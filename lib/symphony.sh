# shellcheck shell=bash
#
# lib/symphony.sh — the opt-in unattended orchestrator: `./start.sh --symphony
# <verb> <host-repo-path>`.
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file is
# safe to source for unit tests. Depends on globals defined in start.sh
# (ENV_FILE, ENVS_DIR, SYMPHONY_DIR, __OCL_DIR) and helpers from lib/core.sh
# (info/warn/err/die, get_env) and lib/project.sh (derive_slug,
# resolve_project_port, write_project_env).
#
# Design (see /home/user/OpenCode-Setup docs/SYMPHONY.md and MULTI_PROJECT.md
# for the full rationale — this is the launcher-side port, not a redesign):
#
#   .symphony/<slug>/
#   ├── symphony.env    launcher-only: SYMPHONY_GITLAB_TOKEN etc. NEVER
#   │                    reaches any container the agent can read from —
#   │                    passed to compose ONLY via --env-file (interpolation,
#   │                    a different mechanism from env_file:), and only the
#   │                    symphony service's own `environment:` block
#   │                    (docker/docker-compose.symphony.yml) actually hands
#   │                    it into a container.
#   ├── config/          mounted read-only at /config in the symphony
#   │   └── WORKFLOW.md  container — a SUBDIRECTORY of .symphony/<slug>/, one
#   │                    level below symphony.env, so that mount can never
#   │                    expose it. See symphony_preflight.
#   ├── queue/           the six file_queue state dirs (unused under
#   │                    tracker: gitlab)
#   └── workspaces/      per-item agent workspaces (used by both trackers)
#
# The AGENT's per-project env stays exactly where Wave 1 (PROJECT_ENV_FILE)
# put it: .envs/<slug>.env. That file is a superset of the root .env plus
# per-project settings (lib/project.sh write_project_env) and is handed to
# the opencode container wholesale via docker/docker-compose.yml's env_file:
# layering — so SYMPHONY_GITLAB_TOKEN must NEVER be written there, and never
# into .env/.env.example either. It lives only in .symphony/<slug>/
# symphony.env.

# --- path derivation ---------------------------------------------------------
# All of these echo a path RELATIVE to the repo root (no leading ./), mirroring
# ENVS_DIR's own convention. Pure string concatenation — no filesystem access,
# so they are safe to call from read-only verbs (check/status/logs/stop/down)
# without creating anything. Absolute forms (for compose interpolation) are
# built by prefixing $__OCL_DIR — see symphony_derive_settings.

symphony_root_dir()        { printf '%s/%s' "${SYMPHONY_DIR}" "$1"; }
symphony_config_dir()      { printf '%s/config' "$(symphony_root_dir "$1")"; }
symphony_queue_dir()       { printf '%s/queue' "$(symphony_root_dir "$1")"; }
symphony_workspaces_dir()  { printf '%s/workspaces' "$(symphony_root_dir "$1")"; }
symphony_env_file()        { printf '%s/symphony.env' "$(symphony_root_dir "$1")"; }
symphony_workflow_file()   { printf '%s/WORKFLOW.md' "$(symphony_config_dir "$1")"; }
symphony_container_name()  { printf 'opencode-symphony-%s' "$1"; }

# --- WORKFLOW.md front-matter parsing ----------------------------------------
# Same sed-only approach as the maintainer's ./scripts/symphony (no yaml
# parser dependency): the front matter is delimited by two `---` lines.

# symphony_tracker_kind WORKFLOW — echo `tracker.kind` (e.g. "file_queue" or
# "gitlab"), or empty if the file/key is missing.
symphony_tracker_kind() {
  local workflow="$1"
  [ -f "$workflow" ] || return 0
  sed -n '/^---$/,/^---$/p' "$workflow" \
    | sed -n 's/^[[:space:]]*kind:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1
}

# symphony_wf_scalar WORKFLOW KEY — first top-level `key: value` in the front
# matter, comments and surrounding quotes stripped. A commented-out line never
# matches: KEY must start the line (after indentation).
symphony_wf_scalar() {
  local workflow="$1" key="$2"
  [ -f "$workflow" ] || return 0
  sed -n '/^---$/,/^---$/p' "$workflow" \
    | sed -n "s/^[[:space:]]*${key}:[[:space:]]*\(.*\)\$/\1/p" | head -1 \
    | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//'
}

