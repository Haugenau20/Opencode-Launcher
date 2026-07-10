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

@test "set_env: appends a key that is not already present, leaving others intact" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  set_env NEWKEY hello
  [ "$(get_env NEWKEY)" = "hello" ]
  [ "$(get_env FOO)" = "bar" ]
}

@test "set_env: an appended value round-trips through sed-special characters" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  set_env JIRA_PAT 'p@ss|w&rd\x'
  [ "$(get_env JIRA_PAT)" = 'p@ss|w&rd\x' ]
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

# --- viewer_port_for / port_pair_free (opencode-pty viewer-port coupling) ---
# Fresh port assignment must never hand out a base port whose derived
# opencode-pty viewer port (1<base>) is already taken by something else —
# oc-publish's second socat leg would then fail to bind, breaking
# `docker compose up`. See lib/project.sh.

@test "viewer_port_for: prepends a literal '1' to the base port" {
  run viewer_port_for 4096
  [ "$output" = "14096" ]
}

@test "port_pair_free: true when neither the base nor its viewer port is busy" {
  port_in_use() { return 1; }   # nothing busy
  run port_pair_free 4096
  [ "$status" -eq 0 ]
}

@test "port_pair_free: false when only the base port is busy" {
  port_in_use() { [ "$1" = 4096 ] && return 0 || return 1; }
  run port_pair_free 4096
  [ "$status" -ne 0 ]
}

@test "port_pair_free: false when only the viewer port is busy" {
  port_in_use() { [ "$1" = 14096 ] && return 0 || return 1; }
  run port_pair_free 4096
  [ "$status" -ne 0 ]
}

@test "find_free_port: skips a candidate whose viewer port is busy, even though the base port itself is free" {
  # 4097's base port is free, but its viewer port 14097 is busy — must be
  # skipped in favor of 4098 (whose base AND viewer port are both free).
  port_in_use() { [ "$1" = 14097 ] && return 0 || return 1; }
  run find_free_port 4097 4196
  [ "$output" = "4098" ]
}

# --- resolve_project_port / publish_container_running (sticky ports) --------
# lib/project.sh — the fix for the "management commands clobber the recorded
# port" bug: ports must be sticky per project rather than recomputed on every
# call. port_in_use and docker (for publish_container_running's `docker ps`)
# are stubbed directly, same convention as the find_free_port tests above.

@test "recorded_port: empty when there is no .envs/<slug>.env file" {
  run recorded_port "no-such-project"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "recorded_port: reads OPENCODE_PORT out of .envs/<slug>.env" {
  mkdir -p "$ENVS_DIR"
  printf 'PROJECT_SLUG=demo\nOPENCODE_PORT=5555\nREPO_PATH=/x\n' > "$ENVS_DIR/demo.env"
  run recorded_port demo
  [ "$output" = "5555" ]
}

# --- pty_enabled (opencode-pty viewer-URL gating) ---------------------------

@test "pty_enabled: false when the file does not exist" {
  run pty_enabled "$BATS_TEST_TMPDIR/no-such.env"
  [ "$status" -ne 0 ]
}

@test "pty_enabled: false when ENABLED_PLUGINS is empty" {
  local f="$BATS_TEST_TMPDIR/empty.env"
  printf 'ENABLED_PLUGINS=\n' > "$f"
  run pty_enabled "$f"
  [ "$status" -ne 0 ]
}

@test "pty_enabled: false when ENABLED_PLUGINS lists other plugins only" {
  local f="$BATS_TEST_TMPDIR/other.env"
  printf 'ENABLED_PLUGINS=superpowers dcp\n' > "$f"
  run pty_enabled "$f"
  [ "$status" -ne 0 ]
}

@test "pty_enabled: true when opencode-pty is among space-separated plugins" {
  local f="$BATS_TEST_TMPDIR/space.env"
  printf 'ENABLED_PLUGINS=superpowers opencode-pty dcp\n' > "$f"
  run pty_enabled "$f"
  [ "$status" -eq 0 ]
}

@test "pty_enabled: true when opencode-pty is comma-separated" {
  local f="$BATS_TEST_TMPDIR/comma.env"
  printf 'ENABLED_PLUGINS=superpowers,opencode-pty\n' > "$f"
  run pty_enabled "$f"
  [ "$status" -eq 0 ]
}

@test "pty_enabled: false on a mere substring match (opencode-pty-fake)" {
  local f="$BATS_TEST_TMPDIR/substr.env"
  printf 'ENABLED_PLUGINS=opencode-pty-fake\n' > "$f"
  run pty_enabled "$f"
  [ "$status" -ne 0 ]
}

@test "publish_container_running: true when docker ps lists this project's oc-publish container" {
  docker() {
    [ "$1" = ps ] && printf 'opencode-publish-demo\n'
  }
  run publish_container_running demo
  [ "$status" -eq 0 ]
}

@test "publish_container_running: false when docker ps lists a different project's container" {
  docker() {
    [ "$1" = ps ] && printf 'opencode-publish-other\n'
  }
  run publish_container_running demo
  [ "$status" -ne 0 ]
}

@test "publish_container_running: false when docker ps lists nothing" {
  docker() { [ "$1" = ps ] && printf ''; }
  run publish_container_running demo
  [ "$status" -ne 0 ]
}

@test "resolve_project_port: (a) reuses the recorded port when this project's own oc-publish container is running, even though the port would otherwise look busy" {
  mkdir -p "$ENVS_DIR"
  printf 'OPENCODE_PORT=5555\n' > "$ENVS_DIR/demo.env"
  docker() { [ "$1" = ps ] && printf 'opencode-publish-demo\n'; }
  port_in_use() { return 0; }   # would look busy everywhere if this were consulted
  run resolve_project_port demo
  [ "$output" = "5555" ]
}

@test "resolve_project_port: running with no recorded port falls back to default logic" {
  docker() { [ "$1" = ps ] && printf 'opencode-publish-demo\n'; }
  port_in_use() { return 1; }   # 4096 free
  run resolve_project_port demo
  [ "$output" = "4096" ]
}

@test "resolve_project_port: (b) reuses the recorded port when it is free and the project is down" {
  mkdir -p "$ENVS_DIR"
  printf 'OPENCODE_PORT=5555\n' > "$ENVS_DIR/demo.env"
  docker() { [ "$1" = ps ] && printf ''; }   # not running
  port_in_use() { return 1; }   # nothing busy
  run resolve_project_port demo
  [ "$output" = "5555" ]
}

@test "resolve_project_port: (c) picks a new free port when the recorded port is taken by something else and the project is down" {
  mkdir -p "$ENVS_DIR"
  printf 'OPENCODE_PORT=5555\n' > "$ENVS_DIR/demo.env"
  docker() { [ "$1" = ps ] && printf ''; }   # not running
  # 5555 (recorded) and 4096 (default) both busy; 4097 is free.
  port_in_use() { case "$1" in 5555|4096) return 0 ;; *) return 1 ;; esac; }
  run resolve_project_port demo
  [ "$output" = "4097" ]
}

