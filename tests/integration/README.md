# Real runtime smoke tests

Run on a disposable Linux test host with a configured engine:

```bash
bash tests/integration/runtime-smoke.sh docker
bash tests/integration/runtime-smoke.sh podman
```

The Podman case requires rootless Podman, subordinate UID/GID mappings and
`podman-compose >= 1.5.0`. The harness does not modify host configuration. It
builds a small local fixture image, creates a unique project, and removes only
that project's containers, networks and volumes on exit. The built fixture
image remains cached. No launcher credentials or existing projects are used.

Both cases exercise the checked-in base Compose file, runtime adapter and
binding code; Podman also uses the checked-in Podman overlay. A final test
overlay substitutes small Python-based application/proxy fixtures and adds an
origin server on the external network. The original publisher runs its real
`socat` command. Checks cover:

- Absolute bind paths containing spaces, from a different working directory,
  with the allowlist mount verified read-only.
- Container-root initialization followed by the configured application UID/GID.
- Workspace access without changing the ownership of existing host files.
- Both loopback publisher ports.
- Proxy access to an external-network service and rejected direct TCP access.
- Container discovery, piped input, and command exit status.
- Named configuration/state volume persistence through down/up.
- Reusing the saved engine after the configured default changes.

This is a container/provider integration test, not full OpenCode acceptance.
The production OpenCode/Squid images, optional package and user-layer features,
multiple terminals, real allowed/denied Squid destinations, an enforcing
SELinux host, and interruption/recovery still require the release matrix in
`docs/RUNTIME_ARCHITECTURE.md`. A smoke test passing does not establish those
additional combinations. CI runs rootful Docker and rootless Podman separately.

## Production-image acceptance

`production-acceptance.sh` is an opt-in target-host harness. It uses
`runtime_select`, `runtime_validate`, `compose_prepare`, mount validation and
probes, the checked-in Compose files, and runtime dispatch. It does not change
user namespaces, SELinux policy, engine settings, login sessions, or run host
ownership repair commands. Run it as the intended ordinary account on each prepared Docker or
rootless Podman host. The engine, Compose provider, registry login, subordinate
IDs, and permitted proxy destination must already work. Use a disposable
workspace and an allowlist with a readable `.conf` file. Images must already be
pulled into the selected engine; supply full registry references or pinned
`@sha256:` references independently for OpenCode and Squid.

```bash
bash tests/integration/production-acceptance.sh \
  --engine podman \
  --opencode-image 'registry.example.com/team/opencode@sha256:<digest>' \
  --squid-image 'registry.example.com/team/squid@sha256:<digest>' \
  --workspace '/tmp/acceptance workspace' \
  --allowlist '/tmp/acceptance allowlist' \
  --port 8192 \
  --proxy-url https://permitted.example.com/health \
  --selinux enforcing \
  --results /tmp/acceptance-podman-2026-09-29
```

Replace the example references and destination with real values. Both `8192`
and its `18192` viewer port must be free on loopback. The URL must give a
successful response through Squid and fail when fetched directly from
OpenCode. It cannot contain URL credentials, query, or fragment data. Use
`--env-file /path/to/project.env` for needed application settings; its values
are copied into private transient state and never written into the report.
For optional features, add `--user-layer DIR`, `--also-ro DIR`, `--also-rw DIR`,
and `--packages-file FILE`. The package file is copied into a disposable build
context; the checkout's `extra-packages.txt` is untouched. `--mixed-owner-file`
accepts an existing file *inside* the workspace whose UID/GID should remain
unchanged. `--timeout` sets the readiness deadline (default 90 seconds). Repeat
with each required feature combination and a new results directory. Do not use
a live worktree: the production image entrypoint may change ownership of
workspace contents.

The harness checks selected-image repository digests, real application health
through its internal and published endpoints, running services and logs,
workspace access, host ownership of its marker and optional mixed-owner
sentinel, proxy egress and rejected direct egress, allowlist and extra-mount
read-only flags, writable extra mounts, user-layer access, persistence after
down/up, and saved-engine conflict rejection. It tears down its unique Compose
project and volumes, and removes its marker and temporary files. A failed
cleanup retains the private recovery state and prints its path; remove the
project with the same engine before deleting it. The local package build image
remains cached. Compose's shared SELinux relabeling acts on the supplied mount
paths; inspect their labels afterward on an enforcing target.

The private `run.txt` records the launcher revision, engine/provider versions,
mode, UID/GID, SELinux mode, image references and matching repository digests,
image IDs, configured paths and URL, and exit code. `checks.tsv` records `PASS`,
`FAIL`, or `NOT_RUN`. Preserve both files with the release evidence. If a check
fails, the harness reports the current case, cleans up its project, and exits
nonzero. Do not treat a run with any `NOT_RUN` rows as full release acceptance.

Complete and record these cases manually on the same target host, using the
same images and `./start.sh --engine ...` against a separate disposable project.
The launcher derives its two images from one `IMAGE_REGISTRY`/`IMAGE_TAG` pair;
configure that pair to resolve to the same tested artifacts for these launcher
flows, or record the image mismatch as an outstanding acceptance gap:

- Attach two terminals; interrupt one TUI, use `--shell`, `--status`, and
  `--logs`, then shut down and verify the other session's lifecycle.
- Pipe input through `--exec`, check exact stdout and exit status, and
  interrupt/restart a one-shot run.
- Exercise a failed start and recovery, existing unbound project adoption,
  and an engine outage without automatic fallback or creation in another store.
- Enable the pty plugin and test its `1<port>` publisher; verify a deliberately
  denied proxy destination and that the allowlist remains read-only.
- Review original file ownership and SELinux labels for mixed-owner workspaces,
  especially after a Podman run. Repeat under non-default host UIDs and with
  each optional-layer combination destined for release.

Record manual observations beside the generated files. The fixture CI workflow
is unchanged. Production compatibility remains unclaimed until target-host
runs and the outstanding manual cases are reviewed.
