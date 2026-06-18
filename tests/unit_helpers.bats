#!/usr/bin/env bats
#
# Unit tests for the pure helpers in start.sh. These source the script (which is
# side-effect-free thanks to the main() source-guard) and call functions
# directly.

setup() {
  load common
  # ENV_FILE/ENVS_DIR are read at source time; point them at per-test scratch
  # paths so digest-state-file writes never touch the real repo's .envs/.
  export ENV_FILE="$BATS_TEST_TMPDIR/.env"
  export ENVS_DIR="$BATS_TEST_TMPDIR/.envs"
  source "$REPO_ROOT/start.sh"
}

# --- derive_slug ------------------------------------------------------------

@test "derive_slug: lowercases and replaces spaces/punctuation with dashes" {
  run derive_slug "/home/u/My Cool Repo!!"
  [ "$status" -eq 0 ]
  [ "$output" = "my-cool-repo" ]
}

@test "derive_slug: collapses runs of dashes and trims leading/trailing" {
  run derive_slug "/x/--a..b--"
  [ "$output" = "a-b" ]
}

@test "derive_slug: keeps underscores and digits" {
  run derive_slug "/x/My_Repo_2"
  [ "$output" = "my_repo_2" ]
}

@test "derive_slug: falls back to 'project' when nothing survives" {
  run derive_slug "/x/!!!"
  [ "$output" = "project" ]
}

# --- sed_escape / set_env / get_env round-trip ------------------------------

@test "sed_escape: escapes backslash, ampersand and pipe" {
  run sed_escape 'a\b&c|d'
  [ "$output" = 'a\\b\&c\|d' ]
}

@test "set_env/get_env: round-trips a value with sed-special characters" {
  printf 'LLM_API_KEY=\n' > "$ENV_FILE"
  set_env LLM_API_KEY 'p@ss|w&rd\x'
  run get_env LLM_API_KEY
  [ "$output" = 'p@ss|w&rd\x' ]
}

@test "get_env: preserves '=' and '/' inside the value" {
  printf 'LLM_API_BASE=https://h/v1?a=b&c=d\n' > "$ENV_FILE"
  run get_env LLM_API_BASE
  [ "$output" = 'https://h/v1?a=b&c=d' ]
}

# --- mask_secret -------------------------------------------------------------

@test "mask_secret: reports '(empty)' for an empty value" {
  run mask_secret ""
  [ "$output" = "(empty)" ]
}

@test "mask_secret: never echoes a non-empty secret value" {
  run mask_secret "sk-super-secret-xyz"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-super-secret-xyz"* ]]
  [[ "$output" == *"press Enter to keep"* ]]
}

@test "set_env: only rewrites the anchored key, not a same-prefixed one" {
  printf 'HOST_UID=1\nHOST_GID=2\n' > "$ENV_FILE"
  set_env HOST_UID 1000
  [ "$(get_env HOST_UID)" = "1000" ]
  [ "$(get_env HOST_GID)" = "2" ]
}

@test "get_env: returns empty for a missing key" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  run get_env NOPE
  [ "$output" = "" ]
}

# --- find_free_port (port_in_use stubbed) -----------------------------------

@test "find_free_port: returns START when it is free" {
  port_in_use() { return 1; }   # nothing is in use
  run find_free_port 4097 4196
  [ "$output" = "4097" ]
}

@test "find_free_port: skips busy ports and returns the first free one" {
  # 4097 and 4098 busy, 4099 free.
  port_in_use() { case "$1" in 4097|4098) return 0 ;; *) return 1 ;; esac; }
  run find_free_port 4097 4196
  [ "$output" = "4099" ]
}

@test "find_free_port: stops at LIMIT even if everything is busy" {
  port_in_use() { return 0; }   # everything busy
  run find_free_port 4097 4100
  [ "$output" = "4100" ]
}

# --- project_running (docker stubbed) ---------------------------------------

@test "project_running: true when compose ls lists the project name" {
  docker() {
    if [ "$1" = compose ] && [ "$2" = ls ]; then
      printf '%s\n' "opencode-my-service	running(3)"
      return 0
    fi
    return 1
  }
  run project_running "opencode-my-service"
  [ "$status" -eq 0 ]
}

@test "project_running: false when compose ls does not list the project" {
  docker() {
    if [ "$1" = compose ] && [ "$2" = ls ]; then
      printf '%s\n' "opencode-other	exited(0)"
      return 0
    fi
    return 1
  }
  run project_running "opencode-my-service"
  [ "$status" -ne 0 ]
}

