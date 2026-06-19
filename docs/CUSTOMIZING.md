# Customizing the environment

Self-service ways to tailor the environment — without entering the container or
bloating the shared base image for everyone else: layer in your own OpenCode
config (agents/skills/commands), bake in extra system packages, extend the
egress allowlist, and configure the built-in service integrations.

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

## Extending the egress allowlist

The agent's egress is restricted to the baked-in Squid allowlist. To allow extra
destinations locally, drop a `*.conf` file into `extra-allowlist.d/` (Squid
config syntax) — it's bind-mounted read-only into Squid at
`/etc/squid/extra-allowlist.d`. The directory is tracked but its `*.conf`
contents are gitignored, so your additions stay local. A restart (`./start.sh`)
applies them.

## Service integrations

Bitbucket, Jira, and GitLab are MCP servers the image auto-enables purely from
the credentials you put in `.env` (each with a `DISABLE_*_MCP` off-switch).
Every service needs its own `*_BASE_URL`; GitLab's is required for its MCP to
start at all.

- **Bitbucket** and **GitLab** each provide both a read-only MCP and a git
  remote. Bitbucket talks plain HTTP on the internal instance; GitLab is HTTPS,
  with REST auth via the `PRIVATE-TOKEN` header and git Basic auth from
  `GITLAB_USER:GITLAB_PAT`.
- **Jira** is REST-only, authenticated with its PAT as a Bearer token.

The service hostnames themselves are baked into the squid allowlist in the
image, so the launcher can't see or change them — it only passes through the
credentials and base URLs you configure. Set or change these any time with
`./start.sh --reconfigure`.
