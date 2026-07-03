# shellcheck shell=bash
#
# lib/project.sh — per-project derivations: slug, free port, URL opener, settings
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

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

# recorded_port SLUG — echo the OPENCODE_PORT last written to
# .envs/<slug>.env, or nothing if there is no such file/key. Pure read, no
# side effects — safe to call from read-only commands.
recorded_port() {
  local slug="$1"
  local penv="${ENVS_DIR}/${slug}.env"
  [ -f "$penv" ] || return 0
  sed -n 's|^OPENCODE_PORT=\(.*\)$|\1|p' "$penv" | tail -n1
}

# publish_container_running SLUG — return 0 iff this project's own
# oc-publish container (container_name opencode-publish-<slug> in
# docker/docker-compose.yml) is currently up, per `docker ps`. This is the
# "does 4096-being-busy actually mean MY stack owns it" check that makes
# port resolution sticky: a project's own running stack should never be
# read as a port conflict against itself.
publish_container_running() {
  local slug="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "opencode-publish-${slug}"
}

# resolve_project_port SLUG — echo the port SLUG's stack should use. Shared
# by the boot flow (start.sh cmd_run) and derive_project_settings so every
# caller agrees on the same sticky rule:
#   a. if SLUG's own oc-publish container is currently running, reuse the
#      port recorded in .envs/<slug>.env (the running stack IS the truth —
#      never treat it as "busy" and bounce it to another port). If somehow
#      running with no recorded port, fall through to the default logic.
#   b. else if a recorded port exists and is currently free, reuse it (sticky
#      across down/up cycles, even after 4096 frees up again).
#   c. else 4096 if free, otherwise the first free port in 4097-4196
#      (find_free_port; existing fallback behavior).
resolve_project_port() {
  local slug="$1" recorded running=0
  recorded="$(recorded_port "$slug")"
  publish_container_running "$slug" && running=1

  if [ "$running" -eq 1 ] && [ -n "$recorded" ]; then
    printf '%s' "$recorded"
    return 0
  fi

  if [ "$running" -eq 0 ] && [ -n "$recorded" ] && ! port_in_use "$recorded"; then
    printf '%s' "$recorded"
    return 0
  fi

  if ! port_in_use 4096; then
    printf '%s' 4096
    return 0
  fi
  find_free_port 4097 4196
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

# _project_compose_files — echo (as a COMPOSE-array-ready sequence, one -f/path
# pair at a time via the caller's array-append idiom below) which compose
# overlay files apply on top of docker-compose.yml, based on the CURRENT
# USER_LAYER_PATH in $ENV_FILE. Internal helper shared by derive_project_settings
# and write_project_env so both agree on the overlay set without duplicating
# the USER_LAYER_PATH resolution logic. Side effect: mkdir -p's USER_LAYER_PATH
# if set (same as before this was split out) so the bind mount target exists.
_project_compose_files() {
  local user_layer_path
  user_layer_path="$(get_env USER_LAYER_PATH)"
  compose_files=(-f "$__OCL_DIR/docker/docker-compose.yml")
  if [ -n "$user_layer_path" ]; then
    mkdir -p "$user_layer_path"
    user_layer_path="$(cd -- "$user_layer_path" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    compose_files+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
  fi
}

# derive_project_settings REPO_PATH — sets SLUG, PORT, PROJECT_ENV,
# PROJECT_NAME, COMPOSE in the caller's scope: a pure COMPUTE step that never
# touches .envs/<slug>.env (or any other state) — the exact values the boot
# flow computes in steps 5/6, WITHOUT pulling/booting/attaching anything and
# WITHOUT writing anything to disk. PORT comes from resolve_project_port, so
# a currently-running or previously-recorded port is reused (sticky) rather
# than recomputed from scratch on every call. Callers that need the per-project
# env file to actually exist on disk must call write_project_env explicitly
# (see below) — derive_project_settings alone is safe to call from read-only
# commands (--status et al.) with no side effects.
derive_project_settings() {
  local repo_path="$1"

  SLUG="$(derive_slug "$repo_path")"
  PORT="$(resolve_project_port "$SLUG")"

  local compose_files
  _project_compose_files

  mkdir -p "$ENVS_DIR"
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
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

# write_project_env REPO_PATH — (re)generate .envs/<slug>.env for REPO_PATH:
# the per-project superset of $ENV_FILE plus PROJECT_SLUG/OPENCODE_PORT/
# REPO_PATH/USER_LAYER_PATH. Must be called AFTER derive_project_settings
# (uses SLUG/PORT/PROJECT_ENV already set in the caller's scope). This is the
# ONLY function that writes the per-project env file — the boot flow calls it
# unconditionally on every run; --down/--logs/--shell only call it once, via
# project_env_for_management (below), when the file doesn't exist yet.
write_project_env() {
  local repo_path="$1"
  local user_layer_path
  user_layer_path="$(get_env USER_LAYER_PATH)"
  if [ -n "$user_layer_path" ]; then
    mkdir -p "$user_layer_path"
    user_layer_path="$(cd -- "$user_layer_path" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
  fi

  mkdir -p "$ENVS_DIR"
  # NOTE: the last statement inside this group must never be a bare
  # `[ cond ] && cmd` — as the LAST command of this function, under
  # set -euo pipefail a false (short-circuited) `&&` list would abort the
  # whole script. `if ... fi` returns 0 on a false condition, `&&` does not.
  {
    cat "$ENV_FILE"
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "PROJECT_SLUG=${SLUG}"
    echo "OPENCODE_PORT=${PORT}"
    echo "REPO_PATH=${repo_path}"
    if [ -n "$user_layer_path" ]; then echo "USER_LAYER_PATH=${user_layer_path}"; fi
  } > "$PROJECT_ENV"
}

# project_env_for_management REPO_PATH — sets SLUG, PORT, PROJECT_ENV,
# PROJECT_NAME, COMPOSE for the management commands (--down/--logs/--shell).
# If .envs/<slug>.env already exists, its recorded PORT is reused VERBATIM —
# read straight out of the file, no port_in_use/docker ps re-resolution at
# all — so these commands can never move (or even reconsider) the port a
# running stack was booted with; --down in particular needs exactly the
# values the stack was booted with, not a fresh guess. Only when the file
# does not exist yet (nothing has ever been booted for this repo) does this
# fall back to derive_project_settings (fresh compute via resolve_project_port)
# and persist it via write_project_env, purely so compose has a valid
# --env-file to point at.
project_env_for_management() {
  local repo_path="$1"

  SLUG="$(derive_slug "$repo_path")"
  mkdir -p "$ENVS_DIR"
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  PROJECT_NAME="opencode-${SLUG}"

  if [ -f "$PROJECT_ENV" ]; then
    PORT="$(recorded_port "$SLUG")"
    [ -n "$PORT" ] || PORT=4096
    local compose_files
    _project_compose_files
    COMPOSE=(docker compose
      --project-directory "$__OCL_DIR"
      --env-file "$PROJECT_ENV"
      -p "$PROJECT_NAME"
      "${compose_files[@]}")
  else
    derive_project_settings "$repo_path"
    write_project_env "$repo_path"
  fi
}
