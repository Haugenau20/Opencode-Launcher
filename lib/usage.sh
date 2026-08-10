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
  ./start.sh --exec "<prompt>" [--continue] [--persist] [--also <path>[:rw]]... [<host-repo-path>]
  ./start.sh --doctor [<host-repo-path>]
  ./start.sh --status [<host-repo-path>]
  ./start.sh --down|--stop <host-repo-path>
  ./start.sh --logs <host-repo-path>
  ./start.sh --shell <host-repo-path>
  ./start.sh --reconfigure
  ./start.sh --config
  ./start.sh --show-allowlist [<host-repo-path>]
  ./start.sh --mfiles-token
  ./start.sh --symphony init <host-repo-path>
  ./start.sh --symphony check|up|logs|status|stop|down <host-repo-path>
  ./start.sh --symphony add <host-repo-path> "what the agent should do" [--id ID] [--title TITLE]
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
             Also bind-mount an extra host folder at /workspace-extra/<name>,
             read-only unless you append :rw. Repeatable.
  --exec "<prompt>"
             Run <prompt> once via `opencode run` and exit with its code.
             <host-repo-path> is optional; omit it for an empty /workspace.

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
  --mfiles-token
             Mint an M-Files authentication token from your vault credentials
             (prompts for base URL, username, domain, vault GUID, and your
             password, input hidden) and write it straight into
             MFILES_BASE_URL/MFILES_PAT in .env — no copy-paste. The setup
             wizard and --reconfigure offer the same mint on a real terminal;
             this is for rotating an expired token on its own.
  --version  Print the launcher version (from the VERSION file). Alias: -V.
  --help     Show this help.

Symphony (opt-in unattended orchestrator — read docs/SYMPHONY.md in
OpenCode-Setup before the first run, especially the GitLab-token scoping):
  --symphony init <host-repo-path>
             Scaffold .symphony/<slug>/{config,queue,workspaces} for this repo
             and print the next steps (copy a WORKFLOW.md template, edit it).
  --symphony check <host-repo-path>
             Preflight only — changes nothing. Refuses on a missing
             WORKFLOW.md, a gitlab tracker with no SYMPHONY_GITLAB_TOKEN, a
             workspaces path that IS the repo, or an agent env file readable
             from the config mount; warns on the quieter mistakes (a
             SYMPHONY_* key leaked into an agent-visible file, the same token
             used for symphony and the agent, GIT_REMOTE_ALLOWLIST and
             GITLAB_WRITE_PROJECTS disagreeing).
  --symphony up <host-repo-path>
             Preflight, then start opencode + squid + symphony (headless — no
             web UI is published; symphony runs unattended).
  --symphony logs <host-repo-path>
             Follow the symphony container's log. Ctrl-C detaches.
  --symphony status <host-repo-path>
             Per-state queue counts (file_queue) or the tracker's project
             (gitlab), plus whether the symphony container is running.
  --symphony stop <host-repo-path>
             Stop the symphony container only; opencode/squid keep running.
  --symphony down <host-repo-path>
             Tear down the whole stack (opencode + squid + symphony).
  --symphony add <host-repo-path> "<what the agent should do>" [--id ID] [--title TITLE]
             Queue a new file_queue item in todo/. Refuses under tracker:
             gitlab — there, work items are GitLab issues, not files.

  Symphony's own settings (above all SYMPHONY_GITLAB_TOKEN) live in
  .symphony/<slug>/symphony.env and are NEVER added to .env/.env.example —
  that file must stay out of the agent's container environment
  (.envs/<slug>.env). See docs/SYMPHONY.md ("two tokens, neither able to do
  the other's job") for why.

Notes:
  * Image: IMAGE_TAG in .env picks the version (default 'latest'; pin e.g.
    IMAGE_TAG=0.0.2).
  * First run creates .env from .env.example and prompts for secrets; later
    runs reuse it.
  * Web/desktop UI: give a new session the working directory /workspace (the
    default TUI is always rooted there).
  * Each interactive boot offers to bring the launcher/image up to latest (the
    only tested pairing) and restart into it when either is behind; after a
    launcher upgrade it also offers to set any config keys new since your old
    version. A headless/CI boot just prints a nudge. Set OC_SKIP_UPDATE_CHECK=1
    to skip.
EOF
}
