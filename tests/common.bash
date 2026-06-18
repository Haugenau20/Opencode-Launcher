# Shared helpers for the start.sh bats suite.
#
# Two test styles use these:
#   * unit  — `source` start.sh and call a pure helper directly.
#   * cli   — run a sandboxed COPY of start.sh as a subprocess, with a fake
#             `docker` on PATH, and assert on its output / side effects.

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
FAKE_BIN="$COMMON_DIR/fake-bin"

# make_sandbox — copy the launcher into an isolated temp dir so .env / .envs
# writes never touch the real repo, and put the fake docker first on PATH.
# Sets $SANDBOX and exports $FAKE_DOCKER_LOG (truncated).
make_sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/launcher"
  mkdir -p "$SANDBOX"
  cp "$REPO_ROOT/start.sh" "$SANDBOX/"
  cp -r "$REPO_ROOT/lib" "$SANDBOX/"
  cp "$REPO_ROOT/.env.example" "$SANDBOX/"
  cp "$REPO_ROOT"/docker-compose*.yml "$SANDBOX/" 2>/dev/null || true
  cp -r "$REPO_ROOT/extra-allowlist.d" "$SANDBOX/" 2>/dev/null || true

  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$FAKE_DOCKER_LOG"
  export FAKE_XDG_OPEN_LOG="$BATS_TEST_TMPDIR/xdg-open.log"
  : > "$FAKE_XDG_OPEN_LOG"
  export PATH="$FAKE_BIN:$PATH"
}

# seed_env — pre-create $SANDBOX/.env (skips the first-run prompt path) with a
# non-placeholder registry so the placeholder warning stays quiet.
seed_env() {
  cp "$SANDBOX/.env.example" "$SANDBOX/.env"
  sed -i 's|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=reg.test.local/opencode|' "$SANDBOX/.env"
}

# make_repo_arg [name] — create a throwaway dir to pass as <host-repo-path>
# and echo its path.
make_repo_arg() {
  local name="${1:-myrepo}"
  local d="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$d"
  printf '%s' "$d"
}

# run_launcher [args...] — run the sandboxed start.sh as a subprocess.
run_launcher() {
  run bash "$SANDBOX/start.sh" "$@"
}

# docker_log — print the recorded fake-docker call log.
docker_log() { cat "$FAKE_DOCKER_LOG"; }
