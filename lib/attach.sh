# shellcheck shell=bash
#
# lib/attach.sh — the attached-TUI registry: who is currently sitting in a TUI
# on a given project's stack
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.
#
# WHY THIS EXISTS
#
# Two terminals running `./start.sh <same repo>` derive the same slug, so they
# get the same compose project and the same `opencode-<slug>` container. That
# is intentional — the second run attaches a second TUI into the running
# container rather than booting a rival stack — but two things in the boot flow
# used to make the second run destroy the first one's session:
#
#   1. The default (non---persist) TUI path runs `compose down` when the TUI
#      exits. Whoever quit FIRST tore the stack down under everyone else.
#   2. `compose up -d` recreates the opencode container whenever the effective
#      compose config changed since it was started — and a second run with
#      different flags changes it (most sharply: no --also this time deletes
#      the previous run's overlay). The recreate kills the attached TUI.
#
# Both need the same fact: how many TUIs are attached to this project right
# now? That is what this registry answers, across separate terminals, via
# $ENVS_DIR/<slug>.attach.d/<pid>.lock — one file per attached TUI.
#
# Liveness is an flock held on the slot file for the TUI's lifetime, NOT the
# presence of the file. A lock is owned by the open file description, so the
# kernel drops it when the holder exits *however* it exits — Ctrl-C, SIGKILL,
# a closed terminal, a crash. That is the whole reason for the lock: a plain
# pidfile would strand a slot on `kill -9` and leave the stack un-tearable-down
# forever. Stale slot files are pruned as they are noticed (see attach_count),
# so the directory self-heals; it never needs cleaning by hand.
#
# The fd survives `exec`, which the --persist path uses to hand the terminal
# straight to `docker exec` — so that TUI keeps holding its slot for as long as
# it runs, with no shell of ours left alive to do bookkeeping.

# The fd each process holds its own slot open on. High enough not to collide
# with the launcher's other redirections (exec_run uses fd3/fd4).
OCL_ATTACH_FD=9

# attach_dir SLUG — echo the directory holding SLUG's TUI slots (whether or not
# it exists). Lives under $ENVS_DIR, which is already gitignored and already
# per-launcher-checkout.
attach_dir() {
  printf '%s/%s.attach.d' "$ENVS_DIR" "$1"
}

# _attach_flock — echo the path to flock(1), or nothing if it isn't installed.
# Resolved per call (not cached) so tests can put a stub first on PATH.
_attach_flock() {
  command -v flock 2>/dev/null || true
}

# _attach_slot_live PATH — return 0 iff some process still holds PATH's lock.
#
# The probe IS the acquisition: open the file on a fresh descriptor and try to
# take the lock non-blockingly. Succeeding means nobody else holds it, i.e. the
# slot is stale. It runs in a subshell so the descriptor — and with it the lock
# we just took — is dropped immediately either way.
#
# Without flock(1) this degrades to a `kill -0` on the pid the slot is named
# after. That is weaker (pid reuse can read a stale slot as live, which errs
# toward leaving a stack up rather than tearing one down under someone), but it
# keeps the registry working on a host with no util-linux.
_attach_slot_live() {
  local slot="$1" flock_bin pid
  [ -e "$slot" ] || return 1
  flock_bin="$(_attach_flock)"
  if [ -n "$flock_bin" ]; then
    if ( exec 8<"$slot" && "$flock_bin" -n -x 8 ) >/dev/null 2>&1; then
      return 1   # lock was free -> the holder is gone -> stale slot
    fi
    return 0
  fi
  pid="$(basename -- "$slot")"
  pid="${pid%.lock}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# attach_count SLUG — echo how many TUIs are attached to SLUG's stack right
# now, deleting any slot whose holder has died on the way past. Counts THIS
# process's own slot too when it holds one, so a caller deciding whether it is
# the last one out must attach_release first and count after.
attach_count() {
  local slug="$1" dir slot n=0
  dir="$(attach_dir "$slug")"
  if [ ! -d "$dir" ]; then
    printf '0'
    return 0
  fi
  for slot in "$dir"/*.lock; do
    [ -e "$slot" ] || continue
    if _attach_slot_live "$slot"; then
      n=$((n + 1))
    else
      rm -f "$slot"
    fi
  done
  printf '%s' "$n"
}

# attach_register SLUG — claim a TUI slot for this process and hold it until
# attach_release (or until this process dies, whichever comes first). Sets
# OCL_ATTACH_SLOT to the slot's path. Idempotent per process: a second call
# re-uses the slot already held rather than opening a second one.
attach_register() {
  local slug="$1" dir flock_bin
  [ -z "${OCL_ATTACH_SLOT:-}" ] || return 0
  dir="$(attach_dir "$slug")"
  mkdir -p "$dir"
  OCL_ATTACH_SLOT="${dir}/$$.lock"
  : > "$OCL_ATTACH_SLOT"
  eval "exec ${OCL_ATTACH_FD}>>\"\$OCL_ATTACH_SLOT\"" || return 0
  flock_bin="$(_attach_flock)"
  if [ -n "$flock_bin" ]; then
    "$flock_bin" -n -x "$OCL_ATTACH_FD" 2>/dev/null || true
  fi
}

# attach_release SLUG — give up this process's slot: drop the lock (by closing
# the descriptor) and remove the file. A no-op when no slot is held, so it is
# safe to call unconditionally on any exit path.
attach_release() {
  [ -n "${OCL_ATTACH_SLOT:-}" ] || return 0
  eval "exec ${OCL_ATTACH_FD}>&-" 2>/dev/null || true
  rm -f "$OCL_ATTACH_SLOT"
  OCL_ATTACH_SLOT=""
}
