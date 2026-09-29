#!/usr/bin/env bash
#
# install.sh — bootstrap helper for first-time setup of the OpenCode Launcher.
#
# Run it directly from a checkout, or fetch-and-run as a one-liner (see the
# Install section of README.md). It is safe to run more than once: it never
# overwrites an existing clone or an existing .env.
#
#   ./install.sh                  # clone into ./opencode-launcher (cwd)
#   INSTALL_DIR=~/tools ./install.sh   # clone into a custom directory
#
# This script does NOT boot anything itself — it only gets a clone onto disk,
# sanity-checks the selected runtime, and prints the exact next command to run.
# Actual environment/secrets setup still happens the first time you run
# ./start.sh <your-repo>, same as today.
set -euo pipefail

# --- tiny output helpers, matching start.sh's style -------------------------
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# REPLACE-ME: the real, internal git remote for this launcher repo. Used only
# when this script is run standalone (e.g. fetched via curl) and no checkout
# already exists alongside it. Keep this in sync with the clone URL documented
# in README.md's Install section.
LAUNCHER_GIT_URL="${LAUNCHER_GIT_URL:-https://CHANGEME.internal.example/scm/opencode-launcher.git}"

# Where to clone to. Defaults to ./opencode-launcher in the current directory
# so running this from, say, ~/tools lands a tidy ~/tools/opencode-launcher.
INSTALL_DIR="${INSTALL_DIR:-$PWD/opencode-launcher}"

# --- prerequisite checks -----------------------------------------------------
# The checkout must exist before checking runtimes, so bootstrap uses the same
# implementation and validation as normal startup rather than duplicating it.
run_prereq_checks() {
  runtime_select "${OCL_ENGINE_REQUESTED:-}" "" || return 1
  runtime_validate || return 1
  if [ "$RUNTIME_ENGINE" = docker ]; then
    info "docker found on PATH."
    info "docker daemon is reachable."
    info "docker compose v2 plugin is available."
  else
    info "podman found on PATH."
    info "podman rootless engine is available."
    info "podman-compose provider is available."
  fi
  info "runtime: $RUNTIME_ENGINE / $RUNTIME_PROVIDER ($RUNTIME_MODE)."
}

install_usage() {
  cat <<'EOF'
Usage: ./install.sh [--engine docker|podman] [--podman]

Clone the launcher if needed and check the selected engine and Compose provider.
--podman is an alias for --engine podman. No containers are started and no
system configuration, group membership, or existing .env is changed.
EOF
}

# --- clone (idempotent) ------------------------------------------------------
# clone_launcher DIR — clone LAUNCHER_GIT_URL into DIR unless something is
# already there. Never deletes or overwrites an existing directory; if DIR
# exists but doesn't look like this launcher, just warn and move on (the user
# can sort out the conflict by hand — this script must stay non-destructive).
clone_launcher() {
  local dir="$1"

  if [ -d "$dir" ]; then
    if [ -f "$dir/start.sh" ]; then
      info "$dir already looks like an opencode-launcher checkout — skipping clone."
      return 0
    fi
    warn "$dir already exists and doesn't look like an opencode-launcher checkout."
    warn "  leaving it untouched — set INSTALL_DIR to a different path and re-run, or clone by hand:"
    warn "  git clone $LAUNCHER_GIT_URL <a-new-directory>"
    return 1
  fi

  command -v git >/dev/null 2>&1 || die "git not found on PATH. Install git first."

  case "$LAUNCHER_GIT_URL" in
    *CHANGEME*|*internal.example*)
      die "LAUNCHER_GIT_URL is still the placeholder ($LAUNCHER_GIT_URL). Edit install.sh (or set \$LAUNCHER_GIT_URL) to your real internal repo URL, or just 'git clone' by hand — see README.md's Install section."
      ;;
  esac

  info "cloning $LAUNCHER_GIT_URL -> $dir ..."
  git clone "$LAUNCHER_GIT_URL" "$dir"
}

# --- main ---------------------------------------------------------------------
main() {
  local OCL_ENGINE_REQUESTED="" selected_arg=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) install_usage; return 0 ;;
      --engine)
        [ "$#" -ge 2 ] || die "--engine requires docker or podman"
        selected_arg="$2"; shift ;;
      --engine=*) selected_arg="${1#*=}" ;;
      --podman) selected_arg=podman ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    case "$selected_arg" in docker|podman) ;; *) die "--engine requires docker or podman" ;; esac
    if [ -n "$OCL_ENGINE_REQUESTED" ] && [ "$OCL_ENGINE_REQUESTED" != "$selected_arg" ]; then
      die "conflicting engine selections"
    fi
    OCL_ENGINE_REQUESTED="$selected_arg"
    shift
  done
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

  echo "OpenCode Launcher — bootstrap"
  echo "=============================="

  # If this script is itself sitting inside a checkout (start.sh next to it),
  # there's nothing to clone — just use that checkout in place. This is the
  # common case once a colleague has already pulled the repo by any means.
  local target_dir
  if [ -f "$here/start.sh" ]; then
    target_dir="$here"
    info "running from an existing checkout: $target_dir"
  else
    target_dir="$INSTALL_DIR"
    clone_launcher "$target_dir" || return 1
  fi

  [ -f "$target_dir/lib/runtime.sh" ] || die "launcher runtime helpers missing in $target_dir; use a complete checkout"
  # Used by the dynamically sourced runtime helpers below.
  # shellcheck disable=SC2034
  local __OCL_DIR="$target_dir" ENV_FILE="$target_dir/.env" ENVS_DIR="$target_dir/.envs"
  # shellcheck source=/dev/null
  source "$target_dir/lib/core.sh"
  # shellcheck source=/dev/null
  source "$target_dir/lib/runtime.sh"

  echo
  info "checking prerequisites ..."
  local prereq_rc=0
  run_prereq_checks || prereq_rc=1

  echo
  if [ -f "$target_dir/.env" ]; then
    info "$target_dir/.env already exists — leaving it untouched."
  else
    info "no .env yet — ./start.sh will create one and prompt for your secrets on first run."
  fi

  echo
  echo "Next steps"
  echo "----------"
  if [ "$prereq_rc" -ne 0 ]; then
    warn "one or more prerequisite checks above need attention before ./start.sh will work."
    warn "re-run ./install.sh (or ./start.sh --doctor once you have a repo) after fixing them."
  fi
  local next_engine=""
  [ -z "$OCL_ENGINE_REQUESTED" ] || next_engine=" --engine $OCL_ENGINE_REQUESTED"
  echo "  cd $target_dir && ./start.sh${next_engine} <your-repo-path>"
  echo
  info "first run prompts for your LLM endpoint/key and Artifactory path (Bitbucket and"
  info "git identity are optional). Run './start.sh --doctor' any time to re-check your setup."

  return "$prereq_rc"
}

# Run main only when executed directly, not when sourced (e.g. by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
