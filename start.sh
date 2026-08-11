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
# Structure: the helpers and the --help text live in lib/*.sh (sourced below) so
# they can be unit-tested in isolation (see tests/); this file keeps only the
# orchestration — argument parsing/dispatch in main() and the boot flow in
# cmd_run(). main() runs only when the script is executed directly (the
# source-guard at the bottom). Strict mode (set -euo pipefail) is enabled inside
# main() so sourcing the file for tests has no side effects.

# Paths are overridable so tests can point them at a sandbox before sourcing.
ENV_FILE="${ENV_FILE:-.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-.env.example}"
ENVS_DIR="${ENVS_DIR:-.envs}"
EXTRA_PACKAGES_FILE="${EXTRA_PACKAGES_FILE:-extra-packages.txt}"

# Plugins baked into the image, all OFF by default. Shown as a hint during
# first-run setup so users can opt in interactively. This is only a convenience
# list: the prompt accepts any value (so a newer image's plugins still work even
# if this is stale), and the authoritative catalog is the /plugins TUI command.
KNOWN_PLUGINS="${KNOWN_PLUGINS:-superpowers dcp opencode-workspace opencode-pty}"

# --- sourced libraries ------------------------------------------------------
# Resolved relative to this script's OWN location so the modules load whether
# start.sh is executed directly or merely sourced by the tests. core.sh defines
# the low-level helpers (output + env-file) that lib/config.sh and the rest
# depend on, so it must load first; the remaining modules are pure function
# definitions and may load in any order (calls resolve at run time, by which
# point every module is loaded and main() has not yet run).
__OCL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
for __lib in core config mfiles usage project also packages allowlist digest manifest update doctor commands exec; do
  # shellcheck source=/dev/null
  source "$__OCL_DIR/lib/$__lib.sh"
done
unset __lib

