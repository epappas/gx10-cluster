#!/usr/bin/env bash
# Copy this node's downloaded weights to the peer, over the 200 Gb/s cable.
#
# WHY THIS EXISTS HERE AND NOWHERE ELSE. Each rank loads from its own disk, so
# every two-node workspace needs the weights twice - and for the ~40-100 GiB
# checkpoints the others run, letting each node fetch its own copy from the Hub
# is fine, which is why they say nothing about it. At 164 GiB it stops being
# fine: the second copy is hours of WAN for bytes that are already sitting on a
# machine at the end of a cable measured at 22.7 GB/s.
#
#   hf download Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw   # once, here
#   ./stage-weights.sh                                   # then to the peer
#
# rsync is resumable and idempotent - an interrupted transfer costs only time,
# and re-running verifies what is already there rather than resending it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

MODEL=${MODEL:-Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw}
DRAFT_MODEL=${DRAFT_MODEL:-incoai/GLM-5.3-Flash-DFlash2}

twonode_stage_model "$MODEL"
# The drafter is ~2.3 GiB and BOTH ranks load a shard of it at the default
# draft_tensor_parallel_size=2. Even at DRAFT_TP=1, where only rank 0 holds it,
# rank 1 still resolves the speculative config at init - so a missing repo on
# the peer fails the launch rather than degrading it, either way.
[[ ${SPEC_METHOD:-dflash} == dflash ]] && twonode_stage_model "$DRAFT_MODEL"
echo
echo "both nodes now hold the weights. ws check on EACH node before starting."