# --- generic file-scoped env reader ------------------------------------------
# env_file_get FILE KEY — like get_env (lib/core.sh) but for an arbitrary
# file, since preflight has to read values out of both the agent's per-project
# env file and symphony's own — neither of which is $ENV_FILE.
env_file_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s|^${key}=\(.*\)\$|\1|p" "$file" | tail -n1
}

# --- allowlist agreement ------------------------------------------------------
# GIT_REMOTE_ALLOWLIST (git plane, enforced by the image's git-guard) and
# GITLAB_WRITE_PROJECTS (API plane, enforced by the MCP write gate) express
# nearly the same intent in two formats, and nothing at runtime makes them
# agree. Ported closely from the maintainer's ./scripts/symphony — see
# docs/SYMPHONY.md §5-6.

# symphony_norm_dest URL|PATH — reduce a destination to `host/path`, or a bare
# project path when there is no host. Drops scheme, userinfo, port, trailing
# `.git` and surrounding slashes, and lowercases. Same normalization as
# git-guard's normalize_remote and the MCP gate's normalizeProject, so all
# three agree on what an entry means.
symphony_norm_dest() {
  local url="${1}" host rest
  url="${url%%\?*}"
  case "${url}" in
    *://*)
      url="${url#*://}"; url="${url#*@}"
      host="${url%%/*}"; rest=""
      case "${url}" in */*) rest="/${url#*/}" ;; esac
      host="${host%%:*}"; url="${host}${rest}"
      ;;
    /*|./*|../*|~*) ;;
    *:*) url="${url#*@}"; url="${url%%:*}/${url#*:}" ;;
  esac
  url="${url#/}"; url="${url%/}"; url="${url%.git}"
  printf '%s' "${url}" | tr '[:upper:]' '[:lower:]'
}

# symphony_path_of <host/a/b> — the path part, empty for a host-only entry
# (which admits every project on that host).
symphony_path_of() {
  case "${1}" in */*) printf '%s' "${1#*/}" ;; *) printf '' ;; esac
}

