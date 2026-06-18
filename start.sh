#!/usr/bin/env bash
#
# start.sh — boot a locked-down OpenCode workplace against your own code repo.
#
#   ./start.sh [--detach] <host-repo-path>
#   ./start.sh --help
#
# One launcher clone handles many repos: per-project settings (slug, port,
# repo path) are derived from the path argument, never stored in .env.
#
# Structure: pure helpers live at the top level so they can be sourced and
# unit-tested in isolation (see tests/). The imperative flow lives in main(),
# which only runs when the script is executed directly (the source-guard at the
# bottom). Strict mode (set -euo pipefail) is enabled inside main() so sourcing
# the file for tests has no side effects.

# Paths are overridable so tests can point them at a sandbox before sourcing.
ENV_FILE="${ENV_FILE:-.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-.env.example}"
ENVS_DIR="${ENVS_DIR:-.envs}"
EXTRA_PACKAGES_FILE="${EXTRA_PACKAGES_FILE:-extra-packages.txt}"

# Plugins baked into the image, all OFF by default. Shown as a hint during
# first-run setup so users can opt in interactively. This is only a convenience
# list: the prompt accepts any value (so a newer image's plugins still work even
# if this is stale), and the authoritative catalog is the /plugins TUI command.
KNOWN_PLUGINS="${KNOWN_PLUGINS:-superpowers dcp opencode-workspace}"

# --- tiny output helpers ----------------------------------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./start.sh [--continue] [--persist] [--detach] [--podman] [--open] <host-repo-path>
  ./start.sh --doctor [<host-repo-path>]
  ./start.sh --status [<host-repo-path>]
  ./start.sh --down|--stop <host-repo-path>
  ./start.sh --logs <host-repo-path>
  ./start.sh --shell <host-repo-path>
  ./start.sh --reconfigure
  ./start.sh --config
  ./start.sh --show-allowlist [<host-repo-path>]
  ./start.sh --help

Boots a locked-down OpenCode environment with your repo mounted at /workspace.
By default the OpenCode TUI is attached in the foreground once the stack is up,
and exiting the TUI tears the stack down again (a clean one-in/one-out flow).

Options:
  --continue Resume your most recent opencode session instead of starting a
             fresh one (passes opencode's own -c). No-op with --detach. If no
             previous session exists, opencode starts a new one. Alias: -c.
  --persist  Keep the stack (and its web UI) running after you exit the TUI, so
             you can resume your session later. Without it, exiting the TUI
             tears the stack down. Alias: --web.
  --detach   Boot the stack but do NOT attach the TUI (headless; the stack keeps
             running). Use this for scripted/CI runs or web-only. Alias: --no-tui.
  --podman   Add the Podman overlay (keep-id userns) for rootless Podman. This is
             auto-detected when `docker` is Podman; use the flag to force it.
  --tui      Attach the TUI (this is the default; accepted for back-compat).
  --open     Once the web UI URL is known, open it in your default browser via
             `xdg-open`. Works alongside --web/--persist/--detach. Non-fatal if
             `xdg-open` isn't available (warns and continues; the URL is always
             printed regardless).
  --doctor   Run all environment checks (Docker, compose, registry auth, .env
             keys, ports, disk space) and print one pasteable PASS/WARN/FAIL
             report, then exit — no image pull, no TUI attach. Optionally pass
             a <host-repo-path> to also check that project's derived port.
             Never prints secret values. Exits non-zero if any check FAILs.
  --status   Report on running launcher stacks, then exit — no image pull, no
             TUI attach, no .env secrets required. With a <host-repo-path>,
             re-derives that project's slug/port and reports whether it's up,
             its web UI URL, and the resume command. Without one, lists every
             running opencode-* stack (project, status, port).
  --down     Tear down the stack for <host-repo-path> via `docker compose
  --stop     down`, re-deriving the same slug / per-project env file / compose
             invocation boot uses. Aliases: --down, --stop. Safe to run even
             if nothing is up; does not require .env secrets.
  --logs     Tail (follow) the running stack's logs for <host-repo-path>, then
             exit — no image pull, no TUI attach, no LLM key required. Ctrl-C
             detaches without affecting the stack. Gracefully no-ops if
             nothing is running for that project.
  --shell    Drop into an interactive shell inside the running opencode
             container for <host-repo-path>, as the `dev` user rooted at
             /workspace (falls back to `sh` if `bash` is unavailable) — no
             image pull, no LLM key required. Gracefully no-ops if the
             container isn't running.
  --reconfigure
             Re-run the secrets setup wizard, pre-filled with your current
             .env values (press Enter on any prompt to keep it). Existing
             secrets are masked, never echoed. Leaves HOST_UID/HOST_GID and
             any unrelated keys untouched. Changes apply on your next run.
             When run from a real terminal AND whiptail or dialog is
             installed, shows a small ncurses menu editor. From a real
             terminal without either installed, shows a read-only dashboard
             plus a plain-text menu so you can edit a single setting instead
             of walking all of them (still available via the menu's "a"
             option). Piped input (scripts, CI) always gets the full linear
             walk. Set OC_CONFIG_TUI=0 to force the plain-text path even when
             whiptail/dialog is available.
  --config   Print a read-only dashboard of every .env setting, grouped by
             section, then exit — no docker, no image pull, no LLM key
             required. Secret values are never printed (shown as set/unset
             only). Takes no <host-repo-path> argument. Edit values with
             ./start.sh --reconfigure.
  --show-allowlist
             Print exactly what outbound egress the sandboxed agent is
             permitted, then exit — no image pull, no TUI attach, no LLM key
             required. The authoritative allowlist (LLM endpoint, Bitbucket,
             Jira, GitLab) is enforced inside the squid image, not this repo;
             this shows the configured LLM/Bitbucket hosts from .env plus any local
             extra-allowlist.d/*.conf extensions. Optionally takes a
             <host-repo-path> (accepted for symmetry; doesn't change the
             report). Never prints secret values.
  --help     Show this help.

Which image tag is used is controlled by IMAGE_TAG in .env (defaults to
'latest'; set it to a specific version like 0.0.2 to pin).

Why TUI-default: on the OpenCode version baked into the current image the
web/desktop UI roots the agent at / instead of /workspace (upstream bug
anomalyco/opencode#14445, #14460). The TUI is pinned to /workspace and is
correct. Re-flip to "all frontends equal" once the image ships a serve --cwd.

First run copies .env.example -> .env and prompts for your secrets. Later runs
reuse .env (edit it by hand any time).
EOF
}

# --- env-file helpers -------------------------------------------------------
# sed-escape a replacement string for use with '|' as the delimiter.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# set_env KEY VALUE — replace `KEY=...` line in $ENV_FILE in place.
set_env() {
  local key="$1" value="$2" esc
  esc="$(sed_escape "$value")"
  sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
}

# read current value of KEY from $ENV_FILE (no surrounding processing).
get_env() {
  local key="$1"
  sed -n "s|^${key}=\(.*\)$|\1|p" "$ENV_FILE" | head -n1
}

# mask_secret VALUE -> a short, non-reversible hint for use as a prompt
# default when displaying a secret ("(empty)" or "(set, press Enter to
# keep)"). Never echoes the actual value.
mask_secret() {
  local value="$1"
  if [ -z "$value" ]; then
    printf '%s' "(empty)"
  else
    printf '%s' "(set, press Enter to keep)"
  fi
}

# --- sourced libs -------------------------------------------------------------
# Resolved relative to this script's OWN location (not main()'s SCRIPT_DIR,
# which is computed too late for a top-level source and isn't set at all when
# tests merely `source` this file). Placed after the shared helpers above
# (info/warn/die, get_env/set_env, sed_escape, mask_secret) so the ordering
# contract holds: lib/config.sh depends on them and must be sourced after
# they're defined, but before main() is invoked.
__OCL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/config.sh
source "$__OCL_DIR/lib/config.sh"

# --- per-project derivations ------------------------------------------------
# derive_slug PATH — lowercase basename, non [a-z0-9_-] -> '-', collapse and
# trim dashes. Falls back to 'project' if nothing survives.
derive_slug() {
  local raw slug
  raw="$(basename -- "$1")"
  slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
  [ -n "$slug" ] || slug="project"
  printf '%s' "$slug"
}

# port_in_use PORT — return 0 if something is already listening on PORT.
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$p" >/dev/null 2>&1
  else
    # Fall back to bash /dev/tcp probe.
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1 && { exec 3>&- 3<&- 2>/dev/null; return 0; } || return 1
  fi
}

# find_free_port START [LIMIT] — echo the first free port >= START, scanning up
# to LIMIT (exclusive; default START+100). Echoes START itself if it is free.
find_free_port() {
  local p="$1" limit="${2:-$(( $1 + 100 ))}"
  while [ "$p" -lt "$limit" ] && port_in_use "$p"; do
    p=$((p + 1))
  done
  printf '%s' "$p"
}

# open_url URL — best-effort launch of the user's default browser on URL via
# `xdg-open` (Linux-only project, matching --help/README scope). Resolved via
# PATH (never a hard-coded absolute path) so tests can put a fake-bin stub
# first on PATH; OPENER lets a caller override the binary name entirely (also
# resolved via `command -v`, so it stays stubbable). Launched in the
# background so it never blocks the boot flow; missing/failing opener is a
# warning, never fatal — the URL was already printed, so the user can always
# open it by hand.
open_url() {
  local url="$1" opener="${OPENER:-xdg-open}" opener_path
  if ! opener_path="$(command -v "$opener" 2>/dev/null)"; then
    warn "--open: '$opener' not found on PATH — open this URL yourself: $url"
    return 0
  fi
  "$opener_path" "$url" >/dev/null 2>&1 &
  info "--open: launching $opener for $url"
}

# --- system-package layer helpers -------------------------------------------
# strip_pkg_comments FILE — echo only the meaningful package lines of FILE
# (drops blank lines and '#' comment lines). Missing file => no output. Mirrors
# the filter baked into Dockerfile.user-packages so detection and the build agree.
strip_pkg_comments() {
  local f="${1:-$EXTRA_PACKAGES_FILE}"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

# extra_packages_active [FILE] — exit 0 iff FILE lists at least one package
# (after stripping comments/blanks). Empty or absent => non-zero (feature off).
extra_packages_active() {
  [ -n "$(strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}")" ]
}

# extra_apt_packages [FILE] / extra_pip_packages [FILE] — split the meaningful
# lines into the apt and pip buckets, mirroring the classification baked into
# Dockerfile.user-packages. apt = lines without a `pip:` prefix (the optional
# `apt:` prefix is stripped); pip = `pip:`-prefixed lines (prefix stripped).
# Used only to report what's being baked; the build does its own parsing.
extra_apt_packages() {
  strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}" \
    | grep -vE '^[[:space:]]*pip:' \
    | sed -E 's/^[[:space:]]*apt:[[:space:]]*//;s/^[[:space:]]+//;s/[[:space:]]+$//' || true
}
extra_pip_packages() {
  strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}" \
    | grep -E '^[[:space:]]*pip:' \
    | sed -E 's/^[[:space:]]*pip:[[:space:]]*//' || true
}

