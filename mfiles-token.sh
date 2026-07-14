#!/usr/bin/env bash
#
# mfiles-token.sh — mint an M-Files authentication token for MFILES_PAT.
#
# M-Files is the one service where the token isn't copied from a web UI: its
# X-Authentication value is a session token you exchange your vault credentials
# for. This helper prompts for the few inputs, POSTs them to the M-Files Web
# Service, and prints the token to paste into MFILES_PAT in .env. Your password
# is read silently and never stored or echoed.
#
# Run it from your own machine (on the corp network, with direct line of sight
# to M-Files) — NOT inside the container. It talks to M-Files directly, bypassing
# any proxy (--noproxy '*'), the same way the tested one-off script did.
#
# Usage:  ./mfiles-token.sh
# Defaults are read from .env where present (MFILES_BASE_URL); press Enter to
# accept a shown [default].

set -euo pipefail

# --- locate .env for defaults (optional) -------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

env_default() {
  # env_default KEY — echo the value of KEY from .env, or empty if absent.
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | head -n1
}

# --- prompt helpers ----------------------------------------------------------
prompt() {
  # prompt VAR "Label" "default" — read a value into VAR, showing [default].
  local __var="$1" __label="$2" __default="${3:-}" __reply
  if [ -n "$__default" ]; then
    read -rp "$__label [$__default]: " __reply
    __reply="${__reply:-$__default}"
  else
    read -rp "$__label: " __reply
  fi
  printf -v "$__var" '%s' "$__reply"
}

# json_escape STRING — escape backslashes and double quotes for a JSON string,
# so a password/username containing " or \ can't break the request body.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

echo "M-Files authentication token helper"
echo "==================================="
echo
echo "Where to find the Vault GUID: system tray → right-click the M-Files icon →"
echo "Settings → M-Files Desktop Settings. In the \"Document Vault on Server\""
echo "column the GUID is shown in curly braces {…}. Copy only the ID inside the"
echo "braces (not the braces, not the whole cell). Pasting the braces is fine —"
echo "this script strips them."
echo

prompt BASE       "M-Files base URL (https://…, no trailing slash)" "$(env_default MFILES_BASE_URL)"
prompt USERNAME   "Username"                                        ""
prompt DOMAIN     "Windows domain (blank for M-Files-native login)" ""
prompt VAULT_GUID "Vault GUID"                                      ""

BASE="${BASE%/}"                       # drop any trailing slash
VAULT_GUID="${VAULT_GUID#\{}"          # strip a leading {
VAULT_GUID="${VAULT_GUID%\}}"          # strip a trailing }

if [ -z "$BASE" ] || [ -z "$USERNAME" ] || [ -z "$VAULT_GUID" ]; then
  echo "Base URL, username and vault GUID are all required." >&2
  exit 1
fi

read -rsp "Password: " PASSWORD
printf '\n\n'

# --- mint --------------------------------------------------------------------
# POST to /REST/server/authenticationtokens (no .aspx needed). The body carries
# the credentials + vault; the response is {"Value":"<token>"}.
mint() {
  printf '{"Username":"%s","Password":"%s","Domain":"%s","VaultGuid":"%s"}' \
    "$(json_escape "$USERNAME")" "$(json_escape "$PASSWORD")" \
    "$(json_escape "$DOMAIN")"   "$(json_escape "$VAULT_GUID")" |
  curl --fail-with-body --silent --show-error --noproxy '*' \
    -X POST "$BASE/REST/server/authenticationtokens" \
    -H 'Content-Type: application/json' \
    --data-binary @-
}

RESPONSE="$(mint)" || {
  echo "Request failed. Check the base URL, credentials, domain and vault GUID above." >&2
  exit 1
}

unset PASSWORD

TOKEN="$(printf '%s' "$RESPONSE" |
  sed -n 's/.*"Value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [ -z "$TOKEN" ]; then
  echo "Failed to get an authentication token. Server said:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

echo "Success. Paste this into MFILES_PAT in your .env:"
echo
echo "    MFILES_PAT=$TOKEN"
echo

# --- optional smoke test -----------------------------------------------------
read -rp "Verify the token against $BASE now? [Y/n]: " VERIFY
case "${VERIFY:-Y}" in
  [Nn]*) exit 0 ;;
esac

echo
echo "GET /REST/structure/objecttypes:"
curl --fail-with-body --silent --show-error --noproxy '*' \
  -H "X-Authentication: $TOKEN" \
  -H "Accept: application/json" \
  "$BASE/REST/structure/objecttypes" && printf '\n' &&
  echo "Token works." ||
  echo "Token was issued but the verification call failed — check network/base URL." >&2
