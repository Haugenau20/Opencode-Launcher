# shellcheck shell=bash
#
# lib/config.sh — the config subsystem: schema, accessors, the setup wizard,
# the read-only dashboard, and the optional ncurses (whiptail/dialog) editor.
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
Bitbucket|BITBUCKET_BASE_URL|url|Bitbucket base URL|optional; plain http:// on the internal instance
Bitbucket|BITBUCKET_USER|text|Bitbucket username|optional
Bitbucket|BITBUCKET_PAT|secret|Bitbucket personal access token|optional
Jira|JIRA_BASE_URL|url|Jira base URL|optional
Jira|JIRA_PAT|secret|Jira personal access token|optional
GitLab|GITLAB_BASE_URL|url|GitLab base URL|optional; https://, required if you use GitLab
GitLab|GITLAB_USER|text|GitLab username|optional
GitLab|GITLAB_PAT|secret|GitLab personal access token|optional
JFrog|JFROG_BASE_URL|url|JFrog base URL|optional; https://, no trailing slash
JFrog|JFROG_PAT|secret|JFrog access token|optional
Confluence|CONFLUENCE_BASE_URL|url|Confluence base URL|optional; include :8090 for the default HTTP connector
Confluence|CONFLUENCE_PAT|secret|Confluence personal access token|optional
Git identity|GIT_USER_NAME|text|Git user name for container commits|optional
Git identity|GIT_USER_EMAIL|text|Git user email for container commits|optional
User layer|HOST_UID|internal|Host UID|auto-filled from `id -u` on first run
User layer|HOST_GID|internal|Host GID|auto-filled from `id -g` on first run
Safety|ALLOW_REMOTE_GIT|bool|Allow remote git (push/fetch/pull/clone)|1 enables, 0 disables
Safety|ENABLE_SESSION_LOGS|bool|Enable session logs|0 swaps session state for tmpfs
Safety|DISABLE_BITBUCKET_MCP|bool|Force-disable the Bitbucket MCP|
Safety|DISABLE_JIRA_MCP|bool|Force-disable the Jira MCP|
Safety|DISABLE_GITLAB_MCP|bool|Force-disable the GitLab MCP|
Safety|DISABLE_JFROG_MCP|bool|Force-disable the JFrog MCP|
Safety|DISABLE_CONFLUENCE_MCP|bool|Force-disable the Confluence MCP|
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
# .env.example. Used ONLY by the ncurses (whiptail/dialog) editor
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
      printf 'Bitbucket REST API base URL, no trailing slash.\nOnly needed if the agent should authenticate to Bitbucket.\nNote: the internal instance speaks plain http:// (https:// fails with a TLS error).'
      ;;
    BITBUCKET_USER)
      printf 'Your Bitbucket username (also used for git auth). Optional.'
      ;;
    BITBUCKET_PAT)
      printf 'Bitbucket personal access token (serves both git and the REST API). Optional.'
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
    GIT_USER_NAME)
      printf 'Git user name used for commits made inside the container. Optional.'
      ;;
    GIT_USER_EMAIL)
      printf 'Git user email used for commits made inside the container. Optional.'
      ;;
    ALLOW_REMOTE_GIT)
      printf 'Allow git push/fetch/pull/clone to remote hosts. 1 enables, 0 disables.'
      ;;
    ENABLE_SESSION_LOGS)
      printf 'Keep session state on disk. 0 swaps session state for tmpfs instead.'
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
JIRA_BASE_URL
JIRA_PAT
GITLAB_BASE_URL
GITLAB_USER
GITLAB_PAT
JFROG_BASE_URL
JFROG_PAT
CONFLUENCE_BASE_URL
CONFLUENCE_PAT
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
# ncurses first-run "Done" gate (below) must never drift apart, so both
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
# ncurses first-run "Done" gate: callers just check whether this is empty.
unmet_required() {
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    field_satisfied "$key" || printf '%s\n' "$key"
  done < <(required_keys)
}

# --- optional ncurses (whiptail/dialog) config editor ------------------------
# Layer 2 of the config UX: when a real terminal AND whiptail/dialog are
# available, --reconfigure drives a small ncurses menu instead of the
# plain-text dashboard+menu (Layer 1) or the linear wizard (Layer 0). Both
# backends are optional; everything degrades gracefully to the pure-bash
# flows when neither is installed, when there's no tty (piped/CI input), or
# when the OC_CONFIG_TUI=0 escape hatch is set.