@test "resolve_project_port: no recorded port, nothing running, 4096 free -> defaults to 4096" {
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { return 1; }
  run resolve_project_port demo
  [ "$output" = "4096" ]
}

@test "resolve_project_port: no recorded port, 4096 busy -> first free port from 4097" {
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { [ "$1" = 4096 ] && return 0 || return 1; }
  run resolve_project_port demo
  [ "$output" = "4097" ]
}

@test "resolve_project_port: fresh assignment skips 4096 when only its viewer port (14096) is busy" {
  # Regression for the opencode-pty viewer-port coupling: 4096 itself is
  # free, but something else is already listening on 14096 (its derived
  # viewer port) — resolve_project_port must not hand out 4096 anyway, since
  # oc-publish's second socat leg would then fail to bind it.
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { [ "$1" = 14096 ] && return 0 || return 1; }
  run resolve_project_port demo
  [ "$output" = "4097" ]
}

# --- derive_project_settings is a pure compute step (no file writes) --------

@test "derive_project_settings: never writes .envs/<slug>.env (compute only)" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { return 1; }
  local repo="$BATS_TEST_TMPDIR/some-repo"
  mkdir -p "$repo"
  derive_project_settings "$repo"
  [ "$SLUG" = "some-repo" ]
  [ "$PORT" = "4096" ]
  [ ! -e "$PROJECT_ENV" ]
}

@test "derive_project_settings: reuses a recorded port instead of recomputing 4096" {
  mkdir -p "$ENVS_DIR"
  printf 'OPENCODE_PORT=5555\n' > "$ENVS_DIR/sticky-repo.env"
  printf 'FOO=bar\n' > "$ENV_FILE"
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { return 1; }   # everything free, including 4096
  local repo="$BATS_TEST_TMPDIR/sticky-repo"
  mkdir -p "$repo"
  derive_project_settings "$repo"
  [ "$PORT" = "5555" ]
}

# --- write_project_env / project_env_for_management -------------------------

@test "write_project_env: writes PROJECT_SLUG/OPENCODE_PORT/REPO_PATH using the caller's SLUG/PORT/PROJECT_ENV" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  mkdir -p "$ENVS_DIR"
  local SLUG=demo PORT=4096 PROJECT_ENV="$ENVS_DIR/demo.env"
  write_project_env "/some/repo"
  [ -f "$PROJECT_ENV" ]
  grep -q '^PROJECT_SLUG=demo$' "$PROJECT_ENV"
  grep -q '^OPENCODE_PORT=4096$' "$PROJECT_ENV"
  grep -q '^REPO_PATH=/some/repo$' "$PROJECT_ENV"
  grep -q '^FOO=bar$' "$PROJECT_ENV"
}

@test "write_project_env: succeeds under set -e even with no USER_LAYER_PATH set (regression: bare && as the last statement)" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  mkdir -p "$ENVS_DIR"
  local SLUG=demo PORT=4096 PROJECT_ENV="$ENVS_DIR/demo.env"
  # A bash `set -euo pipefail` gotcha: if the last statement in a function is
  # a short-circuited `[ cond ] && cmd` that evaluates false, the function
  # returns non-zero and can abort the whole script at the call site. This
  # test just needs to not abort (bats itself runs under bash, but the real
  # regression only shows up under a strict-mode caller — see the cli.bats
  # sticky-port boot tests for the end-to-end version of this check).
  run write_project_env "/some/repo"
  [ "$status" -eq 0 ]
}

