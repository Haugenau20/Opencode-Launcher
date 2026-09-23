#!/usr/bin/env bats

setup() {
  load common
  make_sandbox
  seed_env
  export ENV_FILE="$SANDBOX/.env" ENVS_DIR="$SANDBOX/.envs"
  export FAKE_PODMAN_LOG="$BATS_TEST_TMPDIR/podman.log"
  export FAKE_PODMAN_COMPOSE_LOG="$BATS_TEST_TMPDIR/podman-compose.log"
  : > "$FAKE_PODMAN_LOG"
  : > "$FAKE_PODMAN_COMPOSE_LOG"
  __OCL_DIR="$SANDBOX"
  source "$SANDBOX/lib/core.sh"
  source "$SANDBOX/lib/compose.sh"
  source "$SANDBOX/lib/runtime.sh"
  PROJECT_ENV_FILE="$ENVS_DIR/demo.env"
  COMPOSE_FILES=(-f "$SANDBOX/docker/docker-compose.yml")
  unset OCL_ENGINE OCL_ENGINE_REQUESTED DOCKER_CONTEXT DOCKER_HOST CONTAINER_HOST CONTAINER_CONNECTION
}

teardown() { runtime_release_project; }

select_and_validate() { runtime_select "$@" && runtime_validate; }

@test "runtime: Docker remains the default when both engines are installed" {
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = docker ]
  [ "$RUNTIME_PROVIDER" = docker-compose ]
  [ ! -s "$FAKE_PODMAN_LOG" ]
}

@test "runtime: explicit Podman bypasses Docker and chooses its provider" {
  runtime_select podman demo
  runtime_validate
  [ "$RUNTIME_ENGINE" = podman ]
  [ "$RUNTIME_PROVIDER" = podman-compose ]
  [ "$RUNTIME_ENDPOINT" = local:/fake/podman/store ]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "runtime: configured default yields to an explicit engine" {
  set_env OCL_ENGINE podman
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = podman ]
  runtime_select docker demo
  [ "$RUNTIME_ENGINE" = docker ]
}

@test "runtime: Docker failure never falls back to installed Podman" {
  export FAKE_DOCKER_INFO_RC=1
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'no automatic engine fallback'* ]]
  [ ! -s "$FAKE_PODMAN_LOG" ]
}

@test "runtime: Docker shim selects the Podman implementation" {
  export FAKE_DOCKER_VERSION_OUTPUT='podman version 5.4.2'
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = podman ]
}

@test "runtime: Docker client connected to Podman selects the Podman implementation" {
  export FAKE_DOCKER_SERVER_JSON='{"Platform":{"Name":"Podman Engine"},"Version":"5.4.2"}'
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = podman ]
}

@test "runtime: explicit Docker cannot disguise a Podman backend" {
  export FAKE_DOCKER_SERVER_JSON='{"Platform":{"Name":"Podman Engine"}}'
  run select_and_validate docker demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'use --engine podman'* ]]
}

@test "runtime: remote Docker endpoints are rejected" {
  export DOCKER_HOST=tcp://remote.example:2376
  run select_and_validate docker demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'only local Docker'* ]]
}

@test "runtime: automatic discovery rejects a remote endpoint before connecting" {
  export DOCKER_HOST=ssh://user:private-password@remote.example
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [[ "$output" != *'private-password'* ]]
  ! grep -q '^version ' "$FAKE_DOCKER_LOG"
}

@test "runtime: rootful Podman is rejected" {
  export FAKE_PODMAN_ROOTLESS=false
  run select_and_validate podman demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'rootless Podman only'* ]]
}

@test "runtime: rootless Docker is explicitly outside the first support scope" {
  export FAKE_DOCKER_SECURITY_OPTIONS='["name=rootless"]'
  run select_and_validate docker demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'rootless Docker is outside'* ]]
}

