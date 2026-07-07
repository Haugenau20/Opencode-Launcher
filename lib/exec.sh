# shellcheck shell=bash
#
# lib/exec.sh — the --exec one-shot path: stdout/stderr isolation, the loading
# spinner, and the non-interactive `opencode run` + teardown.
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file is
# safe to source for unit tests. The shared boot flow (cmd_run in start.sh)
# does the actual pull/up (scoped smaller for --exec — see SERVE_WEB_UI there);
# this module owns everything that is --exec-specific.

# --- loading spinner --------------------------------------------------------
# --exec suppresses ALL launcher/opencode chatter on success (see cmd_exec
# below), so without this the terminal would sit silent for however long the
# model takes to answer — the user can't tell the difference between "working"
# and "hung". These draw a small animated spinner to the CONTROLLING TERMINAL
# ONLY (/dev/tty, overridable via OC_EXEC_TTY for tests) so it never pollutes
# stdout (the model's answer, on fd3) or the captured stderr buffer: a
# piped/CI run with no controlling terminal simply gets no spinner. Start
# returns immediately with the spinner animating in the background; stop kills
# it and erases the line. Both are no-ops (never errors) when there's no tty.
OC_EXEC_SPINNER_PID=""

# exec_spinner_start [LABEL] — begin animating a spinner (background job) on the
# controlling terminal. Records its PID in OC_EXEC_SPINNER_PID (empty when no
# terminal is available, so exec_spinner_stop becomes a no-op). Never writes to
# stdout/stderr — only to OC_EXEC_TTY (default /dev/tty).
exec_spinner_start() {
  local label="${1:-working}"
  local tty="${OC_EXEC_TTY:-/dev/tty}"
  OC_EXEC_SPINNER_PID=""
  # Only spin when the target terminal is genuinely openable for writing. A
  # bare `[ -w /dev/tty ]` isn't enough — the device node is world-writable
  # even with no controlling terminal — so probe with a real open.
  { : >"$tty"; } 2>/dev/null || return 0
  {
    local frames='|/-\' i=0
    while :; do
      printf '\r\033[36m%s\033[0m %s...\033[K' "${frames:i++%4:1}" "$label" >"$tty" 2>/dev/null || exit 0
      sleep 0.1
    done
  } &
  OC_EXEC_SPINNER_PID=$!
}

# exec_spinner_stop — stop the spinner started by exec_spinner_start and erase
# its line so the answer (or replayed diagnostics) starts clean. Safe to call
# more than once and when no spinner is running (both no-ops). Kept set -e safe
# via the `|| true` guards (a killed `wait` returns non-zero).
exec_spinner_stop() {
  local tty="${OC_EXEC_TTY:-/dev/tty}"
  [ -n "${OC_EXEC_SPINNER_PID:-}" ] || return 0
  kill "$OC_EXEC_SPINNER_PID" 2>/dev/null || true
  wait "$OC_EXEC_SPINNER_PID" 2>/dev/null || true
  OC_EXEC_SPINNER_PID=""
  printf '\r\033[K' >"$tty" 2>/dev/null || true
}

# --- --exec dispatch (stream isolation) -------------------------------------
# cmd_exec REPO_ARG ATTACH_TUI PERSIST USE_PODMAN CONTINUE WANT_OPEN EXEC_PROMPT
# [ALSO_ARGS...] — the --exec entry point, called from main() in place of a
# bare cmd_run. It sets up the output isolation, then hands off to the shared
# boot flow (cmd_run) with WANT_EXEC=1; cmd_run boots the minimal stack and, in
# its attach step, calls exec_run (below) to run the prompt and tear down.
#
# --exec output contract: on success, print EXACTLY `opencode run`'s stdout
# (the model's answer) and nothing else — no `2>/dev/null` needed — while a
# failure still surfaces its diagnostics. opencode already splits its streams
# (answer -> stdout, logs -> stderr, and in piped/non-TTY mode it emits only
# the final text), so we never match on message content. We:
#   - save the real stdout as fd3 and the real stderr as fd4;
#   - run the whole boot flow with its stdout folded onto stderr (1>&2) and
#     that stderr captured to a buffer file (2>"$buf"), so every launcher
#     info()/warn()/err() line AND every opencode log line lands in the buffer,
#     never on the terminal — exec_run sends opencode's stdout out on fd3;
#   - on EXIT, replay the buffer to the real stderr (fd4) ONLY if the run
#     failed (non-zero). Clean answer on success; boot errors and a non-zero
#     `opencode run` still print their diagnostics. Exit-code driven, so it
#     stays correct no matter what the launcher or opencode print.
# The EXIT trap also stops the spinner, a safety net for an abrupt exit
# (Ctrl-C) between spinner start and the normal stop in exec_run.
cmd_exec() {
  local repo_arg="$1" attach_tui="$2" persist="$3" use_podman="$4" continue_flag="$5" want_open="$6" exec_prompt="$7"
  shift 7
  local also_args=("$@")

  exec 3>&1 4>&2
  # OC_EXEC_ERRBUF is intentionally global so the EXIT trap (which fires while
  # exec_run's `exit` unwinds the call stack) can always see it.
  OC_EXEC_ERRBUF="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/oc-exec.$$")"
  trap 'oc_exec_rc=$?; exec_spinner_stop; { [ "$oc_exec_rc" -ne 0 ] && [ -s "$OC_EXEC_ERRBUF" ] && cat "$OC_EXEC_ERRBUF" >&4; }; rm -f "$OC_EXEC_ERRBUF"' EXIT

  cmd_run "$repo_arg" "$attach_tui" "$persist" "$use_podman" "$continue_flag" "$want_open" \
    1 "$exec_prompt" ${also_args[@]+"${also_args[@]}"} 2>"$OC_EXEC_ERRBUF" 1>&2
}

