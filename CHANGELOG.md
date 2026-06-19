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

Every image release carries one line telling you what to do to pick it up:

- **rerun only** — just re-launch. No new image, no config change.
- **re-pull image** — set the image tag to the new version and pull.
- **edit .env** — a variable was added or renamed; update your `.env`.
- **rebuild squid** — the allowlist or squid config changed; rebuild/repull squid.
- **update launcher** — you also need the launcher version noted alongside.

## Compatibility

Which launcher version goes with which image.

> **Pair the launcher and image on the same row.** They are versioned
> independently but are **not** freely interchangeable. Each image release can
> add or rename `.env` variables, so running a **newer image with an older
> launcher** (and its older `.env.example`) means the new variables are
> missing — at best the image's new features stay off, and in some cases the
> stack won't come up correctly. Likewise a newer launcher may expect `.env`
> fields an older image ignores. Keep your launcher — and your `.env`,
> re-checked against `.env.example` — at the row for the image you run.

| Launcher | Image  | Notes |
|----------|--------|-------|
| 0.5.0    | 0.0.5  | Adds Bitbucket/Jira/GitLab — needs new PATs in `.env` (launcher 0.5.0 added those fields to setup/doctor/allowlist) |
| 0.3.0    | 0.0.4  | `ENABLED_PLUGINS` becomes the single source of truth; launcher surface unchanged since 0.3.0 |
| 0.3.0    | 0.0.3  | Opt-in plugins via `ENABLED_PLUGINS`, surfaced by the launcher at first run |
| 0.2.0    | 0.0.2  | `IMAGE_TAG` pinning lands in the launcher (pin e.g. `0.0.2` or a digest) |
| 0.1.0    | 0.0.1  | First release |

---

# Launcher releases

_Changes to the launcher itself._

> **Note on early entries.** The launcher had no version numbers before this
> changelog existed; versions **0.1.0–0.5.0** below were reconstructed after the
> fact by grouping git history into logical releases. Their version boundaries
> and dates are a **best-effort approximation** — treat them as a guide, not a
> precise tag-for-tag record. Entries from `0.6.0` onward are authoritative.

## [0.6.0] — 2026-06-19

### Added
- This `CHANGELOG.md` (the single user-facing log for both launcher and image),
  a root `VERSION` file as the current-version source of truth, and a
  `./start.sh --version` flag that prints it.
- A "What's new" pointer in the README and a maintainer release step in
  [`docs/MAINTAINERS.md`](docs/MAINTAINERS.md).

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
  doctor checks, and allowlist reporting. _(Pairs with image 0.0.5.)_
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
  first-run prompt to enable the image's baked-in plugins. _(Pairs with image
  0.0.3–0.0.4.)_
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
  digest). _(Pairs with image 0.0.2.)_
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
  docs, and a host-editable user layer (`USER_LAYER_PATH`). _(Pairs with image
  0.0.1.)_

<!--
## [x.y.z] — YYYY-MM-DD
### Added / Changed / Fixed
- ...
-->

---

# Image releases

What's in each OpenCode Workplace image version, distilled for the people who
run it. (Engineering-level detail lives in the image repo and isn't needed
here.)

## [0.0.5] — 2026-06-18

**Action required:** re-pull image + edit .env (new credentials)

- Read-only **Bitbucket, Jira, and GitLab** integration: the agent can browse
  PRs/MRs, diffs, commits, files, and issues directly. Each turns on
  automatically once its PAT is set in `.env`.
- New bundled skills for driving the Bitbucket and Jira integrations.
- Add the new per-service PATs to your `.env` to enable these.

## [0.0.4] — 2026-06-12

**Action required:** re-pull image + review `ENABLED_PLUGINS` in .env

- `ENABLED_PLUGINS` is now the **single source of truth** for plugins —
  anything not listed is off. Re-check your list after updating.
- Each baked-in plugin's upstream + pinned version is now documented.
- Note: leave `opencode-workspace` disabled if you use Qwen (it breaks Qwen).

## [0.0.3] — 2026-06-11

**Action required:** re-pull image + set `ENABLED_PLUGINS` (optional) + rebuild squid

- Curated **OpenCode plugins baked into the image, off by default** — opt in
  per developer via `ENABLED_PLUGINS` in `.env`, no network needed.
- OpenCode version is now pinned in the image for reproducible builds.
- Web UI / desktop app start in `/` instead of `/workspace` on this OpenCode
  version — **prefer the TUI** (unaffected). Squid config was also cleaned up.

## [0.0.2] — 2026-05-29

**Action required:** re-pull image

- Reliability fixes: the OpenCode port now reaches the host on the
  internal-only network setup; `doctor.sh` verifies more of the stack; squid
  handles TLS on non-443 ports.

## [0.0.1] — 2026-05-11

**Action required:** full install (first release)

- Initial release: locked-down OpenCode in Docker, all egress forced through a
  Squid allowlist, starter agents/skills, and a git safety gate.
