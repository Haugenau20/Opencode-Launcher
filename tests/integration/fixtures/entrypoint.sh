#!/bin/sh
set -eu
# Exercise the production image's initialization contract: container root
# initializes only managed state, then drops to the configured application IDs.
test "$(id -u)" = 0
mkdir -p /home/dev/.local/share/opencode /home/dev/.config/opencode
chown "$HOST_UID:$HOST_GID" /home/dev/.local/share/opencode /home/dev/.config/opencode
exec su-exec "$HOST_UID:$HOST_GID" python /fixture/app.py