@test "project_env_for_management: reuses .envs/<slug>.env verbatim (port not re-resolved) when it already exists" {
  mkdir -p "$ENVS_DIR"
  printf 'PROJECT_SLUG=demo\nOPENCODE_PORT=5555\nREPO_PATH=/old/path\n' > "$ENVS_DIR/demo.env"
  printf 'FOO=bar\n' > "$ENV_FILE"
  # If this were re-resolved, port_in_use reporting everything busy would
  # force a completely different port (or die trying); it must not be
  # consulted at all when the file already exists.
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { return 0; }
  local repo="$BATS_TEST_TMPDIR/demo"
  mkdir -p "$repo"
  project_env_for_management "$repo"
  [ "$SLUG" = "demo" ]
  [ "$PORT" = "5555" ]
  # File content is untouched — REPO_PATH still says /old/path, not $repo.
  grep -q '^REPO_PATH=/old/path$' "$PROJECT_ENV"
}

@test "project_env_for_management: generates .envs/<slug>.env when missing" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  docker() { [ "$1" = ps ] && printf ''; }
  port_in_use() { return 1; }
  local repo="$BATS_TEST_TMPDIR/fresh-repo"
  mkdir -p "$repo"
  project_env_for_management "$repo"
  [ -f "$PROJECT_ENV" ]
  grep -q '^OPENCODE_PORT=4096$' "$PROJECT_ENV"
  grep -q "^REPO_PATH=${repo}\$" "$PROJECT_ENV"
}

# --- project_running (docker stubbed) ---------------------------------------

@test "project_running: true when compose ls lists the project name" {
  docker() {
    if [ "$1" = compose ] && [ "$2" = ls ]; then
      printf '%s\n' '[{"Name":"opencode-my-service","Status":"running(3)"}]'
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
      printf '%s\n' '[{"Name":"opencode-other","Status":"exited(0)"}]'
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
      printf '%s\n' '[]'
      return 0
    fi
    return 1
  }
  run project_running "opencode-my-service"
  [ "$status" -ne 0 ]
}

# --- compose_ls_pairs (JSON parser) -----------------------------------------
# `docker compose ls --format` only supports table|json (NOT a Go template, the
# way `ps` does), so the launcher asks for json and parses it. These pin that.

@test "compose_ls_pairs: parses the real ls JSON (extra fields, comma config-files) into name<TAB>status" {
  docker() {
    if [ "$1" = compose ] && [ "$2" = ls ]; then
      printf '%s\n' '[{"Name":"opencode-scaffolder","Status":"running(3)","ConfigFiles":"/g/docker-compose.yml,/g/docker-compose.user-packages.yml"},{"Name":"rag","Status":"running(2)","ConfigFiles":"/g/ai_rag/docker-compose.yml"}]'
      return 0
    fi
    return 1
  }
  run compose_ls_pairs
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'opencode-scaffolder\trunning(3)')" ]
  [ "${lines[1]}" = "$(printf 'rag\trunning(2)')" ]
}

@test "compose_ls_pairs: empty array yields no lines and still succeeds (set -e safe)" {
  docker() { [ "$1" = compose ] && [ "$2" = ls ] && { printf '[]\n'; return 0; }; return 1; }
  run compose_ls_pairs
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
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

# --- doctor_check_env_drift ----------------------------------------------------

@test "doctor_check_env_drift: PASS when .env has every .env.example key" {
  local ex="$BATS_TEST_TMPDIR/ex" envf="$BATS_TEST_TMPDIR/envf"
  printf 'FOO=1\nBAR=2\n' > "$ex"
  printf 'FOO=x\nBAR=y\n' > "$envf"
  ENV_EXAMPLE="$ex" ENV_FILE="$envf" run doctor_check_env_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] env: in sync with"* ]]
}

@test "doctor_check_env_drift: WARNs (not FAILs) and names a missing key" {
  local ex="$BATS_TEST_TMPDIR/ex" envf="$BATS_TEST_TMPDIR/envf"
  printf 'FOO=1\nNEWKEY=2\n' > "$ex"
  printf 'FOO=x\n' > "$envf"
  ENV_EXAMPLE="$ex" ENV_FILE="$envf" run doctor_check_env_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] env: new keys in"* ]]
  [[ "$output" == *"NEWKEY"* ]]
}

@test "doctor_check_env_drift: reports key names only, never values" {
  local ex="$BATS_TEST_TMPDIR/ex" envf="$BATS_TEST_TMPDIR/envf"
  printf 'FOO=1\nNEWKEY=super-secret\n' > "$ex"
  printf 'FOO=x\n' > "$envf"
  ENV_EXAMPLE="$ex" ENV_FILE="$envf" run doctor_check_env_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEWKEY"* ]]
  [[ "$output" != *"super-secret"* ]]
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
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -f "$(digest_state_file myslug)" ]
  [ "$(cat "$(digest_state_file myslug)")" = "sha256:aaaa1111" ]
}

@test "report_digest_update: unchanged digest stays silent" {
  report_digest_update "myslug" "sha256:aaaa1111" || true  # first run: no prior record, returns 1
  run report_digest_update "myslug" "sha256:aaaa1111"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "report_digest_update: changed digest prints an INFO nudge and returns 0 (a change-flag return, not an error)" {
  report_digest_update "myslug" "sha256:aaaa1111" || true  # first run: no prior record, returns 1
  run report_digest_update "myslug" "sha256:bbbb2222"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image updated:"* ]]
  [ "$(cat "$(digest_state_file myslug)")" = "sha256:bbbb2222" ]
}

@test "report_digest_update: empty digest is a no-op" {
  run report_digest_update "myslug" ""
  [ "$status" -eq 1 ]
  [ ! -f "$(digest_state_file myslug)" ]
}

# --- image_manifest / manifest_env_keys / manifest_missing_keys ------------------

# A realistic manifest.json fixture matching the fixed image contract,
# including the whole env_keys array collapsed onto one line (as the
# contract's own example shows it) — the extraction must handle multiple
# "key" matches per line, not just one per line.
REALISTIC_MANIFEST='{
  "manifest_version": 1,
  "image_version": "0.0.7",
  "opencode_version": "1.17.11",
  "env_keys": [ {"key": "LLM_API_BASE", "required": true}, {"key": "JFROG_BASE_URL", "required": false}, {"key": "NEW_KEY_X", "required": false} ],
  "mcps": ["bitbucket", "gitlab", "jira", "jfrog", "confluence"],
  "plugins": ["superpowers", "dcp", "opencode-workspace"]
}'