@test "project_running: false when compose ls reports nothing" {
  docker() {
    if [ "$1" = compose ] && [ "$2" = ls ]; then
      return 0
    fi
    return 1
  }
  run project_running "opencode-my-service"
  [ "$status" -ne 0 ]
}

# --- open_url (opener stubbed via PATH) -------------------------------------

# wait_for_file FILE — poll briefly for FILE to appear/be non-empty. open_url
# launches the opener in the background by design (never blocks the boot
# flow), so tests poll for its write instead of relying on shell job-control
# (`wait`), which doesn't reliably see jobs backgrounded inside a `run`/
# command-substitution subshell.
wait_for_file() {
  local f="$1" tries=50
  while [ "$tries" -gt 0 ]; do
    [ -s "$f" ] && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

@test "open_url: launches the resolved opener with the URL" {
  local bin="$BATS_TEST_TMPDIR/openbin"
  mkdir -p "$bin"
  cat > "$bin/xdg-open" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPEN_URL_LOG"
SCRIPT
  chmod +x "$bin/xdg-open"
  export OPEN_URL_LOG="$BATS_TEST_TMPDIR/open.log"
  run env PATH="$bin:$PATH" OPEN_URL_LOG="$OPEN_URL_LOG" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; open_url "http://localhost:4096"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"launching xdg-open"* ]]
  wait_for_file "$OPEN_URL_LOG"
  grep -q 'http://localhost:4096' "$OPEN_URL_LOG"
}

@test "open_url: warns (non-fatal) when the opener is missing" {
  run env PATH="/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; open_url "http://localhost:4096"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found on PATH"* ]]
  [[ "$output" == *"http://localhost:4096"* ]]
}

@test "open_url: honors an OPENER override" {
  local bin="$BATS_TEST_TMPDIR/openbin2"
  mkdir -p "$bin"
  cat > "$bin/my-custom-opener" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPEN_URL_LOG"
SCRIPT
  chmod +x "$bin/my-custom-opener"
  export OPEN_URL_LOG="$BATS_TEST_TMPDIR/open2.log"
  run env PATH="$bin:$PATH" OPENER=my-custom-opener OPEN_URL_LOG="$OPEN_URL_LOG" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; open_url "http://localhost:4096"'
  [ "$status" -eq 0 ]
  wait_for_file "$OPEN_URL_LOG"
  grep -q 'http://localhost:4096' "$OPEN_URL_LOG"
}

# --- extra_packages_active / strip_pkg_comments -----------------------------

@test "extra_packages_active: false when the file is absent" {
  run extra_packages_active "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -ne 0 ]
}

@test "extra_packages_active: false when only comments and blank lines" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# a comment' '' '   ' '# cmake' > "$f"
  run extra_packages_active "$f"
  [ "$status" -ne 0 ]
}

@test "extra_packages_active: true when a real package line is present" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# pick your tools' '' 'cmake' > "$f"
  run extra_packages_active "$f"
  [ "$status" -eq 0 ]
}

@test "strip_pkg_comments: drops comments/blanks, keeps package lines" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# header' '' 'cmake' '  ' 'ripgrep' > "$f"
  run strip_pkg_comments "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'cmake\nripgrep')" ]
}

# --- compute_base_image -----------------------------------------------------

@test "compute_base_image: joins REGISTRY and TAG" {
  run compute_base_image reg.test.local/opencode latest
  [ "$output" = "reg.test.local/opencode:latest" ]
}

@test "compute_base_image: passes a pinned version tag through" {
  run compute_base_image reg.test.local/opencode 0.0.2
  [ "$output" = "reg.test.local/opencode:0.0.2" ]
}

@test "compute_base_image: an '@sha256:...' TAG joins with '@', not ':'" {
  run compute_base_image reg.test.local/opencode "@sha256:abcdef0123456789"
  [ "$output" = "reg.test.local/opencode@sha256:abcdef0123456789" ]
}

@test "compute_base_image: a bare 'sha256:...' TAG also joins with '@'" {
  run compute_base_image reg.test.local/opencode "sha256:abcdef0123456789"
  [ "$output" = "reg.test.local/opencode@sha256:abcdef0123456789" ]
}

# --- doctor_line --------------------------------------------------------------

@test "doctor_line: PASS with no detail prints just status and label" {
  run doctor_line PASS "docker on PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == "[PASS] docker on PATH" ]]
}

