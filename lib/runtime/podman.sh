# shellcheck shell=bash
# Public output variables are consumed by the runtime interface and doctor.
# shellcheck disable=SC2034
# Local rootless Podman + explicitly invoked podman-compose. Remote selectors
# are rejected at validation and removed from every child invocation.

_runtime_podman_available() { command -v podman >/dev/null 2>&1; }
_runtime_podman_command() { env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman --remote=false "$@"; }

_runtime_podman_validate() {
  local rootless graphroot version uidmap gidmap
  _runtime_podman_available || { _runtime_error 'Podman is not installed; install Podman and podman-compose'; return 1; }
  if [ -n "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ]; then
    _runtime_error 'remote Podman connections are unsupported; unset CONTAINER_HOST/CONTAINER_CONNECTION and use local rootless Podman'; return 1
  fi
  rootless="$(_runtime_podman_command info --format '{{.Host.Security.Rootless}}')" || {
    _runtime_error 'cannot initialize local Podman; check rootless user namespace and storage configuration'; return 1;
  }
  if [ "$rootless" != true ] || [ "$(_runtime_uid)" = 0 ]; then
    _runtime_error 'this launcher supports rootless Podman only; run it as your ordinary user'; return 1
  fi
  graphroot="$(_runtime_podman_command info --format '{{.Store.GraphRoot}}')" || return 1
  [ -n "$graphroot" ] || { _runtime_error 'Podman did not report its local storage directory'; return 1; }
  RUNTIME_ENDPOINT="local:$graphroot"
  RUNTIME_MODE=rootless
  RUNTIME_ENGINE_VERSION="$(_runtime_podman_engine_version)" || return 1
  command -v podman-compose >/dev/null 2>&1 || {
    _runtime_error 'podman-compose is required; install podman-compose >= 1.5.0 (the launcher does not delegate to an arbitrary podman compose provider)'; return 1;
  }
  RUNTIME_PROVIDER_VERSION="$(_runtime_podman_provider_version)" || return 1
  version="$(printf '%s\n' "$RUNTIME_PROVIDER_VERSION" | sed -nE 's/^podman-compose version:? v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
  if [ -z "$version" ] || ! awk -v v="$version" 'BEGIN { split(v,a,"."); exit !(a[1]>1 || (a[1]==1 && a[2]>=5)) }'; then
    _runtime_error "podman-compose >= 1.5.0 is required; found ${version:-an unrecognized version}"; return 1
  fi
  # Inspect real user-namespace maps rather than assuming /etc/subuid is the
  # only allocation source (NSS-backed enterprise hosts can supply them).
  uidmap="$(_runtime_podman_command unshare cat /proc/self/uid_map)" || return 1
  gidmap="$(_runtime_podman_command unshare cat /proc/self/gid_map)" || return 1
  if ! printf '%s\n' "$uidmap" | awk '{ n+=$3 } END { exit !(n>=65536) }' \
    || ! printf '%s\n' "$gidmap" | awk '{ n+=$3 } END { exit !(n>=65536) }'; then
    _runtime_error 'rootless Podman needs subordinate UID and GID ranges (at least 65536 IDs) for keep-id; ask your administrator to configure the account mappings'; return 1
  fi
  RUNTIME_PROVIDER=podman-compose
}

_runtime_podman_compose() {
  # --in-pod=false prevents a provider default from putting all services in a
  # shared network namespace and bypassing the proxy network boundary.
  # podman-compose inserts --podman-args AFTER the Podman subcommand, where
  # global --remote is invalid. An explicit executable wrapper puts it before
  # the subcommand for every provider operation, including build and version.
  local root
  root="${__OCL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
  env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman-compose \
    --in-pod=false --podman-path "$root/lib/runtime/podman-command.sh" "$@"
}
_runtime_podman_exec() { _runtime_podman_command exec "$@"; }
_runtime_podman_exec_replace() { exec env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman --remote=false exec "$@"; }
_runtime_podman_run() { _runtime_podman_command run "$@"; }
_runtime_podman_image_inspect() { _runtime_podman_command image inspect "$@"; }
_runtime_podman_manifest_inspect() { _runtime_podman_command manifest inspect "$@"; }
_runtime_podman_engine_version() { _runtime_podman_command version --format '{{.Client.Version}}'; }
_runtime_podman_provider_version() { _runtime_podman_compose --version; }
_runtime_podman_default_address_pools() { printf '0\n'; }
_runtime_podman_network_count() {
  local output
  output="$(_runtime_podman_command network ls --filter driver=bridge --format '{{.Name}}')" || return 1
  printf '%s\n' "$output" | awk 'NF { count++ } END { print count+0 }'
}
_runtime_podman_container_running() {
  local output
  output="$(_runtime_podman_command ps --format '{{.Names}}')" || return 1
  printf '%s\n' "$output" | grep -qxF -- "$1"
}
_runtime_podman_projects() {
  local output
  # podman-compose has no equivalent of Docker Compose's global `ls`. Labels
  # are its stable discovery mechanism, including stopped containers.
  output="$(_runtime_podman_command ps --all --format $'{{.Label "com.docker.compose.project"}}\t{{.State}}')" || return 1
  printf '%s\n' "$output" | awk -F '\t' '
    $1 != "" { total[$1]++; if ($2 == "running") running[$1]++ }
    END { for (p in total) {
      if (running[p]) printf "%s\trunning(%d)\n", p, running[p]
      else printf "%s\texited(%d)\n", p, total[p]
    }}' | sort
}
