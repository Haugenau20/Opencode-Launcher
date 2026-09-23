# Docker and Podman runtimes

The launcher has one set of shared workflows and separate Docker and Podman
implementations. Configuration, credentials, project names, attachment tracking
and optional features remain shared. `lib/runtime.sh` selects and remembers the
runtime; `lib/runtime/docker.sh` and `lib/runtime/podman.sh` contain the engine
and Compose commands. `lib/compose.sh` assembles the shared service configuration
and resolves host paths before passing it to a provider.

## Scope and validation status

| Engine | Compose provider | Scope |
| --- | --- | --- |
| Docker Engine | Docker Compose plugin | Local rootful Linux engine without daemon-wide user-namespace remapping; existing default |
| Podman | `podman-compose` 1.5.0 or newer | Local rootless Linux engine; new implementation requiring real-container acceptance testing before release |

The Podman provider is invoked directly. Installing Docker Compose alongside it
does not change which provider Podman uses. `podman compose` delegates to an
external provider, so it is not used for implicit provider selection. A
`podman-docker` shim is unnecessary.

Rootless Docker, Docker daemons using `userns-remap`, rootful Podman, Podman
virtual machines, remote engines and interchangeable provider combinations are
outside the initial scope. These Docker namespace modes do not satisfy the
current host-bind UID/GID contract and are rejected during validation. A minimum accepted
provider version is a prerequisite check, not a claim that every release above
it has passed the full application acceptance matrix.

The automated shell tests use simulated engines to verify routing, argument
handling, configuration, binding and lifecycle behavior. Real Compose
configuration tests check both providers independently of a running daemon.

During this branch's development, a local Docker smoke test with cached
OpenCode 1.18.32 and Squid images passed startup, API health inside the container
and through the loopback publisher, and workspace read/write as UID 1000 while
preserving host write ownership. It also confirmed the shared `rw,z` mount
mode after the SELinux workaround described below. This is a focused result,
not completion of the full release matrix or validation of every image/version.

The available host lacked the subordinate UID/GID allocation needed for a real
rootless Podman application run. Podman production-image acceptance remains
pending, as do untested Docker optional-feature and lifecycle combinations.
Do not infer production Podman compatibility merely from passing shell tests.

## Choosing a runtime

```bash
./install.sh --engine docker
./start.sh --engine docker ~/code/project

./install.sh --engine podman
./start.sh --engine podman ~/code/project
```

`--podman` is an alias for `--engine podman`, including in the installer.
The installer validates prerequisites and prints the next command; it does not
start containers, install engines, change groups or configure subordinate IDs.

For a new project, selection follows this order:

1. Explicit `--engine docker` or `--engine podman`.
2. `OCL_ENGINE` from the launcher's configuration.
3. Docker when available; otherwise Podman when it is the available engine.

The selected engine must pass validation. An unavailable Docker daemon does not
trigger a fallback to Podman. Automatic discovery distinguishes Docker Engine
from a Podman-compatible Docker command/backend; the binary's name alone is
insufficient. Use explicit selection if an existing stack cannot be identified
unambiguously.

Docker and Podman have separate registry credentials, image stores and named
volumes. Authenticate with the engine you select:

```bash
docker login <registry-host>
# or
podman login <registry-host>
```

## Project bindings

The launcher stores a binding under `.envs/<project-slug>.runtime` before
creating a stack. It records the engine, provider, endpoint, execution mode and
project configuration references without credentials. The generated project
environment and overlay files hold the effective paths used for that project.
Treat `.envs/` as private launcher state: do not commit it or copy it into a
support ticket.

Later commands for the same repository use that binding:

```bash
./start.sh --status ~/code/project
./start.sh --logs ~/code/project
./start.sh --shell ~/code/project
./start.sh --down ~/code/project
./start.sh --doctor ~/code/project
```

Changing the global default does not redirect a bound project to another
engine. A conflicting explicit engine or endpoint is rejected. Connection
failure does not erase the binding: failed startup must still be inspectable
and cleanable through its original engine. Lifecycle operations for a project
are serialized to avoid two concurrent launches choosing different runtimes.

Existing project names and volume identities are retained. For an existing
stack without a binding, discovery checks the available engines. Ambiguous
matches require explicit selection rather than risking a second stack.

Switching engines is not a data migration. Stop the old stack through its saved
runtime first. Its named volumes remain in that engine's store; a new runtime
cannot read them automatically. After successful `--down`, archive the exact
`.envs/<project-slug>.runtime` file named in the refusal message outside
`.envs/`, then launch with `--engine` for the new engine. Retain the remaining
project files and original engine volumes. Do not reset the binding while the
old stack is running or its engine is unavailable. This manual operation is
intentional; there is no automatic data migration or rebind command.

## Compose configuration and host paths

The base Compose configuration defines OpenCode, Squid, the port publisher,
networks and storage. Runtime and optional-feature overlays add only their
specific differences. Every provider receives absolute host paths for the
workspace, allowlist, user layer, extra folders, environment files and optional
package-build context. The launcher no longer passes `--project-directory`.

