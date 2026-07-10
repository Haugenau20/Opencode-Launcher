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

# image_tag_pinned TAG — return 0 (true) if TAG pins the image to a specific
# release instead of tracking the moving `latest` tag, else 1. Empty and
# `latest` (the default) track latest, so they are NOT pins; `local` is the
# dev/package-layer sentinel for a self-built image, also NOT a pin to nudge
# away from. Anything else — a semver like `0.0.5`, or a `sha256:`/`@sha256:`
# digest — is a deliberate pin. Only the latest launcher + the latest image is
# a supported/tested pairing (see CHANGELOG "Compatibility"), so the boot-time
# upgrade gate treats any pin as a state worth offering to leave.
image_tag_pinned() {
  case "${1:-}" in
    ''|latest|local) return 1 ;;
    *) return 0 ;;
  esac
}

# launcher_pull_ff DIR — fast-forward DIR's checkout to its configured upstream
# via `git pull --ff-only`, returning 0 on success and non-zero on ANY failure
# (no `git`, not a checkout, offline, a dirty tree, or diverged history that
# can't fast-forward). Best-effort and quiet: it prints nothing itself so the
# caller owns all user-facing messaging. Kept separate from
# launcher_behind_count so that probe stays strictly read-only — this is the
# only function here that mutates the checkout, and only when the user has
# explicitly accepted the upgrade.
launcher_pull_ff() {
  local dir="$1"
  command -v git >/dev/null 2>&1 || return 1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$dir" pull --ff-only --quiet >/dev/null 2>&1
}

# env_example_added_keys DIR OLD_REV [FILE] — echo each env key present in FILE
# (default .env.example, path relative to DIR) in DIR's current working tree but
# NOT present at git revision OLD_REV, one per line in current-file order. This
# is the precise "config that is new since OLD_REV" set — used right after a
# launcher upgrade (the gate captured the pre-pull HEAD as OLD_REV) to show only
# keys genuinely introduced in the span the user just crossed, not every unset
# optional key. Best-effort: empty on ANY failure (no git, not a repo, OLD_REV
# or FILE missing at either end) and always returns 0, so it's safe under a
# caller's set -e.
env_example_added_keys() {
  local dir="$1" old_rev="$2" file="${3:-.env.example}" cur old k
  command -v git >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [ -f "$dir/$file" ] || return 0
  cur="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$dir/$file" 2>/dev/null | sed -E 's/=.*//')" || cur=""
  old="$(git -C "$dir" show "${old_rev}:${file}" 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | sed -E 's/=.*//')" || old=""
  [ -n "$cur" ] || return 0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    printf '%s\n' "$old" | grep -qxF -- "$k" || printf '%s\n' "$k"
  done <<< "$cur"
  return 0
}