# tui_backend — echo "whiptail" or "dialog", whichever is found first on
# PATH (whiptail preferred — it's the Debian/Ubuntu default and what most
# users will have); echo nothing if neither is installed. Pure detection, no
# tty required, so this is directly unit-testable.
tui_backend() {
  if command -v whiptail >/dev/null 2>&1; then
    printf '%s' "whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    printf '%s' "dialog"
  fi
}

# have_tui — return 0 iff the ncurses editor should be used: a backend is
# installed, stdin AND stdout are a real terminal, and the OC_CONFIG_TUI=0
# escape hatch has not been set. Set OC_CONFIG_TUI=0 to force the pure-bash
# path even when whiptail/dialog is present (documented in usage()/README).
# The tty check is also what keeps this from ever hijacking a piped/CI
# --reconfigure run (bats included): stdin is never a tty there.
have_tui() {
  [ "${OC_CONFIG_TUI:-}" = "0" ] && return 1
  [ -n "$(tui_backend)" ] || return 1
  [ -t 0 ] && [ -t 1 ]
}

# tui_input TITLE LABEL DEFAULT — show an inputbox pre-filled with DEFAULT;
# echo whatever the user confirmed. Echoes DEFAULT unchanged on Cancel/Esc
# (rc captured locally so a non-zero whiptail/dialog exit under
# set -euo pipefail never kills the script).
tui_input() {
  local title="$1" label="$2" default="$3" backend rc=0 result
  backend="$(tui_backend)"
  result="$("$backend" --inputbox "$label" 0 0 "$default" --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "$default"
  else
    printf '%s' "$result"
  fi
}

# tui_password TITLE LABEL — show a passwordbox (input not echoed to the
# screen); echo whatever the user typed, or empty on Cancel/Esc. NEVER
# pre-fills with the current secret (mirrors prompt_one_key's masked
# handling) — the caller is responsible for treating empty as "keep current".
tui_password() {
  local title="$1" label="$2" backend rc=0 result
  backend="$(tui_backend)"
  result="$("$backend" --passwordbox "$label" 0 0 --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] || result=""
  printf '%s' "$result"
}

# tui_yesno TITLE LABEL — show a yes/no box; return 0 for Yes, 1 for both No
# and Cancel/Esc (whiptail/dialog already exit non-zero for "No", so this
# just passes that through rather than treating it as a script error).
tui_yesno() {
  local title="$1" label="$2" backend
  backend="$(tui_backend)"
  "$backend" --yesno "$label" 0 0 --title "$title" 3>&1 1>&2 2>&3
}

# tui_menu TITLE PROMPT TAG1 ITEM1 [TAG2 ITEM2 ...] — show a menu of
# tag/description pairs; echo the chosen TAG, or empty on Cancel/Esc (rc
# captured locally, never fatal under set -e).
tui_menu() {
  local title="$1" prompt="$2"; shift 2
  local backend rc=0 result
  backend="$(tui_backend)"
  result="$("$backend" --menu "$prompt" 0 0 0 "$@" --title "$title" 3>&1 1>&2 2>&3)" || rc=$?
  [ "$rc" -eq 0 ] || result=""
  printf '%s' "$result"
}

# tui_msgbox TITLE TEXT — show a plain dismiss-only message box (whiptail/
# dialog --msgbox). Used to surface information (e.g. the first-run "Done"
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