# symphony_covered_by NEEDLE ENTRY... — prefix match on a path-segment
# boundary, so `a/b` admits `a/b` and `a/b/c` and refuses `a/b-evil`. A
# host-only (empty) entry covers everything.
symphony_covered_by() {
  local needle="${1}" entry; shift
  for entry in "$@"; do
    [ -n "${entry}" ] || return 0
    case "${needle}/" in "${entry}"/*) return 0 ;; esac
  done
  return 1
}

# symphony_allowlist_agreement WORKFLOW ALLOW_REMOTE_GIT GIT_REMOTE_ALLOWLIST
#   ALLOW_GITLAB_WRITE GITLAB_WRITE_PROJECTS — warns (never fatal) on a
# mismatch between the two allowlists, and cross-checks both against the
# tracker's own project (the one destination the workflow tells the agent to
# clone, so both gates have to admit it).
symphony_allowlist_agreement() {
  local workflow="$1" allow_remote_git="$2" git_allowlist="$3"
  local allow_gitlab_write="$4" write_projects="$5"
  local raw e remotes=() remote_paths=() writes=()

  raw="${git_allowlist}"
  for e in ${raw//,/ }; do
    e="$(symphony_norm_dest "${e}")"
    if [ -n "${e}" ]; then remotes+=("${e}"); fi
  done
  raw="${write_projects}"
  for e in ${raw//,/ }; do
    e="$(symphony_norm_dest "${e}")"
    if [ -n "${e}" ]; then writes+=("${e}"); fi
  done
  for e in ${remotes[@]+"${remotes[@]}"}; do
    if [ -n "${e}" ]; then remote_paths+=("$(symphony_path_of "${e}")"); fi
  done

  if [ "${allow_remote_git:-0}" = "1" ] && [ "${allow_gitlab_write:-0}" = "1" ] \
     && [ "${#remotes[@]}" -gt 0 ] && [ "${#writes[@]}" -gt 0 ]; then
    for e in "${writes[@]}"; do
      if ! symphony_covered_by "${e}" ${remote_paths[@]+"${remote_paths[@]}"}; then
        warn "  ${e} is in GITLAB_WRITE_PROJECTS but no GIT_REMOTE_ALLOWLIST entry covers it"
        warn "    the agent could open a merge request there and could not push the branch for it"
      fi
    done
    for e in ${remote_paths[@]+"${remote_paths[@]}"}; do
      [ -n "${e}" ] || continue
      if ! symphony_covered_by "${e}" ${writes[@]+"${writes[@]}"}; then
        warn "  ${e} is pushable per GIT_REMOTE_ALLOWLIST but not in GITLAB_WRITE_PROJECTS"
        warn "    the agent could push a branch there and could not open the merge request"
      fi
    done
  fi

  # The tracker's own project is the one destination that definitely matters.
  if [ "$(symphony_tracker_kind "$workflow")" != "gitlab" ]; then
    return 0
  fi
  local base project dest
  base="$(symphony_norm_dest "$(symphony_wf_scalar "$workflow" base_url)")"
  project="$(symphony_norm_dest "$(symphony_wf_scalar "$workflow" project_id)")"
  if [ -z "${base}" ] || [ -z "${project}" ]; then
    return 0
  fi
  # A numeric project_id is a valid GitLab reference but carries no path, so
  # there is nothing for an allowlist to be compared against.
  case "${project}" in
    *[!0-9]*) : ;;
    *) return 0 ;;
  esac
  dest="${base}/${project}"

  if [ "${allow_remote_git:-0}" = "1" ] && [ "${#remotes[@]}" -gt 0 ]; then
    if symphony_covered_by "${dest}" "${remotes[@]}"; then
      info "  tracker project ${dest} is git-reachable and API-writable"
    else
      warn "  tracker project ${dest} is not covered by GIT_REMOTE_ALLOWLIST"
      warn "    the workflow tells the agent to clone it and git-guard will refuse"
    fi
  fi
  if [ "${allow_gitlab_write:-0}" = "1" ] && [ "${#writes[@]}" -gt 0 ]; then
    if ! symphony_covered_by "${project}" "${writes[@]}"; then
      warn "  tracker project ${project} is not in GITLAB_WRITE_PROJECTS"
      warn "    the agent could not open a merge request against the project it is working"
    fi
  fi
  return 0
}

# --- preflight ----------------------------------------------------------------
# symphony_preflight REPO_PATH SLUG PROJECT_ENV — everything here is a mistake
# that would otherwise surface as a confusing failure well after start-up, or
# worse, as an unattended agent doing something not intended. PROJECT_ENV is
# the agent's per-project env file (.envs/<slug>.env, already generated by the
# caller) — the file this checks for leaked SYMPHONY_* keys and reads
# ALLOW_REMOTE_GIT/GIT_REMOTE_ALLOWLIST/ALLOW_GITLAB_WRITE/GITLAB_WRITE_PROJECTS/
# GITLAB_PAT from, since those are exactly the values that will reach the
# agent's container. Prints PASS-style lines via info(), warnings via warn(),
# and fatal problems via err(); returns 1 (never exits/dies itself, so callers
# can decide whether a failure should abort — up() and check() both do) iff
# any fatal problem was found.
symphony_preflight() {
  local repo_path="$1" slug="$2" project_env="$3"
  local config_dir queue_dir workspaces_dir sym_env workflow
  config_dir="$(symphony_config_dir "$slug")"
  queue_dir="$(symphony_queue_dir "$slug")"
  workspaces_dir="$(symphony_workspaces_dir "$slug")"
  sym_env="$(symphony_env_file "$slug")"
  workflow="$(symphony_workflow_file "$slug")"

  local fatal=0 kind=""
  info "symphony preflight (project: ${slug})"

  if [ ! -f "$workflow" ]; then
    err "  no $workflow"
    err "    cp symphony/WORKFLOW.md.example $workflow          # file queue"
    err "    cp symphony/WORKFLOW.gitlab.md.example $workflow   # GitLab issues"
    err "    (or: ./start.sh --symphony init <host-repo-path>)"
    fatal=1
  else
    kind="$(symphony_tracker_kind "$workflow")"
    info "  workflow: $workflow (tracker: ${kind:-unknown})"
  fi

  # An AGENT-visible env file must not sit inside the directory mounted at
  # /config in the symphony container — that mount is symphony's, and
  # symphony is supposed to hold the Reporter token and nothing else. By
  # construction config_dir is a subdirectory of .symphony/<slug>/, one level
  # below symphony.env, so this should never trigger in the generated
  # layout — it guards against a file dropped there by hand (matched by
  # inode, like the maintainer's check, not by name: $ENV_FILE itself living
  # in the default config dir would be the mistake this catches).
  if [ -d "$config_dir" ]; then
    local found agent_env
    for found in "$config_dir"/.env "$config_dir"/*.env; do
      [ -f "$found" ] || continue
      for agent_env in "$ENV_FILE" "$project_env"; do
        [ -f "$agent_env" ] || continue
        if [ "$found" -ef "$agent_env" ]; then
          err "  $agent_env is inside $config_dir, which is mounted into the symphony container"
          err "    symphony would be able to read the agent's credentials"
          fatal=1
        fi
      done
    done
  fi

  # The workspaces bind mount must never be the real repo: symphony clones
  # per item and treats the directory as disposable.
  local ws_abs="$__OCL_DIR/$workspaces_dir"
  if [ "$ws_abs" = "$repo_path" ]; then
    err "  symphony's workspaces path is the repo itself ($repo_path)"
    err "    symphony treats workspaces as disposable — this must never be the real repo"
    fatal=1
  fi

  # SYMPHONY_* used to live in the root .env in the maintainer repo; here it
  # must NEVER live in an agent-visible file at all — docker-compose.yml
  # hands .env and .envs/<slug>.env to the AGENT's container wholesale via
  # env_file:, so a tracker token left in either is a token the agent can
  # read. This is the check the CLI invariant test in tests/cli.bats leans on.
  local agent_file stale
  for agent_file in "$ENV_FILE" "$project_env"; do
    [ -f "$agent_file" ] || continue
    stale="$(grep -oE '^SYMPHONY_[A-Z_]+' "$agent_file" 2>/dev/null | sort -u | tr '\n' ' ')" || true
    if [ -n "$stale" ]; then
      warn "  SYMPHONY_* key(s) in $agent_file: $stale"
      warn "    move them to $sym_env — $agent_file is handed to the agent's container"
    fi
  done

  local sym_token agent_token
  sym_token="$(env_file_get "$sym_env" SYMPHONY_GITLAB_TOKEN)"
  agent_token="$(env_file_get "$project_env" GITLAB_PAT)"
  case "$kind" in
    gitlab)
      if [ -n "$sym_token" ]; then
        info "  SYMPHONY_GITLAB_TOKEN set (should be a Reporter project token)"
      else
        err "  tracker is gitlab but SYMPHONY_GITLAB_TOKEN is empty"
        err "    set it in $sym_env — a Reporter token, never the agent's Developer token (GITLAB_PAT)"
        fatal=1
      fi
      if [ -n "$sym_token" ] && [ -n "$agent_token" ] && [ "$sym_token" = "$agent_token" ]; then
        warn "  SYMPHONY_GITLAB_TOKEN and GITLAB_PAT are the same token"
        warn "    the split only means anything if symphony's is Reporter and the agent's is Developer"
      fi
      ;;
    file_queue|"")
      if [ -n "$sym_token" ]; then
        warn "  SYMPHONY_GITLAB_TOKEN is set but the tracker is the file queue — it is unused"
      else
        info "  file queue: symphony holds no credentials"
      fi
      ;;
  esac

  local allow_remote_git git_allowlist allow_gitlab_write write_projects
  allow_remote_git="$(env_file_get "$project_env" ALLOW_REMOTE_GIT)"
  git_allowlist="$(env_file_get "$project_env" GIT_REMOTE_ALLOWLIST)"
  allow_gitlab_write="$(env_file_get "$project_env" ALLOW_GITLAB_WRITE)"
  write_projects="$(env_file_get "$project_env" GITLAB_WRITE_PROJECTS)"

  if [ "${allow_remote_git:-0}" = "1" ]; then
    if [ -n "$git_allowlist" ]; then
      info "  remote git ON, restricted to: $git_allowlist"
    else
      warn "  remote git is ON and GIT_REMOTE_ALLOWLIST is EMPTY"
      warn "    an unattended agent may push to any remote its token can reach"
    fi
  else
    info "  remote git OFF — the agent can commit but cannot push (fine for early runs)"
  fi

  if [ "${allow_gitlab_write:-0}" = "1" ] && [ -z "$write_projects" ]; then
    warn "  ALLOW_GITLAB_WRITE=1 with no GITLAB_WRITE_PROJECTS — writes are not project-limited"
  fi

  if [ -f "$workflow" ]; then
    symphony_allowlist_agreement "$workflow" "$allow_remote_git" "$git_allowlist" \
      "$allow_gitlab_write" "$write_projects"
  fi

  # Concurrency/turns come from WORKFLOW.md; surface them since they are the
  # two numbers most worth keeping small while a deployment is still new.
  if [ -f "$workflow" ]; then
    local turns conc
    turns="$(sed -n 's/^[[:space:]]*max_turns:[[:space:]]*\([0-9]*\).*/\1/p' "$workflow" | head -1)"
    conc="$(sed -n 's/^[[:space:]]*max_concurrent_agents:[[:space:]]*\([0-9]*\).*/\1/p' "$workflow" | head -1)"
    info "  max_turns=${turns:-?}  max_concurrent_agents=${conc:-?}"
    if [ -n "$conc" ] && [ "$conc" -gt 1 ] 2>/dev/null; then
      warn "  more than one agent at a time — consider 1 until you trust a full run"
    fi
  fi

  if [ "$fatal" -ne 0 ]; then
    err "preflight failed."
    return 1
  fi
  return 0
}

