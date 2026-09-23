#!/usr/bin/env bats

setup() {
  load common
  source "$REPO_ROOT/lib/core.sh"
  source "$REPO_ROOT/lib/project.sh"
  source "$REPO_ROOT/lib/packages.sh"
  source "$REPO_ROOT/lib/also.sh"
  source "$REPO_ROOT/lib/compose.sh"
  __OCL_DIR="$BATS_TEST_TMPDIR/launcher space"
  ENVS_DIR="$__OCL_DIR/.envs"
  ENV_FILE="$__OCL_DIR/.env"
  mkdir -p "$ENVS_DIR" "$__OCL_DIR/work" "$__OCL_DIR/docker" "$__OCL_DIR/extra-allowlist.d"
  cp "$REPO_ROOT"/docker/* "$__OCL_DIR/docker/"
  cp "$REPO_ROOT/extra-allowlist.d/placeholder.conf" "$__OCL_DIR/extra-allowlist.d/"
  printf 'IMAGE_REGISTRY=example.invalid/opencode\nIMAGE_TAG=test\n' > "$ENV_FILE"
  PROJECT_ENV="$ENVS_DIR/demo.env"
  cat "$ENV_FILE" > "$PROJECT_ENV"
  compose_env_assignment REPO_PATH "$__OCL_DIR/work" >> "$PROJECT_ENV"
  RUNTIME_ENGINE=docker
}

@test "also paths: punctuation remains literal in status and both real Compose providers" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  python3 -c 'import yaml' || skip "PyYAML required"
  local extra="$BATS_TEST_TMPDIR/literal \$HOME # quote' double\" colon: back\\slash"
  mkdir -p "$extra"
  local mounts
  mounts="$(resolve_also_mounts "$__OCL_DIR/work" "$extra:rw")"
  write_also_overlay demo "$mounts"
  [ "$(also_mounts_from_overlay demo)" = "$mounts" ]
  compose_prepare demo "$PROJECT_ENV"
  # Configuration preserves punctuation; shared SELinux runtime validation
  # separately rejects ':' because providers ultimately use colon separators.
  [ "${COMPOSE_MOUNT_SOURCES[2]}" = "$extra" ]
  [ "${COMPOSE_MOUNT_TYPES[3]}" = file ]

  local provider rendered=0
  for provider in docker "${OCL_TEST_PODMAN_COMPOSE:-podman-compose}"; do
    command -v "$provider" >/dev/null 2>&1 || continue
    if [ "$provider" = docker ]; then
      docker compose version >/dev/null 2>&1 || continue
      docker compose --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
    else
      "$provider" --dry-run --env-file "$PROJECT_ENV_FILE" -p opencode-demo "${COMPOSE_FILES[@]}" config > "$BATS_TEST_TMPDIR/config.yml"
    fi
    rendered=$((rendered + 1))
    python3 - "$BATS_TEST_TMPDIR/config.yml" "$extra" "$ENVS_DIR/demo.also-context.md" "$provider" <<'PY'
import pathlib, sys, yaml
c = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
mounts = c['services']['opencode']['volumes']
extra = next(m for m in mounts if isinstance(m, dict) and m['target'].startswith('/workspace-extra/'))
# Docker's config serializer re-escapes dollars so its output is reusable as a
# Compose file; podman-compose serializes the already-interpolated value.
expected = sys.argv[2].replace('$', '$$') if sys.argv[4] == 'docker' else sys.argv[2]
assert extra['source'] == expected, repr(extra['source'])
assert not extra.get('read_only', False)
assert extra['bind']['selinux'] == 'z'
assert extra['bind'].get('create_host_path', True) is True
context = next(m for m in mounts if isinstance(m, dict) and m['target'] == '/etc/opencode/also-context.md')
assert context['source'] == sys.argv[3]
assert context['read_only'] is True
PY
  done
  [ "$rendered" -gt 0 ] || skip "a real Compose provider is required"
}

@test "also paths: relative state directory and unrelated cwd still produce an absolute breadcrumb mount" {
  ENVS_DIR=.envs
  cd /
  write_also_overlay demo $'/tmp/example\tro\texample'
  [ -f "$__OCL_DIR/.envs/demo.also.yml" ]
  [ -f "$__OCL_DIR/.envs/demo.also-context.md" ]
  grep -qF "source: '$__OCL_DIR/.envs/demo.also-context.md'" "$__OCL_DIR/.envs/demo.also.yml"
  [ "$(also_mounts_from_overlay demo)" = $'/tmp/example\tro\texample' ]
}

@test "also paths: saved legacy short-syntax overlays still report their mounts" {
  printf 'services:\n  opencode:\n    volumes:\n      - /a/one:/workspace-extra/one:ro,z\n      - /b/two:/workspace-extra/two:z\n' > "$ENVS_DIR/demo.also.yml"
  [ "$(also_mounts_from_overlay demo)" = $'/a/one\tro\tone\n/b/two\trw\ttwo' ]
}

@test "also paths: tabs and newlines are rejected before mount records are generated" {
  run resolve_also_mounts "$__OCL_DIR/work" $'/tmp/tab\tname'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot contain tabs or newlines"* ]]
  run resolve_also_mounts "$__OCL_DIR/work" $'/tmp/new\nline'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot contain tabs or newlines"* ]]
}

@test "mount probe: all sources are read-only and no credentials or environment files are passed" {
  compose_prepare demo "$PROJECT_ENV"
  # Exercise the native --mount CSV encoder independently of YAML syntax.
  COMPOSE_MOUNT_SOURCES[0]="$REPO_PATH/comma,and\"quote"
  runtime_run() { printf '%s\0' "$@" >> "$BATS_TEST_TMPDIR/probe.args"; }
  compose_probe_mounts example.invalid/probe:test
  python3 - "$BATS_TEST_TMPDIR/probe.args" "${COMPOSE_MOUNT_SOURCES[0]}" "$EXTRA_ALLOWLIST_PATH" <<'PY'
import csv, pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().decode().split('\0')[:-1]
mounts = [args[i+1] for i, arg in enumerate(args) if arg == '--mount']
assert len(mounts) == 2
assert [next(x[7:] for x in next(csv.reader([m])) if x.startswith('source=')) for m in mounts] == sys.argv[2:]
assert all('readonly' in next(csv.reader([m])) for m in mounts)
assert args.count('--read-only') == 2
assert args.count('none') == 2
assert args.count('label=disable') == 2
assert not any(arg in ('--env', '--env-file', '-e', '-v', '--volume') for arg in args)
PY
}

@test "mount probe: engine errors identify the failing source and retain the original error" {
  compose_prepare demo "$PROJECT_ENV"
  runtime_run() { printf 'original engine permission denied\n' >&2; return 125; }
  run compose_probe_mounts example.invalid/probe:test
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot access mount source: $REPO_PATH"* ]]
  [[ "$output" == *"original engine permission denied"* ]]
  [[ "$output" == *"local path checks passed"* ]]
}

@test "mount probe: Podman uses the same keep-id root initialization identity as the stack" {
  RUNTIME_ENGINE=podman
  compose_prepare demo "$PROJECT_ENV"
  runtime_run() { printf '%s\n' "$@" >> "$BATS_TEST_TMPDIR/probe.args"; }
  compose_probe_mounts example.invalid/probe:test
  [ "$(grep -c '^--userns=keep-id$' "$BATS_TEST_TMPDIR/probe.args")" -eq 2 ]
  [ "$(grep -c '^0:0$' "$BATS_TEST_TMPDIR/probe.args")" -eq 2 ]
}

@test "also paths: colon sources fail before either provider can reinterpret them" {
  local extra="$BATS_TEST_TMPDIR/with:colon"
  mkdir -p "$extra"
  write_also_overlay demo "$(resolve_also_mounts "$__OCL_DIR/work" "$extra")"
  RUNTIME_ENGINE=podman
  compose_prepare demo "$PROJECT_ENV"
  run compose_validate_mounts
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot mount a host path containing ':' with shared SELinux relabeling"* ]]
  [[ "$output" == *"use a path without ':'"* ]]
  RUNTIME_ENGINE=docker
  run compose_validate_mounts
  [ "$status" -ne 0 ]
}
