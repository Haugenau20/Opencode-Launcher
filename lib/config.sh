# shellcheck shell=bash
#
# lib/config.sh — the config subsystem: schema, accessors, the setup wizard,
# the read-only dashboard, and the optional ncurses dialog editor.
#
# Sourced by start.sh (not meant to be run standalone). Depends on the
# shared low-level helpers start.sh defines before sourcing this file:
# info/warn/die, get_env/set_env, sed_escape, mask_secret. Those stay in
# start.sh because they're used by non-config code too (boot/lifecycle);
# everything in this file is exclusively config-subsystem.

# prompt_default VAR "Label" current-default  -> echoes chosen value
prompt_with_default() {
  local label="$1" current="$2" reply
  read -r -p "$label [$current]: " reply || true
  printf '%s' "${reply:-$current}"
}

# --- config schema -----------------------------------------------------------
# config_schema — the single source of truth for every key in .env.example:
# its group (mirrors the .env.example section headers), type, human label and
# an optional hint. Pipe-delimited, one row per key, columns:
#
#   group|key|type|label|hint
#
# Types:
#   url       plain URL, shown in cleartext
#   text      plain string, shown in cleartext
#   secret    masked everywhere (mask_secret), never echoed
#   bool      0/1 toggle
#   list      space-separated free-form list
#   internal  shown in dashboards but not user-editable (later layers)
#
# This function is the schema; wizard_keys() below is a VIEW over it (the
# subset + order the interactive wizard prompts for today). Later layers
# (dashboards, validation, etc.) should read config_schema/the accessors
# rather than re-deriving this list by hand.
config_schema() {
  cat <<'EOF'
LLM|LLM_API_BASE|url|LLM API base URL|
LLM|LLM_API_KEY|secret|LLM API key|
Bitbucket|BITBUCKET_BASE_URL|url|Bitbucket base URL|optional; prefer the canonical https:// endpoint
Bitbucket|BITBUCKET_USER|text|Bitbucket username|optional; only for git-over-HTTPS
Bitbucket|BITBUCKET_PAT|secret|Bitbucket personal access token|optional
Bitbucket|BITBUCKET_LEGACY_URL|url|Bitbucket legacy URL (redirects to base)|optional; git insteadOf rewrite
Jira|JIRA_BASE_URL|url|Jira base URL|optional
Jira|JIRA_PAT|secret|Jira personal access token|optional
GitLab|GITLAB_BASE_URL|url|GitLab base URL|optional; https://, required if you use GitLab
GitLab|GITLAB_USER|text|GitLab username|optional
GitLab|GITLAB_PAT|secret|GitLab personal access token|optional
JFrog|JFROG_BASE_URL|url|JFrog base URL|optional; https://, no trailing slash
JFrog|JFROG_PAT|secret|JFrog access token|optional
Confluence|CONFLUENCE_BASE_URL|url|Confluence base URL|optional; include :8090 for the default HTTP connector
Confluence|CONFLUENCE_PAT|secret|Confluence personal access token|optional
M-Files|MFILES_BASE_URL|url|M-Files base URL|optional; https://, no trailing slash
M-Files|MFILES_PAT|secret|M-Files authentication token (X-Authentication)|optional
Git identity|GIT_USER_NAME|text|Git user name for container commits|optional
Git identity|GIT_USER_EMAIL|text|Git user email for container commits|optional
User layer|HOST_UID|internal|Host UID|auto-filled from `id -u` on first run
User layer|HOST_GID|internal|Host GID|auto-filled from `id -g` on first run
Safety|ALLOW_REMOTE_GIT|bool|Allow remote git (push/fetch/pull/clone)|1 enables, 0 disables
Safety|GIT_REMOTE_ALLOWLIST|list|Git remote allowlist|optional; only applies when ALLOW_REMOTE_GIT=1; defence in depth, not a boundary
Safety|ALLOW_CONFLUENCE_WRITE|bool|Allow Confluence writes|1 enables page create/edit, 0 keeps read-only
Safety|ALLOW_GITLAB_WRITE|bool|Allow GitLab writes|1 enables MRs/comments/issues, 0 keeps read-only
Safety|GITLAB_WRITE_PROJECTS|list|GitLab write projects allowlist|optional; only applies when ALLOW_GITLAB_WRITE=1; defence in depth, not a boundary
Safety|GITLAB_QUEUE_LABEL_PREFIX|text|GitLab label prefix the MCP may never set|optional; only if another process owns labels under this prefix
Safety|DISABLE_BITBUCKET_MCP|bool|Force-disable the Bitbucket MCP|
Safety|DISABLE_JIRA_MCP|bool|Force-disable the Jira MCP|
Safety|DISABLE_GITLAB_MCP|bool|Force-disable the GitLab MCP|
Safety|DISABLE_JFROG_MCP|bool|Force-disable the JFrog MCP|
Safety|DISABLE_CONFLUENCE_MCP|bool|Force-disable the Confluence MCP|
Safety|DISABLE_MFILES_MCP|bool|Force-disable the M-Files MCP|
User layer|USER_LAYER_PATH|text|Personal agents/skills/commands layer path|optional; empty uses a per-project named volume instead
Plugins|ENABLED_PLUGINS|list|Enable plugins|space-separated
Image|IMAGE_REGISTRY|text|Image registry (Artifactory path)|
Image|IMAGE_TAG|internal|Image tag|defaults to latest
EOF
}

# --- config schema accessors --------------------------------------------------
# _schema_field KEY COLUMN — internal helper: look up the Nth pipe-delimited
# column (1=group, 2=key, 3=type, 4=label, 5=hint) of KEY's row.
_schema_field() {
  local key="$1" col="$2"
  config_schema | awk -F'|' -v k="$key" -v c="$col" '$2 == k { print $c; exit }'
}

field_group() { _schema_field "$1" 1; }
field_type()  { _schema_field "$1" 3; }
field_label() { _schema_field "$1" 4; }
field_hint()  { _schema_field "$1" 5; }

# is_secret KEY — true (0) if KEY's schema type is "secret".
is_secret() { [ "$(field_type "$1")" = "secret" ]; }

