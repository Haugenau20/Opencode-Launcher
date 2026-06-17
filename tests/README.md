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
| `unit_helpers.bats` | sources `start.sh`, calls helpers directly | `derive_slug`, `sed_escape`, `set_env`/`get_env` round-trips, `find_free_port`, `extra_packages_active`/`strip_pkg_comments`, `compute_base_image`, `doctor_line`, `doctor_check_env_keys`, `doctor_check_port` |
| `cli.bats` | runs a sandboxed copy of `start.sh` as a subprocess | arg parsing & errors, Docker preflight messages, Artifactory auth handling, slug → per-project env, IMAGE_TAG selection, user-layer and system-package overlay wiring, the first-run secrets flow, `--doctor` report (PASS/WARN/FAIL, exit code, secret masking) |

This is the part of the system that's testable without infrastructure: the
script's own logic. Actually pulling images and booting the stack (does the
proxy block egress, does the UI come up on `:4096`) needs the real images and a
Docker daemon — that's a manual / CI-with-registry step, out of scope here.

## How the harness works

- **`fake-bin/docker`** — a stub on `PATH` that records every call's argv to
  `$FAKE_DOCKER_LOG` and returns a controllable exit code per subcommand
  (`info`, `compose`, `manifest`, `exec`). Tests assert on the recorded calls
  and drive `start.sh` down specific branches (auth failure, daemon down, …).
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
