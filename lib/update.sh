# shellcheck shell=bash
#
# lib/update.sh — best-effort launcher self-update check (git fetch + rev-list)
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# launcher_behind_count DIR — echo the number of commits DIR's checked-out
# branch is behind its configured upstream, or nothing on ANY failure: no
# `git` on PATH, DIR isn't a git repo, no upstream configured, offline, or a
# `git fetch` that hangs (capped at 5s via `timeout` when available). Always
# returns 0 — this is a best-effort probe, never allowed to trip a caller's
# `set -e`.
launcher_behind_count() {
  local dir="$1" count
  command -v git >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 || return 0

  if command -v timeout >/dev/null 2>&1; then
    timeout 5 git -C "$dir" fetch --quiet >/dev/null 2>&1 || return 0
  else
    git -C "$dir" fetch --quiet >/dev/null 2>&1 || return 0
  fi

  count="$(git -C "$dir" rev-list --count 'HEAD..@{upstream}' 2>/dev/null)" || return 0
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$count"
  return 0
}
