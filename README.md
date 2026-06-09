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
rooted at `/workspace` (your repo). Exit the TUI (or Ctrl-C) and the stack keeps
running in the background — re-attach any time with the command it prints, or
boot headless with `--detach` (see below).

Later runs reuse `.env`, so there's no prompt.

### Frontends: TUI (default) vs. web UI

The launcher prints a web-UI URL too (`http://localhost:4096`), but the **TUI is
the default and the recommended frontend right now**:

> ⚠️ **Web/desktop UI caveat (OpenCode 1.16.2).** On the OpenCode version baked
> into the current image, the **web and desktop UIs root the agent at `/`
> instead of `/workspace`** — so it can read across the container but writes to
> your repo fail unless you name full paths. This is a confirmed upstream bug
> ([anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
> [#14460](https://github.com/anomalyco/opencode/issues/14460)), not a launcher
> defect, and `opencode serve` on 1.16.2 has no `--cwd` to override it.
>
> The web UI stays available and is still useful — just make your **first prompt
> `cd /workspace`** so the agent works inside your repo. The **TUI is
> unaffected** (the launcher attaches it with `-w /workspace`).
>
> This will be reverted to "all frontends equal" once a newer image ships
> `opencode serve --cwd /workspace`.

**Headless / scripted runs.** To boot the stack without attaching the TUI (CI,
or when you only want the web UI), pass `--detach` (alias `--no-tui`):

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

## Updating to a new image

Images are pulled fresh from Artifactory on every `./start.sh` (the `:prod`
tag), so you generally get updates automatically. Occasionally `git pull` this
launcher repo to pick up topology changes.

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
  wires up the per-project env file, project name, and (with `--prod`) the
  `docker-compose.prod.yml` overlay. Note the base `docker-compose.yml` carries
  `build:` blocks for the maintainer repo's benefit, but there are no Dockerfiles
  here, so a hand-run compose that tries to build will fail — `--prod` (which
  `start.sh` applies for you) drops those blocks and pulls the `:prod` images.
- **Linux only** — matches the parent system's supported scope.

## What's in this repo

| File | Purpose |
| --- | --- |
| `start.sh` | The launcher. Prompts for secrets, computes per-project settings, boots the stack, attaches the TUI. |
| `docker-compose.yml` | Topology (networks, volumes, services). A near-copy of the maintainer repo's — see [`SYNC.md`](SYNC.md) for the deltas that must stay mirrored. |
| `docker-compose.prod.yml` | Overlay that drops the `build:` blocks and pins all three services to the `:prod` images. Applied with `--prod`. |
| `docker-compose.user-layer.yml` | Optional overlay bind-mounting your personal config layer (see *Adding your own agents/skills*). |
| `.env.example` | Template for the shared `.env` (secrets, identity, toggles). |
| `extra-allowlist.d/` | Bind-mounted (read-only) into Squid for local allowlist drop-ins (`*.conf`). |
| `SYNC.md` | The list of intentional deltas between this launcher's compose and the maintainer repo's. |

> **Maintainer note:** before first run, replace the
> `CHANGEME.artifactory.example/opencode-workplace` placeholder for
> `IMAGE_REGISTRY` in `.env` with your real Artifactory path. `start.sh` warns
> if it still looks like a placeholder.