# compute_base_image REGISTRY TAG — echo the registry image start.sh runs for
# `opencode` (REGISTRY:TAG, where TAG comes from IMAGE_TAG in .env). Used both as
# the access-check target and as BASE_IMAGE for the package overlay's build.
# TAG is normally a moving/pinned tag name (joined with ':', e.g. 'latest',
# '0.0.2'). For full reproducibility TAG may instead be a digest — accepted as
# either 'sha256:...' or '@sha256:...' — in which case it's joined with '@'
# instead, producing Docker's own digest-reference syntax
# (registry/image@sha256:...) rather than the invalid registry:@sha256:...
compute_base_image() {
  local registry="$1" tag="$2"
  case "$tag" in
    @sha256:*) printf '%s%s' "$registry" "$tag" ;;
    sha256:*)  printf '%s@%s' "$registry" "$tag" ;;
    *)         printf '%s:%s' "$registry" "$tag" ;;
  esac
}

# --- allowlist / digest / drift helpers --------------------------------------

# url_host URL — echo just the host[:port] component of a URL
# (https://llm.internal.example/v1 -> llm.internal.example). Best-effort string
# surgery (no curl/python dependency); echoes the input unchanged if it doesn't
# look like a URL at all.
url_host() {
  local url="$1" rest
  rest="${url#*://}"
  rest="${rest%%/*}"
  printf '%s' "$rest"
}

# list_extra_allowlist_files [DIR] — echo each *.conf file in DIR (default
# extra-allowlist.d), one per line, sorted. Empty/absent dir => no output.
list_extra_allowlist_files() {
  local dir="${1:-extra-allowlist.d}"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort || true
}

