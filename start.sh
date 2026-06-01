#!/usr/bin/env bash
#
# start.sh — boot a locked-down OpenCode workplace against your own code repo.
#
#   ./start.sh [--tui] <host-repo-path>
#   ./start.sh --help
#
# One launcher clone handles many repos: per-project settings (slug, port,
# repo path) are derived from the path argument, never stored in .env.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"
ENVS_DIR=".envs"

# --- tiny output helpers ----------------------------------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./start.sh [--tui] <host-repo-path>
  ./start.sh --help

Boots a locked-down OpenCode environment with your repo mounted at /workspace.

Options:
  --tui    After boot, attach the OpenCode TUI in the container.
  --help   Show this help.

First run copies .env.example -> .env and prompts for your secrets. Later runs
reuse .env (edit it by hand any time).
EOF
}

# --- 1. parse args ----------------------------------------------------------
WANT_TUI=0
REPO_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tui)  WANT_TUI=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --)     shift; break ;;
    -*)     usage; die "unknown option: $1" ;;
    *)
      if [ -n "$REPO_ARG" ]; then
        usage; die "unexpected extra argument: $1"
      fi
      REPO_ARG="$1"; shift ;;
  esac
done
[ $# -gt 0 ] && [ -z "$REPO_ARG" ] && { REPO_ARG="$1"; shift; }

[ -n "$REPO_ARG" ] || { usage; die "missing <host-repo-path>"; }

# --- 2. preflight checks ----------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

if ! docker info >/dev/null 2>&1; then
  out="$(docker info 2>&1 || true)"
  if printf '%s' "$out" | grep -qi 'permission denied'; then
    err "cannot talk to the Docker daemon (permission denied)."
    err "you may need: sudo usermod -aG docker \$USER && newgrp docker"
  else
    err "cannot talk to the Docker daemon. Is it running?"
    printf '%s\n' "$out" >&2
  fi
  exit 1
fi

# docker compose v2 (plugin) required.
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) not available. Install the Docker Compose plugin."

# Resolve the repo path to an absolute path.
[ -e "$REPO_ARG" ] || die "repo path does not exist: $REPO_ARG"
[ -d "$REPO_ARG" ] || die "repo path is not a directory: $REPO_ARG"
REPO_PATH="$(cd -- "$REPO_ARG" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $REPO_ARG"

# --- 3. first-run secrets setup ---------------------------------------------
# sed-escape a replacement string for use with '|' as the delimiter.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# set_env KEY VALUE — replace `KEY=...` line in $ENV_FILE in place.
set_env() {
  local key="$1" value="$2" esc
  esc="$(sed_escape "$value")"
  sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
}

# read current value of KEY from $ENV_FILE (no surrounding processing).
get_env() {
  local key="$1"
  sed -n "s|^${key}=\(.*\)$|\1|p" "$ENV_FILE" | head -n1
}

# prompt_default VAR "Label" current-default  -> echoes chosen value
prompt_with_default() {
  local label="$1" current="$2" reply
  read -r -p "$label [$current]: " reply || true
  printf '%s' "${reply:-$current}"
}

if [ ! -f "$ENV_FILE" ]; then
  [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "first run: created $ENV_FILE from $ENV_EXAMPLE. Let's fill in your secrets."
  echo

  # LLM
  cur_base="$(get_env LLM_API_BASE)"
  new_base="$(prompt_with_default "LLM API base URL" "$cur_base")"
  set_env LLM_API_BASE "$new_base"

  printf 'LLM API key (input hidden): '
  read -rs llm_key || true; echo
  set_env LLM_API_KEY "$llm_key"

  # Bitbucket
  read -r -p "Bitbucket username: " bb_user || true
  set_env BITBUCKET_USER "$bb_user"

  printf 'Bitbucket personal access token (input hidden): '
  read -rs bb_pat || true; echo
  set_env BITBUCKET_PAT "$bb_pat"

  # Git identity
  read -r -p "Git user name (for commits in container): " git_name || true
  set_env GIT_USER_NAME "$git_name"

  read -r -p "Git user email (for commits in container): " git_email || true
  set_env GIT_USER_EMAIL "$git_email"

  # Image registry — pre-show default, allow Enter to accept.
  cur_reg="$(get_env IMAGE_REGISTRY)"
  new_reg="$(prompt_with_default "Image registry (Artifactory path)" "$cur_reg")"
  set_env IMAGE_REGISTRY "$new_reg"

  # Auto-fill UID/GID for bind-mount permissions.
  set_env HOST_UID "$(id -u)"
  set_env HOST_GID "$(id -g)"

  echo
  info "wrote $ENV_FILE — you can edit it later in your editor."
  echo
fi

# --- load IMAGE_REGISTRY from .env ------------------------------------------
IMAGE_REGISTRY="$(get_env IMAGE_REGISTRY)"
[ -n "$IMAGE_REGISTRY" ] || IMAGE_REGISTRY="CHANGEME.artifactory.example/opencode-workplace"

case "$IMAGE_REGISTRY" in
  *CHANGEME*|*internal.example*|*artifactory.example*)
    warn "IMAGE_REGISTRY looks like a placeholder ($IMAGE_REGISTRY)."
    warn "Edit .env and set your real Artifactory path, then re-run." ;;
