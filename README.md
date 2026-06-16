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
images and boots the stack.

When the stack is up, `start.sh` **attaches the OpenCode TUI** in your terminal,
rooted at `/workspace` (your repo). By default, **exiting the TUI (or Ctrl-C)
tears the stack down** again — a clean one-command-in, one-command-out flow with
no stacks left running in the background.

Want it to stay up after you exit? Pass **`--persist`** (alias `--web`): the
stack (and its web UI) keeps running, and you can **resume your last session**
later with the `opencode -c` command `start.sh` prints. For a headless boot that
never attaches the TUI, use **`--detach`** (see below).

Later runs reuse `.env`, so there's no prompt.

### Frontends: TUI (default) vs. web UI

The launcher prints a web-UI URL too (`http://localhost:4096`), but the **TUI is
the default and the recommended frontend right now**:

> ⚠️ **Web/desktop UI caveat.** On the OpenCode version baked into the current
> image, the **web and desktop UIs root the agent at `/` instead of
> `/workspace`** — so it can read across the container but writes to your repo
> fail unless you name full paths. This is a confirmed upstream bug
> ([anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
> [#14460](https://github.com/anomalyco/opencode/issues/14460)), not a launcher
> defect, and `opencode serve` in the current image has no `--cwd` to override it.
>
> The web UI stays available and is still useful — just make your **first prompt
> `cd /workspace`** so the agent works inside your repo. The **TUI is
> unaffected** (the launcher attaches it with `-w /workspace`).
>
> This will be reverted to "all frontends equal" once a newer image ships
> `opencode serve --cwd /workspace`.

**Resuming a session.** By default `start.sh` opens a fresh opencode session.
Pass `--continue` (or `-c`) to resume your most recent one instead — this maps
1:1 to opencode's own `--continue`/`-c`, so check opencode's docs for its
semantics. If there is no previous session, opencode prints a harmless server
error and starts a new one on your first prompt.

**Keeping the stack alive.** Exiting the TUI tears the stack down by default. To
keep it running after you exit — so the web UI stays up and you can resume with
`opencode -c` later — boot with `--persist` (alias `--web`):

```bash
./start.sh --persist ~/code/your-repo
```

**Headless / scripted runs.** To boot the stack without attaching the TUI at all
(CI, or when you only want the web UI), pass `--detach` (alias `--no-tui`) — this
also leaves the stack running:

```bash
./start.sh --detach ~/code/your-repo
```

## Running more than one repo

One launcher clone handles many repos — just point `start.sh` at another path:

```bash
./start.sh ~/code/another-service
```

Each invocation derives its own project slug, port, and workspace mount from the
path argument (these are **not** stored in `.env`).

> **Port-4096 caveat.** The OpenCode web/desktop UI hardcodes port **4096** in
> its API calls, so only **one** project can use the browser UI at a time. If
> 4096 is already taken, `start.sh` boots the new project on the next free port
> and warns you — that project still works fully via the **TUI** (the default),
> it just can't use the browser UI on the alternate port.

## Updating your secrets later

Just edit `.env` in your editor (it's gitignored). The values take effect on the
next `./start.sh`.

## Adding your own agents/skills

You can layer in your own personal agents, skills, and commands on top of the
baked-in bundle. By default they live in a per-project named volume inside the
container. To make them **host-editable** — so you can edit them from your
editor without entering the container — set `USER_LAYER_PATH` in `.env` to a
host directory:

```dotenv
USER_LAYER_PATH=./user-layer
```

`start.sh` creates and bind-mounts that directory at
`/home/dev/.config/opencode`. It's a single "you-only" layer **shared across
every repo you launch**, so your personal config follows you everywhere. The
default `./user-layer` dir is gitignored.

## Adding system packages

Need a system tool like `cmake`, or a Python library, in the environment? List
it, self-service, without bloating the shared base image for everyone else. Copy
`extra-packages.txt.example` → `extra-packages.txt` (gitignored) and add one
package per line. Each line is one of (`#` comments and blank lines are ignored):

| Line          | Installs with | Notes                                  |
| ------------- | ------------- | -------------------------------------- |
| `NAME`        | `apt-get`     | no prefix — backward compatible        |
| `apt:NAME`    | `apt-get`     | explicit, same as no prefix            |
| `pip:SPEC`    | `pip3`        | e.g. `pip:requests`, `pip:numpy==1.26.0` |

```text
cmake
apt:ripgrep
pip:requests
pip:httpx==0.27.0
```

On the next `./start.sh`, the packages are fetched with `apt-get`/`pip3` at
**build time on your host** — which has normal internet, so this step does
**not** go through the Squid proxy — and baked into a thin local image layered
on top of the pulled base. pip requirements are installed system-wide (and
auto-pull `python3-pip` if the base image lacks it), so they land on the agent's
`PATH` at runtime. The locked-down **runtime is unchanged**: no new egress, no
root for `dev`; the packages are simply present for the agent to use. An empty
or absent `extra-packages.txt` does nothing (no extra build).

## Plugins

The image ships three OpenCode plugins, **baked in but OFF by default** (opt-in).
They load offline from files inside the image, so enabling them adds **no network
access**:

| Name | What it does | Upstream |
| --- | --- | --- |
| `superpowers` | Skills library: brainstorming, writing-plans, systematic-debugging, TDD, code review, etc. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens (no user-facing tool). | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |

> **Versions live in the image, not here.** This launcher *pulls* a pre-built
> image, so the exact pinned plugin versions track the image (via `IMAGE_TAG`),
> not this repo — don't treat anything here as the authoritative version. The
> **live set and versions** are shown by the **`/plugins`** command in the TUI,
> and the canonical pins live in the image repo
> ([Haugenau20/OpenCode-Setup](https://github.com/Haugenau20/OpenCode-Setup) →
> `opencode/Dockerfile` and its README "Plugins" table).

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
- **Don't run `docker compose up` by hand.** Always go through `start.sh`, which
  wires up the per-project env file and project name and pulls the images before
  bringing the stack up. Note the base `docker-compose.yml` carries `build:`
  blocks for the maintainer repo's benefit, but there are no Dockerfiles here for
  `opencode`/`squid`; `start.sh` pulls first so `up` uses the pulled images and
  never tries to build them. (A hand-run compose that forces a build would fail.)
- **Linux only** — matches the parent system's supported scope.

## What's in this repo

| File | Purpose |
| --- | --- |
| `start.sh` | The launcher. Prompts for secrets, computes per-project settings, boots the stack, attaches the TUI. |
| `docker-compose.yml` | Topology (networks, volumes, services). A near-copy of the maintainer repo's — see [`SYNC.md`](SYNC.md) for the deltas that must stay mirrored. |
| `docker-compose.user-layer.yml` | Optional overlay bind-mounting your personal config layer (see *Adding your own agents/skills*). |
| `docker-compose.user-packages.yml` | Optional overlay (with `Dockerfile.user-packages`) that bakes your `extra-packages.txt` into a local opencode layer at build time (see *Adding system packages*). |
| `docker-compose.podman.yml` | Optional overlay applied under rootless Podman (`keep-id` userns + `x-podman`); auto-detected by `start.sh`, or forced with `--podman`. |
| `extra-packages.txt.example` | Template for the per-developer `extra-packages.txt` (gitignored) list of apt and `pip:` packages to bake in. |
| `.env.example` | Template for the shared `.env` (secrets, identity, toggles). |
| `extra-allowlist.d/` | Bind-mounted (read-only) into Squid for local allowlist drop-ins (`*.conf`). |
| `SYNC.md` | The list of intentional deltas between this launcher's compose and the maintainer repo's. |

> **Maintainer note:** before first run, replace the
> `CHANGEME.artifactory.example/opencode-workplace` placeholder for
> `IMAGE_REGISTRY` in `.env` with your real Artifactory path. `start.sh` warns
> if it still looks like a placeholder.