# cmd_show_allowlist [REPO_PATH] — read-only report of the egress this launcher
# knows about. Honest by construction: the AUTHORITATIVE allowlist (LLM
# endpoint, Bitbucket, Jira, GitLab) is baked into the squid image, not this repo, so
# this can only show the bits start.sh itself knows: the configured LLM/
# Bitbucket/Jira/GitLab hosts from .env, and any local extra-allowlist.d/*.conf
# drop-ins. Never requires an LLM key, never pulls or attaches anything.
cmd_show_allowlist() {
  local repo_path="${1:-}"

  echo "OpenCode Launcher egress allowlist"
  echo "==================================="
  info "the AUTHORITATIVE allowlist (LLM endpoint, Bitbucket, Jira, GitLab) is enforced"
  info "inside the squid image, not in this repo — this report shows only what"
  info "start.sh itself knows about: configured hosts + local extensions."
  echo

  if [ -f "$ENV_FILE" ]; then
    local llm_base llm_host bb_user jira_base gl_user
    llm_base="$(get_env LLM_API_BASE)"
    if [ -n "$llm_base" ]; then
      llm_host="$(url_host "$llm_base")"
      info "LLM endpoint host: $llm_host"
    else
      info "LLM endpoint host: (not configured — LLM_API_BASE is empty in $ENV_FILE)"
    fi

    bb_user="$(get_env BITBUCKET_USER)"
    if [ -n "$bb_user" ]; then
      info "Bitbucket: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "Bitbucket: not configured (no BITBUCKET_USER in $ENV_FILE)"
    fi

    jira_base="$(get_env JIRA_BASE_URL)"
    if [ -n "$jira_base" ]; then
      info "Jira: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "Jira: not configured (no JIRA_BASE_URL in $ENV_FILE)"
    fi

    gl_user="$(get_env GITLAB_USER)"
    if [ -n "$gl_user" ]; then
      info "GitLab: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "GitLab: not configured (no GITLAB_USER in $ENV_FILE)"
    fi
  else
    warn "$ENV_FILE not found — run ./start.sh once to create it. Showing local extensions only."
  fi
  echo

  local allow_dir="extra-allowlist.d"
  [ -n "$repo_path" ] && info "(note: --show-allowlist reports the launcher's own $allow_dir; the optional repo path is accepted for symmetry with other commands but does not change this report)"

  local files=() f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
  done < <(list_extra_allowlist_files "$allow_dir")

  if [ "${#files[@]}" -eq 0 ]; then
    info "local extensions ($allow_dir/*.conf): none"
  else
    info "local extensions ($allow_dir/*.conf):"
    for f in "${files[@]}"; do
      printf '  - %s\n' "$f"
      # Indent each non-comment, non-blank line of the conf file so the rules it
      # adds are visible without requiring the reader to open the file. Never
      # echoes anything from .env, so this can't leak a secret.
      grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | sed 's/^/      /' || true
    done
  fi

  return 0
}

# allowlist_summary_line — a SHORT one-line egress summary for normal boot (the
# full detail lives in --show-allowlist). Never prints secrets.
allowlist_summary_line() {
  local llm_base llm_host extra_count
  llm_base="$(get_env LLM_API_BASE 2>/dev/null || true)"
  llm_host="(unset)"
  [ -n "$llm_base" ] && llm_host="$(url_host "$llm_base")"
  extra_count="$(list_extra_allowlist_files "extra-allowlist.d" | grep -c . || true)"
  if [ "${extra_count:-0}" -gt 0 ]; then
    printf 'egress allowlist: LLM(%s) + Bitbucket/Jira/GitLab (baked into image) + %s local extension file(s) — see ./start.sh --show-allowlist' \
      "$llm_host" "$extra_count"
  else
    printf 'egress allowlist: LLM(%s) + Bitbucket/Jira/GitLab (baked into image) — see ./start.sh --show-allowlist' \
      "$llm_host"
  fi
}

