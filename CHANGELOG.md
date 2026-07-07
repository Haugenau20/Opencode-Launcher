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
- `--exec` now isolates its stdout to **exactly `opencode run`'s stdout** (the
  model's answer). opencode already splits its streams — answer on stdout, logs
  on stderr, and only the final text when its output isn't a TTY — so the
  launcher reserves stdout for it (saving the real stdout as fd 3) and folds all
  of its *own* boot/teardown chatter onto stderr, alongside opencode's stderr.
  A scripted `answer="$(./start.sh --exec "…" repo)"` now captures just the
  result, with no output scraping. This also makes opencode's harmless
  `No .git found at /workspace` notice (and anything else opencode logs) a
  stderr-only concern — no message-content matching, so it stays correct
  whatever opencode prints. Silence the diagnostics on a terminal with
  `2>/dev/null`; the exit code is still `opencode run`'s own.

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
