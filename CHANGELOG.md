# Changelog

Changelog for the **OpenCode launcher**. It tracks two things, kept as
separate logs because they move independently:

1. **Launcher releases** — changes to the launcher itself.
2. **Image releases** — new OpenCode Workplace image versions you can run,
   and what you must do to pick each one up.

The launcher and the image are versioned separately and are **not** released
in lockstep: the launcher can change with no new image, and a new image can
ship with no launcher change. So an image entry here does not imply a launcher
release, and vice versa.

Format loosely based on [Keep a Changelog](https://keepachangelog.com/).

## How to read the "Action required" line

On the default `IMAGE_TAG=latest`, **`./start.sh` pulls the newest image on
every run** — so picking up a new image is usually just re-running it. Each
image's *Action required* line flags only what you must do **in addition** to
that normal re-run:

- **none** — just re-run `./start.sh`.
- **edit .env** — a variable was added or renamed. The launcher flags any new
  keys on the next boot; run `./start.sh --reconfigure` to fill them in.
- **update launcher** — `git pull` the launcher to at least the version noted,
  then re-run.

## Compatibility

The launcher and the image drift on purpose — most changes land in the
launcher; the image moves less often. There is **no version matrix**:

- **Supported pairing: the latest launcher + the latest image.** That's what we
  test and keep working. `IMAGE_TAG=latest` (the default) keeps the image
  current; `git pull` this repo now and then for the launcher. After either
  updates, re-check your `.env` against `.env.example` for new or renamed
  variables.
- **If an image needs a newer launcher**, that image's entry below says so on
  its *Action required* line (e.g. `update launcher (≥ 0.5.0)`). No such note
  means any reasonably current launcher works.
- Pinning an old image is fine, but mixing an old launcher with a new image (or
  vice versa) isn't something we test.

---

# Launcher releases

_Changes to the launcher itself._

> **Note on early entries.** The launcher had no version numbers before this
> changelog existed; versions **0.1.0–0.5.0** below were reconstructed after the
> fact by grouping git history into logical releases. Their version boundaries
> and dates are a **best-effort approximation** — treat them as a guide, not a
> precise tag-for-tag record. Entries from `0.6.0` onward are authoritative.

## [0.16.0] — 2026-08-10

**Action required:** none to keep working as before. To give a project its own
credentials, create `.envs/<slug>.overrides.env` (see README). To run the
unattended orchestrator, `./start.sh --symphony init <repo>` and read
`docs/SYMPHONY.md` in the maintainer repo first — it needs an image tag your
registry may not carry yet.

### Added

- **Per-project credentials now actually reach inside the container.**
  `start.sh` already generated a per-project env file (`.envs/<slug>.env`)
  and pointed `docker compose --env-file` at it, but `--env-file` only ever
  drives compose's own `${VAR}` interpolation — it puts nothing inside a
  container. The `opencode` service's `env_file:` now layers that
  per-project file **on top of** the shared `.env` (last value wins), so a
  project's env file — once it diverges from `.env` — is what the agent
  inside the container actually sees, not just what compose resolves
  variables from. A blank value there (e.g. `CONFLUENCE_PAT=`) drops that
  credential, and with it that MCP server (each one only turns on when its
  credentials are present), from the stack entirely rather than merely
  disabling it.
- **A place to put per-project values that survives a boot:**
  `.envs/<slug>.overrides.env`. The generated `.envs/<slug>.env` is rebuilt
  from `.env` on every run, so a value hand-written into it never survived to
  a second boot — which left the layering above expressible by compose and
  unreachable by a user. The overrides file is read between the shared `.env`
  and the launcher's own generated settings, so its values win over `.env`
  while `PROJECT_SLUG`/`OPENCODE_PORT`/`REPO_PATH` stay the launcher's (a
  stale hand-written port would otherwise leave the stack unreachable at the
  port it just printed). Projects without one are unaffected.
