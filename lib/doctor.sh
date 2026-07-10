# shellcheck shell=bash
#
# lib/doctor.sh — the --doctor diagnostic checks and their orchestrator
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# Each doctor_check_* prints exactly one aligned report line and returns 0 for
# PASS/WARN or 1 for FAIL (only FAIL should flip the overall --doctor exit
# code). They are the same logic the normal boot path uses for its preflight
# checks (kept here as standalone functions so both paths share one source of
# truth and so they're unit-testable without a real Docker daemon).

# doctor_line STATUS LABEL [DETAIL] — print one aligned, pasteable report line.
doctor_line() {
  local status="$1" label="$2" detail="${3:-}"
  if [ -n "$detail" ]; then
    printf '[%-4s] %-46s %s\n' "$status" "$label" "$detail"
  else
    printf '[%-4s] %s\n' "$status" "$label"
  fi
}

# doctor_check_docker_present — is `docker` on PATH.
doctor_check_docker_present() {
  if command -v docker >/dev/null 2>&1; then
    doctor_line PASS "docker on PATH"
    return 0
  fi
  doctor_line FAIL "docker on PATH" "not found — install Docker first"
  return 1
}

# doctor_check_docker_daemon — can we talk to the Docker daemon. Mirrors the
# permission-denied / "is it running?" hinting from the normal preflight.
doctor_check_docker_daemon() {
  local out
  if out="$(docker info 2>&1)"; then
    doctor_line PASS "docker daemon reachable"
    return 0
  fi
  if printf '%s' "$out" | grep -qi 'permission denied'; then
    doctor_line FAIL "docker daemon reachable" \
      "permission denied — try: sudo usermod -aG docker \$USER && newgrp docker"
  else
    doctor_line FAIL "docker daemon reachable" "is it running? ($(printf '%s' "$out" | tail -n1))"
  fi
  return 1
}

# doctor_check_compose_v2 — the `docker compose` (v2) plugin is available.
doctor_check_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    doctor_line PASS "docker compose v2 plugin"
    return 0
  fi
  doctor_line FAIL "docker compose v2 plugin" "not available — install the Docker Compose plugin"
  return 1
}

# doctor_check_podman — informational only; a Podman `docker` shim changes
# which compose overlay is needed, but it is never a failure.
doctor_check_podman() {
  if docker --version 2>&1 | grep -qi podman; then
    doctor_line WARN "podman shim detected" "the --podman overlay will be added automatically"
  else
    doctor_line PASS "podman shim" "not detected (using real Docker)"
  fi
  return 0
}

# doctor_check_registry_access CHECK_IMAGE REGISTRY_HOST — reuses the same
# `docker manifest inspect` access check the normal boot path runs, including
# the docker-login hint on an auth failure.
doctor_check_registry_access() {
  local check_image="$1" registry_host="$2" inspect_err
  if inspect_err="$(docker manifest inspect "$check_image" 2>&1)"; then
    doctor_line PASS "registry access ($check_image)"
    return 0
  fi
  if printf '%s' "$inspect_err" | grep -qiE 'unauthorized|authentication|denied|forbidden|login'; then
    doctor_line FAIL "registry access ($check_image)" \
      "auth problem — run: docker login $registry_host"
    return 1
  fi
  doctor_line WARN "registry access ($check_image)" \
    "could not verify ($(printf '%s' "$inspect_err" | tail -n1))"
  return 0
}

# doctor_check_image_manifest CHECK_IMAGE — WARN if CHECK_IMAGE's
# manifest.json (newer images only — see lib/manifest.sh) lists an env key
# this launcher's .env.example doesn't know about, since that means the
# image needs a newer launcher. PASS when a manifest is present and every key
# is known. Neutral WARN "skipped" when CHECK_IMAGE isn't pulled locally or
# has no manifest at all (older image) — that is the expected, common case
# and must never look like a problem, so this never FAILs the doctor.
doctor_check_image_manifest() {
  local check_image="$1" manifest_json missing_keys
  manifest_json="$(image_manifest "$check_image" 2>/dev/null || true)"
  if [ -z "$manifest_json" ]; then
    doctor_line WARN "image manifest" "not available (older image or image not pulled) — skipped"
    return 0
  fi
  missing_keys="$(manifest_missing_keys "$manifest_json")"
  if [ -n "$missing_keys" ]; then
    doctor_line WARN "image manifest" \
      "reads key(s) this launcher doesn't know: $(printf '%s' "$missing_keys" | tr '\n' ' ' | sed 's/[[:space:]]*$//') — git pull the launcher"
  else
    doctor_line PASS "image manifest: launcher knows every key"
  fi
  return 0
}

