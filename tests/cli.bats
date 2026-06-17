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
  [[ "$output" == *"--detach"* ]]
  [[ "$output" == *"--persist"* ]]
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

@test "default boot uses the base compose file" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.yml' "$FAKE_DOCKER_LOG"
}

# --- TUI-default frontend ---------------------------------------------------

@test "default boot attaches the TUI rooted at /workspace" {
  seed_env
  run_launcher "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  # the stack still comes up first (keepalive), then the TUI attaches
  grep -q 'compose .*up -d' "$FAKE_DOCKER_LOG"
  grep -qE 'exec .*-w /workspace .*-it opencode-my-service opencode' "$FAKE_DOCKER_LOG"
}

@test "default boot prints the web-UI caveat with the workaround" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  # Anchor on the stable upstream issue number and the workaround, not a version
  # string (user-facing prose no longer names the exact OpenCode version).
  [[ "$output" == *"cd /workspace"* ]]
  [[ "$output" == *"14445"* ]]
}

@test "--detach boots the stack but does NOT attach the TUI" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'compose .*up -d' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"detached: stack is running"* ]]
}

@test "--no-tui is an alias for --detach" {
  seed_env
  run_launcher --no-tui "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--tui is accepted as a back-compat no-op (still attaches)" {
  seed_env
  run_launcher --tui "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-w /workspace .*-it ' "$FAKE_DOCKER_LOG"
}

@test "default boot tears the stack down after the TUI exits" {
  seed_env
  run_launcher "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  # attaches, then runs `compose ... down` for this project once the TUI exits
  grep -qE 'exec .*-it opencode-my-service opencode' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*-p opencode-my-service .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"tearing down"* ]]
}

@test "--persist attaches the TUI but keeps the stack running (no teardown)" {
  seed_env
  run_launcher --persist "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-w /workspace .*-it ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"the stack keeps running"* ]]
}

@test "--web is an alias for --persist (no teardown)" {
  seed_env
  run_launcher --web "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-it ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--detach keeps the stack running (no teardown, no attach)" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

# --- podman overlay ---------------------------------------------------------

@test "default boot does NOT add the podman overlay" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.podman.yml' "$FAKE_DOCKER_LOG"
}

@test "--podman adds the podman overlay" {
  seed_env
  run_launcher --podman "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.podman.yml' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"podman:"* ]]
}

@test "--continue passes -c to the attached TUI" {
  seed_env
  run_launcher --continue "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-it opencode-my-service opencode -c$' "$FAKE_DOCKER_LOG"
}

@test "-c is an alias for --continue" {
  seed_env
  run_launcher -c "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'opencode -c$' "$FAKE_DOCKER_LOG"
}

@test "default boot does NOT pass -c (fresh session)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'opencode -c' "$FAKE_DOCKER_LOG"
}

@test "--continue works together with --persist" {
  seed_env
  run_launcher --continue --persist "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'opencode -c$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--continue with --detach warns and attaches nothing" {
  seed_env
  run_launcher --continue --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no effect with --detach"* ]]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--prod is gone: it is rejected as an unknown option" {
  seed_env
  run_launcher --prod "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --prod"* ]]
}

@test "IMAGE_TAG drives the access-check image (defaults to latest)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect reg.test.local/opencode:latest' "$FAKE_DOCKER_LOG"
}

@test "a pinned IMAGE_TAG is used for the access-check image" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect reg.test.local/opencode:0.0.2' "$FAKE_DOCKER_LOG"
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

# --- system-package layer ---------------------------------------------------

@test "absent extra-packages.txt: no overlay, plain pull, no OC_BASE_IMAGE" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  ! grep -q 'build opencode' "$FAKE_DOCKER_LOG"
  ! grep -q '^OC_BASE_IMAGE=' "$SANDBOX/.envs/myrepo.env"
  # plain blanket pull (no per-service split) preserves current behavior
  grep -qE 'compose .*pull$' "$FAKE_DOCKER_LOG"
}

@test "comment/blank-only extra-packages.txt is treated as inactive" {
  seed_env
  printf '%s\n' '# just a comment' '' '   ' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  ! grep -q '^OC_BASE_IMAGE=' "$SANDBOX/.envs/myrepo.env"
}

