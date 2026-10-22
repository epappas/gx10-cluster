#!/usr/bin/env bash
# Stop the server with the KIT's stop.sh - it archives the container log
# (gzipped, newest 10) before `docker rm` deletes it, which a bare `docker
# rm -f` does not. Fall back to docker only when the kit tree is gone, and
# say so, because the archived log is the thing you want after a freeze.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold.git}
KIT_SHA=656879fd752749bbd11a6e1a065a326c00940911
KIT_NAME=qwen38-flash-next-tf

KD=$(kit_dir) || exit 1
if [[ -d $KD/.git ]] \
   && [[ $(git -C "$KD" rev-parse HEAD 2>/dev/null) == "$KIT_SHA" ]]; then
    exec "$KD"/stop.sh
fi

echo "kit tree missing or at another commit - stopping the container directly," >&2
echo "without the log archival the kit's stop.sh would have run." >&2
docker rm -f qwen38-flash-next-tf >/dev/null 2>&1 && echo "qwen38-flash-next-tf stopped" \
    || echo "qwen38-flash-next-tf not running"
