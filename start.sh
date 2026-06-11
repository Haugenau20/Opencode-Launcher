#!/usr/bin/env bash
#
# start.sh — boot a locked-down OpenCode workplace against your own code repo.
#
#   ./start.sh [--detach] <host-repo-path>
#   ./start.sh --help
#
# One launcher clone handles many repos: per-project settings (slug, port,
# repo path) are derived from the path argument, never stored in .env.
#
# Structure: pure helpers live at the top level so they can be sourced and
# unit-tested in isolation (see tests/). The imperative flow lives in main(),
# which only runs when the script is executed directly (the source-guard at the
# bottom). Strict mode (set -euo pipefail) is enabled inside main() so sourcing
# the file for tests has no side effects.

# Paths are overridable so tests can point them at a sandbox before sourcing.
ENV_FILE="${ENV_FILE:-.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-.env.example}"
ENVS_DIR="${ENVS_DIR:-.envs}"
EXTRA_PACKAGES_FILE="${EXTRA_PACKAGES_FILE:-extra-packages.txt}"

# Plugins baked into the image, all OFF by default. Shown as a hint during
# first-run setup so users can opt in interactively. This is only a convenience
# list: the prompt accepts any value (so a newer image's plugins still work even
# if this is stale), and the authoritative catalog is the /plugins TUI command.
KNOWN_PLUGINS="${KNOWN_PLUGINS:-superpowers dcp opencode-workspace}"

# --- tiny output helpers ----------------------------------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./start.sh [--continue] [--persist] [--detach] [--podman] <host-repo-path>
  ./start.sh --help

Boots a locked-down OpenCode environment with your repo mounted at /workspace.
By default the OpenCode TUI is attached in the foreground once the stack is up,
and exiting the TUI tears the stack down again (a clean one-in/one-out flow).