@test "non-empty extra-packages.txt: builds a local opencode layer" {
  seed_env
  # pin a distinct tag so the base image is unambiguous in the assertion below
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=local|' "$SANDBOX/.env"
  printf '%s\n' '# tools' 'cmake' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]

  # overlay added; base image handed to the build via the per-project env file
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  grep -q '^OC_BASE_IMAGE=reg.test.local/opencode:local$' "$SANDBOX/.envs/myrepo.env"

  # registry services pulled by name, then opencode is built (not pulled)
  grep -qE 'compose .*pull squid oc-publish' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*build opencode' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*up -d' "$FAKE_DOCKER_LOG"

  # an info line announces the active layer and the package
  [[ "$output" == *"system packages:"* ]]
  [[ "$output" == *"cmake"* ]]
}

@test "pinned IMAGE_TAG + packages: base image carries the pinned tag" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  printf '%s\n' 'cmake' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^OC_BASE_IMAGE=reg.test.local/opencode:0.0.2$' "$SANDBOX/.envs/myrepo.env"
  # the package overlay is applied last so it wins (overrides opencode's build:)
  grep -qE 'docker-compose.yml .*docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
}

@test "pip:-only extra-packages.txt activates the build layer" {
  seed_env
  printf '%s\n' '# python deps' 'pip:requests' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  # a pip-only file is still "active": the local layer is built
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*build opencode' "$FAKE_DOCKER_LOG"
  # the pip list is reported, and no spurious apt line appears
  [[ "$output" == *"pip: requests"* ]]
  [[ "$output" != *"apt: "* ]]
}

@test "mixed apt/pip extra-packages.txt is split into the right buckets" {
  seed_env
  printf '%s\n' 'cmake' 'apt:ripgrep' 'pip:requests' 'pip:httpx==0.27.0' \
    > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  # apt bucket: bare name + apt:-prefixed name (prefix stripped), no pip entries
  [[ "$output" == *"apt: cmake ripgrep"* ]]
  # pip bucket: pip:-prefixed specs (prefix stripped), version specifier kept
  [[ "$output" == *"pip: requests httpx==0.27.0"* ]]
}

# --- opt-in plugins (ENABLED_PLUGINS) ---------------------------------------

@test "ENABLED_PLUGINS with a space survives into the per-project env file" {
  seed_env
  # A space-separated list is the documented form; the value must reach the
  # opencode container unmangled. start.sh cats .env verbatim into the
  # per-project env, and the compose opencode service injects .env via env_file,
  # so a value preserved here is the value the container sees.
  sed -i 's|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=superpowers dcp|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=superpowers dcp$' "$SANDBOX/.envs/myrepo.env"
}

@test "an empty ENABLED_PLUGINS stays empty (no plugins enabled by default)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=$' "$SANDBOX/.envs/myrepo.env"
}

# --- first-run secrets flow -------------------------------------------------

@test "first run creates .env from the template and stores fed secrets" {
  [ ! -f "$SANDBOX/.env" ]   # precondition: no .env yet
  local repo; repo="$(make_repo_arg)"

  # 8 prompts in order: LLM base, LLM key, BB user, BB PAT, git name, git email,
  # plugins, image registry. Feed a key with sed-special chars to exercise
  # sed_escape and a space-bearing plugin list. Feed via a redirect (not a pipe):
  # `printf | run` would run `run` in a subshell, losing $status.
  printf '%s\n' \
    'https://llm.test/v1' \
    'sk-a&b|c' \
    'bobu' \
    'bbpat' \
    'Bob Builder' \
    'bob@test.dev' \
    'superpowers dcp' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -q '^LLM_API_BASE=https://llm.test/v1$' "$SANDBOX/.env"
  grep -q '^LLM_API_KEY=sk-a&b|c$' "$SANDBOX/.env"       # sed_escape round-trip
  grep -q '^BITBUCKET_USER=bobu$' "$SANDBOX/.env"
  grep -q '^GIT_USER_NAME=Bob Builder$' "$SANDBOX/.env"
  grep -q '^ENABLED_PLUGINS=superpowers dcp$' "$SANDBOX/.env"  # opt-in, space kept
  grep -q "^HOST_UID=$(id -u)$" "$SANDBOX/.env"          # auto-filled
  grep -q "^HOST_GID=$(id -g)$" "$SANDBOX/.env"
}

@test "first run with no plugins selected leaves ENABLED_PLUGINS empty" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  # Same 8 prompts, but press Enter past the plugins one (empty line).
  printf '%s\n' \
    'https://llm.test/v1' 'sk-key' 'bobu' 'bbpat' 'Bob Builder' 'bob@test.dev' \
    '' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=$' "$SANDBOX/.env"
}

