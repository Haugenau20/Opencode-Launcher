# shellcheck shell=bash
#
# lib/allowlist.sh — egress-allowlist reporting (--show-allowlist) and helpers
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# url_host URL — echo just the host[:port] component of a URL
# (https://llm.internal.example/v1 -> llm.internal.example). Best-effort string
# surgery (no curl/python dependency); echoes the input unchanged if it doesn't
# look like a URL at all.
url_host() {
  local url="$1" rest
  rest="${url#*://}"
  rest="${rest%%/*}"
  printf '%s' "$rest"
}

# list_extra_allowlist_files [DIR] — echo each *.conf file in DIR (default
# extra-allowlist.d), one per line, sorted. Empty/absent dir => no output.
list_extra_allowlist_files() {
  local dir="${1:-extra-allowlist.d}"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort || true
}

# cmd_show_allowlist [REPO_PATH] — read-only report of the egress this launcher
# knows about. Honest by construction: the AUTHORITATIVE allowlist (LLM
# endpoint, Bitbucket, Jira, GitLab) is baked into the squid image, not this repo, so
# this can only show the bits start.sh itself knows: the configured LLM/
# Bitbucket/Jira/GitLab hosts from .env, and any local extra-allowlist.d/*.conf
# drop-ins. Never requires an LLM key, never pulls or attaches anything.
cmd_show_allowlist() {
  local repo_path="${1:-}"

  echo "OpenCode Launcher egress allowlist"
  echo "==================================="
  info "the AUTHORITATIVE allowlist (LLM endpoint, Bitbucket, Jira, GitLab) is enforced"
  info "inside the squid image, not in this repo — this report shows only what"
  info "start.sh itself knows about: configured hosts + local extensions."
  echo

  if [ -f "$ENV_FILE" ]; then
    local llm_base llm_host bb_user jira_base gl_user
    llm_base="$(get_env LLM_API_BASE)"
    if [ -n "$llm_base" ]; then
      llm_host="$(url_host "$llm_base")"
      info "LLM endpoint host: $llm_host"
    else
      info "LLM endpoint host: (not configured — LLM_API_BASE is empty in $ENV_FILE)"
    fi

    bb_user="$(get_env BITBUCKET_USER)"
    if [ -n "$bb_user" ]; then
      info "Bitbucket: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "Bitbucket: not configured (no BITBUCKET_USER in $ENV_FILE)"
    fi

    jira_base="$(get_env JIRA_BASE_URL)"
    if [ -n "$jira_base" ]; then
      info "Jira: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "Jira: not configured (no JIRA_BASE_URL in $ENV_FILE)"
    fi

    gl_user="$(get_env GITLAB_USER)"
    if [ -n "$gl_user" ]; then
      info "GitLab: credentials configured (host is baked into the squid image, not visible here)"
    else
      info "GitLab: not configured (no GITLAB_USER in $ENV_FILE)"
    fi
  else
    warn "$ENV_FILE not found — run ./start.sh once to create it. Showing local extensions only."
  fi
  echo

  local allow_dir="extra-allowlist.d"
  [ -n "$repo_path" ] && info "(note: --show-allowlist reports the launcher's own $allow_dir; the optional repo path is accepted for symmetry with other commands but does not change this report)"

  local files=() f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
  done < <(list_extra_allowlist_files "$allow_dir")

  if [ "${#files[@]}" -eq 0 ]; then
    info "local extensions ($allow_dir/*.conf): none"
  else
    info "local extensions ($allow_dir/*.conf):"
    for f in "${files[@]}"; do
      printf '  - %s\n' "$f"
      # Indent each non-comment, non-blank line of the conf file so the rules it
      # adds are visible without requiring the reader to open the file. Never
      # echoes anything from .env, so this can't leak a secret.
      grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | sed 's/^/      /' || true
    done
  fi

  return 0
}

# allowlist_summary_line — a SHORT one-line egress summary for normal boot (the
# full detail lives in --show-allowlist). Never prints secrets.
allowlist_summary_line() {
  local llm_base llm_host extra_count
  llm_base="$(get_env LLM_API_BASE 2>/dev/null || true)"
  llm_host="(unset)"
  [ -n "$llm_base" ] && llm_host="$(url_host "$llm_base")"
  extra_count="$(list_extra_allowlist_files "extra-allowlist.d" | grep -c . || true)"
  if [ "${extra_count:-0}" -gt 0 ]; then
    printf 'egress allowlist: LLM(%s) + Bitbucket/Jira/GitLab (baked into image) + %s local extension file(s) — see ./start.sh --show-allowlist' \
      "$llm_host" "$extra_count"
  else
    printf 'egress allowlist: LLM(%s) + Bitbucket/Jira/GitLab (baked into image) — see ./start.sh --show-allowlist' \
      "$llm_host"
  fi
}