# --- boot-time upgrade gate -------------------------------------------------
# upgrade_gate ATTACH_TUI [ORIG_ARGS...] — the "you're behind latest" gate.
#
# Only the newest launcher checkout running IMAGE_TAG=latest is a supported,
# tested pairing (CHANGELOG "Compatibility"). Two things can leave that state,
# and this walks the user back before the stack boots:
#
#   * the launcher checkout is behind its git upstream — a running bash can't
#     reload itself, so accepting `git pull --ff-only`s it and re-execs
#     start.sh with the original argv (guarded by OC_UPGRADED=1 so it can't
#     loop) to run the new code;
#   * IMAGE_TAG is pinned to a version/digest — accepting rewrites it to
#     `latest` in .env, and the normal boot pull then lands the newest image.
#
# Accepting brings everything current and restarts into it; declining is a soft
# no-op that boots what the user has. The gate only PROMPTS on an interactive
# TUI boot with a real tty; every other boot (--detach/--no-tui, piped/CI, no
# tty) falls back to the passive nudge that shipped before this gate — it never
# blocks or hangs where nobody can answer. Skipped entirely under
# OC_SKIP_UPDATE_CHECK=1, and once already re-exec'd this run (OC_UPGRADED=1).
#
# Uses the globals $__OCL_DIR (the launcher's own checkout) and $ENV_FILE (what
# get_env/set_env read) defined at the top of this file.
upgrade_gate() {
  [ "${OC_SKIP_UPDATE_CHECK:-0}" = "1" ] && return 0
  [ "${OC_UPGRADED:-0}" = "1" ] && return 0

  local attach="$1"; shift
  local -a orig=("$@")

  # What's stale? behind = commits behind upstream (empty/non-numeric => 0);
  # pin = the pinned IMAGE_TAG value, empty when tracking latest.
  local behind pin="" tag
  behind="$(launcher_behind_count "$__OCL_DIR")"
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  if [ -f "$ENV_FILE" ]; then
    tag="$(get_env IMAGE_TAG)"
    if image_tag_pinned "$tag"; then pin="$tag"; fi
  fi

  # Nothing stale => nothing to do.
  if [ "$behind" -eq 0 ] && [ -z "$pin" ]; then return 0; fi

  # Non-interactive (headless --detach/--no-tui, or no tty to prompt on): keep
  # the passive nudge and boot — never prompt where nobody can answer.
  if [ "$attach" -ne 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    if [ "$behind" -gt 0 ]; then
      info "launcher update available: $behind commit(s) behind origin — git pull to update"
    fi
    if [ -n "$pin" ]; then
      info "image pinned to $pin — only IMAGE_TAG=latest is a supported/tested combo; set IMAGE_TAG=latest to update"
    fi
    return 0
  fi

  # Interactive: describe the drift and offer to fix it in one prompt.
  info "updates available before boot:"
  if [ "$behind" -gt 0 ]; then info "  launcher: $behind commit(s) behind origin"; fi
  if [ -n "$pin" ]; then info "  image:    pinned to $pin (only latest is a supported/tested combo)"; fi
  local reply=""
  printf '\033[36m==>\033[0m bring everything up to date and restart? [Y/n] '
  read -r reply || true
  case "$reply" in
    ''|[Yy]|[Yy][Ee][Ss]) ;;
    *) warn "continuing on the current version (declined)."; return 0 ;;
  esac

  # Accepted. Pin first (cheap, local); then the launcher fast-forward, which
  # re-execs on success so the new code runs (and picks up the latest IMAGE_TAG
  # just written). A pin-only accept needs no re-exec: cmd_run reads the fresh
  # IMAGE_TAG=latest from .env on the way down.
  if [ -n "$pin" ]; then
    set_env IMAGE_TAG latest
    info "IMAGE_TAG set to latest."
  fi
  if [ "$behind" -gt 0 ]; then
    info "updating launcher (git pull --ff-only) ..."
    # Record the revision we're upgrading FROM (before the pull) so the restarted
    # run can show exactly which config keys are new since it — see
    # config_drift_step. Best-effort: empty if it can't be read.
    local prev_rev
    prev_rev="$(git -C "$__OCL_DIR" rev-parse HEAD 2>/dev/null || true)"
    if launcher_pull_ff "$__OCL_DIR"; then
      info "launcher updated — restarting to run the newest ..."
      export OC_UPGRADED=1
      [ -n "$prev_rev" ] && export OC_PREV_REV="$prev_rev"
      exec bash "$__OCL_DIR/start.sh" ${orig[@]+"${orig[@]}"}
    fi
    warn "couldn't fast-forward the launcher (dirty tree, diverged history, or offline)."
    warn "  resolve it by hand:  git -C \"$__OCL_DIR\" pull --ff-only"
    warn "  continuing on the current launcher version for now."
  fi
  return 0
}

