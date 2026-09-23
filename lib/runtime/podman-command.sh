#!/usr/bin/env bash
# Executable selected explicitly by podman-compose. Its --podman-args option
# puts options after the subcommand; global engine options must come first.
exec env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman --remote=false "$@"