# field_help_text KEY — a short, human-readable description (1-3 lines) of
# what KEY is for, condensed from the comment block above that key in
# .env.example. Used ONLY by the ncurses dialog editor
# (run_tui_reconfigure below) to show context inside the edit dialog itself —
# the linear wizard (prompt_one_key) gets this same information from its own
# hand-written info/warn lines and hint text, and is NOT touched by this
# function. Every editable_schema_keys() key MUST be cased explicitly here;
# anything not cased (e.g. a future schema key added before this function is
# updated) falls back to field_hint so the dialog never shows a blank body.
#
# ENABLED_PLUGINS is a special case: its help text must always reflect the
# live $KNOWN_PLUGINS list (a start.sh global, present whenever config.sh is
# sourced — same dependency contract as get_env/set_env) plus the Qwen/
# opencode-workspace incompatibility warning, mirroring prompt_one_key's two
# info/warn lines so the same caution is visible in both UIs.
field_help_text() {
  local key="$1"
  case "$key" in
    LLM_API_BASE)
      printf 'Base URL of your LLM API (OpenAI-compatible), e.g. https://llm.internal.example/v1.'
      ;;
    LLM_API_KEY)
      printf 'Bearer token for the LLM API, per developer.'
      ;;
    BITBUCKET_BASE_URL)
      printf 'Bitbucket REST API base URL, no trailing slash.\nOnly needed if the agent should authenticate to Bitbucket.\nPrefer the canonical https:// endpoint (e.g. https://bitbucket.internal.example:8443); the plain-HTTP connector also serves the REST API but can trigger a git auth-redirect prompt.'
      ;;
    BITBUCKET_USER)
      printf 'Your Bitbucket username. Optional — not used by the REST API (Bearer PAT); only the git credential helper for git-over-HTTPS clone/push uses it.'
      ;;
    BITBUCKET_PAT)
      printf 'Bitbucket personal access token — Bearer for the REST API, and the git password over HTTPS. Optional.'
      ;;
    BITBUCKET_LEGACY_URL)
      printf 'Optional legacy Bitbucket URL that redirects to BITBUCKET_BASE_URL (e.g. the plain-HTTP connector on :7990).\nWhen set, the container rewrites git remotes still pointing here to BITBUCKET_BASE_URL before connecting, avoiding a "Username for https://…" prompt.'
      ;;
    JIRA_BASE_URL)
      printf 'Jira REST API base URL, no trailing slash.\nOnly needed if the agent should reach Jira. Optional.'
      ;;
    JIRA_PAT)
      printf 'Jira personal access token, sent as a Bearer token (no username needed). Optional.'
      ;;
    GITLAB_BASE_URL)
      printf 'GitLab base URL over HTTPS, no trailing slash.\nREQUIRED if you use GitLab — the GitLab MCP will not start without it.'
      ;;
    GITLAB_USER)
      printf 'Your GitLab username, used for git Basic auth. Optional.'
      ;;
    GITLAB_PAT)
      printf 'GitLab personal access token (covers git + REST API via the PRIVATE-TOKEN header). Optional.'
      ;;
    JFROG_BASE_URL)
      printf 'JFrog platform base URL over HTTPS, no trailing slash (the MCP appends /artifactory/api).\nAPI-only (no git transport). Optional — the JFrog MCP turns on once this + JFROG_PAT are set.'
      ;;
    JFROG_PAT)
      printf 'JFrog access token, sent as a Bearer token (no username needed). Optional.'
      ;;
    CONFLUENCE_BASE_URL)
      printf 'Confluence site base URL, no trailing slash (the MCP appends /rest/api).\nInclude :8090 for the default HTTP connector, or use plain https:// with no port.\nAPI-only. Optional — the Confluence MCP turns on once this + CONFLUENCE_PAT are set.'
      ;;
    CONFLUENCE_PAT)
      printf 'Confluence personal access token, sent as a Bearer token (no username needed). Optional.'
      ;;
    MFILES_BASE_URL)
      printf 'M-Files site base URL over HTTPS, no trailing slash (the MCP appends /REST).\nAPI-only (no git transport). Optional — the M-Files MCP turns on once this + MFILES_PAT are set.'
      ;;
    MFILES_PAT)
      printf 'M-Files authentication token, sent as the X-Authentication header (no username needed).\nThis prompt can mint one for you from your vault credentials, or run ./start.sh --mfiles-token any time. Optional.'
      ;;
    GIT_USER_NAME)
      printf 'Git user name used for commits made inside the container. Optional.'
      ;;
    GIT_USER_EMAIL)
      printf 'Git user email used for commits made inside the container. Optional.'
      ;;
    ALLOW_REMOTE_GIT)
      printf 'Allow git push/fetch/pull/clone to remote hosts. 1 enables, 0 disables.'
      ;;
    GIT_REMOTE_ALLOWLIST)
      printf 'Optional second gate, applied only when ALLOW_REMOTE_GIT=1: whitespace- or comma-separated host/path prefixes remote git may target, matched on a path-segment boundary. Empty = no restriction.\nDefence in depth, NOT a security boundary — an agent with a shell can call git directly. The real boundary is the token'"'"'s own scope and role.'
      ;;
    ALLOW_CONFLUENCE_WRITE)
      printf 'Allow the Confluence MCP to create and edit pages instead of only reading them. Only the exact value 1 enables writes. Deleting pages is never possible either way.'
      ;;
    ALLOW_GITLAB_WRITE)
      printf 'Allow the GitLab MCP to open merge requests, comment, and create issues instead of only reading. Only the exact value 1 enables writes.\nEven at 1 there is deliberately no tool to set labels, close an issue, or merge an MR.'
      ;;
    GITLAB_WRITE_PROJECTS)
      printf 'Optional narrowing, applied only when ALLOW_GITLAB_WRITE=1: whitespace- or comma-separated project paths or numeric ids writes are restricted to, same segment-boundary rule as GIT_REMOTE_ALLOWLIST. Empty = no restriction.\nDefence in depth, NOT a security boundary — an agent with a shell can call the GitLab API directly. The real boundary is the token'"'"'s own scope and role.'
      ;;
    GITLAB_QUEUE_LABEL_PREFIX)
      printf 'Optional label namespace/prefix the GitLab MCP is never allowed to set, even at ALLOW_GITLAB_WRITE=1. Only relevant if some other process (a workflow queue, an orchestrator) owns labels under that prefix as its own state. Leave blank if that doesn'"'"'t apply to you.'
      ;;
    DISABLE_BITBUCKET_MCP)
      printf 'Force-disable the Bitbucket MCP even if Bitbucket credentials are present in .env.'
      ;;
    DISABLE_JIRA_MCP)
      printf 'Force-disable the Jira MCP even if Jira credentials are present in .env.'
      ;;
    DISABLE_GITLAB_MCP)
      printf 'Force-disable the GitLab MCP even if GitLab credentials are present in .env.'
      ;;
    DISABLE_JFROG_MCP)
      printf 'Force-disable the JFrog MCP even if JFrog credentials are present in .env.'
      ;;
    DISABLE_CONFLUENCE_MCP)
      printf 'Force-disable the Confluence MCP even if Confluence credentials are present in .env.'
      ;;
    DISABLE_MFILES_MCP)
      printf 'Force-disable the M-Files MCP even if M-Files credentials are present in .env.'
      ;;
    USER_LAYER_PATH)
      printf 'Host path to bind-mount as your personal agents/skills/commands layer (e.g. ./user-layer).\nLeave empty to use a per-project named volume instead.'
      ;;
    ENABLED_PLUGINS)
      printf 'Space- or comma-separated list of baked-in plugins to enable (symlinked in on boot, load offline). Empty = none enabled.\nAvailable plugins (all off by default): %s\nWARNING: do NOT enable '"'"'opencode-workspace'"'"' if you intend to use Qwen — they are incompatible.' "$KNOWN_PLUGINS"
      ;;
    IMAGE_REGISTRY)
      printf 'Artifactory path images are pulled from, e.g. registry.example/opencode-workplace. REQUIRED before first run.'
      ;;
    *)
      field_hint "$key"
      ;;
  esac
}

