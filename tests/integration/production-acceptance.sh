#!/usr/bin/env bash
# Opt-in release acceptance against supplied production images on a prepared host.
# Uses the launcher's runtime dispatch and Compose assembly; never configures the host.
# shellcheck disable=SC1091,SC2119
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: production-acceptance.sh --engine docker|podman --opencode-image REF
  --squid-image REF --workspace DIR --allowlist DIR --port FOUR_DIGITS
  --proxy-url URL --results NEW_DIR [--env-file FILE]
  [--selinux enforcing|permissive|disabled]
  [--user-layer DIR] [--also-ro DIR] [--also-rw DIR]
  [--packages-file FILE] [--mixed-owner-file FILE] [--timeout SECONDS]

Run as the ordinary target account. Images must already be available to the
selected engine (pull and authenticate beforehand). The proxy URL must be a
deliberately permitted HTTP(S) destination with a successful response. Both
the port and its 1-prefixed viewer port must be available on loopback.
EOF
}

engine='' open_image='' squid_image='' workspace='' allowlist='' port=''
proxy_url='' results='' selinux='' user_layer='' also_ro='' also_rw=''
packages='' mixed_owner='' settings='' timeout=90
while (($#)); do
  case "$1" in
    --engine|--opencode-image|--squid-image|--workspace|--allowlist|--port|--proxy-url|--results|--env-file|--selinux|--user-layer|--also-ro|--also-rw|--packages-file|--mixed-owner-file|--timeout)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --engine) engine="$2" ;; --opencode-image) open_image="$2" ;;
        --squid-image) squid_image="$2" ;; --workspace) workspace="$2" ;;
        --allowlist) allowlist="$2" ;; --port) port="$2" ;;
        --proxy-url) proxy_url="$2" ;; --results) results="$2" ;;
        --env-file) settings="$2" ;; --selinux) selinux="$2" ;; --user-layer) user_layer="$2" ;;
        --also-ro) also_ro="$2" ;; --also-rw) also_rw="$2" ;;
        --packages-file) packages="$2" ;; --mixed-owner-file) mixed_owner="$2" ;;
        --timeout) timeout="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$engine" = docker || "$engine" = podman ]] || { usage >&2; exit 2; }
for value in "$open_image" "$squid_image" "$workspace" "$allowlist" "$port" "$proxy_url" "$results"; do
  [ -n "$value" ] || { usage >&2; exit 2; }
