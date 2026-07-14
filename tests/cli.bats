#!/usr/bin/env bats
#
# Black-box tests: run a sandboxed copy of start.sh as a subprocess with a fake
# `docker` on PATH, and assert on its exit status, messages and side effects
# (the generated .env / per-project env, and the recorded docker calls).

setup() {
  load common
  make_sandbox
}

# --- argument parsing -------------------------------------------------------

@test "--help prints usage and exits 0" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--detach"* ]]
  [[ "$output" == *"--persist"* ]]
}

@test "missing repo path fails with a clear error" {
  run_launcher
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

@test "unknown option is rejected" {
  run_launcher --bogus "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "a second positional argument is rejected" {
  local repo; repo="$(make_repo_arg)"
  run_launcher "$repo" extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected extra argument: extra"* ]]
}

@test "nonexistent repo path is rejected" {
  run_launcher "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

@test "a file (not a directory) repo path is rejected" {
  local f="$BATS_TEST_TMPDIR/afile"
  : > "$f"
  run_launcher "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory"* ]]
}

# --- preflight: docker daemon -----------------------------------------------

@test "docker daemon unreachable fails with 'Is it running?'" {
  seed_env
  FAKE_DOCKER_INFO_RC=1 run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot talk to the Docker daemon. Is it running?"* ]]
}

@test "docker permission denied surfaces the usermod hint" {
  seed_env
  FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_STDERR="Got permission denied while trying to connect" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"permission denied"* ]]
  [[ "$output" == *"usermod -aG docker"* ]]
}

# --- Artifactory access -----------------------------------------------------

@test "manifest auth failure tells the user to docker login" {
  seed_env
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="unauthorized: authentication required" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth problem"* ]]
  [[ "$output" == *"docker login reg.test.local"* ]]
}

@test "a non-auth manifest error warns but continues to boot" {
  seed_env
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="manifest unknown: not found" \
    run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify"* ]]
  grep -q 'compose .* up -d' "$FAKE_DOCKER_LOG"
}

# --- happy-path boot & per-project derivation -------------------------------

@test "boots: derives slug, generates per-project env, pulls and starts" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher "$repo"
  [ "$status" -eq 0 ]

  # per-project env file named by slug, superset of .env + generated keys
  local penv="$SANDBOX/.envs/my-service.env"
  [ -f "$penv" ]
  grep -q '^PROJECT_SLUG=my-service$' "$penv"
  grep -q "^REPO_PATH=${repo}$" "$penv"
  grep -q '^OPENCODE_PORT=' "$penv"
  grep -q '^IMAGE_REGISTRY=reg.test.local/opencode$' "$penv"   # inherited from .env

  # compose was invoked with the right project name and pull + up
  grep -q 'compose .*-p opencode-my-service .*pull' "$FAKE_DOCKER_LOG"
  grep -q 'compose .*-p opencode-my-service .*up -d' "$FAKE_DOCKER_LOG"
}

@test "default boot uses the base compose file" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.yml' "$FAKE_DOCKER_LOG"
}

# --- TUI-default frontend ---------------------------------------------------

@test "default boot attaches the TUI rooted at /workspace" {
  seed_env
  run_launcher "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  # the stack still comes up first (keepalive), then the TUI attaches
  grep -q 'compose .*up -d' "$FAKE_DOCKER_LOG"
  grep -qE 'exec .*-w /workspace .*-it opencode-my-service opencode' "$FAKE_DOCKER_LOG"
}

@test "default boot prints the web-UI note with the workaround" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  # Anchor on the stable upstream issue number and the one-step workaround, not a
  # version string (user-facing prose no longer names the exact OpenCode version).
  [[ "$output" == *"New session"* ]]
  [[ "$output" == *"/workspace"* ]]
  [[ "$output" == *"14445"* ]]
}

@test "--detach boots the stack but does NOT attach the TUI" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'compose .*up -d' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"detached: stack is running"* ]]
}

@test "--no-tui is an alias for --detach" {
  seed_env
  run_launcher --no-tui "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--tui is accepted as a back-compat no-op (still attaches)" {
  seed_env
  run_launcher --tui "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-w /workspace .*-it ' "$FAKE_DOCKER_LOG"
}

@test "default boot tears the stack down after the TUI exits" {
  seed_env
  run_launcher "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  # attaches, then runs `compose ... down` for this project once the TUI exits
  grep -qE 'exec .*-it opencode-my-service opencode' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*-p opencode-my-service .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"tearing down"* ]]
}

@test "--persist attaches the TUI but keeps the stack running (no teardown)" {
  seed_env
  run_launcher --persist "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-w /workspace .*-it ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"the stack keeps running"* ]]
}

@test "--web is an alias for --persist (no teardown)" {
  seed_env
  run_launcher --web "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-it ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--detach keeps the stack running (no teardown, no attach)" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

# --- podman overlay ---------------------------------------------------------

@test "default boot does NOT add the podman overlay" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.podman.yml' "$FAKE_DOCKER_LOG"
}

@test "--podman adds the podman overlay" {
  seed_env
  run_launcher --podman "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.podman.yml' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"podman:"* ]]
}

@test "--continue passes -c to the attached TUI" {
  seed_env
  run_launcher --continue "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  grep -qE 'exec .*-it opencode-my-service opencode -c$' "$FAKE_DOCKER_LOG"
}

@test "-c is an alias for --continue" {
  seed_env
  run_launcher -c "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'opencode -c$' "$FAKE_DOCKER_LOG"
}

@test "default boot does NOT pass -c (fresh session)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'opencode -c' "$FAKE_DOCKER_LOG"
}

@test "--continue works together with --persist" {
  seed_env
  run_launcher --continue --persist "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'opencode -c$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--continue with --detach warns and attaches nothing" {
  seed_env
  run_launcher --continue --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no effect with --detach"* ]]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--prod is gone: it is rejected as an unknown option" {
  seed_env
  run_launcher --prod "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --prod"* ]]
}

@test "IMAGE_TAG drives the access-check image (defaults to latest)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect reg.test.local/opencode:latest' "$FAKE_DOCKER_LOG"
}

@test "a pinned IMAGE_TAG is used for the access-check image" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect reg.test.local/opencode:0.0.2' "$FAKE_DOCKER_LOG"
}

@test "an IMAGE_TAG pinned to a digest produces a valid @sha256 reference" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'manifest inspect reg.test.local/opencode@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' "$FAKE_DOCKER_LOG"
  ! grep -q ':@sha256:' "$FAKE_DOCKER_LOG"   # never the invalid registry:@sha256 form
}

@test "USER_LAYER_PATH adds the user-layer overlay and records the abs path" {
  seed_env
  # .env already carries an empty USER_LAYER_PATH= line; set that one (get_env
  # reads the first match), don't append a duplicate.
  sed -i 's|^USER_LAYER_PATH=.*|USER_LAYER_PATH=./user-layer|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"user layer:"* ]]
  grep -q 'docker-compose.user-layer.yml' "$FAKE_DOCKER_LOG"
  grep -q "^USER_LAYER_PATH=${SANDBOX}/user-layer$" "$SANDBOX/.envs/myrepo.env"
}

# --- system-package layer ---------------------------------------------------

@test "absent extra-packages.txt: no overlay, plain pull, no OC_BASE_IMAGE" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  ! grep -q 'build opencode' "$FAKE_DOCKER_LOG"
  ! grep -q '^OC_BASE_IMAGE=' "$SANDBOX/.envs/myrepo.env"
  # plain blanket pull (no per-service split) preserves current behavior
  grep -qE 'compose .*pull$' "$FAKE_DOCKER_LOG"
}

@test "comment/blank-only extra-packages.txt is treated as inactive" {
  seed_env
  printf '%s\n' '# just a comment' '' '   ' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  ! grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  ! grep -q '^OC_BASE_IMAGE=' "$SANDBOX/.envs/myrepo.env"
}

@test "non-empty extra-packages.txt: builds a local opencode layer" {
  seed_env
  # pin a distinct tag so the base image is unambiguous in the assertion below
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=local|' "$SANDBOX/.env"
  printf '%s\n' '# tools' 'cmake' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]

  # overlay added; base image handed to the build via the per-project env file
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  grep -q '^OC_BASE_IMAGE=reg.test.local/opencode:local$' "$SANDBOX/.envs/myrepo.env"

  # registry services pulled by name, then opencode is built (not pulled)
  grep -qE 'compose .*pull squid oc-publish' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*build opencode' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*up -d' "$FAKE_DOCKER_LOG"

  # an info line announces the active layer and the package
  [[ "$output" == *"system packages:"* ]]
  [[ "$output" == *"cmake"* ]]
}

@test "pinned IMAGE_TAG + packages: base image carries the pinned tag" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  printf '%s\n' 'cmake' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^OC_BASE_IMAGE=reg.test.local/opencode:0.0.2$' "$SANDBOX/.envs/myrepo.env"
  # the package overlay is applied last so it wins (overrides opencode's build:)
  grep -qE 'docker-compose.yml .*docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
}

@test "pip:-only extra-packages.txt activates the build layer" {
  seed_env
  printf '%s\n' '# python deps' 'pip:requests' > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  # a pip-only file is still "active": the local layer is built
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*build opencode' "$FAKE_DOCKER_LOG"
  # the pip list is reported, and no spurious apt line appears
  [[ "$output" == *"pip: requests"* ]]
  [[ "$output" != *"apt: "* ]]
}

@test "mixed apt/pip extra-packages.txt is split into the right buckets" {
  seed_env
  printf '%s\n' 'cmake' 'apt:ripgrep' 'pip:requests' 'pip:httpx==0.27.0' \
    > "$SANDBOX/extra-packages.txt"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q 'docker-compose.user-packages.yml' "$FAKE_DOCKER_LOG"
  # apt bucket: bare name + apt:-prefixed name (prefix stripped), no pip entries
  [[ "$output" == *"apt: cmake ripgrep"* ]]
  # pip bucket: pip:-prefixed specs (prefix stripped), version specifier kept
  [[ "$output" == *"pip: requests httpx==0.27.0"* ]]
}