# wizard_keys — the ordered list of keys the interactive setup wizard prompts
# for, one per line. This is a VIEW over config_schema: it is the exact
# first-run/--reconfigure sequence the wizard has always used, preserved here
# so the refactor in run_setup_wizard stays behavior-identical. Bools,
# USER_LAYER_PATH and IMAGE_TAG exist in config_schema (for later dashboards)
# but are deliberately NOT prompted here — don't add them without a deliberate
# product decision, since that would change first-run/--reconfigure behavior.
wizard_keys() {
  cat <<'EOF'
LLM_API_BASE
LLM_API_KEY
BITBUCKET_BASE_URL
BITBUCKET_USER
BITBUCKET_PAT
BITBUCKET_LEGACY_URL
JIRA_BASE_URL
JIRA_PAT
GITLAB_BASE_URL
GITLAB_USER
GITLAB_PAT
JFROG_BASE_URL
JFROG_PAT
CONFLUENCE_BASE_URL
CONFLUENCE_PAT
MFILES_BASE_URL
MFILES_PAT
GIT_USER_NAME
GIT_USER_EMAIL
ENABLED_PLUGINS
IMAGE_REGISTRY
EOF
}

# editable_schema_keys — every config_schema key EXCEPT type "internal", in
# schema order. This is the authoritative "editable set" for any interactive
# per-key editor: today's menu-driven --reconfigure (cmd_reconfigure) numbers
# exactly these keys, and any later UI (e.g. an ncurses menu) should reuse
# this function rather than re-deriving the set, so the editable scope stays
# in one place. HOST_UID/HOST_GID/IMAGE_TAG are "internal" and therefore
# excluded — they stay hand-edited. This is a superset of wizard_keys(): it
# also includes the bool safety switches, USER_LAYER_PATH and IMAGE_REGISTRY
# (already in wizard_keys), in config_schema's group order rather than the
# linear wizard's order.
editable_schema_keys() {
  config_schema | awk -F'|' '$3 != "internal" { print $2 }'
}

# required_keys — the keys that MUST be a real (non-placeholder) value before
# the launcher can boot, one per line. This mirrors doctor_check_env_keys'
# required=(...) array in start.sh — the doctor's PASS/FAIL gate and the
# ncurses first-run save gate (below) must never drift apart, so both
# should ultimately read this single list.
required_keys() {
  cat <<'EOF'
LLM_API_BASE
LLM_API_KEY
IMAGE_REGISTRY
EOF
}

# _is_placeholder_value VALUE — true (0) iff VALUE matches one of the
# placeholder sentinels .env.example ships (CHANGEME.../...internal.example.../
# ...artifactory.example...). This is the exact pattern start.sh's boot check
# uses on IMAGE_REGISTRY (see start.sh's IMAGE_REGISTRY placeholder case
# statement) — kept as a literal duplicate (case patterns don't cross files
# cleanly) so field_satisfied below shares the same definition of "looks
# unfilled". If you change one, change the other.
_is_placeholder_value() {
  case "$1" in
    *CHANGEME*|*internal.example*|*artifactory.example*) return 0 ;;
    *) return 1 ;;
  esac
}

# field_satisfied KEY — true (0) iff KEY's current .env value is non-empty
# AND is not a placeholder sentinel (_is_placeholder_value). This is the
# per-field test behind unmet_required()/the ncurses first-run gate: a
# required field that's still blank, or still says CHANGEME..., is not
# "satisfied" yet.
field_satisfied() {
  local value
  value="$(get_env "$1")"
  [ -n "$value" ] || return 1
  ! _is_placeholder_value "$value"
}

# unmet_required — every required_keys() entry that is not yet
# field_satisfied, one per line. Empty output means every required field is
# filled in with a real value. This is the unit-testable core of the
# ncurses first-run save gate: callers just check whether this is empty.
unmet_required() {
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    field_satisfied "$key" || printf '%s\n' "$key"
  done < <(required_keys)
}

# --- optional ncurses configuration editor ----------------------------------
# Layer 2 of the config UX: when a real terminal and dialog are available,
# --reconfigure drives a small ncurses menu instead of the plain-text
# dashboard+menu (Layer 1) or the linear wizard (Layer 0). dialog is required
# for this layer because its --no-ok + --extra-button combination is what lets
# Enter edit a highlighted row while Save & Exit and Discard & Exit remain two
# independent bottom actions. whiptail cannot represent that interaction, so
# a whiptail-only host uses the pure-bash fallback rather than showing a
# misleading Select/Edit button.

