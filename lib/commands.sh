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
  runtime_projects
}

# Resolve the binding before any management operation consults containers.
select_project_runtime() {
  runtime_select "${OCL_ENGINE_REQUESTED:-}" "$(derive_slug "$1")" || return $?
  runtime_validate
}

# cmd_status [REPO_ARG] — read-only report on running launcher stacks. Never
# requires .env/secrets, never pulls or attaches anything.
cmd_status() {
  local repo_arg="${1:-}"

  if [ -z "$repo_arg" ]; then
    info "running launcher stacks:"
    local found=0 name status_str binding bound_slug projects seen='|' failed=0
    local bindings=("$ENVS_DIR"/*.runtime)
    if [ -z "${OCL_ENGINE_REQUESTED:-}" ] && [ -f "${bindings[0]}" ]; then
      for binding in "${bindings[@]}"; do
        bound_slug="$(basename -- "$binding" .runtime)"
        seen+="opencode-$bound_slug|"
        found=1
        (
          runtime_select "" "$bound_slug" && runtime_validate || exit $?
          local state
          state="$(runtime_projects | awk -F '\t' -v p="opencode-$bound_slug" '$1==p {print $2}')" || exit $?
          printf '  %-30s %s [%s]\n' "opencode-$bound_slug" "${state:-down}" "$RUNTIME_ENGINE"
        ) || failed=1
      done
    fi
    # Also show legacy projects from the current default engine. A new binding
    # must not make older, unbound stacks disappear from the status overview.
    runtime_select "${OCL_ENGINE_REQUESTED:-}" || return $?
    runtime_validate || return $?
    projects="$(compose_ls_pairs)" || return $?
    while IFS=$'\t' read -r name status_str; do
      [[ "$name" == opencode-* ]] || continue
      case "$seen" in *"|$name|"*) continue ;; esac
      found=1
      printf '  %-30s %s\n' "$name" "$status_str"
    done <<< "$projects"
    if [ "$found" -eq 0 ]; then
      info "no launcher stacks found (nothing matching opencode-*)"
    fi
    return "$failed"
  fi

  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"
  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  local slug project_name port penv running
  select_project_runtime "$repo_path" || return $?
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
  local is_running=0
  if [[ "$running" =~ running\([1-9][0-9]*\) ]]; then
    is_running=1
    info "status:  up ($running)"
    # Attached TUIs (lib/attach.sh). Worth reporting because it is what decides
    # whether `./start.sh` on this repo will tear the stack down when its TUI
    # exits: the last one out does, anyone else does not.
    local tuis
    tuis="$(attach_count "$slug")"
    info "TUIs:    $tuis attached"
    info "web UI:  http://localhost:${port}"
    # opencode-pty viewer — same condition as the boot report (see pty_enabled,
    # lib/project.sh): only worth reporting when this project has the plugin
    # enabled; nothing is listening on it until it's started in the TUI.
    if pty_enabled "$penv"; then
      info "viewer:  http://localhost:1${port}  (start it in the TUI with /pty-open-background-spy)"
    fi
    info "resume:  ./start.sh --continue $repo_arg"
  else
    if [ -n "$running" ]; then info "status:  stopped ($running)"; else info "status:  down"; fi
    info "resume:  ./start.sh $repo_arg"
  fi

  # --also extra mounts, parsed back out of the generated overlay (if this
  # project was last booted with any). Shown regardless of up/down — it
  # reports what the NEXT boot will reuse, same as the image digest below.
  also_mount_lines "$(also_mounts_from_overlay "$slug")"

  # Last-recorded image digest for this project (written by a previous boot's
  # report_digest_update). Read-only — just shows what was last seen, never
  # pulls or inspects anything live.
  local digest_file last_digest
  digest_file="$(digest_state_file "$slug")"
  if [ -f "$digest_file" ]; then
    last_digest="$(cat "$digest_file" 2>/dev/null || true)"
    [ -n "$last_digest" ] && info "image:   $last_digest (as of last boot)"
  fi

  # MCP servers the image actually wired up — entirely best-effort, and only
  # meaningful while the container is running (a down container can't be
  # exec'd into). Any failure (no jq, exec fails, file missing) prints
  # nothing, never an error — see mcp_status_line.
  #
  # NOTE: as with write_project_env, the LAST statement of this function must
  # never be a bare `[ cond ] && cmd` (or an `if` whose only branch ends in
  # one) — under set -euo pipefail, cmd_status is called as a bare statement
  # in main() (before its own `return 0`), so a false/short-circuited `&&`
  # here would abort the whole script on the (common!) down/no-mcps case
  # rather than just skipping the print. `if ... fi` returns 0 either way.
  if [ "$is_running" -eq 1 ]; then
    local mcps_line
    mcps_line="$(mcp_status_line "$project_name")"
    if [ -n "$mcps_line" ]; then
      info "$mcps_line"
    fi
  fi
}

# mcp_status_line PROJECT_NAME — echo "mcps:    <comma-separated names>" (or
# "mcps:    (none configured)") read from the running PROJECT_NAME container's
# own /home/dev/.config/opencode/opencode.json via `jq`, or nothing at all on
# ANY failure (container gone, no jq in the image, file missing, malformed
# JSON, etc.) — this is a best-effort convenience, never an error condition.
# The `|| rc=$?` idiom keeps this set -e safe regardless of caller context.
mcp_status_line() {
  local project_name="$1" out rc=0
  out="$(runtime_exec "$project_name" jq -r '(.mcp // {}) | keys | join(", ")' \
    /home/dev/.config/opencode/opencode.json 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  if [ -n "$out" ]; then
    printf 'mcps:    %s' "$out"
  else
    printf 'mcps:    (none configured)'
  fi
}

# cmd_down REPO_ARG — reuse the recorded per-project settings, then `compose
# down`. Never requires .env secrets to be filled in; gracefully no-ops when
# there's no .env at all (nothing could have been started). Reuses
# .envs/<slug>.env VERBATIM when it already exists — via
# project_env_for_management, it does NOT recompute the port; down needs the
# exact values the stack was booted with, not a fresh guess (see
# resolve_project_port in lib/project.sh for why re-deriving here would be
# wrong: another process could have taken the recorded port in the meantime).
cmd_down() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  local repo_path
  if [ -d "$repo_arg" ]; then
    repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"
  else
    repo_path="$(realpath -m -- "$repo_arg")" || return $?
    [ -f "$(runtime_binding_file "$(derive_slug "$repo_path")")" ] \
      || die "repo path does not exist and has no saved runtime binding: $repo_arg"
  fi

  if [ ! -f "$ENV_FILE" ] && [ ! -f "${ENVS_DIR}/$(derive_slug "$repo_path").env" ] \
    && [ ! -f "$(runtime_binding_file "$(derive_slug "$repo_path")")" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  runtime_lock_project "$(derive_slug "$repo_path")" || return $?
  select_project_runtime "$repo_path" || return $?
  # Dynamic outputs from project_env_for_management.
  # shellcheck disable=SC2034
  local SLUG PORT PROJECT_ENV PROJECT_NAME
  local COMPOSE
  project_env_for_management "$repo_path" || return $?

  # An explicit --down is a deliberate teardown, so it goes through even with
  # TUIs attached (unlike a TUI exiting, which stands down for the others) —
  # but say what it is about to kill, since those sessions are in other
  # terminals and their owner may not be the one typing this.
  local attached
  attached="$(attach_count "$SLUG")"
  if [ "$attached" -gt 0 ]; then
    warn "$attached TUI(s) are attached to $PROJECT_NAME — --down closes them too."
  fi

  info "tearing down $PROJECT_NAME ..."
  local down_rc=0
  if "${COMPOSE[@]}" down; then
    info "$PROJECT_NAME is down."
  else
    down_rc=$?
    warn "compose down reported an error for $PROJECT_NAME (it may not have been running)."
  fi
  runtime_release_project
  return "$down_rc"
}

# project_running PROJECT_NAME — exit 0 iff `docker compose ls` reports
# PROJECT_NAME as an existing stack. Shared by --logs/--shell so both agree
# with --status on what "running" means. Never pulls or attaches anything.
project_running() {
  local project_name="$1"
  compose_ls_pairs \
    | awk -F'\t' -v p="$project_name" '$1==p && $2 ~ /running\([1-9][0-9]*\)/ {found=1} END{exit !found}'
}

project_exists() {
  compose_ls_pairs | awk -F'\t' -v p="$1" '$1==p{found=1} END{exit !found}'
}

# cmd_logs REPO_ARG — reuse the recorded per-project settings, then tail its
# compose logs (follow). Never requires .env secrets, never pulls an image,
# never attaches the TUI. Gracefully no-ops (not an error) when nothing is
# running for this project. Read-only: via project_env_for_management, this
# never rewrites an existing .envs/<slug>.env (only generates one, once, if
# it's missing) — a --logs call must never perturb the port a running stack
# is actually using.
cmd_logs() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"

  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  if [ ! -f "$ENV_FILE" ] && [ ! -f "${ENVS_DIR}/$(derive_slug "$repo_path").env" ] \
    && [ ! -f "$(runtime_binding_file "$(derive_slug "$repo_path")")" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  select_project_runtime "$repo_path" || return $?
  # Dynamic outputs from project_env_for_management.
  # shellcheck disable=SC2034
  local SLUG PORT PROJECT_ENV PROJECT_NAME
  local COMPOSE
  project_env_for_management "$repo_path" || return $?

  if ! project_exists "$PROJECT_NAME"; then
    info "$PROJECT_NAME is not running — nothing to tail. Start it with ./start.sh $repo_arg"
    return 0
  fi

  info "tailing logs for $PROJECT_NAME (Ctrl-C detaches; the stack keeps running) ..."
  "${COMPOSE[@]}" logs -f
}

# cmd_shell REPO_ARG — reuse the recorded per-project settings, then drop into
# an interactive shell inside the running opencode container as the `dev`
# user rooted at /workspace. Never requires .env secrets, never pulls an
# image. Gracefully no-ops (not an error) when the container isn't running.
# Read-only: via project_env_for_management, this never rewrites an existing
# .envs/<slug>.env (only generates one, once, if it's missing).
cmd_shell() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; die "missing <host-repo-path>"; }
  [ -e "$repo_arg" ] || die "repo path does not exist: $repo_arg"
  [ -d "$repo_arg" ] || die "repo path is not a directory: $repo_arg"

  local repo_path
  repo_path="$(cd -- "$repo_arg" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $repo_arg"

  if [ ! -f "$ENV_FILE" ] && [ ! -f "${ENVS_DIR}/$(derive_slug "$repo_path").env" ] \
    && [ ! -f "$(runtime_binding_file "$(derive_slug "$repo_path")")" ]; then
    info "no $ENV_FILE found — nothing has ever been started for this launcher checkout."
    return 0
  fi

  select_project_runtime "$repo_path" || return $?
  # Dynamic outputs from project_env_for_management.
  # shellcheck disable=SC2034
  local SLUG PORT PROJECT_ENV PROJECT_NAME
  local COMPOSE
  project_env_for_management "$repo_path" || return $?

  if ! project_running "$PROJECT_NAME"; then
    info "$PROJECT_NAME is not running — nothing to shell into. Start it with ./start.sh $repo_arg"
    return 0
  fi

  info "opening a shell in $PROJECT_NAME (exit to detach; the stack keeps running) ..."
  # Prefer bash; fall back to sh for a minimal image that lacks it. The `sh -c`
  # probe runs inside the container, so this works regardless of what's
  # installed on the host.
  if runtime_exec "opencode-${SLUG}" sh -c 'command -v bash' >/dev/null 2>&1; then
    runtime_exec_replace -u dev -w /workspace -it "opencode-${SLUG}" bash
  else
    runtime_exec_replace -u dev -w /workspace -it "opencode-${SLUG}" sh
  fi
}