# --- filesystem scaffolding ---------------------------------------------------

# symphony_ensure_dirs SLUG — mkdir -p everything `up`/`add`/`init` need on
# disk. The six file_queue state dirs are only created for that tracker —
# under tracker: gitlab they would just be a second, empty, meaningless board
# next to the real one (state lives in issue labels).
symphony_ensure_dirs() {
  local slug="$1" workflow config_dir queue_dir workspaces_dir d
  config_dir="$(symphony_config_dir "$slug")"
  queue_dir="$(symphony_queue_dir "$slug")"
  workspaces_dir="$(symphony_workspaces_dir "$slug")"
  workflow="$(symphony_workflow_file "$slug")"

  mkdir -p "$config_dir" "$workspaces_dir"
  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    return 0
  fi
  for d in todo in-progress review done failed cancelled; do
    mkdir -p "${queue_dir}/${d}"
  done
}

# --- egress derivation ---------------------------------------------------------
# symphony_http_proxy WORKFLOW — echo the proxy URL symphony should use, or
# empty. Not a user setting: derived from tracker.kind exactly like the
# maintainer's ./scripts/symphony derive_egress. Both of symphony's networks
# are internal: true (docker/docker-compose.symphony.yml), so squid — reached
# at the fixed compose service hostname `squid` — is the only possible way
# out either way; on the file queue this stays empty and the container has no
# route off-host at all. An explicit SYMPHONY_HTTP_PROXY in symphony.env still
# wins.
symphony_http_proxy() {
  local workflow="$1"
  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    printf '%s' "${SYMPHONY_HTTP_PROXY:-http://squid:3128}"
  else
    printf '%s' "${SYMPHONY_HTTP_PROXY:-}"
  fi
}

