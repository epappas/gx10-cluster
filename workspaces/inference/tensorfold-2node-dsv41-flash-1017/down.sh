#!/usr/bin/env bash
# Stop both ranks through the kit's stop.sh (it archives each rank's log -
# here AND on the worker - before docker rm deletes them, keeps the newest
# LOG_KEEP, and counts running requests from /health first). The fallback
# says plainly what it cannot do.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks.git}
KIT_SHA=31eea4608f8bb292a92e2f7a1db400e928620c78
KIT_NAME=dsv41-1017-tensorfold
CONT=dsv41-1017-exl3-tf

KD=$(kit_dir) || exit 1
if [[ -d $KD/.git ]] \
   && [[ $(git -C "$KD" rev-parse HEAD 2>/dev/null) == "$KIT_SHA" ]]; then
    exec "$KD"/stop.sh
fi

echo "kit tree missing or at another commit - stopping both containers directly," >&2
echo "without the worker-side stop or the log archival." >&2
docker rm -f "$CONT" >/dev/null 2>&1 && echo "rank 0 stopped" || echo "rank 0 not running"
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n ${peer:-} ]] && ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$peer" \
    "docker rm -f $CONT >/dev/null 2>&1" && echo "rank 1 on $peer stopped" \
    || echo "rank 1: no peer reachable or not running"
