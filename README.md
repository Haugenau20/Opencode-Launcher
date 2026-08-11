# OpenCode Launcher

A thin **launcher** for a pre-built, locked-down OpenCode environment that runs
against your own repo. It pulls two images from Artifactory and wires them
together with `docker compose`: the agent runs sandboxed behind a Squid proxy
whose egress allowlist limits it to the LLM endpoint, Bitbucket, Jira, GitLab,
JFrog, Confluence, and M-Files. Everything locked down (agent bundle, policy,
allowlist, CA) lives in the images; this repo is just the glue.

> **What's new:** see the [CHANGELOG](CHANGELOG.md) — it tracks both launcher
> releases and the OpenCode Workplace image versions you can run (each with an
> "Action required" line for picking it up).

## Contents

- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quickstart](#quickstart)
- [Session & lifecycle flags](#session--lifecycle-flags)
- [Extra folders for context (--also)](#extra-folders-for-context---also)
- [Non-interactive one-shot runs (--exec)](#non-interactive-one-shot-runs---exec)
- [Running more than one repo](#running-more-than-one-repo)
  - [Per-project credentials](#per-project-credentials)
- [Known limitations](#known-limitations)
- [Egress allowlist](#egress-allowlist)
- [Image digest & reproducibility](#image-digest--reproducibility)
- [Customizing the environment](#customizing-the-environment)
- [Choosing a model](#choosing-a-model)
- [Plugins](#plugins)
- [Updating to a new image](#updating-to-a-new-image)
- [Troubleshooting](#troubleshooting)

## Repository layout

Almost everything you need is reachable from two scripts in the root; the rest is
grouped into folders so a fresh clone isn't overwhelming.

```
.
├── start.sh              # main entry point — run the launcher (see flags below)
├── install.sh            # one-time bootstrap / prerequisite check
├── .env.example          # template copied to .env on first run (your secrets)
├── extra-packages.txt.example  # template for the optional system-package layer
├── docker/               # the docker compose stack (overlays + the package Dockerfile)
├── lib/                  # start.sh's logic, split into sourced modules (core, config, doctor, …)
├── completions/          # bash/zsh tab-completion scripts
├── docs/                 # extra docs: customizing, models, compose-sync notes
├── tests/                # bats test suite
└── extra-allowlist.d/    # drop *.conf here to extend the Squid egress allowlist
```

You only ever invoke `./start.sh` and `./install.sh` directly — they reach into
`docker/` and `lib/` for you.

## Prerequisites

- **Linux** with **Docker** (Engine + the `docker compose` v2 plugin).
- Your user is in the **`docker` group**
  (`sudo usermod -aG docker $USER && newgrp docker`).
- **Access to Artifactory** for the images. If a pull fails with an auth error,
  run: `docker login <registry-host>`.
- **Podman** (rootless, with the `podman-docker` shim) works too — `start.sh`
  auto-detects it and applies a `keep-id` userns overlay so bind-mount ownership
  stays correct. Force it with `--podman` if detection misses.
- **A git credential helper** (or an SSH remote) for this launcher's own
  checkout. Every boot runs `git fetch` on it to check for updates, so an HTTPS
  remote with nothing to authenticate for git prompts for a username/password
  and looks like a hang. `OC_SKIP_UPDATE_CHECK=1` skips the check instead.

## Install

```bash
curl -fsSL https://CHANGEME.internal.example/opencode-launcher/install.sh | bash
```

> Replace the URL with the real raw-file URL for `install.sh` on your internal
> git host (e.g. a Bitbucket/GitHub raw-content URL). The placeholder above is
> intentionally not reachable.

[`install.sh`](install.sh) clones this launcher (if it isn't already checked out
next to the script), checks for Docker and the `docker compose` v2 plugin, and
prints the exact `cd … && ./start.sh <your-repo>` command to run next. It's safe
to re-run — it never overwrites an existing clone or `.env`. Prefer to do it by
hand? It's just a clone plus `./start.sh` — see [Quickstart](#quickstart).

### Tab completion

Optional: [`completions/`](completions/) has bash and zsh completions for every
`start.sh` flag (plus directory completion for `<host-repo-path>`). Install
instructions in [`completions/README.md`](completions/README.md).

## Quickstart

```bash
git clone <this-launcher-repo>
cd opencode-launcher
./start.sh ~/code/your-repo
```

On the **first run**, `start.sh` copies `.env.example` → `.env` and prompts for
the only required fields — your LLM endpoint/key and Artifactory path. At a real
terminal it's a small ncurses editor (`whiptail`/`dialog`); piped input or CI
gets a plain-text wizard. The service integrations (Bitbucket, Jira, GitLab,
JFrog, Confluence, M-Files, git identity) are optional — press Enter to skip.
M-Files needs a minted token rather than a pasted one — the prompt offers to
mint it for you (see
[Service integrations](docs/CUSTOMIZING.md#m-files-authentication-token)). It
then fills in `HOST_UID`/`HOST_GID`, pulls the images, and boots. Later runs reuse
`.env` (edit it by hand any time; it's gitignored).

The stack comes up with the **OpenCode TUI attached**, rooted at `/workspace`
(your repo). **Exiting the TUI (or Ctrl-C) tears the stack down** — one command
in, one command out, nothing left running.

## Session & lifecycle flags

The default is "attach the TUI, then tear down on exit." These change that:

| Flag (aliases) | What it does |
| --- | --- |
| `--persist` (`--web`) | Keep the stack and its web UI running after you exit; resume later with `./start.sh --continue --persist <repo>`. |
| `--detach` (`--no-tui`) | Boot without attaching the TUI (CI, or web-UI-only); leaves the stack running. |
| `--continue` (`-c`) | Resume your most recent session instead of a fresh one (opencode's own `-c`). |
| `--open` | Open the web UI URL in your browser via `xdg-open`. Also opens the opencode-pty viewer URL when that plugin is enabled. Non-fatal if `xdg-open` is missing. |
| `--also <path>[:rw]` | Mount an extra host folder for context, read-only by default — see [Extra folders for context](#extra-folders-for-context---also). |
| `--exec "<prompt>"` | Boot, run one prompt non-interactively, tear down, exit with its rc — see [Non-interactive one-shot runs](#non-interactive-one-shot-runs---exec). |
| `--doctor [<repo>]` | Print a PASS/WARN/FAIL environment report (Docker, compose, registry auth, `.env`, ports, disk, launcher update, image-tag pin). |
| `--status [<repo>]` | Report running stacks — one project's state/URL/resume command, or every `opencode-*` stack. |
| `--down`/`--stop` `<repo>` | Tear down a repo's stack the clean way (re-derives the same project `docker compose down` would). |
| `--logs <repo>` | Follow the running stack's logs (Ctrl-C detaches). |
| `--shell <repo>` | Open a shell in the running container as the `dev` user at `/workspace` (falls back to `sh`). |
| `--reconfigure` | Re-run the secrets wizard, pre-filled with your current `.env` (Enter keeps each value). |
| `--config` | Read-only dashboard of every `.env` setting (secrets shown as set/unset only). |
| `--show-allowlist [<repo>]` | Print what egress the agent is allowed — see [Egress allowlist](#egress-allowlist). |
| `--mfiles-token` | Mint an M-Files auth token from your vault credentials and write it straight into `.env` — see [Service integrations](docs/CUSTOMIZING.md#m-files-authentication-token). |

The inspect/manage commands (`--doctor`, `--status`, `--down`, `--logs`,
`--shell`, `--config`, `--show-allowlist`, `--mfiles-token`) are read-only or
teardown-only (`--mfiles-token` only ever touches its own two `.env` keys): they
never pull an image, attach the TUI, or need your LLM key, and they no-op
gracefully when nothing is running. Run `./start.sh --help` for the full
per-flag detail.

```bash
./start.sh --persist ~/code/your-repo    # stay up after you exit
./start.sh --detach  ~/code/your-repo    # headless, never attach the TUI
./start.sh --open    ~/code/your-repo    # also open the web UI in your browser
./start.sh --status                      # list every running stack
./start.sh --down    ~/code/your-repo    # tear that stack down
./start.sh --logs    ~/code/your-repo    # tail the running stack's logs
./start.sh --shell   ~/code/your-repo    # shell into the running container
./start.sh --reconfigure                 # edit your secrets interactively
./start.sh --show-allowlist              # see exactly what egress is permitted
```

### TUI (default) vs. web UI

`start.sh` also prints a web-UI URL (e.g. `http://localhost:4096`). The **TUI is
the default** — it's the simplest frontend (zero setup, always rooted at
`/workspace`). The web and desktop UIs are fully usable too; a new session just
needs a one-step working-directory action (see
[Known limitations](#known-limitations)).

## Extra folders for context (--also)

**Read-only by default.** `--also <path>` bind-mounts an extra host folder into
the container so the agent can read it for context — a library repo, a shared
docs tree, whatever it needs to see but isn't editing. Append `:rw` to make one
mount writable. Repeatable:

```bash
./start.sh --also ~/code/libA --also ~/code/libB:rw ~/code/mainrepo
```

Each mount lands at `/workspace-extra/<name>` (its basename; `-2`/`-3`/… if two
paths share one), alongside your main repo at `/workspace`. Boot prints one line
per mount:

```
==> also: /home/you/code/libA -> /workspace-extra/liba (read-only)
==> also: /home/you/code/libB -> /workspace-extra/libb (read-write)
```

A `--also` path must be an existing directory other than the main repo, and
can't contain `:` (beyond the trailing `:rw`).

**The agent is told these folders exist.** opencode's file tools are rooted at
`/workspace`, so it wouldn't find the siblings on its own; the launcher points
the image at a breadcrumb listing them (via `OPENCODE_EXTRA_INSTRUCTIONS`), so
"look at the libA folder" just works. Needs an image new enough to honor that
var — on an older one the folders are still mounted, just not advertised.

`--down`/`--logs`/`--shell` reuse the mounts automatically, and
`./start.sh --status <repo>` lists what a stack was last booted with.

## Non-interactive one-shot runs (--exec)

For scripting or CI, `--exec "<prompt>"` boots the stack, runs `<prompt>`
through `opencode run` inside the container with no TUI attached, tears the
stack down again, and exits with that command's own exit code:

```bash
answer="$(./start.sh --exec "summarize the TODOs in this repo" ~/code/your-repo)"
echo "opencode run exited $?"
printf '%s\n' "$answer"
```

`<host-repo-path>` is optional. Omit it to fire a one-shot prompt with an empty
`/workspace` — the container gets no local code, but it still boots and answers,
which is handy for a quick throwaway question against the sandboxed agent:

```bash
answer="$(./start.sh --exec "explain the CAP theorem in two sentences")"
```

A one-shot run only needs the agent, so `--exec` boots a **minimal stack** —
just the `opencode` container and its `squid` egress proxy, skipping the web-UI
publisher for a faster boot.

- `--continue` resumes your most recent session (opencode's own `-c`).
- `--persist` skips the teardown and boots the full stack (web UI included),
  leaving a resumable environment running.
- `--also` works as it does on a normal run.
- Conflicts with `--detach` — both are non-interactive.

**On success `--exec` prints exactly the model's answer**, nothing else — all
launcher and opencode chatter (boot progress, teardown, the harmless
`No .git found at /workspace` notice) is buffered and dropped, so you get a clean
answer with no `2>/dev/null`. **On failure** (a boot error or a non-zero
`opencode run`) that buffer is replayed to stderr instead, and the exit code is
always `opencode run`'s own — so it never fails silently.

## Running more than one repo

One launcher clone handles many repos — just point `start.sh` at another path:

```bash
./start.sh ~/code/another-service
```

Each invocation derives its own project slug, port, and workspace mount from the
path (nothing stored in `.env`). Each project gets its own web UI on its own port
(the browser UI derives its backend from the page origin, so any port works) —
they don't collide. If `opencode-pty` is enabled, its viewer port travels with
the base port (base `4096` -> viewer `14096`, base `4097` -> viewer `14097`,
etc.) — the two ranges stay disjoint, so multiple instances' viewers don't
collide either.

### Per-project credentials

By default every project shares the credentials in `.env`. To give one project
its own, create `.envs/<slug>.overrides.env`:

```
# .envs/myservice.overrides.env
GITLAB_PAT=a-token-scoped-to-just-this-project
CONFLUENCE_PAT=
```

That file is layered over the shared `.env` on every boot — last value wins — so
the `GITLAB_PAT` above applies to this project only, while every other setting
is still inherited. Projects without such a file are unaffected.

The blank `CONFLUENCE_PAT=` is not a no-op. Each MCP server turns itself on only
when its credentials are present, so blanking one keeps that server out of this
project's stack entirely — absent, not disabled — while your other projects keep
theirs.

The slug is the one `start.sh` prints on boot (derived from the repo directory
name). Edit **only** the `.overrides.env` file: the `.envs/<slug>.env` beside it
is regenerated on every boot and anything written there is overwritten.
`PROJECT_SLUG`, `OPENCODE_PORT` and `REPO_PATH` are the launcher's own and win
over the overrides file — a stale hand-written port would otherwise leave the
stack unreachable at the port it just told you to open.

## Known limitations

One minor rough edge remains in the OpenCode build in the current image; it will
ease as newer images ship.

- **In the web/desktop UI, a new session defaults its working directory to `/`,
  not `/workspace`.** This is just the upstream default
  ([anomalyco/opencode#14445](https://github.com/anomalyco/opencode/issues/14445)),
  not a launcher defect. **One-step fix:** in the web UI click **New session** and,
  when prompted for the working directory, type `/workspace` — everything in that
  session then runs inside your repo. The **TUI** needs no such step (it's always
  rooted at `/workspace`).

## Egress allowlist

The agent runs sandboxed behind a Squid proxy. The **authoritative allowlist**
(LLM endpoint, Bitbucket, Jira, GitLab, JFrog, Confluence, M-Files) is enforced
**inside the squid image**, not in this repo — so the launcher only knows about,
and can report on, the bits it configures:

- the LLM host from `LLM_API_BASE`,
- whether Bitbucket/Jira/GitLab/JFrog/Confluence/M-Files credentials are set (their
  hostnames are baked into the image, not visible here), and
- any local `extra-allowlist.d/*.conf` extensions (see
  [Extending the egress allowlist](docs/CUSTOMIZING.md#extending-the-egress-allowlist)).

`./start.sh --show-allowlist` prints the full, honest picture any time — never
secret values — and every boot prints a one-line summary of the same. For how
each integration authenticates, see
[Service integrations](docs/CUSTOMIZING.md#service-integrations).

## Image digest & reproducibility

Images are pulled by **tag** (`IMAGE_TAG`, default `latest`), and a tag can move.
After every boot `start.sh` prints the actual **sha256 digest** now running — a
tamper-check/reproducibility anchor a tag alone can't give you — and
`./start.sh --status <repo>` shows the digest last seen for that project. If it
changes between runs, the next boot prints a short `image updated: <short-digest>`
nudge (silent otherwise).

**To pin for full reproducibility**, set `IMAGE_TAG` to the digest itself
instead of a tag name:

```dotenv
IMAGE_TAG=@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567
```

A value starting with `sha256:` or `@sha256:` is joined with `@` (Docker's
digest-reference syntax, `registry/image@sha256:…`), guaranteeing byte-identical
pulls — the moving-tag concern no longer applies once pinned this way.

**Newer images self-describe.** A newer image also carries its own version, a
changelog, and a manifest of the env keys it reads. When the digest changes,
`start.sh` prints the new version and its changelog section, and warns if the
image reads an env key this launcher doesn't know (time to `git pull`). Older
images just get the plain `image updated:` nudge. `--doctor` checks the same
manifest independently, so you can spot launcher/image drift any time.

## Customizing the environment

Layer in your own OpenCode agents/skills/commands, bake extra system packages
into the image, extend the egress allowlist, or configure the service
integrations — all self-service, without entering the container or rebuilding
the shared base. See [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md).

## Choosing a model

The endpoint serves several models, each with a different sweet spot — some suit
long autonomous coding, others heavy reasoning, large-context work, or fast
well-scoped tasks. See [`docs/MODELS.md`](docs/MODELS.md) for a benchmarked
comparison and a "when to reach for which" guide.

## Plugins

The image ships four OpenCode plugins, **baked in but OFF by default** (opt-in).
They load offline from files inside the image, so enabling them adds **no network
access**:

| Name | What it does | Upstream |
| --- | --- | --- |
| `superpowers` | Skills library: brainstorming, writing-plans, systematic-debugging, TDD, code review, etc. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens (no user-facing tool). | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |
| `opencode-pty` | Web viewer onto the TUI's own terminal. Once enabled, run `/pty-open-background-spy` inside the TUI to start its server, then open `http://localhost:1<port>` (e.g. port `4096` -> `14096`; `start.sh`/`--status` print the exact URL). | (bundled with the image) |

> **WARNING — `opencode-workspace` is incompatible with some models.** The extra
> tools and system prompt it injects are rejected by certain upstreams, so every
> prompt then fails with
> `AI_APICallError: Failed to communicate with the upstream service`. See
> [`docs/MODELS.md`](docs/MODELS.md) for which models are affected, and leave it
> disabled when using one of them.

Enable them with one variable in `.env` — a space- or comma-separated list:

```dotenv
ENABLED_PLUGINS=superpowers dcp
```

The first run also offers to enable them (optional, default none). Plugins load
at startup, so a change needs a restart — and re-running `./start.sh` IS the
restart. Inside the TUI, **`/plugins`** lists the catalog and each plugin's state.

> **Pin `IMAGE_TAG` for reproducible plugins** — the plugin set and its versions
> move with the image, so pin an explicit version (e.g. `0.0.2`) rather than the
> moving `latest` if you rely on a specific set.

## Updating to a new image

Images are pulled fresh on every `./start.sh`:

- `IMAGE_TAG=latest` (default) — always the newest upload, so you auto-update.
- Pin a version — set `IMAGE_TAG` in `.env` to e.g. `0.0.2`.
- `git pull` this repo occasionally to pick up topology changes.

**The launcher gates on being behind, too.** Because only the latest launcher
running the latest image is a tested pairing (see the changelog's
*Compatibility* note), every boot does a best-effort check of whether this
checkout is behind its git upstream **and** whether `IMAGE_TAG` is pinned to
something other than `latest`. When either is true:

- **Interactive boot (a real terminal):** you're prompted —
  `bring everything up to date and restart? [Y/n]`. Accept and the launcher
  fast-forwards itself (`git pull --ff-only`), flips a pinned `IMAGE_TAG` back to
  `latest`, and **restarts into the newest** so you never run a stale
  launcher/image combination. Decline and it boots what you have.
  - **After a launcher upgrade, it also offers to set any *new* config.** If the
    version you upgraded to added keys to `.env.example` that your `.env` doesn't
    have yet, the restarted run lists exactly those new keys and offers to set
    them right there (`set them now? [Y/n]`), one prompt each — or skip and run
    `./start.sh --reconfigure` later. This is computed from the `.env.example`
    diff across the exact versions you moved between, so it's always just what's
    genuinely new since your last version.
- **Headless/CI boot (`--detach`, `--exec`, or no terminal):** no prompt — it
  just prints a nudge (`launcher update available: …` / `image pinned to …`)
  and boots, exactly as before.

`--doctor` still reports the launcher-behind count. Set
`OC_SKIP_UPDATE_CHECK=1` to skip the whole check (e.g. in CI, or for a
deliberate pin you don't want to be asked about).

## Troubleshooting

- **Start with `./start.sh --doctor`.** It checks Docker (PATH, daemon, compose
  v2), the registry login state, and your `.env` (required/optional keys, plus
  any new keys in `.env.example` you haven't picked up), then prints one
  pasteable PASS/WARN/FAIL report — paste that when asking for help. Add a repo
  path to also validate it. It never prints secrets, pulls an image, or attaches
  the TUI.
- **`unauthorized`/`denied` on pull** — the most common first-time failure: run
  `docker login <registry-host>` and retry (`--doctor` prints the exact command).
- **`permission denied` from Docker** — you're not in the docker group:
  `sudo usermod -aG docker $USER && newgrp docker`.
- **Don't run `docker compose up`/`down` by hand** — always go through
  `start.sh`, which wires up the per-project env file and project name and points
  compose at `docker/` with `--project-directory`. The stack is pull-only
  (everything comes from Artifactory; only the opt-in system-package layer
  builds). To tear a stack down, use `./start.sh --down <repo>`.
- **Lost track of what's running?** `./start.sh --status` (all stacks) or
  `--status <repo>` (one); `--logs <repo>` follows logs, `--shell <repo>` drops
  you inside the container.
- **Prompted to upgrade / `launcher update available: ...` on every boot?** The
  boot gate asks (interactively) or nudges (headless) whenever the launcher is
  behind its upstream or `IMAGE_TAG` is pinned off `latest` — see
  [Updating to a new image](#updating-to-a-new-image). To stop being asked
  (e.g. in CI, or for a deliberate pin), set `OC_SKIP_UPDATE_CHECK=1`. It's
  best-effort and silent on failure, so this is about noise, not an error.
- **Linux only** — matches the parent system's supported scope.
