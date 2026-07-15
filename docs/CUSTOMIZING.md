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

Bitbucket, GitLab, Jira, JFrog, Confluence, and M-Files are read-only MCP
servers the image auto-enables purely from the credentials you put in `.env`
(each with a `DISABLE_*_MCP` off-switch). Every service needs its own
`*_BASE_URL`; GitLab's is required for its MCP to start at all.

- **Bitbucket** and **GitLab** each provide both a read-only MCP and a git
  remote. Bitbucket talks plain HTTP on the internal instance; GitLab is HTTPS,
  with REST auth via the `PRIVATE-TOKEN` header and git Basic auth from
  `GITLAB_USER:GITLAB_PAT`.
- **Jira**, **JFrog**, and **Confluence** are REST-only, each authenticated with
  its PAT as a Bearer token (no username). JFrog's base is the platform root (the
  MCP appends `/artifactory/api`); Confluence's default connector is HTTP on
  `:8090` (the MCP appends `/rest/api`).
- **M-Files** is REST-only too, but is the one service that authenticates via a
  custom **`X-Authentication`** header instead of Bearer/Basic — and its token is
  one you **mint yourself** (see below). Its base is the site root over HTTPS; the
  MCP appends `/REST`.

The service hostnames themselves are baked into the squid allowlist in the
image, so the launcher can't see or change them — it only passes through the
credentials and base URLs you configure. Set or change these any time with
`./start.sh --reconfigure`.

### M-Files authentication token

For every other service you paste a PAT created in that tool's web UI. M-Files
is different: its `X-Authentication` value is a **session token you exchange
your vault credentials for** — there is no "copy token" button. The launcher
mints it for you and writes it straight into `.env` — no copy-paste.

**1. Find your vault GUID.** In the Windows system tray, **right-click the
M-Files icon → Settings → M-Files Desktop Settings**. In the window that opens,
the **"Document Vault on Server"** column shows the GUID in curly braces, e.g.
`{C540E37E-...}`. You need **only the ID inside the braces** — don't copy the
braces or the rest of the cell. (The mint flow strips braces defensively if
you paste them anyway.)

**2. Mint the token.** Two ways to trigger the same mint flow:

- **During the setup wizard or `--reconfigure`**, on a real terminal, the
  `MFILES_PAT` prompt itself asks "Mint an M-Files token automatically instead
  of pasting one? [Y/n]" — accept it and the rest happens inline.
- **On its own, any time** (e.g. to rotate an expired token without touring
  the whole wizard):

  ```bash
  ./start.sh --mfiles-token
  ```

Either way it prompts for the base URL (defaulted from `MFILES_BASE_URL` in
your `.env`), a **Windows domain — pick one of the two the company uses**
(a menu in the ncurses editor, a numbered 1/2 choice on the plain-text path —
see `MFILES_DOMAIN_1`/`MFILES_DOMAIN_2` below), then your username and the
vault GUID, then reads your password **silently** (never stored or echoed).
It POSTs them to
`…/REST/server/authenticationtokens`, verifies the result against the vault
(bounded to 10s to connect / 10s total, so a bad address fails fast rather
than hanging), and writes `MFILES_BASE_URL`/`MFILES_PAT` into `.env` itself —
you never see or handle the raw token.

The two domain choices are placeholders (`DOMAIN-ONE`/`DOMAIN-TWO` by
default) — set the environment variables `MFILES_DOMAIN_1`/`MFILES_DOMAIN_2`
to your real domain names (e.g. in your shell profile, or prefixed on the
command: `MFILES_DOMAIN_1=CORP MFILES_DOMAIN_2=CONTRACTORS ./start.sh
--mfiles-token`) or just edit the two `MFILES_DOMAIN_*` lines at the top of
`lib/mfiles.sh` once you know them.

If the verification call fails — usually a sign the username, password,
domain or vault GUID was wrong — the token is **not** saved automatically:
you're asked "Save this unverified token anyway? [y/N]". Answering no (the
default) discards it and writes nothing; just run the mint again with the
right credentials.

Run this on **your own machine**, on the corp network with direct access to
M-Files — not inside the container. The mint call talks to M-Files directly
(`--noproxy '*'`).

**Manual fallback.** If you'd rather do the exchange by hand (note: **no
`.aspx`** on the path):

```bash
curl --fail-with-body --noproxy '*' \
  -X POST https://mfiles.internal.example/REST/server/authenticationtokens \
  -H 'Content-Type: application/json' \
  -d '{"Username":"you","Password":"secret","Domain":"CORP","VaultGuid":"C540E37E-..."}'
# → {"Value":"<token>"}
```

The `Value` is your `MFILES_PAT` — paste it via `./start.sh --reconfigure`.

**If M-Files starts returning auth errors after it worked**, the session token
has most likely expired — run `./start.sh --mfiles-token` to mint a fresh one.