# --- per-invocation settings ---------------------------------------------------
# symphony_derive_settings REPO_PATH — sets SLUG, PROJECT_ENV, PROJECT_NAME,
# PORT, COMPOSE, SYM_CONFIG_DIR, SYM_QUEUE_DIR, SYM_WORKSPACES_DIR,
# SYM_ENV_FILE, SYM_WORKFLOW, SYM_CONTAINER in the caller's scope — the
# symphony-overlay counterpart of derive_project_settings (lib/project.sh).
#
# UNLIKE project_env_for_management (which reuses .envs/<slug>.env verbatim
# once it exists, so --down/--logs/--shell never perturb a running stack's
# port), this ALWAYS regenerates it — matching cmd_run's own boot-time
# behavior instead. A symphony preflight has to see the CURRENT .env, not a
# snapshot from whenever this project last happened to be touched: the whole
# point of `check` is to catch a just-edited GITLAB_PAT/ALLOW_REMOTE_GIT/a
# leaked SYMPHONY_* key before `up` runs, not the state as of the last boot.
# This is safe to do unconditionally because resolve_project_port is already
# sticky (reuses a running project's own recorded port, or its last free one)
# — regenerating does not reassign the port out from under a running
# interactive stack for this same repo.
#
# Does NOT create any .symphony/<slug>/ directory itself; that is
# symphony_ensure_dirs's job, called only by verbs that actually start
# something (up/add/init), so `check`/`status`/`logs`/`stop`/`down` stay
# side-effect-free with respect to .symphony/.
#
# EXPORTS PROJECT_ENV_FILE, SYMPHONY_QUEUE_PATH, SYMPHONY_WORKSPACES_PATH,
# SYMPHONY_CONFIG_PATH and SYMPHONY_HTTP_PROXY — all absolute, all read by
# docker/docker-compose.symphony.yml's `${VAR}` interpolation, which (like
# env_file:) only ever sees the real process environment. Absolute for the
# same reason PROJECT_ENV_FILE is (see lib/project.sh/docs/SYNC.md): these are
# plain string concatenations against $__OCL_DIR rather than `cd`-resolved, so
# they stay correct even before the directories exist on disk (needed for
# `check`, which must not create anything).
symphony_derive_settings() {
  local repo_path="$1"

  SLUG="$(derive_slug "$repo_path")"
  mkdir -p "$ENVS_DIR"
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  PROJECT_NAME="opencode-${SLUG}"
  PROJECT_ENV_FILE="$(cd -- "$ENVS_DIR" >/dev/null 2>&1 && pwd)/${SLUG}.env" \
    || die "could not resolve ENVS_DIR"
  export PROJECT_ENV_FILE

  PORT="$(resolve_project_port "$SLUG")"
  write_project_env "$repo_path"

  SYM_CONFIG_DIR="$(symphony_config_dir "$SLUG")"
  SYM_QUEUE_DIR="$(symphony_queue_dir "$SLUG")"
  SYM_WORKSPACES_DIR="$(symphony_workspaces_dir "$SLUG")"
  SYM_ENV_FILE="$(symphony_env_file "$SLUG")"
  SYM_WORKFLOW="$(symphony_workflow_file "$SLUG")"
  SYM_CONTAINER="$(symphony_container_name "$SLUG")"

  export SYMPHONY_QUEUE_PATH SYMPHONY_WORKSPACES_PATH SYMPHONY_CONFIG_PATH
  SYMPHONY_QUEUE_PATH="$__OCL_DIR/$SYM_QUEUE_DIR"
  SYMPHONY_WORKSPACES_PATH="$__OCL_DIR/$SYM_WORKSPACES_DIR"
  SYMPHONY_CONFIG_PATH="$__OCL_DIR/$SYM_CONFIG_DIR"

  export SYMPHONY_HTTP_PROXY
  SYMPHONY_HTTP_PROXY="$(symphony_http_proxy "$SYM_WORKFLOW")"

  local compose_files=(
    -f "$__OCL_DIR/docker/docker-compose.yml"
    -f "$__OCL_DIR/docker/docker-compose.symphony.yml"
  )
  COMPOSE=(docker compose --project-directory "$__OCL_DIR" --env-file "$PROJECT_ENV")
  if [ -f "$SYM_ENV_FILE" ]; then
    COMPOSE+=(--env-file "$SYM_ENV_FILE")
  fi
  COMPOSE+=(-p "$PROJECT_NAME" "${compose_files[@]}")
}