# tui_backend — echo "dialog" or "whiptail", preferring dialog when both are
# on PATH. whiptail remains supported by the generic field wrappers, but the
# full-screen configuration editor is enabled only for dialog (see have_tui).
# Pure detection, no tty required, so this is directly unit-testable.
tui_backend() {
  if command -v dialog >/dev/null 2>&1; then
    printf '%s' "dialog"
  elif command -v whiptail >/dev/null 2>&1; then
    printf '%s' "whiptail"
  fi
}

# have_tui — return 0 iff the ncurses editor should be used: dialog is
# installed, stdin AND stdout are a real terminal, and the OC_CONFIG_TUI=0
# escape hatch has not been set. Set OC_CONFIG_TUI=0 to force the pure-bash
# path even when dialog is present (documented in usage()/README).
# The tty check is also what keeps this from ever hijacking a piped/CI
# --reconfigure run (bats included): stdin is never a tty there.
have_tui() {
  [ "${OC_CONFIG_TUI:-}" = "0" ] && return 1
  [ "$(tui_backend)" = "dialog" ] || return 1
  [ -t 0 ] && [ -t 1 ]
}

# config_tui_fallback_notice — explain why a host that has whiptail but not
# dialog gets the plain-text editor. No warning is shown when the user
# explicitly selected that path with OC_CONFIG_TUI=0.
config_tui_fallback_notice() {
  [ "${OC_CONFIG_TUI:-}" = "0" ] && return 0
  if command -v whiptail >/dev/null 2>&1 && ! command -v dialog >/dev/null 2>&1; then
    info "full-screen configuration needs 'dialog' for separate Save & Exit and Discard & Exit actions; using the plain-text editor."
  fi
}

# tui_input TITLE LABEL DEFAULT — show an inputbox pre-filled with DEFAULT,
# with explicit Save/Back buttons. Echo the confirmed value and preserve the
# backend status: 0=Save, 1=Back, 255=Esc. Callers MUST handle the non-zero
# statuses (normally by returning to the parent menu without writing).
tui_input() {
  local title="$1" label="$2" default="$3" backend rc=0 result
  local button_args=()
  backend="$(tui_backend)"
  case "$backend" in
    whiptail) button_args=(--ok-button Save --cancel-button Back) ;;
    dialog)   button_args=(--ok-label Save --cancel-label Back) ;;
  esac
  result="$("$backend" "${button_args[@]}" --inputbox "$label" 0 0 "$default" --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$result"
  return "$rc"
}

# tui_password TITLE LABEL — show a passwordbox (input not echoed to the
# screen), with explicit Save/Back buttons. Echo the confirmed value and
# preserve the backend status just like tui_input. NEVER pre-fill the current
# secret; callers decide whether a confirmed blank means clear or no change.
tui_password() {
  local title="$1" label="$2" backend rc=0 result
  local button_args=()
  backend="$(tui_backend)"
  case "$backend" in
    whiptail) button_args=(--ok-button Save --cancel-button Back) ;;
    dialog)   button_args=(--ok-label Save --cancel-label Back) ;;
  esac
  result="$("$backend" "${button_args[@]}" --passwordbox "$label" 0 0 --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$result"
  return "$rc"
}

# tui_yesno TITLE LABEL [YES_LABEL] [NO_LABEL] — show a yes/no box, optionally
# with clearer action labels. Preserve the backend status: 0=Yes, 1=No,
# 255=Esc. Callers that mutate state must distinguish No from Esc.
tui_yesno() {
  local title="$1" label="$2" yes_label="${3:-Yes}" no_label="${4:-No}" backend
  local button_args=()
  backend="$(tui_backend)"
  case "$backend" in
    whiptail) button_args=(--yes-button "$yes_label" --no-button "$no_label") ;;
    dialog)   button_args=(--yes-label "$yes_label" --no-label "$no_label") ;;
  esac
  "$backend" "${button_args[@]}" --yesno "$label" 0 0 --title "$title" 3>&1 1>&2 2>&3
}

# _tui_menu_with_labels OK_LABEL CANCEL_LABEL TITLE PROMPT TAG1 ITEM1 ... —
# common menu implementation. Echo the selected tag only on confirmation and
# preserve the backend status so Cancel/Back and Esc are never conflated with
# a selected (or empty) tag.
_tui_menu_with_labels() {
  local ok_label="$1" cancel_label="$2" title="$3" prompt="$4"; shift 4
  local backend rc=0 result
  local button_args=()
  backend="$(tui_backend)"
  case "$backend" in
    whiptail) button_args=(--ok-button "$ok_label" --cancel-button "$cancel_label") ;;
    dialog)   button_args=(--ok-label "$ok_label" --cancel-label "$cancel_label") ;;
  esac
  result="$("$backend" "${button_args[@]}" --menu "$prompt" 0 0 0 "$@" --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$result"
  return "$rc"
}

# tui_menu is the generic nested picker: Select confirms a row and Back
# returns to its caller.
tui_menu() { _tui_menu_with_labels Select Back "$@"; }

# tui_config_menu TITLE PROMPT TAG1 ITEM1 ... — dialog-only top-level editor
# menu. --no-ok keeps Enter as the implicit row-edit action without rendering
# a redundant button. The Extra and Cancel buttons are the two session-level
# actions and have distinct return codes: 3=Save & Exit, 1=Discard & Exit,
# 255=Esc. With --no-ok, dialog reserves Enter for the implicit row action;
# Tab moves focus to the button row and Ctrl-D activates the focused button.
# Normalize dialog's configurable exit-code environment variables so callers
# can rely on those values.
tui_config_menu() {
  local title="$1" prompt="$2"; shift 2
  local backend rc=0 result
  backend="$(tui_backend)"
  [ "$backend" = "dialog" ] || return 127
  result="$(DIALOG_OK=0 DIALOG_CANCEL=1 DIALOG_EXTRA=3 DIALOG_ESC=255 \
    "$backend" --no-ok --extra-button --extra-label "Save & Exit" \
      --cancel-label "Discard & Exit" --visit-items \
      --menu "$prompt" 0 0 0 "$@" --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$result"
  return "$rc"
}