@test "doctor_line: includes the detail when given one" {
  run doctor_line FAIL "docker daemon reachable" "permission denied"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FAIL]"* ]]
  [[ "$output" == *"docker daemon reachable"* ]]
  [[ "$output" == *"permission denied"* ]]
}

# --- doctor_check_env_keys ----------------------------------------------------

@test "doctor_check_env_keys: PASSes required keys when all are set" {
  printf '%s\n' 'LLM_API_BASE=https://llm.test/v1' 'LLM_API_KEY=sk-secret' \
    'IMAGE_REGISTRY=reg.test.local/opencode' > "$ENV_FILE"
  run doctor_check_env_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] env: LLM_API_BASE"* ]]
  [[ "$output" == *"[PASS] env: LLM_API_KEY"* ]]
  [[ "$output" == *"[PASS] env: IMAGE_REGISTRY"* ]]
}

@test "doctor_check_env_keys: FAILs and returns non-zero when a required key is empty" {
  printf '%s\n' 'LLM_API_BASE=https://llm.test/v1' 'LLM_API_KEY=' \
    'IMAGE_REGISTRY=reg.test.local/opencode' > "$ENV_FILE"
  run doctor_check_env_keys
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] env: LLM_API_KEY"* ]]
  [[ "$output" == *"unset"* ]]
}

@test "doctor_check_env_keys: optional unset keys are WARN, not FAIL" {
  printf '%s\n' 'LLM_API_BASE=https://llm.test/v1' 'LLM_API_KEY=sk-secret' \
    'IMAGE_REGISTRY=reg.test.local/opencode' > "$ENV_FILE"
  run doctor_check_env_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] env: BITBUCKET_BASE_URL"* ]]
  [[ "$output" == *"[WARN] env: BITBUCKET_USER"* ]]
  [[ "$output" == *"[WARN] env: BITBUCKET_PAT"* ]]
  [[ "$output" == *"[WARN] env: JIRA_BASE_URL"* ]]
  [[ "$output" == *"[WARN] env: JIRA_PAT"* ]]
  [[ "$output" == *"[WARN] env: GITLAB_BASE_URL"* ]]
  [[ "$output" == *"[WARN] env: GITLAB_USER"* ]]
  [[ "$output" == *"[WARN] env: GITLAB_PAT"* ]]
}

@test "doctor_check_env_keys: never prints the secret value, only set/unset" {
  printf '%s\n' 'LLM_API_BASE=https://llm.test/v1' 'LLM_API_KEY=sk-super-secret-xyz' \
    'IMAGE_REGISTRY=reg.test.local/opencode' 'BITBUCKET_PAT=another-secret-token' \
    > "$ENV_FILE"
  run doctor_check_env_keys
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-super-secret-xyz"* ]]
  [[ "$output" != *"another-secret-token"* ]]
}

@test "doctor_check_env_keys: missing env file FAILs all required keys" {
  rm -f "$ENV_FILE"
  run doctor_check_env_keys
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] env: LLM_API_BASE"* ]]
  [[ "$output" == *"[FAIL] env: LLM_API_KEY"* ]]
  [[ "$output" == *"[FAIL] env: IMAGE_REGISTRY"* ]]
}

# --- doctor_check_port ---------------------------------------------------------

@test "doctor_check_port: PASSes a free port" {
  port_in_use() { return 1; }
  run doctor_check_port 4096 "web UI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] port 4096 free (web UI)"* ]]
}

@test "doctor_check_port: WARNs (not FAILs) a busy port" {
  port_in_use() { return 0; }
  run doctor_check_port 4096 "web UI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] port 4096 free (web UI)"* ]]
}

# --- url_host -----------------------------------------------------------------

@test "url_host: strips scheme and path, keeps host" {
  run url_host "https://llm.internal.example/v1"
  [ "$output" = "llm.internal.example" ]
}

@test "url_host: keeps a port if present" {
  run url_host "https://llm.internal.example:8443/v1/chat"
  [ "$output" = "llm.internal.example:8443" ]
}

@test "url_host: passes through a bare host unchanged" {
  run url_host "llm.internal.example"
  [ "$output" = "llm.internal.example" ]
}

# --- list_extra_allowlist_files ------------------------------------------------

