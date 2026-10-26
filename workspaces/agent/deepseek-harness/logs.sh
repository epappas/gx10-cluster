#!/usr/bin/env bash
# `ws logs` for a harness that may be on another node. `ws` runs its own
# compose command locally, which would look for a container that is not here.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

[[ -f .env ]] && { set -a; # shellcheck disable=SC1091
                   source .env; set +a; }

HARNESS_HOST=${HARNESS_HOST:-gb10-homer}

case $HARNESS_HOST in
    local|localhost|"$(hostname)"|"$(hostname -s)")
        exec docker logs "$@" ws-deepseek-harness
        ;;
    *)
        exec ssh -o BatchMode=yes "$HARNESS_HOST" docker logs "$@" ws-deepseek-harness
        ;;
esac
