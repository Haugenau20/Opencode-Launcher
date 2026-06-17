#!/usr/bin/env bats
#
# Unit tests for the pure helpers in start.sh. These source the script (which is
# side-effect-free thanks to the main() source-guard) and call functions
# directly.

setup() {
  load common
  # ENV_FILE is read at source time; point it at a per-test scratch file.
  export ENV_FILE="$BATS_TEST_TMPDIR/.env"
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
  [[ "$output" == *"[WARN] env: BITBUCKET_USER"* ]]
  [[ "$output" == *"[WARN] env: BITBUCKET_PAT"* ]]
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
