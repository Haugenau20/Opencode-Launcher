# Keeping compose in sync with the maintainer repo

This launcher's `docker-compose*.yml` are **close relatives** of the maintainer
repo's (OpenCode-Setup). The images, entrypoint, and the upstream fix tracking
live there; this repo only changes *how the stack is launched and presented*.

The two compose sets must stay **behaviourally in sync** for the runtime blocks
listed below. Rather than fetch a published/templated compose at runtime (extra
network + versioning complexity that fights the "thin glue, `git clone` and run"
goal), we keep our own copy and track the intentional deltas here. When you touch
compose in either repo, walk this list and mirror the runtime-relevant changes.

> **The launcher stack is pull-only.** It never builds the `opencode` or `squid`
> images — it only fetches them from the configured Artifactory and consumes
> them. The maintainer repo's `build:` blocks (`context: .`,
> `dockerfile: opencode/Dockerfile` / `squid/Dockerfile`, the `OPENCODE_VERSION`
> arg) point at source trees that **do not exist in this repo**, so they were
> removed here. **Do not re-add them when mirroring.** The single exception is the
> launcher-only system-package layer (see below), which builds one local image
> from a Dockerfile that *does* live here.

## Blocks that must match the maintainer repo exactly

1. **SELinux relabels (`:z`).** Under enforcing SELinux, bind-mounted host paths
   need a relabel or the container is denied access. Use `:z` (shared), never
   `:Z` (private) — the same host dir (e.g. `extra-allowlist.d`) is mounted
   across every project's stack.
   - `docker/docker-compose.yml`: `${REPO_PATH}:/workspace:z`
   - `docker/docker-compose.yml`: `./extra-allowlist.d:/etc/squid/extra-allowlist.d:ro,z`
     (short syntax, so the flag is expressible)
   - `docker/docker-compose.user-layer.yml`: `${USER_LAYER_PATH:?…}:/home/dev/.config/opencode:z`
   - Named volumes (`oc_state`, `oc_cfg`) are left alone — Docker auto-labels them.

2. **`oc-publish` image tag.** The socat publisher sidecar must resolve to the
   **same image tag** as `opencode` and `squid`. All three read `${IMAGE_TAG}`
   from `.env` (defaults to `latest`; pin to a version like `0.0.2` if you want).
   Keep them sharing the one variable so the publisher can never drift to a
   different/absent tag and silently break `localhost:4096`.

## File location (a presentation-only delta)

The launcher keeps its compose stack under **`docker/`** (`docker/docker-compose.yml`,
`docker/docker-compose.podman.yml`, `docker/docker-compose.user-layer.yml`,
`docker/docker-compose.user-packages.yml`, `docker/Dockerfile.user-packages`) to keep
the repo root uncluttered. The maintainer repo may keep them at its root — that's
fine. **Only the folder differs; the contents of the synced files must still match
block-for-block.** `start.sh` invokes them with `--project-directory <repo-root>`,
so every relative path inside (build `context: .`, the `:z` bind mounts, `env_file`)
still resolves from the root exactly as before. When you mirror a change, compare
the file *bodies*, not their paths.

(The one exception is `docker/docker-compose.user-packages.yml`: because it's a
launcher-only delta, its `dockerfile:` was updated to `docker/Dockerfile.user-packages`
to match the new location. Nothing to mirror.)

## Intentional launcher-only deltas (not mirrored to the maintainer repo)

- **System-package layer** (`docker/docker-compose.user-packages.yml`,
  `docker/Dockerfile.user-packages`, `extra-packages.txt`). A build-time apt layer the
  launcher bakes on top of the pulled base when a developer lists packages. This
  is launcher-only by design: the maintainer image repo builds its base
  differently and doesn't need it. Do **not** port it back.

- **Podman overlay** (`docker/docker-compose.podman.yml`). Adds `userns_mode: keep-id`
  (and the `x-podman` no-op extension) so rootless Podman maps the host user into
  the container and bind-mount ownership stays correct. `start.sh` applies it only
  under Podman (auto-detected, or `--podman`). It is a separate overlay on purpose:
  `keep-id` is a Podman-only value Docker rejects, so it must never land in the
  base `docker/docker-compose.yml`. Launcher-only; do **not** port it back.

## Verified: needs no mirroring

- **Opt-in plugins (`ENABLED_PLUGINS`).** The image bakes in three plugins
  (`superpowers`, `dcp`, `opencode-workspace`), all OFF by default, and its
  entrypoint reads `ENABLED_PLUGINS` on boot to symlink the requested ones in.
  On the launcher side this is **just a plain env var the user sets in `.env`**.
  The opencode service already injects `.env` into the container via
  `env_file: - .env`, so the value reaches the entrypoint with **no compose or
  `start.sh` change** — verified with `docker compose config` that a
  space-separated value (e.g. `superpowers dcp`) survives env_file injection
  intact. The plugin loading itself lives entirely in the image (entrypoint +
  Dockerfile in OpenCode-Setup); nothing here mirrors it. Do **not** add an
  `environment:` entry or any docker-exec/YAML-editing flow for it.

## Reversibility marker — the web-UI / TUI-default flip

The OpenCode build baked into the current image (pinned via `OPENCODE_VERSION`
in the maintainer repo) has a web/desktop UI that roots the agent at `/` instead
of `/workspace` (upstream
[anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
[#14460](https://github.com/anomalyco/opencode/issues/14460)). User-facing prose
deliberately does **not** name the exact version (it moves with image bumps); the
upstream issue numbers are the stable anchor. Because of this the launcher
currently:

- makes the **TUI the default frontend** (`start.sh`, `ATTACH_TUI=1`), and
- prints a **web-UI caveat** on every boot and in the README.

**When to unwind:** once a newer image ships and `opencode serve --help` lists a
`--cwd` flag, the maintainer repo will pass `--cwd /workspace` to `serve`. At
that point the web/desktop UI is rooted correctly again, and this launcher
should:

- revert to "all frontends equal" (drop the TUI-default bias / make `--detach`
  the unremarkable headless option), and
- remove the web-UI caveat from `start.sh` and the README.

Search the tree for `14445` / `14460` to find every spot to flip.

> **Status — still present as of the 1.17.3 image.** The image's OpenCode build
> was bumped to 1.17.3, but that does **not** fix #14445/#14460: the web/desktop
> UI still roots the agent at `/`, and `opencode serve` still has no `--cwd`. So
> the caveat and TUI-default stay. Re-check on each future bump: once
> `opencode serve --help` lists `--cwd`, this whole marker fires — do the flip
> above instead of carrying the caveat forward.
