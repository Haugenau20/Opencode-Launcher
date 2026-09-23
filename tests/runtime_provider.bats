#!/usr/bin/env bats
# Exercise the real podman-compose parser/process launcher against a recording
# engine; no container daemon or privilege is needed. CI installs version 1.5.0.

setup() {
  load common
  provider="${OCL_REAL_PODMAN_COMPOSE:-$(command -v podman-compose || true)}"
  [ -n "$provider" ] && [ -x "$provider" ] || skip 'set OCL_REAL_PODMAN_COMPOSE to an installed real podman-compose executable'
  make_sandbox
  __OCL_DIR="$SANDBOX"
  source "$SANDBOX/lib/runtime.sh"
  mkdir -p "$BATS_TEST_TMPDIR/provider-bin" "$BATS_TEST_TMPDIR/fixture"
  ln -s "$provider" "$BATS_TEST_TMPDIR/provider-bin/podman-compose"
  cp "$REPO_ROOT/tests/fixtures/recording-podman.py" "$BATS_TEST_TMPDIR/provider-bin/podman"
  chmod +x "$BATS_TEST_TMPDIR/provider-bin/podman"
  export PATH="$BATS_TEST_TMPDIR/provider-bin:$PATH"
  export OCL_PROVIDER_ARGV_LOG="$BATS_TEST_TMPDIR/provider-argv.jsonl"
  : > "$OCL_PROVIDER_ARGV_LOG"
  cat > "$BATS_TEST_TMPDIR/fixture/compose.yml" <<'YAML'
services:
  fixture:
    image: localhost/fixture:latest
    build:
      context: .
    command: ["sleep", "infinity"]
YAML
  printf 'FROM scratch\n' > "$BATS_TEST_TMPDIR/fixture/Dockerfile"
  touch "$BATS_TEST_TMPDIR/fixture/.env"
  runtime_select podman fixture
  COMPOSE=(runtime_compose --env-file "$BATS_TEST_TMPDIR/fixture/.env" -p argv-fixture -f "$BATS_TEST_TMPDIR/fixture/compose.yml")
}

@test "real podman-compose places global engine option before build up logs and down commands" {
  # Direct adapter calls must sanitize remote selectors even when a caller has
  # not invoked runtime_validate, as provider version and discovery also do.
  export CONTAINER_HOST=ssh://invalid.example CONTAINER_CONNECTION=unexpected
  runtime_provider_version >/dev/null
  "${COMPOSE[@]}" build fixture
  "${COMPOSE[@]}" up -d --no-build
  "${COMPOSE[@]}" logs --tail 5 fixture
  "${COMPOSE[@]}" down
  python3 - "$OCL_PROVIDER_ARGV_LOG" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
assert records, 'real provider did not invoke the recording engine'
commands = set()
for record in records:
    args = record['args']
    assert args[0] == '--remote=false', args
    assert not any(arg.startswith('--remote') for arg in args[1:]), args
    assert record['host'] is None and record['connection'] is None, record
    commands.add(args[1])
assert {'--version', 'build', 'logs', 'stop', 'rm'} <= commands, commands
assert {'create', 'run'} & commands, commands
PY
}

@test "recording engine rejects the old global-option placement" {
  run podman build --remote=false .
  [ "$status" -eq 125 ]
  [[ "$output" == *'global --remote=false must be the first argument'* ]]
}