# --- --exec run (non-interactive one-shot) ----------------------------------
# exec_run PROJECT_NAME EXEC_PROMPT CONTINUE PERSIST [COMPOSE...] — run the
# one-shot prompt inside the already-booted PROJECT_NAME container (container
# name == project name), then (unless PERSIST) tear the stack down with the
# passed-through COMPOSE invocation. Ends with `exit <rc>` carrying opencode's
# own exit code. Called by cmd_run's attach step for the --exec path.
#
# `-i` but deliberately NOT `-t` — output must pipe cleanly for scripting.
# --continue prepends opencode's own `-c` (resume most recent session) ahead of
# the prompt.
#
# stdin needs care. `docker exec -i` binds opencode's stdin to whatever the
# launcher was started with, and `opencode run` drains stdin for any piped
# prompt context. When the launcher is attached to an interactive terminal that
# pipe never closes, so the run blocks forever waiting for an EOF that can't
# come — opencode prints its startup lines and then hangs. So only forward
# stdin when it's genuinely piped/redirected into the launcher
# (`data | ./start.sh --exec …` still reaches opencode); on a TTY, hand opencode
# /dev/null instead so it sees an immediate EOF and runs the prompt alone.
#
# Output isolation: cmd_exec has folded the launcher's own stdout onto stderr,
# captured that stderr to a buffer, and saved the real stdout as fd3. So here we
# send opencode's stdout straight to fd3 (`1>&3`) — that's the answer, and the
# only thing on the real stdout — and leave its stderr alone: it flows into the
# same buffer as the launcher chatter and (on success) is discarded, or (on
# failure) replayed. No message-content matching.
#
# rc capture must survive `set -euo pipefail`: guard every step with `|| ...`
# so a nonzero `opencode run` (or teardown) never aborts the script before we
# can exit with the RIGHT code.
exec_run() {
  local project_name="$1" prompt="$2" continue_flag="$3" persist="$4"
  shift 4
  local compose=("$@")

  local oc_args=()
  [ "$continue_flag" -eq 1 ] && oc_args+=(-c)

  info "exec: running one-shot prompt in $project_name ..."
  local rc=0
  local exec_cmd=(docker exec -u dev
    -e HOME=/home/dev
    -e XDG_CONFIG_HOME=/home/dev/.config
    -e XDG_DATA_HOME=/home/dev/.local/share
    -w /workspace
    -i "$project_name" opencode run ${oc_args[@]+"${oc_args[@]}"} "$prompt")

  exec_spinner_start "running your prompt in $project_name (this can take a bit)"
  if [ -t 0 ]; then
    "${exec_cmd[@]}" </dev/null 1>&3 || rc=$?
  else
    "${exec_cmd[@]}" 1>&3 || rc=$?
  fi
  exec_spinner_stop

  if [ "$persist" -eq 1 ]; then
    info "exec finished (rc=$rc) — --persist: leaving $project_name running."
  else
    info "exec finished (rc=$rc) — tearing down $project_name (pass --persist to keep it running) ..."
    "${compose[@]}" down || true
  fi
  exit "$rc"
}
