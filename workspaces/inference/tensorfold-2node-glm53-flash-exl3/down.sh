#!/usr/bin/env bash
# Stop BOTH ranks through the kit's stop.sh - it stops rank 1 on the worker
# over ssh, waits STOP_TIMEOUT for the prompt-state flush to spill cleanly,
# and archives each rank's gzipped log before `docker rm` deletes it. The
# fallback removes the containers by name and owns up to what it cannot do.
# Either way the memory guards go last, so a rank is never stopping unguarded.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh
# shellcheck source-path=SCRIPTDIR source=memory_guard.sh
source ./memory_guard.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git}
KIT_SHA=3fd60dfc836fab0f1ed0fd4f0afaf2a1d62b2aab
KIT_NAME=glm53-flash-tensorfold

KD=$(kit_dir) || exit 1
# The pair from the inventory - the SAME kit_pair up.sh calls (lib/kit.sh):
# the kit's stop.sh stops rank 1 only through WORKER, and a down.sh that
# never set it would leave rank 1 alone with a WARN (1017, 2026-10-24 - the
# same drift, caught here before it needed to be). Soft on purpose: a missing
# peer line must not stop stop.sh from stopping rank 0.
kit_pair || true
if [[ -d $KD/.git ]] \
   && [[ $(git -C "$KD" rev-parse HEAD 2>/dev/null) == "$KIT_SHA" ]]; then
    status=0
    "$KD"/stop.sh || status=$?
    memory_guard_down
    exit "$status"
fi

echo "kit tree missing or at another commit - stopping both containers directly," >&2
echo "without the worker-side stop, the state flush or the log archival." >&2
docker rm -f glm53-flash-tf >/dev/null 2>&1 && echo "rank 0 stopped" || echo "rank 0 not running"
if [[ -n ${WORKER:-} ]]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" \
        "docker rm -f glm53-flash-tf >/dev/null 2>&1" && echo "rank 1 on $WORKER stopped" \
        || echo "rank 1 on $WORKER: unreachable or not running"
else
    echo "rank 1: no peer in the interconnect inventory - nothing to reach it with" >&2
fi
memory_guard_down
