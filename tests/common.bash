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
  mkdir -p "$SANDBOX/docker"
  cp "$REPO_ROOT"/docker/docker-compose*.yml "$SANDBOX/docker/" 2>/dev/null || true
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

# make_sandbox_git_repo_behind N — turn $SANDBOX itself into a real git repo
# with an upstream that is N commits ahead (i.e. $SANDBOX's checked-out branch
# is N commits behind). Used by the launcher self-update-check tests, which
# need REAL git (not the fake docker stub) — see lib/update.sh. N=0 leaves
# the two in sync. Requires $SANDBOX to already exist (call after
# make_sandbox); uses $BATS_TEST_TMPDIR/git-origin as the bare "upstream".
make_sandbox_git_repo_behind() {
  local n="${1:-1}" origin push_clone i
  origin="$BATS_TEST_TMPDIR/git-origin"
  git init -q --bare "$origin"

  ( cd "$SANDBOX" \
      && git init -q -b main \
      && git config user.email test@example.com \
      && git config user.name "Test" \
      && git add -A \
      && git commit -q -m "initial" \
      && git remote add origin "$origin" \
      && git push -q origin main \
      && git branch -q --set-upstream-to=origin/main main )
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  if [ "$n" -gt 0 ]; then
    push_clone="$BATS_TEST_TMPDIR/git-push-clone"
    git clone -q "$origin" "$push_clone"
    ( cd "$push_clone" \
        && git config user.email test@example.com \
        && git config user.name "Test" )
    for ((i = 0; i < n; i++)); do
      ( cd "$push_clone" && echo "change $i" >> upstream-only.txt && git add -A && git commit -q -m "upstream change $i" )
    done
    ( cd "$push_clone" && git push -q origin main )
  fi
}