# tui_msgbox TITLE TEXT — show a plain dismiss-only message box (whiptail/
# dialog --msgbox). Used to surface information (e.g. the first-run save
# gate's unmet-required-fields notice) rather than ask a question, so unlike
# tui_yesno there is no meaningful Yes/No/Cancel result to report — a
# dismissal (Esc/Cancel/Enter) is never an error, it just closes the box (rc
# captured locally so a non-zero exit never trips set -e).
tui_msgbox() {
  local title="$1" text="$2" backend rc=0
  backend="$(tui_backend)"
  "$backend" --msgbox "$text" 0 0 --title "$title" 3>&1 1>&2 2>&3 || rc=$?
  return 0
}

# NOTE: no tui_infobox helper here. One was tried (a transient whiptail/
# dialog --infobox to cover the M-Files mint/verify network calls) and
# dropped: confirmed by hand that even a bare `whiptail --infobox "..." 10
# 50; sleep 5` shows nothing on some terminals/whiptail builds — --infobox
# isn't a reliable "please wait" mechanism, unlike the other widgets here.
# See mfiles_tui_mint (lib/mfiles.sh) for what covers those calls instead: a
# plain status line + spinner written directly to the terminal, the same
# mechanism the non-whiptail mint path already used successfully.

# field_is_required KEY — true iff KEY participates in the first-run/doctor
# required-field gate.
field_is_required() {
  local wanted="$1" key
  while IFS= read -r key; do
    [ "$key" = "$wanted" ] && return 0
  done < <(required_keys)
  return 1
}

# field_state_text KEY — concise, non-secret state for the ncurses menu.
# Required placeholders are distinguished from real values; booleans say what
# they mean instead of reporting both 0 and 1 as merely "set".
field_state_text() {
  local key="$1" value type
  value="$(get_env "$key")"
  type="$(field_type "$key")"

  if field_is_required "$key" && ! field_satisfied "$key"; then
    if [ -z "$value" ]; then
      printf '%s' '(missing — REQUIRED)'
    else
      printf '%s' '(placeholder — REQUIRED)'
    fi
    return 0
  fi

  case "$type" in
    bool)
      case "$value" in
        1)  printf '%s' '(enabled)' ;;
        0)  printf '%s' '(disabled)' ;;
        '') printf '%s' '(unset)' ;;
        *)  printf '%s' '(invalid — expected 0 or 1)' ;;
      esac
      ;;
    *)
      if [ -n "$value" ]; then printf '%s' '(set)'; else printf '%s' '(unset)'; fi
      ;;
  esac
}

# config_set_if_changed KEY VALUE — write only a real change. Return 0 when a
# write happened and 1 when VALUE already matched the current configuration.
config_set_if_changed() {
  local key="$1" value="$2"
  [ "$(get_env "$key")" = "$value" ] && return 1
  set_env "$key" "$value"
  return 0
}

# _restore_tui_trap SIGNAL SAVED_TRAP — reinstate a caller's signal handler
# after the transactional editor temporarily installs its own cleanup trap.
_restore_tui_trap() {
  local signal="$1" saved_trap="$2"
  if [ -n "$saved_trap" ]; then
    # trap -p emits a complete, shell-quoted trap command.
    # shellcheck disable=SC2294
    eval "$saved_trap"
  else
    trap - "$signal"
  fi
}