@test "placeholder IMAGE_REGISTRY triggers a warning" {
  # Construct a placeholder value explicitly rather than relying on whatever
  # .env.example happens to ship (a real deployment edits that file).
  seed_env
  sed -i 's|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=CHANGEME.artifactory.example/opencode-workplace|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_REGISTRY looks like a placeholder"* ]]
}

# --- --doctor -----------------------------------------------------------------

# seed_env_doctor — seed_env plus a non-empty LLM_API_KEY, so the "all required
# keys set" path is reachable (seed_env alone leaves LLM_API_KEY empty).
seed_env_doctor() {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-test-secret-value|' "$SANDBOX/.env"
}

@test "--doctor short-circuits: no pull, no up, no exec" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenCode Launcher doctor report"* ]]
  ! grep -qE 'compose .*pull' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*up -d' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--doctor all-good: every check passes and exit is 0" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] docker on PATH"* ]]
  [[ "$output" == *"[PASS] docker daemon reachable"* ]]
  [[ "$output" == *"[PASS] docker compose v2 plugin"* ]]
  [[ "$output" == *"[PASS] .env present"* ]]
  [[ "$output" == *"[PASS] env: LLM_API_BASE"* ]]
  [[ "$output" == *"[PASS] env: LLM_API_KEY"* ]]
  [[ "$output" == *"[PASS] env: IMAGE_REGISTRY"* ]]
  [[ "$output" == *"[PASS] registry access"* ]]
  [[ "$output" == *"[PASS] port 4096 free"* ]]
  [[ "$output" == *"all critical checks passed"* ]]
  ! [[ "$output" == *"[FAIL]"* ]]
}

@test "--doctor: daemon-down FAILs that check and exits non-zero" {
  seed_env_doctor
  FAKE_DOCKER_INFO_RC=1 run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] docker daemon reachable"* ]]
  [[ "$output" == *"one or more critical checks FAILED"* ]]
}

@test "--doctor: permission-denied daemon failure surfaces the usermod hint" {
  seed_env_doctor
  FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_STDERR="Got permission denied while trying to connect" \
    run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] docker daemon reachable"* ]]
  [[ "$output" == *"usermod -aG docker"* ]]
}

@test "--doctor: missing required env key FAILs and exits non-zero" {
  seed_env_doctor
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] env: LLM_API_KEY"* ]]
  [[ "$output" == *"unset — required"* ]]
  [[ "$output" == *"one or more critical checks FAILED"* ]]
}

@test "--doctor: optional unset keys are reported as WARN, not FAIL" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] env: BITBUCKET_USER"* ]]
  [[ "$output" == *"unset (optional)"* ]]
}

@test "--doctor: registry auth failure reports it and gives the docker login hint" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="unauthorized: authentication required" \
    run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] registry access"* ]]
  [[ "$output" == *"auth problem"* ]]
  [[ "$output" == *"docker login reg.test.local"* ]]
}

@test "--doctor: a non-auth registry error WARNs but does not fail the run" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="manifest unknown: not found" \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] registry access"* ]]
  [[ "$output" == *"could not verify"* ]]
}

@test "--doctor: podman shim is reported as WARN, not FAIL" {
  seed_env_doctor
  FAKE_DOCKER_VERSION_OUTPUT="Docker version 0.0.0, podman" \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] podman shim detected"* ]]
}

@test "--doctor: no podman shim reports PASS" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] podman shim"* ]]
}

@test "--doctor: an optional repo path also checks that project's port" {
  seed_env_doctor
  run_launcher --doctor "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project: my-service"* ]]
}

@test "--doctor: never prints the secret LLM_API_KEY value" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-test-secret-value"* ]]
}

@test "--doctor: never prints a configured BITBUCKET_PAT value" {
  seed_env_doctor
  sed -i 's|^BITBUCKET_PAT=.*|BITBUCKET_PAT=super-secret-token-xyz|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-token-xyz"* ]]
  [[ "$output" == *"[PASS] env: BITBUCKET_PAT"* ]]
}

@test "--doctor exits non-zero overall even when only one of several checks FAILs" {
  seed_env_doctor
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -ne 0 ]
  # the rest of the report still ran (not an early abort)
  [[ "$output" == *"[PASS] docker on PATH"* ]]
  [[ "$output" == *"[PASS] docker compose v2 plugin"* ]]
}
