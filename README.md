# OpenCode Launcher

A thin **launcher** for a pre-built, locked-down OpenCode environment that runs
against your own repo. It pulls two images from Artifactory and wires them
together with `docker compose`: the agent runs sandboxed behind a Squid proxy
whose egress allowlist limits it to the LLM endpoint, Bitbucket, and JIRA.
Everything locked down (agent bundle, policy, allowlist, CA) lives in the images;
this repo is just the glue.

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

On the **first run**, the script copies `.env.example` → `.env` and prompts for
your LLM endpoint/key and Artifactory path (Bitbucket user/PAT and git identity
are optional — press Enter to skip). It auto-fills `HOST_UID`/`HOST_GID`, then
pulls the images and boots the stack. Later runs reuse `.env`; to change a
secret, edit `.env` (gitignored) and it applies next run.

The stack comes up with the **OpenCode TUI attached**, rooted at `/workspace`
(your repo). **Exiting the TUI (or Ctrl-C) tears the stack down** — one command
in, one command out, nothing left running.

## Session & lifecycle flags

Flags that change the default attach-and-teardown behavior:

| Flag (aliases)        | What it does |
| --------------------- | --- |
| `--persist` (`--web`) | Keep the stack and its web UI running after you exit; resume your last session with the `opencode -c` command `start.sh` prints. |
| `--detach` (`--no-tui`) | Boot without attaching the TUI (CI, or web-UI-only). Also leaves the stack running. |
| `--continue` (`-c`)   | Resume your most recent session instead of a fresh one. Maps 1:1 to opencode's own `--continue`/`-c`. |
| `--doctor [<repo-path>]` | Run all environment checks (Docker, compose, registry auth, `.env` keys, ports, disk space) and print one pasteable PASS/WARN/FAIL report. No pull, no TUI attach. |
| `--status [<repo-path>]` | Report on running launcher stacks. With a repo path: that project's up/down state, web UI URL, and resume command. Without one: every running `opencode-*` stack. Read-only — no secrets needed. |
| `--down` (`--stop`) `<repo-path>` | Tear down a stack left running by `--persist`/`--detach`, the clean way (re-derives the same project `docker compose down` would use). Safe to run even if nothing is up. |
| `--reconfigure`       | Re-run the secrets setup wizard, pre-filled with your current `.env` values (Enter keeps each one). Existing secrets are masked, never echoed. Changes apply next run. |

```bash
./start.sh --persist ~/code/your-repo    # stay up after you exit
./start.sh --detach  ~/code/your-repo    # headless, never attach the TUI
./start.sh --status                      # list every running stack
./start.sh --status ~/code/your-repo     # status for one project
./start.sh --down    ~/code/your-repo    # tear that stack down
./start.sh --reconfigure                 # edit your secrets interactively
```

> `--continue` with no previous session is harmless: opencode prints a server
> error and starts a fresh one on your first prompt.

### Frontends: TUI (default) vs. web UI