# run_tui_reconfigure [--first-run] [--new-file] — transactional ncurses
# editor. Every field action writes only to a private staged copy. Choosing
# Save & Exit atomically replaces the real .env; choosing Discard & Exit,
# pressing Esc, or interrupting with Ctrl+C removes the stage
# and leaves an existing .env untouched. --new-file additionally removes the
# just-created template on discard/interruption, so canceled first-run setup
# never leaves a partial configuration behind.
#
# The top-level dialog renders only Save & Exit and Discard & Exit; Enter edits
# the highlighted setting without a visible Select/Edit button. Field dialogs
# use Save/Back, and only Save/Enable/Disable changes the stage.
#
# First run uses wizard_keys() (the same intentionally smaller scope as the
# linear wizard); normal --reconfigure uses every editable_schema_keys() key.
# Save is gated on first run until every required field is satisfied; discard
# is always available. TUI_CONFIG_CHANGED is 1 only after staged changes are
# committed, and TUI_CONFIG_RESULT reports saved, unchanged, or discarded.
# shellcheck disable=SC2120  # called with no args for plain --reconfigure
run_tui_reconfigure() {
  local first_run=0 new_file=0 arg
  for arg in "$@"; do
    case "$arg" in
      --first-run) first_run=1 ;;
      --new-file)  new_file=1 ;;
      *) warn "unknown configuration UI option: $arg"; return 2 ;;
    esac
  done

  TUI_CONFIG_CHANGED=0
  TUI_CONFIG_RESULT=unchanged

  local original_env_file="$ENV_FILE" staged_env_file
  staged_env_file="$(mktemp "${original_env_file}.staged.XXXXXX")" || {
    warn "could not create a staged configuration beside $original_env_file."
    [ "$new_file" -eq 0 ] || rm -f -- "$original_env_file"
    return 1
  }
  if ! cp -p -- "$original_env_file" "$staged_env_file"; then
    warn "could not stage $original_env_file for editing."
    rm -f -- "$staged_env_file"
    [ "$new_file" -eq 0 ] || rm -f -- "$original_env_file"
    return 1
  fi

  local old_int_trap old_term_trap
  old_int_trap="$(trap -p INT)"
  old_term_trap="$(trap -p TERM)"
  trap 'ENV_FILE="$original_env_file"; rm -f -- "$staged_env_file"; if [ "$new_file" -eq 1 ]; then rm -f -- "$original_env_file"; fi; exit 130' INT
  trap 'ENV_FILE="$original_env_file"; rm -f -- "$staged_env_file"; if [ "$new_file" -eq 1 ]; then rm -f -- "$original_env_file"; fi; exit 143' TERM
  ENV_FILE="$staged_env_file"

  local keys=() key
  if [ "$first_run" -eq 1 ]; then
    while IFS= read -r key; do
      [ -n "$key" ] && keys+=("$key")
    done < <(wizard_keys)
  else
    while IFS= read -r key; do
      [ -n "$key" ] && keys+=("$key")
    done < <(editable_schema_keys)
  fi

  while true; do
    local menu_args=() k label state desc
    for k in "${keys[@]}"; do
      label="$(field_label "$k")"
      state="$(field_state_text "$k")"
      desc="$label $state"
      menu_args+=("$k" "$desc")
    done

    local choice="" menu_rc=0
    choice="$(tui_config_menu \
      "OpenCode Launcher — configuration" \
      "Enter edits the highlighted setting. Tab moves to an exit action; Ctrl-D activates it. Changes are staged." \
      "${menu_args[@]}")" || menu_rc=$?

    case "$menu_rc" in
      1|255)
        ENV_FILE="$original_env_file"
        rm -f -- "$staged_env_file"
        [ "$new_file" -eq 0 ] || rm -f -- "$original_env_file"
        _restore_tui_trap INT "$old_int_trap"
        _restore_tui_trap TERM "$old_term_trap"
        TUI_CONFIG_CHANGED=0
        TUI_CONFIG_RESULT=discarded
        return 2
        ;;
      3)
        if [ "$first_run" -eq 1 ]; then
          local unmet=() ukey
          while IFS= read -r ukey; do
            [ -n "$ukey" ] && unmet+=("$ukey")
          done < <(unmet_required)

          if [ "${#unmet[@]}" -gt 0 ]; then
            local msg="These are required before you can save:"$'\n'
            for ukey in "${unmet[@]}"; do
              msg+=$'\n'"  - $(field_label "$ukey")"
            done
            msg+=$'\n\n'"Fill them in, or choose Discard & Exit to abort."
            tui_msgbox "OpenCode Launcher — configuration" "$msg"
            continue
          fi
        fi

        ENV_FILE="$original_env_file"
        if cmp -s -- "$staged_env_file" "$original_env_file"; then
          rm -f -- "$staged_env_file"
          _restore_tui_trap INT "$old_int_trap"
          _restore_tui_trap TERM "$old_term_trap"
          TUI_CONFIG_CHANGED=0
          TUI_CONFIG_RESULT=unchanged
          return 0
        fi
        if ! mv -f -- "$staged_env_file" "$original_env_file"; then
          warn "could not save the staged configuration to $original_env_file."
          rm -f -- "$staged_env_file"
          [ "$new_file" -eq 0 ] || rm -f -- "$original_env_file"
          _restore_tui_trap INT "$old_int_trap"
          _restore_tui_trap TERM "$old_term_trap"
          TUI_CONFIG_CHANGED=0
          TUI_CONFIG_RESULT=error
          return 1
        fi
        _restore_tui_trap INT "$old_int_trap"
        _restore_tui_trap TERM "$old_term_trap"
        TUI_CONFIG_CHANGED=1
        TUI_CONFIG_RESULT=saved
        return 0
        ;;
      0)
        [ -n "$choice" ] || continue

        local type cur new help body input_rc bool_rc clear_rc secret_status
        type="$(field_type "$choice")"
        label="$(field_label "$choice")"
        help="$(field_help_text "$choice")"
        case "$type" in
          secret)
            cur="$(get_env "$choice")"
            # MFILES_PAT: offer to mint a token instead of pasting one (see
            # prompt_one_key's linear-path equivalent). Declining THIS offer
            # falls through to the normal password box below (that's the
            # expected "I'll paste one myself" path) — but once minting is
            # accepted, mfiles_tui_mint's own outcome (success, a declined
            # save-anyway, or a failed attempt) is final: it already reported
            # what happened via its own tui_msgbox, so this never ALSO shows
            # a manual-paste box asking for a raw token the user doesn't have.
            if [ "$choice" = "MFILES_PAT" ]; then
              local mint_offer_rc=0 mint_rc=0 before_base after_base
              tui_yesno "$label" "Mint an M-Files authentication token automatically instead of pasting one?" || mint_offer_rc=$?
              if [ "$mint_offer_rc" -eq 0 ]; then
                before_base="$(get_env MFILES_BASE_URL)"
                new="$(mfiles_tui_mint)" || mint_rc=$?
                after_base="$(get_env MFILES_BASE_URL)"
                [ "$before_base" != "$after_base" ] && TUI_CONFIG_CHANGED=1
                if [ "$mint_rc" -eq 0 ] && config_set_if_changed "$choice" "$new"; then
                  TUI_CONFIG_CHANGED=1
                fi
                continue
              elif [ "$mint_offer_rc" -ne 1 ]; then
                # Esc backs out of the field; No deliberately continues to
                # the manual password box.
                continue
              fi
            fi

            if [ -n "$cur" ]; then secret_status="(set)"; else secret_status="(empty)"; fi
            body="$help"$'\n\n'"Current value: $secret_status"$'\n'"Enter a replacement, leave blank to clear it, or choose Back to keep it."
            input_rc=0
            new="$(tui_password "$label" "$body")" || input_rc=$?
            [ "$input_rc" -eq 0 ] || continue

            if [ -z "$new" ] && [ -n "$cur" ]; then
              clear_rc=0
              tui_yesno "$label" "Clear the currently saved secret?" Clear Keep || clear_rc=$?
              [ "$clear_rc" -eq 0 ] || continue
            fi
            if config_set_if_changed "$choice" "$new"; then
              TUI_CONFIG_CHANGED=1
            fi
            ;;
          bool)
            body="$help"$'\n\n'"Enable $label?"
            bool_rc=0
            tui_yesno "$label" "$body" Enable Disable || bool_rc=$?
            case "$bool_rc" in
              0) new=1 ;;
              1) new=0 ;;
              *) continue ;;  # Esc: return without changing the setting.
            esac
            if config_set_if_changed "$choice" "$new"; then
              TUI_CONFIG_CHANGED=1
            fi
            ;;
          url|text|list)
            cur="$(get_env "$choice")"
            body="$help"$'\n\n'"$label:"
            input_rc=0
            new="$(tui_input "$label" "$body" "$cur")" || input_rc=$?
            [ "$input_rc" -eq 0 ] || continue
            if config_set_if_changed "$choice" "$new"; then
              TUI_CONFIG_CHANGED=1
            fi
            ;;
        esac
        ;;
      *)
        warn "configuration UI exited unexpectedly (status $menu_rc)."
        ENV_FILE="$original_env_file"
        rm -f -- "$staged_env_file"
        [ "$new_file" -eq 0 ] || rm -f -- "$original_env_file"
        _restore_tui_trap INT "$old_int_trap"
        _restore_tui_trap TERM "$old_term_trap"
        TUI_CONFIG_CHANGED=0
        TUI_CONFIG_RESULT=error
        return "$menu_rc"
        ;;
    esac
  done
}