# --- opt-in plugins (ENABLED_PLUGINS) ---------------------------------------

@test "ENABLED_PLUGINS with a space survives into the per-project env file" {
  seed_env
  # A space-separated list is the documented form; the value must reach the
  # opencode container unmangled. start.sh cats .env verbatim into the
  # per-project env, and the compose opencode service injects .env via env_file,
  # so a value preserved here is the value the container sees.
  sed -i 's|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=superpowers dcp|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=superpowers dcp$' "$SANDBOX/.envs/myrepo.env"
}

@test "an empty ENABLED_PLUGINS stays empty (no plugins enabled by default)" {
  seed_env
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=$' "$SANDBOX/.envs/myrepo.env"
}

# --- opencode-pty viewer URL -------------------------------------------------
# The viewer (a second oc-publish socat leg on 1<port>) is only worth
# reporting when opencode-pty is actually enabled for this project — see
# pty_enabled in lib/project.sh.

@test "boot report prints the opencode-pty viewer URL when the plugin is enabled" {
  seed_env
  sed -i 's|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=superpowers opencode-pty|' "$SANDBOX/.env"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web UI:  http://localhost:4096"* ]]
  [[ "$output" == *"viewer:  http://localhost:14096"* ]]
  [[ "$output" == *"/pty-open-background-spy"* ]]
}

@test "boot report does not print a viewer URL when opencode-pty is not enabled" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web UI:  http://localhost:4096"* ]]
  [[ "$output" != *"viewer:"* ]]
}

@test "--open also opens the opencode-pty viewer URL when the plugin is enabled" {
  seed_env
  sed -i 's|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=opencode-pty|' "$SANDBOX/.env"
  run_launcher --detach --open "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'http://localhost:4096' "$FAKE_XDG_OPEN_LOG"
  grep -qE 'http://localhost:14096' "$FAKE_XDG_OPEN_LOG"
}

@test "--status prints the opencode-pty viewer URL for an up stack when the plugin is enabled" {
  seed_env
  sed -i 's|^ENABLED_PLUGINS=.*|ENABLED_PLUGINS=opencode-pty|' "$SANDBOX/.env"
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web UI:  http://localhost:"* ]]
  [[ "$output" == *"viewer:  http://localhost:1"* ]]
  [[ "$output" == *"/pty-open-background-spy"* ]]
}

@test "--status prints no viewer URL for an up stack when opencode-pty is not enabled" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web UI:  http://localhost:"* ]]
  [[ "$output" != *"viewer:"* ]]
}

# --- first-run secrets flow -------------------------------------------------

@test "first run creates .env from the template and stores fed secrets" {
  [ ! -f "$SANDBOX/.env" ]   # precondition: no .env yet
  local repo; repo="$(make_repo_arg)"

  # 21 prompts in order: LLM base, LLM key, BB base URL, BB user, BB PAT,
  # BB legacy URL, Jira base URL, Jira PAT, GitLab base URL, GitLab user, GitLab
  # PAT, JFrog base URL, JFrog PAT, Confluence base URL, Confluence PAT, M-Files
  # base URL, M-Files PAT, git name, git email, plugins, image registry. Feed a
  # key with sed-special chars to exercise sed_escape and a space-bearing plugin
  # list. Feed via a redirect (not a pipe): `printf | run` would run `run` in a
  # subshell, losing $status.
  printf '%s\n' \
    'https://llm.test/v1' \
    'sk-a&b|c' \
    'http://bb.test' \
    'bobu' \
    'bbpat' \
    'http://bb-old.test' \
    'https://jira.test' \
    'jirapat' \
    'https://gitlab.test' \
    'glu' \
    'glpat' \
    'https://jfrog.test' \
    'jfrogpat' \
    'http://confluence.test:8090' \
    'confpat' \
    'https://mfiles.test' \
    'mfilespat' \
    'Bob Builder' \
    'bob@test.dev' \
    'superpowers dcp' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -q '^LLM_API_BASE=https://llm.test/v1$' "$SANDBOX/.env"
  grep -q '^LLM_API_KEY=sk-a&b|c$' "$SANDBOX/.env"       # sed_escape round-trip
  grep -q '^BITBUCKET_BASE_URL=http://bb.test$' "$SANDBOX/.env"
  grep -q '^BITBUCKET_USER=bobu$' "$SANDBOX/.env"
  grep -q '^BITBUCKET_LEGACY_URL=http://bb-old.test$' "$SANDBOX/.env"
  grep -q '^JIRA_BASE_URL=https://jira.test$' "$SANDBOX/.env"
  grep -q '^JIRA_PAT=jirapat$' "$SANDBOX/.env"
  grep -q '^GITLAB_BASE_URL=https://gitlab.test$' "$SANDBOX/.env"
  grep -q '^GITLAB_USER=glu$' "$SANDBOX/.env"
  grep -q '^GITLAB_PAT=glpat$' "$SANDBOX/.env"
  grep -q '^JFROG_BASE_URL=https://jfrog.test$' "$SANDBOX/.env"
  grep -q '^JFROG_PAT=jfrogpat$' "$SANDBOX/.env"
  grep -q '^CONFLUENCE_BASE_URL=http://confluence.test:8090$' "$SANDBOX/.env"
  grep -q '^CONFLUENCE_PAT=confpat$' "$SANDBOX/.env"
  grep -q '^MFILES_BASE_URL=https://mfiles.test$' "$SANDBOX/.env"
  grep -q '^MFILES_PAT=mfilespat$' "$SANDBOX/.env"
  grep -q '^GIT_USER_NAME=Bob Builder$' "$SANDBOX/.env"
  grep -q '^ENABLED_PLUGINS=superpowers dcp$' "$SANDBOX/.env"  # opt-in, space kept
  grep -q "^HOST_UID=$(id -u)$" "$SANDBOX/.env"          # auto-filled
  grep -q "^HOST_GID=$(id -g)$" "$SANDBOX/.env"
}

@test "first run: no tty still runs the linear wizard even with whiptail on PATH" {
  # make_sandbox already puts tests/fake-bin (a fake whiptail included) first
  # on PATH. This is the critical regression: have_tui requires a real tty,
  # and bats's stdin here is a redirected file, not a tty, so a piped/CI
  # first-run must still hit the linear run_setup_wizard (pinned 21-prompt
  # walk + UID/GID autofill) — the ncurses --first-run path must never
  # hijack it just because a backend happens to be installed.
  [ ! -f "$SANDBOX/.env" ]
  command -v whiptail >/dev/null 2>&1   # sanity: the fake whiptail IS on PATH
  local repo; repo="$(make_repo_arg)"
  printf '%s\n' \
    'https://llm.test/v1' 'sk-key' \
    '' '' '' '' \
    '' '' \
    '' '' '' \
    '' '' '' '' \
    '' '' \
    '' '' \
    '' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -q '^LLM_API_BASE=https://llm.test/v1$' "$SANDBOX/.env"
  grep -q '^LLM_API_KEY=sk-key$' "$SANDBOX/.env"
  grep -q '^IMAGE_REGISTRY=reg.test.local/opencode$' "$SANDBOX/.env"
  grep -q "^HOST_UID=$(id -u)$" "$SANDBOX/.env"          # auto-filled
  grep -q "^HOST_GID=$(id -g)$" "$SANDBOX/.env"
}

@test "first run with no plugins selected leaves ENABLED_PLUGINS empty" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  # Same 21 prompts, but press Enter past the plugins one (empty line).
  printf '%s\n' \
    'https://llm.test/v1' 'sk-key' \
    'http://bb.test' 'bobu' 'bbpat' '' \
    'https://jira.test' 'jirapat' \
    'https://gitlab.test' 'glu' 'glpat' \
    'https://jfrog.test' 'jfrogpat' \
    'http://confluence.test:8090' 'confpat' \
    'https://mfiles.test' 'mfilespat' \
    'Bob Builder' 'bob@test.dev' \
    '' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  grep -q '^ENABLED_PLUGINS=$' "$SANDBOX/.env"
}

@test "first run: skipping the integration prompts leaves them blank" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  # Provide the required LLM base + registry; press Enter past every optional
  # integration prompt (Bitbucket base URL/user/PAT/legacy URL, then Jira/GitLab/
  # JFrog/Confluence/M-Files base URLs, users, PATs).
  printf '%s\n' \
    'https://llm.test/v1' 'sk-key' \
    '' '' '' '' \
    '' '' \
    '' '' '' \
    '' '' '' '' \
    '' '' \
    '' '' \
    '' \
    'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" "$repo" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  # Each optional integration key exists in the template (so set_env can target
  # it) but stays empty when skipped.
  grep -q '^BITBUCKET_BASE_URL=$' "$SANDBOX/.env"
  grep -q '^BITBUCKET_USER=$' "$SANDBOX/.env"
  grep -q '^JIRA_BASE_URL=$' "$SANDBOX/.env"
  grep -q '^JIRA_PAT=$' "$SANDBOX/.env"
  grep -q '^GITLAB_BASE_URL=$' "$SANDBOX/.env"
  grep -q '^GITLAB_USER=$' "$SANDBOX/.env"
  grep -q '^GITLAB_PAT=$' "$SANDBOX/.env"
  # JFrog/Confluence/M-Files base URLs are url-type fields that ship with
  # non-empty example values (like LLM_API_BASE), so Enter keeps the placeholder;
  # the empty PATs are what keep each MCP off (auto-enable needs both set).
  grep -q '^JFROG_PAT=$' "$SANDBOX/.env"
  grep -q '^CONFLUENCE_PAT=$' "$SANDBOX/.env"
  grep -q '^MFILES_PAT=$' "$SANDBOX/.env"
}

