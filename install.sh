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
# sanity-checks Docker, and prints the exact next command to run. All the
# actual environment/secrets setup still happens the first time you run
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
# Deliberately lightweight: this mirrors the same checks/messages start.sh's
# own preflight and --doctor use (docker on PATH, daemon reachable, compose v2
# plugin, permission-denied => docker-group hint) without pulling in start.sh
# itself, since at this point we may not even have a checkout yet.

check_docker_present() {
  if command -v docker >/dev/null 2>&1; then
    info "docker found on PATH."
    return 0
  fi
  warn "docker not found on PATH — install Docker before running ./start.sh."
  warn "  https://docs.docker.com/engine/install/"
  return 1
}

check_docker_daemon() {
  local out
  if out="$(docker info 2>&1)"; then
    info "docker daemon is reachable."
    return 0
  fi
  if printf '%s' "$out" | grep -qi 'permission denied'; then
    warn "cannot talk to the Docker daemon (permission denied)."
    warn "  you may need: sudo usermod -aG docker \$USER && newgrp docker"
  else
    warn "cannot talk to the Docker daemon. Is it running?"
  fi
  return 1
}

check_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    info "docker compose v2 plugin is available."
    return 0
  fi
  warn "'docker compose' (v2) not available — install the Docker Compose plugin."
  return 1
}

run_prereq_checks() {
  local rc=0
  check_docker_present || rc=1
  # Only bother checking the daemon/compose plugin if docker itself exists —
  # otherwise every subsequent check is a foregone (and noisier) failure.
  if command -v docker >/dev/null 2>&1; then
    check_docker_daemon || rc=1
    check_compose_v2 || rc=1
  fi
  return "$rc"
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
    clone_launcher "$target_dir" || true
  fi

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
  echo "  cd $target_dir && ./start.sh <your-repo-path>"
  echo
  info "first run prompts for your LLM endpoint/key and Artifactory path (Bitbucket and"
  info "git identity are optional). Run './start.sh --doctor' any time to re-check your setup."

  return "$prereq_rc"
}

# Run main only when executed directly, not when sourced (e.g. by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