esac

REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
PROD_IMAGE="${IMAGE_REGISTRY}:prod"

# --- 4. verify Artifactory access -------------------------------------------
info "checking access to $PROD_IMAGE ..."
if ! docker manifest inspect "$PROD_IMAGE" >/dev/null 2>&1; then
  inspect_err="$(docker manifest inspect "$PROD_IMAGE" 2>&1 || true)"
  if printf '%s' "$inspect_err" | grep -qiE 'unauthorized|authentication|denied|forbidden|login'; then
    err "cannot pull $PROD_IMAGE — looks like an auth problem."
    err "run:  docker login $REGISTRY_HOST"
    exit 1
  fi
  warn "could not verify $PROD_IMAGE via 'docker manifest inspect'."
  warn "(continuing — 'docker compose pull' below will surface the real error)"
  warn "detail: $(printf '%s' "$inspect_err" | tail -n1)"
fi

# --- 5. compute per-project settings ----------------------------------------
raw_slug="$(basename -- "$REPO_PATH")"
SLUG="$(printf '%s' "$raw_slug" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$SLUG" ] || SLUG="project"

# Port: default to 4096, find next free port if taken (and warn loudly).
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$p" >/dev/null 2>&1
  else
    # Fall back to bash /dev/tcp probe.
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1 && { exec 3>&- 3<&- 2>/dev/null; return 0; } || return 1
  fi
}

PORT=4096
PORT_OK=1
if port_in_use 4096; then
  PORT_OK=0
  p=4097
  while [ "$p" -lt 4196 ] && port_in_use "$p"; do
    p=$((p + 1))
  done
  PORT="$p"
  warn "port 4096 in use; booting $SLUG on $PORT — web UI won't work on this port, use ./start.sh --tui $REPO_ARG"
fi

# --- 6. generate per-project env file (superset of .env) --------------------
mkdir -p "$ENVS_DIR"
PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
{
  cat "$ENV_FILE"
  echo
  echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
  echo "PROJECT_SLUG=${SLUG}"
  echo "OPENCODE_PORT=${PORT}"
  echo "REPO_PATH=${REPO_PATH}"
} > "$PROJECT_ENV"

PROJECT_NAME="opencode-${SLUG}"
COMPOSE=(docker compose
  --env-file "$PROJECT_ENV"
  -p "$PROJECT_NAME"
  -f docker-compose.yml
  -f docker-compose.prod.yml)

# --- 7. boot the stack ------------------------------------------------------
info "pulling images for $PROJECT_NAME ..."
"${COMPOSE[@]}" pull

info "starting $PROJECT_NAME ..."
"${COMPOSE[@]}" up -d

# --- 8. report --------------------------------------------------------------
echo
info "project: $PROJECT_NAME"
info "repo:    $REPO_PATH  ->  /workspace"
if [ "$PORT_OK" -eq 1 ]; then
  info "web UI:  http://localhost:${PORT}"
else
  info "web UI:  http://localhost:${PORT}  (note: opencode web UI is hardwired to 4096 — use --tui on this port)"
fi
echo

# --- 9. optional TUI attach -------------------------------------------------
if [ "$WANT_TUI" -eq 1 ]; then
  info "attaching TUI (Ctrl-C / exit to detach the stack keeps running) ..."
  exec docker exec -u dev \
    -e HOME=/home/dev \
    -e XDG_CONFIG_HOME=/home/dev/.config \
    -e XDG_DATA_HOME=/home/dev/.local/share \
    -w /workspace \
    -it "opencode-${SLUG}" opencode
fi