@test "placeholder IMAGE_REGISTRY triggers a warning" {
  # Construct a placeholder value explicitly rather than relying on whatever
  # .env.example happens to ship (a real deployment edits that file).
  seed_env
  sed -i 's|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=CHANGEME.artifactory.example/opencode-workplace|' "$SANDBOX/.env"
  run_launcher "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_REGISTRY looks like a placeholder"* ]]
}

# --- --doctor -----------------------------------------------------------------

# seed_env_doctor — seed_env plus a non-empty LLM_API_KEY, so the "all required
# keys set" path is reachable (seed_env alone leaves LLM_API_KEY empty).
seed_env_doctor() {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-test-secret-value|' "$SANDBOX/.env"
}

@test "--doctor short-circuits: no pull, no up, no exec" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenCode Launcher doctor report"* ]]
  ! grep -qE 'compose .*pull' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .*up -d' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--doctor all-good: every check passes and exit is 0" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] docker on PATH"* ]]
  [[ "$output" == *"[PASS] docker daemon reachable"* ]]
  [[ "$output" == *"[PASS] docker compose v2 plugin"* ]]
  [[ "$output" == *"[PASS] .env present"* ]]
  [[ "$output" == *"[PASS] env: LLM_API_BASE"* ]]
  [[ "$output" == *"[PASS] env: LLM_API_KEY"* ]]
  [[ "$output" == *"[PASS] env: IMAGE_REGISTRY"* ]]
  [[ "$output" == *"[PASS] registry access"* ]]
  [[ "$output" == *"[PASS] env: in sync with"* ]]
  [[ "$output" == *"all critical checks passed"* ]]
  ! [[ "$output" == *"[FAIL]"* ]]
}

@test "--doctor: daemon-down FAILs that check and exits non-zero" {
  seed_env_doctor
  FAKE_DOCKER_INFO_RC=1 run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] docker daemon reachable"* ]]
  [[ "$output" == *"one or more critical checks FAILED"* ]]
}

@test "--doctor: permission-denied daemon failure surfaces the usermod hint" {
  seed_env_doctor
  FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_STDERR="Got permission denied while trying to connect" \
    run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] docker daemon reachable"* ]]
  [[ "$output" == *"usermod -aG docker"* ]]
}

@test "--doctor: missing required env key FAILs and exits non-zero" {
  seed_env_doctor
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] env: LLM_API_KEY"* ]]
  [[ "$output" == *"unset — required"* ]]
  [[ "$output" == *"one or more critical checks FAILED"* ]]
}

@test "--doctor: optional unset keys are reported as WARN, not FAIL" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] env: BITBUCKET_USER"* ]]
  [[ "$output" == *"unset (optional)"* ]]
}

@test "--doctor: registry auth failure reports it and gives the docker login hint" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="unauthorized: authentication required" \
    run_launcher --doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] registry access"* ]]
  [[ "$output" == *"auth problem"* ]]
  [[ "$output" == *"docker login reg.test.local"* ]]
}

@test "--doctor: a non-auth registry error WARNs but does not fail the run" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST_RC=1 \
    FAKE_DOCKER_MANIFEST_STDERR="manifest unknown: not found" \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] registry access"* ]]
  [[ "$output" == *"could not verify"* ]]
}

@test "--doctor: image manifest PASSes when every key is known" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST='{"env_keys": [ {"key": "LLM_API_BASE", "required": true}, {"key": "JFROG_BASE_URL", "required": false} ]}' \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] image manifest: launcher knows every key"* ]]
}

@test "--doctor: image manifest WARNs (not FAILs) when the image reads an unknown env key" {
  seed_env_doctor
  FAKE_DOCKER_MANIFEST='{"env_keys": [ {"key": "LLM_API_BASE", "required": true}, {"key": "NEW_KEY_X", "required": false} ]}' \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] image manifest"* ]]
  [[ "$output" == *"NEW_KEY_X"* ]]
  [[ "$output" == *"git pull the launcher"* ]]
  ! [[ "$output" == *"[FAIL] image manifest"* ]]
}

@test "--doctor: image manifest is a neutral skipped WARN on an old/unpulled image" {
  seed_env_doctor
  run_launcher --doctor   # FAKE_DOCKER_MANIFEST unset => empty, mirrors an old image
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] image manifest"* ]]
  [[ "$output" == *"not available"* ]]
  [[ "$output" == *"skipped"* ]]
}

@test "--doctor: podman shim is reported as WARN, not FAIL" {
  seed_env_doctor
  FAKE_DOCKER_VERSION_OUTPUT="Docker version 0.0.0, podman" \
    run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] podman shim detected"* ]]
}

@test "--doctor: no podman shim reports PASS" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] podman shim"* ]]
}

@test "--doctor: an optional repo path is validated and its project reported" {
  seed_env_doctor
  run_launcher --doctor "$(make_repo_arg "My Service")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] project: my-service"* ]]
}

@test "--doctor: a new .env.example key missing from .env WARNs (not FAIL)" {
  seed_env_doctor
  printf 'A_BRAND_NEW_KEY=somedefault\n' >> "$SANDBOX/.env.example"
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] env: new keys in"* ]]
  [[ "$output" == *"A_BRAND_NEW_KEY"* ]]
  [[ "$output" == *"--reconfigure"* ]]
  ! [[ "$output" == *"[FAIL]"* ]]
}

@test "--doctor: env drift never prints a new key's value" {
  seed_env_doctor
  printf 'SECRET_NEW_KEY=do-not-print-this\n' >> "$SANDBOX/.env.example"
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRET_NEW_KEY"* ]]
  [[ "$output" != *"do-not-print-this"* ]]
}

@test "--doctor: WARNs (not FAILs) when IMAGE_TAG is pinned off latest" {
  seed_env_doctor
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] image tag"* ]]
  [[ "$output" == *"pinned to 0.0.2"* ]]
  ! [[ "$output" == *"[FAIL]"* ]]
}

@test "--doctor: PASSes the image tag check when tracking latest" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] image tag"* ]]
}

@test "--doctor: never prints the secret LLM_API_KEY value" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-test-secret-value"* ]]
}

@test "--doctor: never prints a configured BITBUCKET_PAT value" {
  seed_env_doctor
  sed -i 's|^BITBUCKET_PAT=.*|BITBUCKET_PAT=super-secret-token-xyz|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-token-xyz"* ]]
  [[ "$output" == *"[PASS] env: BITBUCKET_PAT"* ]]
}

@test "--doctor exits non-zero overall even when only one of several checks FAILs" {
  seed_env_doctor
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --doctor
  [ "$status" -ne 0 ]
  # the rest of the report still ran (not an early abort)
  [[ "$output" == *"[PASS] docker on PATH"* ]]
  [[ "$output" == *"[PASS] docker compose v2 plugin"* ]]
}

# --- --status -----------------------------------------------------------------

@test "--help mentions --status, --down/--stop and --reconfigure" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--status"* ]]
  [[ "$output" == *"--down"* ]]
  [[ "$output" == *"--stop"* ]]
  [[ "$output" == *"--reconfigure"* ]]
}

@test "--status with a repo path reports a down stack" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode-my-service"* ]]
  [[ "$output" == *"status:  down"* ]]
  # never pulls or attaches
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--status with a repo path reports an up stack with its port and URL" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  # Boot once (--detach: no TUI exec) so the per-project env file (and thus
  # the same SLUG/PORT) exists, which --status reads OPENCODE_PORT from.
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  : > "$FAKE_DOCKER_LOG"   # isolate the log to the --status call below

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode-my-service"* ]]
  [[ "$output" == *"status:  up"* ]]
  [[ "$output" == *"web UI:  http://localhost:"* ]]
  # resume points at the launcher's own --continue flag, not a raw docker exec
  [[ "$output" == *"resume:  ./start.sh --continue $repo"* ]]
  [[ "$output" != *"resume:  docker exec"* ]]
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
  # An up stack DOES now get a non-interactive `docker exec ... jq ...`
  # best-effort MCP-status probe (see mcp_status_line in lib/commands.sh) —
  # but never an interactive (-it) exec, which would mean attaching a TUI.
  ! grep -q -- '-it ' "$FAKE_DOCKER_LOG"
  grep -qE '^exec opencode-my-service jq ' "$FAKE_DOCKER_LOG"
}

@test "--status with no repo path lists all running opencode-* stacks" {
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="$(printf '%s\n%s' \
    'opencode-my-service	running(3)' \
    'opencode-other	exited(0)')" \
    run_launcher --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode-my-service"* ]]
  [[ "$output" == *"opencode-other"* ]]
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--status with no repo path and nothing running says so" {
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no launcher stacks found"* ]]
}

@test "--status queries compose ls with --format json, never a Go template" {
  # Regression: `docker compose ls --format '{{.Name}}…'` is silently rejected
  # by current compose (only table|json are valid), which made --status/--logs
  # report nothing even with a stack up.
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" run_launcher --status
  [ "$status" -eq 0 ]
  grep -qE 'compose ls .*--format json' "$FAKE_DOCKER_LOG"
  ! grep -qF '{{.Name}}' "$FAKE_DOCKER_LOG"
}

@test "--status does not require .env to exist" {
  [ ! -f "$SANDBOX/.env" ]
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/.env" ]   # still never created
}

@test "--status rejects a nonexistent repo path" {
  run_launcher --status "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

# --- --down / --stop -----------------------------------------------------------

@test "--down re-derives the project and invokes compose down with the right -p" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  # Boot first so the per-project env file (and thus the same SLUG/PORT) exists.
  run_launcher "$repo"
  [ "$status" -eq 0 ]

  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'compose .*-p opencode-my-service .*down' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"opencode-my-service is down"* ]]
}

@test "--stop is an alias for --down" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --stop "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--down is graceful when nothing was ever started (no .env)" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing has ever been started"* ]]
  ! grep -q 'compose' "$FAKE_DOCKER_LOG"
}

