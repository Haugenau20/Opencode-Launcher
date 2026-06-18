#compdef start.sh ./start.sh
#
# Zsh completion for start.sh.
#
# Install (pick one):
#   source completions/opencode-launcher.zsh                    # this session only
#   echo 'source /path/to/completions/opencode-launcher.zsh' >> ~/.zshrc
#   # or drop it on your $fpath as a function named _start.sh / _opencode-launcher
#   # and let compinit pick it up (rename the file to drop the .zsh extension).
#
# Completes every flag start.sh accepts, then falls back to directory
# completion for the <host-repo-path> argument. The flag list below is a
# maintained static copy — keep it in sync with usage() in ../start.sh
# whenever a flag is added/removed/renamed there.

_opencode_launcher() {
  local -a flags
  flags=(
    '--continue:resume your most recent opencode session'
    '-c:resume your most recent opencode session'
    '--persist:keep the stack running after you exit the TUI'
    '--web:keep the stack running after you exit the TUI'
    '--detach:boot without attaching the TUI'
    '--no-tui:boot without attaching the TUI'
    '--podman:force the Podman (keep-id userns) overlay'
    '--tui:attach the TUI (default; back-compat no-op)'
    '--open:open the web UI URL in your default browser'
    '--doctor:run environment checks and print a PASS/WARN/FAIL report'
    '--status:report on running launcher stacks'
    '--down:tear down the stack for a repo path'
    '--stop:tear down the stack for a repo path'
    '--logs:tail the running stack'\''s logs'
    '--shell:open an interactive shell in the running container'
    '--reconfigure:re-run the secrets setup wizard'
    '--config:print a read-only dashboard of every .env setting'
    '--show-allowlist:print the configured outbound egress allowlist'
    '--help:show usage'
    '-h:show usage'
  )

  _arguments -s \
    "${flags[@]}" \
    '*:host-repo-path:_directories'
}

# Only invoke when running inside zsh's completion system (i.e. _arguments is
# available). Plain `source`-ing this file (e.g. a syntax smoke test) must be
# a no-op rather than erroring with "command not found: _arguments".
if whence -w _arguments >/dev/null 2>&1; then
  _opencode_launcher "$@"
fi