- **Symphony: opt-in unattended runs** (`./start.sh --symphony <verb> <repo>`,
  verbs `init check up logs status stop down add`). An orchestrator watches a
  queue of work items and runs an agent per item until each is ready for a
  human. Off unless you ask for it; nothing about a normal boot changes.

  Its per-project state lives in `.symphony/<slug>/` — `config/WORKFLOW.md`
  (the tracker choice and the agent's prompt), plus `queue/` and `workspaces/`.
  `symphony.env` beside them holds the orchestrator's own GitLab token, and is
  deliberately NOT one of the files handed to the agent's container: the
  orchestrator gets a Reporter token that can move issues but not push code,
  the agent a Developer token that can push but not relabel its own work.
  Neither can do the other's job, and that split is the containment — read
  `docs/SYMPHONY.md` in the maintainer repo before the first run.

  `--symphony check` is a preflight that refuses to start on the mistakes that
  otherwise surface as an unattended agent doing something unintended: a
  missing workflow, a GitLab tracker with no token, a workspaces mount pointing
  at your real repo, or a credential file readable from inside the orchestrator
  container. It also cross-checks `GIT_REMOTE_ALLOWLIST` against
  `GITLAB_WRITE_PROJECTS`, which gate different protocols in different
  processes and so cannot check each other at runtime.

  Requires the `-symphony` image tag in your registry; it is pulled, never
  built here.
- Five safety keys the image already read are now known to `.env.example`,
  `--config`, and `--reconfigure`: `GIT_REMOTE_ALLOWLIST`,
  `ALLOW_CONFLUENCE_WRITE`, `ALLOW_GITLAB_WRITE`, `GITLAB_WRITE_PROJECTS`,
  `GITLAB_QUEUE_LABEL_PREFIX`. The image consumed them already; the launcher
  just didn't list them, so `--doctor` and every boot's manifest check were
  spuriously warning the launcher was behind. All are opt-in and default to
  today's behaviour — nothing to do unless you want to turn one on:
  - `GIT_REMOTE_ALLOWLIST` (applies only when `ALLOW_REMOTE_GIT=1`) and
    `GITLAB_WRITE_PROJECTS` (only when `ALLOW_GITLAB_WRITE=1`) restrict
    where remote git / the GitLab MCP may write, as comma- or
    whitespace-separated host or project-path prefixes. **Both are defence
    in depth, not a security boundary** — an agent with a shell can call
    git or the GitLab API directly, bypassing either. They turn a mistake
    (a stale remote, a hallucinated project) into a clear local error
    instead of a confusing 403; the real boundary is what the token itself
    is scoped and permissioned to do, so scope your tokens accordingly —
    these settings are not a substitute for that.
  - `ALLOW_CONFLUENCE_WRITE` / `ALLOW_GITLAB_WRITE` gate whether their MCPs
    can write at all (create/edit Confluence pages; open MRs, comment,
    create GitLab issues) instead of only reading. Deleting a Confluence
    page is never possible either way, and even with GitLab writes on there
    is deliberately no tool to set labels, close an issue, or merge an MR.
  - `GITLAB_QUEUE_LABEL_PREFIX` is the one key here that is **not**
    off-by-default: it ships as `symphony`, a label namespace the GitLab
    MCP is never allowed to set (relevant only if something else — a
    workflow queue, an orchestrator — owns labels under that prefix as its
    own state). Blanking it doesn't remove the protection, since the MCP
    falls back to that same `symphony` default — set it only if you need to
    protect a *different* namespace.

## [0.15.0] — 2026-07-15

**Action required:** edit `.env` (add the M-Files keys — `./start.sh --reconfigure`
offers them) if you want the M-Files MCP; otherwise none.

### Added

- **M-Files service integration** (sixth read-only MCP server, matching the
  image). `.env.example` gains an M-Files block (`MFILES_BASE_URL`,
  `MFILES_PAT`, `DISABLE_MFILES_MCP`); the setup wizard, `--reconfigure`,
  `--doctor`, and `--show-allowlist` all now cover M-Files alongside the other
  five services.
- **Automatic M-Files token minting.** M-Files is the one service where the
  token isn't copied from a web UI — its `X-Authentication` value is a session
  token exchanged for vault credentials. The `MFILES_PAT` prompt in the setup
  wizard/`--reconfigure` (on a real terminal) now offers to mint it inline —
  username, a pick-one Windows domain, vault GUID, and a silently-read
  password — and writes the result straight into `.env`, with no copy-paste.
  The same flow is also available on its own via **`./start.sh
  --mfiles-token`**, for rotating an expired token without touring the whole
  wizard. Every mint auto-verifies the token against the vault; a failed
  verification (almost always wrong credentials) is never saved silently — it
  asks "save it anyway? [y/N]" first. See
  [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md#m-files-authentication-token)
  for the full flow, including how to read the vault GUID from **M-Files
  Desktop Settings** and the manual `curl` fallback.

### Changed

- The M-Files setup wizard now shows a status line while the mint/verify
  network calls run, instead of the terminal going silent for however long
  they take. The Windows domain field is a pick-one between the two domains
  set via `MFILES_DOMAIN_1`/`MFILES_DOMAIN_2` (placeholder names — set them to
  your real domains) rather than free text.

## [0.14.0] — 2026-07-10

### Added
- Support for the image `0.1.0` Bitbucket changes: the **new optional
  `BITBUCKET_LEGACY_URL`** field is now known to `.env.example`, the first-run
  setup wizard, and `--doctor`. Set it to a legacy Bitbucket URL that redirects
  to your `BITBUCKET_BASE_URL` (e.g. the plain-HTTP connector on `:7990`) and the
  image rewrites git remotes still pointing there — no more
  `Username for 'https://…'` prompt from a redirecting remote. Existing `.env`
  files get the new key flagged on the next boot; run `./start.sh --reconfigure`
  to fill it in.

### Changed
- The Bitbucket setup prompts and help text now reflect the image `0.1.0`
  **Bearer-PAT** auth: `BITBUCKET_USER` is optional (used only for
  git-over-HTTPS, not the REST API), and `.env.example` steers toward the
  canonical **HTTPS** base URL instead of the old plain-`http://` guidance.

## [0.13.0] — 2026-07-09

### Changed

- **The boot update check is now an interactive upgrade gate.** On a normal
  interactive boot, when the launcher checkout is behind its git upstream
  and/or `IMAGE_TAG` is pinned off `latest`, `start.sh` now prompts
  `bring everything up to date and restart? [Y/n]` **before** booting the
  stack. Accepting fast-forwards the launcher (`git pull --ff-only`), flips a
  pinned `IMAGE_TAG` back to `latest`, and re-execs `start.sh` with the same
  arguments so the run continues on the newest launcher + image — the only
  tested pairing. Declining boots the current version unchanged.
- The check runs **before** the image pull now (it used to nudge after the
  stack was already up). Headless boots (`--detach`, `--exec`, or any run with
  no controlling terminal) never prompt — they print the same passive
  `launcher update available: …` nudge as before, plus an `image pinned to …`
  line when relevant, and boot without blocking.
- `OC_SKIP_UPDATE_CHECK=1` continues to skip the whole thing; a fresh
  `OC_UPGRADED=1` guard (set only on the internal re-exec) prevents any restart
  loop. `--doctor`'s launcher-behind report is unchanged. A pinned `local`
  image tag (self-built / package-layer) is never treated as a pin to nudge.
- **After a launcher upgrade, offer to set newly-added config keys.** When the
  gate fast-forwards the launcher, the restarted run compares `.env.example` at
  the version you upgraded *from* against the new one and, at a tty, offers to
  set any keys that are new since then and still missing from your `.env` — one
  prompt each (reusing the setup wizard), or skip and run `--reconfigure` later.
  Fully generic: driven by the tracked `.env.example` diff across the exact
  commits crossed, so future releases surface their new keys with no per-release
  code. A headless boot keeps the existing passive drift warning.
- **`--reconfigure` and the setup wizard can now add keys missing from your
  `.env`.** Previously `set_env` only *replaced* an existing `KEY=` line, so a
  key that was new to your `.env` since it was created (e.g. one added to
  `.env.example` by a later release) was silently dropped — and the drift
  warning's advice to "run `--reconfigure`" couldn't actually fix it. `set_env`
  now appends a missing key, so both the wizard and the post-upgrade offer write
  it correctly.
- **`--doctor` now WARNs when `IMAGE_TAG` is pinned** off `latest` (only the
  latest launcher + latest image is a tested pairing), alongside its existing
  "new keys in `.env.example`" drift report. Both are WARN, never FAIL.

### Internal

- New pure helpers `image_tag_pinned`, `launcher_pull_ff`, and
  `env_example_added_keys` in `lib/update.sh` (unit-tested); the boot gate
  (`upgrade_gate`) and the post-upgrade config offer (`config_drift_step`) live
  in `start.sh`. The gate passes the pre-upgrade revision to the restarted run
  via `OC_PREV_REV`. New `doctor_check_image_pin` in `lib/doctor.sh`.

## [0.12.0] — 2026-07-09

### Added
- Support for the new **`opencode-pty`** plugin (image `0.0.8`): opt in via
  `ENABLED_PLUGINS` as usual, then start its web viewer from the TUI with
  `/pty-open-background-spy`. The launcher publishes the viewer on a derived
  port — the base port with a literal `1` prepended (`4096` → `14096`) — and
  prints its URL alongside the main web UI on boot, `--status`, and `--open`
  whenever the plugin is enabled for that project. Fresh port assignment now
  also checks that a candidate's derived viewer port is free, not just the
  candidate itself, so multiple instances' viewers never collide either.

## [0.11.0] — 2026-07-07

### Changed
- `--exec` now boots a **minimal stack** — just the `opencode` container and
  its `squid` egress proxy. A one-shot run only `docker exec`s a single prompt
  into the agent, so the web-UI publisher (`oc-publish`) is no longer started
  for it: no port is published and the boot is faster. `--exec --persist`
  (which leaves a resumable environment running) still boots the **full**
  stack, web UI included, as before; every TUI/web run is unchanged. The pull
  is likewise scoped to the images actually needed, and the web-UI URL/
  workaround notice is suppressed for a one-shot run (there is no web UI to
  point at).
- `--exec` shows a small **spinner** while it works, so a slow one-shot run
  no longer looks like a hang (a successful `--exec` is otherwise silent — all
  chatter is buffered away, see 0.10.0). It starts the instant you hit Enter
  and animates through the whole boot (pull/up) and the model call, then
  erases itself and drops the answer a couple of lines below for a clean
  separation. It's drawn **only to the terminal** (never stdout or the
  captured stderr) and **only when the launcher is interactive** (a real
  terminal on stderr) — so a piped/CI run gets no spinner and byte-exact
  output, and the answer is captured/streamed exactly as before. The answer is
  briefly buffered so the spinner is guaranteed to clear before the first
  answer byte prints (`opencode run` emits its text as a final burst, so
  nothing is lost).
- `--exec` no longer runs the best-effort launcher self-update check
  (`git fetch`): its output is machine-consumed and the nudge was buffered
  away on success anyway, so the extra network round-trip was pure startup
  latency. Normal runs still perform the check; `OC_SKIP_UPDATE_CHECK=1` still
  disables it everywhere.
- `--exec` now accepts no `<host-repo-path>`: run a one-shot prompt against an
  empty `/workspace` (no repo mounted). Every other run still requires the
  repo path.

### Internal
- The `--exec` path moved out of `start.sh` into its own `lib/exec.sh`
  (stream isolation, the spinner, and the non-interactive `opencode run` +
  teardown), matching how the other subcommands live under `lib/`. Behaviour
  is unchanged apart from the items above.

## [0.10.0] — 2026-07-03

### Added
- `--also <path>[:rw]`: mount an extra host folder (e.g. a library repo the
  agent should read for context) into the container alongside your main repo,
  at `/workspace-extra/<name>` (`<name>` derives from the folder's own
  basename the same way the project slug does, with `-2`/`-3`/... suffixing
  on a name collision between two `--also` paths). Read-only by default;
  append `:rw` to opt one mount into read-write. Repeatable. Implemented as a
  small generated per-project compose overlay
  (`.envs/<slug>.also.yml`, appended last so it always wins); a boot with no
  `--also` flags deletes any stale overlay from a previous run. `--down`/
  `--logs`/`--shell` pick it up automatically when present, and
  `./start.sh --status <repo>` lists the mounts a stack was last booted with.
  The launcher also makes the mounts **discoverable** to the agent: opencode's
  file tools are anchored to `/workspace`, so it would never find the siblings
  on its own. On each `--also` boot the launcher writes a breadcrumb
  (`.envs/<slug>.also-context.md`) listing each folder and its
  `/workspace-extra/<name>` path, mounts it read-only, and points the image at
  it via `OPENCODE_EXTRA_INSTRUCTIONS` — a generic "load these instruction
  files" hook the image honors (it has no `--also` knowledge of its own).
  Needs an image that honors that var (see the image release below); on an
  older image the folders are still mounted, just not advertised.
- `--exec "<prompt>"`: boot the stack without attaching the TUI, run
  `<prompt>` non-interactively via `opencode run` inside the container, tear
  the stack down (unless `--persist` is also given), and exit with that
  command's own exit code — for scripting/CI one-shot runs. `--continue`
  prepends opencode's own `-c` (resume most recent session) ahead of the
  prompt; `--also` works as normal. Conflicts with `--detach` (both are
  non-interactive; pick one).
- `./start.sh --status <repo>` now also reports the MCP servers the running
  container's image actually wired up (`mcps:    bitbucket, jira`, or
  `mcps:    (none configured)`), read from the container's own
  `opencode.json` via `jq`. Entirely best-effort: any failure (exec fails, no
  jq, file missing) prints nothing, only shown while the stack is running.
