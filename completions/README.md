# Shell completion

Tab-completion for `start.sh`'s flags (bash and zsh). After flags, both
complete a directory for the `<host-repo-path>` argument using the shell's
native directory completion — no extra dependencies.

The flag lists in both scripts are maintained as static arrays. If `start.sh`
gains/renames/drops a flag, update `usage()` there first, then mirror the
change in `opencode-launcher.bash` and `opencode-launcher.zsh` (each file has
a comment pointing back here).

## Bash

```bash
# this session only
source completions/opencode-launcher.bash

# every new shell
echo 'source /path/to/opencode-launcher/completions/opencode-launcher.bash' >> ~/.bashrc

# system-wide (if your distro sources /etc/bash_completion.d)
sudo cp completions/opencode-launcher.bash /etc/bash_completion.d/opencode-launcher
```

## Zsh

```zsh
# this session only
source completions/opencode-launcher.zsh

# every new shell
echo 'source /path/to/opencode-launcher/completions/opencode-launcher.zsh' >> ~/.zshrc

# or drop it on your $fpath as a compdef function (rename without the .zsh
# extension, e.g. to `_opencode-launcher`) and let `compinit` autoload it.
```

Both scripts complete `start.sh` and `./start.sh` by name; if you invoke the
launcher some other way (a symlink, an alias), add a `complete`/`compdef` line
for that name alongside the ones already in the script.