@test "--down surfaces a warning (not a hard failure) when compose down errors" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_RC=1 run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"may not have been running"* ]]
}

@test "--down requires a repo path" {
  seed_env
  run_launcher --down
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

@test "--down rejects a nonexistent repo path" {
  seed_env
  run_launcher --down "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

@test "--down does not pull images or attach the TUI" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  : > "$FAKE_DOCKER_LOG"   # isolate the log to the --down call below
  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  ! grep -q 'pull' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

# --- --reconfigure ---------------------------------------------------------

@test "--reconfigure round-trips an edited value and keeps untouched ones" {
  seed_env
  # Pre-seed a few values so we can verify both "change" and "keep" behavior.
  sed -i 's|^GIT_USER_NAME=.*|GIT_USER_NAME=Old Name|' "$SANDBOX/.env"
  sed -i 's|^GIT_USER_EMAIL=.*|GIT_USER_EMAIL=old@test.dev|' "$SANDBOX/.env"
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://old.example/v1|' "$SANDBOX/.env"
  sed -i 's|^BITBUCKET_USER=.*|BITBUCKET_USER=olduser|' "$SANDBOX/.env"

  # 21 prompts in order: LLM base (keep), LLM key (keep/empty), BB base (keep),
  # BB user (keep), BB PAT (keep/empty), BB legacy URL (keep), Jira base (keep),
  # Jira PAT (keep), GitLab base (keep), GitLab user (keep), GitLab PAT (keep),
  # JFrog base (keep), JFrog PAT (keep), Confluence base (keep),
  # Confluence PAT (keep), M-Files base (keep), M-Files PAT (keep),
  # git name (CHANGE), git email (keep), plugins (keep), registry (keep).
  printf '%s\n' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    '' \
    'New Name' \
    '' \
    '' \
    '' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  grep -q '^GIT_USER_NAME=New Name$' "$SANDBOX/.env"        # changed
  grep -q '^GIT_USER_EMAIL=old@test.dev$' "$SANDBOX/.env"   # kept
  grep -q '^LLM_API_BASE=https://old.example/v1$' "$SANDBOX/.env"  # kept
  grep -q '^BITBUCKET_USER=olduser$' "$SANDBOX/.env"        # kept
}

@test "--reconfigure does not clobber HOST_UID/HOST_GID" {
  seed_env
  sed -i 's|^HOST_UID=.*|HOST_UID=42|' "$SANDBOX/.env"
  sed -i 's|^HOST_GID=.*|HOST_GID=43|' "$SANDBOX/.env"

  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  grep -q '^HOST_UID=42$' "$SANDBOX/.env"
  grep -q '^HOST_GID=43$' "$SANDBOX/.env"
}

@test "--reconfigure preserves unrelated keys it doesn't own" {
  seed_env
  sed -i 's|^ALLOW_REMOTE_GIT=.*|ALLOW_REMOTE_GIT=1|' "$SANDBOX/.env"
  sed -i 's|^DISABLE_JIRA_MCP=.*|DISABLE_JIRA_MCP=1|' "$SANDBOX/.env"

  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  grep -q '^ALLOW_REMOTE_GIT=1$' "$SANDBOX/.env"
  grep -q '^DISABLE_JIRA_MCP=1$' "$SANDBOX/.env"
}

@test "--reconfigure masks existing secrets instead of echoing them" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=super-secret-value|' "$SANDBOX/.env"

  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-value"* ]]
  [[ "$output" == *"set, press Enter to keep"* ]]
  grep -q '^LLM_API_KEY=super-secret-value$' "$SANDBOX/.env"   # kept (Enter)
}

@test "--reconfigure creates .env from the template when none exists yet" {
  [ ! -f "$SANDBOX/.env" ]
  printf '%s\n' \
    'https://llm.test/v1' 'sk-newkey' \
    'http://bb.test' 'newuser' 'newpat' 'http://bb-old.test' \
    'https://jira.test' 'jirapat' \
    'https://gitlab.test' 'glu' 'glpat' \
    'https://jfrog.test' 'jfrogpat' \
    'http://confluence.test:8090' 'confpat' \
    'https://mfiles.test' 'mfilespat' \
    'New Person' 'new@test.dev' 'superpowers' 'reg.test.local/opencode' \
    > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"

  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -q '^LLM_API_KEY=sk-newkey$' "$SANDBOX/.env"
  grep -q '^GIT_USER_NAME=New Person$' "$SANDBOX/.env"
  grep -q '^JIRA_BASE_URL=https://jira.test$' "$SANDBOX/.env"
  grep -q '^GITLAB_PAT=glpat$' "$SANDBOX/.env"
  grep -q '^MFILES_PAT=mfilespat$' "$SANDBOX/.env"
}

@test "--reconfigure rejects a repo-path argument" {
  seed_env
  run_launcher --reconfigure "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--reconfigure takes no"* ]]
}

@test "--reconfigure notes that changes apply on the next run" {
  seed_env
  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"next"* ]]
}

@test "--reconfigure never pulls images or attaches the TUI" {
  seed_env
  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_DOCKER_LOG" ]   # docker is never even invoked
}

@test "--reconfigure: piped input still runs the linear walk even with whiptail on PATH" {
  # make_sandbox already puts tests/fake-bin (which includes a fake whiptail)
  # first on PATH. This proves the ncurses editor (Layer 2) never hijacks a
  # piped/CI --reconfigure run: have_tui requires a real tty, and bats's
  # stdin here is a redirected file, not a tty, so the linear wizard (pinned
  # intro line + per-field round-trip) must still run, exactly as it did
  # before whiptail existed on PATH.
  seed_env
  command -v whiptail >/dev/null 2>&1   # sanity: the fake whiptail IS on PATH
  sed -i 's|^GIT_USER_NAME=.*|GIT_USER_NAME=Old Name|' "$SANDBOX/.env"
  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' 'New Name' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconfigure: press Enter on any prompt to keep the current value."* ]]
  grep -q '^GIT_USER_NAME=New Name$' "$SANDBOX/.env"
}

@test "--reconfigure: OC_CONFIG_TUI=0 escape hatch still works from a piped run" {
  seed_env
  printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' '' > "$BATS_TEST_TMPDIR/answers"
  OC_CONFIG_TUI=0 run bash "$SANDBOX/start.sh" --reconfigure < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconfigure: press Enter on any prompt to keep the current value."* ]]
}

# --- --config ----------------------------------------------------------

@test "--help mentions --config" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--config"* ]]
}

@test "--config never pulls, attaches, or requires docker/an LLM key" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --config
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_DOCKER_LOG" ]   # docker is never even invoked
}

@test "--config works with no docker available on PATH" {
  seed_env
  PATH="$(dirname "$(command -v bash)")" run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuration"* ]]
}

@test "--config masks secrets: never prints the value, shows the mask and [set]" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-super-secret-value|' "$SANDBOX/.env"
  sed -i 's|^BITBUCKET_PAT=.*|BITBUCKET_PAT=bb-super-secret-pat|' "$SANDBOX/.env"
  run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-super-secret-value"* ]]
  [[ "$output" != *"bb-super-secret-pat"* ]]
  [[ "$output" == *"LLM_API_KEY"*"(secret, set)"* ]]
  [[ "$output" == *"[set]"* ]]
}

@test "--config shows plain url/text values in cleartext" {
  seed_env
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://llm.internal.example/v1|' "$SANDBOX/.env"
  sed -i 's|^GIT_USER_NAME=.*|GIT_USER_NAME=Jane Dev|' "$SANDBOX/.env"
  run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://llm.internal.example/v1"* ]]
  [[ "$output" == *"Jane Dev"* ]]
}

@test "--config marks unset keys as unset" {
  seed_env
  sed -i 's|^BITBUCKET_BASE_URL=.*|BITBUCKET_BASE_URL=|' "$SANDBOX/.env"
  sed -i 's|^JIRA_PAT=.*|JIRA_PAT=|' "$SANDBOX/.env"
  run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" == *"BITBUCKET_BASE_URL"*"(unset)"* ]]
  [[ "$output" == *"JIRA_PAT"*"(unset)"* ]]
  [[ "$output" == *"[ -- ]"* ]]
}

@test "--config handles a missing .env gracefully without creating one" {
  [ ! -f "$SANDBOX/.env" ]
  run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -f "$SANDBOX/.env" ]
}

@test "--config groups keys by section" {
  seed_env
  run_launcher --config
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM"* ]]
  [[ "$output" == *"Bitbucket"* ]]
  [[ "$output" == *"Safety"* ]]
}

@test "--config rejects a repo-path argument" {
  seed_env
  run_launcher --config "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--config takes no"* ]]
}

# --- --show-allowlist -----------------------------------------------------

@test "--help mentions --show-allowlist" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--show-allowlist"* ]]
}

@test "--show-allowlist reports the configured LLM host and squid-image disclaimer" {
  seed_env
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://llm.test/v1|' "$SANDBOX/.env"
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM endpoint host: llm.test"* ]]
  [[ "$output" == *"enforced"* ]]
  [[ "$output" == *"squid image"* ]]
  [[ "$output" == *"local extensions"* ]]
  [[ "$output" == *"none"* ]]
}

@test "--show-allowlist works with no repo path" {
  seed_env
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenCode Launcher egress allowlist"* ]]
}

@test "--show-allowlist accepts an optional repo path" {
  seed_env
  run_launcher --show-allowlist "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenCode Launcher egress allowlist"* ]]
}

@test "--show-allowlist lists files and rules from extra-allowlist.d/*.conf" {
  seed_env
  mkdir -p "$SANDBOX/extra-allowlist.d"
  printf '%s\n' '# allow internal docs' \
    'acl allowed_sites dstdomain .docs.internal.example' \
    'http_access allow allowed_sites' \
    > "$SANDBOX/extra-allowlist.d/extra.conf"
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"extra.conf"* ]]
  [[ "$output" == *"docs.internal.example"* ]]
  [[ "$output" != *"# allow internal docs"* ]]   # comment line is stripped
}