# --- .env.example drift / post-upgrade config offer -------------------------
# config_drift_step [PREV_REV] — reconcile the user's .env against .env.example.
#
# Ordinary boot (no PREV_REV, or non-interactive): passively warn about any
# .env.example keys missing from the user's .env — today's behavior, unchanged.
#
# Right after an upgrade the gate re-execs us with OC_PREV_REV set to the commit
# we upgraded FROM; at a real tty we then offer to set the keys that are NEW
# since that version — the intersection of (keys added to .env.example in the
# span just pulled) ∩ (still missing from .env) ∩ (editable via the wizard) —
# one prompt each, reusing prompt_one_key. This is fully generic: it's driven by
# the tracked .env.example diff across the exact commits the user crossed, so a
# future release that adds a key surfaces automatically with no per-release code.
# Declined/leftover keys fall through to the passive warning (and a later normal
# boot re-flags anything still unset). Never prints values — keys only.
#
# Uses globals ENV_EXAMPLE, ENV_FILE, __OCL_DIR.
config_drift_step() {
  local prev_rev="${1:-}"
  local drift_keys
  drift_keys="$(check_env_drift "$ENV_EXAMPLE" "$ENV_FILE")"
  [ -n "$drift_keys" ] || return 0

  if [ -n "$prev_rev" ] && [ -t 0 ] && [ -t 1 ]; then
    local added
    added="$(env_example_added_keys "$__OCL_DIR" "$prev_rev")"
    if [ -n "$added" ]; then
      # new_keys = editable_schema_keys ∩ added ∩ drift_keys, in schema order.
      # (editable_schema_keys excludes internal keys like HOST_UID/IMAGE_TAG.)
      local -a new_keys=()
      local k
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        printf '%s\n' "$added"      | grep -qxF -- "$k" || continue
        printf '%s\n' "$drift_keys" | grep -qxF -- "$k" || continue
        new_keys+=("$k")
      done < <(editable_schema_keys)

      if [ "${#new_keys[@]}" -gt 0 ]; then
        info "you just upgraded — ${#new_keys[@]} new config key(s) since your previous version:"
        info "  ${new_keys[*]}"
        local reply=""
        printf '\033[36m==>\033[0m set them now? [Y/n] '
        read -r reply || true
        case "$reply" in
          ''|[Yy]|[Yy][Ee][Ss])
            # Buffer into an array first (done above) so each prompt_one_key
            # reads from the terminal, not from a piped key list. prompt_one_key
            # always set_env's the result, and set_env appends keys missing from
            # .env — so every offered key lands (a skipped one as an empty line,
            # which also stops the drift warning re-firing for it next boot).
            for k in "${new_keys[@]}"; do prompt_one_key "$k"; done
            info "saved to $ENV_FILE — continuing boot."
            return 0 ;;
          *)
            warn "skipped — run ./start.sh --reconfigure to set them later."
            return 0 ;;
        esac
      fi
    fi
  fi

  # Passive fallback: ordinary boot, non-interactive, or nothing newly added.
  warn "$ENV_EXAMPLE has new key(s) not in your $ENV_FILE: $(printf '%s' "$drift_keys" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  warn "  run ./start.sh --reconfigure, or add them to $ENV_FILE by hand."
  return 0
}