@test "runtime: daemon-wide Docker UID remapping cannot silently change workspace ownership" {
  export FAKE_DOCKER_SECURITY_OPTIONS='["name=userns"]'
  run select_and_validate docker demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'user-namespace remapping is outside'* ]]
}

@test "runtime: effective Podman image IDs must match the invoking account" {
  runtime_select podman demo
  printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" > "$BATS_TEST_TMPDIR/project.env"
  runtime_validate_project_env "$BATS_TEST_TMPDIR/project.env"
  printf 'HOST_UID=98765\nHOST_GID=%s\n' "$(id -g)" > "$BATS_TEST_TMPDIR/project.env"
  run runtime_validate_project_env "$BATS_TEST_TMPDIR/project.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Podman keep-id requires HOST_UID='* ]]
}

@test "runtime: Docker retains support for explicitly configured image IDs" {
  runtime_select docker demo
  printf 'HOST_UID=98765\nHOST_GID=98765\n' > "$BATS_TEST_TMPDIR/project.env"
  run runtime_validate_project_env "$BATS_TEST_TMPDIR/project.env"
  [ "$status" -eq 0 ]
}

@test "runtime: unsupported podman-compose fails before creating resources" {
  export FAKE_PODMAN_COMPOSE_VERSION=1.0.6
  run select_and_validate podman demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'podman-compose >= 1.5.0'* ]]
  ! grep -qE ' (up|run|pull) ' "$FAKE_PODMAN_LOG"
}

@test "runtime: missing subordinate ranges have an actionable error" {
  export FAKE_PODMAN_ID_MAP='0 1000 1'
  run select_and_validate podman demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'subordinate UID and GID'* ]]
}

@test "runtime: remote Podman selection is rejected" {
  export CONTAINER_HOST=ssh://remote.example
  run select_and_validate podman demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'remote Podman connections are unsupported'* ]]
}

@test "runtime: Podman Compose disables pods and never receives project-directory" {
  runtime_select podman demo
  runtime_compose --env-file '/some project/settings.env' -p opencode-demo -f '/some project/compose.yml' config --quiet
  log="$(cat "$FAKE_PODMAN_COMPOSE_LOG")"
  [[ "$log" == *'--in-pod=false --podman-args=--remote=false'* ]]
  [[ "$log" != *'--project-directory'* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "runtime: image command failures preserve their exit status" {
  runtime_select podman demo
  export FAKE_DOCKER_IMAGE_INSPECT_RC=42
  run runtime_image_inspect image:test
  [ "$status" -eq 42 ]
}

@test "runtime: command execution preserves piped stdin and exit status" {
  runtime_select podman demo
  export FAKE_DOCKER_EXEC_DRAIN_STDIN=1 FAKE_DOCKER_EXEC_RC=17
  export FAKE_DOCKER_EXEC_STDIN_LOG="$BATS_TEST_TMPDIR/stdin"
  run bash -c 'source "$1"; RUNTIME_ENGINE=podman; printf "hello\n" | runtime_exec -i opencode-demo opencode run' _ "$SANDBOX/lib/runtime.sh"
  [ "$status" -eq 17 ]
  [ "$(cat "$FAKE_DOCKER_EXEC_STDIN_LOG")" = hello ]
}

@test "runtime: project binding persists provider endpoint and paths without evaluating values" {
  runtime_select podman demo
  runtime_validate
  PROJECT_ENV_FILE="$BATS_TEST_TMPDIR/a project.env"
  COMPOSE_FILES=(-f "$BATS_TEST_TMPDIR/base.yml" -f '/tmp/$(touch SHOULD_NOT_EXIST)/overlay.yml')
  runtime_save_binding demo
  [ "$(stat -c %a "$ENVS_DIR/demo.runtime")" = 600 ]
  OCL_ENGINE=docker
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = podman ]
  [ "$RUNTIME_BOUND" = 1 ]
  [ "$RUNTIME_PROJECT_ENV_FILE" = "$PROJECT_ENV_FILE" ]
  [ "${RUNTIME_CONFIG_FILES[1]}" = '/tmp/$(touch SHOULD_NOT_EXIST)/overlay.yml' ]
  [ ! -e SHOULD_NOT_EXIST ]
}

@test "runtime: bound project rejects a conflicting explicit engine" {
  runtime_select podman demo
  runtime_validate
  runtime_save_binding demo
  run runtime_select docker demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'bound to podman'* ]]
}