- Best-effort launcher self-update check: on every boot, and as its own
  `--doctor` PASS/WARN line, `start.sh` reports when this launcher checkout
  is behind its git upstream (`launcher update available: N commit(s) behind
  origin — git pull to update`). Silent/neutral on any failure (offline, no
  upstream, not a git checkout) — never a FAIL. Skip the boot-time check
  entirely with `OC_SKIP_UPDATE_CHECK=1`.

### Fixed
- `--exec` no longer hangs when run from an interactive terminal. The
  one-shot `docker exec -i ... opencode run` left opencode's stdin bound to
  the launcher's terminal; `opencode run` drains stdin for piped prompt
  context, so it blocked forever on an EOF that never came (it printed its
  startup lines, then hung). The launcher now feeds `opencode run` `/dev/null`
  when its own stdin is a TTY, while still forwarding stdin that is genuinely
  piped/redirected in (`data | ./start.sh --exec …`).
- `--exec` now prints **only the model's answer on success**, with no
  `2>/dev/null` needed. opencode already splits its streams — answer on stdout,
  logs on stderr, and only the final text when its output isn't a TTY — so the
  launcher reserves stdout for `opencode run`'s stdout (via fd 3) and buffers
  everything else (its own boot/teardown chatter *and* opencode's stderr,
  including the harmless `No .git found at /workspace` notice). On success that
  buffer is discarded — a clean answer on the terminal and a clean
  `answer="$(./start.sh --exec "…" repo)"` capture. **On failure** (a boot error
  or a non-zero `opencode run`) the buffer is replayed to stderr so nothing
  fails silently. It's exit-code driven — no message-content matching — so it
  stays correct whatever the launcher or opencode print, and `opencode run`'s
  exit code is always propagated.

