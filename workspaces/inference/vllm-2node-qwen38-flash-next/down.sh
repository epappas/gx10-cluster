#!/usr/bin/env bash
# Stop both ranks. The JIT/autotune cache in ~/.cache/vllm-qwen38-fn is the
# only per-node state that carries over, and it is worth keeping - FlashInfer
# autotunes on the first real request, not at boot.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh
twonode_down ws-vllm-qwen38-fn
