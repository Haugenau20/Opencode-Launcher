# shellcheck shell=bash
# Public output variables are consumed by other sourced modules.
# shellcheck disable=SC2034
# Shared runtime selection, project bindings and operation dispatch. Only the
# implementation modules call engine/provider executables. Sourcing is inert.

_runtime_error() { printf 'error: %s\n' "$*" >&2; return 1; }
_runtime_uid() { id -u; }
_runtime_gid() { id -g; }
_runtime_safe_value() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]]; }
_runtime_valid_slug() { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

runtime_binding_file() {
  _runtime_valid_slug "$1" || { _runtime_error 'invalid runtime project name'; return 1; }
  printf '%s/%s.runtime' "${ENVS_DIR:-.envs}" "$1"
}

_runtime_load_adapters() {
  local root
  root="${__OCL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
  # shellcheck source=/dev/null
  source "$root/lib/runtime/docker.sh"
  # shellcheck source=/dev/null
  source "$root/lib/runtime/podman.sh"
}

# The binding is data, never shell code. Tabs delimit keys/values; paths retain
# spaces, '=' and shell metacharacters. Unknown/duplicate fields fail closed.
runtime_load_binding() {
  local slug="$1" file key value seen='|' version=''
  file="$(runtime_binding_file "$slug")" || return 1
  [ -f "$file" ] || return 1
  RUNTIME_CONFIG_FILES=()
  while IFS=$'\t' read -r key value || [ -n "$key" ]; do
    _runtime_safe_value "$value" || { _runtime_error "invalid runtime binding: $file"; return 1; }
    if [ "$key" != compose_file ]; then
      case "$seen" in *"|$key|"*) _runtime_error "duplicate field in runtime binding: $file"; return 1 ;; esac
      seen+="$key|"
    fi
    case "$key" in
      version) version="$value" ;;
      engine) RUNTIME_ENGINE="$value" ;;
      provider) RUNTIME_PROVIDER="$value" ;;
      endpoint) RUNTIME_ENDPOINT="$value" ;;
      mode) RUNTIME_MODE="$value" ;;
      uid) RUNTIME_UID="$value" ;;
      project) RUNTIME_PROJECT="$value" ;;
      project_env) RUNTIME_PROJECT_ENV_FILE="$value" ;;
      compose_file) RUNTIME_CONFIG_FILES+=("$value") ;;
      *) _runtime_error "unknown field in runtime binding: $file"; return 1 ;;
    esac
  done < "$file"
  if [ "$version" != 1 ] || [ "${RUNTIME_PROJECT:-}" != "opencode-$slug" ] \
    || ! [[ "${RUNTIME_UID:-}" =~ ^[0-9]+$ ]] || [ -z "${RUNTIME_ENDPOINT:-}" ] \
    || [[ "${RUNTIME_PROJECT_ENV_FILE:-}" != /* ]] || [ "${#RUNTIME_CONFIG_FILES[@]}" -eq 0 ]; then
    _runtime_error "incomplete or unsupported runtime binding: $file"; return 1
  fi
  for value in "${RUNTIME_CONFIG_FILES[@]}"; do
    [[ "$value" = /* ]] || { _runtime_error "runtime binding contains a relative Compose path: $file"; return 1; }
  done
  case "${RUNTIME_ENGINE:-}:${RUNTIME_PROVIDER:-}:${RUNTIME_MODE:-}" in
    docker:docker-compose:rootful|docker:docker-compose:rootless|podman:podman-compose:rootless) ;;
    *) _runtime_error "unsupported engine/provider/mode in runtime binding: $file"; return 1 ;;
  esac
  RUNTIME_BOUND=1
}

# Saved bindings take precedence over the configured default. Explicit choices
# may not change a bound project, even when its daemon is currently unavailable.
runtime_select() {
  local requested="${1:-}" slug="${2:-}" configured='' detected='' file=''
  _runtime_load_adapters
  RUNTIME_ENGINE='' RUNTIME_PROVIDER='' RUNTIME_ENDPOINT='' RUNTIME_MODE=''
  RUNTIME_UID='' RUNTIME_PROJECT='' RUNTIME_PROJECT_ENV_FILE='' RUNTIME_BOUND=0
  RUNTIME_ENGINE_VERSION='' RUNTIME_PROVIDER_VERSION=''
  RUNTIME_CONFIG_FILES=()
  case "$requested" in ''|auto|docker|podman) ;; *) _runtime_error "unknown engine '$requested' (choose docker or podman)"; return 1 ;; esac
  [ "$requested" != auto ] || requested=''
  if [ -n "$slug" ]; then
    file="$(runtime_binding_file "$slug")" || return 1
    if [ -e "$file" ]; then
      runtime_load_binding "$slug" || return 1
      if [ -n "$requested" ] && [ "$requested" != "$RUNTIME_ENGINE" ]; then
        _runtime_error "project opencode-$slug is bound to $RUNTIME_ENGINE; --engine $requested would use a different container/volume store. Stop the original stack, then deliberately archive the binding $file before changing engines. Existing data is not migrated."
        return 1
      fi
      [ "$RUNTIME_UID" = "$(_runtime_uid)" ] || { _runtime_error "project opencode-$slug belongs to runtime user $RUNTIME_UID; use that account"; return 1; }
      return 0
    fi
  fi
  if [ -z "$requested" ]; then
    configured="${OCL_ENGINE:-}"
    if [ -z "$configured" ] && declare -F get_env >/dev/null && [ -f "${ENV_FILE:-.env}" ]; then configured="$(get_env OCL_ENGINE)"; fi
    case "$configured" in ''|auto|docker|podman) ;; *) _runtime_error "invalid OCL_ENGINE '$configured' (choose auto, docker or podman)"; return 1 ;; esac
    [ "$configured" != auto ] || configured=''
  fi
  RUNTIME_ENGINE="${requested:-$configured}"
  if [ -z "$RUNTIME_ENGINE" ]; then
    if _runtime_docker_available; then
      detected="$(_runtime_docker_backend)" || return 1
      RUNTIME_ENGINE="$detected"
    elif _runtime_podman_available; then
      RUNTIME_ENGINE=podman
    else
      _runtime_error 'no supported container engine found; install Docker Engine with Docker Compose, or rootless Podman with podman-compose'; return 1
    fi
    # Old launcher projects have no binding. Inspect both available stores so
    # installing Docker cannot silently move an existing Podman project.
    if [ -n "$slug" ] && [ -f "${ENVS_DIR:-.envs}/$slug.env" ]; then
      _runtime_adopt_legacy "$slug" || return 1
    fi
  fi
  RUNTIME_PROVIDER="${RUNTIME_ENGINE}-compose"
  RUNTIME_UID="$(_runtime_uid)"
  [ -z "$slug" ] || RUNTIME_PROJECT="opencode-$slug"
}

_runtime_adopt_legacy() {
  local slug="$1" engine projects found='' backend
  for engine in docker podman; do
    "_runtime_${engine}_available" || continue
    if [ "$engine" = docker ]; then
      backend="$(_runtime_docker_backend)" || {
        _runtime_error 'cannot discover the previous project runtime; specify --engine docker or --engine podman'; return 1;
      }
      [ "$backend" = docker ] || continue
    fi
    projects="$("_runtime_${engine}_projects")" || {
      _runtime_error "cannot inspect $engine for an existing project; specify --engine docker or --engine podman"; return 1;
    }
    if printf '%s\n' "$projects" | awk -F '\t' -v p="opencode-$slug" '$1 == p { found=1 } END { exit !found }'; then
      if [ -n "$found" ]; then
        _runtime_error "project opencode-$slug exists in both engines; specify --engine docker or --engine podman"; return 1
      fi
      found="$engine"
    fi
  done
  [ -z "$found" ] || RUNTIME_ENGINE="$found"
  return 0
}

runtime_validate() {
  [ -n "${RUNTIME_ENGINE:-}" ] || runtime_select "${OCL_ENGINE_REQUESTED:-}" || return 1
  local saved_mode="${RUNTIME_MODE:-}" saved_endpoint="${RUNTIME_ENDPOINT:-}"
  "_runtime_${RUNTIME_ENGINE}_validate" || return 1
  if [ "${RUNTIME_BOUND:-0}" = 1 ] && { [ "$saved_mode" != "$RUNTIME_MODE" ] || [ "$saved_endpoint" != "$RUNTIME_ENDPOINT" ]; }; then
    _runtime_error "the $RUNTIME_ENGINE runtime identity differs from the saved project binding; refusing to use a different container/volume store"; return 1
  fi
}

# The image changes its dev account to these IDs before dropping privileges.
# Under keep-id, different values would map workspace writes to subordinate
# host IDs. Fail before mounting instead of attempting an ownership workaround.
runtime_validate_project_env() {
  local file="$1" host_uid host_gid
  [ "${RUNTIME_ENGINE:-docker}" = podman ] || return 0
  host_uid="$(compose_env_value HOST_UID "$file")"
  host_gid="$(compose_env_value HOST_GID "$file")"
  if [ "$host_uid" != "$(_runtime_uid)" ] || [ "$host_gid" != "$(_runtime_gid)" ]; then
    _runtime_error "Podman keep-id requires HOST_UID=$(_runtime_uid) and HOST_GID=$(_runtime_gid) in the effective project settings; correct .env or the project overrides before starting"
    return 1
  fi
}

# Call after configuration is resolved and before any resources are created.
runtime_save_binding() {
  local slug="$1" file tmp item next=0 count=0
  file="$(runtime_binding_file "$slug")" || return 1
  for item in "${RUNTIME_ENGINE:-}" "${RUNTIME_PROVIDER:-}" "${RUNTIME_ENDPOINT:-}" "${RUNTIME_MODE:-}" "${PROJECT_ENV_FILE:-}" "${COMPOSE_FILES[@]}"; do
    _runtime_safe_value "$item" || { _runtime_error 'runtime paths cannot contain tabs or newlines'; return 1; }
  done
  [ -n "${RUNTIME_ENDPOINT:-}" ] && [ -n "${RUNTIME_MODE:-}" ] || { _runtime_error 'validate the runtime before saving a project binding'; return 1; }
  [[ "${PROJECT_ENV_FILE:-}" = /* ]] || { _runtime_error 'the runtime binding requires an absolute project environment path'; return 1; }
  for item in "${COMPOSE_FILES[@]}"; do
    if [ "$next" = 1 ]; then
      [[ "$item" = /* ]] || { _runtime_error 'the runtime binding requires absolute Compose paths'; return 1; }
      count=$((count + 1)); next=0
    elif [ "$item" = -f ]; then next=1
    else _runtime_error 'invalid Compose file argument in runtime binding'; return 1
    fi
  done
  if [ "$next" = 1 ] || [ "$count" = 0 ]; then _runtime_error 'the runtime binding requires resolved Compose files'; return 1; fi
  mkdir -p -- "$(dirname -- "$file")" || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! {
    printf 'version\t1\nengine\t%s\nprovider\t%s\nendpoint\t%s\nmode\t%s\nuid\t%s\nproject\topencode-%s\nproject_env\t%s\n' \
      "$RUNTIME_ENGINE" "$RUNTIME_PROVIDER" "$RUNTIME_ENDPOINT" "$RUNTIME_MODE" "$(_runtime_uid)" "$slug" "${PROJECT_ENV_FILE:-}"
    for item in "${COMPOSE_FILES[@]}"; do
      if [ "$next" = 1 ]; then printf 'compose_file\t%s\n' "$item"; next=0
      elif [ "$item" = -f ]; then next=1
      fi
    done
  } > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"; _runtime_error "could not record runtime binding: $file"; return 1
  fi
  RUNTIME_BOUND=1
}

runtime_lock_project() {
  local slug="$1" file
  _runtime_valid_slug "$slug" || { _runtime_error 'invalid project lock name'; return 1; }
  if [ -n "${RUNTIME_LOCK_FD:-}" ]; then
    [ "${RUNTIME_LOCK_SLUG:-}" = "$slug" ] && return 0
    _runtime_error 'another project lifecycle lock is already held'; return 1
  fi
  command -v flock >/dev/null 2>&1 || { _runtime_error 'flock is required to serialize project startup and shutdown'; return 1; }
  file="${ENVS_DIR:-.envs}/$slug.runtime.lock"
  mkdir -p -- "$(dirname -- "$file")" || return 1
  exec {RUNTIME_LOCK_FD}>"$file" || return 1
  if ! flock -n -x "$RUNTIME_LOCK_FD"; then
    exec {RUNTIME_LOCK_FD}>&-
    unset RUNTIME_LOCK_FD
    _runtime_error "another launcher is starting or stopping opencode-$slug; retry when it finishes"; return 1
  fi
  RUNTIME_LOCK_SLUG="$slug"
}

runtime_release_project() {
  if [ -n "${RUNTIME_LOCK_FD:-}" ]; then
    exec {RUNTIME_LOCK_FD}>&-
    unset RUNTIME_LOCK_FD RUNTIME_LOCK_SLUG
  fi
}

# Read-only helper callers can be sourced independently by the existing unit
# suite. All normal workflows select/validate explicitly before dispatch.
_runtime_dispatch() {
  local operation="$1"; shift
  _runtime_load_adapters
  "_runtime_${RUNTIME_ENGINE:-docker}_${operation}" "$@"
}
runtime_compose() { _runtime_dispatch compose "$@"; }
runtime_projects() { _runtime_dispatch projects "$@"; }
runtime_container_running() { _runtime_dispatch container_running "$@"; }
runtime_exec() { _runtime_dispatch exec "$@"; }
runtime_exec_replace() { _runtime_dispatch exec_replace "$@"; }
runtime_run() { _runtime_dispatch run "$@"; }
runtime_image_inspect() { _runtime_dispatch image_inspect "$@"; }
runtime_manifest_inspect() { _runtime_dispatch manifest_inspect "$@"; }
runtime_image_digest() { runtime_image_inspect --format '{{index .RepoDigests 0}}' "$1"; }
runtime_image_label() { runtime_image_inspect --format "{{index .Config.Labels \"$2\"}}" "$1"; }
runtime_network_count() { _runtime_dispatch network_count; }
runtime_default_address_pools() { _runtime_dispatch default_address_pools; }
runtime_engine_version() { _runtime_dispatch engine_version; }
runtime_provider_version() { _runtime_dispatch provider_version; }