@test "--show-allowlist never pulls, attaches, or requires an LLM key" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
  [ ! -s "$FAKE_DOCKER_LOG" ]   # docker is never even invoked
}

@test "--show-allowlist never prints a configured secret value" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-super-secret-value|' "$SANDBOX/.env"
  sed -i 's|^BITBUCKET_PAT=.*|BITBUCKET_PAT=bb-super-secret-pat|' "$SANDBOX/.env"
  sed -i 's|^BITBUCKET_USER=.*|BITBUCKET_USER=bobu|' "$SANDBOX/.env"
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-super-secret-value"* ]]
  [[ "$output" != *"bb-super-secret-pat"* ]]
  [[ "$output" == *"Bitbucket: credentials configured"* ]]
}

@test "--show-allowlist reports Jira and GitLab when configured, never their secrets" {
  seed_env
  sed -i 's|^JIRA_BASE_URL=.*|JIRA_BASE_URL=https://jira.test|' "$SANDBOX/.env"
  sed -i 's|^JIRA_PAT=.*|JIRA_PAT=jira-super-secret-pat|' "$SANDBOX/.env"
  sed -i 's|^GITLAB_BASE_URL=.*|GITLAB_BASE_URL=https://gitlab.test|' "$SANDBOX/.env"
  sed -i 's|^GITLAB_USER=.*|GITLAB_USER=glu|' "$SANDBOX/.env"
  sed -i 's|^GITLAB_PAT=.*|GITLAB_PAT=gl-super-secret-pat|' "$SANDBOX/.env"
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jira: credentials configured"* ]]
  [[ "$output" == *"GitLab: credentials configured"* ]]
  [[ "$output" != *"jira-super-secret-pat"* ]]
  [[ "$output" != *"gl-super-secret-pat"* ]]
}

@test "--show-allowlist reports Jira and GitLab as not configured when absent" {
  seed_env
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jira: not configured"* ]]
  [[ "$output" == *"GitLab: not configured"* ]]
}

@test "--show-allowlist handles a missing .env gracefully" {
  [ ! -f "$SANDBOX/.env" ]
  run_launcher --show-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [[ "$output" == *"local extensions"* ]]
}

@test "default boot prints a concise one-line allowlist summary, never a secret" {
  seed_env
  sed -i 's|^LLM_API_BASE=.*|LLM_API_BASE=https://llm.test/v1|' "$SANDBOX/.env"
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-super-secret-value|' "$SANDBOX/.env"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"egress allowlist: LLM(llm.test)"* ]]
  [[ "$output" == *"--show-allowlist"* ]]
  [[ "$output" != *"sk-super-secret-value"* ]]
}

# --- --mfiles-token -------------------------------------------------------------
# make_sandbox puts tests/fake-bin (which includes a fake curl — see its header)
# first on PATH, so these never touch a real M-Files instance.

@test "--help mentions --mfiles-token" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--mfiles-token"* ]]
}

@test "--mfiles-token rejects a repo-path argument" {
  seed_env
  run_launcher --mfiles-token "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--mfiles-token takes no"* ]]
}

@test "--mfiles-token mints a token and writes it straight into .env — no copy-paste" {
  seed_env
  FAKE_CURL_MINT_OUTPUT='{"Value":"minted-tok-42"}' \
    run bash -c '
      printf "https://mfiles.test\nbob\n1\n{GUID-1}\nsecretpw\n" |
        bash "'"$SANDBOX"'/start.sh" --mfiles-token
    '
  [ "$status" -eq 0 ]
  [[ "$output" != *"minted-tok-42"* ]]   # never echoed to the terminal
  [[ "$output" == *"wrote MFILES_BASE_URL/MFILES_PAT"* ]]
  grep -q '^MFILES_BASE_URL=https://mfiles.test$' "$SANDBOX/.env"
  grep -q '^MFILES_PAT=minted-tok-42$' "$SANDBOX/.env"
}

@test "--mfiles-token creates .env from the template when none exists yet" {
  [ ! -f "$SANDBOX/.env" ]
  FAKE_CURL_MINT_OUTPUT='{"Value":"tok-from-scratch"}' \
    run bash -c '
      printf "https://mfiles.test\nbob\n1\n{GUID-1}\nsecretpw\n" |
        bash "'"$SANDBOX"'/start.sh" --mfiles-token
    '
  [ "$status" -eq 0 ]
  grep -q '^MFILES_PAT=tok-from-scratch$' "$SANDBOX/.env"
}

@test "--mfiles-token dies with a clear message when the vault rejects the credentials" {
  seed_env
  FAKE_CURL_MINT_RC=1 FAKE_CURL_MINT_OUTPUT='unauthorized' \
    run bash -c '
      printf "https://mfiles.test\nbob\n1\n{GUID-1}\nwrongpw\n" |
        bash "'"$SANDBOX"'/start.sh" --mfiles-token
    '
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not mint an M-Files token"* ]]
  grep -q '^MFILES_PAT=$' "$SANDBOX/.env"
}

@test "--mfiles-token: a failed verification never writes a bogus token to .env by default" {
  # Regression test: minting can succeed (the vault issues a session token)
  # while the credentials are still wrong for the resource actually checked,
  # surfacing only as a failed verify (e.g. a 403 on objecttypes). That must
  # not land an unverified token in .env silently.
  seed_env
  FAKE_CURL_MINT_OUTPUT='{"Value":"bogus-tok"}' FAKE_CURL_VERIFY_RC=22 \
    run bash -c '
      printf "https://mfiles.test\nwrongUsername\n1\n{GUID-1}\nwrongpw\nn\n" |
        bash "'"$SANDBOX"'/start.sh" --mfiles-token
    '
  [ "$status" -eq 1 ]
  [[ "$output" == *"verification call failed"* ]]
  [[ "$output" != *"bogus-tok"* ]]
  grep -q '^MFILES_PAT=$' "$SANDBOX/.env"
}

@test "--mfiles-token: an unverified token is written when the user explicitly opts in" {
  seed_env
  FAKE_CURL_MINT_OUTPUT='{"Value":"unverified-tok"}' FAKE_CURL_VERIFY_RC=22 \
    run bash -c '
      printf "https://mfiles.test\nbob\n1\n{GUID-1}\nsecretpw\ny\n" |
        bash "'"$SANDBOX"'/start.sh" --mfiles-token
    '
  [ "$status" -eq 0 ]
  grep -q '^MFILES_PAT=unverified-tok$' "$SANDBOX/.env"
}

# --- --logs -------------------------------------------------------------------

@test "--help mentions --logs and --shell" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--logs"* ]]
  [[ "$output" == *"--shell"* ]]
}

@test "--logs invokes compose logs -f with the right -p when the stack is up" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  : > "$FAKE_DOCKER_LOG"   # isolate the log to the --logs call below

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'compose .*-p opencode-my-service .*logs -f' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"tailing logs"* ]]
  [[ "$output" == *"Ctrl-C detaches"* ]]
}

@test "--logs is graceful when nothing is running" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  ! grep -qE 'logs -f' "$FAKE_DOCKER_LOG"
}

@test "--logs is graceful when no .env has ever been created" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing has ever been started"* ]]
}

@test "--logs requires a repo path" {
  seed_env
  run_launcher --logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

@test "--logs rejects a nonexistent repo path" {
  seed_env
  run_launcher --logs "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

@test "--logs never pulls an image or attaches the TUI" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  : > "$FAKE_DOCKER_LOG"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--logs does not require an LLM key" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'logs -f' "$FAKE_DOCKER_LOG"
}

# --- --shell ------------------------------------------------------------------

@test "--shell execs into the container as dev rooted at /workspace" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  : > "$FAKE_DOCKER_LOG"

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^exec .*-u dev .*-w /workspace .*-it opencode-my-service bash$' "$FAKE_DOCKER_LOG"
  [[ "$output" == *"opening a shell"* ]]
}

@test "--shell falls back to sh when bash is unavailable in the container" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  : > "$FAKE_DOCKER_LOG"

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    FAKE_DOCKER_EXEC_PROBE_RC=1 \
    run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^exec .*-u dev .*-w /workspace .*-it opencode-my-service sh$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'opencode-my-service bash$' "$FAKE_DOCKER_LOG"
}

@test "--shell is graceful when the container isn't running" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  ! grep -q '^exec ' "$FAKE_DOCKER_LOG"
}

@test "--shell is graceful when no .env has ever been created" {
  [ ! -f "$SANDBOX/.env" ]
  local repo; repo="$(make_repo_arg)"
  run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing has ever been started"* ]]
}

@test "--shell requires a repo path" {
  seed_env
  run_launcher --shell
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

@test "--shell rejects a nonexistent repo path" {
  seed_env
  run_launcher --shell "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

@test "--shell never pulls an image" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --detach "$repo"
  : > "$FAKE_DOCKER_LOG"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  ! grep -qE 'pull' "$FAKE_DOCKER_LOG"
}

@test "--shell does not require an LLM key" {
  seed_env
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=|' "$SANDBOX/.env"
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    run_launcher --shell "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^exec .*-it opencode-myrepo bash$' "$FAKE_DOCKER_LOG"
}

# --- sticky ports / read-only commands must not rewrite state ---------------
# Regression coverage for: derive_project_settings used to recompute the port
# with a fresh `port_in_use 4096` and rewrite .envs/<slug>.env on EVERY call
# (including --down/--logs/--shell). If a project's own stack was running on
# 4096, those commands saw 4096 "busy" (their own stack!), picked 4097, and
# overwrote the recorded port — after which --status read the wrong web-UI
# URL back out of the file. Ports must be sticky per project, and read-only
# commands must never perturb the recorded file.

@test "boot: sticky port — re-running while the project's own stack is already up keeps the recorded (non-default) port" {
  seed_env
  local repo; repo="$(make_repo_arg "Sticky Repo")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  local penv="$SANDBOX/.envs/sticky-repo.env"
  [ -f "$penv" ]

  # Simulate the project having previously landed on a non-default port (e.g.
  # 4096 was busy at the time) and its own oc-publish container being up
  # right now — re-running boot must NOT bounce it back to 4096.
  sed -i 's|^OPENCODE_PORT=.*|OPENCODE_PORT=5555|' "$penv"
  FAKE_DOCKER_PS_OUTPUT="opencode-publish-sticky-repo" run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://localhost:5555"* ]]
  grep -q '^OPENCODE_PORT=5555$' "$penv"
}

@test "regression: --logs does not clobber the recorded port for a running stack (matches --status afterward)" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  local penv="$SANDBOX/.envs/my-service.env"
  grep -q '^OPENCODE_PORT=4096$' "$penv"

  # The project's own oc-publish container is up (so 4096 would look "busy"
  # to a naive re-derivation) — --logs must leave the recorded port alone.
  FAKE_DOCKER_PS_OUTPUT="opencode-publish-my-service" \
    FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --logs "$repo"
  [ "$status" -eq 0 ]
  grep -q '^OPENCODE_PORT=4096$' "$penv"

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://localhost:4096"* ]]
}

