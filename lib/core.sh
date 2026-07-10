# shellcheck shell=bash
#
# lib/core.sh — low-level output and .env-file helpers everything else builds on
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# --- output helpers --------------------------------------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# --- env-file helpers -------------------------------------------------------
# sed-escape a replacement string for use with '|' as the delimiter.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# set_env KEY VALUE — set `KEY=VALUE` in $ENV_FILE: replace the existing `KEY=`
# line in place, or APPEND it if the key isn't there yet. The append case
# matters because a key can be genuinely new to a user's .env (a wizard/
# --reconfigure key added to .env.example after their .env was created, or the
# post-upgrade config offer): a pure in-place replace would silently no-op and
# the value would be lost. Keys are `[A-Za-z_][A-Za-z0-9_]*`, so the `^KEY=`
# grep/sed anchors carry no regex-special characters.
set_env() {
  local key="$1" value="$2" esc
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    esc="$(sed_escape "$value")"
    sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# read current value of KEY from $ENV_FILE (no surrounding processing).
get_env() {
  local key="$1"
  sed -n "s|^${key}=\(.*\)$|\1|p" "$ENV_FILE" | head -n1
}

# mask_secret VALUE -> a short, non-reversible hint for use as a prompt
# default when displaying a secret ("(empty)" or "(set, press Enter to
# keep)"). Never echoes the actual value.
mask_secret() {
  local value="$1"
  if [ -z "$value" ]; then
    printf '%s' "(empty)"
  else
    printf '%s' "(set, press Enter to keep)"
  fi
}