@test "image_manifest: echoes manifest.json when the image exists and has one" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_MANIFEST="$REALISTIC_MANIFEST" \
    run image_manifest "reg.test.local/opencode:latest"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"image_version": "0.0.7"'* ]]
}

@test "image_manifest: silent (non-zero) when the image isn't present locally" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_IMAGE_INSPECT_RC=1 FAKE_DOCKER_MANIFEST="$REALISTIC_MANIFEST" \
    run image_manifest "reg.test.local/opencode:latest"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "image_manifest: silent (non-zero) on an old image with no manifest.json" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_MANIFEST="" \
    run image_manifest "reg.test.local/opencode:latest"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "manifest_env_keys: extracts every key from a realistic manifest, one line each" {
  run manifest_env_keys "$REALISTIC_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'LLM_API_BASE\nJFROG_BASE_URL\nNEW_KEY_X')" ]
}

@test "manifest_env_keys: also reads the manifest JSON from stdin" {
  run manifest_env_keys <<< "$REALISTIC_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM_API_BASE"* ]]
  [[ "$output" == *"NEW_KEY_X"* ]]
}

@test "manifest_missing_keys: a real .env.example key (LLM_API_BASE) is not reported missing" {
  ENV_EXAMPLE="$REPO_ROOT/.env.example" run manifest_missing_keys "$REALISTIC_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" != *"LLM_API_BASE"* ]]
  [[ "$output" != *"JFROG_BASE_URL"* ]]
}

@test "manifest_missing_keys: an unknown key (NEW_KEY_X) IS reported missing" {
  ENV_EXAMPLE="$REPO_ROOT/.env.example" run manifest_missing_keys "$REALISTIC_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "NEW_KEY_X" ]
}

@test "manifest_missing_keys: empty when every manifest key is known" {
  local manifest='{"env_keys": [ {"key": "LLM_API_BASE", "required": true}, {"key": "JFROG_BASE_URL", "required": false} ]}'
  ENV_EXAMPLE="$REPO_ROOT/.env.example" run manifest_missing_keys "$manifest"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- image_version_label ----------------------------------------------------

@test "image_version_label: echoes the OCI version label when present" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_IMAGE_LABEL="0.0.7" run image_version_label "reg.test.local/opencode:latest"
  [ "$status" -eq 0 ]
  [ "$output" = "0.0.7" ]
}

@test "image_version_label: silent (non-zero) on an old image with no label" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_IMAGE_LABEL="" run image_version_label "reg.test.local/opencode:latest"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- image_changelog_section -------------------------------------------------

REALISTIC_CHANGELOG='# Changelog

## [0.0.7] — 2026-07-01

### Added
- JFrog MCP server.
- Confluence MCP server.

## [0.0.6] — 2026-06-20

### Added
- Something older.'

@test "image_changelog_section: extracts just the requested version's section" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_CHANGELOG="$REALISTIC_CHANGELOG" \
    run image_changelog_section "reg.test.local/opencode:latest" "0.0.7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## [0.0.7]"* ]]
  [[ "$output" == *"JFrog MCP server."* ]]
  # trimmed: does not bleed into the next section's own heading/body
  [[ "$output" != *"## [0.0.6]"* ]]
  [[ "$output" != *"Something older."* ]]
}

@test "image_changelog_section: the newest (last) section has no trailing heading to trim" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_CHANGELOG="$REALISTIC_CHANGELOG" \
    run image_changelog_section "reg.test.local/opencode:latest" "0.0.6"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## [0.0.6]"* ]]
  [[ "$output" == *"Something older."* ]]
}

@test "image_changelog_section: caps output at 25 lines" {
  local long="## [9.9.9]"
  for i in $(seq 1 40); do long="$long
line$i"; done
  long="$long
## [9.9.8]
older"
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_CHANGELOG="$long" \
    run image_changelog_section "reg.test.local/opencode:latest" "9.9.9"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -le 25 ]
}

