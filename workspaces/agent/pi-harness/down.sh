#!/usr/bin/env bash
# `ws up` runs pi in the foreground with --rm, so quitting the TUI IS the
# normal stop and there is usually nothing here to do. This exists for the
# other case: a session detached with Ctrl-P Ctrl-Q, or a `-p` run left going
# by a terminal that died, holding the container name the next `ws up` needs.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

CONTAINER=${PI_CONTAINER:-ws-pi-harness}

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER"
else
    echo "no container '$CONTAINER' - nothing to stop"
fi

# The IMAGE is deliberately left alone: it is the npm install that `ws up`
# would otherwise redo, and `docker rmi ws-pi-harness:<version>` is one command
# when you actually want the space back.
