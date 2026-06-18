# shellcheck shell=bash
#
# lib/digest.sh — image-digest reproducibility anchor and .env drift detection
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

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
