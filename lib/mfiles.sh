# shellcheck shell=bash
#
# lib/mfiles.sh — M-Files authentication token minting.
#
# M-Files is the one service (unlike Bitbucket/Jira/GitLab/JFrog/Confluence)
# where MFILES_PAT isn't a PAT you copy from a web UI: its X-Authentication
# value is a session token you exchange your vault credentials for. This
# module does that exchange so nobody has to hand-run curl or copy a token off
# a terminal into .env.
#
# Sourced by start.sh (not run standalone); depends on core.sh (info/warn/
# get_env/set_env) and config.sh (prompt_with_default, tui_input/tui_password/
# tui_msgbox), both sourced earlier in start.sh's load order.

# mfiles_strip_guid_braces GUID — drop a leading/trailing {} so a GUID copied
# straight out of M-Files Desktop Settings ("Document Vault on Server" shows
# it as "{C540E37E-...}") works whether or not the braces came along.
mfiles_strip_guid_braces() {
  local g="$1"
  g="${g#\{}"
  g="${g%\}}"
  printf '%s' "$g"
}

# mfiles_json_escape STRING — escape backslashes and double quotes for a JSON
# string, so a password/username containing " or \ can't break the request
# body built by mfiles_mint_token.
mfiles_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Bounds on both M-Files calls below: fail fast on a black-holed connection
# (--connect-timeout) instead of hanging on curl/OS defaults, and cap the
# whole request (--max-time) in case the server accepts the connection but
# never answers. Override via the environment if a slow link needs more.
MFILES_CURL_CONNECT_TIMEOUT="${MFILES_CURL_CONNECT_TIMEOUT:-10}"
MFILES_CURL_MAX_TIME="${MFILES_CURL_MAX_TIME:-20}"

# Sites typically only ever log into one of a small, fixed set of Windows
# domains, so the domain step is a pick-one rather than free text. These are
# placeholders — override via the environment (or just edit the two lines)
# once you know your real domain names.
MFILES_DOMAIN_1="${MFILES_DOMAIN_1:-DOMAIN-ONE}"
MFILES_DOMAIN_2="${MFILES_DOMAIN_2:-DOMAIN-TWO}"

# mfiles_prompt_domain_plain — plain-read 1/2 choice between the two known
# domains; echoes the chosen domain on stdout. Anything other than "2"
# (blank, garbage, "1") defaults to MFILES_DOMAIN_1 rather than looping.
mfiles_prompt_domain_plain() {
  echo "Windows domain:" >&2
  printf '  1) %s\n' "$MFILES_DOMAIN_1" >&2
  printf '  2) %s\n' "$MFILES_DOMAIN_2" >&2
  local choice
  read -r -p 'Choose [1-2]: ' choice || true
  case "$choice" in
    2) printf '%s' "$MFILES_DOMAIN_2" ;;
    *) printf '%s' "$MFILES_DOMAIN_1" ;;
  esac
}

# mfiles_prompt_domain_tui TITLE — same choice as mfiles_prompt_domain_plain,
# via a whiptail/dialog menu instead of a plain 1/2 read. Tags are "1"/"2"
# (not the domain name itself) so the menu shows "1  <domain>" / "2  <domain>"
# instead of the domain name appearing twice per row.
mfiles_prompt_domain_tui() {
  local title="$1" choice
  choice="$(tui_menu "$title" 'Windows domain:' \
    1 "$MFILES_DOMAIN_1" \
    2 "$MFILES_DOMAIN_2")"
  case "$choice" in
    2) printf '%s' "$MFILES_DOMAIN_2" ;;
    *) printf '%s' "$MFILES_DOMAIN_1" ;;
  esac
}

# mfiles_mint_token BASE USERNAME DOMAIN VAULT_GUID PASSWORD — exchange vault
# credentials for an X-Authentication token via POST …/REST/server/
# authenticationtokens (no .aspx). Echoes the token on stdout and returns 0 on
# success; on failure prints a diagnostic to stderr and returns 1. --noproxy
# '*' talks to M-Files directly, matching the original one-off script (run
# from the caller's own machine, not the sandboxed container).
mfiles_mint_token() {
  local base="$1" username="$2" domain="$3" vault_guid="$4" password="$5"
  local body response token
  vault_guid="$(mfiles_strip_guid_braces "$vault_guid")"
  body="$(printf '{"Username":"%s","Password":"%s","Domain":"%s","VaultGuid":"%s"}' \
    "$(mfiles_json_escape "$username")" "$(mfiles_json_escape "$password")" \
    "$(mfiles_json_escape "$domain")"   "$(mfiles_json_escape "$vault_guid")")"

  if ! response="$(printf '%s' "$body" |
    curl --fail-with-body --silent --show-error --noproxy '*' \
      --connect-timeout "$MFILES_CURL_CONNECT_TIMEOUT" --max-time "$MFILES_CURL_MAX_TIME" \
      -X POST "${base%/}/REST/server/authenticationtokens" \
      -H 'Content-Type: application/json' --data-binary @- 2>&1)"; then
    printf 'M-Files token request failed: %s\n' "$response" >&2
    return 1
  fi

  token="$(printf '%s' "$response" | sed -n 's/.*"Value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "$token" ]; then
    printf 'M-Files did not return a token. Server said: %s\n' "$response" >&2
    return 1
  fi
  printf '%s' "$token"
}

