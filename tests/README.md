# Tests

Automated tests for `start.sh`, written with [bats](https://bats-core.readthedocs.io)
(Bash Automated Testing System). No Docker daemon and no Artifactory access are
required — a fake `docker` stands in for the real one.

## Run

```bash
./tests/run.sh            # whole suite
./tests/run.sh cli.bats   # one file
```

`run.sh` uses a system `bats` if you have one; otherwise it fetches `bats-core`
into `tests/.bats/` (gitignored) on first run. Installing bats yourself
(`brew install bats-core`, `apt install bats`, …) skips the fetch.

## What's covered

The suite has two styles:

| File | Style | Covers |
| --- | --- | --- |
| `unit_helpers.bats` | sources `start.sh`, calls helpers directly | transactional config TUI save/discard, exact two-button Dialog layout, whiptail-only fallback, secret-safe state labels, `derive_slug`, `sed_escape`, `set_env`/`get_env` round-trips, `find_free_port`, `project_running` (docker stubbed), `open_url` (opener stubbed via `PATH`/`OPENER`), `extra_packages_active`/`strip_pkg_comments`, `compute_base_image` (incl. digest-pinned `IMAGE_TAG`), `mask_secret`, `doctor_line`, `doctor_check_env_keys`, `doctor_check_env_drift`, `url_host`, `list_extra_allowlist_files`, `allowlist_summary_line`, `get_image_digest`/`short_digest`, `digest_state_file`/`report_digest_update`, `env_example_keys`/`check_env_drift` |
| `cli.bats` | runs a sandboxed copy of `start.sh` as a subprocess | arg parsing & errors, Docker preflight messages, Artifactory auth handling, slug → per-project env, IMAGE_TAG selection (incl. digest-pinned), user-layer and system-package overlay wiring, the first-run secrets flow, `--doctor` report (PASS/WARN/FAIL, exit code, secret masking), `--status` (single-project and all-stacks, incl. last-seen image digest), `--down`/`--stop` teardown, `--reconfigure` round-trip, `--show-allowlist` (LLM/Bitbucket hosts, local `extra-allowlist.d/*.conf` extensions, secret masking), boot-time allowlist summary line, image-digest print, update-nudge on digest change, `.env.example` drift warning, `--logs` (follow with the right `-p`, graceful when nothing is running), `--shell` (exec as `dev` rooted at `/workspace`, bash-then-sh fallback, graceful when not running), `--open` (launches the resolved opener with the web UI URL, warns but never fails the boot when the opener is missing) |
| `packaging.bats` | syntax/smoke-checks the onboarding helpers (not `start.sh` itself) | `completions/opencode-launcher.bash` and `.zsh` (`bash -n`/`zsh -n`, sources cleanly, mentions every flag); `install.sh` (`bash -n`, runs from an existing checkout without cloning, reports the same docker/daemon/compose-v2 checks as `start.sh`'s preflight, never overwrites an existing `.env` or `start.sh`, is idempotent across repeated runs, refuses to clone with the placeholder URL still set, leaves a pre-existing non-launcher directory untouched) |

This is the part of the system that's testable without infrastructure: the
script's own logic. Actually pulling images and booting the stack (does the
proxy block egress, does the UI come up on `:4096`) needs the real images and a
Docker daemon — that's a manual / CI-with-registry step, out of scope here.

## How the harness works

- **`fake-bin/docker`** — a stub on `PATH` that records every call's argv to
  `$FAKE_DOCKER_LOG` and returns a controllable exit code per subcommand
  (`info`, `compose`, `manifest`, `exec`, `image inspect`). Tests assert on the
  recorded calls and drive `start.sh` down specific branches (auth failure,
  daemon down, a changed/unchanged image digest, …). `FAKE_DOCKER_EXEC_PROBE_RC`
  controls the `--shell` bash-availability probe (`sh -c 'command -v bash'`)
  independently of `FAKE_DOCKER_EXEC_RC`, which controls the real interactive
  exec.
- **`fake-bin/xdg-open`** — a stub on `PATH` that records the URL it was asked
  to open to `$FAKE_XDG_OPEN_LOG` (exit code controllable via
  `FAKE_XDG_OPEN_RC`), so `--open` tests can assert on the URL without
  launching a real browser.
- **`common.bash`** — `make_sandbox` copies the launcher into a temp dir so
  `.env`/`.envs` writes stay isolated; `seed_env`, `make_repo_arg`,
  `run_launcher` are convenience helpers.
- **source-guard** — `start.sh` runs `main` only when executed directly, so the
  unit tests can `source` it for free.

## Adding a test

- Pure helper? Add to `unit_helpers.bats`: `source "$REPO_ROOT/start.sh"` then
  call it. Stub collaborators by redefining them as functions (see how
  `find_free_port` tests stub `port_in_use`).
- End-to-end behaviour? Add to `cli.bats`: `make_sandbox`, optionally
  `seed_env`, then `run_launcher …` and assert on `$status`, `$output`, the
  generated files, or `$FAKE_DOCKER_LOG`. Feed prompt answers with a stdin
  redirect (`run … < file`), never a pipe — a pipe puts `run` in a subshell and
  loses `$status`.
