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
# Structure: the pure helpers live in lib/*.sh (sourced below) so they can be
# unit-tested in isolation (see tests/); this file keeps only the CLI surface —
# usage(), argument parsing/dispatch in main(), and the boot flow in cmd_run().
# main() runs only when the script is executed directly (the source-guard at the
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

# --- sourced libraries ------------------------------------------------------
# Resolved relative to this script's OWN location so the modules load whether
# start.sh is executed directly or merely sourced by the tests. core.sh defines
# the low-level helpers (output + env-file) that lib/config.sh and the rest
# depend on, so it must load first; the remaining modules are pure function
# definitions and may load in any order (calls resolve at run time, by which
# point every module is loaded and main() has not yet run).
__OCL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for __lib in core config project packages allowlist digest doctor commands; do
  # shellcheck source=/dev/null
  source "$__OCL_DIR/lib/$__lib.sh"
done
unset __lib

usage() {
  cat <<'EOF'
Usage:
  ./start.sh [--continue] [--persist] [--detach] [--podman] [--open] <host-repo-path>
  ./start.sh --doctor [<host-repo-path>]
  ./start.sh --status [<host-repo-path>]
  ./start.sh --down|--stop <host-repo-path>
  ./start.sh --logs <host-repo-path>
  ./start.sh --shell <host-repo-path>
  ./start.sh --reconfigure
  ./start.sh --config
  ./start.sh --show-allowlist [<host-repo-path>]
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
  --open     Once the web UI URL is known, open it in your default browser via
             `xdg-open`. Works alongside --web/--persist/--detach. Non-fatal if
             `xdg-open` isn't available (warns and continues; the URL is always
             printed regardless).
  --doctor   Run all environment checks (Docker, compose, registry auth, .env
             keys, ports, disk space) and print one pasteable PASS/WARN/FAIL
             report, then exit — no image pull, no TUI attach. Optionally pass
             a <host-repo-path> to also check that project's derived port.
             Never prints secret values. Exits non-zero if any check FAILs.
  --status   Report on running launcher stacks, then exit — no image pull, no
             TUI attach, no .env secrets required. With a <host-repo-path>,
             re-derives that project's slug/port and reports whether it's up,
             its web UI URL, and the resume command. Without one, lists every
             running opencode-* stack (project, status, port).
  --down     Tear down the stack for <host-repo-path> via `docker compose
  --stop     down`, re-deriving the same slug / per-project env file / compose
             invocation boot uses. Aliases: --down, --stop. Safe to run even
             if nothing is up; does not require .env secrets.
  --logs     Tail (follow) the running stack's logs for <host-repo-path>, then
             exit — no image pull, no TUI attach, no LLM key required. Ctrl-C
             detaches without affecting the stack. Gracefully no-ops if
             nothing is running for that project.
  --shell    Drop into an interactive shell inside the running opencode
             container for <host-repo-path>, as the `dev` user rooted at
             /workspace (falls back to `sh` if `bash` is unavailable) — no
             image pull, no LLM key required. Gracefully no-ops if the
             container isn't running.
  --reconfigure
             Re-run the secrets setup wizard, pre-filled with your current
             .env values (press Enter on any prompt to keep it). Existing
             secrets are masked, never echoed. Leaves HOST_UID/HOST_GID and
             any unrelated keys untouched. Changes apply on your next run.
             When run from a real terminal AND whiptail or dialog is
             installed, shows a small ncurses menu editor. From a real
             terminal without either installed, shows a read-only dashboard
             plus a plain-text menu so you can edit a single setting instead
             of walking all of them (still available via the menu's "a"
             option). Piped input (scripts, CI) always gets the full linear
             walk. Set OC_CONFIG_TUI=0 to force the plain-text path even when
             whiptail/dialog is available.
  --config   Print a read-only dashboard of every .env setting, grouped by
             section, then exit — no docker, no image pull, no LLM key
             required. Secret values are never printed (shown as set/unset
             only). Takes no <host-repo-path> argument. Edit values with
             ./start.sh --reconfigure.
  --show-allowlist
             Print exactly what outbound egress the sandboxed agent is
             permitted, then exit — no image pull, no TUI attach, no LLM key
             required. The authoritative allowlist (LLM endpoint, Bitbucket,
             Jira, GitLab) is enforced inside the squid image, not this repo;
             this shows the configured LLM/Bitbucket hosts from .env plus any local
             extra-allowlist.d/*.conf extensions. Optionally takes a
             <host-repo-path> (accepted for symmetry; doesn't change the
             report). Never prints secret values.
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
  local WANT_DOCTOR=0
  local WANT_STATUS=0
  local WANT_DOWN=0
  local WANT_RECONFIGURE=0
  local WANT_CONFIG=0
  local WANT_SHOW_ALLOWLIST=0
  local WANT_LOGS=0
  local WANT_SHELL=0
  local WANT_OPEN=0
  local REPO_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach|--no-tui) ATTACH_TUI=0; PERSIST=1; shift ;;
      --persist|--web)   PERSIST=1; shift ;;
      --podman) USE_PODMAN=1; shift ;;
      --tui)  ATTACH_TUI=1; shift ;;
      --continue|-c) CONTINUE=1; shift ;;
      --open) WANT_OPEN=1; shift ;;
      --doctor) WANT_DOCTOR=1; shift ;;
      --status) WANT_STATUS=1; shift ;;
      --down|--stop) WANT_DOWN=1; shift ;;
      --reconfigure) WANT_RECONFIGURE=1; shift ;;
      --config) WANT_CONFIG=1; shift ;;
      --show-allowlist) WANT_SHOW_ALLOWLIST=1; shift ;;
      --logs) WANT_LOGS=1; shift ;;
      --shell) WANT_SHELL=1; shift ;;
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

  # --doctor short-circuits everything else: no secrets prompt, no image pull,
  # no TUI attach. <host-repo-path> is OPTIONAL here (it only adds a check for
  # that project's derived port); plain preflight/env/registry checks run
  # either way.
  if [ "$WANT_DOCTOR" -eq 1 ]; then
    cmd_doctor "$REPO_ARG"
    exit $?
  fi

  # --show-allowlist also short-circuits everything else: no image pull, no
  # TUI attach, no LLM key required. <host-repo-path> is OPTIONAL (accepted
  # for symmetry with --doctor/--status; it doesn't change the report).
  if [ "$WANT_SHOW_ALLOWLIST" -eq 1 ]; then
    cmd_show_allowlist "$REPO_ARG"
    exit $?
  fi

  # --reconfigure/--status/--down also short-circuit everything else: no
  # image pull, no TUI attach. --reconfigure takes no repo path; --status's
  # is optional; --down requires one (cmd_down itself enforces that so the
  # error message matches the rest of the script).
  if [ "$WANT_RECONFIGURE" -eq 1 ]; then
    [ -z "$REPO_ARG" ] || { usage; die "--reconfigure takes no <host-repo-path> argument"; }
    cmd_reconfigure
    return 0
  fi

  # --config also short-circuits everything else: no docker, no image pull,
  # no LLM key required, pure read of $ENV_FILE. Takes no <host-repo-path>
  # argument, mirroring --reconfigure.
  if [ "$WANT_CONFIG" -eq 1 ]; then
    [ -z "$REPO_ARG" ] || { usage; die "--config takes no <host-repo-path> argument"; }
    cmd_config_show
    return 0
  fi

  if [ "$WANT_STATUS" -eq 1 ]; then
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker first."
    cmd_status "$REPO_ARG"
    return 0
  fi

  if [ "$WANT_DOWN" -eq 1 ]; then
    cmd_down "$REPO_ARG"
    return 0
  fi

  # --logs/--shell also short-circuit everything else: no image pull, no
  # secrets prompt, no LLM key required. Both require a <host-repo-path>
  # (cmd_logs/cmd_shell enforce that themselves so the error message matches
  # the rest of the script).
  if [ "$WANT_LOGS" -eq 1 ]; then
    cmd_logs "$REPO_ARG"
    return 0
  fi

  if [ "$WANT_SHELL" -eq 1 ]; then
    cmd_shell "$REPO_ARG"
    return 0
  fi

  [ -n "$REPO_ARG" ] || { usage; die "missing <host-repo-path>"; }

  # Everything validated; hand off to the boot flow with the parsed options.
  cmd_run "$REPO_ARG" "$ATTACH_TUI" "$PERSIST" "$USE_PODMAN" "$CONTINUE" "$WANT_OPEN"
}

# --- boot flow --------------------------------------------------------------
# cmd_run REPO_ARG ATTACH_TUI PERSIST USE_PODMAN CONTINUE WANT_OPEN — the full
# boot sequence for the default "run" path: preflight, first-run secrets,
# per-project env, pull, up, and (by default) attach the TUI. Split out of
# main() so main() stays a thin parse-args-and-dispatch entry point. Inherits
# strict mode (set -euo pipefail) and the cd to the script dir from main().
cmd_run() {
  local REPO_ARG="$1" ATTACH_TUI="$2" PERSIST="$3" USE_PODMAN="$4" CONTINUE="$5" WANT_OPEN="$6"

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

    if have_tui; then
      # Real terminal + whiptail/dialog available: the ncurses editor, with
      # its first-run Done gate (required_keys() must be field_satisfied
      # before Done is allowed to finish). set_host_ids does what
      # run_setup_wizard's own first-run branch does for the linear path —
      # the ncurses path must not skip it, bind-mount permissions depend on
      # HOST_UID/HOST_GID being filled in.
      run_tui_reconfigure --first-run
      set_host_ids
    else
      run_setup_wizard            # linear path — unchanged, still does its own first-run UID/GID autofill
    fi

    echo
    info "wrote $ENV_FILE — you can edit it later in your editor."
    echo
  fi

  # --- .env.example drift check ----------------------------------------------
  # Non-fatal: new config can ship in .env.example between runs (a new optional
  # key, etc). Tell the user what's missing from their own .env rather than
  # silently ignoring it. Never prints values — keys only.
  local drift_keys
  drift_keys="$(check_env_drift "$ENV_EXAMPLE" "$ENV_FILE")"
  if [ -n "$drift_keys" ]; then
    warn "$ENV_EXAMPLE has new key(s) not in your $ENV_FILE: $(printf '%s' "$drift_keys" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    warn "  run ./start.sh --reconfigure, or add them to $ENV_FILE by hand."
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

  # Concise one-line egress reminder on every boot (full detail: --show-allowlist).
  info "$(allowlist_summary_line)"

  # --- optional user layer (host-editable personal agents/skills/commands) --
  # When USER_LAYER_PATH is set, add the user-layer overlay so the dir is
  # bind-mounted at /home/dev/.config/opencode. The overlay uses
  # ${USER_LAYER_PATH:?...} so it must NOT be applied when the value is empty.
  local COMPOSE_FILES
  COMPOSE_FILES=(-f "$__OCL_DIR/docker/docker-compose.yml")
  # Podman overlay (keep-id userns + no shared pod). Kept out of the base file so
  # docker-compose.yml stays Docker-valid; applied only under Podman.
  if [ "$USE_PODMAN" -eq 1 ]; then
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.podman.yml")
    info "podman: adding overlay (keep-id userns so bind-mount ownership matches)."
  fi
  local USER_LAYER_PATH
  USER_LAYER_PATH="$(get_env USER_LAYER_PATH)"
  if [ -n "$USER_LAYER_PATH" ]; then
    mkdir -p "$USER_LAYER_PATH"
    USER_LAYER_PATH="$(cd -- "$USER_LAYER_PATH" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve USER_LAYER_PATH"
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-layer.yml")
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
  # root. The base stack is pull-only; this overlay points opencode at a distinct
  # local tag and adds a build: block (docker/Dockerfile.user-packages) so that
  # one service is built locally. Applied last so it wins. Empty/absent file =>
  # nothing here changes.
  local PKG_LAYER_ACTIVE=0 OC_BASE_IMAGE=""
  if extra_packages_active "$EXTRA_PACKAGES_FILE"; then
    PKG_LAYER_ACTIVE=1
    OC_BASE_IMAGE="$CHECK_IMAGE"
    COMPOSE_FILES+=(-f "$__OCL_DIR/docker/docker-compose.user-packages.yml")
    local apt_list pip_list
    apt_list="$(extra_apt_packages "$EXTRA_PACKAGES_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    pip_list="$(extra_pip_packages "$EXTRA_PACKAGES_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    info "system packages: baking a local opencode layer (build-time, on this host):"
    [ -n "$apt_list" ] && info "  apt: $apt_list"
    [ -n "$pip_list" ] && info "  pip: $pip_list"
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
  # See the note in the management-command builder above: the compose files sit
  # under docker/, so --project-directory pins their relative paths to the root.
  COMPOSE=(docker compose
    --project-directory "$__OCL_DIR"
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

  # --- image digest (reproducibility / tamper-check anchor) ------------------
  # Print the resolved sha256 digest of the image actually in use — the tag
  # (e.g. `latest`) can silently move, the digest cannot. Best-effort: a
  # registry/runtime that doesn't expose RepoDigests just means this is
  # skipped, never a failure. Also records it so the NEXT run can report
  # whether the image changed since last time (the update nudge below).
  local IMAGE_DIGEST=""
  IMAGE_DIGEST="$(get_image_digest "$CHECK_IMAGE" 2>/dev/null || true)"
  if [ -n "$IMAGE_DIGEST" ]; then
    info "image:   $IMAGE_DIGEST"
    report_digest_update "$SLUG" "$IMAGE_DIGEST"
  fi

  # --- 8. report ------------------------------------------------------------
  echo
  info "project: $PROJECT_NAME"
  info "repo:    $REPO_PATH  ->  /workspace"
  local WEB_UI_URL="http://localhost:${PORT}"
  if [ "$PORT_OK" -eq 1 ]; then
    info "web UI:  ${WEB_UI_URL}"
  else
    info "web UI:  ${WEB_UI_URL}  (note: opencode web UI is hardwired to 4096 — only one project gets the browser UI at a time)"
  fi
  [ "$WANT_OPEN" -eq 1 ] && open_url "$WEB_UI_URL"
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