@test "image_changelog_section: silent (non-zero) on an old image with no CHANGELOG.md" {
  PATH="$FAKE_BIN:$PATH" FAKE_DOCKER_CHANGELOG="" \
    run image_changelog_section "reg.test.local/opencode:latest" "0.0.7"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
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
  [[ "$output" == *"DISABLE_BITBUCKET_MCP"* ]]
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

# --- field_help_text (ncurses editor per-field description) -----------------

@test "field_help_text: non-empty for every editable_schema_keys() key" {
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    run field_help_text "$key"
    [ "$status" -eq 0 ]
    [ -n "$output" ] || {
      echo "field_help_text returned empty for $key" >&2
      return 1
    }
  done < <(editable_schema_keys)
}

@test "field_help_text: ENABLED_PLUGINS lists every KNOWN_PLUGINS name and warns about Qwen" {
  run field_help_text ENABLED_PLUGINS
  [ "$status" -eq 0 ]
  [[ "$output" == *"superpowers"* ]]
  [[ "$output" == *"dcp"* ]]
  [[ "$output" == *"opencode-workspace"* ]]
  [[ "$output" == *"Qwen"* ]]
}

@test "field_help_text: GITLAB_BASE_URL notes it is required" {
  run field_help_text GITLAB_BASE_URL
  [ "$status" -eq 0 ]
  [[ "$output" == *"REQUIRED"* ]]
}

@test "field_help_text: BITBUCKET_BASE_URL notes plain http://" {
  run field_help_text BITBUCKET_BASE_URL
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://"* ]]
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

@test "tui_msgbox: a non-zero (dismiss) exit is not a script error" {
  run bash -c '
    source "'"$REPO_ROOT"'/start.sh"
    tui_backend() { printf "%s" "fake-cancel-backend"; }
    fake-cancel-backend() { return 1; }
    set -euo pipefail
    tui_msgbox "Title" "some text"
    echo SURVIVED
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SURVIVED"* ]]
}

# --- required_keys / field_satisfied / unmet_required (first-run gate) ------

@test "required_keys: lists exactly the three required keys" {
  run required_keys
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'LLM_API_BASE\nLLM_API_KEY\nIMAGE_REGISTRY')" ]
}

@test "field_satisfied: false for an empty value" {
  printf 'LLM_API_KEY=\n' > "$ENV_FILE"
  run field_satisfied LLM_API_KEY
  [ "$status" -ne 0 ]
}

@test "field_satisfied: false for the CHANGEME placeholder" {
  printf 'IMAGE_REGISTRY=CHANGEME.artifactory.example/opencode-workplace\n' > "$ENV_FILE"
  run field_satisfied IMAGE_REGISTRY
  [ "$status" -ne 0 ]
}

@test "field_satisfied: false for the internal.example placeholder" {
  printf 'LLM_API_BASE=https://llm.internal.example/v1\n' > "$ENV_FILE"
  run field_satisfied LLM_API_BASE
  [ "$status" -ne 0 ]
}

@test "field_satisfied: false for the artifactory.example placeholder" {
  printf 'IMAGE_REGISTRY=foo.artifactory.example/bar\n' > "$ENV_FILE"
  run field_satisfied IMAGE_REGISTRY
  [ "$status" -ne 0 ]
}

@test "field_satisfied: true for a real, non-placeholder value" {
  printf 'LLM_API_KEY=sk-real-key\n' > "$ENV_FILE"
  run field_satisfied LLM_API_KEY
  [ "$status" -eq 0 ]
}

@test "unmet_required: a fresh .env.example copy reports all three required keys" {
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  run unmet_required
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM_API_BASE"* ]]    # internal.example placeholder
  [[ "$output" == *"LLM_API_KEY"* ]]     # empty
  [[ "$output" == *"IMAGE_REGISTRY"* ]]  # CHANGEME/artifactory.example placeholder
}

@test "unmet_required: empty once every required key has a real value" {
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://llm.test/v1|' "$ENV_FILE"
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-real-key|' "$ENV_FILE"
  sed -i 's|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=reg.test.local/opencode|' "$ENV_FILE"
  run unmet_required
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unmet_required: reports only the still-unsatisfied subset" {
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://llm.test/v1|' "$ENV_FILE"
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-real-key|' "$ENV_FILE"
  # IMAGE_REGISTRY left at its CHANGEME placeholder.
  run unmet_required
  [ "$status" -eq 0 ]
  [ "$output" = "IMAGE_REGISTRY" ]
}

# --- set_host_ids -------------------------------------------------------------

@test "set_host_ids: writes the current user's uid/gid into HOST_UID/HOST_GID" {
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  set_host_ids
  grep -q "^HOST_UID=$(id -u)$" "$ENV_FILE"
  grep -q "^HOST_GID=$(id -g)$" "$ENV_FILE"
}

# --- resolve_also_mounts (lib/also.sh) ---------------------------------------

@test "resolve_also_mounts: a bare path defaults to read-only" {
  local liba="$BATS_TEST_TMPDIR/liba"; mkdir -p "$liba"
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" "$liba"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\tro\tliba' "$liba")" ]
}

@test "resolve_also_mounts: a trailing :rw suffix opts into read-write" {
  local libb="$BATS_TEST_TMPDIR/libb"; mkdir -p "$libb"
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" "${libb}:rw"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\trw\tlibb' "$libb")" ]
}

@test "resolve_also_mounts: emits one line per spec, in argument order" {
  local liba="$BATS_TEST_TMPDIR/liba" libb="$BATS_TEST_TMPDIR/libb"
  mkdir -p "$liba" "$libb"
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" "$liba" "${libb}:rw"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '%s\tro\tliba' "$liba")" ]
  [ "${lines[1]}" = "$(printf '%s\trw\tlibb' "$libb")" ]
}

@test "resolve_also_mounts: a name collision between two paths gets -2/-3 suffixing" {
  mkdir -p "$BATS_TEST_TMPDIR/one/lib" "$BATS_TEST_TMPDIR/two/lib" "$BATS_TEST_TMPDIR/three/lib"
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" \
    "$BATS_TEST_TMPDIR/one/lib" "$BATS_TEST_TMPDIR/two/lib" "$BATS_TEST_TMPDIR/three/lib"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *$'\t'lib ]]
  [[ "${lines[1]}" == *$'\t'lib-2 ]]
  [[ "${lines[2]}" == *$'\t'lib-3 ]]
}