Relative configured paths resolve from the launcher checkout. Repository and
`--also` arguments retain their normal command-line path semantics. Paths with
spaces remain individual arguments throughout provider invocation. The launcher
checks that mount sources exist with the required file/directory type, probes
engine access, and checks the sources again immediately before starting the
stack. An ordinarily missing configured directory fails these checks.

Compose mounts use `create_host_path: true` alongside `selinux: z` because the
tested Docker Compose path with `create_host_path: false` dropped SELinux
relabeling. The resulting container could start but could not access the host
files. This behavior is also recorded in [Docker Compose issue
13396](https://github.com/docker/compose/issues/13396). Shared relabeling remains
enabled for the actual services; no service disables SELinux confinement.

This workaround leaves a race: if a source disappears after the last check but
before the engine mounts it, the engine may create a directory. The checks do
not provide an atomic engine-level guarantee against creating missing paths.
Do not remove or replace configured mount sources during startup.

Host bind sources containing a colon (`:`) are rejected before startup. Both
providers use colon-separated bind arguments on the compatibility path that
preserves SELinux relabeling. Use a source path without a colon.

The bundled `extra-allowlist.d/placeholder.conf` is deliberately comment-only.
Squid includes `*.conf`, and an otherwise empty directory needs a matching
file. A custom allowlist directory must also contain a readable `.conf` file.

## Rootless Podman startup

OpenCode Setup's image initializes accounts and managed state as container
root, then drops to the `dev` user. The Podman overlay combines `keep-id` with
an explicit startup user of `0:0` to preserve that initialization contract.
Container root is inside Podman's user namespace. Podman must be configured
with subordinate UID/GID ranges suitable for the image's users before startup.

The runtime must preserve the shared network boundary: OpenCode stays on its
internal network, permitted egress passes through Squid, and published ports
remain on the intended loopback interface. Podman Compose must not place all
services in a shared pod network namespace that collapses that boundary.

Do not repair ownership issues with a recursive ownership change to the user's
repository. The existing OpenCode Setup entrypoint performs recursive workspace
ownership handling; this launcher-only change does not rewrite that entrypoint.
The launcher supplies the host UID/GID and Podman's mapping, and rejects
Podman configurations whose effective `HOST_UID`/`HOST_GID` differ from the
invoking user's IDs. Ownership preservation with the actual image, especially mixed-owner repositories, remains
an integration concern to resolve and verify before declaring Podman supported.

## Mount diagnostics

Run `./start.sh --doctor <repo>` to report the selected engine/provider, versions,
endpoint, rootless mode, configuration and effective mount directories. Doctor
checks local filesystem access without starting containers or dumping
credential values. Local success is not proof of engine access: startup checks
mount access through the selected engine as well. That disposable probe runs
with read-only mounts, no network and no application credentials. It disables
SELinux labeling only for the probe container so it tests filesystem visibility
without changing mount labels. Actual services retain their configured SELinux
labeling; passing the probe does not prove that their relabeling will succeed.

After starting the stack, the launcher waits for OpenCode's `/global/health`
endpoint inside the container before attaching a session or reporting detached
startup success. `OCL_START_TIMEOUT` sets the timeout in seconds (default `60`).
A timeout reports a readiness failure and preserves the project's binding for
inspection and cleanup through the same engine.

For a source-path permission failure, record the exact operation in the error
(`mkdir`, `chown`, `lsetxattr`, etc.) and inspect the path on the engine host:

```bash
namei -l /absolute/path/to/extra-allowlist.d
findmnt -T /absolute/path/to/extra-allowlist.d -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -ldZ /absolute/path/to/extra-allowlist.d
getenforce
```

Parent-directory traversal restrictions, NFS root squashing and SELinux
relabeling are different failure causes. Docker socket permissions matter only
when connecting to the daemon fails. They do not explain a daemon that accepts
the command and then fails to prepare a host mount. An administrator can inspect
recent SELinux AVC denials after reproducing the failure; do not disable
SELinux as a generic workaround.

## Release acceptance

The separate [container smoke harness](../tests/integration/README.md) exercises
both providers with disposable fixture services; CI has independent Docker and
rootless Podman jobs. Those fixtures do not replace production-image acceptance.
Run the same scenarios against real Docker and rootless Podman using the actual
OpenCode Setup images and registry configuration:

- Fresh startup, readiness, TUI attachment, shell, logs, status and shutdown.
- Multiple attached terminals, persistence, interruption and failed-start cleanup.
- Piped `--exec` input, stdout and exit-code propagation.
- Existing project adoption, saved runtime routing and rejected engine conflicts.
- Workspace and configuration persistence with ordinary and non-default UIDs.
- Allowlist, user layer, extra folders, optional packages and paths with spaces.
- Host ownership preservation and mounts on an enforcing SELinux system.
- Successful permitted proxy traffic and rejected direct outbound traffic.
- Engine outages without fallback or accidental creation in another store.

Record exact engine/provider versions and image digests in the test results.
Only then publish a tested compatibility matrix.