# doctor_check_env_file — $ENV_FILE exists at all (a missing .env means the
# required-keys check below has nothing to read; report it as its own line).
doctor_check_env_file() {
  if [ -f "$ENV_FILE" ]; then
    doctor_line PASS "$ENV_FILE present"
    return 0
  fi
  doctor_line FAIL "$ENV_FILE present" "missing — run ./start.sh <repo> once to create it"
  return 1
}

# doctor_check_env_keys — required keys are non-empty; optional keys are
# reported as set/unset. NEVER prints a secret's value, only whether it is
# set, so this output is safe to paste into a chat or ticket.
#
# The required set is required_keys() (lib/config.sh) — the single source of
# truth shared with the ncurses first-run "Done" gate (run_tui_reconfigure
# --first-run) — read into an array here rather than hardcoded, so the two
# can't silently drift apart.
doctor_check_env_keys() {
  local rc=0
  local required=() optional=(BITBUCKET_BASE_URL BITBUCKET_USER BITBUCKET_PAT JIRA_BASE_URL JIRA_PAT GITLAB_BASE_URL GITLAB_USER GITLAB_PAT JFROG_BASE_URL JFROG_PAT CONFLUENCE_BASE_URL CONFLUENCE_PAT GIT_USER_NAME GIT_USER_EMAIL ENABLED_PLUGINS USER_LAYER_PATH IMAGE_TAG)
  local key val
  while IFS= read -r key; do
    [ -n "$key" ] && required+=("$key")
  done < <(required_keys)

  if [ ! -f "$ENV_FILE" ]; then
    for key in "${required[@]}"; do
      doctor_line FAIL "env: $key" "unset ($ENV_FILE missing)"
    done
    return 1
  fi

  for key in "${required[@]}"; do
    val="$(get_env "$key")"
    if [ -n "$val" ]; then
      doctor_line PASS "env: $key" "set"
    else
      doctor_line FAIL "env: $key" "unset — required"
      rc=1
    fi
  done

  for key in "${optional[@]}"; do
    val="$(get_env "$key")"
    if [ -n "$val" ]; then
      doctor_line PASS "env: $key" "set"
    else
      doctor_line WARN "env: $key" "unset (optional)"
    fi
  done

  return "$rc"
}

# doctor_check_env_drift — WARN if .env.example carries key(s) the user's .env
# is missing (reuses check_env_drift). Keys only, never values, so the report
# stays paste-safe. Informational: never fails the overall report.
doctor_check_env_drift() {
  local drift_keys
  [ -f "$ENV_FILE" ] || return 0
  drift_keys="$(check_env_drift "$ENV_EXAMPLE" "$ENV_FILE")"
  if [ -n "$drift_keys" ]; then
    doctor_line WARN "env: new keys in $ENV_EXAMPLE" \
      "$(printf '%s' "$drift_keys" | tr '\n' ' ' | sed 's/[[:space:]]*$//') — run ./start.sh --reconfigure to add them"
  else
    doctor_line PASS "env: in sync with $ENV_EXAMPLE"
  fi
  return 0
}

# doctor_check_image_pin [TAG] — WARN (never FAIL) when IMAGE_TAG pins the image
# to a specific version/digest instead of tracking `latest`. Only the newest
# launcher + the `latest` image is a tested pairing (CHANGELOG "Compatibility"),
# so a pin is worth surfacing — but it's a deliberate choice, not a broken
# environment, hence WARN. The `local` self-built sentinel is not a pin (see
# image_tag_pinned). Reads IMAGE_TAG from $ENV_FILE by default; a TAG argument
# exists purely for testability.
doctor_check_image_pin() {
  local tag
  if [ "$#" -ge 1 ]; then
    tag="$1"
  elif [ -f "$ENV_FILE" ]; then
    tag="$(get_env IMAGE_TAG)"
  else
    tag=""
  fi
  if image_tag_pinned "$tag"; then
    doctor_line WARN "image tag" "pinned to $tag — only IMAGE_TAG=latest is a tested pairing (set IMAGE_TAG=latest to track it)"
  else
    doctor_line PASS "image tag" "tracks latest"
  fi
  return 0
}

