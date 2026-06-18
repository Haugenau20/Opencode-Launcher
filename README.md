# OpenCode Launcher

A thin **launcher** for a pre-built, locked-down OpenCode environment that runs
against your own repo. It pulls two images from Artifactory and wires them
together with `docker compose`: the agent runs sandboxed behind a Squid proxy
whose egress allowlist limits it to the LLM endpoint, Bitbucket, Jira, and GitLab.
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

## Install

### Quick install (one-liner)

```bash
curl -fsSL https://CHANGEME.internal.example/opencode-launcher/install.sh | bash
```

> **Replace `https://CHANGEME.internal.example/opencode-launcher/install.sh`**
> with the real raw-file URL for `install.sh` on your internal git host (e.g.
> a Bitbucket/GitHub raw-content URL). The placeholder above is intentionally
> not a real, reachable address.

This fetches and runs [`install.sh`](install.sh), which clones this launcher
repo (if it isn't already checked out next to the script), checks for Docker
and the `docker compose` v2 plugin, and prints the exact `cd ... && ./start.sh
<your-repo>` command to run next. It is safe to run more than once — it never
overwrites an existing clone or an existing `.env`.

### Manual equivalent

```bash
git clone <this-launcher-repo>
cd opencode-launcher
./start.sh ~/code/your-repo
```

Either way, only the very first run does anything different (see Quickstart
below) — `install.sh` is just a convenience wrapper around the same clone +
`./start.sh` flow, handy for colleagues who'd rather not hand-type the
prerequisite checks.

### Tab completion

Optional, but handy: [`completions/`](completions/) has bash and zsh
completion scripts for every `start.sh` flag (plus directory completion for
`<host-repo-path>`). See [`completions/README.md`](completions/README.md) for
install instructions.

## Quickstart

```bash
git clone <this-launcher-repo>
cd opencode-launcher
./start.sh ~/code/your-repo
```

On the **first run**, the script copies `.env.example` → `.env` and prompts for
your LLM endpoint/key and Artifactory path. From a real terminal with
`whiptail` or `dialog` installed, this is a small ncurses editor whose "Done"
refuses to finish until the required fields (LLM base URL, LLM key, image
registry) are filled in — unmet ones are marked `(REQUIRED)` in the menu;
press Ctrl+C any time to abort. Without a real terminal or either backend
(piped input, CI, or `OC_CONFIG_TUI=0`), it falls back to the plain-text
wizard. The service integrations are all optional (press Enter to skip, or
just leave them blank in the ncurses editor): Bitbucket (base URL + user/PAT),
Jira (base URL + PAT), and GitLab (base URL + user/PAT), plus git identity.
Each integration needs its own base URL — Bitbucket's is plain HTTP on the
internal instance, while Jira's and GitLab's are HTTPS, and GitLab's base URL
is required for its MCP to start. It auto-fills `HOST_UID`/`HOST_GID`, then
pulls the images and boots the stack. Later runs reuse `.env`; to change a
secret, edit `.env`
(gitignored) and it applies next run.

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
| `--open`              | Once the web UI URL is known, open it in your default browser via `xdg-open`. Works alongside `--web`/`--persist`/`--detach`. Never fails the boot if `xdg-open` is missing (warns and continues). |
| `--doctor [<repo-path>]` | Run all environment checks (Docker, compose, registry auth, `.env` keys, ports, disk space) and print one pasteable PASS/WARN/FAIL report. No pull, no TUI attach. |
| `--status [<repo-path>]` | Report on running launcher stacks. With a repo path: that project's up/down state, web UI URL, and resume command. Without one: every running `opencode-*` stack. Read-only — no secrets needed. |
| `--down` (`--stop`) `<repo-path>` | Tear down a stack left running by `--persist`/`--detach`, the clean way (re-derives the same project `docker compose down` would use). Safe to run even if nothing is up. |
| `--logs <repo-path>`  | Tail (follow) the running stack's logs. Ctrl-C detaches without affecting the stack. No pull, no TUI attach, no LLM key required. Graceful no-op if nothing is running. |
| `--shell <repo-path>` | Drop into an interactive shell inside the running opencode container, as the `dev` user rooted at `/workspace` (falls back to `sh` if `bash` is unavailable). No pull, no LLM key required. Graceful no-op if the container isn't running. |
| `--reconfigure`       | Re-run the secrets setup wizard, pre-filled with your current `.env` values (Enter keeps each one). Existing secrets are masked, never echoed. From a real terminal with `whiptail` or `dialog` installed, shows a small ncurses menu editor; from a real terminal without either, shows a dashboard + plain-text menu instead; piped input (scripts/CI) gets the full linear walk. Set `OC_CONFIG_TUI=0` to force the plain-text path even when whiptail/dialog is installed. Changes apply next run. |
| `--config`            | Print a read-only dashboard of every `.env` setting, grouped by section, then exit. No docker, no pull, no LLM key required. Secret values are never printed (set/unset only). Takes no repo path. |
| `--show-allowlist [<repo-path>]` | Print exactly what outbound egress the agent is permitted. Read-only — no pull, no TUI attach, no LLM key required. See [Egress allowlist](#egress-allowlist) below. |

```bash
./start.sh --persist ~/code/your-repo    # stay up after you exit
./start.sh --detach  ~/code/your-repo    # headless, never attach the TUI
./start.sh --open    ~/code/your-repo    # also open the web UI in your browser
./start.sh --status                      # list every running stack
./start.sh --status ~/code/your-repo     # status for one project
./start.sh --down    ~/code/your-repo    # tear that stack down
./start.sh --logs    ~/code/your-repo    # tail the running stack's logs
./start.sh --shell   ~/code/your-repo    # shell into the running container
./start.sh --reconfigure                 # edit your secrets interactively
./start.sh --config                      # see your current .env settings at a glance
./start.sh --show-allowlist              # see exactly what egress is permitted
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

## Egress allowlist

The agent runs sandboxed behind a Squid proxy. The **authoritative allowlist**
(LLM endpoint, Bitbucket, Jira, GitLab) is enforced **inside the squid image**,
not in this repo — this launcher only knows about, and can only report on, the
bits it itself configures:

- the LLM host derived from `LLM_API_BASE` in `.env`,
- whether Bitbucket, Jira, and GitLab credentials are configured (the service
  hostnames themselves are baked into the squid image, not visible from here),
  and
- any local extensions you've dropped into `extra-allowlist.d/*.conf` (see
  [Extending the egress allowlist](docs/CUSTOMIZING.md#extending-the-egress-allowlist)).

Each integration is an MCP server the image auto-enables purely from the
credentials you put in `.env` (and its `DISABLE_*_MCP` switch). **Bitbucket** and
**GitLab** provide both a read-only MCP and a git remote (Bitbucket over plain
HTTP on the internal instance; GitLab over HTTPS, with REST auth via the
`PRIVATE-TOKEN` header and git Basic auth from `GITLAB_USER:GITLAB_PAT`).
**Jira** is REST-only, authenticated with its PAT as a Bearer token. Every
service needs its own `*_BASE_URL`; GitLab's is required for its MCP to start.

Run `./start.sh --show-allowlist` any time for the full, honest picture —
read-only, no image pull, no TUI attach, no LLM key required, and it **never
prints secret values**. Every normal boot also prints a one-line summary of
the same information as a standing reminder; the full detail lives in
`--show-allowlist`.

```bash
./start.sh --show-allowlist                  # full report
./start.sh --show-allowlist ~/code/your-repo # repo path accepted for symmetry
```

## Image digest & reproducibility

Images are pulled by **tag** (`IMAGE_TAG`, default `latest`), and a tag can
move. After every boot, `start.sh` resolves and prints the actual **sha256
digest** of the image now running (`docker image inspect ... RepoDigests`) —
a tamper-check/reproducibility anchor that a tag alone doesn't give you.
`./start.sh --status <repo-path>` also shows the digest last seen for that
project. If the digest changes between runs (the moving `latest` tag pointed
somewhere new, or someone re-pushed a pinned tag), the next boot prints a
short `image updated: <short-digest>` nudge — silent otherwise.

**To pin by digest for full reproducibility**, set `IMAGE_TAG` in `.env` to
the digest itself (printed by the boot-time `image:` line above) instead of a
tag name:

```dotenv
IMAGE_TAG=@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567
```

A `IMAGE_TAG` starting with `sha256:` or `@sha256:` is joined with `@` instead
of `:`, producing Docker's own digest-reference syntax
(`registry/image@sha256:...`). This guarantees byte-identical pulls — the
moving-tag concern above no longer applies once pinned this way.

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
- **Need to see what the agent/services are logging?** `./start.sh --logs
  ~/code/your-repo` tails (follows) the stack's compose logs; Ctrl-C detaches
  without affecting the stack.
- **Need to poke around inside the container?** `./start.sh --shell
  ~/code/your-repo` drops you into an interactive shell as the `dev` user
  rooted at `/workspace` — no need to remember the raw `docker exec`
  incantation.
- **Changed your mind about a secret or plugin?** `./start.sh --reconfigure`
  re-runs the setup wizard pre-filled with your current `.env` values — Enter
  keeps each one. If `whiptail` or `dialog` is installed and you're at a real
  terminal, this opens a small ncurses menu instead of the plain-text
  prompts; set `OC_CONFIG_TUI=0` to opt back into the plain-text flow.
- **Linux only** — matches the parent system's supported scope.
