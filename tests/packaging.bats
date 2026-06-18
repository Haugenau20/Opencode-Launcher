#!/usr/bin/env bats
#
# Packaging/onboarding deliverables: shell completions and install.sh.
# These don't touch start.sh's runtime behavior — they're smoke tests that the
# new files are syntactically valid, mention the right flags, and that
# install.sh is safe/idempotent.

setup() {
  load common
}

# --- completions: bash -------------------------------------------------------

@test "bash completion script: passes bash -n" {
  run bash -n "$REPO_ROOT/completions/opencode-launcher.bash"
  [ "$status" -eq 0 ]
}

@test "bash completion script: sources cleanly and registers a completion function" {
  run bash -c "source '$REPO_ROOT/completions/opencode-launcher.bash' && complete -p start.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_opencode_launcher_complete"* ]]
}

@test "bash completion script: mentions the management/convenience flags" {
  run cat "$REPO_ROOT/completions/opencode-launcher.bash"
  [ "$status" -eq 0 ]
  for flag in --doctor --show-allowlist --logs --shell --status --down --stop \
              --reconfigure --continue --persist --detach --podman --open --help; do
    [[ "$output" == *"$flag"* ]]
  done
}

# --- completions: zsh --------------------------------------------------------

@test "zsh completion script: passes zsh -n (skipped if zsh is unavailable)" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh not installed"
  fi
  run zsh -n "$REPO_ROOT/completions/opencode-launcher.zsh"
  [ "$status" -eq 0 ]
}

@test "zsh completion script: sources cleanly outside the completion system (skipped if zsh is unavailable)" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh not installed"
  fi
  # Sourced standalone (no compinit/_arguments available), this must be a
  # no-op rather than erroring — real completion only fires through zsh's
  # own completion widget, which a plain `source` does not invoke.
  run zsh -c "source '$REPO_ROOT/completions/opencode-launcher.zsh'"
  [ "$status" -eq 0 ]
}

@test "zsh completion script: mentions the management/convenience flags" {
  run cat "$REPO_ROOT/completions/opencode-launcher.zsh"
  [ "$status" -eq 0 ]
  for flag in --doctor --show-allowlist --logs --shell --status --down --stop \
              --reconfigure --continue --persist --detach --podman --open --help; do
    [[ "$output" == *"$flag"* ]]
  done
}

@test "completions/README.md documents install steps for both shells" {
  run cat "$REPO_ROOT/completions/README.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode-launcher.bash"* ]]
  [[ "$output" == *"opencode-launcher.zsh"* ]]
}

# --- install.sh: syntax -------------------------------------------------------

@test "install.sh: passes bash -n" {
  run bash -n "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "install.sh: is executable" {
  [ -x "$REPO_ROOT/install.sh" ]
}

# --- install.sh: behavior -----------------------------------------------------
#
# Drive a copy of install.sh in a temp dir with the fake `docker` stub on
# PATH (same stub the rest of the suite uses) so the prerequisite checks pass
# without a real Docker daemon. install.sh detects "already a checkout" by
# the presence of start.sh next to it, so most scenarios below copy start.sh
# alongside it, exactly like a real clone would have.

# install_sandbox — copy install.sh (+ start.sh, to look like a real checkout)
# into an isolated temp dir and put the fake docker first on PATH.
install_sandbox() {
  INSTALL_SANDBOX="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$INSTALL_SANDBOX"
  cp "$REPO_ROOT/install.sh" "$INSTALL_SANDBOX/"
  cp "$REPO_ROOT/start.sh" "$INSTALL_SANDBOX/"
  export PATH="$FAKE_BIN:$PATH"
}

@test "install.sh: running from an existing checkout never clones" {
  install_sandbox
  run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running from an existing checkout"* ]]
  [[ "$output" != *"cloning"* ]]
}

@test "install.sh: prints the cd-and-start next-step command" {
  install_sandbox
  run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd $INSTALL_SANDBOX && ./start.sh <your-repo-path>"* ]]
}

@test "install.sh: reports prerequisite checks (docker, daemon, compose v2)" {
  install_sandbox
  run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker found on PATH"* ]]
  [[ "$output" == *"docker daemon is reachable"* ]]
  [[ "$output" == *"docker compose v2 plugin is available"* ]]
}

@test "install.sh: warns and exits non-zero when the docker daemon is unreachable" {
  install_sandbox
  FAKE_DOCKER_INFO_RC=1 run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot talk to the Docker daemon"* ]]
}

@test "install.sh: permission-denied daemon failure surfaces the usermod hint" {
  install_sandbox
  FAKE_DOCKER_INFO_RC=1 FAKE_DOCKER_INFO_STDERR="permission denied" \
    run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usermod -aG docker"* ]]
}

@test "install.sh: does NOT overwrite an existing .env" {
  install_sandbox
  printf 'LLM_API_KEY=super-secret-do-not-touch\n' > "$INSTALL_SANDBOX/.env"
  local before; before="$(md5sum "$INSTALL_SANDBOX/.env" | awk '{print $1}')"

  run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists — leaving it untouched"* ]]

  local after; after="$(md5sum "$INSTALL_SANDBOX/.env" | awk '{print $1}')"
  [ "$before" = "$after" ]
  run cat "$INSTALL_SANDBOX/.env"
  [[ "$output" == *"super-secret-do-not-touch"* ]]
}

@test "install.sh: is idempotent (running twice produces identical output)" {
  install_sandbox
  run bash "$INSTALL_SANDBOX/install.sh"
  local first="$output"
  run bash "$INSTALL_SANDBOX/install.sh"
  local second="$output"
  [ "$first" = "$second" ]
}

@test "install.sh: never deletes or modifies start.sh in an existing checkout" {
  install_sandbox
  local before; before="$(md5sum "$INSTALL_SANDBOX/start.sh" | awk '{print $1}')"
  run bash "$INSTALL_SANDBOX/install.sh"
  [ "$status" -eq 0 ]
  local after; after="$(md5sum "$INSTALL_SANDBOX/start.sh" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "install.sh: refuses to clone with the placeholder LAUNCHER_GIT_URL still set" {
  # Run standalone (no start.sh alongside) so it takes the clone path, into a
  # fresh INSTALL_DIR that doesn't exist yet.
  local standalone="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/install.sh" "$standalone/"
  export PATH="$FAKE_BIN:$PATH"

  run env INSTALL_DIR="$BATS_TEST_TMPDIR/work/opencode-launcher" \
    bash "$standalone/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/work/opencode-launcher" ]
}

@test "install.sh: leaves a pre-existing non-launcher INSTALL_DIR untouched" {
  local standalone="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/install.sh" "$standalone/"
  export PATH="$FAKE_BIN:$PATH"

  local target="$BATS_TEST_TMPDIR/work/opencode-launcher"
  mkdir -p "$target"
  echo "unrelated" > "$target/foo.txt"

  run env INSTALL_DIR="$target" LAUNCHER_GIT_URL="https://example.invalid/fake.git" \
    bash "$standalone/install.sh"
  [[ "$output" == *"doesn't look like an opencode-launcher checkout"* ]]
  [ -f "$target/foo.txt" ]
  [ ! -e "$target/start.sh" ]
}