# doctor_check_launcher_update [DIR] — best-effort launcher-self-update check
# (see lib/update.sh). PASS "launcher up to date" when 0 commits behind, WARN
# (never FAIL — this is informational, not a broken environment) naming the
# count when behind, and a neutral skipped WARN when it can't be determined at
# all (not a git checkout, no upstream configured, offline, `git`/`timeout`
# missing, etc.) — the common case for a tarball install or an air-gapped host,
# and never a problem to flag as such. Defaults DIR to $SCRIPT_DIR (the
# launcher's own checkout — set in main() and visible here via bash's dynamic
# scoping, same pattern as doctor_check_disk_space below); a DIR argument
# exists purely for testability.
doctor_check_launcher_update() {
  local dir="${1:-$SCRIPT_DIR}" behind
  behind="$(launcher_behind_count "$dir")"
  case "$behind" in
    ''|*[!0-9]*)
      doctor_line WARN "launcher update check" "skipped (no upstream/offline)" ;;
    0)
      doctor_line PASS "launcher up to date" ;;
    *)
      doctor_line WARN "launcher update check" "$behind commit(s) behind origin — git pull" ;;
  esac
  return 0
}

# doctor_check_disk_space [PATH] — best-effort free-space check for image
# pulls. Never fails hard: no `df`, unparsable output, etc. all degrade to an
# informational WARN rather than blocking --doctor's exit code.
doctor_check_disk_space() {
  local path="${1:-.}" avail_kb
  if ! command -v df >/dev/null 2>&1; then
    doctor_line WARN "disk space" "'df' not available — skipped"
    return 0
  fi
  avail_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if ! [ "$avail_kb" -ge 0 ] 2>/dev/null; then
    doctor_line WARN "disk space" "could not determine free space — skipped"
    return 0
  fi
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt 5 ]; then
    doctor_line WARN "disk space" "${avail_gb}G free on $path — image pulls may need more"
  else
    doctor_line PASS "disk space" "${avail_gb}G free on $path"
  fi
  return 0
}

# cmd_doctor [REPO_PATH] — run every check above and print one pasteable
# report. Returns 1 if any check FAILed, 0 otherwise (WARN never fails it).
# This is a pure diagnostic: it never pulls images, never boots the stack,
# never attaches the TUI.
cmd_doctor() {
  local repo_path="${1:-}"
  local overall_rc=0
  local IMAGE_REGISTRY IMAGE_TAG REGISTRY_HOST CHECK_IMAGE

  echo "OpenCode Launcher doctor report"
  echo "================================"

  doctor_check_docker_present || overall_rc=1
  doctor_check_docker_daemon || overall_rc=1
  doctor_check_compose_v2 || overall_rc=1
  doctor_check_podman || true

  doctor_check_env_file || overall_rc=1
  doctor_check_env_keys || overall_rc=1
  doctor_check_env_drift
  doctor_check_image_pin

  IMAGE_REGISTRY="$(get_env IMAGE_REGISTRY 2>/dev/null || true)"
  if [ -n "$IMAGE_REGISTRY" ]; then
    IMAGE_TAG="$(get_env IMAGE_TAG 2>/dev/null || true)"
    [ -n "$IMAGE_TAG" ] || IMAGE_TAG="latest"
    REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
    CHECK_IMAGE="$(compute_base_image "$IMAGE_REGISTRY" "$IMAGE_TAG")"
    doctor_check_registry_access "$CHECK_IMAGE" "$REGISTRY_HOST" || overall_rc=1
    doctor_check_image_manifest "$CHECK_IMAGE"
  else
    doctor_line WARN "registry access" "skipped — IMAGE_REGISTRY not set"
    doctor_line WARN "image manifest" "skipped — IMAGE_REGISTRY not set"
  fi

  doctor_check_launcher_update || true

  if [ -n "$repo_path" ]; then
    if [ -e "$repo_path" ] && [ -d "$repo_path" ]; then
      local abs_repo slug
      abs_repo="$(cd -- "$repo_path" >/dev/null 2>&1 && pwd)" || abs_repo="$repo_path"
      slug="$(derive_slug "$abs_repo")"
      doctor_line PASS "project: $slug" "repo path OK"
    else
      doctor_line WARN "project" "repo path not found/usable: $repo_path"
    fi
  fi

  doctor_check_disk_space "$SCRIPT_DIR"

  echo "================================"
  if [ "$overall_rc" -eq 0 ]; then
    info "doctor: all critical checks passed (WARN lines above are informational)."
  else
    err "doctor: one or more critical checks FAILED — see [FAIL] lines above."
  fi
  return "$overall_rc"
}
