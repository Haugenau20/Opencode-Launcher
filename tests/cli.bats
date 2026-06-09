#!/usr/bin/env bats
#
# Black-box tests: run a sandboxed copy of start.sh as a subprocess with a fake
# `docker` on PATH, and assert on its exit status, messages and side effects
# (the generated .env / per-project env, and the recorded docker calls).

setup() {
  load common
  make_sandbox
}

# --- argument parsing -------------------------------------------------------

@test "--help prints usage and exits 0" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--prod"* ]]
}

@test "missing repo path fails with a clear error" {
  run_launcher
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

@test "unknown option is rejected" {
  run_launcher --bogus "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "a second positional argument is rejected" {
  local repo; repo="$(make_repo_arg)"
  run_launcher "$repo" extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected extra argument: extra"* ]]
}

@test "nonexistent repo path is rejected" {
  run_launcher "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

@test "a file (not a directory) repo path is rejected" {
  local f="$BATS_TEST_TMPDIR/afile"
  : > "$f"
  run_launcher "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory"* ]]
}

# --- preflight: docker daemon -----------------------------------------------

@test "docker daemon unreachable fails with 'Is it running?'" {
  seed_env
  FAKE_DOCKER_INFO_RC=1 run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot talk to the Docker daemon. Is it running?"* ]]
}

@test "docker permission denied surfaces the usermod hint" {
  seed_env
  FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_STDERR="Got permission denied while trying to connect" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"permission denied"* ]]
  [[ "$output" == *"usermod -aG docker"* ]]
}

# --- Artifactory access -----------------------------------------------------

@test "manifest auth failure tells the user to docker login" {
  seed_env
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="unauthorized: authentication required" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth problem"* ]]
  [[ "$output" == *"docker login reg.test.local"* ]]
}

@test "a non-auth manifest error warns but continues to boot" {
  seed_env
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="manifest unknown: not found" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify"* ]]
  grep -q 'compose .* up -d' "$FAKE_DOCKER_LOG"
}

# --- happy-path boot & per-project derivation -------------------------------

@test "boots: derives slug, generates per-project env, pulls and starts" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher "$repo"
  [ "$status" -eq 0 ]

  # per-project env file named by slug, superset of .env + generated keys
  local penv="$SANDBOX/.envs/my-service.env"
  [ -f "$penv" ]
  grep -q '^PROJECT_SLUG=my-service$' "$penv"
  grep -q "^REPO_PATH=${repo}$" "$penv"
  grep -q '^OPENCODE_PORT=' "$penv"
  grep -q '^IMAGE_REGISTRY=reg.test.local/opencode$' "$penv"   # inherited from .env

  # compose was invoked with the right project name and pull + up
  grep -q 'compose .*-p opencode-my-service .*pull' "$FAKE_DOCKER_LOG"
  grep -q 'compose .*-p opencode-my-service .*up -d' "$FAKE_DOCKER_LOG"
}

@test "default boot uses only the base compose file (no prod overlay)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.yml' "$FAKE_DOCKER_LOG"
  ! grep -q 'docker-compose.prod.yml' "$FAKE_DOCKER_LOG"
}

@test "--prod adds the prod overlay and checks the :prod image" {
  seed_env
  run_launcher --prod "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prod overlay enabled"* ]]
  grep -q 'docker-compose.prod.yml' "$FAKE_DOCKER_LOG"
  grep -q 'manifest inspect reg.test.local/opencode:prod' "$FAKE_DOCKER_LOG"
}

@test "USER_LAYER_PATH adds the user-layer overlay and records the abs path" {
  seed_env
  # .env already carries an empty USER_LAYER_PATH= line; set that one (get_env
  # reads the first match), don't append a duplicate.
  sed -i 's|^USER_LAYER_PATH=.*|USER_LAYER_PATH=./user-layer|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"user layer:"* ]]
  grep -q 'docker-compose.user-layer.yml' "$FAKE_DOCKER_LOG"
  grep -q "^USER_LAYER_PATH=${SANDBOX}/user-layer$" "$SANDBOX/.envs/myrepo.env"
}

# --- first-run secrets flow -------------------------------------------------

@test "first run creates .env from the template and stores fed secrets" {
  [ ! -f "$SANDBOX/.env" ]   # precondition: no .env yet
  local repo; repo="$(make_repo_arg)"

  # 7 prompts in order: LLM base, LLM key, BB user, BB PAT, git name, git email,
  # image registry. Feed a key with sed-special chars to exercise sed_escape.
  # Feed via a redirect (not a pipe): `printf | run` would run `run` in a
  # subshell, losing $status.
  printf '%s\n' \
    'https://llm.test/v1' \
    'sk-a&b|c' \
    'bobu' \
    'bbpat' \
    'Bob Builder' \
    'bob@test.dev' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -q '^LLM_API_BASE=https://llm.test/v1$' "$SANDBOX/.env"
  grep -q '^LLM_API_KEY=sk-a&b|c$' "$SANDBOX/.env"       # sed_escape round-trip
  grep -q '^BITBUCKET_USER=bobu$' "$SANDBOX/.env"
  grep -q '^GIT_USER_NAME=Bob Builder$' "$SANDBOX/.env"
  grep -q "^HOST_UID=$(id -u)$" "$SANDBOX/.env"          # auto-filled
  grep -q "^HOST_GID=$(id -g)$" "$SANDBOX/.env"
}

@test "placeholder IMAGE_REGISTRY triggers a warning" {
  # keep the CHANGEME default in .env
  cp "$SANDBOX/.env.example" "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_REGISTRY looks like a placeholder"* ]]
}