# get_image_digest IMAGE — echo the resolved sha256 RepoDigest of IMAGE (the
# tag actually pulled, not just the tag name) via `docker image inspect`.
# Echoes nothing (and returns non-zero) if it can't be determined — e.g. image
# not present locally, or a registry without digest support — so callers must
# treat an empty result as "unavailable", never as an error.
get_image_digest() {
  local image="$1" out
  out="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# short_digest DIGEST — echo just the sha256:xxxxxxxx short form (12 hex chars)
# of a full image reference or digest string, for compact log lines.
short_digest() {
  local d="$1" hash
  hash="${d#*@sha256:}"
  hash="${hash#sha256:}"
  printf 'sha256:%s' "${hash:0:12}"
}

# digest_state_file SLUG — echo the path to the small per-project state file
# that records the last-seen image digest (gitignored alongside the rest of
# .envs/). Kept separate from the per-project env file because that file is
# fully regenerated (cat .env + derived keys) on every boot.
digest_state_file() {
  printf '%s/%s.digest' "$ENVS_DIR" "$1"
}

# report_digest_update SLUG NEW_DIGEST — compare NEW_DIGEST against the
# last-seen digest recorded for SLUG; if it changed (and a previous digest was
# recorded), print a short INFO nudge. Always (re)writes the new digest as the
# last-seen one. Silent when nothing changed or there's no prior record (first
# run for this project) — non-fatal either way.
report_digest_update() {
  local slug="$1" new_digest="$2" state_file prev_digest
  [ -n "$new_digest" ] || return 0
  state_file="$(digest_state_file "$slug")"
  mkdir -p "$ENVS_DIR"
  prev_digest=""
  [ -f "$state_file" ] && prev_digest="$(cat "$state_file" 2>/dev/null || true)"
  if [ -n "$prev_digest" ] && [ "$prev_digest" != "$new_digest" ]; then
    info "image updated: $(short_digest "$new_digest") (was $(short_digest "$prev_digest"))"
  fi
  printf '%s' "$new_digest" > "$state_file"
}

# env_example_keys [FILE] — echo each KEY= name found in FILE (default
# $ENV_EXAMPLE), one per line, in file order. Comments/blanks ignored.
env_example_keys() {
  local f="${1:-$ENV_EXAMPLE}"
  [ -f "$f" ] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/'
}

# check_env_drift [EXAMPLE_FILE] [ENV_FILE] — echo any key present in
# EXAMPLE_FILE but missing entirely from ENV_FILE (one per line). Reuses
# get_env's exact-line matching semantics. Never prints values — keys only.
check_env_drift() {
  local example="${1:-$ENV_EXAMPLE}" env_f="${2:-$ENV_FILE}" key
  [ -f "$example" ] || return 0
  [ -f "$env_f" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! grep -qE "^${key}=" "$env_f"; then
      printf '%s\n' "$key"
    fi
  done < <(env_example_keys "$example")
}

# --- doctor: diagnostic checks -----------------------------------------------
# Each doctor_check_* prints exactly one aligned report line and returns 0 for
# PASS/WARN or 1 for FAIL (only FAIL should flip the overall --doctor exit
# code). They are the same logic the normal boot path uses for its preflight
# checks (kept here as standalone functions so both paths share one source of
# truth and so they're unit-testable without a real Docker daemon).

# doctor_line STATUS LABEL [DETAIL] — print one aligned, pasteable report line.
doctor_line() {
  local status="$1" label="$2" detail="${3:-}"
  if [ -n "$detail" ]; then
    printf '[%-4s] %-46s %s\n' "$status" "$label" "$detail"
  else
    printf '[%-4s] %s\n' "$status" "$label"
  fi
}

# doctor_check_docker_present — is `docker` on PATH.
doctor_check_docker_present() {
  if command -v docker >/dev/null 2>&1; then
    doctor_line PASS "docker on PATH"
    return 0
  fi
  doctor_line FAIL "docker on PATH" "not found — install Docker first"
  return 1
}

# doctor_check_docker_daemon — can we talk to the Docker daemon. Mirrors the
# permission-denied / "is it running?" hinting from the normal preflight.
doctor_check_docker_daemon() {
  local out
  if out="$(docker info 2>&1)"; then
    doctor_line PASS "docker daemon reachable"
    return 0
  fi
  if printf '%s' "$out" | grep -qi 'permission denied'; then
    doctor_line FAIL "docker daemon reachable" \
      "permission denied — try: sudo usermod -aG docker \$USER && newgrp docker"
  else
    doctor_line FAIL "docker daemon reachable" "is it running? ($(printf '%s' "$out" | tail -n1))"
  fi
  return 1
}

# doctor_check_compose_v2 — the `docker compose` (v2) plugin is available.
doctor_check_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    doctor_line PASS "docker compose v2 plugin"
    return 0
  fi
  doctor_line FAIL "docker compose v2 plugin" "not available — install the Docker Compose plugin"
  return 1
}

# doctor_check_podman — informational only; a Podman `docker` shim changes
# which compose overlay is needed, but it is never a failure.
doctor_check_podman() {
  if docker --version 2>&1 | grep -qi podman; then
    doctor_line WARN "podman shim detected" "the --podman overlay will be added automatically"
  else
    doctor_line PASS "podman shim" "not detected (using real Docker)"
  fi
  return 0
}

# doctor_check_registry_access CHECK_IMAGE REGISTRY_HOST — reuses the same
# `docker manifest inspect` access check the normal boot path runs, including
# the docker-login hint on an auth failure.
doctor_check_registry_access() {
  local check_image="$1" registry_host="$2" inspect_err
  if inspect_err="$(docker manifest inspect "$check_image" 2>&1)"; then
    doctor_line PASS "registry access ($check_image)"
    return 0
  fi
  if printf '%s' "$inspect_err" | grep -qiE 'unauthorized|authentication|denied|forbidden|login'; then
    doctor_line FAIL "registry access ($check_image)" \
      "auth problem — run: docker login $registry_host"
    return 1
  fi
  doctor_line WARN "registry access ($check_image)" \
    "could not verify ($(printf '%s' "$inspect_err" | tail -n1))"
  return 0
}

# doctor_check_env_file — $ENV_FILE exists at all (a missing .env means the
# required-keys check below has nothing to read; report it as its own line).
doctor_check_env_file() {
  if [ -f "$ENV_FILE" ]; then
    doctor_line PASS "$ENV_FILE present"
    return 0
  fi
  doctor_line FAIL "$ENV_FILE present" "missing — run ./start.sh <repo> once to create it"
  return 1
}

# doctor_check_env_keys — required keys are non-empty; optional keys are
# reported as set/unset. NEVER prints a secret's value, only whether it is
# set, so this output is safe to paste into a chat or ticket.
#
# The required set is required_keys() (lib/config.sh) — the single source of
# truth shared with the ncurses first-run "Done" gate (run_tui_reconfigure
# --first-run) — read into an array here rather than hardcoded, so the two
# can't silently drift apart.
doctor_check_env_keys() {
  local rc=0
  local required=() optional=(BITBUCKET_BASE_URL BITBUCKET_USER BITBUCKET_PAT JIRA_BASE_URL JIRA_PAT GITLAB_BASE_URL GITLAB_USER GITLAB_PAT GIT_USER_NAME GIT_USER_EMAIL ENABLED_PLUGINS USER_LAYER_PATH IMAGE_TAG)
  local key val
  while IFS= read -r key; do
    [ -n "$key" ] && required+=("$key")
  done < <(required_keys)

  if [ ! -f "$ENV_FILE" ]; then
    for key in "${required[@]}"; do
      doctor_line FAIL "env: $key" "unset ($ENV_FILE missing)"
    done
    return 1
  fi

  for key in "${required[@]}"; do
    val="$(get_env "$key")"
    if [ -n "$val" ]; then
      doctor_line PASS "env: $key" "set"
    else
      doctor_line FAIL "env: $key" "unset — required"
      rc=1
    fi
  done

  for key in "${optional[@]}"; do
    val="$(get_env "$key")"
    if [ -n "$val" ]; then
      doctor_line PASS "env: $key" "set"
    else
      doctor_line WARN "env: $key" "unset (optional)"
    fi
  done

  return "$rc"
}

# doctor_check_port PORT LABEL — reuses port_in_use; a busy port is only a WARN
# (start.sh itself falls back to find_free_port), never a FAIL.
doctor_check_port() {
  local port="$1" label="$2"
  if port_in_use "$port"; then
    doctor_line WARN "port $port free ($label)" "in use — start.sh will pick the next free port"
  else
    doctor_line PASS "port $port free ($label)"
  fi
  return 0
}

# doctor_check_disk_space [PATH] — best-effort free-space check for image
# pulls. Never fails hard: no `df`, unparsable output, etc. all degrade to an
# informational WARN rather than blocking --doctor's exit code.
doctor_check_disk_space() {
  local path="${1:-.}" avail_kb
  if ! command -v df >/dev/null 2>&1; then
    doctor_line WARN "disk space" "'df' not available — skipped"
    return 0
  fi
  avail_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if ! [ "$avail_kb" -ge 0 ] 2>/dev/null; then
    doctor_line WARN "disk space" "could not determine free space — skipped"
    return 0
  fi
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt 5 ]; then
    doctor_line WARN "disk space" "${avail_gb}G free on $path — image pulls may need more"
  else
    doctor_line PASS "disk space" "${avail_gb}G free on $path"
  fi
  return 0
}

# cmd_doctor [REPO_PATH] — run every check above and print one pasteable
# report. Returns 1 if any check FAILed, 0 otherwise (WARN never fails it).
# This is a pure diagnostic: it never pulls images, never boots the stack,
# never attaches the TUI.
cmd_doctor() {
  local repo_path="${1:-}"
  local overall_rc=0
  local IMAGE_REGISTRY IMAGE_TAG REGISTRY_HOST CHECK_IMAGE

  echo "OpenCode Launcher doctor report"
  echo "================================"

  doctor_check_docker_present || overall_rc=1
  doctor_check_docker_daemon || overall_rc=1
  doctor_check_compose_v2 || overall_rc=1
  doctor_check_podman || true

  doctor_check_env_file || overall_rc=1
  doctor_check_env_keys || overall_rc=1

  IMAGE_REGISTRY="$(get_env IMAGE_REGISTRY 2>/dev/null || true)"
  if [ -n "$IMAGE_REGISTRY" ]; then
    IMAGE_TAG="$(get_env IMAGE_TAG 2>/dev/null || true)"
    [ -n "$IMAGE_TAG" ] || IMAGE_TAG="latest"
    REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
    CHECK_IMAGE="$(compute_base_image "$IMAGE_REGISTRY" "$IMAGE_TAG")"
    doctor_check_registry_access "$CHECK_IMAGE" "$REGISTRY_HOST" || overall_rc=1
  else
    doctor_line WARN "registry access" "skipped — IMAGE_REGISTRY not set"
  fi

  doctor_check_port 4096 "web UI"
  if [ -n "$repo_path" ]; then
    if [ -e "$repo_path" ] && [ -d "$repo_path" ]; then
      local abs_repo slug proj_port
      abs_repo="$(cd -- "$repo_path" >/dev/null 2>&1 && pwd)" || abs_repo="$repo_path"
      slug="$(derive_slug "$abs_repo")"
      proj_port="$(find_free_port 4096 4196)"
      doctor_check_port "$proj_port" "project: $slug"
    else
      doctor_line WARN "project port" "repo path not found/usable: $repo_path"
    fi
  fi

  doctor_check_disk_space "$SCRIPT_DIR"

  echo "================================"
  if [ "$overall_rc" -eq 0 ]; then
    info "doctor: all critical checks passed (WARN lines above are informational)."
  else
    err "doctor: one or more critical checks FAILED — see [FAIL] lines above."
  fi
  return "$overall_rc"
}