# --- setup wizard (first-run and --reconfigure) ------------------------------
# prompt_one_key KEY [--reconfigure] — prompt for a single schema KEY and
# write the answer via set_env. This is the per-field body extracted out of
# run_setup_wizard so both the linear wizard loop AND the menu-driven
# single-key editor (cmd_reconfigure's interactive menu) share one source of
# truth for prompt wording/behavior. In default (first-run) mode, secrets
# start blank. In --reconfigure mode the prompt is pre-filled from the CURRENT
# .env value (Enter keeps it); secret values are shown masked (never echoed)
# but still round-trip correctly when left untouched.
#
# Driven by config_schema(): the key's type selects secret/bool/plain-text
# handling, and its label/hint build the prompt text. LLM_API_BASE and
# LLM_API_KEY are the only two required fields (no "optional" hint, no
# Enter-to-skip wording); every other field is optional. ENABLED_PLUGINS gets
# two extra lines (the known-plugins info + Qwen incompatibility warning)
# immediately before its prompt — preserved here as a special case keyed off
# the field name, same as the original hand-written wizard. bool fields are
# prompted as a 0/1 toggle, defaulting to the current value (or 0 if unset).
#
# NOTE: the exact prompt strings below are pinned by tests (cli.bats) — do not
# reword them.
prompt_one_key() {
  local key="$1" reconfigure=0
  [ "${2:-}" = "--reconfigure" ] && reconfigure=1

  local type label hint required always_show_default prompt_label
  type="$(field_type "$key")"
  label="$(field_label "$key")"
  hint="$(field_hint "$key")"
  # Only the two LLM fields are required; everything else prompted is
  # optional. required tracks that so the prompt wording matches today's.
  case "$key" in
    LLM_API_BASE|LLM_API_KEY) required=1 ;;
    *) required=0 ;;
  esac
  # Plain URLs (and IMAGE_REGISTRY) always pre-show their current value via
  # prompt_with_default, in both first-run and --reconfigure — they were
  # never given the first-run "Enter to skip" plain-read treatment the other
  # optional text/list fields get. is_secret fields have their own masked
  # handling below regardless of this flag.
  case "$type" in
    url) always_show_default=1 ;;
    *) [ "$key" = "IMAGE_REGISTRY" ] && always_show_default=1 || always_show_default=0 ;;
  esac

  prompt_label="$label"
  [ -n "$hint" ] && prompt_label="$label ($hint)"

  if [ "$key" = "ENABLED_PLUGINS" ]; then
    info "available plugins (all off by default): ${KNOWN_PLUGINS}"
    warn "do NOT enable 'opencode-workspace' if you intend to use Qwen — they are incompatible."
  fi

  local cur new
  cur="$(get_env "$key")"

  if [ "$type" = "bool" ]; then
    # 0/1 toggle, default = current value (or 0 if unset/unrecognized).
    local cur_bool; cur_bool="$cur"
    [ "$cur_bool" = "1" ] || cur_bool=0
    new="$(prompt_with_default "$prompt_label (0/1)" "$cur_bool")"
    [ "$new" = "1" ] || new=0
  elif is_secret "$key"; then
    new=""
    # MFILES_PAT is the one secret you can't just copy off a web UI — offer to
    # mint it instead of pasting, but only on a real terminal (never during a
    # piped/CI run, so tests and scripted use are unaffected). Declining, or a
    # required sub-field left blank, falls through to the normal paste prompt.
    if [ "$key" = "MFILES_PAT" ] && [ -t 0 ] && [ -t 1 ]; then
      new="$(mfiles_plain_mint)" || new=""
    fi
    if [ -z "$new" ]; then
      if [ "$reconfigure" -eq 1 ]; then
        printf '%s %s (input hidden): ' "$prompt_label" "$(mask_secret "$cur")"
      else
        if [ "$required" -eq 1 ]; then
          printf '%s (input hidden): ' "$prompt_label"
        else
          printf '%s, Enter to skip, input hidden): ' "${prompt_label%)}"
        fi
      fi
      read -rs new || true; echo
      [ -n "$new" ] || new="$cur"
    fi
  elif [ "$required" -eq 1 ] || [ "$always_show_default" -eq 1 ]; then
    # Required fields and plain URLs/registry: always pre-shown, Enter accepts.
    new="$(prompt_with_default "$prompt_label" "$cur")"
  else
    # Optional text/list fields: first run uses a plain "Enter to skip" read
    # (no current value to show yet); --reconfigure pre-fills from .env.
    if [ "$reconfigure" -eq 1 ]; then
      new="$(prompt_with_default "$prompt_label" "$cur")"
    else
      read -r -p "${prompt_label%)}, Enter to skip): " new || true
    fi
  fi

  set_env "$key" "$new"
}

# set_host_ids — auto-fill HOST_UID/HOST_GID from the current user (id -u /
# id -g) for bind-mount permissions. First-run only — every first-run path
# (linear wizard AND the ncurses editor) must call this exactly once;
# --reconfigure/the ncurses menu's per-key edits must never touch these two
# keys, since they're "internal" (hand-edited, not in editable_schema_keys).
set_host_ids() {
  set_env HOST_UID "$(id -u)"
  set_env HOST_GID "$(id -g)"
}

