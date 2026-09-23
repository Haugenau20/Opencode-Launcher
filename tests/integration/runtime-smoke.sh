#!/usr/bin/env bash
# Runs real containers in a unique disposable Compose project. Requires an
# already configured engine; never changes host configuration or uses secrets.
# The sourced runtime interface deliberately has variadic dispatch wrappers.
# shellcheck disable=SC1091,SC2119
set -euo pipefail

engine="${1:?usage: runtime-smoke.sh docker|podman}"
case "$engine" in docker|podman) ;; *) echo 'choose docker or podman' >&2; exit 2 ;; esac
__OCL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$__OCL_DIR/lib/core.sh"
source "$__OCL_DIR/lib/runtime.sh"
source "$__OCL_DIR/lib/compose.sh"
source "$__OCL_DIR/lib/also.sh"
source "$__OCL_DIR/lib/packages.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ocl-runtime-smoke.XXXXXX")"
slug="smoke-${engine}-$(id -u)-$$"
ENVS_DIR="$scratch/state"
ENV_FILE="$scratch/shared.env"
export PROJECT_ENV_FILE="$scratch/project.env"
export OCL_SMOKE_IMAGE="localhost/ocl-runtime-smoke:${engine}"
export OCL_SMOKE_FIXTURES="$__OCL_DIR/tests/integration/fixtures"
mkdir -p "$ENVS_DIR" "$scratch/workspace with spaces" "$scratch/allowlist with spaces"
printf 'unchanged\n' > "$scratch/workspace with spaces/original"
original_owner="$(stat -c '%u:%g' "$scratch/workspace with spaces/original")"
printf '# empty allowlist fixture\n' > "$scratch/allowlist with spaces/placeholder.conf"
port="$(python3 - <<'PY'
import socket
for port in range(8100, 9900):
    first = socket.socket()
    second = socket.socket()
    try:
        first.bind(('127.0.0.1', port))
        second.bind(('127.0.0.1', int('1' + str(port))))
        print(port)
        break
    except OSError:
        pass
    finally:
        first.close()
        second.close()
else:
    raise SystemExit('no free smoke-test port pair')
PY
)"
{
  printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)"
  printf 'IMAGE_REGISTRY=unused-fixture\nIMAGE_TAG=local\nOPENCODE_PORT=%s\n' "$port"
  compose_env_assignment REPO_PATH "$scratch/workspace with spaces"
  compose_env_assignment EXTRA_ALLOWLIST_PATH "$scratch/allowlist with spaces"
} > "$ENV_FILE"
cp "$ENV_FILE" "$PROJECT_ENV_FILE"

started=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$started" = 1 ]; then
    if [ "$rc" -ne 0 ]; then "${COMPOSE[@]}" logs --tail 50 >&2 || true; fi
    "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null || true
  fi
  runtime_release_project
  rm -rf -- "$scratch"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

runtime_lock_project "$slug"
runtime_select "$engine" "$slug"
runtime_validate
compose_prepare "$slug" "$PROJECT_ENV_FILE"
runtime_validate_project_env "$PROJECT_ENV_FILE"
compose_validate_mounts
COMPOSE_FILES+=(-f "$__OCL_DIR/tests/integration/fixture-compose.yml")
COMPOSE=(runtime_compose --env-file "$PROJECT_ENV_FILE" -p "opencode-$slug" "${COMPOSE_FILES[@]}")
# A different cwd must not alter any effective mount/build paths.
cd /
"${COMPOSE[@]}" config --quiet
runtime_save_binding "$slug"
"${COMPOSE[@]}" build opencode
started=1
"${COMPOSE[@]}" up -d
runtime_release_project

wait_http() {
  local url="$1" attempt
  for ((attempt=1; attempt<=30; attempt++)); do
    if python3 -c 'import sys,urllib.request; print(urllib.request.urlopen(sys.argv[1],timeout=1).read().decode())' "$url" 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "service did not become ready: $url" >&2
  return 1
}
wait_http "http://127.0.0.1:$port/" | grep -F "uid=$(id -u) gid=$(id -g)"
wait_http "http://127.0.0.1:1$port/" | grep -F "uid=$(id -u) gid=$(id -g)"
"${COMPOSE[@]}" logs --tail 5 opencode >/dev/null
[ "$(stat -c '%u:%g' "$scratch/workspace with spaces/original")" = "$original_owner" ]
[ "$(stat -c '%u:%g' "$scratch/workspace with spaces/fixture-writable")" = "$original_owner" ]
runtime_projects | awk -F '\t' -v name="opencode-$slug" '$1 == name { found=1 } END { exit !found }'
runtime_exec "opencode-squid-$slug" python -c '
import errno
from pathlib import Path
try:
    Path("/etc/squid/extra-allowlist.d/must-stay-readonly.conf").write_text("unexpected")
except OSError as error:
    assert error.errno == errno.EROFS, error
else:
    raise SystemExit("allowlist mount unexpectedly writable")
'
# Preserve stdin all the way into the actual container, including exit codes.
[ "$(printf 'stdin preserved' | runtime_exec -i "opencode-$slug" cat)" = 'stdin preserved' ]
rc=0
runtime_exec "opencode-$slug" sh -c 'exit 23' || rc=$?
[ "$rc" -eq 23 ]

runtime_exec "opencode-$slug" python -c '
import urllib.request
opener=urllib.request.build_opener(urllib.request.ProxyHandler({"http":"http://squid:3128"}))
assert b"origin reachable through proxy" in opener.open("http://origin:8080",timeout=5).read()
'
origin_ip="$(runtime_exec "opencode-origin-$slug" hostname -i | awk '{print $1}')"
runtime_exec -e "ORIGIN_IP=$origin_ip" "opencode-$slug" python -c '
import os, socket
try:
    connection=socket.create_connection((os.environ["ORIGIN_IP"],8080),timeout=2)
except OSError:
    pass
else:
    connection.close()
    raise SystemExit("network boundary broken: application reached external network directly")
'
runtime_exec -u "$(id -u):$(id -g)" "opencode-$slug" sh -c \
  'echo persisted > /home/dev/.local/share/opencode/smoke-state; echo configured > /home/dev/.config/opencode/smoke-config'
"${COMPOSE[@]}" down

# A changed default must retain the saved engine for subsequent operations.
if [ "$engine" = docker ]; then OCL_ENGINE=podman; else OCL_ENGINE=docker; fi
runtime_select '' "$slug"
runtime_validate
[ "$RUNTIME_ENGINE" = "$engine" ]
"${COMPOSE[@]}" up -d
wait_http "http://127.0.0.1:$port/" >/dev/null
[ "$(runtime_exec "opencode-$slug" cat /home/dev/.local/share/opencode/smoke-state)" = persisted ]
[ "$(runtime_exec "opencode-$slug" cat /home/dev/.config/opencode/smoke-config)" = configured ]
printf 'PASS: %s real-container Compose smoke test\n' "$engine"
