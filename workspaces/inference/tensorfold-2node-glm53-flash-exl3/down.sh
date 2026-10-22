#!/usr/bin/env bash
# Stop BOTH ranks through the kit's stop.sh - it stops rank 1 on the worker
# over ssh, waits STOP_TIMEOUT for the prompt-state flush to spill cleanly,
# and archives each rank's gzipped log before `docker rm` deletes it. The
# fallback removes the containers by name and owns up to what it cannot do.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git}
KIT_SHA=3fd60dfc836fab0f1ed0fd4f0afaf2a1d62b2aab
KIT_NAME=glm53-flash-tensorfold

KD=$(kit_dir) || exit 1
if [[ -d $KD/.git ]] \
   && [[ $(git -C "$KD" rev-parse HEAD 2>/dev/null) == "$KIT_SHA" ]]; then
    exec "$KD"/stop.sh
fi

echo "kit tree missing or at another commit - stopping both containers directly," >&2
echo "without the worker-side stop, the state flush or the log archival." >&2
docker rm -f glm53-flash-tf >/dev/null 2>&1 && echo "rank 0 stopped" || echo "rank 0 not running"
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n ${peer:-} ]] && ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$peer" \
    "docker rm -f glm53-flash-tf >/dev/null 2>&1" && echo "rank 1 on $peer stopped" \
    || echo "rank 1: no peer reachable or not running"