## [0.9.0] — 2026-07-03

### Added
- Image self-description: newer images ship `/etc/opencode/manifest.json`
  (the env keys they read), `/etc/opencode/CHANGELOG.md`, and an
  `org.opencontainers.image.version` OCI label. `./start.sh` now reads these
  best-effort (never pulling, never failing on an older image that has
  none of them) and, only when a boot's image digest actually changed,
  prints the new image version and that version's changelog section, and
  warns if the image now reads an env key this launcher's `.env.example`
  doesn't know about ("this image reads env key(s) your launcher doesn't
  know: ... — git pull the launcher, then ./start.sh --reconfigure").
- `./start.sh --doctor` gained an `image manifest` check: PASS when the
  image's manifest is present and every key it reads is known to this
  launcher, WARN (never FAIL) listing the unknown key(s) on drift, and a
  neutral skipped WARN when the image isn't pulled locally or predates the
  manifest.

## [0.8.0] — 2026-07-03

### Fixed
- Ports are now sticky per project. `--down`/`--logs`/`--shell` used to
  re-derive the port with a fresh `port_in_use 4096` check and rewrite
  `.envs/<slug>.env` on every call — if a project's own stack was running on
  4096, those commands saw 4096 as "busy" (their own stack!), picked 4097,
  and overwrote the recorded port, after which `--status` reported the wrong
  web-UI URL. Re-running `./start.sh <repo>` while that repo's stack was
  already up had the same problem: it moved the port instead of reusing it.
  Port resolution is now a single shared helper (`resolve_project_port`,
  used by both the boot flow and the management commands): a running
  project's own recorded port is always reused, and a down project's
  recorded port is reused whenever it's still free.