@test "--logs never rewrites an existing .envs/<slug>.env (content and mtime unchanged)" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  local penv="$SANDBOX/.envs/my-service.env"
  [ -f "$penv" ]
  local before_sum before_mtime
  before_sum="$(md5sum "$penv" | awk '{print $1}')"
  before_mtime="$(stat -c %Y "$penv")"
  sleep 1

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --logs "$repo"
  [ "$status" -eq 0 ]

  [ "$before_sum" = "$(md5sum "$penv" | awk '{print $1}')" ]
  [ "$before_mtime" = "$(stat -c %Y "$penv")" ]
}

@test "--shell never rewrites an existing .envs/<slug>.env (content and mtime unchanged)" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  local penv="$SANDBOX/.envs/my-service.env"
  [ -f "$penv" ]
  local before_sum before_mtime
  before_sum="$(md5sum "$penv" | awk '{print $1}')"
  before_mtime="$(stat -c %Y "$penv")"
  sleep 1

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --shell "$repo"
  [ "$status" -eq 0 ]

  [ "$before_sum" = "$(md5sum "$penv" | awk '{print $1}')" ]
  [ "$before_mtime" = "$(stat -c %Y "$penv")" ]
}

@test "--down never rewrites an existing .envs/<slug>.env (content and mtime unchanged)" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  local penv="$SANDBOX/.envs/my-service.env"
  [ -f "$penv" ]
  local before_sum before_mtime
  before_sum="$(md5sum "$penv" | awk '{print $1}')"
  before_mtime="$(stat -c %Y "$penv")"
  sleep 1

  run_launcher --down "$repo"
  [ "$status" -eq 0 ]

  [ "$before_sum" = "$(md5sum "$penv" | awk '{print $1}')" ]
  [ "$before_mtime" = "$(stat -c %Y "$penv")" ]
}

@test "--down generates .envs/<slug>.env when nothing was ever booted for this repo (but .env exists)" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  local penv="$SANDBOX/.envs/myrepo.env"
  [ ! -f "$penv" ]
  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  [ -f "$penv" ]
}

# --- --open ---------------------------------------------------------------

@test "--help mentions --open" {
  run_launcher --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--open"* ]]
}

@test "--open launches xdg-open with the printed web UI URL" {
  seed_env
  run_launcher --detach --open "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'http://localhost:[0-9]+' "$FAKE_XDG_OPEN_LOG"
  [[ "$output" == *"launching xdg-open"* ]]
}

@test "--open works alongside --persist/--web" {
  seed_env
  run_launcher --persist --open "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  grep -qE 'http://localhost:[0-9]+' "$FAKE_XDG_OPEN_LOG"
}

@test "without --open, xdg-open is never invoked" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_XDG_OPEN_LOG" ]
}

@test "--open warns but does not fail the boot when xdg-open is missing" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  # Run in a stripped-down PATH that has docker (sandbox copy is found via the
  # fake-bin dir already on PATH) but no xdg-open at all. Use a temp PATH
  # containing only FAKE_BIN's docker stub directory and core utils.
  local stub_dir="$BATS_TEST_TMPDIR/no-xdg-open-bin"
  mkdir -p "$stub_dir"
  ln -sf "$FAKE_BIN/docker" "$stub_dir/docker"
  PATH="$stub_dir:/usr/bin:/bin" run bash "$SANDBOX/start.sh" --detach --open "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found on PATH"* ]]
  [[ "$output" == *"open this URL yourself"* ]]
}

@test "--open respects an OPENER override for the browser command" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  OPENER=xdg-open run_launcher --detach --open "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'http://localhost:[0-9]+' "$FAKE_XDG_OPEN_LOG"
}

# --- image digest print -----------------------------------------------------

@test "default boot prints the resolved image digest" {
  seed_env
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123ab" \
    run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image:"* ]]
  [[ "$output" == *"sha256:abc123abc123"* ]]
}

@test "boot does not fail when the image digest can't be determined" {
  seed_env
  FAKE_DOCKER_IMAGE_INSPECT_RC=1 run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
}

@test "--status surfaces the last-recorded image digest after a boot" {
  seed_env
  local repo; repo="$(make_repo_arg "My Service")"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:def456def456def456def456def456def456def456def456def456def456de" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-my-service	running(3)" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image:"* ]]
  [[ "$output" == *"sha256:def456def456"* ]]
}

# --- update nudge -----------------------------------------------------------

@test "update nudge stays silent on the first boot for a project" {
  seed_env
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:1111111111111111111111111111111111111111111111111111111111111a" \
    run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"image updated:"* ]]
}

@test "update nudge stays silent when the digest is unchanged across boots" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:2222222222222222222222222222222222222222222222222222222222222b" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:2222222222222222222222222222222222222222222222222222222222222b" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"image updated:"* ]]
}

@test "update nudge fires when the digest changes between boots" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:3333333333333333333333333333333333333333333333333333333333333c" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:4444444444444444444444444444444444444444444444444444444444444d" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image updated:"* ]]
  [[ "$output" == *"sha256:444444444444"* ]]
  [[ "$output" == *"sha256:333333333333"* ]]
}

# --- image self-description on update (manifest/changelog/version label) ---

@test "boot on a digest change prints the image version + changelog and warns on manifest drift" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:5555555555555555555555555555555555555555555555555555555555555e" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:6666666666666666666666666666666666666666666666666666666666666f" \
    FAKE_DOCKER_IMAGE_LABEL="0.0.7" \
    FAKE_DOCKER_MANIFEST='{"env_keys": [ {"key": "LLM_API_BASE", "required": true}, {"key": "NEW_KEY_X", "required": false} ]}' \
    FAKE_DOCKER_CHANGELOG='## [0.0.7] — 2026-07-01

### Added
- JFrog MCP server.' \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image updated:"* ]]
  [[ "$output" == *"image version: 0.0.7"* ]]
  [[ "$output" == *"JFrog MCP server."* ]]
  [[ "$output" == *"this image reads env key(s) your launcher doesn't know: NEW_KEY_X"* ]]
  [[ "$output" == *"git pull the launcher"* ]]
}

@test "boot on a digest change with a drift-free manifest prints no drift warning" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:9999999999999999999999999999999999999999999999999999999999999c" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaad" \
    FAKE_DOCKER_IMAGE_LABEL="0.0.7" \
    FAKE_DOCKER_MANIFEST='{"env_keys": [ {"key": "LLM_API_BASE", "required": true} ]}' \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image version: 0.0.7"* ]]
  [[ "$output" != *"reads env key(s)"* ]]
}

@test "boot stays silent about manifest/version/changelog for an old image, even when the digest changes" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:7777777777777777777777777777777777777777777777777777777777777a" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  # No FAKE_DOCKER_IMAGE_LABEL / FAKE_DOCKER_MANIFEST / FAKE_DOCKER_CHANGELOG
  # set — mirrors an old image that has none of the newer self-description
  # files, even though the digest still changed.
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:8888888888888888888888888888888888888888888888888888888888888b" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image updated:"* ]]
  [[ "$output" != *"image version:"* ]]
  [[ "$output" != *"reads env key(s)"* ]]
  [[ "$output" != *"changelog"* ]]
}

@test "boot on an UNCHANGED digest never runs the manifest/version/changelog reporting" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc" \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  # Same digest again, but WITH a manifest/label/changelog fixture set — if
  # the reporting ran anyway it would show up; it must not, since nothing
  # changed and boot should stay exactly as fast/quiet as before this feature.
  FAKE_DOCKER_IMAGE_DIGEST="reg.test.local/opencode@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc" \
    FAKE_DOCKER_IMAGE_LABEL="0.0.7" \
    FAKE_DOCKER_MANIFEST='{"env_keys": [ {"key": "NEW_KEY_X", "required": false} ]}' \
    run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"image updated:"* ]]
  [[ "$output" != *"image version:"* ]]
  [[ "$output" != *"reads env key(s)"* ]]
}

# --- .env.example drift check -----------------------------------------------

@test "drift check is silent when .env has every .env.example key" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"new key"* ]]
}

@test "drift check warns when .env.example has a key missing from .env" {
  seed_env
  printf '\nNEW_FEATURE_FLAG=\n' >> "$SANDBOX/.env.example"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW_FEATURE_FLAG"* ]]
  [[ "$output" == *"--reconfigure"* ]]
}

@test "drift check never prints a value, only the missing key name" {
  seed_env
  printf '\nNEW_SECRET_FLAG=\n' >> "$SANDBOX/.env.example"
  sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-super-secret-value|' "$SANDBOX/.env"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW_SECRET_FLAG"* ]]
  [[ "$output" != *"sk-super-secret-value"* ]]
}

# --- --also (extra repo/folder mounts) --------------------------------------

