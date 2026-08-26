# Demo / onboarding pack

An interactive onboarding and demo experience for the OpenCode workplace,
shipped as a **user layer** so it loads on top of a stock released image —
**no image rebuild, no custom tag**.

```
demo/
  RUNSHEET.md                     the presenter's run-sheet (read this first)
  onboarding-layer/
    .gitignore                    keeps the entrypoint's generated config untracked
    agents/guide.md               `guide` — a mode: primary host agent (Tab-selectable)
    commands/demo-tour.md         `/demo-tour <1-7>` — presenter-paced, one stage per call
    commands/try-it.md            `/try-it` — the self-paced take-home
```

## Turning it on

One line in `.env`:

```dotenv
USER_LAYER_PATH=./demo/onboarding-layer
```

Then `./start.sh <repo>`. `start.sh` resolves the path, applies
`docker/docker-compose.user-layer.yml`, and bind-mounts the directory at
`/home/dev/.config/opencode` — so `guide`, `/demo-tour` and `/try-it` load
alongside everything baked into the image.

## Turning it off

Delete that line (or blank it) and re-run. Nothing else references `demo/`, so
with `USER_LAYER_PATH` unset these files are inert bytes on disk — the image,
the compose stack and the bundle are untouched. That is the whole reason this is
a user layer rather than a `DEMO_MODE=1` build flag: packing it away costs one
line, not a rebuild and a release.

## How it loads (mechanics)

The backbone entrypoint symlinks the baked-in bundle into
`~/.config/opencode/{agents,skills,commands}` at boot. When `USER_LAYER_PATH`
bind-mounts a host directory over that same path, the two coexist: bundle items
are linked in, and these user-layer files sit alongside them. A user-layer file
with the *same name* as a bundle item shadows it — these names don't collide
with anything shipped, so nothing is overridden.

Two consequences worth knowing:

- **The entrypoint writes into this directory.** Every boot it creates
  `agents/ skills/ commands/ mcp/ plugin/ themes/`, symlinks the bundle in, and
  drops a generated `opencode.json`, `disabled.yaml`, `tui.json` and plugin
  seeds — then chowns the tree to `HOST_UID`/`HOST_GID`. The `.gitignore` in
  `onboarding-layer/` tracks only `agents/`, `commands/` and `skills/` so the
  rest stays out of git. Expect the directory to look busy on disk after a run.
- **Do not add an `AGENTS.md` here.** A user-layer `AGENTS.md` shadows the
  bundle's house rules (skills-over-raw-tools, git conventions) — which are
  exactly what the demo is trying to show off. This pack deliberately ships none.

## Why the directory isn't called `user-layer`

`.gitignore` in this repo ignores `user-layer/` unanchored, so it matches at any
depth — even `demo/user-layer/` would be silently untracked. The name is
arbitrary (`USER_LAYER_PATH` is what points at it), so just avoid that token.

## `/demo-tour` is a command, not a skill

It reads like a skill, but it is a **command** on purpose. `/demo-tour 3` needs
explicit invocation with an argument, which is what `$ARGUMENTS` in a command
file gives you deterministically. Slash-invoking a *skill* in OpenCode has known
rough edges — the body gets injected raw while the skill tool stays exposed
([opencode#26185](https://github.com/anomalyco/opencode/issues/26185)), and
arguments can be dropped. On a projector, predictable beats lazy-loaded.

## Promoting it into the image later

If this earns its keep and you want it on for everyone without a user layer, the
files move to the backbone's `opencode/bundle/{agents,commands}/`. Note the gate
asymmetry before you plan that: bundled **skills** can be hidden behind a switch
today via a `.requires` file (`env=DEMO_MODE=1`, see
`docs/ADDING_SKILLS.md` in the backbone), but **agents and commands are flat
`.md` files and cannot carry one** — `opencode/entrypoint.sh` says so explicitly.
Gating these three would mean extending that mechanism first.