# --- main flow --------------------------------------------------------------
main() {
  set -euo pipefail

  # Preserve argv verbatim before the parse loop consumes it, so the boot-time
  # upgrade gate can re-exec start.sh into the freshly pulled version with the
  # exact same invocation (see upgrade_gate).
  local -a OC_ORIG_ARGS=("$@")

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  cd "$SCRIPT_DIR"

  # --- 1. parse args --------------------------------------------------------
  # ATTACH_TUI defaults to 1: the TUI is the default frontend (zero setup, always
  # rooted at /workspace; see usage()). The web/desktop UI also works — a new
  # session just defaults its working directory to / until you set /workspace.
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
  local WANT_MFILES_TOKEN=0
  local WANT_LOGS=0
  local WANT_SHELL=0
  local WANT_OPEN=0
  local WANT_EXEC=0
  local EXEC_PROMPT=""
  local ALSO_ARGS=()
  local REPO_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach|--no-tui) ATTACH_TUI=0; PERSIST=1; shift ;;
      --persist|--web)   PERSIST=1; shift ;;
      --podman) USE_PODMAN=1; shift ;;
      --tui)  ATTACH_TUI=1; shift ;;
      --continue|-c) CONTINUE=1; shift ;;
      --open) WANT_OPEN=1; shift ;;
      --also)
        [ $# -gt 1 ] || { usage; die "--also requires a <path>[:rw] argument"; }
        ALSO_ARGS+=("$2"); shift 2 ;;
      --exec)
        [ $# -gt 1 ] || { usage; die "--exec requires a <prompt> argument"; }
        WANT_EXEC=1; EXEC_PROMPT="$2"; shift 2 ;;
      --doctor) WANT_DOCTOR=1; shift ;;
      --status) WANT_STATUS=1; shift ;;
      --down|--stop) WANT_DOWN=1; shift ;;
      --reconfigure) WANT_RECONFIGURE=1; shift ;;
      --config) WANT_CONFIG=1; shift ;;
      --show-allowlist) WANT_SHOW_ALLOWLIST=1; shift ;;
      --mfiles-token) WANT_MFILES_TOKEN=1; shift ;;
      --logs) WANT_LOGS=1; shift ;;
      --shell) WANT_SHELL=1; shift ;;
      --help|-h) usage; exit 0 ;;
      --version|-V)
        if [ -r "$__OCL_DIR/VERSION" ]; then
          cat "$__OCL_DIR/VERSION"
        else
          echo "unknown"
        fi
        exit 0 ;;
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
  # no TUI attach. <host-repo-path> is OPTIONAL here (it only adds a check that
  # the repo path is usable); plain preflight/env/registry checks run
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

  # --mfiles-token also short-circuits everything else: no image pull, no TUI
  # attach, no LLM key required. Takes no <host-repo-path> argument, mirroring
  # --reconfigure/--config.
  if [ "$WANT_MFILES_TOKEN" -eq 1 ]; then
    [ -z "$REPO_ARG" ] || { usage; die "--mfiles-token takes no <host-repo-path> argument"; }
    cmd_mfiles_token
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

  # <host-repo-path> is required for every run EXCEPT a one-shot --exec, which
  # can run with no repo at all — a fire-and-forget prompt against the LLM with
  # an empty /workspace (the container gets no local code, but it still boots
  # and answers). Every other path still requires the repo.
  if [ -z "$REPO_ARG" ] && [ "$WANT_EXEC" -eq 0 ]; then
    usage; die "missing <host-repo-path>"
  fi

  # --exec is itself non-interactive (boots, runs one prompt via `docker exec`,
  # tears down, exits with that command's rc) — combining it with --detach
  # (also non-interactive, but leaves the stack running with nothing attached)
  # is a contradiction the user should be told about rather than silently
  # resolved one way. ATTACH_TUI is only ever 0 here because --detach/--no-tui
  # was passed (--exec itself doesn't touch it at parse time), so this check
  # is exactly "both flags given".
  if [ "$WANT_EXEC" -eq 1 ] && [ "$ATTACH_TUI" -eq 0 ]; then
    usage; die "--exec and --detach conflict — --exec is itself non-interactive"
  fi

  # Boot-time upgrade gate: on an interactive boot, offer to bring the launcher
  # and image up to latest (the only supported/tested pairing) before running,
  # and restart into it if accepted. Skipped for --exec, which is scripted and
  # non-interactive by construction — its output is machine-consumed and a
  # prompt would hang it (upgrade_gate also falls back to a passive nudge on any
  # non-tty boot, but skipping it here avoids the extra git fetch entirely).
  if [ "$WANT_EXEC" -eq 0 ]; then
    upgrade_gate "$ATTACH_TUI" ${OC_ORIG_ARGS[@]+"${OC_ORIG_ARGS[@]}"}
  fi

  # Everything validated; hand off to the boot flow with the parsed options.
  #
  # --exec has its own entry point (cmd_exec, lib/exec.sh): it wraps the shared
  # boot flow in the stdout/stderr isolation that makes a one-shot run print
  # EXACTLY `opencode run`'s answer on success and replay diagnostics only on
  # failure (see the full contract there). Every other run goes straight to
  # cmd_run with the normal streams.
  if [ "$WANT_EXEC" -eq 1 ]; then
    cmd_exec "$REPO_ARG" "$ATTACH_TUI" "$PERSIST" "$USE_PODMAN" "$CONTINUE" "$WANT_OPEN" \
      "$EXEC_PROMPT" "${ALSO_ARGS[@]}"
  else
    cmd_run "$REPO_ARG" "$ATTACH_TUI" "$PERSIST" "$USE_PODMAN" "$CONTINUE" "$WANT_OPEN" \
      "$WANT_EXEC" "$EXEC_PROMPT" "${ALSO_ARGS[@]}"
  fi
}