@test "runtime: Docker binding ignores a later context change" {
  runtime_select docker demo
  runtime_validate
  runtime_save_binding demo
  export DOCKER_HOST=tcp://unrelated.example:2375
  runtime_select '' demo
  runtime_validate
  [ "$RUNTIME_ENDPOINT" = unix:///var/run/docker.sock ]
}

@test "runtime: changed Podman storage cannot silently move a saved project" {
  runtime_select podman demo
  runtime_validate
  runtime_save_binding demo
  export FAKE_PODMAN_GRAPHROOT=/some/other/store
  runtime_select '' demo
  run runtime_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *'runtime identity differs'* ]]
}

@test "runtime: malformed bindings fail closed without executing shell code" {
  mkdir -p "$ENVS_DIR"
  printf 'engine\t$(touch %s)\n' "$BATS_TEST_TMPDIR/executed" > "$ENVS_DIR/demo.runtime"
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "runtime: incomplete saved configuration cannot be reconstructed silently" {
  runtime_select podman demo
  runtime_validate
  runtime_save_binding demo
  sed -i '/^compose_file/d' "$ENVS_DIR/demo.runtime"
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'incomplete or unsupported runtime binding'* ]]
}

@test "runtime: binding rejects unresolved configuration paths" {
  runtime_select podman demo
  runtime_validate
  COMPOSE_FILES=(-f docker/docker-compose.yml)
  run runtime_save_binding demo
  [ "$status" -ne 0 ]
  [ ! -e "$ENVS_DIR/demo.runtime" ]
}

@test "runtime: lifecycle locks serialize the same project and release cleanly" {
  runtime_lock_project demo
  run bash -c 'source "$1"; runtime_lock_project demo' _ "$SANDBOX/lib/runtime.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'another launcher is starting or stopping'* ]]
  runtime_release_project
  run bash -c 'source "$1"; runtime_lock_project demo' _ "$SANDBOX/lib/runtime.sh"
  [ "$status" -eq 0 ]
}

@test "runtime: existing project on Podman is adopted instead of moved to Docker" {
  mkdir -p "$ENVS_DIR"
  touch "$ENVS_DIR/demo.env"
  export FAKE_PODMAN_PROJECTS=$'opencode-demo\trunning\nopencode-demo\trunning'
  runtime_select '' demo
  [ "$RUNTIME_ENGINE" = podman ]
}

@test "runtime: ambiguous legacy projects require explicit selection" {
  mkdir -p "$ENVS_DIR"
  touch "$ENVS_DIR/demo.env"
  export FAKE_PODMAN_PROJECTS=$'opencode-demo\trunning'
  export FAKE_DOCKER_COMPOSE_LS_OUTPUT=$'opencode-demo\trunning(3)'
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'exists in both engines'* ]]
}

@test "runtime: unavailable legacy engine requires explicit selection" {
  mkdir -p "$ENVS_DIR"
  touch "$ENVS_DIR/demo.env"
  export FAKE_PODMAN_PS_RC=125
  run runtime_select '' demo
  [ "$status" -ne 0 ]
  [[ "$output" == *'specify --engine'* ]]
}

@test "runtime: Podman discovery returns the normalized project/status pairs" {
  runtime_select podman
  export FAKE_PODMAN_PROJECTS=$'opencode-b\texited\nopencode-a\trunning\nopencode-a\trunning'
  run runtime_projects
  [ "$status" -eq 0 ]
  [ "$output" = $'opencode-a\trunning(2)\nopencode-b\texited(1)' ]
}
