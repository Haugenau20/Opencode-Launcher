# shellcheck shell=bash
#
# lib/usage.sh — the --help / usage text.
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definition, no top-level side effects, so the file is
# safe to source for unit tests.

# --- usage / --help ---------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  ./start.sh [--continue] [--persist] [--detach] [--podman] [--open]
              [--also <path>[:rw]]... <host-repo-path>
  ./start.sh --exec "<prompt>" [--continue] [--persist] [--also <path>[:rw]]... <host-repo-path>
  ./start.sh --doctor [<host-repo-path>]
  ./start.sh --status [<host-repo-path>]
  ./start.sh --down|--stop <host-repo-path>
  ./start.sh --logs <host-repo-path>
  ./start.sh --shell <host-repo-path>
  ./start.sh --reconfigure
  ./start.sh --config
  ./start.sh --show-allowlist [<host-repo-path>]
  ./start.sh --version
  ./start.sh --help

Boots a locked-down OpenCode environment with your repo mounted at /workspace.
By default the TUI is attached in the foreground; exiting it tears the stack
down again (a clean one-in/one-out flow).

Run options:
  --continue Resume your most recent opencode session instead of a fresh one.
             No-op with --detach. Alias: -c.
  --persist  Keep the stack (and its web UI) running after you exit the TUI, so
             you can resume later. Alias: --web.
  --detach   Boot headless — don't attach the TUI; the stack keeps running.
             For scripted/CI or web-only runs. Alias: --no-tui. Conflicts with
             --exec (both are non-interactive; pick one).
  --podman   Add the Podman overlay (keep-id userns) for rootless Podman.
             Auto-detected; pass the flag to force it.
  --tui      Attach the TUI (the default; accepted for back-compat).
  --open     Open the web UI URL in your browser via xdg-open once it's known.
             Non-fatal if xdg-open is missing.
  --also <path>[:rw]
             Bind-mount an extra host folder into the container at
             /workspace-extra/<name> (<name> is derived from the folder's own
             basename, like the project slug; -2/-3/... on a name collision
             between two --also paths), alongside your main repo at
             /workspace. Read-only by default; append :rw to mount that one
             path read-write. Repeatable. A path containing ':' beyond the
             optional trailing ':rw' isn't supported (matches Docker's own
             short bind-mount syntax) — avoid such paths. Applies to the run
             and --exec paths; --status <repo> lists the mounts a stack was
             last booted with.
  --exec "<prompt>"
             Boot a minimal stack (just the agent + its egress proxy — no web
             UI, no TUI attached), run <prompt> non-interactively via
             `opencode run` inside the container, tear the stack down (unless
             --persist is also given), and exit with that command's own exit
             code — for scripting/CI. --continue prepends opencode's own -c
             (resume most recent session) ahead of the prompt. On success it
             prints EXACTLY opencode's answer — all launcher/opencode chatter
             is buffered and dropped; on failure that buffer is replayed to
             stderr so you can see what went wrong. When run interactively a
             spinner confirms progress from the moment you hit Enter through
             the whole boot, then erases itself before the answer prints; it is
             drawn only to the terminal (never stdout/stderr) and only when a
             terminal is present, so piped/CI output is byte-exact with no
             spinner at all. --persist keeps the full stack (web UI included)
             running afterward instead.

Inspect / manage (these report or act, then exit — no image pull, no secrets
needed):
  --doctor   Check the environment (Docker, compose, registry auth, .env keys
             and .env.example drift, disk) and print a PASS/WARN/FAIL report. An
             optional <host-repo-path> also validates that repo path; exits
             non-zero on any FAIL.
  --status   Report on running stacks. With <host-repo-path>, shows whether that
             project is up, its web UI URL, and the resume command; without one,
             lists every opencode-* stack.
  --down     Tear down the stack for <host-repo-path> (docker compose down),
  --stop     re-deriving the same project boot uses. Safe if nothing is up.
  --logs     Follow the running stack's logs for <host-repo-path>. Ctrl-C
             detaches without affecting the stack.
  --shell    Open a shell in the running container for <host-repo-path> as the
             `dev` user at /workspace (falls back to sh). No-op if not running.
  --reconfigure
             Re-run the secrets wizard, pre-filled with your current .env (Enter
             keeps a value; secrets stay masked). On a real terminal it uses a
             whiptail/dialog menu when available, otherwise a dashboard plus a
             plain-text editor; piped input walks every key. OC_CONFIG_TUI=0
             forces the plain-text path.
  --config   Print a read-only dashboard of every .env setting, grouped by
             section. Secrets show as set/unset only. Edit with --reconfigure.
  --show-allowlist
             Print the outbound egress the sandboxed agent is allowed. The
             allowlist (LLM, Bitbucket, Jira, GitLab) is enforced in the squid
             image; this shows your configured LLM/Bitbucket hosts plus any
             local extra-allowlist.d/*.conf extensions.
  --version  Print the launcher version (from the VERSION file). Alias: -V.
  --help     Show this help.

The image tag comes from IMAGE_TAG in .env (default 'latest'; pin e.g. 0.0.2).
The TUI is the default frontend — zero setup and always rooted at /workspace. The
web/desktop UI also works; a new session just defaults its working directory to /,
so click 'New session' and type /workspace to root that session at your repo.

First run creates .env from .env.example and prompts for your secrets; later
runs reuse it (edit by hand any time).

On every boot, a best-effort check reports if this launcher checkout is behind
its git upstream ("launcher update available: N commit(s) behind origin — git
pull to update"); silent when up to date, offline, or not a git checkout. Set
OC_SKIP_UPDATE_CHECK=1 to skip the check entirely (e.g. scripted/CI runs).
--doctor reports the same check as its own PASS/WARN line.
EOF
}
