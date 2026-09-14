#!/usr/bin/env bash
# DeepSeek-V4.1-Flash at EXL3 mul1 2.9 bpw across BOTH nodes, TP=2 over RoCE.
#
# Ported from MiaAI-Lab/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks, the fourth
# recipe from that lab this repo has mined (docs/decisions.md#two-node-vllm,
# #glm53-flash, #qwen38-flash-next). What was taken and what was left behind is
# at docs/decisions.md#dsv41-flash-exl3.
#
# THIS HAS NOT BEEN RUN HERE. The flags are theirs and were measured on this
# exact hardware; the launcher, the staging order and the three lowered
# defaults are ours. workspace.yml says why it has not booted: the checkpoint
# and its Engram tables do not fit on either node as they stand.
#
# The launcher is shared (../../lib/twonode.sh). Only the flags below are ours.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

NAME=ws-vllm-dsv41-exl3

# The overlay image, and the same exception #glm53-flash argued for: upstream
# vLLM has no `exl3` quantisation method, and the E3 v2 grouped fat-expert
# kernels, the 64-token KV envelope and the file-backed Engram loader do not
# exist outside this build. Digest-pin it in .env for the stronger guarantee;
# both ranks pull the same tag either way, which is the property that matters.
#
# Runs as root for the same narrow reason GLM-5.3 does: the overlay writes into
# dist-packages at start. Weights are staged on the host as you, before any
# container starts, so the 243 GiB stays yours.
export GX10_CONTAINER_ROOT=1

IMAGE=${IMAGE:-ghcr.io/miaai-lab/deepseek-v4.1-flash-exl3-2x-dgx-sparks:2.9bpw}
PORT=${PORT:-8897}
SERVED=${SERVED_MODEL_NAME:-DeepSeek-v4.1-Flash-EXL3}

# MODEL MUST BE A PATH, NOT A REPO ID - the same trap #glm53-flash paid for.
# The overlay's loader joins the model string with a filename instead of
# resolving through the Hub, so a repo id becomes a FileNotFoundError on a
# file that is present both locally and on the Hub. stage-weights.sh resolves
# the snapshot and writes MODEL into .env for you.
MODEL=${MODEL:-}
ENGRAM_PACKED=${ENGRAM_PACKED:-$HOME/.cache/dsv41-exl3/engram-packed}

if [[ -z $MODEL || ! -d $MODEL ]]; then
    cat >&2 <<'MSG'
MODEL is unset or not a directory.

This workspace does NOT download its own weights, and that is deliberate: the
checkpoint is 196 GiB, the Engram build input is another 189 GiB, and the order
those two land in decides whether the node runs out of disk. ./stage-weights.sh
sequences it and writes MODEL into .env.

  ./stage-weights.sh --plan     what it will do, and the free space it needs
  ./stage-weights.sh            do it
MSG
    exit 1
fi
[[ -d $ENGRAM_PACKED ]] || {
    echo "packed Engram tables missing at $ENGRAM_PACKED" >&2
    echo "  ./stage-weights.sh --pack   builds them (~96 GiB per rank, two layers)" >&2
    exit 1
}

JIT_CACHE=${JIT_CACHE:-$HOME/.cache/vllm-dsv41-exl3}
PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' \
    "${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}" 2>/dev/null || true)}
mkdir -p "$JIT_CACHE/triton" "$JIT_CACHE/tilelang"
if [[ -n ${PEER:-} ]]; then
    # Best effort: a missing cache on the peer costs a re-JIT, never
    # correctness. Do not fail launch on it.
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$PEER" \
        "mkdir -p $(printf '%q' "$JIT_CACHE/triton") $(printf '%q' "$JIT_CACHE/tilelang")" \
        2>/dev/null || true
fi

# BOTH RANKS MUST SEE THE SAME PATHS, and on this cluster one of them gets
# there over NFS. twonode.sh builds ONE docker command and runs it on both
# nodes, so a mount that exists here and not on the peer fails at model load
# rather than at launch - seven minutes in, as a worker init error that says
# nothing about a missing directory.
#
# The peer holds its own ~96 GiB packed Engram shard (node-local, because every
# miss there would otherwise be an NFS round trip - that is the entire reason
# packing exists) and reads the 196 GiB checkpoint from rank 0. It cannot hold
# a replica: see THE DISK ARITHMETIC in workspace.yml.
#
# `-r` not `-d`: an NFS mount that dropped leaves the mountpoint present and
# empty, which `-d` calls success and the loader calls a missing weight file.
if [[ -n ${PEER:-} ]]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$PEER" \
        "[ -r $(printf '%q' "$MODEL/config.json") ] && [ -d $(printf '%q' "$ENGRAM_PACKED") ]" \
        || { echo "peer $PEER cannot read $MODEL, or is missing $ENGRAM_PACKED" >&2
             echo >&2
             echo "  the checkpoint reaches the peer over NFS - it does not fit twice." >&2
             echo "  that export is Ansible's half:" >&2
             echo "    make optional TAGS=nfs -e nfs_export_path=$MODEL" >&2
             echo >&2
             echo "  the packed Engram shard IS this script's half:" >&2
             echo "    ./stage-weights.sh --peer" >&2
             exit 1; }