- `--down`/`--logs`/`--shell` no longer rewrite `.envs/<slug>.env` at all
  when it already exists — they read it back verbatim (compose still needs
  `--env-file` to point at *something*, so it's generated once if missing).
  Only the boot flow (re)writes the file unconditionally, as intended.

### Removed
- `ENABLE_SESSION_LOGS` — the tmpfs-swap knob never actually worked (the
  image-side mount needs `CAP_SYS_ADMIN`, which the container is never
  granted, so the mount silently failed and session state was always
  persisted regardless of the setting). Removed from `.env.example`, the
  config schema, and the `--reconfigure`/`--config` UI; it never functioned
  in the image either and is being removed there too. A leftover
  `ENABLE_SESSION_LOGS=` line in an existing `.env` is harmless — it's simply
  ignored.

## [0.7.0] — 2026-06-26

### Added
- JFrog and Confluence support, matching the new MCP servers in image `0.0.6`:
  `JFROG_BASE_URL`/`JFROG_PAT` and `CONFLUENCE_BASE_URL`/`CONFLUENCE_PAT`, plus
  the `DISABLE_JFROG_MCP`/`DISABLE_CONFLUENCE_MCP` switches. They now flow
  through `.env.example`, the first-run/`--reconfigure` wizard, the `--config`
  dashboard, `--show-allowlist`, and the `--doctor` env checks.

## [0.6.0] — 2026-06-19

### Added
- This `CHANGELOG.md` (the single user-facing log for both launcher and image),
  a root `VERSION` file as the current-version source of truth, and a
  `./start.sh --version` flag that prints it.
- A "What's new" pointer in the README and a maintainer release step in
  [`docs/MAINTAINERS.md`](docs/MAINTAINERS.md).
- `--doctor` now flags `.env.example` drift — any new keys you haven't picked up
  into your `.env` — and points you at `./start.sh --reconfigure` to add them
  (key names only, never values).

### Changed
- `--doctor` no longer runs a port-free check: `start.sh` already picks a free
  port automatically and any port works, so it was a non-issue. With a repo
  path, `--doctor` now just validates that path.

### Fixed
- `--status`/`--logs`/`--shell` no longer miss running stacks (use
  `compose ls --format`).
- "Resume" guidance points at `./start.sh --continue` instead of a raw
  `docker exec`.
- Corrected the web/desktop-UI port and working-directory claims in the docs.

## [0.5.0] — 2026-06-18

### Added
- Schema-driven configuration: a `--config` read-only dashboard and a
  `--reconfigure` menu, backed by an ncurses (whiptail/dialog) editor with a
  plain-text fallback, and a gated ncurses editor for first-run setup.

### Changed
- Synced the launcher's integration surface with the image: GitLab plus
  read-only Bitbucket/Jira credentials now flow through `.env`, setup, the
  doctor checks, and allowlist reporting.
- Refactored `start.sh` into sourced `lib/` modules with a thin `main()`,
  extracted the usage text, moved the compose stack under `docker/` and
  `SYNC.md` under `docs/`, and made the stack pull-only.

## [0.4.0] — 2026-06-17

### Added
- Lifecycle and inspection commands: `--doctor`, `--status`, `--down`/`--stop`,
  `--logs`, `--shell`, `--open`, and `--show-allowlist`.
- Image digest reporting with an "image updated" nudge, and an `.env.example`
  drift check.
- Shell completions (bash/zsh) and an `install.sh` bootstrap helper.

## [0.3.0] — 2026-06-16

### Added
- Opt-in `ENABLED_PLUGINS` support surfaced through the launcher, with a
  first-run prompt to enable the image's baked-in plugins.
- `docs/MODELS.md` model comparison guide and plugin provenance docs.
- `pip:` prefix support in `extra-packages.txt`.

### Changed
- Stopped hardcoding the OpenCode version in prose; trimmed and restructured the
  README.
- Added a first-run warning about the `opencode-workspace` plugin being
  incompatible with Qwen.

## [0.2.0] — 2026-06-10 _(approximate)_

### Added
- `IMAGE_TAG` drives image selection (default `latest`; pin e.g. `0.0.2` or a
  digest).
- A bats test suite, a self-service build-time system-package layer, and a
  `--continue`/`-c` passthrough.

### Changed
- Made the TUI the default frontend and synced the compose deltas with the
  maintainer repo.
- Dropped the prod overlay/workflow; marked Bitbucket and git identity optional
  in setup.

## [0.1.0] — 2026-06-01 _(approximate)_

### Added
- Initial launcher: `docker compose` glue, `start.sh`, the `.env` template,
  docs, and a host-editable user layer (`USER_LAYER_PATH`).

<!--
## [x.y.z] — YYYY-MM-DD
### Added / Changed / Fixed
- ...
-->

---

# Image releases

What's in each OpenCode Workplace image version, distilled for the people who
run it.

## [0.2.0] — 2026-07-15

**Action required:** re-pull image + recreate the stack (the Squid allowlist
change rides the images); edit `.env` (new M-Files credentials) + update
launcher (≥ 0.15.0) if you want the M-Files MCP — otherwise none beyond the
re-pull.

- **Read-only M-Files integration** (sixth MCP server, alongside
  Bitbucket/Jira/GitLab/JFrog/Confluence): browse object types and classes,
  search objects, fetch an object with its properties and files, and download
  file content. Auto-enables once `MFILES_BASE_URL` + `MFILES_PAT` are set
  (force off with `DISABLE_MFILES_MCP=1`). M-Files is the first service
  authenticated via a custom `X-Authentication` header instead of
  Bearer/Basic — no username needed — and, unlike every other service, the
  PAT is a **session token you mint from your vault credentials** rather than
  one copied from a web UI. The launcher (≥ 0.15.0) can mint it for you
  automatically; see the launcher's `0.15.0` entry above.
- New bundled **`mfiles-fetch`** skill driving the M-Files tools for
  document-management lookups.
- New "Getting an M-Files authentication token" section in the image's
  `docs/MCP_SERVERS.md` — the manual fallback for minting `MFILES_PAT` if you'd
  rather not use the launcher's built-in flow.
- Docs and the bundled agent instructions now cover six MCP servers instead
  of five.
- **`pty-sessions` skill clarified:** `pty_spawn`'s `command` must be
  something that keeps the terminal open (e.g. `bash`, not `echo hello`,
  which exits immediately), and driving a session via `pty_write` requires a
  trailing newline (`\n`) to act as pressing Enter.

## [0.1.0] — 2026-07-10

**Action required:** re-pull image + recreate the stack (the `NO_PROXY`, Squid,
and theme changes ride the images) + edit `.env` + update launcher (≥ 0.14.0).

- **Bitbucket now authenticates with a Bearer PAT** (Bitbucket Data Center HTTP
  access token), matching Jira/JFrog/Confluence. `BITBUCKET_USER` is no longer
  required to turn the MCP on — it's now optional, used only by git for
  clone/push over HTTPS. Existing setups with the full user+PAT keep working.
- **New optional `BITBUCKET_LEGACY_URL`.** Point it at a legacy Bitbucket URL
  that redirects to your `BITBUCKET_BASE_URL` (typically the plain-HTTP connector
  on `:7990`) and the container rewrites any git remote still using it before
  connecting — so a redirecting remote no longer surfaces an interactive
  `Username for 'https://…'` prompt. Prefer pointing `BITBUCKET_BASE_URL` at your
  canonical **HTTPS** endpoint. Add the new key to `.env` via
  `./start.sh --reconfigure` (needs launcher ≥ 0.14.0).
- **Internal `*.local` hosts now route through the proxy** (removed `.local`
  from `NO_PROXY`). Previously `git`/`curl` tried to reach them directly and
  failed with `could not resolve host` / `CONNECT tunnel failed`; now they go
  through Squid like the MCP already did, so git-over-HTTPS to Bitbucket works.
- **Squid resolves bare (short) hostnames** by appending your internal domain,
  so an internal service reachable only by short name (e.g. `mybitbucket`) no
  longer `503`s at the proxy.
- **The bundled `corp` theme is split into `corp-dark` and `corp-light`;** the
  default is now `corp-dark`. If you pinned `corp` in your own `tui.json`
  `theme` or a `disabled.yaml` `themes:` entry, update it to `corp-dark` or
  `corp-light`.
- New **troubleshooting docs** (image `docs/TROUBLESHOOTING.md`) for the
  Bitbucket base-URL redirect prompt and the `NO_PROXY` bypass errors above.

## [0.0.8] — 2026-07-09

**Action required:** re-pull image. Opt in to `opencode-pty` via
`ENABLED_PLUGINS`; if you want its web viewer, also update launcher (≥ 0.12.0).

- New **`opencode-pty`** plugin (opt-in via `ENABLED_PLUGINS`, off by default):
  interactive PTY management tools for driving background processes, plus a
  live web viewer you start from the TUI with `/pty-open-background-spy`. The
  viewer is served on a port derived from the main one (see the launcher
  0.12.0 entry for the host-side wiring).
- New **`pty-sessions`** skill teaching the agent to use those PTY tools
  instead of the blocking one-shot `bash` tool; only present when
  `opencode-pty` is enabled.
- The `*-fetch` skills (Bitbucket, Jira, GitLab, JFrog, Confluence) now only
  appear when their matching MCP server is actually up, instead of always
  showing regardless of whether credentials are configured.
- Bumped the bundled OpenCode CLI to `1.17.15`.

## [0.0.7] — 2026-07-07

**Action required:** none — just re-run `./start.sh`

- The launcher's **`--also`** extra folders are now **discoverable** to the
  agent. opencode's file tools are anchored to `/workspace`, so on an older
  image those sibling folders are mounted but the agent won't find them on its
  own; this image lets a launcher (≥ 0.10.0) advertise them. Nothing to
  configure — see the launcher 0.10.0 entry for the `--also` side.
- **Squid now logs *denied* requests** — a blocked destination, a disallowed
  `CONNECT` port, an unsafe port — to `docker compose logs squid`, so you can
  debug allowlist misses yourself. Allowed traffic, including all
  LLM/conversation data, is still **never** logged; the no-retention stance is
  unchanged.
- **Security hardening:** removed passwordless `sudo` (and dropped the `sudo`
  package) — it let the container re-own the host workspace bind mount and
  nothing legitimate used it; the git credential helper now matches hosts
  **exactly** (a lookalike host could previously be handed real credentials);
  and the git safety gate no longer lets `git -C …`, `git -c k=v …`, or
  `git --git-dir=… …` forms slip past its remote gate (`ls-remote` is gated
  too).
- The image now ships a machine-readable **manifest**
  (`/etc/opencode/manifest.json`) and its own **`CHANGELOG.md`** — the source
  the launcher reads to show a new image's version and notes on update, and to
  warn about env keys it doesn't yet know (see launcher 0.9.0).
- **Removed the `ENABLE_SESSION_LOGS` knob** — it never worked (the tmpfs swap
  it relied on needs a capability compose never grants, so session state was
  always persisted anyway) and is now ignored. Already dropped launcher-side in
  0.8.0; if it still lingers in your `.env`, delete it.

## [0.0.6] — 2026-06-26

**Action required:** edit `.env` (new MCP credentials) + update launcher (≥ 0.7.0)

- Read-only **JFrog Artifactory** integration: browse repositories, search
  artifacts (incl. AQL), look up the latest version, fetch files, and read
  build info. Auto-enables once `JFROG_BASE_URL` + `JFROG_PAT` are set (force off
  with `DISABLE_JFROG_MCP=1`). Bearer token, no username — same shape as Jira.
- Read-only **Confluence** integration: read pages, CQL search, browse a space's
  page tree, list spaces. Auto-enables once `CONFLUENCE_BASE_URL` +
  `CONFLUENCE_PAT` are set (force off with `DISABLE_CONFLUENCE_MCP=1`). Bearer
  token, no username. Note the default HTTP connector is port **8090** — include
  it in the URL unless your instance is on standard HTTPS.
- New bundled `jfrog-fetch` and `confluence-fetch` skills driving the two
  integrations.
- Add the new per-service credentials to your `.env` to enable these (re-run
  `./start.sh --reconfigure` to fill them in), then re-run `./start.sh` — it
  re-pulls both the agent and squid images on `latest`.
- Newer pinned OpenCode version inside the image.

## [0.0.5] — 2026-06-18

**Action required:** edit `.env` (new credentials) + update launcher (≥ 0.5.0)

- Read-only **Bitbucket, Jira, and GitLab** integration: the agent can browse
  PRs/MRs, diffs, commits, files, and issues directly. Each turns on
  automatically once its PAT is set in `.env`.
- New bundled skills for driving the Bitbucket and Jira integrations.
- Add the new per-service PATs to your `.env` to enable these.

## [0.0.4] — 2026-06-12

**Action required:** review `ENABLED_PLUGINS` in `.env`

- `ENABLED_PLUGINS` is now the **single source of truth** for plugins —
  anything not listed is off. Re-check your list after updating.
- Each baked-in plugin's upstream + pinned version is now documented.
- Note: leave `opencode-workspace` disabled if you use Qwen (it breaks Qwen).

## [0.0.3] — 2026-06-11

**Action required:** set `ENABLED_PLUGINS` (optional)

- Curated **OpenCode plugins baked into the image, off by default** — opt in
  per developer via `ENABLED_PLUGINS` in `.env`, no network needed.
- OpenCode version is now pinned in the image for reproducible builds.
- Web UI / desktop app start in `/` instead of `/workspace` on this OpenCode
  version — **prefer the TUI** (unaffected).

## [0.0.2] — 2026-05-29

**Action required:** none — just re-run `./start.sh`

- Reliability fixes: the OpenCode port now reaches the host on the
  internal-only network setup; `doctor.sh` verifies more of the stack; squid
  handles TLS on non-443 ports.

## [0.0.1] — 2026-05-11

**Action required:** full install (first release)

- Initial release: locked-down OpenCode in Docker, all egress forced through a
  Squid allowlist, starter agents/skills, and a git safety gate.