@test "--also: default is read-only, prints the boot line and writes a ro,z overlay" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"also: ${liba} -> /workspace-extra/liba (read-only)"* ]]
  [ -f "$SANDBOX/.envs/myrepo.also.yml" ]
  grep -qF "# generated by start.sh --also; do not edit" "$SANDBOX/.envs/myrepo.also.yml"
  grep -qF -- "- ${liba}:/workspace-extra/liba:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
  grep -q 'myrepo.also.yml' "$FAKE_DOCKER_LOG"
}

@test "--also: a trailing :rw suffix opts a mount into read-write (z, not ro,z)" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local libb; libb="$(make_repo_arg "libb")"
  run_launcher --detach --also "${libb}:rw" "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"also: ${libb} -> /workspace-extra/libb (read-write)"* ]]
  grep -qF -- "- ${libb}:/workspace-extra/libb:z" "$SANDBOX/.envs/myrepo.also.yml"
  ! grep -qF -- "- ${libb}:/workspace-extra/libb:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
}

@test "--also is repeatable: each mount gets its own line, in order" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  local libb; libb="$(make_repo_arg "libb")"
  run_launcher --detach --also "$liba" --also "${libb}:rw" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "- ${liba}:/workspace-extra/liba:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
  grep -qF -- "- ${libb}:/workspace-extra/libb:z" "$SANDBOX/.envs/myrepo.also.yml"
}

@test "--also: a name collision between two paths gets -2/-3 suffixing" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  mkdir -p "$BATS_TEST_TMPDIR/one/lib" "$BATS_TEST_TMPDIR/two/lib" "$BATS_TEST_TMPDIR/three/lib"
  run_launcher --detach \
    --also "$BATS_TEST_TMPDIR/one/lib" \
    --also "$BATS_TEST_TMPDIR/two/lib" \
    --also "$BATS_TEST_TMPDIR/three/lib" \
    "$repo"
  [ "$status" -eq 0 ]
  grep -qF "/workspace-extra/lib:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
  grep -qF "/workspace-extra/lib-2:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
  grep -qF "/workspace-extra/lib-3:ro,z" "$SANDBOX/.envs/myrepo.also.yml"
}

@test "--also: a nonexistent path dies with a clear message" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --detach --also "$BATS_TEST_TMPDIR/does-not-exist" "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--also path does not exist"* ]]
}

@test "--also: a file (not a directory) path dies" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  local f="$BATS_TEST_TMPDIR/afile"
  : > "$f"
  run_launcher --detach --also "$f" "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--also path is not a directory"* ]]
}

@test "--also: duplicating the main repo path dies with a clear message" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --detach --also "$repo" "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicates the main repo path"* ]]
}

@test "--also requires a <path> argument" {
  seed_env
  run_launcher --detach --also
  [ "$status" -eq 1 ]
  [[ "$output" == *"--also requires a"* ]]
}

@test "--also: no --also flags on a later boot deletes a stale overlay" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.envs/myrepo.also.yml" ]

  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/.envs/myrepo.also.yml" ]
}

@test "--also: writes a breadcrumb and wires OPENCODE_EXTRA_INSTRUCTIONS so the image surfaces it" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  # breadcrumb generated next to the overlay, naming the mount + its container path
  [ -f "$SANDBOX/.envs/myrepo.also-context.md" ]
  grep -qF -- '`/workspace-extra/liba`' "$SANDBOX/.envs/myrepo.also-context.md"
  # overlay tells the image to load it via the generic hook (no --also knowledge image-side)
  grep -qF "OPENCODE_EXTRA_INSTRUCTIONS: /etc/opencode/also-context.md" "$SANDBOX/.envs/myrepo.also.yml"
  grep -qF -- "/etc/opencode/also-context.md:ro,z" "$SANDBOX/.envs/myrepo.also.yml"

  # a later boot with no --also removes the breadcrumb too, not just the overlay
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/.envs/myrepo.also-context.md" ]
}

@test "--also overlay is appended LAST in COMPOSE_FILES (after the podman overlay)" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --podman --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  # the `pull` invocation lists every -f in COMPOSE_FILES order
  local pull_line
  pull_line="$(grep -E 'compose .*pull$' "$FAKE_DOCKER_LOG")"
  [[ "$pull_line" == *"docker-compose.podman.yml"* ]]
  [[ "$pull_line" == *"myrepo.also.yml"* ]]
  local podman_pos also_pos
  podman_pos="${pull_line%%docker-compose.podman.yml*}"
  also_pos="${pull_line%%myrepo.also.yml*}"
  [ "${#podman_pos}" -lt "${#also_pos}" ]
}

@test "--down/--logs/--shell include the --also overlay when present" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  : > "$FAKE_DOCKER_LOG"

  run_launcher --down "$repo"
  [ "$status" -eq 0 ]
  grep -qE 'compose .*myrepo\.also\.yml.*down' "$FAKE_DOCKER_LOG"
}

# --- --exec (non-interactive one-shot run) ----------------------------------

@test "--exec runs opencode run non-interactively (-i, not -t) and tears the stack down" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --exec "summarize the TODOs" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^exec .*-i opencode-myrepo opencode run summarize the TODOs$' "$FAKE_DOCKER_LOG"
  ! grep -qE '^exec .*-it .*opencode run' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--exec requires a <prompt> argument" {
  seed_env
  run_launcher --exec
  [ "$status" -eq 1 ]
  [[ "$output" == *"--exec requires a"* ]]
}

@test "--exec conflicts with --detach" {
  seed_env
  run_launcher --exec "hi" --detach "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--exec and --detach conflict"* ]]

  run_launcher --detach --exec "hi" "$(make_repo_arg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--exec and --detach conflict"* ]]
}

@test "--exec propagates opencode run's exit code and still tears down" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_EXEC_RC=7 run_launcher --exec "do the thing" "$repo"
  [ "$status" -eq 7 ]
  grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--exec --persist skips teardown (and stays quiet on success)" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  run_launcher --exec "hi" --persist "$repo"
  [ "$status" -eq 0 ]
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
  # A successful --exec prints only opencode's answer; the launcher's own
  # notices (this one included) are buffered and dropped, not shown.
  [[ "$output" != *"--persist: leaving"* ]]
}

@test "--exec --persist still propagates a nonzero exit code" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_EXEC_RC=3 run_launcher --exec "hi" --persist "$repo"
  [ "$status" -eq 3 ]
  ! grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--exec --continue prepends -c to the opencode run args, ahead of the prompt" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --exec "summarize" --continue "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^exec .*opencode-myrepo opencode run -c summarize$' "$FAKE_DOCKER_LOG"
}

@test "--exec works together with --also" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --exec "hi" --also "$liba" "$repo"
  [ "$status" -eq 0 ]
  # The overlay is still wired in (asserted via the compose files); the "also:"
  # notice itself is a success-time diagnostic, so it's suppressed, not printed.
  grep -qE 'compose .*myrepo\.also\.yml.*down' "$FAKE_DOCKER_LOG"
}

@test "--exec is quiet on success: boot chatter is suppressed" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --exec "hi" "$repo"
  [ "$status" -eq 0 ]
  # On success the launcher emits nothing of its own — no `2>/dev/null` needed;
  # the boot chatter is buffered and discarded (it's replayed only on failure,
  # covered by the failure test below).
  [[ "$output" != *"project: opencode-myrepo"* ]]
  [[ "$output" != *"pulling images"* ]]
  [[ "$output" != *"exec: running"* ]]
}

@test "--exec forwards genuinely piped stdin through to opencode run" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local infile="$BATS_TEST_TMPDIR/in.txt"
  printf 'PIPED-CONTEXT' > "$infile"
  local slog="$BATS_TEST_TMPDIR/exec-stdin.log"
  # stdin is a regular file (not a TTY): the launcher must forward it, so the
  # (drain-emulating) fake opencode receives exactly the piped bytes.
  export FAKE_DOCKER_EXEC_DRAIN_STDIN=1 FAKE_DOCKER_EXEC_STDIN_LOG="$slog"
  run_launcher --exec "summarize" "$repo" < "$infile"
  [ "$status" -eq 0 ]
  [ "$(cat "$slog")" = "PIPED-CONTEXT" ]
}

@test "--exec success: stdout is ONLY opencode's answer, and nothing hits stderr" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local errfile="$BATS_TEST_TMPDIR/exec.err"
  # Fake opencode: answer on stdout, project-id noise (x2) + a real diagnostic
  # on stderr. Capture the launcher's stdout in $output and its stderr in a file
  # so we can assert on each stream independently.
  export FAKE_DOCKER_EXEC_EMIT_NOISE=1
  run bash -c 'bash "$1" --exec "hello" "$2" 2>"$3"' _ "$SANDBOX/start.sh" "$repo" "$errfile"
  [ "$status" -eq 0 ]
  # stdout is EXACTLY opencode's answer — no launcher chatter, no opencode log.
  [ "$output" = "ANSWER-MARKER" ]
  # On success the buffered diagnostics are discarded: stderr is empty, so the
  # user gets a clean answer without needing `2>/dev/null`.
  [ ! -s "$errfile" ]
}

@test "--exec failure: answer still on stdout, buffered diagnostics replayed to stderr, rc preserved" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local errfile="$BATS_TEST_TMPDIR/exec.err"
  # Same split output, but opencode exits non-zero this time.
  export FAKE_DOCKER_EXEC_EMIT_NOISE=1 FAKE_DOCKER_EXEC_RC=7
  run bash -c 'bash "$1" --exec "hello" "$2" 2>"$3"' _ "$SANDBOX/start.sh" "$repo" "$errfile"
  [ "$status" -eq 7 ]
  # opencode's own exit code is preserved, and whatever it wrote to stdout stays.
  [ "$output" = "ANSWER-MARKER" ]
  # Because the run FAILED, the buffer is replayed to stderr: opencode's logs
  # (unfiltered — the noise rides along) AND the launcher's boot chatter.
  local err; err="$(cat "$errfile")"
  [[ "$err" == *"No .git found"* ]]
  [[ "$err" == *"REAL-STDERR-DIAGNOSTIC"* ]]
  [[ "$err" == *"project: opencode-myrepo"* ]]
}

