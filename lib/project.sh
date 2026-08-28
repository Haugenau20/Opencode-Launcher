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

# --- host port range -------------------------------------------------------
# The window fresh port assignment may hand out: OCL_PORT_BASE first, then
# every port up to and including OCL_PORT_MAX.
#
# OCL_PORT_MAX MUST stay 4-digit (<= 9999). The opencode-pty viewer port is
# derived by prepending a literal '1' to the base port — in docker-compose.yml
# (`PTY_WEB_PORT: "1${OPENCODE_PORT}"` and the oc-publish `ports:` mapping) as
# well as in viewer_port_for below — so a 5-digit base would derive a 6-digit
# "port" that cannot be bound. Within 4096-9999 the derived viewer ports land
# in 14096-19999, which cannot collide with the base range either.
: "${OCL_PORT_BASE:=4096}"
: "${OCL_PORT_MAX:=9999}"

# viewer_port_for BASE — echo the opencode-pty web-viewer port derived from
# BASE by the docker-compose.yml oc-publish/opencode blocks: a literal '1'
# prepended to BASE (e.g. 4096 -> 14096). Only meaningful for a 4-digit BASE,
# same assumption the compose interpolation (`1${OPENCODE_PORT:-4096}`) makes
# — which is exactly why OCL_PORT_MAX above is capped at 9999.
viewer_port_for() {
  printf '1%s' "$1"
}

# port_pair_free BASE — return 0 iff BASE AND its derived viewer port
# (viewer_port_for BASE) are BOTH free. Fresh port assignment must check both:
# handing out a base port whose viewer port is already taken by some other
# process would leave oc-publish unable to publish that second port (its
# socat leg fails to bind), breaking `docker compose up` even though BASE
# itself was fine.
port_pair_free() {
  local base="$1"
  ! port_in_use "$base" && ! port_in_use "$(viewer_port_for "$base")"
}

