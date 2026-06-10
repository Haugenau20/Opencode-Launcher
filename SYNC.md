# Keeping compose in sync with the maintainer repo

This launcher's `docker-compose*.yml` are **near-duplicates** of the maintainer
repo's (OpenCode-Setup). The images, entrypoint, and the upstream fix tracking
live there; this repo only changes *how the stack is launched and presented*.

The two compose sets must stay **behaviourally in sync**. Rather than fetch a
published/templated compose at runtime (extra network + versioning complexity
that fights the "thin glue, `git clone` and run" goal), we keep our own copy and
track the intentional deltas here. When you touch compose in either repo, walk
this list and mirror the change.

## Blocks that must match the maintainer repo exactly

1. **SELinux relabels (`:z`).** Under enforcing SELinux, bind-mounted host paths
   need a relabel or the container is denied access. Use `:z` (shared), never
   `:Z` (private) — the same host dir (e.g. `extra-allowlist.d`) is mounted
   across every project's stack.
   - `docker-compose.yml`: `${REPO_PATH}:/workspace:z`
   - `docker-compose.yml`: `./extra-allowlist.d:/etc/squid/extra-allowlist.d:ro,z`
     (short syntax, so the flag is expressible)
   - `docker-compose.user-layer.yml`: `${USER_LAYER_PATH:?…}:/home/dev/.config/opencode:z`
   - Named volumes (`oc_state`, `oc_cfg`) are left alone — Docker auto-labels them.

2. **`oc-publish` image tag.** The socat publisher sidecar must resolve to the
   **same image tag** as `opencode` and `squid`. All three read `${IMAGE_TAG}`
   from `.env` (defaults to `latest`; pin to a version like `0.0.2` if you want).
   Keep them sharing the one variable so the publisher can never drift to a
   different/absent tag and silently break `localhost:4096`.

## Intentional launcher-only deltas (not mirrored to the maintainer repo)

- **System-package layer** (`docker-compose.user-packages.yml`,
  `Dockerfile.user-packages`, `extra-packages.txt`). A build-time apt layer the
  launcher bakes on top of the pulled base when a developer lists packages. This
  is launcher-only by design: the maintainer image repo builds its base
  differently and doesn't need it. Do **not** port it back.

- **Podman overlay** (`docker-compose.podman.yml`). Adds `userns_mode: keep-id`
  (and the `x-podman` no-op extension) so rootless Podman maps the host user into
  the container and bind-mount ownership stays correct. `start.sh` applies it only
  under Podman (auto-detected, or `--podman`). It is a separate overlay on purpose:
  `keep-id` is a Podman-only value Docker rejects, so it must never land in the
  base `docker-compose.yml`. Launcher-only; do **not** port it back.

## Reversibility marker — the web-UI / TUI-default flip

The current image bakes **OpenCode 1.16.2**, whose web/desktop UI roots the
agent at `/` instead of `/workspace` (upstream
[anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
[#14460](https://github.com/anomalyco/opencode/issues/14460)). Because of this
the launcher currently:

- makes the **TUI the default frontend** (`start.sh`, `ATTACH_TUI=1`), and
- prints a **web-UI caveat** on every boot and in the README.

**When to unwind:** once a newer image ships and `opencode serve --help` lists a
`--cwd` flag, the maintainer repo will pass `--cwd /workspace` to `serve`. At
that point the web/desktop UI is rooted correctly again, and this launcher
should:

- revert to "all frontends equal" (drop the TUI-default bias / make `--detach`
  the unremarkable headless option), and
- remove the web-UI caveat from `start.sh` and the README.

Search the tree for `14445` / `14460` / `1.16.2` to find every spot to flip.
