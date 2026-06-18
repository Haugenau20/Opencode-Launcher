# Bash completion for start.sh.
#
# Install (pick one):
#   source completions/opencode-launcher.bash                  # this session only
#   echo 'source /path/to/completions/opencode-launcher.bash' >> ~/.bashrc
#   sudo cp completions/opencode-launcher.bash /etc/bash_completion.d/opencode-launcher
#
# Completes every flag start.sh accepts, then falls back to directory
# completion for the <host-repo-path> argument. The flag list below is a
# maintained static copy — keep it in sync with usage() in ../start.sh
# whenever a flag is added/removed/renamed there.

_opencode_launcher_flags=(
  --continue -c
  --persist --web
  --detach --no-tui
  --podman
  --tui
  --open
  --doctor
  --status
  --down --stop
  --logs
  --shell
  --reconfigure
  --config
  --show-allowlist
  --help -h
)

_opencode_launcher_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"

  # Only start.sh itself takes a flag right after it; once a non-flag word
  # (the repo path) has been typed, just keep offering directories.
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "${_opencode_launcher_flags[*]}" -- "$cur"))
    return 0
  fi

  # <host-repo-path>: native directory completion (compgen -d), matching
  # every flag above that takes a repo path argument.
  COMPREPLY=($(compgen -d -- "$cur"))
}

complete -F _opencode_launcher_complete start.sh
complete -F _opencode_launcher_complete ./start.sh