Options:
  --continue Resume your most recent opencode session instead of starting a
             fresh one (passes opencode's own -c). No-op with --detach. If no
             previous session exists, opencode starts a new one. Alias: -c.
  --persist  Keep the stack (and its web UI) running after you exit the TUI, so
             you can resume your session later. Without it, exiting the TUI
             tears the stack down. Alias: --web.
  --detach   Boot the stack but do NOT attach the TUI (headless; the stack keeps
             running). Use this for scripted/CI runs or web-only. Alias: --no-tui.
  --podman   Add the Podman overlay (keep-id userns) for rootless Podman. This is
             auto-detected when `docker` is Podman; use the flag to force it.
  --tui      Attach the TUI (this is the default; accepted for back-compat).
  --help     Show this help.

Which image tag is used is controlled by IMAGE_TAG in .env (defaults to
'latest'; set it to a specific version like 0.0.2 to pin).

Why TUI-default: on the OpenCode version baked into the current image the
web/desktop UI roots the agent at / instead of /workspace (upstream bug
anomalyco/opencode#14445, #14460). The TUI is pinned to /workspace and is
correct. Re-flip to "all frontends equal" once the image ships a serve --cwd.

First run copies .env.example -> .env and prompts for your secrets. Later runs
reuse .env (edit it by hand any time).
EOF
}

# --- env-file helpers -------------------------------------------------------
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

# --- per-project derivations ------------------------------------------------
# derive_slug PATH — lowercase basename, non [a-z0-9_-] -> '-', collapse and
# trim dashes. Falls back to 'project' if nothing survives.
derive_slug() {
  local raw slug
  raw="$(basename -- "$1")"
  slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
  [ -n "$slug" ] || slug="project"
  printf '%s' "$slug"
}

# port_in_use PORT — return 0 if something is already listening on PORT.
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

# find_free_port START [LIMIT] — echo the first free port >= START, scanning up
# to LIMIT (exclusive; default START+100). Echoes START itself if it is free.
find_free_port() {
  local p="$1" limit="${2:-$(( $1 + 100 ))}"
  while [ "$p" -lt "$limit" ] && port_in_use "$p"; do
    p=$((p + 1))
  done
  printf '%s' "$p"
}

# --- system-package layer helpers -------------------------------------------
# strip_pkg_comments FILE — echo only the meaningful package lines of FILE
# (drops blank lines and '#' comment lines). Missing file => no output. Mirrors
# the filter baked into Dockerfile.user-packages so detection and the build agree.
strip_pkg_comments() {
  local f="${1:-$EXTRA_PACKAGES_FILE}"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

# extra_packages_active [FILE] — exit 0 iff FILE lists at least one package
# (after stripping comments/blanks). Empty or absent => non-zero (feature off).
extra_packages_active() {
  [ -n "$(strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}")" ]
}

# compute_base_image REGISTRY TAG — echo the registry image start.sh runs for
# `opencode` (REGISTRY:TAG, where TAG comes from IMAGE_TAG in .env). Used both as
# the access-check target and as BASE_IMAGE for the package overlay's build.
compute_base_image() {
  local registry="$1" tag="$2"
  printf '%s' "${registry}:${tag}"
}

# --- main flow --------------------------------------------------------------
main() {
  set -euo pipefail

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  cd "$SCRIPT_DIR"

  # --- 1. parse args --------------------------------------------------------
  # ATTACH_TUI defaults to 1: the TUI is the default frontend (see usage() for
  # why — the current image's web UI roots the agent at / not /workspace).
  # PERSIST defaults to 0: exiting the TUI tears the stack down again (a clean
  #   one-command-in/one-command-out flow). --persist/--web keeps it running
  #   (web UI stays up; resume later). --detach/--no-tui skips the TUI for
  #   headless/scripted runs and implies persist — nothing is attached, so there
  #   is nothing to tear down on exit. --tui is a back-compat no-op.
  # USE_PODMAN adds the Podman overlay (keep-id userns); auto-detected below from
  #   `docker --version`, or forced with --podman.
  # CONTINUE passes opencode's own -c to the attached TUI to resume the most
  #   recent session instead of starting a fresh one.
  local ATTACH_TUI=1
  local PERSIST=0
  local USE_PODMAN=0
  local CONTINUE=0
  local REPO_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach|--no-tui) ATTACH_TUI=0; PERSIST=1; shift ;;
      --persist|--web)   PERSIST=1; shift ;;
      --podman) USE_PODMAN=1; shift ;;
      --tui)  ATTACH_TUI=1; shift ;;
      --continue|-c) CONTINUE=1; shift ;;
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

  if [ "$CONTINUE" -eq 1 ] && [ "$ATTACH_TUI" -eq 0 ]; then
    warn "--continue has no effect with --detach (no TUI is attached)."
  fi

  # --- 2. preflight checks --------------------------------------------------
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."

  if ! docker info >/dev/null 2>&1; then
    local out
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

  # Podman ships a `docker` shim (podman-docker); detect it so we can add the
  # Podman overlay, which carries a keep-id userns Docker would reject. --podman
  # forces it on regardless of what `docker` reports.
  if [ "$USE_PODMAN" -eq 0 ] && docker --version 2>&1 | grep -qi podman; then
    USE_PODMAN=1
    info "detected Podman (via 'docker --version'); enabling the Podman overlay."
  fi

  # Resolve the repo path to an absolute path.
  [ -e "$REPO_ARG" ] || die "repo path does not exist: $REPO_ARG"
  [ -d "$REPO_ARG" ] || die "repo path is not a directory: $REPO_ARG"
  local REPO_PATH
  REPO_PATH="$(cd -- "$REPO_ARG" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $REPO_ARG"

  # --- 3. first-run secrets setup -------------------------------------------
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "first run: created $ENV_FILE from $ENV_EXAMPLE. Let's fill in your secrets."
    echo

    # LLM
    local cur_base new_base
    cur_base="$(get_env LLM_API_BASE)"
    new_base="$(prompt_with_default "LLM API base URL" "$cur_base")"
    set_env LLM_API_BASE "$new_base"

    local llm_key
    printf 'LLM API key (input hidden): '
    read -rs llm_key || true; echo
    set_env LLM_API_KEY "$llm_key"

    # Bitbucket (optional — Enter to skip)
    local bb_user bb_pat
    read -r -p "Bitbucket username (optional, Enter to skip): " bb_user || true
    set_env BITBUCKET_USER "$bb_user"

    printf 'Bitbucket personal access token (optional, Enter to skip, input hidden): '
    read -rs bb_pat || true; echo
    set_env BITBUCKET_PAT "$bb_pat"

    # Git identity (optional — Enter to skip)
    local git_name git_email
    read -r -p "Git user name for container commits (optional, Enter to skip): " git_name || true
    set_env GIT_USER_NAME "$git_name"

    read -r -p "Git user email for container commits (optional, Enter to skip): " git_email || true
    set_env GIT_USER_EMAIL "$git_email"

    # Plugins (optional — all OFF by default). The image bakes these in; list the
    # ones to enable, space-separated. Free-form so a newer image's plugins still
    # work even if the hint is stale; /plugins (in the TUI) is the source of truth.
    local plugins
    info "available plugins (all off by default): ${KNOWN_PLUGINS}"
    read -r -p "Enable plugins (space-separated, Enter to skip): " plugins || true
    set_env ENABLED_PLUGINS "$plugins"

    # Image registry — pre-show default, allow Enter to accept.
    local cur_reg new_reg
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

  # --- load IMAGE_REGISTRY and IMAGE_TAG from .env --------------------------
  local IMAGE_REGISTRY IMAGE_TAG
  IMAGE_REGISTRY="$(get_env IMAGE_REGISTRY)"
  [ -n "$IMAGE_REGISTRY" ] || IMAGE_REGISTRY="CHANGEME.artifactory.example/opencode-workplace"

  case "$IMAGE_REGISTRY" in
    *CHANGEME*|*internal.example*|*artifactory.example*)
      warn "IMAGE_REGISTRY looks like a placeholder ($IMAGE_REGISTRY)."
      warn "Edit .env and set your real Artifactory path, then re-run." ;;
  esac

  IMAGE_TAG="$(get_env IMAGE_TAG)"
  [ -n "$IMAGE_TAG" ] || IMAGE_TAG="latest"

  # --- optional user layer (host-editable personal agents/skills/commands) --
  # When USER_LAYER_PATH is set, add the user-layer overlay so the dir is
  # bind-mounted at /home/dev/.config/opencode. The overlay uses
  # ${USER_LAYER_PATH:?...} so it must NOT be applied when the value is empty.
  local COMPOSE_FILES
  COMPOSE_FILES=(-f docker-compose.yml)
  # Podman overlay (keep-id userns + no shared pod). Kept out of the base file so
  # docker-compose.yml stays Docker-valid; applied only under Podman.
  if [ "$USE_PODMAN" -eq 1 ]; then
    COMPOSE_FILES+=(-f docker-compose.podman.yml)
    info "podman: adding overlay (keep-id userns so bind-mount ownership matches)."
  fi
  local USER_LAYER_PATH
  USER_LAYER_PATH="$(get_env USER_LAYER_PATH)"
  if [ -n "$USER_LAYER_PATH" ]; then
    mkdir -p "$USER_LAYER_PATH"
    USER_LAYER_PATH="$(cd -- "$USER_LAYER_PATH" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    COMPOSE_FILES+=(-f docker-compose.user-layer.yml)
    info "user layer: $USER_LAYER_PATH -> /home/dev/.config/opencode"
  fi

  local REGISTRY_HOST CHECK_IMAGE
  REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
  CHECK_IMAGE="$(compute_base_image "$IMAGE_REGISTRY" "$IMAGE_TAG")"

  # --- optional system-package layer (host-built, build-time apt) -----------
  # When extra-packages.txt lists real packages, bake them into a thin LOCAL
  # image layered on the pulled opencode base. apt runs at BUILD time on this
  # host (NOT through Squid), and the base drops root->dev via gosu at runtime,
  # so the packages are usable by the agent at runtime with no runtime egress or
  # root. The overlay points opencode at a distinct local tag and overrides its
  # build: block to use Dockerfile.user-packages; it is applied last so it wins.
  # Empty/absent file => nothing here changes.
  local PKG_LAYER_ACTIVE=0 OC_BASE_IMAGE=""
  if extra_packages_active "$EXTRA_PACKAGES_FILE"; then
    PKG_LAYER_ACTIVE=1
    OC_BASE_IMAGE="$CHECK_IMAGE"
    COMPOSE_FILES+=(-f docker-compose.user-packages.yml)
    local pkg_list
    pkg_list="$(strip_pkg_comments "$EXTRA_PACKAGES_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    info "system packages: baking a local opencode layer (build-time apt): $pkg_list"
    info "  fetched on this host; the locked-down runtime is unchanged."
  fi

  # --- 4. verify Artifactory access -----------------------------------------
  info "checking access to $CHECK_IMAGE ..."
  if ! docker manifest inspect "$CHECK_IMAGE" >/dev/null 2>&1; then
    local inspect_err
    inspect_err="$(docker manifest inspect "$CHECK_IMAGE" 2>&1 || true)"
    if printf '%s' "$inspect_err" | grep -qiE 'unauthorized|authentication|denied|forbidden|login'; then
      err "cannot pull $CHECK_IMAGE — looks like an auth problem."
      err "run:  docker login $REGISTRY_HOST"
      exit 1
    fi
    warn "could not verify $CHECK_IMAGE via 'docker manifest inspect'."
    warn "(continuing — 'docker compose pull' below will surface the real error)"
    warn "detail: $(printf '%s' "$inspect_err" | tail -n1)"
  fi

  # --- 5. compute per-project settings --------------------------------------
  local SLUG PORT PORT_OK
  SLUG="$(derive_slug "$REPO_PATH")"

  # Port: default to 4096, find next free port if taken (and warn loudly).
  PORT=4096
  PORT_OK=1
  if port_in_use 4096; then
    PORT_OK=0
    PORT="$(find_free_port 4097 4196)"
    warn "port 4096 in use; booting $SLUG on $PORT — web UI won't work on this port. The default TUI (no flag) works regardless."
  fi

  # --- 6. generate per-project env file (superset of .env) ------------------
  mkdir -p "$ENVS_DIR"
  local PROJECT_ENV
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  {
    cat "$ENV_FILE"
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "PROJECT_SLUG=${SLUG}"
    echo "OPENCODE_PORT=${PORT}"
    echo "REPO_PATH=${REPO_PATH}"
    # Overwrite USER_LAYER_PATH with the resolved absolute path (a later line
    # wins on duplicate keys) so the overlay interpolates an unambiguous path.
    [ -n "$USER_LAYER_PATH" ] && echo "USER_LAYER_PATH=${USER_LAYER_PATH}"
    # When the package layer is active, hand the overlay the base image to build
    # FROM (the registry image start.sh would otherwise run for opencode).
    [ -n "$OC_BASE_IMAGE" ] && echo "OC_BASE_IMAGE=${OC_BASE_IMAGE}"
  } > "$PROJECT_ENV"

  local PROJECT_NAME COMPOSE
  PROJECT_NAME="opencode-${SLUG}"
  COMPOSE=(docker compose
    --env-file "$PROJECT_ENV"
    -p "$PROJECT_NAME"
    "${COMPOSE_FILES[@]}")

  # --- 7. boot the stack ----------------------------------------------------
  # With the package layer active, opencode is a buildable LOCAL image: a blanket
  # `compose pull` would fail trying to pull that local tag. Pull only the
  # registry-backed services, then build opencode (which auto-pulls its FROM
  # base). Without the layer, behaviour is byte-for-byte unchanged.
  if [ "$PKG_LAYER_ACTIVE" -eq 1 ]; then
    info "pulling registry images (squid, oc-publish) for $PROJECT_NAME ..."
    "${COMPOSE[@]}" pull squid oc-publish
    info "building local opencode package layer for $PROJECT_NAME ..."
    "${COMPOSE[@]}" build opencode
  else
    info "pulling images for $PROJECT_NAME ..."
    "${COMPOSE[@]}" pull
  fi

  info "starting $PROJECT_NAME ..."
  "${COMPOSE[@]}" up -d

  # --- 8. report ------------------------------------------------------------
  echo
  info "project: $PROJECT_NAME"
  info "repo:    $REPO_PATH  ->  /workspace"
  if [ "$PORT_OK" -eq 1 ]; then
    info "web UI:  http://localhost:${PORT}"
  else
    info "web UI:  http://localhost:${PORT}  (note: opencode web UI is hardwired to 4096 — only one project gets the browser UI at a time)"
  fi
  # Web-UI caveat — keep this visible on every boot. Remove once the image ships
  # an `opencode serve --cwd` (upstream anomalyco/opencode#14445, #14460) and
  # the web/desktop UI roots the agent at /workspace again.
  warn "web/desktop UI caveat: the browser UI roots the agent"
  warn "  at / instead of /workspace. WORKAROUND: make your first prompt"
  warn "  'cd /workspace' so the agent works in your repo. The default TUI is"
  warn "  unaffected. Tracking: anomalyco/opencode#14445, #14460."
  echo

  # --- 9. attach the TUI (default) ------------------------------------------
  # TUI is the default frontend: docker exec pins -w /workspace, so the agent is
  # correctly rooted at the repo (unlike the current web UI — see the caveat
  # above). By default, exiting the TUI tears the stack down (clean one-in/one-
  # out, no orphaned stacks). --persist/--web keeps it running so the web UI
  # stays up and you can resume; --detach/--no-tui skips the TUI entirely
  # (headless — opencode serve is PID 1 and keeps running).
  local OC_ARGS=()
  [ "$CONTINUE" -eq 1 ] && OC_ARGS+=(-c)
  if [ "$ATTACH_TUI" -eq 1 ]; then
    if [ "$PERSIST" -eq 1 ]; then
      # Persist: keep the stack up after the TUI exits. `exec` hands the terminal
      # straight to docker exec (the stack outlives this script either way).
      info "attaching TUI (exit/Ctrl-C detaches; the stack keeps running) ..."
      info "  resume later with: docker exec -u dev -w /workspace -it opencode-${SLUG} opencode -c"
      exec docker exec -u dev \
        -e HOME=/home/dev \
        -e XDG_CONFIG_HOME=/home/dev/.config \
        -e XDG_DATA_HOME=/home/dev/.local/share \
        -w /workspace \
        -it "opencode-${SLUG}" opencode ${OC_ARGS[@]+"${OC_ARGS[@]}"}
    else
      # Default: attach, then tear the stack down once the TUI exits. No `exec`
      # here — we need to run `compose down` afterwards. `|| true` so a non-zero
      # TUI exit (e.g. Ctrl-C => 130) still reaches the teardown under set -e.
      info "attaching TUI (exit/Ctrl-C tears the stack down; pass --persist to keep it up) ..."
      docker exec -u dev \
        -e HOME=/home/dev \
        -e XDG_CONFIG_HOME=/home/dev/.config \
        -e XDG_DATA_HOME=/home/dev/.local/share \
        -w /workspace \
        -it "opencode-${SLUG}" opencode ${OC_ARGS[@]+"${OC_ARGS[@]}"} || true
      echo
      info "TUI exited — tearing down $PROJECT_NAME (pass --persist next time to keep it running) ..."
      "${COMPOSE[@]}" down
    fi
  else
    info "detached: stack is running. Attach the TUI any time with:"
    info "  docker exec -u dev -w /workspace -it opencode-${SLUG} opencode -c"
  fi
}

# Run main only when executed directly, not when sourced (e.g. by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