# --- status reporting ----------------------------------------------------------
# symphony_queue_status SLUG — the board symphony is actually reading. Under
# tracker: gitlab, printing file counts from a leftover file-queue directory
# would be worse than printing nothing (it reads as pending work symphony is
# not looking at), so this reports the tracker's project/board instead.
symphony_queue_status() {
  local slug="$1" workflow queue_dir workspaces_dir container
  workflow="$(symphony_workflow_file "$slug")"
  queue_dir="$(symphony_queue_dir "$slug")"
  workspaces_dir="$(symphony_workspaces_dir "$slug")"
  container="$(symphony_container_name "$slug")"

  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    local base project
    base="$(symphony_wf_scalar "$workflow" base_url)"
    project="$(symphony_wf_scalar "$workflow" project_id)"
    info "tracker: gitlab — ${project:-<project_id unset>}"
    if [ -n "$base" ] && [ -n "$project" ]; then
      case "$project" in
        *[!0-9]*)
          info "  board: ${base%/}/${project}/-/issues?label_name[]=$(symphony_wf_scalar "$workflow" label_prefix)::todo" ;;
        *)
          info "  board: ${base%/} (project id $project)" ;;
      esac
    fi
    info "  queue state lives in the issues themselves — ./start.sh --symphony logs <host-repo-path>"
    info "workspaces: $workspaces_dir"
  else
    local d n total=0
    info "queue: $queue_dir"
    for d in todo in-progress review failed done cancelled; do
      # -d first: `find` on a missing directory exits non-zero, and under
      # `set -o pipefail` that aborts the whole script. Reachable on any
      # queue whose state dirs have not been created yet — a freshly
      # scaffolded project, or `status` before the first `up`/`add`.
      if [ ! -d "${queue_dir}/${d}" ]; then
        printf '    %-12s -\n' "$d"
        continue
      fi
      n=$(find "${queue_dir}/${d}" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      total=$((total + n))
      if [ "$n" -gt 0 ]; then printf '    %-12s %s\n' "$d" "$n"; else printf '    %-12s -\n' "$d"; fi
    done
    if [ "$total" -eq 0 ]; then
      info "queue is empty — add work with: ./start.sh --symphony add <host-repo-path> \"...\""
    fi
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    info "symphony: running"
  else
    info "symphony: NOT running"
  fi
}

# --- verbs ----------------------------------------------------------------

