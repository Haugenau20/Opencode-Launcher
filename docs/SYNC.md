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
   - `docker/docker-compose.yml`: `${EXTRA_ALLOWLIST_PATH:-./extra-allowlist.d}:/etc/squid/extra-allowlist.d:ro,z`
     (short syntax, so the flag is expressible)
   - `docker/docker-compose.user-layer.yml`: `${USER_LAYER_PATH:?…}:/home/dev/.config/opencode:z`
   - Named volumes (`oc_state`, `oc_cfg`) are left alone — Docker auto-labels them.

2. **`oc-publish` image tag.** The socat publisher sidecar must resolve to the
   **same image tag** as `opencode` and `squid`. All three read `${IMAGE_TAG}`
   from `.env` (defaults to `latest`; pin to a version like `0.0.2` if you want).
   Keep them sharing the one variable so the publisher can never drift to a
   different/absent tag and silently break `localhost:4096`.

3. **`oc-publish` viewer-port block (opencode-pty).** The dual-socat
   `entrypoint`/`command` shell wrapper, its second `ports:` line, and the
   `opencode` service's `PTY_WEB_HOSTNAME`/`PTY_WEB_PORT` environment lines
   must stay **byte-for-byte identical** to the maintainer repo:
   - `docker/docker-compose.yml` (`opencode` `environment:`):
     `PTY_WEB_HOSTNAME: "0.0.0.0"` and `PTY_WEB_PORT: "1${OPENCODE_PORT:-4096}"`
   - `docker/docker-compose.yml` (`oc-publish`): the `entrypoint: ["/bin/sh", "-c"]`
     + `trap 'kill 0' TERM INT` / dual-`socat` / `wait` `command:` block, and
     the second `ports:` entry `"127.0.0.1:1${OPENCODE_PORT:-4096}:1${OPENCODE_PORT:-4096}"`

   The second socat leg and the `PTY_WEB_*` env vars are what let the
   opencode-pty viewer (started in the TUI via `/pty-open-background-spy`) be
   reached from the host at `1<OPENCODE_PORT>`. A drift here breaks the viewer
   the same way an `oc-publish` tag drift breaks the main web UI (see #2) —
   `oc-publish` would either fail to bind the second port or forward it to a
   host/port the opencode-pty server isn't actually listening on.

4. **`env_file` per-project layering (`opencode` service).** Two entries,
   last-wins, order IS the mechanism:
   ```yaml
       env_file:
         - .env
         - path: ${PROJECT_ENV_FILE:-.env}
           required: false
   ```
   `--env-file` (the `docker compose` CLI flag `start.sh`/`lib/project.sh`
   already pass) only drives compose's `${VAR}` *interpolation* — it puts
   nothing inside a container. Only an `env_file:` directive does that, and it
   needs a literal path. Without this second layer every project's container
   gets the exact same credentials as every other, no matter how many
   `--env-file`s differ. `PROJECT_ENV_FILE` unset defaults to `.env`, so the
   file is read twice and nothing changes — the single-project case, intact.
   `required: false` keeps a project with no generated file yet from being an
   error. See `PROJECT_ENV_FILE` under "Shared env-var contracts" below for
   who sets it.

5. **`EXTRA_ALLOWLIST_PATH` squid allowlist override.** Mirrors item 1's
   `:ro,z` bind mount above — `${EXTRA_ALLOWLIST_PATH:-./extra-allowlist.d}` —
   but is listed separately here because the override itself (not just the
   SELinux flag) must match: unset, it resolves to the same shared directory
   every project used before; set, it points one project's squid at its own
   allowlist directory instead.

6. **`OPENCODE_INTERNAL_PORT` parameterization.** The in-container listen
   port used to be a hardcoded `4096` in three spots; all three now read
   `${OPENCODE_INTERNAL_PORT:-4096}`, keeping the default identical while
   letting the maintainer repo's stacks (which decouple host and container
   ports) and this launcher agree on the mechanism:
   - `docker/docker-compose.yml` (`opencode` `environment:`):
     `OPENCODE_INTERNAL_PORT: "${OPENCODE_INTERNAL_PORT:-4096}"`
   - `docker/docker-compose.yml` (`oc-publish` `command:`, first socat leg):
     `socat TCP-LISTEN:${OPENCODE_INTERNAL_PORT:-4096},fork,reuseaddr TCP:opencode:${OPENCODE_INTERNAL_PORT:-4096}`
   - `docker/docker-compose.yml` (`oc-publish` `ports:`, first mapping):
     `"127.0.0.1:${OPENCODE_PORT:-4096}:${OPENCODE_INTERNAL_PORT:-4096}"`

   This launcher does not currently vary `OPENCODE_INTERNAL_PORT` from its
   default — the point of mirroring it now is so the block matches the
   maintainer repo byte-for-byte, not that this launcher exposes a new knob.

