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