done
[[ "$open_image" == */* && "$squid_image" == */* ]] || { echo 'use explicit registry/image references' >&2; exit 2; }
[[ "$port" =~ ^[1-9][0-9]{3}$ ]] && ((10#$port <= 9999)) || { echo 'port must be four digits' >&2; exit 2; }
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'timeout must be positive seconds' >&2; exit 2; }
[[ "$proxy_url" =~ ^https?://[^/@]+(/|$) ]] || { echo 'proxy URL must be HTTP(S) without credentials' >&2; exit 2; }
[[ "$proxy_url" != *'?'* && "$proxy_url" != *'#'* ]] || { echo 'proxy URL cannot contain query or fragment data' >&2; exit 2; }
for path in "$workspace" "$allowlist" "$user_layer" "$also_ro" "$also_rw"; do
  [ -z "$path" ] || [ -d "$path" ] || { echo "missing directory: $path" >&2; exit 2; }
done
[ -z "$packages" ] || [ -s "$packages" ] || { echo 'packages file must be nonempty' >&2; exit 2; }
[ -z "$settings" ] || [ -r "$settings" ] || { echo 'env file must be readable' >&2; exit 2; }
[ -z "$mixed_owner" ] || [ -f "$mixed_owner" ] || { echo 'mixed-owner file must exist' >&2; exit 2; }
case "$selinux" in ''|enforcing|permissive|disabled) ;; *) usage >&2; exit 2 ;; esac
if [ -n "$selinux" ]; then
  command -v getenforce >/dev/null || { echo 'getenforce unavailable' >&2; exit 2; }
  [ "$(getenforce | tr '[:upper:]' '[:lower:]')" = "$selinux" ] || { echo 'host SELinux mode differs from --selinux' >&2; exit 2; }
fi

__OCL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$__OCL_DIR/lib/core.sh"
source "$__OCL_DIR/lib/runtime.sh"
source "$__OCL_DIR/lib/compose.sh"
source "$__OCL_DIR/lib/also.sh"
source "$__OCL_DIR/lib/packages.sh"
source "$__OCL_DIR/lib/project.sh"

# Results are deliberately new and private: configuration or engine logs may
# contain sensitive data, so only selected metadata and check outcomes are saved.
mkdir -- "$results"
results="$(cd -- "$results" && pwd)"
chmod 700 "$results"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ocl-acceptance.XXXXXX")"
chmod 700 "$scratch"
ENVS_DIR="$scratch/state" ENV_FILE="$scratch/shared.env"
PROJECT_ENV_FILE="$scratch/project.env"
slug="accept-$(id -u)-$(basename "$scratch" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')"
project="opencode-$slug"
mkdir -p "$ENVS_DIR"
started=0 marker_created=0 current=preflight marker='' also_marker=''
printf 'check\tresult\n' > "$results/checks.tsv"
record() { printf '%s\t%s\n' "$1" "$2" >> "$results/checks.tsv"; }
cleanup() {
  local rc=$? recovered=1
  trap - EXIT INT TERM
  if ((rc != 0)); then record "$current" FAIL; fi
  if ((started)); then
    if ! "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1; then
      record cleanup FAIL
      printf 'Cleanup failed: inspect project %s with %s before removing resources.\n' "$project" "$engine" >&2
      rc=1
      recovered=0
    else
      record cleanup PASS
    fi
  fi
  runtime_release_project
  if ((marker_created)); then rm -f -- "$marker" "$marker-write"; fi
  [ -z "$also_marker" ] || rm -f -- "$also_marker"
  if ((marker_created)) && [ -n "$user_layer" ]; then rm -f -- "$user_layer/acceptance-config-$slug"; fi
  # Keep state if cleanup failed so that the exact Compose project is recoverable.
  if ((recovered)); then rm -rf -- "$scratch"; else printf 'Recovery state (may contain credentials): %s\n' "$scratch" >&2; fi
  printf 'exit_code=%s\ncompleted_utc=%s\n' "$rc" "$(date -u +%FT%TZ)" >> "$results/run.txt"
  if ((rc == 0)); then printf 'PASS: automated checks and cleanup; review NOT_RUN cases in %s/checks.tsv\n' "$results"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pass() { record "$current" PASS; }

current=runtime
runtime_lock_project "$slug"
runtime_select "$engine" "$slug"
runtime_validate
[ -z "$settings" ] || cp -- "$settings" "$PROJECT_ENV_FILE"
{
  printf 'started_utc=%s\nengine=%s\nprovider=%s\nengine_version=%s\nprovider_version=%s\nmode=%s\n' \
    "$(date -u +%FT%TZ)" "$RUNTIME_ENGINE" "$RUNTIME_PROVIDER" "$RUNTIME_ENGINE_VERSION" "$RUNTIME_PROVIDER_VERSION" "$RUNTIME_MODE"
  printf 'uid=%s\ngid=%s\nselinux=%s\n' "$(id -u)" "$(id -g)" "$(command -v getenforce >/dev/null && getenforce || echo unavailable)"
  printf 'opencode_reference=%s\nsquid_reference=%s\nproject=%s\n' "$open_image" "$squid_image" "$project"
  printf 'launcher_revision=%s\nport=%s\nproxy_url=%s\nworkspace=%s\nallowlist=%s\nuser_layer=%s\nalso_ro=%s\nalso_rw=%s\n' \
    "$(git -C "$__OCL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)" "$port" "$proxy_url" \
    "$workspace" "$allowlist" "$user_layer" "$also_ro" "$also_rw"
  [ -z "$packages" ] || printf 'packages_sha256=%s\n' "$(sha256sum "$packages" | awk '{print $1}')"
} > "$results/run.txt"
pass

# Reuse Compose's image interpolation after the shared assembly; these two
# independent references need not share IMAGE_REGISTRY/IMAGE_TAG.
current=images
image_evidence() {
  local label="$1" ref="$2" raw
  raw="$(runtime_image_inspect "$ref")" || { echo "image unavailable: $ref" >&2; return 1; }
  printf '%s' "$raw" | python3 -c '
import json,sys
label,ref=sys.argv[1:]
info=json.load(sys.stdin)[0]
digests=info.get("RepoDigests") or []
if "@sha256:" in ref: digests=[ref]
repo=ref.split("@",1)[0] if "@" in ref else ref.rsplit(":",1)[0]
digests=[d for d in digests if d.startswith(repo+"@")]
if not digests: raise SystemExit("no matching repository digest for " + ref + "; pull by digest or use a registry image")
for digest in digests: print(label + "_digest=" + digest)
print(label + "_image_id=" + str(info.get("Id") or info.get("ID") or ""))
' "$label" "$ref" >> "$results/run.txt"
}
image_evidence opencode "$open_image"
image_evidence squid "$squid_image"
pass

current=paths
python3 - "$port" <<'PY'
import socket,sys
for port in (int(sys.argv[1]), int('1'+sys.argv[1])):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',port))
PY
workspace="$(realpath -- "$workspace")"
allowlist="$(realpath -- "$allowlist")"
[ -z "$user_layer" ] || user_layer="$(realpath -- "$user_layer")"
[ -z "$also_ro" ] || also_ro="$(realpath -- "$also_ro")"
[ -z "$also_rw" ] || also_rw="$(realpath -- "$also_rw")"
if [ -n "$mixed_owner" ]; then
  mixed_owner="$(realpath -- "$mixed_owner")"
  [[ "$mixed_owner" == "$workspace/"* ]] || { echo 'mixed-owner file must be inside workspace' >&2; exit 2; }
  mixed_before="$(stat -c '%u:%g' "$mixed_owner")"
fi
marker="$workspace/.ocl-acceptance-$slug"
[ ! -e "$marker" ] || { echo "marker already exists: $marker" >&2; exit 2; }
printf 'acceptance marker\n' > "$marker"
marker_created=1
pass

# The harness owns only its marker and temporary state. It never chowns the
# workspace; a mixed-owner sentinel lets the operator catch image-side chown.
{
  compose_env_assignment HOST_UID "$(id -u)"
  compose_env_assignment HOST_GID "$(id -g)"
  compose_env_assignment OPENCODE_PORT "$port"
  compose_env_assignment REPO_PATH "$workspace"
  compose_env_assignment EXTRA_ALLOWLIST_PATH "$allowlist"
  compose_env_assignment USER_LAYER_PATH "$user_layer"
  if [ -n "$packages" ]; then
    compose_env_assignment OCL_PACKAGE_LAYER 1
    compose_env_assignment OC_BASE_IMAGE "$open_image"
  else
    compose_env_assignment OCL_PACKAGE_LAYER 0
    compose_env_assignment OC_BASE_IMAGE ''
  fi
} >> "$PROJECT_ENV_FILE"
cp "$PROJECT_ENV_FILE" "$ENV_FILE"
if [ -n "$also_ro" ] || [ -n "$also_rw" ]; then
  specs=()
  [ -z "$also_ro" ] || specs+=("$also_ro")
  [ -z "$also_rw" ] || specs+=("$also_rw:rw")
  mounts="$(resolve_also_mounts "$workspace" "${specs[@]}")"
  write_also_overlay "$slug" "$mounts"
fi
compose_prepare "$slug" "$PROJECT_ENV_FILE"
OCL_OPENCODE_IMAGE="$open_image" OCL_SQUID_IMAGE="$squid_image"
export OCL_OPENCODE_IMAGE OCL_SQUID_IMAGE
if [ -n "$packages" ]; then
  mkdir "$scratch/build"
  cp "$packages" "$scratch/build/extra-packages.txt"
  cp "$__OCL_DIR/docker/Dockerfile.user-packages" "$scratch/build/Dockerfile.user-packages"
  OCL_BUILD_CONTEXT="$scratch/build" OCL_BUILD_DOCKERFILE="$scratch/build/Dockerfile.user-packages"
  export OCL_BUILD_CONTEXT OCL_BUILD_DOCKERFILE
fi
runtime_validate_project_env "$PROJECT_ENV_FILE"
compose_validate_mounts
compose_probe_mounts "$squid_image"
OCL_START_TIMEOUT="$timeout"
export OCL_START_TIMEOUT
COMPOSE=(runtime_compose --env-file "$PROJECT_ENV_FILE" -p "$project" "${COMPOSE_FILES[@]}")
current=compose
"${COMPOSE[@]}" config --quiet
runtime_save_binding "$slug"
pass

current=startup
if [ -n "$packages" ]; then
  "${COMPOSE[@]}" build opencode
  package_image_id="$(runtime_image_inspect --format '{{.Id}}' "opencode-workplace-local-$slug:user-packages")"
  printf 'package_image_id=%s\n' "$package_image_id" >> "$results/run.txt"
fi
started=1
"${COMPOSE[@]}" up -d
runtime_release_project
project_wait_ready "opencode-$slug" "${OPENCODE_INTERNAL_PORT:-4096}" || exit 1
curl --noproxy '*' --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/global/health" >/dev/null
pass

current=services
for name in "opencode-$slug" "opencode-squid-$slug" "opencode-publish-$slug"; do
  runtime_container_running "$name"
done
"${COMPOSE[@]}" logs --tail 5 >/dev/null
runtime_exec -u dev "opencode-$slug" sh -c 'test -r /workspace/"$1" && printf persisted > /home/dev/.local/share/opencode/acceptance-state' sh "$(basename "$marker")"
runtime_exec -u dev "opencode-$slug" sh -c 'printf workspace > "/workspace/$1"' sh "$(basename "$marker")-write"
runtime_exec -u dev "opencode-$slug" sh -c 'printf configured > "/home/dev/.config/opencode/acceptance-config-$1"' sh "$slug"
[ "$(stat -c '%u:%g' "$marker")" = "$(id -u):$(id -g)" ]
[ "$(stat -c '%u:%g' "$marker-write")" = "$(id -u):$(id -g)" ]
[ -z "$mixed_owner" ] || [ "$(stat -c '%u:%g' "$mixed_owner")" = "$mixed_before" ]
pass

current=network
runtime_exec -u dev "opencode-$slug" curl --proxy http://squid:3128 --noproxy '' --fail --silent --show-error --max-time 15 "$proxy_url" >/dev/null
if runtime_exec -u dev "opencode-$slug" curl --noproxy '*' --connect-only --silent --max-time 5 "$proxy_url" >/dev/null 2>&1; then
  echo 'direct application egress unexpectedly succeeded' >&2; exit 1
fi
pass

current=optional_mounts
runtime_exec "opencode-squid-$slug" cat /proc/mounts | awk '$2=="/etc/squid/extra-allowlist.d" && $4 ~ /(^|,)ro(,|$)/ {ok=1} END {exit !ok}'
if [ -n "$also_ro" ]; then
  ro_name="$(printf '%s\n' "$mounts" | awk -F '\t' -v p="$also_ro" '$1==p{print $3; exit}')"
  runtime_exec -u dev "opencode-$slug" test -r "/workspace-extra/$ro_name"
  runtime_exec "opencode-$slug" cat /proc/mounts | awk -v target="/workspace-extra/$ro_name" '$2==target && $4 ~ /(^|,)ro(,|$)/ {ok=1} END {exit !ok}'
fi
if [ -n "$also_rw" ]; then
  rw_name="$(printf '%s\n' "$mounts" | awk -F '\t' -v p="$also_rw" '$1==p{print $3; exit}')"
  also_marker="$also_rw/.ocl-acceptance-$slug"
  runtime_exec -u dev "opencode-$slug" sh -c 'echo write > "$1"' sh "/workspace-extra/$rw_name/.ocl-acceptance-$slug"
  [ "$(stat -c '%u:%g' "$also_marker")" = "$(id -u):$(id -g)" ]
  rm -- "$also_marker"
  also_marker=''
fi
[ -z "$user_layer" ] || runtime_exec -u dev "opencode-$slug" test -w /home/dev/.config/opencode
pass

current=persistence
"${COMPOSE[@]}" down
runtime_select '' "$slug"
runtime_validate
[ "$RUNTIME_ENGINE" = "$engine" ]
"${COMPOSE[@]}" up -d
project_wait_ready "opencode-$slug" "${OPENCODE_INTERNAL_PORT:-4096}"
[ "$(runtime_exec -u dev "opencode-$slug" cat /home/dev/.local/share/opencode/acceptance-state)" = persisted ]
[ "$(runtime_exec -u dev "opencode-$slug" cat "/home/dev/.config/opencode/acceptance-config-$slug")" = configured ]
[ -z "$mixed_owner" ] || [ "$(stat -c '%u:%g' "$mixed_owner")" = "$mixed_before" ]
pass

current=engine_conflict
other=docker; [ "$engine" != docker ] || other=podman
if runtime_select "$other" "$slug" >/dev/null 2>&1; then
  echo 'bound project accepted conflicting engine' >&2; exit 1
fi
runtime_select "$engine" "$slug"
runtime_validate
pass

for item in 'TUI attachment and concurrent terminals' 'piped --exec and interrupted sessions' \
  'failed-start recovery and engine outage' 'existing unbound project adoption' \
  'viewer port with active pty plugin' 'allowlist rejection and read-only enforcement'; do
  record "$item" NOT_RUN
done
