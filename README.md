# OpenCode Launcher

A thin **launcher** that runs a pre-built, locked-down OpenCode environment
against your own code repo. It pulls two images from Artifactory and wires them
together with `docker compose` — the agent runs sandboxed behind a Squid proxy
with a baked-in egress allowlist, so it can only reach the LLM endpoint,
Bitbucket, and JIRA. Everything that must stay locked down (the agent bundle,
policy, allowlist, CA) lives inside the images; this repo is just the glue.

## Prerequisites

- **Linux** with **Docker** (Engine + the `docker compose` v2 plugin).
- Your user is in the **`docker` group**
  (`sudo usermod -aG docker $USER && newgrp docker`).
- **Access to Artifactory** for the images. If a pull fails with an auth error,
  run: `docker login <registry-host>`.
- **Podman** (rootless, with the `podman-docker` shim) works too — `start.sh`
  auto-detects it and applies a `keep-id` userns overlay so bind-mount ownership
  stays correct. Force it with `--podman` if detection misses.

## Quickstart

```bash
git clone <this-launcher-repo>
cd opencode-launcher
./start.sh ~/code/your-repo
```

On the **first run** the script copies `.env.example` → `.env` and prompts for
your LLM endpoint/key and the Artifactory path. The Bitbucket user/PAT and git
identity are **optional** — press Enter to skip any you don't need. It writes
the values into `.env` and auto-fills your `HOST_UID`/`HOST_GID`, then pulls the
images and boots the stack. Later runs reuse `.env`, so there's no prompt — to
change a secret, just edit `.env` (it's gitignored) and it takes effect next run.

When the stack is up, `start.sh` **attaches the OpenCode TUI** in your terminal,
rooted at `/workspace` (your repo). By default, **exiting the TUI (or Ctrl-C)
tears the stack down** again — a clean one-command-in, one-command-out flow with
no stacks left running in the background.

## Session & lifecycle flags

`start.sh` attaches the TUI and tears the stack down on exit by default. Flags
change that:

| Flag (aliases)        | What it does |
| --------------------- | --- |
| `--persist` (`--web`) | Keep the stack and its web UI running after you exit; resume your last session later with the `opencode -c` command `start.sh` prints. |
| `--detach` (`--no-tui`) | Boot without attaching the TUI at all (CI, or web-UI-only). Also leaves the stack running. |
| `--continue` (`-c`)   | Resume your most recent session instead of opening a fresh one. Maps 1:1 to opencode's own `--continue`/`-c` — check opencode's docs for semantics. |

```bash
./start.sh --persist ~/code/your-repo    # stay up after you exit
./start.sh --detach  ~/code/your-repo    # headless, never attach the TUI
```

> Passing `--continue` with no previous session is harmless: opencode prints a
> server error and starts a fresh one on your first prompt.

### Frontends: TUI (default) vs. web UI

The launcher prints a web-UI URL too (`http://localhost:4096`), but the **TUI is
the default and the recommended frontend right now** — the web/desktop UI has a
known workspace-rooting bug (see [Known limitations](#known-limitations)). The
TUI is unaffected (the launcher attaches it with `-w /workspace`).

## Running more than one repo

One launcher clone handles many repos — just point `start.sh` at another path:

```bash
./start.sh ~/code/another-service
```

Each invocation derives its own project slug, port, and workspace mount from the
path argument (these are **not** stored in `.env`). Only one project can use the
**browser UI** at a time; see [Known limitations](#known-limitations).

## Known limitations

Both stem from the OpenCode build in the current image and will ease as newer
images ship.

- **Web/desktop UI roots the agent at `/`, not `/workspace`.** It can read across
  the container, but writes to your repo fail unless you name full paths. This is
  a confirmed upstream bug
  ([anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
  [#14460](https://github.com/anomalyco/opencode/issues/14460)), not a launcher
  defect, and `opencode serve` in the current image has no `--cwd` to override it.
  **Workaround:** make your first web-UI prompt `cd /workspace`. The **TUI is
  unaffected.** This reverts to "all frontends equal" once a newer image ships
  `opencode serve --cwd /workspace`.
- **Only one browser UI at a time (port 4096).** The web/desktop UI hardcodes
  port **4096** in its API calls. If 4096 is already taken, `start.sh` boots the
  new project on the next free port and warns you — that project still works
  fully via the **TUI**, it just can't use the browser UI on the alternate port.

## Customizing the environment

You can layer in your own OpenCode agents/skills/commands, and bake extra system
packages into the image — both self-service, without entering the container or
rebuilding the shared base. See [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md).

## Choosing a model

The internal LLM endpoint serves a few different models, and they are not
interchangeable — MiniMax for long autonomous coding, Qwen for heavy reasoning
and large-context/multilingual work, Gemma for fast well-scoped tasks and
anything with an image. See [`docs/MODELS.md`](docs/MODELS.md) for a side-by-side
comparison (with benchmarks) and a "when to reach for which" guide. Switching the
active model is handled by OpenCode itself.

## Plugins

The image ships three OpenCode plugins, **baked in but OFF by default** (opt-in).
They load offline from files inside the image, so enabling them adds **no network
access**:

| Name | What it does | Upstream |
| --- | --- | --- |
| `superpowers` | Skills library: brainstorming, writing-plans, systematic-debugging, TDD, code review, etc. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens (no user-facing tool). | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |

> **WARNING! Do not enable `opencode-workspace` if you use Qwen.** The extra tools and
> system prompt it injects are rejected by Qwen's upstream, so every prompt then
> fails with `AI_APICallError: Failed to communicate with the upstream service`.
> Other models (e.g. MiniMax, Gemma) are unaffected. Leave this plugin disabled
> when working with Qwen.

Turn them on with a single host-side variable in `.env` — a space- or
comma-separated list:

```dotenv
ENABLED_PLUGINS=superpowers dcp
```

The **first run also offers to enable them** (an optional prompt, default none),
so you can opt in without editing `.env` by hand. Leave it empty for none. On boot the image symlinks the listed plugins into
OpenCode's plugin directory. **OpenCode only loads plugins at startup, so a
restart applies your change — and re-running `./start.sh` IS the restart.** Once
inside the TUI, the **`/plugins`** command lists the catalog and each plugin's
on/off state.

> **Pin `IMAGE_TAG` for reproducible plugins.** Because the plugin set and its
> versions move with the image, pin `IMAGE_TAG` in `.env` to an explicit version
> (e.g. `0.0.2`) rather than the moving `latest` (see below) if you rely on a
> specific plugin set.

## Updating to a new image

Images are pulled fresh from Artifactory on every `./start.sh`. By default
`IMAGE_TAG` is `latest` (the moving tag that always points at the newest
upload), so you generally get updates automatically. To pin a specific version,
set `IMAGE_TAG` in `.env` to an explicit number (e.g. `0.0.2`). Occasionally
`git pull` this launcher repo to pick up topology changes.

## Testing

`start.sh` has an automated test suite (bats) that needs no Docker daemon or
Artifactory access — a fake `docker` stands in:

```bash
./tests/run.sh
```

See [`tests/README.md`](tests/README.md) for what's covered and how to add more.

## Troubleshooting

- **`docker login` needed** — the most common first-time failure. If a pull
  fails with `unauthorized`/`denied`, run `docker login <registry-host>` and
  retry.
- **Not in the docker group** — if Docker says *permission denied*, run
  `sudo usermod -aG docker $USER && newgrp docker`.
- **Don't run `docker compose up` by hand.** Always go through `start.sh` — it
  wires up the per-project env file and project name and pulls the images first.
  (The base `docker-compose.yml` carries `build:` blocks for the maintainer
  repo's benefit, but the images are pulled, not built here; a hand-run `up` that
  forces a build would fail.)
- **Linux only** — matches the parent system's supported scope.

## What's in this repo

| File | Purpose |
| --- | --- |
| `start.sh` | The launcher. Prompts for secrets, computes per-project settings, boots the stack, attaches the TUI. |
| `docker-compose.yml` | Topology (networks, volumes, services). A near-copy of the maintainer repo's — see [`SYNC.md`](SYNC.md) for the deltas that must stay mirrored. |
| `docker-compose.user-layer.yml` | Optional overlay bind-mounting your personal config layer (see [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md)). |
| `docker-compose.user-packages.yml` | Optional overlay (with `Dockerfile.user-packages`) that bakes your `extra-packages.txt` into a local opencode layer at build time (see [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md)). |
| `docker-compose.podman.yml` | Optional overlay applied under rootless Podman (`keep-id` userns + `x-podman`); auto-detected by `start.sh`, or forced with `--podman`. |
| `extra-packages.txt.example` | Template for the per-developer `extra-packages.txt` (gitignored) list of apt and `pip:` packages to bake in. |
| `.env.example` | Template for the shared `.env` (secrets, identity, toggles). |
| `extra-allowlist.d/` | Bind-mounted (read-only) into Squid for local allowlist drop-ins (`*.conf`). |
| `SYNC.md` | The list of intentional deltas between this launcher's compose and the maintainer repo's. |

> **Maintainer note:** before first run, replace the
> `CHANGEME.artifactory.example/opencode-workplace` placeholder for
> `IMAGE_REGISTRY` in `.env` with your real Artifactory path. `start.sh` warns
> if it still looks like a placeholder.