@test "resolve_also_mounts: dies on a nonexistent path" {
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--also path does not exist"* ]]
}

@test "resolve_also_mounts: dies when the path is a file, not a directory" {
  local f="$BATS_TEST_TMPDIR/afile"; : > "$f"
  run resolve_also_mounts "$BATS_TEST_TMPDIR/repo" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--also path is not a directory"* ]]
}

@test "resolve_also_mounts: dies when a spec resolves to the main repo path" {
  local repo="$BATS_TEST_TMPDIR/repo"; mkdir -p "$repo"
  run resolve_also_mounts "$repo" "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicates the main repo path"* ]]
}

# --- also_mount_lines / write_also_overlay / also_mounts_from_overlay --------
# (lib/also.sh)

@test "also_mount_lines: formats read-only and read-write lines distinctly" {
  local mounts; mounts="$(printf '/a/b\tro\tb\n/c/d\trw\td\n')"
  run also_mount_lines "$mounts"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"also: /a/b -> /workspace-extra/b (read-only)"* ]]
  [[ "${lines[1]}" == *"also: /c/d -> /workspace-extra/d (read-write)"* ]]
}

@test "also_mount_lines: empty input is a silent no-op" {
  run also_mount_lines ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "write_also_overlay + also_mounts_from_overlay: round-trips ro/rw flags and names" {
  local mounts; mounts="$(printf '/a/b\tro\tliba\n/c/d\trw\tlibb\n')"
  write_also_overlay myslug "$mounts"
  [ -f "${ENVS_DIR}/myslug.also.yml" ]
  grep -qF -- "- /a/b:/workspace-extra/liba:ro,z" "${ENVS_DIR}/myslug.also.yml"
  grep -qF -- "- /c/d:/workspace-extra/libb:z" "${ENVS_DIR}/myslug.also.yml"

  run also_mounts_from_overlay myslug
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '/a/b\tro\tliba')" ]
  [ "${lines[1]}" = "$(printf '/c/d\trw\tlibb')" ]
}