# _symphony_require_repo REPO_ARG — shared guard every verb starts with: dies
# on a missing/nonexistent/non-directory <host-repo-path>, else sets REPO_PATH
# (the resolved absolute path) in the caller's scope. Every cmd_symphony_*
# below declares `local REPO_PATH` before calling this, the same
# dynamic-scope "callee sets caller's local" idiom derive_project_settings
# (lib/project.sh) uses for SLUG/PORT/etc.
_symphony_require_repo() {
  local repo_arg="${1:-}"
  if [ -z "$repo_arg" ]; then usage; die "missing <host-repo-path>"; fi
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"
  REPO_PATH="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"
}

cmd_symphony_init() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"

  local SLUG root config_dir queue_dir workspaces_dir workflow sym_env
  SLUG="$(derive_slug "$REPO_PATH")"
  root="$(symphony_root_dir "$SLUG")"
  config_dir="$(symphony_config_dir "$SLUG")"
  queue_dir="$(symphony_queue_dir "$SLUG")"
  workspaces_dir="$(symphony_workspaces_dir "$SLUG")"
  workflow="$(symphony_workflow_file "$SLUG")"
  sym_env="$(symphony_env_file "$SLUG")"

  symphony_ensure_dirs "$SLUG"

  info "scaffolded $root"
  info "  config:     $config_dir"
  info "  queue:      $queue_dir (file_queue state — unused under tracker: gitlab)"
  info "  workspaces: $workspaces_dir"
  echo
  if [ -f "$workflow" ]; then
    info "WORKFLOW.md already present: $workflow"
  else
    info "next: copy a workflow template and edit it:"
    info "  cp symphony/WORKFLOW.md.example $workflow          # file queue"
    info "  cp symphony/WORKFLOW.gitlab.md.example $workflow   # GitLab issues"
    info "  \$EDITOR $workflow"
  fi
  echo
  info "gitlab tracker only — put a Reporter-role project token in $sym_env:"
  info "  echo 'SYMPHONY_GITLAB_TOKEN=<token>' >> $sym_env"
  info "  (never in .env or .envs/${SLUG}.env — see docs/SYMPHONY.md §3)"
  echo
  info "then:"
  info "  ./start.sh --symphony check $repo_arg"
  info "  ./start.sh --symphony up    $repo_arg"
}

cmd_symphony_check() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE found — run ./start.sh <repo> once first."

  local SLUG PROJECT_ENV PROJECT_NAME PORT
  local COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_WORKFLOW SYM_CONTAINER
  symphony_derive_settings "$REPO_PATH"

  if symphony_preflight "$REPO_PATH" "$SLUG" "$PROJECT_ENV"; then
    info "preflight passed."
    return 0
  fi
  return 1
}

cmd_symphony_up() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE found — run ./start.sh <repo> once first."
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local SLUG PROJECT_ENV PROJECT_NAME PORT
  local COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_WORKFLOW SYM_CONTAINER
  symphony_derive_settings "$REPO_PATH"

  symphony_preflight "$REPO_PATH" "$SLUG" "$PROJECT_ENV" \
    || die "preflight failed — nothing started. Fix the [above] and re-run, or run ./start.sh --symphony check $repo_arg for detail only."

  symphony_ensure_dirs "$SLUG"

  # Headless by design: symphony is meant to run unattended, so this brings up
  # opencode + squid (the agent's own stack) + symphony, but never oc-publish
  # (the web-UI port publisher) — there is nothing for a human to look at, and
  # skipping it avoids publishing a port this run doesn't need.
  info "pulling images for $PROJECT_NAME (opencode, squid, symphony) ..."
  "${COMPOSE[@]}" pull opencode squid symphony

  info "starting $PROJECT_NAME (opencode + symphony; no web UI) ..."
  "${COMPOSE[@]}" up -d opencode squid symphony

  echo
  symphony_queue_status "$SLUG"
  echo
  info "logs:  ./start.sh --symphony logs $repo_arg"
  info "stop:  ./start.sh --symphony stop $repo_arg"
}

cmd_symphony_logs() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  local SLUG PROJECT_ENV PROJECT_NAME PORT
  local COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_WORKFLOW SYM_CONTAINER
  symphony_derive_settings "$REPO_PATH"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SYM_CONTAINER"; then
    info "$SYM_CONTAINER is not running — nothing to tail. Start it with ./start.sh --symphony up $repo_arg"
    return 0
  fi

  info "tailing logs for $SYM_CONTAINER (Ctrl-C detaches; the stack keeps running) ..."
  "${COMPOSE[@]}" logs -f --tail=100 symphony
}

