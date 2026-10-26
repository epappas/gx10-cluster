#!/usr/bin/env bash
# Stop the harness wherever up.sh put it. Called by `ws down deepseek-harness`.
#
# The container is removed; the image and dsh-home/ (config, credentials,
# sessions) stay. `ws` itself only ever speaks to the local docker, which is
# why a workspace that can run on another node ships this instead.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

[[ -f .env ]] && { set -a; # shellcheck disable=SC1091
                   source .env; set +a; }

HARNESS_HOST=${HARNESS_HOST:-gb10-homer}
REMOTE_DIR=${REMOTE_DIR:-ws-deepseek-harness}
PROJECT=ws-deepseek-harness

case $HARNESS_HOST in
    local|localhost|"$(hostname)"|"$(hostname -s)")
        docker compose --project-name "$PROJECT" down
        ;;
    *)
        ssh -o BatchMode=yes "$HARNESS_HOST" \
            "cd '$REMOTE_DIR' && docker compose --project-name '$PROJECT' down"
        ;;
esac