# --- per-project derivation (shared by boot, --status, --down) --------------
# derive_project_settings REPO_PATH — sets SLUG, PORT, PORT_OK, PROJECT_ENV,
# PROJECT_NAME, COMPOSE in the caller's scope, mirroring exactly what the boot
# flow computes in steps 5/6, WITHOUT pulling/booting/attaching anything.
# Shared by the boot flow and the --status/--down management commands so they
# all agree on which stack a given repo path maps to. Like boot, this
# (re)writes the per-project env file at .envs/<slug>.env so --env-file always
# matches what's actually running.
derive_project_settings() {
  local repo_path="$1"

  SLUG="$(derive_slug "$repo_path")"

  PORT=4096
  PORT_OK=1
  if port_in_use 4096; then
    PORT_OK=0
    PORT="$(find_free_port 4097 4196)"
  fi

  local user_layer_path
  user_layer_path="$(get_env USER_LAYER_PATH)"
  local compose_files
  compose_files=(-f "$__OCL_DIR/docker/docker-compose.yml")
  if [ -n "$user_layer_path" ]; then
    mkdir -p "$user_layer_path"
    user_layer_path="$(cd -- "$user_layer_path" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    compose_files+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
  fi

  mkdir -p "$ENVS_DIR"
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  {
    cat "$ENV_FILE"
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "PROJECT_SLUG=${SLUG}"
    echo "OPENCODE_PORT=${PORT}"
    echo "REPO_PATH=${repo_path}"
    [ -n "$user_layer_path" ] && echo "USER_LAYER_PATH=${user_layer_path}"
  } > "$PROJECT_ENV"

  PROJECT_NAME="opencode-${SLUG}"
  # The compose files live under docker/, but their relative paths (build
  # contexts, the :z bind mounts, env_file) must resolve from the repo root.
  # --project-directory pins that base so moving the files stays transparent.
  COMPOSE=(docker compose
    --project-directory "$__OCL_DIR"
    --env-file "$PROJECT_ENV"
    -p "$PROJECT_NAME"
    "${compose_files[@]}")
}

# --- management commands: --status / --down / --stop / --reconfigure --------
# Like --doctor, these short-circuit the normal boot flow: no image pull, no
# TUI attach.

# cmd_status [REPO_ARG] — read-only report on running launcher stacks. Never
# requires .env/secrets, never pulls or attaches anything.
cmd_status() {
  local repo_arg="${1:-}"

  if [ -z "$repo_arg" ]; then
    info "running launcher stacks:"
    local found=0 name status_str
    while IFS=$'\t' read -r name status_str; do
      [ -n "$name" ] || continue
      found=1
      printf '  %-30s %s\n' "$name" "$status_str"
    done < <(docker compose ls --all --format '{{.Name}}\t{{.Status}}' 2>/dev/null | grep '^opencode-' || true)
    if [ "$found" -eq 0 ]; then
      info "no launcher stacks found (docker compose ls shows nothing matching opencode-*)"
    fi
    return 0
  fi

  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"
  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  local slug project_name port penv running
  slug="$(derive_slug "$repo_path")"
  project_name="opencode-${slug}"

  # Re-derive the port the same way boot would, from the last-generated
  # per-project env file if there is one (best-effort guess when down).
  penv="${ENVS_DIR}/${slug}.env"
  port=""
  if [ -f "$penv" ]; then
    port="$(sed -n 's|^OPENCODE_PORT=\(.*\)$|\1|p' "$penv" | head -n1)"
  fi
  [ -n "$port" ] || port=4096

  running="$(docker compose ls --all --format '{{.Name}}\t{{.Status}}' 2>/dev/null | awk -F'\t' -v p="$project_name" '$1==p{print $2}')"

  info "project: $project_name"
  info "repo:    $repo_path"
  if [ -n "$running" ]; then
    info "status:  up ($running)"
    info "web UI:  http://localhost:${port}"
    info "resume:  docker exec -u dev -w /workspace -it ${project_name} opencode -c"
  else
    info "status:  down"
    info "resume:  ./start.sh $repo_arg"
  fi

  # Last-recorded image digest for this project (written by a previous boot's
  # report_digest_update). Read-only — just shows what was last seen, never
  # pulls or inspects anything live.
  local digest_file last_digest
  digest_file="$(digest_state_file "$slug")"
  if [ -f "$digest_file" ]; then
    last_digest="$(cat "$digest_file" 2>/dev/null || true)"
    [ -n "$last_digest" ] && info "image:   $last_digest (as of last boot)"
  fi
}

# cmd_down REPO_ARG — re-derive the same project boot would, then `compose
# down`. Never requires .env secrets to be filled in; gracefully no-ops when
# there's no .env at all (nothing could have been started).
cmd_down() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"

  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  local SLUG PORT PORT_OK PROJECT_ENV PROJECT_NAME
  local COMPOSE
  derive_project_settings "$repo_path"

  info "tearing down $PROJECT_NAME ..."
  if "${COMPOSE[@]}" down; then
    info "$PROJECT_NAME is down."
  else
    warn "compose down reported an error for $PROJECT_NAME (it may not have been running)."
  fi
}

# project_running PROJECT_NAME — exit 0 iff `docker compose ls` reports
# PROJECT_NAME as an existing stack. Shared by --logs/--shell so both agree
# with --status on what "running" means. Never pulls or attaches anything.
project_running() {
  local project_name="$1"
  docker compose ls --all --format '{{.Name}}\t{{.Status}}' 2>/dev/null \
    | awk -F'\t' -v p="$project_name" '$1==p{found=1} END{exit !found}'
}

# cmd_logs REPO_ARG — re-derive the same project boot would, then tail its
# compose logs (follow). Never requires .env secrets, never pulls an image,
# never attaches the TUI. Gracefully no-ops (not an error) when nothing is
# running for this project.
cmd_logs() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"

  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  local SLUG PORT PORT_OK PROJECT_ENV PROJECT_NAME
  local COMPOSE
  derive_project_settings "$repo_path"

  if ! project_running "$PROJECT_NAME"; then
    info "$PROJECT_NAME is not running — nothing to tail. Start it with ./start.sh $repo_arg"
    return 0
  fi

  info "tailing logs for $PROJECT_NAME (Ctrl-C detaches; the stack keeps running) ..."
  "${COMPOSE[@]}" logs -f
}

