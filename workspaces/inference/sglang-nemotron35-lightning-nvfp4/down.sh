#!/usr/bin/env bash
# Stop and remove the server. --restart unless-stopped means `docker stop`
# alone is not enough across a reboot, so this removes the container.
set -euo pipefail
docker rm -f "${NAME:-ws-sglang-nemotron35}" >/dev/null 2>&1 \
    && echo "removed ${NAME:-ws-sglang-nemotron35}" \
    || echo "nothing running"