@test "--exec does not hang when the launcher is attached to an interactive TTY" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required for the PTY harness"
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  # Reproduce the original hang: a fake `opencode run` that drains stdin, driven
  # under a genuine, never-closing PTY on the launcher's stdin (see pty-run.py).
  # The fix must feed opencode /dev/null for a TTY so the drain sees EOF; without
  # it the drain blocks forever and the PTY harness times out (status 124).
  export FAKE_DOCKER_EXEC_DRAIN_STDIN=1
  run python3 "$REPO_ROOT/tests/pty-run.py" 20 \
    bash "$SANDBOX/start.sh" --exec "hi" "$repo"
  [ "$status" -ne 124 ]   # 124 == the harness timed out => the hang is back
  [ "$status" -eq 0 ]
  grep -qE '^exec .*-i opencode-myrepo opencode run hi$' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--exec on an interactive terminal: spinner draws, answer lands cleanly on its own line" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required for the PTY harness"
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  # Fake opencode emits the answer on stdout (+ noise on stderr). Under a full
  # PTY the launcher is interactive, so the spinner runs; capture what the
  # terminal actually received.
  export FAKE_DOCKER_EXEC_EMIT_NOISE=1
  run python3 "$REPO_ROOT/tests/pty-capture.py" 20 \
    bash "$SANDBOX/start.sh" --exec "hello" "$repo"
  [ "$status" -eq 0 ]
  # A braille spinner glyph (U+28xx -> UTF-8 lead bytes E2 A0..) was drawn.
  [[ "$output" == *$'\xe2\xa0'* ]]
  # The answer is present AND starts on its own line — the regression was the
  # spinner text and the answer ending up smooshed on a single line.
  [[ "$output" == *"ANSWER-MARKER"* ]]
  [[ "$output" == *$'\nANSWER-MARKER'* ]]
}

@test "--exec (teardown) boots only opencode — no web-UI publisher — and scopes the pull" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --exec "hi" "$repo"
  [ "$status" -eq 0 ]
  # Only the agent (+ its squid dependency) comes up; NOT the whole stack, so
  # oc-publish (the host-port web-UI publisher) is never started.
  grep -qE 'compose .* up -d opencode$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .* up -d$' "$FAKE_DOCKER_LOG"
  # The pull is scoped to the two images actually needed, not a blanket pull.
  grep -qE 'compose .* pull opencode squid$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .* pull$' "$FAKE_DOCKER_LOG"
}

@test "--exec --persist boots the FULL stack (web UI included)" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --exec "hi" --persist "$repo"
  [ "$status" -eq 0 ]
  # --persist keeps a resumable environment, so the whole stack comes up.
  grep -qE 'compose .* up -d$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .* up -d opencode$' "$FAKE_DOCKER_LOG"
}

@test "--exec (teardown) omits the web-UI URL/note, even in the failure replay" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local errfile="$BATS_TEST_TMPDIR/exec.err"
  # Force a nonzero run so the buffered boot chatter is replayed to stderr, then
  # assert it carries the normal boot lines but NOT the web-UI URL/workaround —
  # a one-shot --exec publishes no port, so those lines are suppressed.
  export FAKE_DOCKER_EXEC_RC=7
  run bash -c 'bash "$1" --exec "hi" "$2" 2>"$3"' _ "$SANDBOX/start.sh" "$repo" "$errfile"
  [ "$status" -eq 7 ]
  local err; err="$(cat "$errfile")"
  [[ "$err" == *"project: opencode-myrepo"* ]]
  [[ "$err" != *"web UI:"* ]]
  [[ "$err" != *"14445"* ]]
}

@test "--exec with no repo path boots the norepo project against an empty workspace" {
  seed_env
  run_launcher --exec "explain the CAP theorem"
  [ "$status" -eq 0 ]
  # No repo arg: the run uses the fixed 'norepo' slug/project and still runs the
  # one-shot prompt non-interactively, then tears down.
  grep -qE '^exec .*-i opencode-norepo opencode run explain the CAP theorem$' "$FAKE_DOCKER_LOG"
  ! grep -qE '^exec .*-it .*opencode run' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .*down' "$FAKE_DOCKER_LOG"
}

@test "--exec with no repo path still boots only the minimal stack" {
  seed_env
  run_launcher --exec "hi"
  [ "$status" -eq 0 ]
  # Same minimal-stack scoping as a repo-backed --exec: only opencode comes up,
  # and the pull is scoped (no web-UI publisher).
  grep -qE 'compose .* up -d opencode$' "$FAKE_DOCKER_LOG"
  ! grep -qE 'compose .* up -d$' "$FAKE_DOCKER_LOG"
  grep -qE 'compose .* pull opencode squid$' "$FAKE_DOCKER_LOG"
}

@test "a bare run with no repo path and no --exec still errors" {
  seed_env
  run_launcher
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <host-repo-path>"* ]]
}

# --- --status: --also mounts + MCP servers ----------------------------------

@test "--status lists --also mounts from the generated overlay" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  local liba; liba="$(make_repo_arg "liba")"
  run_launcher --detach --also "${liba}:rw" "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"also: ${liba} -> /workspace-extra/liba (read-write)"* ]]
}

@test "--status shows no also: line when there is no overlay" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"also:"* ]]
}

@test "--status shows the mcps line when running and MCP servers are configured" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    FAKE_DOCKER_MCP_OUTPUT="bitbucket, jira" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mcps:    bitbucket, jira"* ]]
}

@test "--status shows '(none configured)' when running with an empty MCP list" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    FAKE_DOCKER_MCP_OUTPUT="" \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mcps:    (none configured)"* ]]
}

@test "--status shows no mcps line when the stack is down" {
  seed_env
  local repo; repo="$(make_repo_arg)"
  FAKE_DOCKER_COMPOSE_LS_OUTPUT="" run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"mcps:"* ]]
}

@test "--status shows no mcps line when the jq probe fails (best-effort)" {
  seed_env
  local repo; repo="$(make_repo_arg "myrepo")"
  run_launcher --detach "$repo"
  [ "$status" -eq 0 ]

  FAKE_DOCKER_COMPOSE_LS_OUTPUT="opencode-myrepo	running(3)" \
    FAKE_DOCKER_MCP_RC=1 \
    run_launcher --status "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"mcps:"* ]]
}

# --- launcher self-update check ----------------------------------------------

@test "boot prints the update nudge when the launcher checkout is behind origin" {
  seed_env
  make_sandbox_git_repo_behind 1
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher update available: 1 commit(s) behind origin — git pull to update"* ]]
}

@test "boot stays silent when the launcher checkout is in sync with origin" {
  seed_env
  make_sandbox_git_repo_behind 0
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"launcher update available"* ]]
}

@test "boot stays silent when the launcher checkout isn't a git repo at all" {
  seed_env
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"launcher update available"* ]]
}

@test "OC_SKIP_UPDATE_CHECK=1 suppresses the boot nudge even when behind" {
  seed_env
  make_sandbox_git_repo_behind 1
  OC_SKIP_UPDATE_CHECK=1 run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"launcher update available"* ]]
}

# The gate only PROMPTS on an interactive tty boot; bats' `run` has no tty, so
# these headless (`--detach`) runs exercise the passive-nudge fallback — the
# same path a --detach/CI boot takes in production. The interactive accept +
# git-pull + re-exec path is covered by the pure-helper unit tests
# (image_tag_pinned, launcher_pull_ff) plus manual verification.

@test "boot nudges when IMAGE_TAG is pinned off latest" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image pinned to 0.0.2"* ]]
}

@test "boot does NOT nudge when IMAGE_TAG=local (self-built sentinel)" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=local|' "$SANDBOX/.env"
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"image pinned"* ]]
}

@test "OC_SKIP_UPDATE_CHECK=1 suppresses the pinned-image nudge" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  OC_SKIP_UPDATE_CHECK=1 run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"image pinned"* ]]
}

@test "boot nudges for BOTH a behind launcher and a pinned image" {
  seed_env
  sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=0.0.2|' "$SANDBOX/.env"
  make_sandbox_git_repo_behind 2
  run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launcher update available: 2 commit(s) behind origin — git pull to update"* ]]
  [[ "$output" == *"image pinned to 0.0.2"* ]]
}

@test "post-upgrade config offer falls back to the passive drift warn on a non-tty boot" {
  # OC_PREV_REV is set (as it would be right after a re-exec), but bats has no
  # tty, so config_drift_step must NOT prompt (no hang) and must print the same
  # passive drift warning instead. A brand-new .env.example key the .env lacks
  # is the drift signal.
  seed_env
  printf 'NEWKEY_FOR_TEST=\n' >> "$SANDBOX/.env.example"
  OC_PREV_REV=HEAD run_launcher --detach "$(make_repo_arg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has new key(s) not in your"* ]]
  [[ "$output" == *"NEWKEY_FOR_TEST"* ]]
  [[ "$output" != *"set them now?"* ]]
}

@test "--doctor: PASSes 'launcher up to date' when in sync" {
  seed_env_doctor
  make_sandbox_git_repo_behind 0
  run_launcher --doctor
  [[ "$output" == *"[PASS] launcher up to date"* ]]
}

@test "--doctor: WARNs (never FAILs) the commit count when behind" {
  seed_env_doctor
  make_sandbox_git_repo_behind 2
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] launcher update check"* ]]
  [[ "$output" == *"2 commit(s) behind origin — git pull"* ]]
}

@test "--doctor: a neutral skipped WARN when the checkout isn't a git repo" {
  seed_env_doctor
  run_launcher --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] launcher update check"* ]]
  [[ "$output" == *"skipped (no upstream/offline)"* ]]
}
