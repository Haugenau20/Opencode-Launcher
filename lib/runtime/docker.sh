# shellcheck shell=bash
# Public output variables are consumed by the runtime interface and doctor.
# shellcheck disable=SC2034
# Docker Engine + Docker Compose implementation. Keep executable names here.

_runtime_docker_available() { command -v docker >/dev/null 2>&1; }

_runtime_docker_command() {
  if [ -n "${RUNTIME_ENDPOINT:-}" ]; then
    env -u DOCKER_CONTEXT DOCKER_HOST="$RUNTIME_ENDPOINT" docker "$@"
  else
    docker "$@"
  fi
}

_runtime_docker_resolve_endpoint() {
  if [ -z "${RUNTIME_ENDPOINT:-}" ]; then
    if [ -n "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ]; then
      RUNTIME_ENDPOINT="$DOCKER_HOST"
    else
      RUNTIME_ENDPOINT="$(docker context inspect --format '{{.Endpoints.docker.Host}}')" || {
        _runtime_error 'cannot resolve the current Docker context'; return 1;
      }
    fi
  fi
  case "$RUNTIME_ENDPOINT" in unix:///*) ;; *) _runtime_error 'only local Docker Unix-socket endpoints are supported; select a local Docker context'; return 1 ;; esac
}

_runtime_docker_backend() {
  local client server
  client="$(_runtime_docker_command --version 2>/dev/null)" || {
    _runtime_error 'Docker could not start; check its installation (no automatic engine fallback)'; return 1;
  }
  if [[ "${client,,}" = *podman* ]]; then printf 'podman\n'; return 0; fi
  # Check the connection before contacting a server, including during auto
  # discovery. This also prevents remote URL credentials entering diagnostics.
  _runtime_docker_resolve_endpoint || return 1
  server="$(_runtime_docker_command version --format '{{json .Server}}')" || {
    _runtime_error 'cannot connect to the selected Docker endpoint; check that Docker is running and that this account can access its socket (no automatic engine fallback)'; return 1;
  }
  case "${server,,}" in
    *podman*) printf 'podman\n' ;;
    ''|null) _runtime_error 'Docker returned no server identity'; return 1 ;;
    *docker*|*moby*) printf 'docker\n' ;;
    *) _runtime_error 'the endpoint does not identify itself as Docker Engine; select a supported local engine explicitly'; return 1 ;;
  esac
}

_runtime_docker_validate() {
  local backend security
  _runtime_docker_available || { _runtime_error 'Docker is not installed'; return 1; }
  _runtime_docker_resolve_endpoint || return 1
  backend="$(_runtime_docker_backend)" || return 1
  [ "$backend" = docker ] || { _runtime_error 'the docker executable reaches Podman; use --engine podman with podman-compose'; return 1; }
  security="$(_runtime_docker_command info --format '{{json .SecurityOptions}}')" || {
    _runtime_error 'Docker is unavailable; check daemon/socket access'; return 1;
  }
  case "$security" in
    *rootless*) _runtime_error 'rootless Docker is outside the supported runtime scope; use local rootful Docker or rootless Podman'; return 1 ;;
    *name=userns*) _runtime_error 'Docker user-namespace remapping is outside the supported runtime scope; use local Docker without daemon-wide UID remapping or rootless Podman'; return 1 ;;
    *) RUNTIME_MODE=rootful ;;
  esac
  RUNTIME_ENGINE_VERSION="$(_runtime_docker_engine_version)" || return 1
  RUNTIME_PROVIDER_VERSION="$(_runtime_docker_provider_version)" || {
    _runtime_error 'Docker Compose is unavailable; install the Docker Compose plugin'; return 1;
  }
  RUNTIME_PROVIDER=docker-compose
}

_runtime_docker_compose() { _runtime_docker_command compose "$@"; }
_runtime_docker_exec() { _runtime_docker_command exec "$@"; }
_runtime_docker_exec_replace() {
  if [ -n "${RUNTIME_ENDPOINT:-}" ]; then
    exec env -u DOCKER_CONTEXT DOCKER_HOST="$RUNTIME_ENDPOINT" docker exec "$@"
  else
    exec docker exec "$@"
  fi
}
_runtime_docker_run() { _runtime_docker_command run "$@"; }
_runtime_docker_image_inspect() { _runtime_docker_command image inspect "$@"; }
_runtime_docker_manifest_inspect() { _runtime_docker_command manifest inspect "$@"; }
_runtime_docker_engine_version() { _runtime_docker_command version --format '{{.Server.Version}}'; }
_runtime_docker_provider_version() { _runtime_docker_command compose version --short; }
_runtime_docker_default_address_pools() { _runtime_docker_command info --format '{{len .DefaultAddressPools}}'; }
_runtime_docker_network_count() {
  local output
  output="$(_runtime_docker_command network ls --filter driver=bridge --format '{{.Name}}')" || return 1
  printf '%s\n' "$output" | awk 'NF { count++ } END { print count+0 }'
}
_runtime_docker_container_running() {
  local output
  output="$(_runtime_docker_command ps --format '{{.Names}}')" || return 1
  printf '%s\n' "$output" | grep -qxF -- "$1"
}
_runtime_docker_projects() {
  local output
  output="$(_runtime_docker_command compose ls --all --format json)" || return 1
  printf '%s\n' "$output" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g' |
    while IFS= read -r object; do
      local name status
      name="$(printf '%s' "$object" | sed -n 's/.*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      status="$(printf '%s' "$object" | sed -n 's/.*"Status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      if [ -n "$name" ]; then printf '%s\t%s\n' "$name" "$status"; fi
    done
}
