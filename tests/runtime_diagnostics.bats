#!/usr/bin/env bats

load common

setup() {
  source "$REPO_ROOT/lib/doctor.sh"
  source "$REPO_ROOT/lib/compose.sh"
  SCRIPT_DIR="$BATS_TEST_TMPDIR/launcher"
  mkdir -p "$SCRIPT_DIR/extra-allowlist.d"
  printf '# Empty allowlist\n' > "$SCRIPT_DIR/extra-allowlist.d/placeholder.conf"
  get_env() { return 0; }
}

@test "doctor reports Podman engine and provider separately" {
  runtime_select() {
    RUNTIME_ENGINE=podman RUNTIME_PROVIDER=podman-compose
    RUNTIME_ENDPOINT=local RUNTIME_MODE=rootless
  }
  runtime_validate() {
    RUNTIME_ENGINE_VERSION=5.6.0 RUNTIME_PROVIDER_VERSION=1.5.0
  }
  run doctor_check_runtime my-project
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman rootless engine"*"5.6.0"* ]]
  [[ "$output" == *"podman-compose provider"*"1.5.0"* ]]
  [[ "$output" != *"docker daemon"* ]]
}

@test "doctor passes explicit engine and project slug to runtime selection" {
  OCL_ENGINE_REQUESTED=podman
  runtime_select() {
    [ "$1" = podman ] && [ "$2" = project-slug ] || return 1
    RUNTIME_ENGINE=podman RUNTIME_PROVIDER=podman-compose RUNTIME_MODE=rootless
  }
  runtime_validate() { return 0; }
  run doctor_check_runtime project-slug
  [ "$status" -eq 0 ]
}

@test "doctor selection failure does not try another engine or validate" {
  runtime_select() { return 1; }
  runtime_validate() { echo SHOULD_NOT_VALIDATE; }
  run doctor_check_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] runtime selection"* ]]
  [[ "$output" != *"SHOULD_NOT_VALIDATE"* ]]
}

@test "doctor Podman validation failure offers no Docker group advice" {
  runtime_select() { RUNTIME_ENGINE=podman; }
  runtime_validate() { echo 'subordinate UID range missing' >&2; return 1; }
  run doctor_check_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"subordinate UID range missing"* ]]
  [[ "$output" == *"[FAIL] podman runtime"* ]]
  [[ "$output" != *"usermod"* ]]
}

@test "doctor registry auth hint uses selected engine" {
  RUNTIME_ENGINE=podman
  runtime_manifest_inspect() { echo unauthorized >&2; return 1; }
  run doctor_check_registry_access registry.example/opencode registry.example
  [ "$status" -eq 1 ]
  [[ "$output" == *"podman login registry.example"* ]]
  [[ "$output" != *"docker login"* ]]
}

@test "doctor registry errors do not echo credential-bearing provider output" {
  runtime_manifest_inspect() { echo 'https://user:secret-value@example.org unavailable' >&2; return 1; }
  run doctor_check_registry_access example.org/opencode example.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] registry access"* ]]
  [[ "$output" != *"secret-value"* ]]
}

@test "doctor missing mount reports directory without creating it" {
  run doctor_check_mount_directory allowlist missing-directory
  [ "$status" -eq 1 ]
  [[ "$output" == *"$SCRIPT_DIR/missing-directory"* ]]
  [ ! -e "$SCRIPT_DIR/missing-directory" ]
  [[ "$output" != *"usermod"* ]]
}

@test "doctor rejects file where mount directory is required" {
  touch "$SCRIPT_DIR/a-file"
  run doctor_check_mount_directory allowlist "$SCRIPT_DIR/a-file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrong type"* ]]
}

@test "doctor differentiates local mount checks from engine access" {
  run doctor_check_mounts
  [ "$status" -eq 0 ]
  [[ "$output" == *"local user access"* ]]
  [[ "$output" == *"local checks only"* ]]
  [[ "$output" == *"filesystem/NFS and SELinux"* ]]
}

@test "doctor empty custom allowlist fails before Squid includes it" {
  rm "$SCRIPT_DIR/extra-allowlist.d/placeholder.conf"
  run doctor_check_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a readable *.conf file"* ]]
}