# find_free_port START [LIMIT] — echo the first free port >= START, scanning up
# to LIMIT (exclusive; default START+100). Echoes START itself if it is free.
# "Free" means the viewer-port-aware sense (port_pair_free): a candidate whose
# derived opencode-pty viewer port is taken gets skipped too, not just the
# candidate itself.
#
# Returns 1 and echoes NOTHING when every candidate in [START, LIMIT) is taken.
# It used to fall out of the loop and echo LIMIT itself — a port it had never
# probed — so an exhausted range silently handed the caller a colliding port
# and the failure only surfaced later as an opaque `docker compose up` bind
# error. Exhaustion is a caller-visible condition now.
find_free_port() {
  local p="$1" limit="${2:-$(( $1 + 100 ))}"
  while [ "$p" -lt "$limit" ]; do
    if port_pair_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
    p=$((p + 1))
  done
  return 1
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

# pty_enabled ENV_PATH — return 0 iff ENV_PATH's ENABLED_PLUGINS list (space-
# or comma-separated, same convention as .env.example) contains the token
# "opencode-pty". Takes a file path rather than a SLUG so callers can point it
# at whichever env file is in scope (the per-project env file at boot/status
# time, or $ENV_FILE itself); a missing file or key is just "not enabled",
# never fatal.
pty_enabled() {
  local env_path="$1" enabled
  [ -f "$env_path" ] || return 1
  enabled="$(sed -n 's|^ENABLED_PLUGINS=\(.*\)$|\1|p' "$env_path" | tail -n1)"
  printf '%s' "$enabled" | grep -qE '(^|[[:space:],])opencode-pty([[:space:],]|$)'
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
#   c. else OCL_PORT_BASE (4096) if free (base AND its opencode-pty viewer port
#      14096 — see port_pair_free), otherwise the first free port in
#      OCL_PORT_BASE+1 .. OCL_PORT_MAX (find_free_port, equally viewer-aware).
#
# Only the FRESH-assignment branch (c) gets the viewer-port coupling — (a)/(b)
# are sticky reuse of a port this project itself already recorded/is running
# on, and must keep behaving exactly as before (never bounced to a different
# port just because a viewer port looks busy).
#
# Returns 1 and echoes NOTHING when branch (c) finds the whole range taken, so
# callers can report a real exhaustion instead of booting onto a port nothing
# ever probed. With the range at 4096-9999 that is ~5900 concurrent stacks, so
# in practice exhaustion means something else on the host has taken the range,
# not that you ran out of projects.
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

  if port_pair_free "$OCL_PORT_BASE"; then
    printf '%s' "$OCL_PORT_BASE"
    return 0
  fi
  find_free_port "$(( OCL_PORT_BASE + 1 ))" "$(( OCL_PORT_MAX + 1 ))"
}

# port_exhausted_msg — the one wording every caller uses when
# resolve_project_port comes back empty, so the boot flow and the read-only
# commands explain the same thing.
port_exhausted_msg() {
  printf '%s' "no free host port in ${OCL_PORT_BASE}-${OCL_PORT_MAX} (base port and its '1'-prefixed opencode-pty viewer port must BOTH be free). Free some ports, or stop stacks you no longer need with ./start.sh --down <repo>."
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

# _project_compose_files SLUG — echo (as a COMPOSE-array-ready sequence, one
# -f/path pair at a time via the caller's array-append idiom below) which
# compose overlay files apply on top of docker-compose.yml, based on the
# CURRENT USER_LAYER_PATH in $ENV_FILE and whether SLUG has a generated
# --also overlay on disk. Internal helper shared by derive_project_settings
# and write_project_env/project_env_for_management so all three agree on the
# overlay set without duplicating the USER_LAYER_PATH resolution logic. Side
# effect: mkdir -p's USER_LAYER_PATH if set (same as before this was split
# out) so the bind mount target exists. The --also overlay (lib/also.sh) is
# appended LAST, same as the boot flow (cmd_run in start.sh) — it is only
# ever included when the file already exists (i.e. a previous boot with
# --also wrote it); management commands never generate it themselves.
_project_compose_files() {
  local slug="$1"
  local user_layer_path
  user_layer_path="$(get_env USER_LAYER_PATH)"
  compose_files=(-f "$__OCL_DIR/docker/docker-compose.yml")
  if [ -n "$user_layer_path" ]; then
    mkdir -p "$user_layer_path"
    user_layer_path="$(cd -- "$user_layer_path" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    compose_files+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
  fi
  # NOTE: as with write_project_env below, the LAST statement of this function
  # must never be a bare `[ cond ] && cmd` — under set -euo pipefail a false
  # (short-circuited) `&&` list would abort the whole script here. `if ... fi`
  # returns 0 on a false condition, `&&` does not.
  local also_overlay
  also_overlay="$(also_overlay_file "$slug")"
  if [ -f "$also_overlay" ]; then
    compose_files+=(-f "$also_overlay")
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
#
# Also EXPORTS PROJECT_ENV_FILE, the absolute path to the same file PROJECT_ENV
# names. This is what carries per-project credentials INTO the container: the
# opencode service's `env_file:` directive (docker/docker-compose.yml) layers
# `${PROJECT_ENV_FILE:-.env}` on top of the shared .env, and that is compose
# `${VAR}` interpolation — it only ever reads the real process environment, so
# the value must be exported, not merely assigned.
#
# It is resolved to an ABSOLUTE path deliberately, though a relative one would
# work today: main() cd's to the launcher root, so ENVS_DIR's default `.envs`
# and --project-directory ($__OCL_DIR) happen to share a base, and env_file
# paths resolve against the latter. That agreement is a coincidence of two
# independent facts, and ENVS_DIR is overridable (the test suite points it at a
# sandbox). Resolving here costs nothing and removes the coupling — worth it
# because the failure mode is SILENT: a path that misses is swallowed by
# env_file's `required: false`, so the stack boots with no per-project
# credentials instead of an error.
derive_project_settings() {
  local repo_path="$1"

  SLUG="$(derive_slug "$repo_path")"
  PORT="$(resolve_project_port "$SLUG")" || die "$(port_exhausted_msg)"

  local compose_files
  _project_compose_files "$SLUG"

  mkdir -p "$ENVS_DIR"
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  PROJECT_NAME="opencode-${SLUG}"
  PROJECT_ENV_FILE="$(cd -- "$ENVS_DIR" >/dev/null 2>&1 && pwd)/${SLUG}.env" \
    || die "could not resolve ENVS_DIR"
  export PROJECT_ENV_FILE
  # The compose files live under docker/, but their relative paths (build
  # contexts, the :z bind mounts, env_file) must resolve from the repo root.
  # --project-directory pins that base so moving the files stays transparent.
  COMPOSE=(docker compose
    --project-directory "$__OCL_DIR"
    --env-file "$PROJECT_ENV"
    -p "$PROJECT_NAME"
    "${compose_files[@]}")
}

# project_overrides_file SLUG — echo the path to SLUG's hand-edited per-project
# overrides file (whether or not it exists). This is the ONE file in $ENVS_DIR a
# user is meant to edit: everything else there is generated and truncated on
# every boot.
#
# It exists because PROJECT_ENV_FILE would otherwise be plumbing with nothing
# feeding it. The generated .envs/<slug>.env reaches inside the container now,
# but it is rebuilt from $ENV_FILE on every run, so a value hand-written into it
# never survives to a second boot — which left "give this project its own
# credentials" expressible by the compose layer and unreachable by a user.
project_overrides_file() {
  printf '%s/%s.overrides.env' "$ENVS_DIR" "$1"
}

# write_project_env REPO_PATH — (re)generate .envs/<slug>.env for REPO_PATH:
# the per-project superset of $ENV_FILE plus this project's own overrides plus
# PROJECT_SLUG/OPENCODE_PORT/REPO_PATH/USER_LAYER_PATH. Must be called AFTER
# derive_project_settings (uses SLUG/PORT/PROJECT_ENV already set in the
# caller's scope). This is the ONLY function that writes the per-project env
# file — the boot flow calls it unconditionally on every run; --down/--logs/
# --shell only call it once, via project_env_for_management (below), when the
# file doesn't exist yet.
#
# Three layers, in this order, because the file is read last-wins:
#
#   1. $ENV_FILE            what every project shares
#   2. <slug>.overrides.env what THIS project differs on — above all scoped
#                           credentials, which cannot be shared even in
#                           principle (a GitLab project access token reaches
#                           exactly one project). A blank value here drops an
#                           inherited credential, which removes that MCP server
#                           from this stack entirely rather than disabling it.
#   3. generated identity   PROJECT_SLUG/OPENCODE_PORT/REPO_PATH — LAST on
#                           purpose, so a stale hand-edited port cannot fight
#                           resolve_project_port's sticky assignment and leave
#                           a stack unreachable at the port it printed.
write_project_env() {
  local repo_path="$1"
  local user_layer_path overrides
  user_layer_path="$(get_env USER_LAYER_PATH)"
  if [ -n "$user_layer_path" ]; then
    mkdir -p "$user_layer_path"
    user_layer_path="$(cd -- "$user_layer_path" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
  fi
  overrides="$(project_overrides_file "$SLUG")"

  mkdir -p "$ENVS_DIR"
  # NOTE: the last statement inside this group must never be a bare
  # `[ cond ] && cmd` — as the LAST command of this function, under
  # set -euo pipefail a false (short-circuited) `&&` list would abort the
  # whole script. `if ... fi` returns 0 on a false condition, `&&` does not.
  {
    cat "$ENV_FILE"
    if [ -f "$overrides" ]; then
      echo
      echo "# --- from $(basename "$overrides") ---"
      cat "$overrides"
    fi
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "# To override a value for this project, edit ${overrides}"
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
#
# Also EXPORTS PROJECT_ENV_FILE (absolute, same reasoning as
# derive_project_settings above) on both branches, so --down/--logs/--shell
# tear down or attach to the SAME per-project container environment the
# stack was booted with.
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
    _project_compose_files "$SLUG"
    PROJECT_ENV_FILE="$(cd -- "$ENVS_DIR" >/dev/null 2>&1 && pwd)/${SLUG}.env" \
      || die "could not resolve ENVS_DIR"
    export PROJECT_ENV_FILE
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

# --- docker network address pools ------------------------------------------
# The other resource a new instance can run out of, and the one that actually
# bites first. Every stack creates its own bridge networks, and each needs a
# subnet carved out of the daemon's address pools. Those pools are FAR smaller
# than they look: with no `default-address-pools` in /etc/docker/daemon.json,
# dockerd defaults to 172.17.0.0/12 split into /16s (16 subnets) plus
# 192.168.0.0/16 split into /20s (16 subnets) — 32 in total, minus docker0 and
# whatever else on the host holds one. At OCL_NETS_PER_STACK networks per
# stack that ceiling arrives after a handful of concurrent projects, and
# dockerd reports it as:
#
#   Error response from daemon: all predefined address pools have been fully
#   subnetted
#
# which says nothing about pools being small, about which stacks are holding
# them, or about the one-line daemon fix. Hence the helpers below: the boot
# flow turns that error into an explanation (see cmd_run), and --doctor warns
# before it happens.

# How many networks docker/docker-compose.yml creates per stack. Keep in sync
# with its `networks:` block.
: "${OCL_NETS_PER_STACK:=4}"

# docker_network_count — echo how many docker networks currently exist, or
# nothing if that cannot be determined. Only bridge networks consume a pool
# subnet (host/none/overlay do not), so count those.
docker_network_count() {
  docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | grep -c . || true
}

# address_pool_advice — echo the multi-line explanation + fix for a pool
# exhaustion. Kept next to the constant above so the number of networks per
# stack is quoted from one place.
address_pool_advice() {
  cat <<ADVICE
Docker ran out of network address space, not out of ports.

Every launcher stack creates ${OCL_NETS_PER_STACK} bridge networks, and each needs a subnet
from the daemon's address pools. With no default-address-pools configured,
dockerd carves only ~32 subnets in total (172.16.0.0/12 as /16s, plus
192.168.0.0/16 as /20s) — so a handful of concurrent stacks exhausts them.

Two ways forward:

  * Free some now — stop stacks you are done with:
      ./start.sh --status                 # what is running
      ./start.sh --down <repo>            # stop one
      docker network prune                # reap networks nothing is using

  * Raise the ceiling for good — give dockerd many more, smaller subnets.
    As root, put this in /etc/docker/daemon.json (merge with what is there):

      {
        "default-address-pools": [
          { "base": "172.16.0.0/12", "size": 24 },
          { "base": "192.168.0.0/16", "size": 24 }
        ]
      }

    then: sudo systemctl restart docker
    That yields 4096 + 256 subnets instead of 32. It renumbers existing
    container networks, so restart your stacks afterwards.
ADVICE
}

# compose_up_or_explain COMPOSE... — run a `docker compose up` invocation,
# streaming its output as usual, and if it fails on address-pool exhaustion
# replace the daemon's one-liner with address_pool_advice above. Any other
# failure is passed through untouched (and still fatal) — this only adds an
# explanation to the one error whose text sends people looking for a port
# conflict that isn't there.
#
# Output is tee'd rather than captured: compose's progress display is the
# normal, useful thing to watch during a pull/create, and swallowing it to
# grep afterwards would make every successful boot quieter than it is today.
compose_up_or_explain() {
  local rc=0 log
  log="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/oc-compose-up.$$")"
  # Three things this shape is load-bearing for. The pipeline is the `if`
  # CONDITION, so a non-zero compose cannot abort the script under `set -e`
  # before we react to it. The exit code comes from PIPESTATUS[0] because the
  # compose command runs in the pipe's subshell, where an `rc=$?` would never
  # reach us. And PIPESTATUS is read on BOTH branches — identical on purpose —
  # because the branch itself is the only place it is still intact: any command
  # run first, `:` included, overwrites it, and testing the pipeline's own
  # status is not enough (without `set -o pipefail` a pipeline reports tee's
  # status, which is always 0, so the `then` branch takes a compose failure).
  if "$@" 2>&1 | tee "$log"; then
    rc=${PIPESTATUS[0]}
  else
    rc=${PIPESTATUS[0]}
  fi
  if [ "$rc" -ne 0 ] && grep -qi 'address pools have been fully subnetted' "$log"; then
    rm -f "$log"
    echo >&2
    err "could not create this stack's networks."
    address_pool_advice >&2
    exit 1
  fi
  rm -f "$log"
  return "$rc"
}
