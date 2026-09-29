#!/usr/bin/env bats
# Real-provider configuration checks use synthetic settings and need no daemon.

setup() {
  load common
  source "$REPO_ROOT/lib/core.sh"
  source "$REPO_ROOT/lib/packages.sh"
  source "$REPO_ROOT/lib/also.sh"
  source "$REPO_ROOT/lib/compose.sh"
  __OCL_DIR="$BATS_TEST_TMPDIR/launcher space"
  ENVS_DIR="$__OCL_DIR/.envs"
  ENV_FILE="$__OCL_DIR/.env"
  mkdir -p "$__OCL_DIR/docker" "$ENVS_DIR" "$__OCL_DIR/work space" "$__OCL_DIR/extra-allowlist.d"
  cp "$REPO_ROOT"/docker/* "$__OCL_DIR/docker/"
  cp "$REPO_ROOT/extra-allowlist.d/placeholder.conf" "$__OCL_DIR/extra-allowlist.d/"
  printf 'IMAGE_REGISTRY=example.invalid/opencode\nIMAGE_TAG=test\nSCOPED_SECRET=shared-test-value\n' > "$ENV_FILE"
  PROJECT_ENV="$ENVS_DIR/demo.env"
  {
    cat "$ENV_FILE"
    printf 'SCOPED_SECRET=\nREPO_PATH=./work space\nOPENCODE_PORT=4096\nOCL_PACKAGE_LAYER=0\n'
  } > "$PROJECT_ENV"
  RUNTIME_ENGINE=docker
}

need_yaml() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML required"
}

@test "compose paths: explicit paths are independent of caller working directory" {
  cd /
  compose_prepare demo "$PROJECT_ENV"
  [ "$REPO_PATH" = "$__OCL_DIR/work space" ]
  [ "$EXTRA_ALLOWLIST_PATH" = "$__OCL_DIR/extra-allowlist.d" ]
  [ "$OCL_SHARED_ENV_FILE" = "$ENV_FILE" ]
  [ "$PROJECT_ENV_FILE" = "$PROJECT_ENV" ]
  [ "$OCL_BUILD_CONTEXT" = "$__OCL_DIR" ]
  [ "$OCL_BUILD_DOCKERFILE" = "$__OCL_DIR/docker/Dockerfile.user-packages" ]
  [ "${#COMPOSE_FILES[@]}" -eq 2 ]
  compose_validate_mounts
}

@test "compose paths: generated dotenv preserves quotes dollars backslashes spaces and hashes" {
  local value="a path/\$HOME/#part/o'brien\\file"
  compose_env_assignment VALUE "$value" > "$PROJECT_ENV"
  [ "$(compose_env_value VALUE "$PROJECT_ENV")" = "$value" ]
  printf 'VALUE=earlier\n' > "$PROJECT_ENV"
  compose_env_assignment VALUE "$value" >> "$PROJECT_ENV"
  [ "$(compose_env_value VALUE "$PROJECT_ENV")" = "$value" ]
}

@test "compose paths: omitted image settings use the same nonempty defaults for provider and probes" {
  printf 'REPO_PATH=./work space\n' > "$PROJECT_ENV"
  compose_prepare demo "$PROJECT_ENV"
  [ "$IMAGE_REGISTRY" = opencode-workplace ]
  [ "$IMAGE_TAG" = latest ]
  [ "$OCL_OPENCODE_IMAGE" = opencode-workplace:latest ]
  [ "$OCL_SQUID_IMAGE" = opencode-workplace-squid:latest ]
  [ "$(compute_base_image "${IMAGE_REGISTRY}-squid" "$IMAGE_TAG")" = opencode-workplace-squid:latest ]
}

@test "compose paths: digest image references remain valid with both real providers" {
  need_yaml
  local digest='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  local provider rendered=0 tag
  for tag in "$digest" "@$digest"; do
    compose_env_assignment IMAGE_TAG "$tag" >> "$PROJECT_ENV"
    compose_prepare demo "$PROJECT_ENV"
    [ "$OCL_OPENCODE_IMAGE" = "example.invalid/opencode@$digest" ]
    [ "$OCL_SQUID_IMAGE" = "example.invalid/opencode-squid@$digest" ]
    for provider in docker "${OCL_TEST_PODMAN_COMPOSE:-podman-compose}"; do
      command -v "$provider" >/dev/null 2>&1 || continue
      if [ "$provider" = docker ]; then
        docker compose version >/dev/null 2>&1 || continue
        docker compose --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
      else
        "$provider" --dry-run --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
      fi
      rendered=$((rendered + 1))
      python3 - "$BATS_TEST_TMPDIR/config.yml" "$digest" <<'PY'
import pathlib, sys, yaml
c = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert c['services']['opencode']['image'] == 'example.invalid/opencode@' + sys.argv[2]
for service in ('squid', 'oc-publish'):
    assert c['services'][service]['image'] == 'example.invalid/opencode-squid@' + sys.argv[2]
PY
    done
  done
  [ "$rendered" -gt 0 ] || skip "a real Compose provider is required"
}

@test "compose paths: project overrides win and management ignores changed shared settings" {
  mkdir -p "$__OCL_DIR/project rules" "$__OCL_DIR/personal layer"
  printf '# placeholder\n' > "$__OCL_DIR/project rules/placeholder.conf"
  printf 'EXTRA_ALLOWLIST_PATH=./project rules\nUSER_LAYER_PATH=./personal layer\n' >> "$PROJECT_ENV"
  printf 'EXTRA_ALLOWLIST_PATH=/absent-new-shared\nUSER_LAYER_PATH=/absent-new-layer\n' >> "$ENV_FILE"
  compose_prepare demo "$PROJECT_ENV"
  [ "$EXTRA_ALLOWLIST_PATH" = "$__OCL_DIR/project rules" ]
  [ "$USER_LAYER_PATH" = "$__OCL_DIR/personal layer" ]
  compose_validate_mounts
}

@test "compose paths: all feature overlays are assembled once in the same order" {
  printf 'USER_LAYER_PATH=./personal layer\nOCL_PACKAGE_LAYER=1\nOC_BASE_IMAGE=example.invalid/base:test\n' >> "$PROJECT_ENV"
  printf 'services: {}\n' > "$ENVS_DIR/demo.also.yml"
  RUNTIME_ENGINE=podman
  compose_prepare demo "$PROJECT_ENV"
  [ "${COMPOSE_FILES[1]}" = "$__OCL_DIR/docker/docker-compose.yml" ]
  [ "${COMPOSE_FILES[3]}" = "$__OCL_DIR/docker/docker-compose.podman.yml" ]
  [ "${COMPOSE_FILES[5]}" = "$__OCL_DIR/docker/docker-compose.user-layer.yml" ]
  [ "${COMPOSE_FILES[7]}" = "$__OCL_DIR/docker/docker-compose.user-packages.yml" ]
  [ "${COMPOSE_FILES[9]}" = "$ENVS_DIR/demo.also.yml" ]
  [ "${#COMPOSE_FILES[@]}" -eq 10 ]
}

@test "compose paths: missing custom directories fail before any engine invocation and are not created" {
  printf 'USER_LAYER_PATH=./missing custom layer\n' >> "$PROJECT_ENV"
  compose_prepare demo "$PROJECT_ENV"
  run compose_validate_mounts
  [ "$status" -ne 0 ]
  [[ "$output" == *"mount source is not an existing directory"* ]]
  [ ! -e "$__OCL_DIR/missing custom layer" ]
}

@test "compose paths: an empty custom allowlist gives an actionable failure" {
  mkdir -p "$__OCL_DIR/empty rules"
  printf 'EXTRA_ALLOWLIST_PATH=./empty rules\n' >> "$PROJECT_ENV"
  compose_prepare demo "$PROJECT_ENV"
  run compose_validate_mounts
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowlist directory contains no .conf files"* ]]
  [[ "$output" == *"placeholder.conf"* ]]
}

@test "compose paths: Docker Compose resolves paths credentials and volume names without project-directory" {
  need_yaml
  docker compose version >/dev/null 2>&1 || skip "Docker Compose required"
  compose_prepare demo "$PROJECT_ENV"
  cd /
  docker compose --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
  python3 - "$BATS_TEST_TMPDIR/config.yml" "$__OCL_DIR" <<'PY'
import pathlib, sys, yaml
c = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
root = sys.argv[2]
oc, squid = c['services']['opencode'], c['services']['squid']
workspace = next(v for v in oc['volumes'] if v['target'] == '/workspace')
assert workspace['source'] == root + '/work space'
assert workspace['bind']['selinux'] == 'z'
assert workspace['bind'].get('create_host_path', True) is True
assert squid['volumes'][0]['source'] == root + '/extra-allowlist.d'
assert squid['volumes'][0]['read_only'] is True
assert oc['environment']['SCOPED_SECRET'] == ''
assert 'build' not in oc
assert c['volumes']['oc_state']['name'] == 'opencode-demo_state'
assert c['volumes']['oc_cfg']['name'] == 'opencode-demo_cfg'
assert c['networks']['oc_proxy']['internal'] is True
assert set(oc['networks']) == {'oc_proxy'}
PY
}

@test "compose paths: real podman-compose merges explicit feature paths and root initialization" {
  need_yaml
  local provider="${OCL_TEST_PODMAN_COMPOSE:-podman-compose}"
  command -v "$provider" >/dev/null 2>&1 || skip "podman-compose required"
  mkdir -p "$__OCL_DIR/personal layer"
  printf 'USER_LAYER_PATH=./personal layer\nOCL_PACKAGE_LAYER=1\nOC_BASE_IMAGE=example.invalid/base:test\n' >> "$PROJECT_ENV"
  printf 'jq\n' > "$__OCL_DIR/extra-packages.txt"
  RUNTIME_ENGINE=podman
  compose_prepare demo "$PROJECT_ENV"
  cd /
  # --dry-run skips Podman's version/runtime initialization, but still invokes
  # the provider's real merge/interpolation/config code. No daemon is needed.
  "$provider" --dry-run --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
  "$provider" --dry-run --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config --quiet
  python3 - "$BATS_TEST_TMPDIR/config.yml" "$__OCL_DIR" "$PROJECT_ENV_FILE" "$ENV_FILE" <<'PY'
import pathlib, sys, yaml
c = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
root = sys.argv[2]
oc = c['services']['opencode']
assert c['x-podman']['in_pod'] is False
assert oc['userns_mode'] == 'keep-id'
assert oc['user'] == '0:0'
assert oc['env_file'] == [sys.argv[4], sys.argv[3]]
mounts = {v['target']: v for v in oc['volumes'] if isinstance(v, dict)}
assert mounts['/workspace']['source'] == root + '/work space'
assert mounts['/home/dev/.config/opencode']['source'] == root + '/personal layer'
assert mounts['/home/dev/.config/opencode']['bind']['selinux'] == 'z'
assert oc['build']['context'] == root
assert oc['build']['dockerfile'] == root + '/docker/Dockerfile.user-packages'
args = oc['build']['args']
if isinstance(args, list):
    args = dict(value.split('=', 1) for value in args)
assert args['BASE_IMAGE'] == 'example.invalid/base:test'
assert c['volumes']['oc_state']['name'] == 'opencode-demo_state'
assert c['networks']['oc_proxy']['internal'] is True
assert set(oc['networks']) == {'oc_proxy'}
PY
}
