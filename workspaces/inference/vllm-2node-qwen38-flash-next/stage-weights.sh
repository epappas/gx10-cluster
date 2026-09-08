#!/usr/bin/env bash
# Copy this node's downloaded weights to the peer, over the 200 Gb/s cable.
#
# 133 GiB, and each rank loads from its own disk - nothing about the HF cache
# is shared between them. Off a cold cache with no staging both ranks fetch
# their own copy from the Hub, which is the WAN paid twice for bytes already
# sitting on a machine at the end of an idle, trusted cable. Measured on the
# DeepSeek workspace: ~56 MB/s per rank over WAN against 534 MB/s over the
# interconnect.
#
#   ~/venvs/ml/bin/hf download nvidia/Qwen3.8-Flash-Next-NVFP4   # once, here
#   ./stage-weights.sh                                           # to the peer
#
# up.sh calls this itself on a cold cache, so the fast path is the default
# rather than a step to remember. rsync is resumable and idempotent - an
# interrupted transfer costs only time.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

MODEL=${MODEL:-nvidia/Qwen3.8-Flash-Next-NVFP4}
twonode_stage_model "$MODEL"
echo
echo "both nodes now hold the weights. ws check on EACH node before starting."