# cmd_shell REPO_ARG — re-derive the same project boot would, then drop into
# an interactive shell inside the running opencode container as the `dev`
# user rooted at /workspace. Never requires .env secrets, never pulls an
# image. Gracefully no-ops (not an error) when the container isn't running.
cmd_shell() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"

  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  local SLUG PORT PORT_OK PROJECT_ENV PROJECT_NAME
  local COMPOSE
  derive_project_settings "$repo_path"

  if ! project_running "$PROJECT_NAME"; then
    info "$PROJECT_NAME is not running — nothing to shell into. Start it with ./start.sh $repo_arg"
    return 0
  fi

  info "opening a shell in $PROJECT_NAME (exit to detach; the stack keeps running) ..."
  # Prefer bash; fall back to sh for a minimal image that lacks it. The `sh -c`
  # probe runs inside the container, so this works regardless of what's
  # installed on the host.
  if docker exec "opencode-${SLUG}" sh -c 'command -v bash' >/dev/null 2>&1; then
    exec docker exec -u dev -w /workspace -it "opencode-${SLUG}" bash
  else
    exec docker exec -u dev -w /workspace -it "opencode-${SLUG}" sh
  fi
}

# --- main flow --------------------------------------------------------------
main() {
  set -euo pipefail

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  cd "$SCRIPT_DIR"

  # --- 1. parse args --------------------------------------------------------
  # ATTACH_TUI defaults to 1: the TUI is the default frontend (see usage() for
  # why — the current image's web UI roots the agent at / not /workspace).
  # PERSIST defaults to 0: exiting the TUI tears the stack down again (a clean
  #   one-command-in/one-command-out flow). --persist/--web keeps it running
  #   (web UI stays up; resume later). --detach/--no-tui skips the TUI for
  #   headless/scripted runs and implies persist — nothing is attached, so there
  #   is nothing to tear down on exit. --tui is a back-compat no-op.
  # USE_PODMAN adds the Podman overlay (keep-id userns); auto-detected below from
  #   `docker --version`, or forced with --podman.
  # CONTINUE passes opencode's own -c to the attached TUI to resume the most
  #   recent session instead of starting a fresh one.
  local ATTACH_TUI=1
  local PERSIST=0
  local USE_PODMAN=0
  local CONTINUE=0
  local WANT_DOCTOR=0
  local WANT_STATUS=0
  local WANT_DOWN=0
  local WANT_RECONFIGURE=0
  local WANT_CONFIG=0
  local WANT_SHOW_ALLOWLIST=0
  local WANT_LOGS=0
  local WANT_SHELL=0
  local WANT_OPEN=0
  local REPO_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach|--no-tui) ATTACH_TUI=0; PERSIST=1; shift ;;
      --persist|--web)   PERSIST=1; shift ;;
      --podman) USE_PODMAN=1; shift ;;
      --tui)  ATTACH_TUI=1; shift ;;
      --continue|-c) CONTINUE=1; shift ;;
      --open) WANT_OPEN=1; shift ;;
      --doctor) WANT_DOCTOR=1; shift ;;
      --status) WANT_STATUS=1; shift ;;
      --down|--stop) WANT_DOWN=1; shift ;;
      --reconfigure) WANT_RECONFIGURE=1; shift ;;
      --config) WANT_CONFIG=1; shift ;;
      --show-allowlist) WANT_SHOW_ALLOWLIST=1; shift ;;
      --logs) WANT_LOGS=1; shift ;;
      --shell) WANT_SHELL=1; shift ;;
      --help|-h) usage; exit 0 ;;
      --)     shift; break ;;
      -*)     usage; die "unknown option: $1" ;;
      *)
        if [ -n "$REPO_ARG" ]; then
          usage; die "unexpected extra argument: $1"
        fi
        REPO_ARG="$1"; shift ;;
    esac
  done
  [ $# -gt 0 ] && [ -z "$REPO_ARG" ] && { REPO_ARG="$1"; shift; }

  # --doctor short-circuits everything else: no secrets prompt, no image pull,
  # no TUI attach. <host-repo-path> is OPTIONAL here (it only adds a check for
  # that project's derived port); plain preflight/env/registry checks run
  # either way.
  if [ "$WANT_DOCTOR" -eq 1 ]; then
    cmd_doctor "$REPO_ARG"
    exit $?
  fi

  # --show-allowlist also short-circuits everything else: no image pull, no
  # TUI attach, no LLM key required. <host-repo-path> is OPTIONAL (accepted
  # for symmetry with --doctor/--status; it doesn't change the report).
  if [ "$WANT_SHOW_ALLOWLIST" -eq 1 ]; then
    cmd_show_allowlist "$REPO_ARG"
    exit $?
  fi

  # --reconfigure/--status/--down also short-circuit everything else: no
  # image pull, no TUI attach. --reconfigure takes no repo path; --status's
  # is optional; --down requires one (cmd_down itself enforces that so the
  # error message matches the rest of the script).
  if [ "$WANT_RECONFIGURE" -eq 1 ]; then
    [ -z "$REPO_ARG" ] || { usage; die "--reconfigure takes no <host-repo-path> argument"; }
    cmd_reconfigure
    return 0
  fi

  # --config also short-circuits everything else: no docker, no image pull,
  # no LLM key required, pure read of $ENV_FILE. Takes no <host-repo-path>
  # argument, mirroring --reconfigure.
  if [ "$WANT_CONFIG" -eq 1 ]; then
    [ -z "$REPO_ARG" ] || { usage; die "--config takes no <host-repo-path> argument"; }
    cmd_config_show
    return 0
  fi

  if [ "$WANT_STATUS" -eq 1 ]; then
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
    cmd_status "$REPO_ARG"
    return 0
  fi

  if [ "$WANT_DOWN" -eq 1 ]; then
    cmd_down "$REPO_ARG"
    return 0
  fi

  # --logs/--shell also short-circuit everything else: no image pull, no
  # secrets prompt, no LLM key required. Both require a <host-repo-path>
  # (cmd_logs/cmd_shell enforce that themselves so the error message matches
  # the rest of the script).
  if [ "$WANT_LOGS" -eq 1 ]; then
    cmd_logs "$REPO_ARG"
    return 0
  fi

  if [ "$WANT_SHELL" -eq 1 ]; then
    cmd_shell "$REPO_ARG"
    return 0
  fi

  [ -n "$REPO_ARG" ] || { usage; die "missing <host-repo-path>"; }

  if [ "$CONTINUE" -eq 1 ] && [ "$ATTACH_TUI" -eq 0 ]; then
    warn "--continue has no effect with --detach (no TUI is attached)."
  fi

  # --- 2. preflight checks --------------------------------------------------
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  if ! docker info >/dev/null 2>&1; then
    local out
    out="$(docker info 2>&1 || true)"
    if printf '%s' "$out" | grep -qi 'permission denied'; then
      err "cannot talk to the Docker daemon (permission denied)."
      err "you may need: sudo usermod -aG docker \$USER && newgrp docker"
    else
      err "cannot talk to the Docker daemon. Is it running?"
      printf '%s\n' "$out" >&2
    fi
    exit 1
  fi

  # docker compose v2 (plugin) required.
  docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) not available. Install the Docker Compose plugin."

  # Podman ships a `docker` shim (podman-docker); detect it so we can add the
  # Podman overlay, which carries a keep-id userns Docker would reject. --podman
  # forces it on regardless of what `docker` reports.
  if [ "$USE_PODMAN" -eq 0 ] && docker --version 2>&1 | grep -qi podman; then
    USE_PODMAN=1
    info "detected Podman (via 'docker --version'); enabling the Podman overlay."
  fi

  # Resolve the repo path to an absolute path.
  [ -e "$REPO_ARG" ] || die "repo path does not exist: $REPO_ARG"
  [ -d "$REPO_ARG" ] || die "repo path is not a directory: $REPO_ARG"
  local REPO_PATH
  REPO_PATH="$(cd -- "$REPO_ARG" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $REPO_ARG"

  # --- 3. first-run secrets setup -------------------------------------------
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "first run: created $ENV_FILE from $ENV_EXAMPLE. Let's fill in your secrets."
    echo

    if have_tui; then
      # Real terminal + whiptail/dialog available: the ncurses editor, with
      # its first-run Done gate (required_keys() must be field_satisfied
      # before Done is allowed to finish). set_host_ids does what
      # run_setup_wizard's own first-run branch does for the linear path —
      # the ncurses path must not skip it, bind-mount permissions depend on
      # HOST_UID/HOST_GID being filled in.
      run_tui_reconfigure --first-run
      set_host_ids
    else
      run_setup_wizard            # linear path — unchanged, still does its own first-run UID/GID autofill
    fi

    echo
    info "wrote $ENV_FILE — you can edit it later in your editor."
    echo
  fi

  # --- .env.example drift check ----------------------------------------------
  # Non-fatal: new config can ship in .env.example between runs (a new optional
  # key, etc). Tell the user what's missing from their own .env rather than
  # silently ignoring it. Never prints values — keys only.
  local drift_keys
  drift_keys="$(check_env_drift "$ENV_EXAMPLE" "$ENV_FILE")"
  if [ -n "$drift_keys" ]; then
    warn "$ENV_EXAMPLE has new key(s) not in your $ENV_FILE: $(printf '%s' "$drift_keys" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "  run ./start.sh --reconfigure, or add them to $ENV_FILE by hand."
  fi

  # --- load IMAGE_REGISTRY and IMAGE_TAG from .env --------------------------
  local IMAGE_REGISTRY IMAGE_TAG
  IMAGE_REGISTRY="$(get_env IMAGE_REGISTRY)"
  [ -n "$IMAGE_REGISTRY" ] || IMAGE_REGISTRY="CHANGEME.artifactory.example/opencode-workplace"

  case "$IMAGE_REGISTRY" in
    *CHANGEME*|*internal.example*|*artifactory.example*)
      warn "IMAGE_REGISTRY looks like a placeholder ($IMAGE_REGISTRY)."
      warn "Edit .env and set your real Artifactory path, then re-run." ;;
  esac

  IMAGE_TAG="$(get_env IMAGE_TAG)"
  [ -n "$IMAGE_TAG" ] || IMAGE_TAG="latest"

  # Concise one-line egress reminder on every boot (full detail: --show-allowlist).
  info "$(allowlist_summary_line)"

  # --- optional user layer (host-editable personal agents/skills/commands) --
  # When USER_LAYER_PATH is set, add the user-layer overlay so the dir is
  # bind-mounted at /home/dev/.config/opencode. The overlay uses
  # ${USER_LAYER_PATH:?...} so it must NOT be applied when the value is empty.
  local COMPOSE_FILES
  COMPOSE_FILES=(-f "$__OCL_DIR/docker/docker-compose.yml")
  # Podman overlay (keep-id userns + no shared pod). Kept out of the base file so
  # docker-compose.yml stays Docker-valid; applied only under Podman.
  if [ "$USE_PODMAN" -eq 1 ]; then
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.podman.yml")
    info "podman: adding overlay (keep-id userns so bind-mount ownership matches)."
  fi
  local USER_LAYER_PATH
  USER_LAYER_PATH="$(get_env USER_LAYER_PATH)"
  if [ -n "$USER_LAYER_PATH" ]; then
    mkdir -p "$USER_LAYER_PATH"
    USER_LAYER_PATH="$(cd -- "$USER_LAYER_PATH" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
    info "user layer: $USER_LAYER_PATH -> /home/dev/.config/opencode"
  fi

  local REGISTRY_HOST CHECK_IMAGE
  REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
  CHECK_IMAGE="$(compute_base_image "$IMAGE_REGISTRY" "$IMAGE_TAG")"

  # --- optional system-package layer (host-built, build-time apt) -----------
  # When extra-packages.txt lists real packages, bake them into a thin LOCAL
  # image layered on the pulled opencode base. apt runs at BUILD time on this
  # host (NOT through Squid), and the base drops root->dev via gosu at runtime,
  # so the packages are usable by the agent at runtime with no runtime egress or
  # root. The overlay points opencode at a distinct local tag and overrides its
  # build: block to use Dockerfile.user-packages; it is applied last so it wins.
  # Empty/absent file => nothing here changes.
  local PKG_LAYER_ACTIVE=0 OC_BASE_IMAGE=""
  if extra_packages_active "$EXTRA_PACKAGES_FILE"; then
    PKG_LAYER_ACTIVE=1
    OC_BASE_IMAGE="$CHECK_IMAGE"
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-packages.yml")
    local apt_list pip_list
    apt_list="$(extra_apt_packages "$EXTRA_PACKAGES_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    pip_list="$(extra_pip_packages "$EXTRA_PACKAGES_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    info "system packages: baking a local opencode layer (build-time, on this host):"
    [ -n "$apt_list" ] && info "  apt: $apt_list"
    [ -n "$pip_list" ] && info "  pip: $pip_list"
    info "  fetched on this host; the locked-down runtime is unchanged."
  fi

  # --- 4. verify Artifactory access -----------------------------------------
  info "checking access to $CHECK_IMAGE ..."
  if ! docker manifest inspect "$CHECK_IMAGE" >/dev/null 2>&1; then
    local inspect_err
    inspect_err="$(docker manifest inspect "$CHECK_IMAGE" 2>&1 || true)"
    if printf '%s' "$inspect_err" | grep -qiE 'unauthorized|authentication|denied|forbidden|login'; then
      err "cannot pull $CHECK_IMAGE — looks like an auth problem."
      err "run:  docker login $REGISTRY_HOST"
      exit 1
    fi
    warn "could not verify $CHECK_IMAGE via 'docker manifest inspect'."
    warn "(continuing — 'docker compose pull' below will surface the real error)"
    warn "detail: $(printf '%s' "$inspect_err" | tail -n1)"
  fi

  # --- 5. compute per-project settings --------------------------------------
  local SLUG PORT PORT_OK
  SLUG="$(derive_slug "$REPO_PATH")"

  # Port: default to 4096, find next free port if taken (and warn loudly).
  PORT=4096
  PORT_OK=1
  if port_in_use 4096; then
    PORT_OK=0
    PORT="$(find_free_port 4097 4196)"
    warn "port 4096 in use; booting $SLUG on $PORT — web UI won't work on this port. The default TUI (no flag) works regardless."
  fi

  # --- 6. generate per-project env file (superset of .env) ------------------
  mkdir -p "$ENVS_DIR"
  local PROJECT_ENV
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  {
    cat "$ENV_FILE"
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "PROJECT_SLUG=${SLUG}"
    echo "OPENCODE_PORT=${PORT}"
    echo "REPO_PATH=${REPO_PATH}"
    # Overwrite USER_LAYER_PATH with the resolved absolute path (a later line
    # wins on duplicate keys) so the overlay interpolates an unambiguous path.
    [ -n "$USER_LAYER_PATH" ] && echo "USER_LAYER_PATH=${USER_LAYER_PATH}"
    # When the package layer is active, hand the overlay the base image to build
    # FROM (the registry image start.sh would otherwise run for opencode).
    [ -n "$OC_BASE_IMAGE" ] && echo "OC_BASE_IMAGE=${OC_BASE_IMAGE}"
  } > "$PROJECT_ENV"

  local PROJECT_NAME COMPOSE
  PROJECT_NAME="opencode-${SLUG}"
  # See the note in the management-command builder above: the compose files sit
  # under docker/, so --project-directory pins their relative paths to the root.
  COMPOSE=(docker compose
    --project-directory "$__OCL_DIR"
    --env-file "$PROJECT_ENV"
    -p "$PROJECT_NAME"
    "${COMPOSE_FILES[@]}")

  # --- 7. boot the stack ----------------------------------------------------
  # With the package layer active, opencode is a buildable LOCAL image: a blanket
  # `compose pull` would fail trying to pull that local tag. Pull only the
  # registry-backed services, then build opencode (which auto-pulls its FROM
  # base). Without the layer, behaviour is byte-for-byte unchanged.
  if [ "$PKG_LAYER_ACTIVE" -eq 1 ]; then
    info "pulling registry images (squid, oc-publish) for $PROJECT_NAME ..."
    "${COMPOSE[@]}" pull squid oc-publish
    info "building local opencode package layer for $PROJECT_NAME ..."
    "${COMPOSE[@]}" build opencode
  else
    info "pulling images for $PROJECT_NAME ..."
    "${COMPOSE[@]}" pull
  fi

  info "starting $PROJECT_NAME ..."
  "${COMPOSE[@]}" up -d

  # --- image digest (reproducibility / tamper-check anchor) ------------------
  # Print the resolved sha256 digest of the image actually in use — the tag
  # (e.g. `latest`) can silently move, the digest cannot. Best-effort: a
  # registry/runtime that doesn't expose RepoDigests just means this is
  # skipped, never a failure. Also records it so the NEXT run can report
  # whether the image changed since last time (the update nudge below).
  local IMAGE_DIGEST=""
  IMAGE_DIGEST="$(get_image_digest "$CHECK_IMAGE" 2>/dev/null || true)"
  if [ -n "$IMAGE_DIGEST" ]; then
    info "image:   $IMAGE_DIGEST"
    report_digest_update "$SLUG" "$IMAGE_DIGEST"
  fi

  # --- 8. report ------------------------------------------------------------
  echo
  info "project: $PROJECT_NAME"
  info "repo:    $REPO_PATH  ->  /workspace"
  local WEB_UI_URL="http://localhost:${PORT}"
  if [ "$PORT_OK" -eq 1 ]; then
    info "web UI:  ${WEB_UI_URL}"
  else
    info "web UI:  ${WEB_UI_URL}  (note: opencode web UI is hardwired to 4096 — only one project gets the browser UI at a time)"
  fi
  [ "$WANT_OPEN" -eq 1 ] && open_url "$WEB_UI_URL"
  # Web-UI caveat — keep this visible on every boot. Remove once the image ships
  # an `opencode serve --cwd` (upstream anomalyco/opencode#14445, #14460) and
  # the web/desktop UI roots the agent at /workspace again.
  warn "web/desktop UI caveat: the browser UI roots the agent"
  warn "  at / instead of /workspace. WORKAROUND: make your first prompt"
  warn "  'cd /workspace' so the agent works in your repo. The default TUI is"
  warn "  unaffected. Tracking: anomalyco/opencode#14445, #14460."
  echo

  # --- 9. attach the TUI (default) ------------------------------------------
  # TUI is the default frontend: docker exec pins -w /workspace, so the agent is
  # correctly rooted at the repo (unlike the current web UI — see the caveat
  # above). By default, exiting the TUI tears the stack down (clean one-in/one-
  # out, no orphaned stacks). --persist/--web keeps it running so the web UI
  # stays up and you can resume; --detach/--no-tui skips the TUI entirely
  # (headless — opencode serve is PID 1 and keeps running).
  local OC_ARGS=()
  [ "$CONTINUE" -eq 1 ] && OC_ARGS+=(-c)
  if [ "$ATTACH_TUI" -eq 1 ]; then
    if [ "$PERSIST" -eq 1 ]; then
      # Persist: keep the stack up after the TUI exits. `exec` hands the terminal
      # straight to docker exec (the stack outlives this script either way).
      info "attaching TUI (exit/Ctrl-C detaches; the stack keeps running) ..."
      info "  resume later with: docker exec -u dev -w /workspace -it opencode-${SLUG} opencode -c"
      exec docker exec -u dev \
        -e HOME=/home/dev \
        -e XDG_CONFIG_HOME=/home/dev/.config \
        -e XDG_DATA_HOME=/home/dev/.local/share \
        -w /workspace \
        -it "opencode-${SLUG}" opencode ${OC_ARGS[@]+"${OC_ARGS[@]}"}
    else
      # Default: attach, then tear the stack down once the TUI exits. No `exec`
      # here — we need to run `compose down` afterwards. `|| true` so a non-zero
      # TUI exit (e.g. Ctrl-C => 130) still reaches the teardown under set -e.
      info "attaching TUI (exit/Ctrl-C tears the stack down; pass --persist to keep it up) ..."
      docker exec -u dev \
        -e HOME=/home/dev \
        -e XDG_CONFIG_HOME=/home/dev/.config \
        -e XDG_DATA_HOME=/home/dev/.local/share \
        -w /workspace \
        -it "opencode-${SLUG}" opencode ${OC_ARGS[@]+"${OC_ARGS[@]}"} || true
      echo
      info "TUI exited — tearing down $PROJECT_NAME (pass --persist next time to keep it running) ..."
      "${COMPOSE[@]}" down
    fi
  else
    info "detached: stack is running. Attach the TUI any time with:"
    info "  docker exec -u dev -w /workspace -it opencode-${SLUG} opencode -c"
  fi
}

# Run main only when executed directly, not when sourced (e.g. by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