@test "list_extra_allowlist_files: empty when the dir is absent" {
  run list_extra_allowlist_files "$BATS_TEST_TMPDIR/nope-dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list_extra_allowlist_files: empty when the dir has no .conf files" {
  local d="$BATS_TEST_TMPDIR/allow1"
  mkdir -p "$d"
  : > "$d/.gitkeep"
  run list_extra_allowlist_files "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list_extra_allowlist_files: lists .conf files, sorted" {
  local d="$BATS_TEST_TMPDIR/allow2"
  mkdir -p "$d"
  : > "$d/zzz.conf"
  : > "$d/aaa.conf"
  : > "$d/notconf.txt"
  run list_extra_allowlist_files "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s' "$d/aaa.conf" "$d/zzz.conf")" ]
}

# --- allowlist_summary_line -----------------------------------------------------

@test "allowlist_summary_line: reports the LLM host and no local extensions" {
  printf 'LLM_API_BASE=https://llm.test/v1\n' > "$ENV_FILE"
  cd "$BATS_TEST_TMPDIR"
  run allowlist_summary_line
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM(llm.test)"* ]]
  [[ "$output" != *"local extension file"* ]]
  [[ "$output" == *"--show-allowlist"* ]]
}

@test "allowlist_summary_line: counts local extension files" {
  printf 'LLM_API_BASE=https://llm.test/v1\n' > "$ENV_FILE"
  cd "$BATS_TEST_TMPDIR"
  mkdir -p extra-allowlist.d
  : > extra-allowlist.d/one.conf
  run allowlist_summary_line
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 local extension file(s)"* ]]
}

# --- get_image_digest / short_digest --------------------------------------------

@test "get_image_digest: echoes the RepoDigest docker image inspect reports" {
  docker() {
    if [ "$1" = image ] && [ "$2" = inspect ]; then
      printf '%s\n' "reg.test.local/opencode@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      return 0
    fi
    return 1
  }
  run get_image_digest "reg.test.local/opencode:latest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha256:abcdef0123456789"* ]]
}

@test "get_image_digest: returns non-zero when docker fails" {
  docker() { return 1; }
  run get_image_digest "reg.test.local/opencode:latest"
  [ "$status" -ne 0 ]
}

@test "short_digest: trims to a 12-hex-char short form" {
  run short_digest "reg.test.local/opencode@sha256:abcdef0123456789abcdef0123456789"
  [ "$output" = "sha256:abcdef012345" ]
}

# --- digest_state_file / report_digest_update -----------------------------------

@test "digest_state_file: path is under ENVS_DIR named by slug" {
  run digest_state_file "my-service"
  [ "$output" = "${ENVS_DIR}/my-service.digest" ]
}

@test "report_digest_update: first run (no prior record) is silent but writes the file" {
  run report_digest_update "myslug" "sha256:aaaa1111"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$(digest_state_file myslug)" ]
  [ "$(cat "$(digest_state_file myslug)")" = "sha256:aaaa1111" ]
}

@test "report_digest_update: unchanged digest stays silent" {
  report_digest_update "myslug" "sha256:aaaa1111"
  run report_digest_update "myslug" "sha256:aaaa1111"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "report_digest_update: changed digest prints an INFO nudge" {
  report_digest_update "myslug" "sha256:aaaa1111"
  run report_digest_update "myslug" "sha256:bbbb2222"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image updated:"* ]]
  [ "$(cat "$(digest_state_file myslug)")" = "sha256:bbbb2222" ]
}

@test "report_digest_update: empty digest is a no-op" {
  run report_digest_update "myslug" ""
  [ "$status" -eq 0 ]
  [ ! -f "$(digest_state_file myslug)" ]
}

# --- env_example_keys / check_env_drift -----------------------------------------

@test "env_example_keys: lists key names, comments and blanks ignored" {
  local f="$BATS_TEST_TMPDIR/ex.env"
  printf '%s\n' '# comment' '' 'FOO=bar' 'BAZ=' > "$f"
  run env_example_keys "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'FOO\nBAZ')" ]
}

