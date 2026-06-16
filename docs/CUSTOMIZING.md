# Customizing the environment

Two self-service ways to tailor the environment — without entering the container
or bloating the shared base image for everyone else: layer in your own OpenCode
config (agents/skills/commands), and bake in extra system packages.

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
