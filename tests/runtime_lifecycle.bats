#!/usr/bin/env bats

setup() {
  load common
  make_sandbox
  seed_env
  export OC_SKIP_UPDATE_CHECK=1
}

@test "runtime lifecycle: saved binding supports down after shared env removal" {
  local repo
  repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  rm "$SANDBOX/.env"
  : > "$FAKE_DOCKER_LOG"
  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  grep -q ' down$' "$FAKE_DOCKER_LOG"
  [ -s "$SANDBOX/.envs/myrepo.runtime" ]
}

@test "runtime lifecycle: engine mount failure retains binding and never starts containers" {
  local repo
  repo="$(make_repo_arg)"
  export FAKE_DOCKER_RUN_RC=17
  run_launcher --detach "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot access mount source:"* ]]
  [ -s "$SANDBOX/.envs/myrepo.runtime" ]
  ! grep -q ' up -d' "$FAKE_DOCKER_LOG"
}

@test "runtime lifecycle: readiness failure retains binding and does not attach" {
  local repo
  repo="$(make_repo_arg)"
  export FAKE_DOCKER_READY_RC=1 OCL_START_TIMEOUT=1
  run_launcher "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
  [ -s "$SANDBOX/.envs/myrepo.runtime" ]
  ! grep -q 'exec .* -it ' "$FAKE_DOCKER_LOG"
}

@test "runtime lifecycle: concurrent mutation fails without contacting the engine" {
  local repo
  repo="$(make_repo_arg)"
  mkdir -p "$SANDBOX/.envs"
  # Acquire the exact same operation lock from another process context.
  source "$SANDBOX/start.sh"
  ENVS_DIR="$SANDBOX/.envs"
  runtime_lock_project myrepo
  run_launcher --detach "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"another launcher is starting or stopping"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
  runtime_release_project
}

@test "runtime lifecycle: one-shot registers while running and releases before teardown" {
  source "$SANDBOX/start.sh"
  ENVS_DIR="$SANDBOX/.envs"
  SLUG=myrepo
  local observed="$BATS_TEST_TMPDIR/observed"
  attach_register "$SLUG"
  runtime_exec() { attach_count "$SLUG" > "$observed"; printf answer; }
  # exec_run exits, so run it in a child while preserving its answer descriptor.
  ( exec 3>/dev/null 4>/dev/null; exec_run opencode-myrepo prompt 0 1 0 true )
  [ "$(cat "$observed")" -eq 1 ]
  attach_release "$SLUG"
}

@test "runtime lifecycle: down still works after the primary workspace disappears" {
  local repo
  repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  rmdir "$repo"
  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  grep -q ' down$' "$FAKE_DOCKER_LOG"
}

@test "runtime lifecycle: status lists saved and legacy projects together" {
  local repo
  repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  export FAKE_DOCKER_COMPOSE_LS_OUTPUT=$'opencode-myrepo\trunning(3)\nopencode-legacy\trunning(3)'
  run_launcher --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode-myrepo"* ]]
  [[ "$output" == *"opencode-legacy"* ]]
}

@test "runtime lifecycle: image preflight and package build follow project overrides" {
  local repo
  repo="$(make_repo_arg)"
  mkdir -p "$SANDBOX/.envs"
  printf 'IMAGE_REGISTRY=project.test/app\nIMAGE_TAG=2.0\n' > "$SANDBOX/.envs/myrepo.overrides.env"
  printf 'jq\n' > "$SANDBOX/extra-packages.txt"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect project.test/app:2.0' "$FAKE_DOCKER_LOG"
  grep -q "OC_BASE_IMAGE='project.test/app:2.0'" "$SANDBOX/.envs/myrepo.env"
}

@test "runtime lifecycle: stopped containers are not reported up or offered a shell" {
  local repo
  repo="$(make_repo_arg)"
  export FAKE_DOCKER_COMPOSE_LS_OUTPUT=$'opencode-myrepo\texited(3)'
  run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:  stopped (exited(3))"* ]]
  [[ "$output" != *"web UI:"* ]]
  : > "$FAKE_DOCKER_LOG"
  run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}