@test "also_mounts_from_overlay: empty (not an error) when the overlay file doesn't exist" {
  run also_mounts_from_overlay no-such-slug
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "delete_also_overlay: removes an existing overlay and is a no-op when absent" {
  write_also_overlay myslug "$(printf '/a/b\tro\tliba\n')"
  [ -f "${ENVS_DIR}/myslug.also.yml" ]
  delete_also_overlay myslug
  [ ! -f "${ENVS_DIR}/myslug.also.yml" ]
  # calling again (nothing to delete) must not error
  run delete_also_overlay myslug
  [ "$status" -eq 0 ]
}

@test "also_overlay_file: path is <ENVS_DIR>/<slug>.also.yml" {
  run also_overlay_file myslug
  [ "$status" -eq 0 ]
  [ "$output" = "${ENVS_DIR}/myslug.also.yml" ]
}

@test "also_context_file: path is <ENVS_DIR>/<slug>.also-context.md" {
  run also_context_file myslug
  [ "$status" -eq 0 ]
  [ "$output" = "${ENVS_DIR}/myslug.also-context.md" ]
}

@test "write_also_overlay: sets OPENCODE_EXTRA_INSTRUCTIONS and mounts the breadcrumb read-only" {
  write_also_overlay myslug "$(printf '/a/b\tro\tliba\n')"
  # the generic image hook: the var points at the breadcrumb's container path...
  grep -qF "OPENCODE_EXTRA_INSTRUCTIONS: /etc/opencode/also-context.md" \
    "${ENVS_DIR}/myslug.also.yml"
  # ...and the breadcrumb itself is bind-mounted there read-only (ro,z).
  grep -qF -- "- ${ENVS_DIR}/myslug.also-context.md:/etc/opencode/also-context.md:ro,z" \
    "${ENVS_DIR}/myslug.also.yml"
}

@test "write_also_overlay: the breadcrumb names each mount, its container path, and ro/rw" {
  write_also_overlay myslug "$(printf '/a/b\tro\tliba\n/c/d\trw\tlibb\n')"
  local ctx="${ENVS_DIR}/myslug.also-context.md"
  [ -f "$ctx" ]
  grep -qF -- '- **liba** — `/workspace-extra/liba` (read-only)' "$ctx"
  grep -qF -- '- **libb** — `/workspace-extra/libb` (read-write)' "$ctx"
}

@test "write_also_overlay: the breadcrumb mount is NOT reported by also_mounts_from_overlay (--status)" {
  # The context file mounts to /etc/opencode, not /workspace-extra, so the
  # overlay parse that drives --status keeps listing only the real --also
  # mounts — never the launcher's own breadcrumb.
  write_also_overlay myslug "$(printf '/a/b\tro\tliba\n')"
  run also_mounts_from_overlay myslug
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$(printf '/a/b\tro\tliba')" ]
}

@test "delete_also_overlay: removes the breadcrumb as well as the overlay" {
  write_also_overlay myslug "$(printf '/a/b\tro\tliba\n')"
  [ -f "${ENVS_DIR}/myslug.also.yml" ]
  [ -f "${ENVS_DIR}/myslug.also-context.md" ]
  delete_also_overlay myslug
  [ ! -f "${ENVS_DIR}/myslug.also.yml" ]
  [ ! -f "${ENVS_DIR}/myslug.also-context.md" ]
}

# --- mcp_status_line (lib/commands.sh) ---------------------------------------

@test "mcp_status_line: reports the comma-joined MCP keys" {
  docker() {
    if [ "$1" = exec ]; then printf 'bitbucket, jira\n'; return 0; fi
    return 1
  }
  run mcp_status_line opencode-myrepo
  [ "$status" -eq 0 ]
  [ "$output" = "mcps:    bitbucket, jira" ]
}

@test "mcp_status_line: reports '(none configured)' on an empty-but-successful probe" {
  docker() { [ "$1" = exec ] && { printf '\n'; return 0; }; return 1; }
  run mcp_status_line opencode-myrepo
  [ "$status" -eq 0 ]
  [ "$output" = "mcps:    (none configured)" ]
}

@test "mcp_status_line: silent (not an error) when the exec fails" {
  docker() { [ "$1" = exec ] && return 1; return 1; }
  run mcp_status_line opencode-myrepo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- launcher_behind_count (lib/update.sh) -----------------------------------
#
# Deliberately uses REAL git (bare "origin" + a clone, in the bats temp dir),
# not a fake-bin stub — this is exercising real `git fetch`/`rev-list`
# semantics, which a stub would just assert away.

# git_repo_pair NAME — set up a bare "$BATS_TEST_TMPDIR/NAME-origin.git" and a
# clone of it at "$BATS_TEST_TMPDIR/NAME" tracking origin/main. Echoes nothing;
# callers reference the two paths directly.
git_repo_pair() {
  local name="$1" origin="$BATS_TEST_TMPDIR/${1}-origin.git" clone="$BATS_TEST_TMPDIR/${1}"
  git init -q --bare "$origin"
  git init -q -b main "$BATS_TEST_TMPDIR/${1}-seed"
  ( cd "$BATS_TEST_TMPDIR/${1}-seed" \
      && git config user.email t@example.com && git config user.name t \
      && echo seed > f && git add f && git commit -q -m seed \
      && git remote add origin "$origin" && git push -q origin main )
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$clone"
  ( cd "$clone" && git config user.email t@example.com && git config user.name t )
}

@test "launcher_behind_count: empty for a directory that is not a git repo at all" {
  run launcher_behind_count "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "launcher_behind_count: empty when the repo has no upstream configured" {
  git init -q -b main "$BATS_TEST_TMPDIR/norepo-upstream"
  ( cd "$BATS_TEST_TMPDIR/norepo-upstream" && git config user.email t@example.com && git config user.name t \
      && echo x > f && git add f && git commit -q -m init )
  run launcher_behind_count "$BATS_TEST_TMPDIR/norepo-upstream"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "launcher_behind_count: 0 when the clone is fully in sync with its upstream" {
  git_repo_pair insync
  run launcher_behind_count "$BATS_TEST_TMPDIR/insync"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "launcher_behind_count: 1 after a single new commit lands on the upstream" {
  git_repo_pair behind1
  ( cd "$BATS_TEST_TMPDIR/behind1-seed" && echo more >> f && git add f && git commit -q -m second && git push -q origin main )
  run launcher_behind_count "$BATS_TEST_TMPDIR/behind1"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "launcher_behind_count: counts multiple upstream commits correctly" {
  git_repo_pair behind3
  for i in 1 2 3; do
    ( cd "$BATS_TEST_TMPDIR/behind3-seed" && echo "change $i" >> f && git add f && git commit -q -m "change $i" && git push -q origin main )
  done
  run launcher_behind_count "$BATS_TEST_TMPDIR/behind3"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "launcher_behind_count: never a script-fatal error under set -e (no git on PATH)" {
  run bash -c '
    PATH="/nonexistent-path-with-no-git"
    source "'"$REPO_ROOT"'/lib/core.sh"
    source "'"$REPO_ROOT"'/lib/update.sh"
    set -euo pipefail
    launcher_behind_count "'"$BATS_TEST_TMPDIR"'"
    echo "still running"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"still running"* ]]
}

# --- image_tag_pinned (lib/update.sh) ----------------------------------------

@test "image_tag_pinned: empty tag is NOT a pin (tracks latest)" {
  run image_tag_pinned ""
  [ "$status" -ne 0 ]
}

@test "image_tag_pinned: 'latest' is NOT a pin" {
  run image_tag_pinned "latest"
  [ "$status" -ne 0 ]
}

@test "image_tag_pinned: 'local' (self-built sentinel) is NOT a pin to nudge" {
  run image_tag_pinned "local"
  [ "$status" -ne 0 ]
}

@test "image_tag_pinned: a semver tag IS a pin" {
  run image_tag_pinned "0.0.5"
  [ "$status" -eq 0 ]
}

@test "image_tag_pinned: a @sha256 digest IS a pin" {
  run image_tag_pinned "@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  [ "$status" -eq 0 ]
}

# --- launcher_pull_ff (lib/update.sh) ----------------------------------------

@test "launcher_pull_ff: fast-forwards a behind clone to its upstream" {
  git_repo_pair ffclone
  ( cd "$BATS_TEST_TMPDIR/ffclone-seed" && echo more >> f && git add f && git commit -q -m second && git push -q origin main )
  # precondition: 1 behind
  run launcher_behind_count "$BATS_TEST_TMPDIR/ffclone"
  [ "$output" = "1" ]
  # pull --ff-only succeeds and lands us back in sync
  run launcher_pull_ff "$BATS_TEST_TMPDIR/ffclone"
  [ "$status" -eq 0 ]
  run launcher_behind_count "$BATS_TEST_TMPDIR/ffclone"
  [ "$output" = "0" ]
}

@test "launcher_pull_ff: non-zero (never fatal) for a directory that is not a git repo" {
  run launcher_pull_ff "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
}

# --- env_example_added_keys (lib/update.sh) ----------------------------------

@test "env_example_added_keys: lists only keys new in .env.example since OLD_REV" {
  local d="$BATS_TEST_TMPDIR/added"
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@e.com && git config user.name t \
      && printf 'A=1\nB=2\n# a comment\n' > .env.example && git add -A && git commit -q -m v1 )
  local old; old="$(git -C "$d" rev-parse HEAD)"
  ( cd "$d" && printf 'A=1\nB=2\n# a comment\nC=3\nD=\n' > .env.example && git add -A && git commit -q -m v2 )
  run env_example_added_keys "$d" "$old"
  [ "$status" -eq 0 ]
  [[ "$output" == *"C"* ]]
  [[ "$output" == *"D"* ]]
  [[ "$output" != *"A"* ]]
  [[ "$output" != *"B"* ]]
}

@test "env_example_added_keys: empty when only a value changed (same keys)" {
  local d="$BATS_TEST_TMPDIR/samekeys"
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@e.com && git config user.name t \
      && printf 'A=1\n' > .env.example && git add -A && git commit -q -m v1 )
  local old; old="$(git -C "$d" rev-parse HEAD)"
  ( cd "$d" && printf 'A=999\n' > .env.example && git add -A && git commit -q -m v2 )
  run env_example_added_keys "$d" "$old"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "env_example_added_keys: empty (never fatal) for a non-git dir or bad rev" {
  run env_example_added_keys "$BATS_TEST_TMPDIR" "deadbeef"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- doctor_check_image_pin (lib/doctor.sh) ----------------------------------

@test "doctor_check_image_pin: WARN (never FAIL) when the tag is pinned to a version" {
  run doctor_check_image_pin 0.0.5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"pinned to 0.0.5"* ]]
}

@test "doctor_check_image_pin: PASS when the tag tracks latest" {
  run doctor_check_image_pin latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"* ]]
  [[ "$output" == *"tracks latest"* ]]
}

@test "doctor_check_image_pin: PASS for the 'local' self-built sentinel" {
  run doctor_check_image_pin local
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"* ]]
}

@test "doctor_check_image_pin: reads IMAGE_TAG from .env when no arg is given" {
  printf 'IMAGE_TAG=0.0.9\n' > "$ENV_FILE"
  run doctor_check_image_pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"pinned to 0.0.9"* ]]
}