7. **`NO_PROXY`/`no_proxy` (`opencode` `environment:`).** Must be, exactly:

   ```yaml
         NO_PROXY: "localhost,127.0.0.1,::1,opencode,squid,rag"
         no_proxy: "localhost,127.0.0.1,::1,opencode,squid,rag"
   ```

   This is the docker-side copy of the image's own `policy.yaml` `NO_PROXY`,
   and the two must agree: it exists so in-container DNS for the sidecars
   (`opencode`, `squid`, `rag`) bypasses the proxy.

   **Never add `.local` — or any other corp-domain suffix — to this list.**
   Squid is the container's only route out, so every entry here is a hole
   punched *around* it. A corp service addressed by a `*.local` FQDN (e.g.
   `bitbucket.corp.local`) matches the suffix, gets routed **directly**
   instead of through squid, and fails with `could not resolve host` /
   `CONNECT tunnel failed` — which is what git-over-HTTPS to an internal
   Bitbucket used to do. The maintainer repo dropped `.local` in image
   `0.1.0` for exactly this reason; this launcher carried it until `0.17.0`
   (see the changelog), and the drift was invisible because nothing compares
   the two files automatically. The entries that belong here are loopback and
   compose **service names** only — never a DNS suffix.

## Shared env-var contracts (launcher sets, image consumes)

These are behavioural contracts, not compose blocks to compare line-for-line:
the launcher produces an env var and the image's entrypoint consumes it. Keep
the name and semantics in sync across both repos.

- **`OPENCODE_EXTRA_INSTRUCTIONS`** — a space/comma-separated list of absolute
  *container* paths to extra instruction files. The image's entrypoint appends
  each to `opencode.json`'s `instructions` array at boot (concatenated with
  `AGENTS.md`); unset ⇒ no-op. The launcher sets it **only** from the `--also`
  overlay's `environment:` block, pointing at the generated breadcrumb mounted
  at `/etc/opencode/also-context.md` (see `lib/also.sh`; the breadcrumb is what
  makes `--also` folders discoverable to the agent).

  This var is **internal launcher→image plumbing, not a user knob.** It must
  appear in **neither** the image's `manifest.json` **nor** this launcher's
  `.env.example`. That symmetry is load-bearing: `manifest_missing_keys`
  (`lib/manifest.sh`) warns when the image manifest lists an env key this
  launcher's `.env.example` doesn't — so listing it in the manifest but not
  `.env.example` would fire a bogus "update your launcher" drift warning, while
  adding it to `.env.example` would wrongly advertise an internal var as a user
  setting. Keeping it out of both is the invariant; do not add it to either.

- **`PTY_WEB_HOSTNAME`/`PTY_WEB_PORT`** — told to the opencode-pty plugin so its
  web-viewer server binds `0.0.0.0` (non-loopback, so `oc-publish`'s second
  socat leg can reach it) on the derived `1<OPENCODE_PORT>` port. Same
  symmetric-exclusion invariant as `OPENCODE_EXTRA_INSTRUCTIONS` above: these
  are set **only** in `docker/docker-compose.yml`'s `opencode` `environment:`
  block (computed from `OPENCODE_PORT`, not a user-facing setting), and must
  appear in **neither** `.env.example` nor the image's `manifest.json` — adding
  them to either would either advertise internal plumbing as a user knob, or
  trip `manifest_missing_keys`' drift warning for a key `.env.example`
  deliberately never carries.

