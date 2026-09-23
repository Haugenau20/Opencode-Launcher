# shellcheck shell=bash
# Shared Compose assembly. Runtime adapters supply the executable; this module
# supplies the same effective paths and overlays to either provider.

# Parse a single-line dotenv value without executing shell code. Generated
# settings are literal single-quoted strings; also accept the launcher's
# existing unquoted files. Duplicate assignments use Compose's last-wins rule.
compose_env_value() {
  local key="$1" file="$2" value quote ch next decoded="" i
  [ -r "$file" ] || return 0
  value="$(sed -n "s|^${key}=\(.*\)$|\1|p" "$file" | tail -n1)"
  value="${value%$'\r'}"
  quote="${value:0:1}"
  if [[ ( "$quote" == "'" || "$quote" == '"' ) && "${value: -1}" == "$quote" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
    for ((i=0; i<${#value}; i++)); do
      ch="${value:i:1}"
      if [[ "$ch" == '\' && $((i + 1)) -lt ${#value} ]]; then
        next="${value:i+1:1}"
        if [[ "$next" == '\' || "$next" == "$quote" ]]; then
          ch="$next"; i=$((i + 1))
        elif [[ "$quote" == '"' ]]; then
          case "$next" in
            n) ch=$'\n'; i=$((i + 1)) ;;
            r) ch=$'\r'; i=$((i + 1)) ;;
            t) ch=$'\t'; i=$((i + 1)) ;;
          esac
        fi
      fi
      decoded+="$ch"
    done
    value="$decoded"
  fi
  printf '%s' "$value"
}

# Literal dotenv assignment; shell metacharacters must stay data when a
# provider parses --env-file. No eval/source is used to read generated files.
compose_env_assignment() {
  local key="$1" value="$2"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid generated configuration key"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$key cannot contain a newline"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "%s='%s'\n" "$key" "$value"
}

# Resolve all launcher configuration paths from the launcher root, never from
# the current directory or the location of the first Compose file. -m allows
# management/cleanup to assemble the original configuration after a source
# directory was moved or removed; startup validates sources separately.
compose_absolute_path() {
  local path="$1" base="${2:-$__OCL_DIR}"
  case "$path" in
    /*) ;;
    *) path="${base}/${path}" ;;
  esac
  realpath -m -- "$path"
}

# compose_prepare SLUG EFFECTIVE_ENV_FILE
# The generated project env is a complete snapshot of shared settings plus
# project overrides. Never read current shared settings for overlay selection:
# a later --down must describe what that project actually started with.
# Populates COMPOSE_FILES (-f/path pairs), exported interpolation variables,
# and COMPOSE_MOUNT_SOURCES/TARGETS (for engine access probes).
compose_prepare() {
  local slug="$1" effective_env="$2" setting overlay package_layer abs _mode name
  PROJECT_ENV_FILE="$(compose_absolute_path "$effective_env")"
  [ -r "$PROJECT_ENV_FILE" ] || die "project configuration is missing or unreadable: $PROJECT_ENV_FILE"
  OCL_SHARED_ENV_FILE="$(compose_absolute_path "${ENV_FILE:-.env}")"
  # A saved project env includes the shared values; it remains usable for
  # cleanup even if the shared file was subsequently removed.
  [ -r "$OCL_SHARED_ENV_FILE" ] || OCL_SHARED_ENV_FILE="$PROJECT_ENV_FILE"
  PROJECT_SLUG="$slug"
  REPO_PATH="$(compose_env_value REPO_PATH "$PROJECT_ENV_FILE")"
  [ -n "$REPO_PATH" ] || die "project configuration has no REPO_PATH: $PROJECT_ENV_FILE"
  REPO_PATH="$(compose_absolute_path "$REPO_PATH")"
  setting="$(compose_env_value EXTRA_ALLOWLIST_PATH "$PROJECT_ENV_FILE")"
  EXTRA_ALLOWLIST_PATH="$(compose_absolute_path "${setting:-extra-allowlist.d}")"
  setting="$(compose_env_value USER_LAYER_PATH "$PROJECT_ENV_FILE")"
  USER_LAYER_PATH=""
  [ -z "$setting" ] || USER_LAYER_PATH="$(compose_absolute_path "$setting")"
  OCL_BUILD_CONTEXT="$(compose_absolute_path .)"
  OCL_BUILD_DOCKERFILE="$(compose_absolute_path docker/Dockerfile.user-packages)"
  OC_BASE_IMAGE="$(compose_env_value OC_BASE_IMAGE "$PROJECT_ENV_FILE")"
  for setting in IMAGE_REGISTRY IMAGE_TAG OPENCODE_PORT OPENCODE_INTERNAL_PORT; do
    printf -v "$setting" '%s' "$(compose_env_value "$setting" "$PROJECT_ENV_FILE")"
    export "${setting?}"
  done
  IMAGE_REGISTRY="${IMAGE_REGISTRY:-opencode-workplace}"
  IMAGE_TAG="${IMAGE_TAG:-latest}"
  OCL_OPENCODE_IMAGE="$(compute_base_image "$IMAGE_REGISTRY" "$IMAGE_TAG")"
  OCL_SQUID_IMAGE="$(compute_base_image "${IMAGE_REGISTRY}-squid" "$IMAGE_TAG")"
  export OCL_SHARED_ENV_FILE PROJECT_ENV_FILE PROJECT_SLUG REPO_PATH
  export EXTRA_ALLOWLIST_PATH USER_LAYER_PATH OCL_BUILD_CONTEXT OCL_BUILD_DOCKERFILE OC_BASE_IMAGE
  export OCL_OPENCODE_IMAGE OCL_SQUID_IMAGE

  COMPOSE_FILES=(-f "$__OCL_DIR/docker/docker-compose.yml")
  if [ "${RUNTIME_ENGINE:-docker}" = podman ]; then
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.podman.yml")
  fi
  if [ -n "$USER_LAYER_PATH" ]; then
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
  fi
  package_layer="$(compose_env_value OCL_PACKAGE_LAYER "$PROJECT_ENV_FILE")"
  if [ "$package_layer" = 1 ] || { [ -z "$package_layer" ] && [ -n "$OC_BASE_IMAGE" ]; }; then
    [ -n "$OC_BASE_IMAGE" ] || OC_BASE_IMAGE="$(compute_base_image "${IMAGE_REGISTRY:-opencode-workplace}" "${IMAGE_TAG:-local}")"
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-packages.yml")
  fi
  overlay="$(compose_absolute_path "$(also_overlay_file "$slug")")"
  if [ -f "$overlay" ]; then
    COMPOSE_FILES+=(-f "$overlay")
  fi
  COMPOSE_MOUNT_SOURCES=("$REPO_PATH" "$EXTRA_ALLOWLIST_PATH")
  COMPOSE_MOUNT_TARGETS=(/workspace /etc/squid/extra-allowlist.d)
  COMPOSE_MOUNT_TYPES=(directory directory)
  if [ -n "$USER_LAYER_PATH" ]; then
    COMPOSE_MOUNT_SOURCES+=("$USER_LAYER_PATH")
    COMPOSE_MOUNT_TARGETS+=(/home/dev/.config/opencode)
    COMPOSE_MOUNT_TYPES+=(directory)
  fi
  if [ -f "$overlay" ]; then
    while IFS=$'\t' read -r abs _mode name; do
      [ -n "$abs" ] || continue
      COMPOSE_MOUNT_SOURCES+=("$abs")
      COMPOSE_MOUNT_TARGETS+=("/workspace-extra/$name")
      COMPOSE_MOUNT_TYPES+=(directory)
    done < <(also_mounts_from_overlay "$slug")
    # Old overlays may predate the breadcrumb. Include it only when the
    # overlay references it; its absence will then produce a local error.
    if grep -qF "$ALSO_CONTEXT_CONTAINER_PATH" "$overlay"; then
      COMPOSE_MOUNT_SOURCES+=("$(compose_absolute_path "$(also_context_file "$slug")")")
      COMPOSE_MOUNT_TARGETS+=("$ALSO_CONTEXT_CONTAINER_PATH")
      COMPOSE_MOUNT_TYPES+=(file)
    fi
  fi
}

# Only startup calls this: logs/down should continue to work when a host
# directory disappeared. This checks the invoking user's access; the runtime
# must separately establish daemon/rootless-engine access before startup.
compose_validate_mounts() {
  local path conf found=0 i
  for i in "${!COMPOSE_MOUNT_SOURCES[@]}"; do
    path="${COMPOSE_MOUNT_SOURCES[$i]}"
    # Both providers use colon-separated volume arguments for the :z relabel.
    # A source colon cannot be represented without changing the actual mount.
    if [[ "$path" == *:* ]]; then
      die "container providers cannot mount a host path containing ':' with shared SELinux relabeling: $path (use a path without ':')"
    fi
    if [ "${COMPOSE_MOUNT_TYPES[$i]:-directory}" = file ]; then
      [ -f "$path" ] && [ -r "$path" ] || die "mount source is not an existing readable file: $path"
    else
      [ -d "$path" ] || die "mount source is not an existing directory: $path"
      [ -r "$path" ] && [ -x "$path" ] || die "mount source is not readable/searchable: $path"
    fi
  done
  for conf in "$EXTRA_ALLOWLIST_PATH"/*.conf; do
    [ -f "$conf" ] || continue
    [ -r "$conf" ] || die "allowlist file is unreadable: $conf"
    found=1
  done
  [ "$found" -eq 1 ] || die "allowlist directory contains no .conf files: $EXTRA_ALLOWLIST_PATH (add a comment-only placeholder.conf when no extra domains are needed)"
}

# Check engine-side source visibility with a disposable, network-isolated
# container after its image has been pulled. No credentials or env files are
# mounted. --mount fails for missing sources instead of creating directories.
# label=disable is scoped to THIS read-only probe: Compose performs the real
# shared SELinux relabel later. A probe cannot use --mount with Docker's :z
# volume flag, and pre-label access otherwise rejects valid enforcing hosts.
compose_probe_mounts() {
  local image="$1" path field output i
  local probe=(--rm --network none --read-only --user 0:0
    --security-opt label=disable --entrypoint /bin/sh)
  if [ "${RUNTIME_ENGINE:-docker}" = podman ]; then
    probe+=(--userns=keep-id)
  fi
  for i in "${!COMPOSE_MOUNT_SOURCES[@]}"; do
    path="${COMPOSE_MOUNT_SOURCES[$i]}"
    # Both engine CLIs parse --mount as CSV. Quote the whole source field,
    # doubling embedded quotes, so commas/quotes remain part of the path.
    field="source=${path}"
    field="${field//\"/\"\"}"
    if output="$(runtime_run "${probe[@]}" \
      --mount "type=bind,\"${field}\",target=/ocl-probe,readonly" \
      "$image" -c 'test -r /ocl-probe && { test -f /ocl-probe || { test -d /ocl-probe && test -x /ocl-probe && ls -A /ocl-probe >/dev/null; }; }' 2>&1)"; then
      continue
    fi
    err "${RUNTIME_ENGINE:-container engine} cannot access mount source: $path (for ${COMPOSE_MOUNT_TARGETS[$i]})"
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    err "local path checks passed; check engine permissions, parent directories, and the backing filesystem"
    return 1
  done
}