fi

EXTRA_MOUNTS=(
    -v "$MODEL:$MODEL:ro"
    -v "$ENGRAM_PACKED:/opt/dsv41/engram:ro"
    -v "$JIT_CACHE/triton:/root/.triton/cache"
    -v "$JIT_CACHE/tilelang:/root/.tilelang/cache"
)

EXTRA_ENV=(
    # The `a` suffix is load-bearing, for the reason #glm53-flash records: the
    # EXL3 trellis kernels are built for 12.1a and Blackwell's FP4 instructions
    # are not forward-compatible from 12.1.
    -e "TORCH_CUDA_ARCH_LIST=12.1a"
    -e "FLASHINFER_CUDA_ARCH_LIST=12.1a"
    -e "FLASHINFER_DISABLE_VERSION_CHECK=1"
    -e "TRITON_CACHE_DIR=/root/.triton/cache"
    -e "TILELANG_CACHE_DIR=/root/.tilelang/cache"

    -e "ENGRAM_DIR=/opt/dsv41/engram"

    # BOTH OF THESE ARE MANDATORY UPSTREAM, and both are deadlock fixes rather
    # than tuning. Serial EXL3 streams prevent a dual-stream CUDA deadlock; the
    # shared-experts stream is the same hazard from vLLM's side.
    -e "DSV41_EXL3_SERIAL_STREAMS=1"
    -e "VLLM_DISABLE_SHARED_EXPERTS_STREAM=1"

    # E3 v2 grouped fat-expert kernels. E2 (EXL3_FAT_KERNEL) is K4/MCG-only and
    # does not apply to this mul1 K2/K3 tree - setting it is not a speedup, it
    # is a no-op that hides the grouped path.
    -e "EXL3_FUSED_MOE=${EXL3_FUSED_MOE:-1}"
    -e "EXL3_FAT_KERNEL=0"
    -e "EXL3_FAT_GROUPED=${EXL3_FAT_GROUPED:-1}"
    # Must stay >= MAX_NUM_SEQS x (DSPARK_TOKENS+1) so a decode step remains a
    # single fused launch. At the shipped 2 x 4 that floor is 8; 16 keeps room
    # to raise --max-num-seqs without silently splitting decode.
    -e "EXL3_TEMP_ROWS_FUSED=${EXL3_TEMP_ROWS_FUSED:-16}"

    # Thread pool for packed Engram reads. Upstream tuned 96 on their kit; GB10
    # has 20 cores, so this is one of the few upstream numbers that is about
    # THEIR machine rather than this architecture. Left at their value because
    # the reads are I/O-bound on NVMe, not CPU-bound - but it is the first knob
    # to question if prefill is slower here than their table.
    -e "DSV41_IO_THREADS=${DSV41_IO_THREADS:-96}"

    # A cold Triton/TileLang JIT on TP=2 outlasts EngineCore's stock 300 s
    # execute timeout, which turns a slow compile into a reported hang. NCCL's
    # own 600 s watchdog still backstops a real one.
    -e "VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=${EXECUTE_MODEL_TIMEOUT:-1800}"
)

