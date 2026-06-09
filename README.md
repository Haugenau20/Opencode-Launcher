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
your secrets (LLM key, Bitbucket user/PAT, git identity) plus the Artifactory
path. It writes them into `.env` and auto-fills your `HOST_UID`/`HOST_GID`.
Then it pulls the images and boots the stack.

When it finishes it prints a URL — open it in your browser:

```
web UI: http://localhost:4096
```

Later runs reuse `.env`, so there's no prompt.

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
> and warns you — that project still works fully via the **TUI**, it just can't
> use the browser UI on the alternate port:
>
> ```bash
> ./start.sh --tui ~/code/another-service
> ```

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
./run_tests.sh
```

See [`tests/README.md`](tests/README.md) for what's covered and how to add more.

## Troubleshooting

- **`docker login` needed** — the most common first-time failure. If a pull
  fails with `unauthorized`/`denied`, run `docker login <registry-host>` and
  retry.
- **Not in the docker group** — if Docker says *permission denied*, run
  `sudo usermod -aG docker $USER && newgrp docker`.
- **Don't run `docker compose up` by hand** without the prod overlay. Always go
  through `start.sh`, which passes both `-f docker-compose.yml` **and**
  `-f docker-compose.prod.yml`. Without the overlay, compose tries to *build*
  the images (there are no Dockerfiles here) and fails.
- **Linux only** — matches the parent system's supported scope.

## What's in this repo

| File | Purpose |
| --- | --- |
| `start.sh` | The launcher. Prompts for secrets, computes per-project settings, boots the stack. |
| `docker-compose.yml` | Topology (networks, volumes, services). Copied verbatim from the parent repo. |
| `docker-compose.prod.yml` | Overlay that drops the `build:` blocks and points at the `:prod` images. **Always applied.** |
| `.env.example` | Template for the shared `.env` (secrets, identity, toggles). |
| `extra-allowlist.d/` | Bind-mounted into Squid for local allowlist drop-ins (`*.conf`). |

> **Maintainer note:** before first run, replace the
> `CHANGEME.artifactory.example/opencode-workplace` placeholder for
> `IMAGE_REGISTRY` in `.env` with your real Artifactory path. `start.sh` warns
> if it still looks like a placeholder.
