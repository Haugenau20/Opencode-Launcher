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
By default the TUI is attached in the foreground; exiting it tears the stack
down again (a clean one-in/one-out flow).

Run options:
  --continue Resume your most recent opencode session instead of a fresh one.
             No-op with --detach. Alias: -c.
  --persist  Keep the stack (and its web UI) running after you exit the TUI, so
             you can resume later. Alias: --web.
  --detach   Boot headless — don't attach the TUI; the stack keeps running.
             For scripted/CI or web-only runs. Alias: --no-tui.
  --podman   Add the Podman overlay (keep-id userns) for rootless Podman.
             Auto-detected; pass the flag to force it.
  --tui      Attach the TUI (the default; accepted for back-compat).
  --open     Open the web UI URL in your browser via xdg-open once it's known.
             Non-fatal if xdg-open is missing.

Inspect / manage (these report or act, then exit — no image pull, no secrets
needed):
  --doctor   Check the environment (Docker, compose, registry auth, .env keys,
             ports, disk) and print a PASS/WARN/FAIL report. An optional
             <host-repo-path> also checks that project's port; exits non-zero
             on any FAIL.
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
  --help     Show this help.

The image tag comes from IMAGE_TAG in .env (default 'latest'; pin e.g. 0.0.2).
The TUI is the default frontend — zero setup and always rooted at /workspace. The
web/desktop UI also works; a new session just defaults its working directory to /,
so click 'New session' and type /workspace to root that session at your repo.

First run creates .env from .env.example and prompts for your secrets; later
runs reuse it (edit by hand any time).
EOF
}