# mfiles_verify_token BASE TOKEN — smoke-test a minted token with a read-only
# GET …/REST/structure/objecttypes call. Returns curl's exit code (0 = the
# vault accepted the token). Callers must NOT write an unverified token
# without asking first (see mfiles_collect_and_mint/mfiles_tui_mint) — a 4xx
# here almost always means the credentials were wrong.
mfiles_verify_token() {
  local base="$1" token="$2"
  curl --fail-with-body --silent --show-error --noproxy '*' \
    --connect-timeout "$MFILES_CURL_CONNECT_TIMEOUT" --max-time "$MFILES_CURL_MAX_TIME" \
    -H "X-Authentication: $token" -H 'Accept: application/json' \
    "${base%/}/REST/structure/objecttypes" >/dev/null
}

# mfiles_collect_and_mint — prompt (plain read) for base URL/domain/username/
# vault GUID/password, mint a token, auto-verify it, and echo the token on
# stdout (rc 0). Base URL defaults from MFILES_BASE_URL in $ENV_FILE and is
# written back via set_env if the user changes it — the only field this
# writes itself; MFILES_PAT stays the caller's responsibility (prompt_one_key/
# cmd_mfiles_token), so there is one place that decides how secrets land in
# .env. rc 1 when a required field is left blank or the mint call fails
# (diagnostic already emitted via warn/mfiles_mint_token's stderr).
mfiles_collect_and_mint() {
  local base user domain vault_guid password token mint_rc verify_rc
  base="$(get_env MFILES_BASE_URL)"

  echo "Vault GUID: system tray -> right-click the M-Files icon -> Settings ->" >&2
  echo "M-Files Desktop Settings. \"Document Vault on Server\" shows it in curly" >&2
  echo "braces {...} - only the ID inside matters." >&2

  base="$(prompt_with_default 'M-Files base URL (https://…, no trailing slash)' "$base")"
  base="${base%/}"
  domain="$(mfiles_prompt_domain_plain)"
  read -r -p 'Username: ' user || true
  read -r -p 'Vault GUID: ' vault_guid || true
  read -rs -p 'M-Files password (input hidden): ' password || true
  echo >&2

  if [ -z "$base" ] || [ -z "$user" ] || [ -z "$vault_guid" ]; then
    warn "base URL, username and vault GUID are all required — skipping token mint."
    return 1
  fi

  # info()/warn() write to stdout/stderr respectively, but this function's
  # whole point is to be called as `token="$(mfiles_collect_and_mint)"` —
  # anything printed to stdout here (other than the final token line below)
  # would land IN that variable, so every status line is explicitly on
  # stderr (info needs the redirect; warn already goes there). The spinner
  # (writes only to /dev/tty, never fd1/fd2 — see lib/exec.sh) covers the
  # curl calls below: without it the terminal sits silent for however long
  # the network round-trip takes, which reads as the program having exited.
  info "minting M-Files token…" >&2
  exec_spinner_start
  # A bare `token="$(mfiles_mint_token ...)"` would abort the whole script
  # under set -e the instant the mint fails, skipping exec_spinner_stop below
  # (leaving a stuck spinner) — wrapping it as an if-condition is one of the
  # contexts set -e exempts, so the failure path below can run normally.
  if token="$(mfiles_mint_token "$base" "$user" "$domain" "$vault_guid" "$password")"; then
    mint_rc=0
  else
    mint_rc=$?
  fi
  exec_spinner_stop
  if [ "$mint_rc" -ne 0 ]; then
    warn "M-Files token mint failed — check the base URL, credentials, domain and vault GUID."
    return 1
  fi

  set_env MFILES_BASE_URL "$base"
  info "verifying token against the vault…" >&2
  exec_spinner_start
  if mfiles_verify_token "$base" "$token"; then
    verify_rc=0
  else
    verify_rc=$?
  fi
  exec_spinner_stop
  if [ "$verify_rc" -eq 0 ]; then
    info "M-Files token minted and verified." >&2
  else
    # A failed verify usually means the credentials were wrong — an
    # unverified token must never be saved silently. Require an explicit
    # opt-in (e.g. the objecttypes endpoint itself may be restricted even
    # for otherwise-valid credentials); declining discards the token
    # entirely rather than looping — just run the mint again.
    warn "M-Files token minted, but the verification call failed — the base URL, credentials, domain or vault GUID may be wrong."
    local keep
    read -r -p 'Save this unverified token to MFILES_PAT anyway? [y/N]: ' keep || true
    case "$keep" in
      [Yy]*) : ;;
      *)
        warn "discarding the unverified token — nothing was written. Re-run to try again."
        return 1
        ;;
    esac
  fi
  printf '%s' "$token"
}