@test "check_env_drift: empty when .env has every .env.example key" {
  local ex="$BATS_TEST_TMPDIR/ex.env" envf="$BATS_TEST_TMPDIR/real.env"
  printf '%s\n' 'FOO=' 'BAR=' > "$ex"
  printf '%s\n' 'FOO=1' 'BAR=2' > "$envf"
  run check_env_drift "$ex" "$envf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_env_drift: reports a key present in .env.example but missing from .env" {
  local ex="$BATS_TEST_TMPDIR/ex.env" envf="$BATS_TEST_TMPDIR/real.env"
  printf '%s\n' 'FOO=' 'NEWKEY=' > "$ex"
  printf '%s\n' 'FOO=1' > "$envf"
  run check_env_drift "$ex" "$envf"
  [ "$status" -eq 0 ]
  [ "$output" = "NEWKEY" ]
}

@test "check_env_drift: never prints values, only key names" {
  local ex="$BATS_TEST_TMPDIR/ex.env" envf="$BATS_TEST_TMPDIR/real.env"
  printf '%s\n' 'SECRET_KEY=' > "$ex"
  printf '%s\n' > "$envf"
  run check_env_drift "$ex" "$envf"
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret"* ]]
  [ "$output" = "SECRET_KEY" ]
}

# --- editable_schema_keys ----------------------------------------------------

@test "editable_schema_keys: excludes internal-typed keys" {
  run editable_schema_keys
  [ "$status" -eq 0 ]
  [[ "$output" != *"HOST_UID"* ]]
  [[ "$output" != *"HOST_GID"* ]]
  [[ "$output" != *"IMAGE_TAG"* ]]
}

@test "editable_schema_keys: includes bool safety switches and non-internal keys" {
  run editable_schema_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOW_REMOTE_GIT"* ]]
  [[ "$output" == *"ENABLE_SESSION_LOGS"* ]]
  [[ "$output" == *"USER_LAYER_PATH"* ]]
  [[ "$output" == *"LLM_API_BASE"* ]]
  [[ "$output" == *"IMAGE_REGISTRY"* ]]
}

@test "editable_schema_keys: every line is a real config_schema key, in schema order" {
  run editable_schema_keys
  [ "$status" -eq 0 ]
  local expected
  expected="$(config_schema | awk -F'|' '$3 != "internal" { print $2 }')"
  [ "$output" = "$expected" ]
}

# --- cmd_config_show ----------------------------------------------------------

@test "cmd_config_show: never prints a configured secret value" {
  printf 'LLM_API_KEY=sk-super-secret-value\nBITBUCKET_PAT=bb-super-secret-pat\n' > "$ENV_FILE"
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-super-secret-value"* ]]
  [[ "$output" != *"bb-super-secret-pat"* ]]
  [[ "$output" == *"(secret, set)"* ]]
}

@test "cmd_config_show: shows [set] and the mask for a non-empty secret" {
  printf 'LLM_API_KEY=sk-super-secret-value\n' > "$ENV_FILE"
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" == *"[set]"*"LLM_API_KEY"*"(secret, set)"* ]]
}

@test "cmd_config_show: shows plain url/text values in cleartext" {
  printf 'LLM_API_BASE=https://llm.internal.example/v1\nGIT_USER_NAME=Jane Dev\n' > "$ENV_FILE"
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://llm.internal.example/v1"* ]]
  [[ "$output" == *"Jane Dev"* ]]
}

@test "cmd_config_show: marks an unset (empty) key as unset" {
  printf 'LLM_API_BASE=\nBITBUCKET_PAT=\n' > "$ENV_FILE"
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ -- ]"*"LLM_API_BASE"*"(unset)"* ]]
  [[ "$output" == *"[ -- ]"*"BITBUCKET_PAT"*"(unset)"* ]]
}

@test "cmd_config_show: missing .env is reported but never created" {
  [ ! -f "$ENV_FILE" ]
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -f "$ENV_FILE" ]
}

@test "cmd_config_show: groups keys under their field_group section header" {
  printf 'LLM_API_BASE=https://llm.test/v1\n' > "$ENV_FILE"
  run cmd_config_show
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM"* ]]
  [[ "$output" == *"Bitbucket"* ]]
}

# --- prompt_one_key -----------------------------------------------------------

@test "prompt_one_key: required secret (LLM_API_KEY) first-run prompt text is pinned" {
  printf 'LLM_API_KEY=\n' > "$ENV_FILE"
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    export ENV_FILE="'"$ENV_FILE"'"
    printf "sk-newkey\n" | { prompt_one_key LLM_API_KEY; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM API key (input hidden): "* ]]
}

@test "prompt_one_key: --reconfigure secret prompt uses the masked hint form" {
  printf 'LLM_API_KEY=already-set\n' > "$ENV_FILE"
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    export ENV_FILE="'"$ENV_FILE"'"
    printf "\n" | { prompt_one_key LLM_API_KEY --reconfigure; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"set, press Enter to keep"* ]]
  [[ "$output" != *"already-set"* ]]
  [ "$(get_env LLM_API_KEY)" = "already-set" ]
}