# run_setup_wizard [--reconfigure] — prompts for the secrets/config that
# first-run handles, looping wizard_keys() and delegating each key to
# prompt_one_key. Never touches HOST_UID/HOST_GID (or any other key it
# doesn't explicitly own) when reconfiguring. Both first-run and
# --reconfigure call this so behavior stays identical between the two entry
# points.
run_setup_wizard() {
  local reconfigure=0
  [ "${1:-}" = "--reconfigure" ] && reconfigure=1

  # Read the key list into an array first (rather than piping wizard_keys
  # into a `while read` loop) so the loop body's own stdin stays free — the
  # per-field prompts in prompt_one_key (`read`, `read -rs`,
  # prompt_with_default) need the real stdin (the user's terminal, or the
  # test's fed answers), not the wizard_keys() stream.
  local keys=() key
  while IFS= read -r key; do
    [ -n "$key" ] && keys+=("$key")
  done < <(wizard_keys)

  for key in "${keys[@]}"; do
    if [ "$reconfigure" -eq 1 ]; then
      prompt_one_key "$key" --reconfigure
    else
      prompt_one_key "$key"
    fi
  done

  if [ "$reconfigure" -eq 0 ]; then
    # Auto-fill UID/GID for bind-mount permissions (first run only —
    # reconfigure must never clobber these).
    set_host_ids
  fi
}

# cmd_config_show — read-only dashboard: every config_schema key, grouped by
# field_group in schema order, with a [set]/[ -- ] marker and its current
# value. secret-typed keys (is_secret) NEVER print their value — only a fixed
# mask plus "(secret, set)"/the unset marker — so this is always safe to
# paste into a chat or ticket. Pure read: never creates or modifies
# $ENV_FILE, even when it doesn't exist yet.
cmd_config_show() {
  info "Configuration ($ENV_FILE)"

  if [ ! -f "$ENV_FILE" ]; then
    echo
    info "$ENV_FILE not found — nothing is configured yet."
    info "run ./start.sh <host-repo-path> (first run) or ./start.sh --reconfigure to create it."
  fi

  local keys=() key
  while IFS= read -r key; do
    [ -n "$key" ] && keys+=("$key")
  done < <(config_schema | awk -F'|' '{ print $2 }')

  local last_group="" group value marker shown
  for key in "${keys[@]}"; do
    group="$(field_group "$key")"
    if [ "$group" != "$last_group" ]; then
      echo
      printf '  %s\n' "$group"
      last_group="$group"
    fi

    value=""
    [ -f "$ENV_FILE" ] && value="$(get_env "$key")"

    if is_secret "$key"; then
      if [ -n "$value" ]; then
        marker="[set]"
        shown="••••••  (secret, set)"
      else
        marker="[ -- ]"
        shown="(unset)"
      fi
    else
      if [ -n "$value" ]; then
        marker="[set]"
        shown="$value"
      else
        marker="[ -- ]"
        shown="(unset)"
      fi
    fi

    printf '    %-6s %-24s %s\n' "$marker" "$key" "$shown"
  done
  echo
  return 0
}

# cmd_reconfigure — re-run the secrets setup, picking one of three flows:
#   1. have_tui (real terminal + dialog installed, and
#      OC_CONFIG_TUI != 0): run_tui_reconfigure, the ncurses menu editor.
#   2. real terminal but no ncurses backend (or OC_CONFIG_TUI=0): a read-only
#      dashboard (cmd_config_show) followed by a small plain-text menu so the
#      user can edit ONE key instead of being forced through the full linear
#      wizard; "a" still runs the complete linear walk.
#   3. NOT a tty (piped input — tests, CI, scripted use): falls through
#      unchanged to the linear run_setup_wizard --reconfigure walk. have_tui
#      always returns false here (no tty), so this path can never be
#      hijacked by the ncurses editor.
cmd_reconfigure() {
  local used_tui=0 env_created=0 tui_rc=0
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    env_created=1
    info "no $ENV_FILE found — created one from $ENV_EXAMPLE to reconfigure."
  fi

  if have_tui; then
    used_tui=1
    # Interactive + dialog available: ncurses menu editor (Layer 2).
    # The editor stages every field and commits only from its explicit save
    # row. If this command created .env, discard removes that template too.
    # shellcheck disable=SC2119,SC2120
    if [ "$env_created" -eq 1 ]; then
      run_tui_reconfigure --new-file || tui_rc=$?
    else
      run_tui_reconfigure || tui_rc=$?
    fi
    case "$tui_rc" in
      0) ;;
      2)
        echo
        info "configuration discarded — no changes were saved."
        return 0
        ;;
      *) return "$tui_rc" ;;
    esac
  elif [ -t 0 ] && [ -t 1 ]; then
    # Interactive, no ncurses backend (or OC_CONFIG_TUI=0): dashboard + a
    # plain-text menu (Layer 1). Editable set = editable_schema_keys() (every
    # non-"internal" schema key); HOST_UID/HOST_GID/IMAGE_TAG are "internal"
    # and stay out of the menu (hand-edited only).
    config_tui_fallback_notice
    local keys=() key
    while IFS= read -r key; do
      [ -n "$key" ] && keys+=("$key")
    done < <(editable_schema_keys)

    while true; do
      cmd_config_show
      local i=1
      for key in "${keys[@]}"; do
        printf '  %2d) %s\n' "$i" "$key"
        i=$((i + 1))
      done
      echo
      local choice
      read -r -p 'Edit which setting? [number to edit, "a" = walk all, Enter/"q" = done]: ' choice || true
      case "$choice" in
        ''|q|Q) break ;;
        a|A)
          echo
          run_setup_wizard --reconfigure
          ;;
        *)
          if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
            local sel_key="${keys[$((choice - 1))]}"
            echo
            prompt_one_key "$sel_key" --reconfigure
          else
            warn "not a valid choice: $choice"
          fi
          ;;
      esac
    done
  else
    # Non-interactive (piped input, CI, tests): unchanged linear walk.
    info "reconfigure: press Enter on any prompt to keep the current value."
    echo
    run_setup_wizard --reconfigure
  fi

  echo
  if [ "$used_tui" -eq 1 ]; then
    if [ "$env_created" -eq 1 ] || [ "${TUI_CONFIG_CHANGED:-0}" -eq 1 ]; then
      info "configuration saved — changes apply on your next ./start.sh run."
    else
      info "configuration closed — no changes made."
    fi
  else
    info "wrote $ENV_FILE — changes apply on your next ./start.sh run."
  fi
}