# --- boot flow --------------------------------------------------------------
# cmd_run REPO_ARG ATTACH_TUI PERSIST USE_PODMAN CONTINUE WANT_OPEN WANT_EXEC
# EXEC_PROMPT [ALSO_ARGS...] — the full boot sequence for the default "run"
# path: preflight, first-run secrets, per-project env, pull, up, and (by
# default) attach the TUI. ALSO_ARGS (the trailing, possibly-empty varargs)
# are the raw `--also` specs, one per repeated flag. Split out of
# main() so main() stays a thin parse-args-and-dispatch entry point. Inherits
# strict mode (set -euo pipefail) and the cd to the script dir from main().
cmd_run() {
  local REPO_ARG="$1" ATTACH_TUI="$2" PERSIST="$3" USE_PODMAN="$4" CONTINUE="$5" WANT_OPEN="$6"
  local WANT_EXEC="$7" EXEC_PROMPT="$8"
  shift 8
  local ALSO_ARGS=("$@")

  if [ "$CONTINUE" -eq 1 ] && [ "$ATTACH_TUI" -eq 0 ]; then
    warn "--continue has no effect with --detach (no TUI is attached)."
  fi

  # The web UI (the oc-publish service — a host-port publisher for the browser/
  # desktop UI) is only worth running when something will actually use it. A
  # one-shot `--exec` that tears the stack down afterwards never does: it just
  # `docker exec`s a single prompt into the container. So skip oc-publish there
  # — booting only opencode (+ its squid egress proxy, pulled in via depends_on)
  # is faster and publishes no port. `--persist` keeps a resumable environment,
  # so it still gets the full stack; every TUI/web run always does. Used below
  # to scope the pull/up and to suppress the web-UI report lines.
  local SERVE_WEB_UI=1
  if [ "$WANT_EXEC" -eq 1 ] && [ "$PERSIST" -eq 0 ]; then
    SERVE_WEB_UI=0
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

  # Resolve the repo path to an absolute path — or, for a one-shot --exec with
  # no repo argument, synthesize an empty scratch workspace instead. A NO_REPO
  # run mounts an empty, launcher-owned directory at /workspace: the container
  # gets no local code, but it still boots and answers a single prompt. The dir
  # lives under $ENVS_DIR (gitignored) so it never pollutes the launcher clone,
  # and we create it ourselves (mkdir -p) so it is owned by the user rather than
  # created root-owned by docker's bind-mount autocreate.
  local NO_REPO=0 REPO_PATH
  if [ -z "$REPO_ARG" ]; then
    NO_REPO=1
    mkdir -p "$ENVS_DIR/norepo.workspace"
    REPO_PATH="$(cd -- "$ENVS_DIR/norepo.workspace" >/dev/null 2>&1 && pwd)" \
      || die "could not resolve the no-repo scratch workspace"
  else
    [ -e "$REPO_ARG" ] || die "repo path does not exist: $REPO_ARG"
    [ -d "$REPO_ARG" ] || die "repo path is not a directory: $REPO_ARG"
    REPO_PATH="$(cd -- "$REPO_ARG" >/dev/null 2>&1 && pwd)" || die "could not resolve repo path: $REPO_ARG"
  fi

  # --- --also: extra repo/folder mounts (read-only by default) --------------
  # Validate/resolve now (needs only REPO_PATH, not the per-project SLUG) so a
  # bad --also path fails fast, before the secrets prompt/pull/up below. The
  # per-project overlay file itself is written later, once SLUG is known (see
  # step 6) — resolve_also_mounts/also_mount_lines (lib/also.sh) are pure.
  local ALSO_MOUNTS=""
  if [ "${#ALSO_ARGS[@]}" -gt 0 ]; then
    ALSO_MOUNTS="$(resolve_also_mounts "$REPO_PATH" "${ALSO_ARGS[@]}")"
    also_mount_lines "$ALSO_MOUNTS"
  fi

  # --- 3. first-run secrets setup -------------------------------------------
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found; cannot create $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "first run: created $ENV_FILE from $ENV_EXAMPLE. Let's fill in your secrets."
    echo

    if have_tui; then
      # Real terminal + dialog available: the ncurses editor, with
      # its first-run save gate (required_keys() must be field_satisfied
      # before staged changes can be committed). set_host_ids does what
      # run_setup_wizard's own first-run branch does for the linear path —
      # the ncurses path must not skip it, bind-mount permissions depend on
      # HOST_UID/HOST_GID being filled in. Discard also removes the template
      # copied above, leaving no partial .env behind.
      local first_run_config_rc=0
      run_tui_reconfigure --first-run --new-file || first_run_config_rc=$?
      case "$first_run_config_rc" in
        0) ;;
        2)
          echo
          info "configuration discarded — no .env file was created."
          return 0
          ;;
        *) return "$first_run_config_rc" ;;
      esac
      set_host_ids
    else
      [ -t 0 ] && [ -t 1 ] && config_tui_fallback_notice
      run_setup_wizard            # linear path — unchanged, still does its own first-run UID/GID autofill
    fi

    echo
    info "wrote $ENV_FILE — you can edit it later in your editor."
    echo
  fi

  # --- .env.example drift / post-upgrade config offer ------------------------
  # Non-fatal: new config can ship in .env.example between versions. On an
  # ordinary boot this passively flags keys missing from the user's .env; right
  # after an upgrade (OC_PREV_REV set) and at a tty it instead offers to set the
  # keys that are NEW since the version upgraded from. See config_drift_step.
  config_drift_step "${OC_PREV_REV:-}"

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
  local SLUG PORT
  if [ "$NO_REPO" -eq 1 ]; then
    # Fixed slug for no-repo runs (they all share one throwaway project) rather
    # than deriving the scratch dir's basename.
    SLUG="norepo"
  else
    SLUG="$(derive_slug "$REPO_PATH")"
  fi

  # Port: sticky per project via resolve_project_port (shared with
  # derive_project_settings in lib/project.sh — see there for the full rule).
  # In short: reuse this project's own running port, else its last-recorded
  # port if that's free, else 4096, else the first free port in 4097-4196.
  # The browser web UI derives its backend from the page's own origin, so any
  # host port works.
  PORT="$(resolve_project_port "$SLUG")"
  if [ "$PORT" != "4096" ]; then
    info "booting $SLUG on port $PORT (sticky/first-free; the web UI works on any port)."
  fi

  # --- 6. generate per-project env file (superset of .env) ------------------
  mkdir -p "$ENVS_DIR"
  local PROJECT_ENV
  PROJECT_ENV="${ENVS_DIR}/${SLUG}.env"
  local OVERRIDES_ENV
  OVERRIDES_ENV="$(project_overrides_file "$SLUG")"
  {
    cat "$ENV_FILE"
    # This project's own values, layered over the shared .env (last wins). The
    # one file under .envs/ a user is meant to edit — everything else there is
    # regenerated from scratch on every boot, so a hand-edited value in the
    # generated file would silently vanish on the next run.
    if [ -f "$OVERRIDES_ENV" ]; then
      echo
      echo "# --- from $(basename "$OVERRIDES_ENV") ---"
      cat "$OVERRIDES_ENV"
    fi
    echo
    echo "# --- per-project (generated by start.sh; do not edit by hand) ---"
    echo "# To override a value for this project, edit ${OVERRIDES_ENV}"
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

  # --- --also overlay: write (or clear) .envs/<slug>.also.yml ---------------
  # Now that SLUG is known: with mounts, (re)generate the overlay and append it
  # LAST in COMPOSE_FILES (after the podman/user-layer/package-layer overlays
  # above) so it always wins; with none, delete any stale overlay from a
  # previous boot so `compose up -d` recreates the container without it.
  if [ -n "$ALSO_MOUNTS" ]; then
    write_also_overlay "$SLUG" "$ALSO_MOUNTS"
    COMPOSE_FILES+=(-f "$(also_overlay_file "$SLUG")")
  else
    delete_also_overlay "$SLUG"
  fi

  local PROJECT_NAME COMPOSE
  PROJECT_NAME="opencode-${SLUG}"
  # PROJECT_ENV_FILE: the absolute path to the same file write_project_env
  # just wrote, EXPORTED so `docker compose` (a child process) can see it.
  # This is what actually gets per-project credentials INTO the container —
  # the opencode service's `env_file:` directive layers
  # `${PROJECT_ENV_FILE:-.env}` over the shared .env. Absolute for the reasons
  # in lib/project.sh (derive_project_settings); the short version is that a
  # miss here is silent, swallowed by env_file's `required: false`.
  #
  # This boot path assembles its own COMPOSE array rather than calling
  # derive_project_settings, so the export has to be repeated. That
  # duplication predates this change.
  local PROJECT_ENV_FILE
  PROJECT_ENV_FILE="$(cd -- "$ENVS_DIR" >/dev/null 2>&1 && pwd)/${SLUG}.env" \
    || die "could not resolve ENVS_DIR"
  export PROJECT_ENV_FILE
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
    if [ "$SERVE_WEB_UI" -eq 1 ]; then
      info "pulling registry images (squid, oc-publish) for $PROJECT_NAME ..."
      "${COMPOSE[@]}" pull squid oc-publish
    else
      info "pulling registry image (squid) for $PROJECT_NAME ..."
      "${COMPOSE[@]}" pull squid
    fi
    info "building local opencode package layer for $PROJECT_NAME ..."
    "${COMPOSE[@]}" build opencode
  else
    if [ "$SERVE_WEB_UI" -eq 1 ]; then
      info "pulling images for $PROJECT_NAME ..."
      "${COMPOSE[@]}" pull
    else
      info "pulling images (opencode, squid) for $PROJECT_NAME ..."
      "${COMPOSE[@]}" pull opencode squid
    fi
  fi

  # With the web UI, bring the whole stack up. Without it (one-shot --exec),
  # bring up only opencode; compose starts its squid dependency (depends_on)
  # but not oc-publish (a dependent, not a dependency), so no port is published.
  if [ "$SERVE_WEB_UI" -eq 1 ]; then
    info "starting $PROJECT_NAME ..."
    "${COMPOSE[@]}" up -d
  else
    info "starting $PROJECT_NAME (opencode + egress proxy; no web UI) ..."
    "${COMPOSE[@]}" up -d opencode
  fi

  # --- image digest (reproducibility / tamper-check anchor) ------------------
  # Print the resolved sha256 digest of the image actually in use — the tag
  # (e.g. `latest`) can silently move, the digest cannot. Best-effort: a
  # registry/runtime that doesn't expose RepoDigests just means this is
  # skipped, never a failure. Also records it so the NEXT run can report
  # whether the image changed since last time (the update nudge below).
  local IMAGE_DIGEST="" DIGEST_CHANGED=1
  IMAGE_DIGEST="$(get_image_digest "$CHECK_IMAGE" 2>/dev/null || true)"
  if [ -n "$IMAGE_DIGEST" ]; then
    info "image:   $IMAGE_DIGEST"
    if report_digest_update "$SLUG" "$IMAGE_DIGEST"; then
      DIGEST_CHANGED=0
    fi
  fi

  # --- image self-description (newer images only) ---------------------------
  # Only worth the extra `docker run`s when the digest actually changed above
  # — on an unchanged digest there's nothing new to say, and on an old image
  # (no manifest/label at all) every piece below degrades to empty output
  # anyway. Keeps a same-digest boot exactly as fast as before this feature.
  if [ "$DIGEST_CHANGED" -eq 0 ]; then
    local IMG_VERSION="" CHANGELOG_SECTION="" MANIFEST_JSON="" MISSING_KEYS=""
    IMG_VERSION="$(image_version_label "$CHECK_IMAGE" 2>/dev/null || true)"
    if [ -n "$IMG_VERSION" ]; then
      info "image version: $IMG_VERSION"
      CHANGELOG_SECTION="$(image_changelog_section "$CHECK_IMAGE" "$IMG_VERSION" 2>/dev/null || true)"
      if [ -n "$CHANGELOG_SECTION" ]; then
        info "changelog for $IMG_VERSION:"
        echo "  ---------------------------------------------------------------"
        printf '%s\n' "$CHANGELOG_SECTION" | sed 's/^/  /'
        echo "  ---------------------------------------------------------------"
      fi
    fi
    MANIFEST_JSON="$(image_manifest "$CHECK_IMAGE" 2>/dev/null || true)"
    if [ -n "$MANIFEST_JSON" ]; then
      MISSING_KEYS="$(manifest_missing_keys "$MANIFEST_JSON")"
      if [ -n "$MISSING_KEYS" ]; then
        warn "this image reads env key(s) your launcher doesn't know: $(printf '%s' "$MISSING_KEYS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        warn "  git pull the launcher, then ./start.sh --reconfigure"
      fi
    fi
  fi

  # --- 8. report ------------------------------------------------------------
  echo
  info "project: $PROJECT_NAME"
  if [ "$NO_REPO" -eq 1 ]; then
    info "repo:    (none — empty /workspace; one-shot run, no repo mounted)"
  else
    info "repo:    $REPO_PATH  ->  /workspace"
  fi
  # The web-UI lines only make sense when oc-publish is up (see SERVE_WEB_UI):
  # a one-shot --exec publishes no port, so printing a URL/workaround for it
  # would be misleading.
  if [ "$SERVE_WEB_UI" -eq 1 ]; then
    local WEB_UI_URL="http://localhost:${PORT}"
    info "web UI:  ${WEB_UI_URL}"
    [ "$WANT_OPEN" -eq 1 ] && open_url "$WEB_UI_URL"
    # opencode-pty viewer: only worth printing when the plugin is actually
    # enabled for this project (see pty_enabled, lib/project.sh) — its port is
    # published (oc-publish's second socat leg) either way, but nothing is
    # listening on it until the plugin's server is started in the TUI.
    if pty_enabled "$PROJECT_ENV"; then
      local VIEWER_URL="http://localhost:1${PORT}"
      info "viewer:  ${VIEWER_URL}  (start it in the TUI with /pty-open-background-spy)"
      [ "$WANT_OPEN" -eq 1 ] && open_url "$VIEWER_URL"
    fi
    # Web-UI note — keep this visible on every web-UI boot. Remove once a newer
    # image defaults a new web-UI session to /workspace (upstream
    # anomalyco/opencode#14445).
    warn "web/desktop UI note: a NEW session defaults its working directory to /"
    warn "  instead of /workspace. WORKAROUND: in the web UI click 'New session' and,"
    warn "  when prompted for the working directory, type /workspace — that session"
    warn "  then runs inside your repo. The default TUI is unaffected (always"
    warn "  /workspace). Tracking: anomalyco/opencode#14445."
  fi

  # The launcher/image update check now runs as an interactive gate BEFORE the
  # boot (see upgrade_gate, called from main): on a tty it offers to bring both
  # current and restart into the newest; on a headless/CI boot it falls back to
  # the same passive nudge that used to print here. Nothing to repeat post-boot.
  echo

  # --- 9. attach the TUI (default) ------------------------------------------
  # TUI is the default frontend: docker exec pins -w /workspace, so the agent is
  # rooted at the repo with zero setup (the web UI needs the one-step New-session
  # working-directory action — see the note above). By default, exiting the TUI
  # tears the stack down (clean one-in/one-out, no orphaned stacks).
  # --persist/--web keeps it running so the web UI
  # stays up and you can resume; --detach/--no-tui skips the TUI entirely
  # (headless — opencode serve is PID 1 and keeps running).
  local OC_ARGS=()
  [ "$CONTINUE" -eq 1 ] && OC_ARGS+=(-c)
  if [ "$WANT_EXEC" -eq 1 ]; then
    # --exec: non-interactive one-shot run — the whole path (spinner, stdin
    # handling, stdout isolation on fd3, teardown, exit code) lives in
    # exec_run (lib/exec.sh). It exits with opencode run's own rc.
    exec_run "$PROJECT_NAME" "$EXEC_PROMPT" "$CONTINUE" "$PERSIST" "${COMPOSE[@]}"
  elif [ "$ATTACH_TUI" -eq 1 ]; then
    if [ "$PERSIST" -eq 1 ]; then
      # Persist: keep the stack up after the TUI exits. `exec` hands the terminal
      # straight to docker exec (the stack outlives this script either way).
      info "attaching TUI (exit/Ctrl-C detaches; the stack keeps running) ..."
      info "  resume later with: ./start.sh --continue --persist $REPO_ARG"
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
    info "  ./start.sh --continue --persist $REPO_ARG"
  fi
}

# Run main only when executed directly, not when sourced (e.g. by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