- **`PROJECT_ENV_FILE`** — the absolute path to the generated per-project env
  file (`.envs/<slug>.env`, produced by `write_project_env`/the boot flow's
  own copy of it), passed to `docker/docker-compose.yml`'s `opencode`
  `env_file:` layer (see block 4 above) so per-project credentials actually
  reach the container instead of only driving `--env-file` interpolation.
  Exported by `derive_project_settings` and `project_env_for_management` in
  `lib/project.sh`, and by the equivalent inline step in `start.sh`'s boot
  flow (`cmd_run`) — every code path that assembles the `COMPOSE` array sets
  it. It must be **absolute**: `env_file:` paths resolve against
  `--project-directory` (`$__OCL_DIR`), not against `$ENVS_DIR`'s own
  (typically CWD-relative) meaning, so a relative value would resolve against
  the wrong base and silently vanish behind `required: false` — no error, just
  a project quietly back on shared credentials.

  Same symmetric-exclusion invariant as `OPENCODE_EXTRA_INSTRUCTIONS` and
  `PTY_WEB_HOSTNAME`/`PTY_WEB_PORT` above: this is **internal
  launcher→container plumbing, computed by the launcher from `ENVS_DIR` +
  the derived slug, not a user knob.** It must appear in **neither**
  `.env.example` **nor** the image's `manifest.json`. A future contributor
  will be tempted to add it to `.env.example` as "the var that controls which
  env file loads" — don't; the launcher sets it per boot, and a user-set value
  in `.env` would just be overwritten (or, worse, read back through the very
  layering mechanism it's meant to select).

- **`EXTRA_ALLOWLIST_PATH`** — optional per-project override of the squid
  `extra-allowlist.d` bind-mount source (see block 5 above); unset, every
  project shares the one committed `./extra-allowlist.d`. This launcher does
  not currently generate or set a value for it anywhere (no per-project
  allowlist-directory feature yet) — it exists in `docker/docker-compose.yml`
  purely so the block matches the maintainer repo's contract, ready for that
  feature to land. Same invariant as `PROJECT_ENV_FILE`: if/when a per-project
  allowlist feature is added, this stays **launcher-computed, not a
  `.env.example`/`manifest.json` entry** — do not add it to either.

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

- **`--also` extra-mount overlay** (`.envs/<slug>.also.yml` plus its breadcrumb
  `.envs/<slug>.also-context.md`, generated at boot by `start.sh` — see
  `lib/also.sh`, not files checked into the repo). Adds `/workspace-extra/<name>`
  bind mounts (`:ro,z` by default, `:z` for a `--also <path>:rw`) for extra host
  folders the launcher user wants the agent to read, alongside the main repo at
  `/workspace`. The **mounts themselves** need nothing from the image — the
  entrypoint only ever `chown -R`s `/workspace`, never `/workspace-extra`. The
  repeatable `--also <path>[:rw]` flag, the sticky overlay/breadcrumb files, and
  `--status` reporting are all launcher-only; do **not** port them back.

  **One caveat vs. the old "no image-side dependency" wording:** making those
  mounts *discoverable* to the agent does lean on a shared contract. opencode
  runs with `/workspace` as its project root and never searches siblings, so the
  launcher writes the breadcrumb (naming each mount and its `/workspace-extra/<name>`
  path) and points the image at it via `OPENCODE_EXTRA_INSTRUCTIONS` (see the
  shared-contract section above). The image stays generic — it has no `--also`
  or `/workspace-extra` knowledge, only "load the instruction files this var
  names." On an image too old to honor the var, the folders are still mounted
  and readable, just not advertised.

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

- **Opt-in plugins (`ENABLED_PLUGINS`).** The image bakes in four plugins
  (`superpowers`, `dcp`, `opencode-workspace`, `opencode-pty`), all OFF by
  default, and its entrypoint reads `ENABLED_PLUGINS` on boot to symlink the
  requested ones in. On the launcher side this is **just a plain env var the
  user sets in `.env`**. The opencode service already injects `.env` into the
  container via `env_file: - .env`, so the value reaches the entrypoint with
  **no compose or `start.sh` change** — verified with `docker compose config`
  that a space-separated value (e.g. `superpowers dcp`) survives env_file
  injection intact. The plugin loading itself lives entirely in the image
  (entrypoint + Dockerfile in OpenCode-Setup); nothing here mirrors it. Do
  **not** add an `environment:` entry or any docker-exec/YAML-editing flow for
  the *enable/disable* mechanism itself.

  **`opencode-pty` is the one exception to "no compose change."** Unlike the
  other three (purely image-internal), it needs a host-reachable port for its
  web viewer — that's the `PTY_WEB_HOSTNAME`/`PTY_WEB_PORT` environment lines
  and the `oc-publish` dual-socat/second-`ports:` block described above (see
  "Blocks that must match the maintainer repo exactly" #3 and the
  `PTY_WEB_HOSTNAME`/`PTY_WEB_PORT` entry under "Shared env-var contracts").
  Those DO need mirroring; only the enable-list plumbing itself doesn't.

## Reversibility marker — the web-UI working-directory default

The OpenCode build baked into the current image (pinned via `OPENCODE_VERSION`
in the maintainer repo) defaults a NEW web/desktop-UI session's working directory
to `/` instead of `/workspace` (upstream
[anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445)).
This is only the default: typing `/workspace` into the working-directory prompt
when starting a New session roots that session at the repo. User-facing prose
deliberately does **not** name the exact version (it moves with image bumps); the
upstream issue number is the stable anchor. Because of this the launcher
currently:

- keeps the **TUI as the default frontend** (`start.sh`, `ATTACH_TUI=1`) — it's
  the zero-setup path (always `/workspace`), and
- prints a **web-UI note** on every boot and in the README pointing at the
  one-step New-session working-directory action.

**When to unwind:** once a newer image ships and a New session in the web UI
defaults to `/workspace` without touching the working directory, the manual step
is no longer needed. At that point this launcher should:

- keep the **TUI as the default frontend** (persisting current behavior — the TUI
  stays the simplest, zero-setup path), and
- remove the web-UI note from `start.sh` and the README.

Search the tree for `14445` to find every spot to flip.

> **Status — still present as of the 1.17.3 image.** The image's OpenCode build
> was bumped to 1.17.3, but that does **not** change the #14445 default: a new
> web/desktop-UI session still starts in `/`. Verified against OpenCode source at
> the pinned tags v1.16.2 and v1.17.3, and confirmed by manual testing. Note that
> `opencode serve` resolves the working directory per-request (via an
> `x-opencode-directory` header) and will **not** gain a `--cwd` flag — do not
> wait for one. Re-check on each future bump: once a New session in the web UI
> defaults to `/workspace`, this marker fires — do the flip above instead of
> carrying the note forward.
