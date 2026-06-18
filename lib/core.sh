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

# set_env KEY VALUE — replace `KEY=...` line in $ENV_FILE in place.
set_env() {
  local key="$1" value="$2" esc
  esc="$(sed_escape "$value")"
  sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
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