# run_tui_reconfigure [--first-run] — the ncurses editor loop: a tui_menu of
# editable_schema_keys() (the same authoritative editable set Layer 1 uses),
# each item tagged by KEY with a description of its label plus a
# set/unset hint (secrets show only (set)/(unset), never the value), plus a
# trailing "Done" entry. Selecting a key dispatches by field_type to the
# matching wrapper above and writes the result via set_env (so sed_escape
# still handles special characters); Cancel/Esc on the menu itself also
# exits the loop. Loops until Done/Cancel, then falls through to the same
# "wrote $ENV_FILE" line the other two flows print.
#
# --first-run additionally GATES the Done entry: required_keys() that are
# not yet field_satisfied get a "(REQUIRED)" marker appended to their menu
# description (so the user can see at a glance what's still missing — this
# marker is shown in both modes, but only --first-run enforces it), and
# selecting Done with unmet_required() non-empty shows a tui_msgbox listing
# what's missing and CONTINUES the loop instead of exiting — the menu simply
# reappears, it never force-opens the unmet field for editing. Without
# --first-run (plain --reconfigure), Done is never gated, exactly as before.
#
# Ctrl+C is deliberately NOT trapped here: SIGINT still kills the whole
# process immediately, same as every other interactive prompt in this
# script. The gate only ever blocks the Done menu *action* — it is not a
# substitute for providing credentials, just a nudge before declaring
# first-run setup finished.
# shellcheck disable=SC2120  # called with no args for plain --reconfigure
run_tui_reconfigure() {
  local first_run=0
  [ "${1:-}" = "--first-run" ] && first_run=1

  local keys=() key
  while IFS= read -r key; do
    [ -n "$key" ] && keys+=("$key")
  done < <(editable_schema_keys)

  local required=() rkey
  while IFS= read -r rkey; do
    [ -n "$rkey" ] && required+=("$rkey")
  done < <(required_keys)

  while true; do
    local menu_args=() k label state desc is_required
    for k in "${keys[@]}"; do
      label="$(field_label "$k")"
      if [ -n "$(get_env "$k")" ]; then state="(set)"; else state="(unset)"; fi
      desc="$label $state"

      is_required=0
      for rkey in "${required[@]}"; do
        [ "$rkey" = "$k" ] && is_required=1 && break
      done
      if [ "$is_required" -eq 1 ] && ! field_satisfied "$k"; then
        desc="$desc  (REQUIRED)"
      fi

      menu_args+=("$k" "$desc")
    done
    menu_args+=(DONE "Done — finish editing")

    local choice
    choice="$(tui_menu "OpenCode Launcher — configuration" "Choose a setting to edit:" "${menu_args[@]}")"

    case "$choice" in
      ''|DONE)
        if [ "$first_run" -eq 1 ]; then
          local unmet=() ukey
          while IFS= read -r ukey; do
            [ -n "$ukey" ] && unmet+=("$ukey")
          done < <(unmet_required)

          if [ "${#unmet[@]}" -gt 0 ]; then
            local msg="These are required before you can finish:"$'\n'
            for ukey in "${unmet[@]}"; do
              msg+=$'\n'"  - $(field_label "$ukey")"
            done
            msg+=$'\n\n'"Fill them in, or press Ctrl+C to abort."
            tui_msgbox "OpenCode Launcher — configuration" "$msg"
            continue
          fi
        fi
        break
        ;;
      *)
        local type cur new help body
        type="$(field_type "$choice")"
        label="$(field_label "$choice")"
        help="$(field_help_text "$choice")"
        case "$type" in
          secret)
            cur="$(get_env "$choice")"
            body="$help"$'\n\n'"Current value: $(mask_secret "$cur")"$'\n'"Leave blank to keep the current value."
            new="$(tui_password "$label" "$body")"
            # Blank input keeps the current value, same rule prompt_one_key
            # uses for masked secrets.
            [ -n "$new" ] || new="$cur"
            set_env "$choice" "$new"
            ;;
          bool)
            body="$help"$'\n\n'"Enable $label?"
            cur="$(get_env "$choice")"
            if tui_yesno "$label" "$body"; then
              set_env "$choice" 1
            else
              set_env "$choice" 0
            fi
            ;;
          url|text|list)
            cur="$(get_env "$choice")"
            body="$help"$'\n\n'"$label:"
            new="$(tui_input "$label" "$body" "$cur")"
            set_env "$choice" "$new"
            ;;
        esac
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
#   1. have_tui (real terminal + whiptail/dialog installed, and
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
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "no $ENV_FILE found — created one from $ENV_EXAMPLE to reconfigure."
  fi

  if have_tui; then
    # Interactive + whiptail/dialog available: ncurses menu editor (Layer 2).
    # No --first-run here — plain --reconfigure's Done is never gated.
    # shellcheck disable=SC2119,SC2120
    run_tui_reconfigure
  elif [ -t 0 ] && [ -t 1 ]; then
    # Interactive, no ncurses backend (or OC_CONFIG_TUI=0): dashboard + a
    # plain-text menu (Layer 1). Editable set = editable_schema_keys() (every
    # non-"internal" schema key); HOST_UID/HOST_GID/IMAGE_TAG are "internal"
    # and stay out of the menu (hand-edited only).
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
  info "wrote $ENV_FILE — changes apply on your next ./start.sh run."
}
