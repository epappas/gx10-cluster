#!/usr/bin/env bash
# Two-node tensor-parallel vLLM. Rank 0 here, rank 1 on the peer.
#
# BOTH RANKS ARE LAUNCHED FROM THIS ONE SCRIPT, on purpose. The recipe this is
# ported from keeps a .env file on each node and warns you to sync it before
# restarting, with both ranks needing an identical image digest - a real
# operational hazard with a silent failure mode (mismatched ranks hang at
# init). Generating both command lines from a single place removes the class of
# bug rather than documenting it.
#
# The launcher itself - RDMA device nodes, memlock, the gloo interface
# variables, the rendezvous split - lives in ../../lib/twonode.sh for the same
# reason, one level up: see its header. What stays here is the part that is
# actually about THIS model.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

NAME=ws-vllm-2node
IMAGE=${IMAGE:-vllm/vllm-openai:nightly-aarch64}
PORT=${PORT:-8888}

MODEL=${MODEL:-nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4}
SERVED=${SERVED_NAME:-nemotron-120b}

MODEL_ARGS=(
    --model "$MODEL" --served-model-name "$SERVED"
    --trust-remote-code
    --tensor-parallel-size 2 --pipeline-parallel-size 1
    --distributed-executor-backend mp
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.80}"
    --max-model-len "${MAX_MODEL_LEN:-131072}"
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"
    --enable-prefix-caching --enable-chunked-prefill
)

echo "model   $MODEL  TP=2"
twonode_up
echo
echo "75 GB of weights split two ways - expect minutes, not seconds."
