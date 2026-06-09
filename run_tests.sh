#!/usr/bin/env bash
#
# run_tests.sh — run the start.sh test suite.
#
#   ./run_tests.sh            # run everything
#   ./run_tests.sh cli.bats   # run one file
#
# Thin wrapper around tests/run.sh (which fetches bats-core on first run if you
# don't already have bats installed).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
exec "$HERE/tests/run.sh" "$@"