@test "doctor reads effective saved mount paths instead of edited defaults" {
  mkdir -p "$SCRIPT_DIR/saved allowlist" "$SCRIPT_DIR/saved workspace"
  printf '# Empty\n' > "$SCRIPT_DIR/saved allowlist/placeholder.conf"
  printf 'EXTRA_ALLOWLIST_PATH=%s\nREPO_PATH=%s\n' \
    "$SCRIPT_DIR/saved allowlist" "$SCRIPT_DIR/saved workspace" > "$SCRIPT_DIR/project.env"
  get_env() { printf '/wrong/current/default'; }
  run doctor_check_mounts "$SCRIPT_DIR/wrong-workspace" "$SCRIPT_DIR/project.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved allowlist"* ]]
  [[ "$output" == *"saved workspace"* ]]
  [[ "$output" != *"wrong/current/default"* ]]
}

@test "doctor Podman skips Docker-specific network exhaustion estimate" {
  RUNTIME_ENGINE=podman
  runtime_network_count() { echo SHOULD_NOT_COUNT; return 1; }
  run doctor_check_address_pools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker address-pool estimate does not apply"* ]]
  [[ "$output" != *"SHOULD_NOT_COUNT"* ]]
}

@test "bash completion offers supported engine values" {
  source "$REPO_ROOT/completions/opencode-launcher.bash"
  COMP_WORDS=(./start.sh --engine po) COMP_CWORD=2
  _opencode_launcher_complete
  [ "${COMPREPLY[*]}" = podman ]
}

@test "installer validates engine argument before touching installation" {
  run bash "$REPO_ROOT/install.sh" --engine unsupported
  [ "$status" -ne 0 ]
  [[ "$output" == *"--engine requires docker or podman"* ]]
}

@test "doctor explicitly selected Podman never probes Docker" {
  make_sandbox
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=test-private-key|' "$SANDBOX/.env"
  run_launcher --engine podman --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman rootless engine"* ]]
  [[ "$output" == *"podman-compose provider"* ]]
  [[ "$output" != *"test-private-key"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "doctor project binding overrides the changed Docker default" {
  make_sandbox
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=test-private-key|' "$SANDBOX/.env"
  sed -i 's|^OCL_ENGINE=.*|OCL_ENGINE=docker|' "$SANDBOX/.env"
  source "$SANDBOX/start.sh"
  ENV_FILE="$SANDBOX/.env" ENVS_DIR="$SANDBOX/.envs"
  repo="$(make_repo_arg)"
  slug="$(derive_slug "$repo")"
  runtime_select podman "$slug"
  runtime_validate
  PROJECT_ENV_FILE="$SANDBOX/.envs/$slug.env"
  COMPOSE_FILES=(-f "$SANDBOX/docker/docker-compose.yml")
  runtime_save_binding "$slug"
  run_launcher --doctor "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman rootless engine"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "installer Podman alias selects explicit provider and next command" {
  make_sandbox
  cp "$REPO_ROOT/install.sh" "$SANDBOX/"
  run bash "$SANDBOX/install.sh" --podman
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman-compose provider is available"* ]]
  [[ "$output" == *"./start.sh --engine podman <your-repo-path>"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "installer Podman failure preserves failure and never checks Docker" {
  make_sandbox
  cp "$REPO_ROOT/install.sh" "$SANDBOX/"
  FAKE_PODMAN_INFO_RC=1 run bash "$SANDBOX/install.sh" --engine podman
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot initialize local Podman"* ]]
  [[ "$output" != *"usermod"* ]]
  [ ! -s "$FAKE_DOCKER_LOG" ]
}

@test "doctor rejects colon bind sources for either engine's SELinux-compatible mount path" {
  mkdir -p "$SCRIPT_DIR/with:colon"
  for RUNTIME_ENGINE in docker podman; do
    run doctor_check_mount_directory workspace "$SCRIPT_DIR/with:colon"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsupported with shared SELinux relabeling"* ]]
  done
}