The launcher also prints a web-UI URL (`http://localhost:4096`), but the **TUI is
the default and recommended** — the web/desktop UI has a known workspace-rooting
bug (see [Known limitations](#known-limitations)). The TUI is unaffected.

## Running more than one repo

One launcher clone handles many repos — just point `start.sh` at another path:

```bash
./start.sh ~/code/another-service
```

Each invocation derives its own project slug, port, and workspace mount from the
path (not stored in `.env`). Only one project can use the **browser UI** at a
time — see [Known limitations](#known-limitations).

## Known limitations

Both stem from the OpenCode build in the current image and will ease as newer
images ship.

- **Web/desktop UI roots the agent at `/`, not `/workspace`.** It can read across
  the container, but writes to your repo fail unless you give full paths.
  Confirmed upstream bug
  ([anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
  [#14460](https://github.com/anomalyco/opencode/issues/14460)), not a launcher
  defect. **Workaround:** make your first web-UI prompt `cd /workspace`. The
  **TUI is unaffected.**
- **Only one browser UI at a time (port 4096).** The web/desktop UI hardcodes
  port **4096**. If it's taken, `start.sh` uses the next free port and warns you
  — that project still works fully via the **TUI**, just not the browser UI.

## Customizing the environment

Layer in your own OpenCode agents/skills/commands, bake extra system packages
into the image, or extend the egress allowlist — all self-service, without
entering the container or rebuilding the shared base. See
[`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md).

## Choosing a model

The endpoint serves several models, each with a different sweet spot — some
suit long autonomous coding, others heavy reasoning, large-context work, or fast
well-scoped tasks. See [`docs/MODELS.md`](docs/MODELS.md) for a benchmarked
comparison and a "when to reach for which" guide.

## Plugins

The image ships three OpenCode plugins, **baked in but OFF by default** (opt-in).
They load offline from files inside the image, so enabling them adds **no network
access**:

| Name | What it does | Upstream |
| --- | --- | --- |
| `superpowers` | Skills library: brainstorming, writing-plans, systematic-debugging, TDD, code review, etc. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens (no user-facing tool). | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |

> **WARNING! `opencode-workspace` is incompatible with some models.** The extra
> tools and system prompt it injects are rejected by certain upstreams, so every
> prompt then fails with
> `AI_APICallError: Failed to communicate with the upstream service`. See
> [`docs/MODELS.md`](docs/MODELS.md) for which models are affected, and leave this
> plugin disabled when using one of them.

Turn them on with a single host-side variable in `.env` — a space- or
comma-separated list:

```dotenv
ENABLED_PLUGINS=superpowers dcp
```

The **first run also offers to enable them** (optional, default none). Plugins
load at startup, so a change needs a restart — and re-running `./start.sh` IS the
restart. Inside the TUI, **`/plugins`** lists the catalog and each plugin's state.

> **Pin `IMAGE_TAG` for reproducible plugins.** The plugin set and its versions
> move with the image, so pin `IMAGE_TAG` in `.env` to an explicit version (e.g.
> `0.0.2`) rather than the moving `latest` if you rely on a specific plugin set.

## Updating to a new image

Images are pulled fresh on every `./start.sh`:

- `IMAGE_TAG=latest` (default) — always the newest upload, so you auto-update.
- Pin a version — set `IMAGE_TAG` in `.env` to e.g. `0.0.2`.
- `git pull` this repo occasionally to pick up topology changes.

## Troubleshooting

- **Run `./start.sh --doctor` first.** It checks Docker (on PATH, daemon
  reachable, compose v2 plugin), the registry (auth/login state), your `.env`
  (required keys set, optional keys listed as set/unset), and ports — then
  prints one pasteable PASS/WARN/FAIL report. Optionally pass a repo path to
  also check that project's derived port: `./start.sh --doctor ~/code/your-repo`.
  It never prints secret values, exits non-zero only on a FAIL, and never pulls
  an image or attaches the TUI — paste its output when asking for help instead
  of describing the error by hand.
- **`docker login` needed** — the most common first-time failure. If a pull
  fails with `unauthorized`/`denied`, run `docker login <registry-host>` and
  retry. `--doctor` surfaces this with the exact command to run.
- **Not in the docker group** — if Docker says *permission denied*, run
  `sudo usermod -aG docker $USER && newgrp docker`.
- **Don't run `docker compose up`/`down` by hand.** Always go through
  `start.sh` — it wires up the per-project env file and project name and pulls
  the images first. (The base `docker-compose.yml` carries `build:` blocks for
  the maintainer repo, but the images are pulled, not built here; a hand-run
  `up` that forces a build would fail.) To tear down a stack left running by
  `--persist`/`--detach`, use `./start.sh --down ~/code/your-repo` instead — it
  re-derives the same project so the right stack comes down.
- **Forgot what's running, or what port it's on?** `./start.sh --status` lists
  every running stack; `./start.sh --status ~/code/your-repo` reports one
  project's web UI URL and resume command.
- **Changed your mind about a secret or plugin?** `./start.sh --reconfigure`
  re-runs the setup wizard pre-filled with your current `.env` values — Enter
  keeps each one.
- **Linux only** — matches the parent system's supported scope.