cmd_symphony_status() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"

  local SLUG
  SLUG="$(derive_slug "$REPO_PATH")"

  info "project: opencode-${SLUG}  (symphony: $(symphony_container_name "$SLUG"))"
  symphony_queue_status "$SLUG"
}

cmd_symphony_stop() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  local SLUG PROJECT_ENV PROJECT_NAME PORT
  local COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_WORKFLOW SYM_CONTAINER
  symphony_derive_settings "$REPO_PATH"

  info "stopping $SYM_CONTAINER ..."
  "${COMPOSE[@]}" stop symphony
  info "symphony stopped. opencode/squid keep running. In-flight items stay in in-progress/ and resume on restart."
}

cmd_symphony_down() {
  local repo_arg="${1:-}"
  local REPO_PATH
  _symphony_require_repo "$repo_arg"
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
  if [ ! -f "$ENV_FILE" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  local SLUG PROJECT_ENV PROJECT_NAME PORT
  local COMPOSE
  local SYM_CONFIG_DIR SYM_QUEUE_DIR SYM_WORKSPACES_DIR SYM_ENV_FILE SYM_WORKFLOW SYM_CONTAINER
  symphony_derive_settings "$REPO_PATH"

  info "tearing down $PROJECT_NAME (opencode + symphony stack) ..."
  if "${COMPOSE[@]}" down; then
    info "$PROJECT_NAME is down."
  else
    warn "compose down reported an error for $PROJECT_NAME (it may not have been running)."
  fi
}

# cmd_symphony_add REPO_ARG BODY [--id ID] [--title TITLE] — queue a new
# file_queue item. Refuses outright under tracker: gitlab, where a file in
# todo/ is read by nothing — writing one and reporting success would leave
# the caller waiting on work that was never queued.
cmd_symphony_add() {
  local repo_arg="${1:-}"
  if [ $# -ge 1 ]; then shift; fi
  local REPO_PATH
  _symphony_require_repo "$repo_arg"

  local SLUG workflow queue_dir
  SLUG="$(derive_slug "$REPO_PATH")"
  workflow="$(symphony_workflow_file "$SLUG")"
  queue_dir="$(symphony_queue_dir "$SLUG")"

  if [ "$(symphony_tracker_kind "$workflow")" = "gitlab" ]; then
    err "the tracker is gitlab — work items are GitLab issues, not files."
    err "  create an issue and label it $(symphony_wf_scalar "$workflow" label_prefix)::todo"
    exit 1
  fi

  [ "$#" -ge 1 ] || { usage; die 'usage: ./start.sh --symphony add <host-repo-path> "what the agent should do" [--id ID] [--title TITLE]'; }
  local body="$1"; shift
  local id="" title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)    id="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  symphony_ensure_dirs "$SLUG"

  [ -n "$id" ] || id="SYM-$(date +%Y%m%d-%H%M%S)"
  case "$id" in
    [A-Za-z0-9]*) : ;;
    *) die "id must start with a letter or digit: $id" ;;
  esac
  [ -n "$title" ] || title="${body%%$'\n'*}"

  local slug_title file now
  slug_title="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/-$//')"
  file="${queue_dir}/todo/${id}-${slug_title}.md"
  [ ! -e "$file" ] || die "already exists: $file"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$file" <<ITEM
---
id: ${id}
title: ${title}
priority: 5
labels: []
blocked_by: []
branch: null
attempts: 0
next_retry_at: null
session_id: null
created_at: ${now}
updated_at: ${now}
---

${body}
ITEM
  info "queued $file"
}

# cmd_symphony VERB [ARGS...] — dispatch table for `./start.sh --symphony`.
cmd_symphony() {
  local verb="${1:-}"
  if [ -z "$verb" ]; then
    usage
    die "--symphony requires a verb: check|up|logs|status|stop|down|add|init"
  fi
  shift || true

  case "$verb" in
    init)   cmd_symphony_init "$@" ;;
    check)  cmd_symphony_check "$@" ;;
    up)     cmd_symphony_up "$@" ;;
    logs)   cmd_symphony_logs "$@" ;;
    status) cmd_symphony_status "$@" ;;
    stop)   cmd_symphony_stop "$@" ;;
    down)   cmd_symphony_down "$@" ;;
    add)    cmd_symphony_add "$@" ;;
    *)
      usage
      die "--symphony: unknown verb '$verb' (expected check|up|logs|status|stop|down|add|init)" ;;
  esac
}
