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
  --also
  --exec
  --doctor
  --status
  --down --stop
  --logs
  --shell
  --reconfigure
  --config
  --show-allowlist
  --mfiles-token
  --symphony
  --help -h
)

# Verbs --symphony accepts as its immediately-following argument. Keep in
# sync with cmd_symphony's case in ../lib/symphony.sh.
_opencode_launcher_symphony_verbs=(
  check up logs status stop down add init
)

_opencode_launcher_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"

  # Right after --symphony, offer its verbs instead of directories/flags —
  # everything past the verb is that verb's own argument shape (a repo path,
  # then for `add` free text), which generic completion can't usefully help
  # with, so no further special-casing beyond this one slot.
  if [[ "$prev" == "--symphony" ]]; then
    COMPREPLY=($(compgen -W "${_opencode_launcher_symphony_verbs[*]}" -- "$cur"))
    return 0
  fi

  # Only start.sh itself takes a flag right after it; once a non-flag word
  # (the repo path) has been typed, just keep offering directories.
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "${_opencode_launcher_flags[*]}" -- "$cur"))
    return 0
  fi

  # --also takes a <path>[:rw] argument — directory completion, same as the
  # repo path (a trailing :rw is typed by hand, not completed). --exec takes
  # a free-text <prompt> argument, which has no useful completion, so it
  # falls through to directory completion too (harmless: it just offers
  # nothing useful rather than something wrong).
  # <host-repo-path>: native directory completion (compgen -d), matching
  # every flag above that takes a repo path argument.
  COMPREPLY=($(compgen -d -- "$cur"))
}

complete -F _opencode_launcher_complete start.sh
complete -F _opencode_launcher_complete ./start.sh