# --- doctor_check_launcher_update (lib/doctor.sh) ----------------------------
#
# launcher_behind_count itself is exercised with real git above; here the
# formatting/PASS-WARN choice is pinned by stubbing launcher_behind_count
# directly (bash lets a test-local function shadow the sourced one) so these
# stay fast and deterministic.

@test "doctor_check_launcher_update: PASS 'launcher up to date' when 0 behind" {
  launcher_behind_count() { printf '0'; }
  run doctor_check_launcher_update /some/dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] launcher up to date"* ]]
}

@test "doctor_check_launcher_update: WARN (never FAIL) naming the count when behind" {
  launcher_behind_count() { printf '4'; }
  run doctor_check_launcher_update /some/dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"4 commit(s) behind origin — git pull"* ]]
  [[ "$output" != *"[FAIL]"* ]]
}

@test "doctor_check_launcher_update: neutral skipped WARN when undeterminable" {
  launcher_behind_count() { printf ''; }
  run doctor_check_launcher_update /some/dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] launcher update check"* ]]
  [[ "$output" == *"skipped (no upstream/offline)"* ]]
}

# --- exec spinner (lib/exec.sh) ---------------------------------------------
# The spinner draws only to OC_EXEC_TTY (default /dev/tty), so it never
# pollutes --exec's stdout/stderr contract. Point it at a temp file here to
# drive it without a real terminal; the start/stop lifecycle is what matters.

@test "exec_spinner_start/stop: runs when the target tty is writable, then clears" {
  local tty="$BATS_TEST_TMPDIR/spin.tty"
  : > "$tty"
  OC_EXEC_TTY="$tty" exec_spinner_start
  # A writable target => a live background spinner recorded in the PID var.
  [ -n "$OC_EXEC_SPINNER_PID" ]
  kill -0 "$OC_EXEC_SPINNER_PID"
  local pid="$OC_EXEC_SPINNER_PID"
  OC_EXEC_TTY="$tty" exec_spinner_stop
  # Stop reaps the process and clears the PID var; the process is gone.
  [ -z "$OC_EXEC_SPINNER_PID" ]
  ! kill -0 "$pid" 2>/dev/null
  # Something was drawn to the tty target (frames and/or the clear sequence).
  [ -s "$tty" ]
}

@test "exec_spinner_start: no-op (no process) when the tty target isn't writable" {
  # A path under a nonexistent directory can't be opened for writing.
  OC_EXEC_TTY="$BATS_TEST_TMPDIR/nope/spin.tty" run exec_spinner_start
  [ "$status" -eq 0 ]
  OC_EXEC_TTY="$BATS_TEST_TMPDIR/nope/spin.tty" exec_spinner_start
  [ -z "$OC_EXEC_SPINNER_PID" ]
}

@test "exec_spinner_stop: safe no-op when no spinner is running" {
  OC_EXEC_SPINNER_PID=""
  OC_EXEC_TTY="$BATS_TEST_TMPDIR/spin.tty" run exec_spinner_stop
  [ "$status" -eq 0 ]
}