MODEL_ARGS=(
    --model "$MODEL" --served-model-name "$SERVED"
    --tensor-parallel-size 2 --pipeline-parallel-size 1
    --distributed-executor-backend mp

    # `exl3`, and never marlin. The wrong method here does not fall back - it
    # loads the routed experts as BF16 and the model stops fitting on two nodes.
    --quantization "${QUANTIZATION:-exl3}"

    # 0.86, LOWERED FROM UPSTREAM'S 0.88, and this is a sanity check rather
    # than a budget: with --kv-cache-memory-bytes pinned below, vLLM only uses
    # this to assert MemAvailable at init >= util x 121.69 GiB. 0.88 asks for
    # 107.1 GiB free. ../vllm-2node-glm53-flash-exl3 measured 0.87 (105.8 GiB)
    # being refused on these nodes with 104.87 GiB free, so 0.88 would fail here
    # for a reason that has nothing to do with this model.
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.86}"

    # 128K, NOT the 600K upstream validated. Their own .env calls 128k the
    # "first clean boot" target and 600k the setting reached by raising one
    # knob at a time while watching low-water MemAvailable - on a budget whose
    # headroom is 4.07 GiB and whose failure mode, recorded in their
    # HANDOFF.md, was both nodes wedging. This repo ships the first-boot number
    # and documents the ladder. See .env.example for the order.
    --max-model-len "${MAX_MODEL_LEN:-131072}"

    # Two in-flight generations. Not a typo and not timidity: at ~99.5 GiB of
    # resident weights per rank there is no batch to be had, and upstream's own
    # measurement says a third stream costs more than it earns.
    --max-num-seqs "${MAX_NUM_SEQS:-2}"

    # The V4.1 indexer scores every chunk row against the WHOLE prefix, so the
    # activation peak grows with chunk x context. 2048 is upstream's first-boot
    # value at 128k; their 600k profile drops to 1024 because that product is
    # the thing that grew. If you raise --max-model-len, lower this first.
    #
    # FLOOR: with the vision tower enabled vLLM needs >= max image tokens + 1
    # (1025), so 1024 is rejected and 1536 is the smallest round value. We serve
    # text-only, which is what makes 1024 legal in their 600k profile at all.
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-2048}"

    # Cap one request's tokens per step, so a short chat sent during a long
    # prefill does not wait for the whole prefill. Upstream measured 216 s
    # against ~4 s, for ~6% off solo prefill. Keep
    # MAX_NUM_BATCHED_TOKENS - this >= 256.
    --long-prefill-token-threshold "${LONG_PREFILL_TOKEN_THRESHOLD:-1792}"

    # PINNED, and the pin is the point. V4.1 keeps KV only on the kv_source
    # layers (~1.63 KB/token), so 1 GiB is ~658k tokens - comfortably 4 x 128k.
    # Unpinned, vLLM sizes the pool from host MemAvailable after a profile run,
    # which on unified memory drifts with the page cache: the same command
    # yields a different pool on Tuesday and Wednesday. Upstream's 600k profile
    # uses 2.5 GiB (774,400 tokens); raise this with --max-model-len, not before.
    --kv-cache-memory-bytes "${KV_CACHE_MEMORY_BYTES:-1073741824}"

    # 64, and only 32 or 64 are valid. The SM12x DeepGEMM paged indexer kernel
    # takes 32 or 64 states per block; 128 - the vLLM default on other hardware
    # - dies on the first decode of the ratio-1 indexer layers. This is an
    # architecture fact, not a tuning knob.
    --block-size "${KV_BLOCK_SIZE:-64}"

    # Native KV is CSA2 at ~890 B/token FP4. Do NOT copy GLM-5.3's fp8_ds_mla
    # here: that is a different sparse-MLA envelope for a different model, and
    # #glm53-flash's note that the SM12x kernel accepts only packed fp8_ds_mla
    # is a statement about NoPE-MLA, not about this checkpoint.

    # DeepSeek-V4.1-specific parsers. The version suffix is not interchangeable
    # with the v4 ones the ../vllm-2node-deepseek-v4-flash workspace uses.
    --tokenizer-mode "${TOKENIZER_MODE:-deepseek_v41}"
    --tool-call-parser "${TOOL_CALL_PARSER:-deepseek_v41}" --enable-auto-tool-choice
    --reasoning-parser "${REASONING_PARSER:-deepseek_v41}"

    --enable-prefix-caching
)

# DSpark drafts from MTP experts already in the checkpoint - no second repo to
# download, unlike GLM-5.3's DFlash2. Upstream measured it 2026-09-12 on prose:
#
#   one stream    k=3  28 tok/s   k=5  25   none 23   -> k=3 wins
#   four streams  none 54 aggregate > k=3 42          -> k=3 LOSES
#
# So this is the rare speculator that is a per-workload choice rather than a
# strict win, and the crossover is inside the concurrency range this workspace
# supports. Interactive: leave it. Serving four streams: SPEC_METHOD=none.
case "${SPEC_METHOD:-dspark}" in
  dspark)
    MODEL_ARGS+=( --speculative-config \
        "{\"method\":\"dspark\",\"num_speculative_tokens\":${DSPARK_TOKENS:-3}}" )
    ;;
  none) ;;
  *) echo "SPEC_METHOD must be dspark or none" >&2; exit 1 ;;
esac

# CUDA graphs must capture the DECODE BATCH SHAPE the speculator produces: k=3
# emits 4 tokens per sequence, so 1..2 sequences are 4 and 8. Capture the wrong
# ladder and every decode step falls back to eager, which reads as the graphs
# simply not helping. Upstream autotunes 130 distinct EXL3 shapes before
# capture, so the first boot is slow whatever this is set to.
if [[ ${ENFORCE_EAGER:-0} == 1 ]]; then
    MODEL_ARGS+=( --enforce-eager )
elif [[ ${SPEC_METHOD:-dspark} == none ]]; then
    MODEL_ARGS+=( --cudagraph-capture-sizes 1 2 4 )
else
    MODEL_ARGS+=( --cudagraph-capture-sizes 1 2 4 8 )
fi

echo "model   $MODEL"
echo "        EXL3 mul1 2.9bpw, 196 GiB, TP=2 -> ~99.5 GiB per node"
echo "engram  $ENGRAM_PACKED (packed, file-backed - NOT resident)"
echo "spec    ${SPEC_METHOD:-dspark}  (k=${DSPARK_TOKENS:-3}; acceptance is the only number that proves it)"
echo
echo "HEADROOM IS ~4 GiB PER NODE. Watch it during the first long prefill:"
echo "  watch -n5 'ssh poseidon free -g; free -g'"
echo
twonode_up
echo
echo "then ask the three questions a tok/s number cannot answer:"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up spec-decode-accept   # is the drafter working?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate    # is it answering correctly?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-prefill-ladder --chunk-tokens ${MAX_NUM_BATCHED_TOKENS:-2048}"
