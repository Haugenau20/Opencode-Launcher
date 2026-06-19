# shellcheck shell=bash
#
# lib/commands.sh — lifecycle subcommands: --status / --down / --logs / shell
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# Like --doctor, these short-circuit the normal boot flow: no image pull, no
# TUI attach.

# compose_ls_pairs — emit one "<project-name><TAB><status>" line per compose
# project. Sourced by every command that needs to know which stacks exist.
#
# Note `docker compose ls --format` only accepts `table` or `json` — NOT a Go
# template like `docker compose ps` does. Passing `--format '{{.Name}}...'`
# silently yields nothing on a current compose, which is why --status/--logs/
# --shell all reported "no stacks" even with one running. So we ask for json
# and pull the fields out by key: no jq dependency, order-independent, and
# robust to compose's column formatting.
compose_ls_pairs() {
  # Trailing `|| true` keeps this best-effort: a daemon-down `docker compose ls`
  # (or simply no stacks) must yield empty output and success, never abort the
  # caller under `set -euo pipefail`.
  docker compose ls --all --format json 2>/dev/null \
    | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g' \
    | while IFS= read -r _obj; do
        local name status
        name="$(printf '%s' "$_obj"   | sed -n 's/.*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        status="$(printf '%s' "$_obj" | sed -n 's/.*"Status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        if [ -n "$name" ]; then printf '%s\t%s\n' "$name" "$status"; fi
      done || true
}

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
    done < <(compose_ls_pairs | grep '^opencode-' || true)
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

  running="$(compose_ls_pairs | awk -F'\t' -v p="$project_name" '$1==p{print $2}')"

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
  compose_ls_pairs \
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