@test "prompt_one_key: bool field toggles via 0/1 and defaults to current value" {
  printf 'ALLOW_REMOTE_GIT=1\n' > "$ENV_FILE"
  printf '\n' | prompt_one_key ALLOW_REMOTE_GIT --reconfigure
  [ "$(get_env ALLOW_REMOTE_GIT)" = "1" ]

  printf 'ALLOW_REMOTE_GIT=1\n' > "$ENV_FILE"
  printf '0\n' | prompt_one_key ALLOW_REMOTE_GIT --reconfigure
  [ "$(get_env ALLOW_REMOTE_GIT)" = "0" ]
}

@test "prompt_one_key: optional Bitbucket PAT prompt text is pinned" {
  printf 'BITBUCKET_PAT=\n' > "$ENV_FILE"
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    export ENV_FILE="'"$ENV_FILE"'"
    printf "\n" | { prompt_one_key BITBUCKET_PAT; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bitbucket personal access token (optional, Enter to skip, input hidden): "* ]]
}

# --- tui_backend / have_tui (ncurses config editor detection) ---------------
# tests/fake-bin/whiptail and tests/fake-bin/dialog are detection-only stubs
# (no real ncurses rendering) — see their headers. These tests only exercise
# the pure detection/gating logic (tui_backend, have_tui), never an actual
# interactive ncurses screen, since bats has no tty.

@test "tui_backend: echoes whiptail when it is on PATH" {
  run env PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; tui_backend'
  [ "$status" -eq 0 ]
  [ "$output" = "whiptail" ]
}

@test "tui_backend: falls back to dialog when whiptail is absent" {
  local bin="$BATS_TEST_TMPDIR/dialog-only-bin"
  mkdir -p "$bin"
  cp "$FAKE_BIN/dialog" "$bin/dialog"
  chmod +x "$bin/dialog"
  run env PATH="$bin:/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; tui_backend'
  [ "$status" -eq 0 ]
  [ "$output" = "dialog" ]
}

@test "tui_backend: empty when neither whiptail nor dialog is on PATH" {
  run env PATH="/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; tui_backend'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "have_tui: false when not a tty, even with whiptail present (bats is never a tty)" {
  run env PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; have_tui'
  [ "$status" -ne 0 ]
}

@test "have_tui: false when OC_CONFIG_TUI=0, even with whiptail present" {
  run env PATH="$FAKE_BIN:/usr/bin:/bin" OC_CONFIG_TUI=0 \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; have_tui'
  [ "$status" -ne 0 ]
}

@test "have_tui: false when no backend is installed at all" {
  run env PATH="/usr/bin:/bin" \
    bash -c 'source "'"$REPO_ROOT"'/start.sh"; have_tui'
  [ "$status" -ne 0 ]
}

# --- tui_* wrappers (Cancel/Esc safety) --------------------------------------
# Stub the backend directly (rather than relying on tui_backend's PATH probe)
# so these stay lightweight and don't depend on which fake binary won the
# PATH race. Each wrapper must survive a non-zero "Cancel" exit under
# set -euo pipefail without killing the caller.

@test "tui_input: a Cancel (non-zero) exit falls back to the default, not a script error" {
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-cancel-backend"; }
    fake-cancel-backend() { return 1; }
    set -euo pipefail
    tui_input "Title" "Label" "the-default"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "the-default" ]
}

@test "tui_password: a Cancel (non-zero) exit yields empty, not a script error" {
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-cancel-backend"; }
    fake-cancel-backend() { return 1; }
    set -euo pipefail
    tui_password "Title" "Label"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tui_menu: a Cancel (non-zero) exit yields empty, not a script error" {
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-cancel-backend"; }
    fake-cancel-backend() { return 1; }
    set -euo pipefail
    tui_menu "Title" "Prompt" KEY1 "Item 1" DONE "Done"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tui_yesno: propagates Yes (0) and No (1) without tripping set -e" {
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-yes-backend"; }
    fake-yes-backend() { return 0; }
    set -euo pipefail
    if tui_yesno "Title" "Label"; then echo YES; else echo NO; fi
  '
  [ "$status" -eq 0 ]
  [ "$output" = "YES" ]

  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-no-backend"; }
    fake-no-backend() { return 1; }
    set -euo pipefail
    if tui_yesno "Title" "Label"; then echo YES; else echo NO; fi
  '
  [ "$status" -eq 0 ]
  [ "$output" = "NO" ]
}