# mfiles_plain_mint — the setup-wizard hook (plain/linear path): ask whether
# to mint automatically, and if so, delegate to mfiles_collect_and_mint.
# Declining (or leaving the answer at its Yes default and then a required
# sub-field blank) returns 1 so the caller falls back to the normal
# paste-a-token prompt.
mfiles_plain_mint() {
  local reply
  read -r -p 'Mint an M-Files token automatically instead of pasting one? [Y/n]: ' reply || true
  case "${reply:-Y}" in
    [Nn]*) return 1 ;;
  esac
  mfiles_collect_and_mint
}

# mfiles_tui_mint — the ncurses editor's mint flow (Layer 2): same fields as
# mfiles_collect_and_mint, gathered via tui_input/tui_password and reported
# via tui_msgbox instead of plain read/warn/info. Caller (run_tui_reconfigure)
# gates this behind its own tui_yesno "mint automatically?" prompt, and — once
# that's accepted — treats every outcome here (success, decline-to-save, or a
# failed attempt) as final: it never falls through to a manual-paste box
# asking for a raw token the user doesn't have.
mfiles_tui_mint() {
  local title="M-Files Authentication"
  local base user domain vault_guid password token

  base="$(get_env MFILES_BASE_URL)"
  base="$(tui_input "$title" 'M-Files base URL (https://…, no trailing slash)' "$base")"
  base="${base%/}"
  domain="$(mfiles_prompt_domain_tui "$title")"
  user="$(tui_input "$title" 'M-Files username' '')"
  vault_guid="$(tui_input "$title" 'Vault GUID (M-Files Desktop Settings -> Document Vault on Server)' '')"

  if [ -z "$base" ] || [ -z "$user" ] || [ -z "$vault_guid" ]; then
    tui_msgbox "$title" 'Base URL, username and vault GUID are all required — try again from the menu.'
    return 1
  fi

  password="$(tui_password 'M-Files Password' 'Enter your M-Files account password:')"

  # An --infobox has no OK button and returns immediately, but — unlike a
  # dialog closing with nothing to replace it — it stays drawn on screen while
  # the blocking curl call right after it runs. Without this, the whiptail
  # screen would go blank for however long the network call takes, which
  # reads as the program having silently exited.
  tui_infobox "$title" 'Minting M-Files token…'
  token="$(mfiles_mint_token "$base" "$user" "$domain" "$vault_guid" "$password")" || {
    tui_msgbox "$title" 'Token mint failed. Check the base URL, credentials, domain and vault GUID, then try again from the menu.'
    return 1
  }

  set_env MFILES_BASE_URL "$base"
  tui_infobox "$title" 'Verifying token against the vault…'
  if mfiles_verify_token "$base" "$token"; then
    tui_msgbox "$title" 'Token minted and verified.'
  else
    # Same rule as mfiles_collect_and_mint: a failed verify usually means bad
    # credentials, so require an explicit opt-in before saving it.
    if tui_yesno "$title" 'Token minted, but the verification call failed — the base URL, credentials, domain or vault GUID may be wrong. Save this unverified token anyway?'; then
      :
    else
      tui_msgbox "$title" 'Discarded the unverified token — nothing was written. Try again from the menu.'
      return 1
    fi
  fi
  printf '%s' "$token"
}

# cmd_mfiles_token — standalone `./start.sh --mfiles-token` entry point: mint
# a token and write MFILES_BASE_URL/MFILES_PAT straight into $ENV_FILE
# (creating it from $ENV_EXAMPLE first if missing, same as --reconfigure) —
# for rotating an expired token without touring the full wizard. Never pulls,
# attaches, or requires docker/an LLM key.
cmd_mfiles_token() {
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "no $ENV_FILE found — created one from $ENV_EXAMPLE."
  fi

  echo "M-Files authentication token helper"
  echo "==================================="
  echo

  local token
  token="$(mfiles_collect_and_mint)" || die "could not mint an M-Files token."
  set_env MFILES_PAT "$token"
  echo
  info "wrote MFILES_BASE_URL/MFILES_PAT to $ENV_FILE."
}
