#!/usr/bin/env bash
# Qwen3.8-Flash-Next NVFP4 across BOTH nodes, tensor-parallel over RoCE.
#
# Ported from MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks, which is the only
# published two-node GB10 configuration for this model. What was taken and what
# was left is at docs/decisions.md#qwen38-flash-next. The short version: the
# FLAGS and the arithmetic behind them are ported, the LAUNCHER is ours, and
# the five patches are re-implemented from the documented mechanism rather than
# copied - their repo is AGPL-3.0-or-later and this one is MIT.
#
# The launcher is shared (../../lib/twonode.sh). Only the flags below are ours.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

NAME=ws-vllm-qwen38-fn
IMAGE=${IMAGE:-vllm/vllm-openai:qwen38-flash-next}
PORT=${PORT:-8896}

MODEL=${MODEL:-nvidia/Qwen3.8-Flash-Next-NVFP4}
SERVED=${SERVED_NAME:-qwen3.8-flash-next}

# THIS IMAGE MUST RUN AS ROOT, for the same reason the GLM-5.3 one does: the
# patches below rewrite files inside /usr/local/lib/python3.12/dist-packages,
# and twonode_launch otherwise passes --user "$(id -u):$(id -g)". Safe HERE
# specifically because up.sh downloads and stages the weights on the host as
# you, before any container starts, so the 133 GiB stays yours.
export GX10_CONTAINER_ROOT=1

# ---------------------------------------------------------------------------
# PREFLIGHT 1: is anything else holding a GPU, on EITHER node?
#
# This is the check this repo did not have and this model is the reason to add
# it. `ws check` says outright that it can only measure THIS node, and on
# unified memory a peer with a desktop session resident is not a slow launch -
# it is rank 1 refusing at the memory check about a minute in, which rank 0
# then reports as a gloo "Connection closed by peer". That points at the
# network rather than at the memory, and it is the single most misleading
# failure in two-node serving here.
#
# Ported from their REQUIRE_IDLE_GPU. Set it to false to override.
# ---------------------------------------------------------------------------
if [[ ${REQUIRE_IDLE_GPU:-true} == true ]]; then
    twonode_require_idle_gpu || exit 1
fi

# ---------------------------------------------------------------------------
# PREFLIGHT 2: the patches exist.
#
# Two of the five patch SOURCE FILES that live inside the image, and they
# cannot be written without it - see patches/README.md and ./extract-sources.sh.
# Both are fatal-at-load rather than optional: without ple_fp8_resolver vLLM
# builds a ~102 GB BF16 embedding for a table that is FP8 on disk, and without
# mxfp8_kernel_fallback the [48, 2560] linear_attn projections hit an
# AssertionError during the memory profile ~7 minutes in, after the weights are
# already resident.
#
# REFUSING IS THE POINT. `[ -f ... ] || true` here would produce a launch that
# looks healthy for seven minutes and then dies with a message about tensor
# shapes, which is how an afternoon disappears.
# ---------------------------------------------------------------------------
PATCH_DIR=$PWD/patches
REQUIRED_PATCHES=(ple_fp8_resolver.py mxfp8_kernel_fallback.py fp8_block_moe.py)
missing=()
for p in "${REQUIRED_PATCHES[@]}"; do
    [[ -f "$PATCH_DIR/$p" ]] || missing+=("$p")
done
if (( ${#missing[@]} )); then
    cat >&2 <<MSG
refusing to launch: ${#missing[@]} mandatory patch(es) not written yet
  ${missing[*]}

Both patch source files that ship INSIDE $IMAGE, so they cannot be
written until the image is here. Get the sources out of it with:

  ./extract-sources.sh          # pulls the image, copies 4 files to patches/src/

then write the two patches against what lands in patches/src/ - the exact
mechanism each one needs is specified in patches/README.md.

Without them this model does not load at all. This is not a warning that can
be skipped with a flag.
MSG
    exit 1
fi

# ---------------------------------------------------------------------------
# WEIGHTS, on BOTH nodes, staged over the cable rather than twice over the WAN.
#
# 133 GiB per node. Each rank loads from its own disk - nothing about the HF
# cache is shared - so a cold start with no staging pays the WAN twice, which
# on the DeepSeek workspace measured ~56 MB/s per rank against 534 MB/s over
# the interconnect. Calling stage-weights.sh from here makes the fast path the
# default rather than a step people read about afterwards.
# ---------------------------------------------------------------------------
_hf=${HF_HOME:-$HOME/.cache/huggingface}
if [[ ! -d "$_hf/hub/models--${MODEL//\//--}" ]]; then
    _cli=$(twonode_hf_cli) || {
        echo "no hf CLI found, and this workspace needs one to stage weights." >&2
        echo "roles/ml installs it: make apply TAGS=ml" >&2
        exit 1; }
    echo "==> downloading $MODEL (~133 GiB) - first run only"
    "$_cli" download "$MODEL" >/dev/null || { echo "download failed: $MODEL" >&2; exit 1; }
    echo "==> staging to the peer over the interconnect"
    ./stage-weights.sh || { echo "staging to the peer failed" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# CHECKPOINT BOOKKEEPING, done on the host, mounted in.
#
# Three of the five fixes are about how THIS publisher recorded metadata, not
# about kernels, so they are JSON rather than Python and they run here. The HF
# cache is never modified - the patched copies live beside this script and are
# bind-mounted over the snapshot's own files.
# ---------------------------------------------------------------------------
SNAPSHOT=$(./detect-ple-dtype.py --snapshot-dir "$MODEL") || {
    echo "cannot resolve a snapshot for $MODEL" >&2; exit 1; }

# The PLE dtype the patched resolver dispatches on, recovered from wherever
# this checkpoint recorded it. Empty is a legitimate answer for a checkpoint
# that declares text_config.ple_embedding_dtype directly.
PLE_DTYPE=${PLE_EMBEDDING_DTYPE:-$(./detect-ple-dtype.py "$SNAPSHOT" || true)}

# The MTP layer-index alias, and the MoE-algo preflight that fails in seconds
# rather than seven minutes. Prints the files it rewrote, or nothing.
CFG_OUT=$PWD/.generated
mkdir -p "$CFG_OUT"
PATCHED_CFGS=$(./patch-checkpoint-config.py "$SNAPSHOT" "$CFG_OUT") || {
    echo "checkpoint config preflight failed - see above" >&2; exit 1; }

MTP_TOKENS=${MTP_NUM_SPECULATIVE_TOKENS:-3}
if (( MTP_TOKENS > 0 )); then
    ./patch-checkpoint-config.py --check-mtp-moe-algo "$SNAPSHOT" || {
        cat >&2 <<'MSG'
The MTP routed experts use a quantization this image's mixed-precision MoE
dispatch cannot build (it covers FP8 / NVFP4 / W4A16_NVFP4 / MXFP8; anything
else returns None and yields a silently UNQUANTIZED MoE that dies ~7 minutes
into the load).

Set MTP_NUM_SPECULATIVE_TOKENS=0 in .env to serve without speculative
decoding, or use a checkpoint whose MTP experts are NVFP4.
MSG
        exit 1; }
fi

# ---------------------------------------------------------------------------
# STAGE THE PATCHES TO A FIXED PATH ON BOTH NODES, so the mount string is
# identical on both ranks. Same mechanism as the GLM-5.3 kpool patch, and for
# the same reason: half the ranks patched and half not is worse than neither.
# ---------------------------------------------------------------------------
STAGE=/tmp/qwen38fn
PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' \
    "${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}" 2>/dev/null || true)}
mkdir -p "$STAGE"
install -m 0644 "$PATCH_DIR"/*.py "$STAGE/"
if [[ -n ${PEER:-} ]]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$PEER" "mkdir -p $STAGE" \
        || { echo "cannot reach $PEER to stage patches - refusing to start" >&2; exit 1; }
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$PATCH_DIR"/*.py "$PEER:$STAGE/" \
        || { echo "cannot stage patches to $PEER - refusing to start" >&2
             echo "  half the ranks patched and half not is worse than not starting" >&2
             exit 1; }
fi

# JIT caches on the host. FlashInfer autotunes on the FIRST REAL REQUEST here
# (their README notes it explicitly), and on an overlay filesystem that work is
# thrown away by `docker rm`. Persisting it also means the peer's re-JIT cannot
# sit inside a TP=2 collective long enough to trip NCCL's 600 s watchdog, which
# reports a hang rather than a slow compile.
JIT_CACHE=${JIT_CACHE:-$HOME/.cache/vllm-qwen38-fn}
mkdir -p "$JIT_CACHE/vllm" "$JIT_CACHE/triton"
if [[ -n ${PEER:-} ]]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$PEER" \
        "mkdir -p $(printf '%q' "$JIT_CACHE/vllm") $(printf '%q' "$JIT_CACHE/triton")" \
        2>/dev/null || true
fi

EXTRA_MOUNTS=(
    -v "$JIT_CACHE/vllm:/root/.cache/vllm"
    -v "$JIT_CACHE/triton:/root/.triton/cache"
    -v "$STAGE:/opt/qwen38fn:ro"
)
# The rewritten checkpoint configs, over the snapshot's own. Container-side the
# HF cache is /root/.cache/huggingface (this image runs as root), so the mount
# target is spelled from there rather than from $HF_HOME.
CONTAINER_SNAPSHOT="/root/.cache/huggingface/hub/models--${MODEL//\//--}/snapshots/$(basename "$SNAPSHOT")"
for cfg in $PATCHED_CFGS; do
    EXTRA_MOUNTS+=( -v "$CFG_OUT/$cfg:$CONTAINER_SNAPSHOT/$cfg:ro" )
done

EXTRA_ENV=(
    # The resolver shim reads this. Without it the patched ple_layer.py leaves
    # the stock quant-method lookup in place and the 51 GB table inflates.
    -e "PLE_QUANT_OVERRIDE=${PLE_QUANT_OVERRIDE:-fp8}"
    # Weights are staged by up.sh above, so nothing should reach the Hub at
    # load time. Offline makes a missing shard fail loudly instead of silently
    # re-downloading 133 GiB inside a container during a TP=2 rendezvous.
    -e "HF_HUB_OFFLINE=1"
    -e "TRANSFORMERS_OFFLINE=1"
    # Only meaningful above 262144, but harmless below and required with YaRN.
    -e "VLLM_ALLOW_LONG_MAX_MODEL_LEN=${VLLM_ALLOW_LONG_MAX_MODEL_LEN:-1}"
)

# BOTH PATCHES ARE MANDATORY, so both get `||  exit 1` rather than the
# `[ -f ] || true` shape the GLM-5.3 workspace uses for its already-in-image
# repairs. `--restart unless-stopped` then loops a failure loudly, which is the
# cheaper outcome: docker logs names the reason on every attempt.
# shellcheck disable=SC2016
PRE_EXEC='for p in ple_fp8_resolver mxfp8_kernel_fallback fp8_block_moe; do
    python3 "/opt/qwen38fn/$p.py" || {
        echo "$p did not apply - refusing to serve" >&2
        exit 1
    }
done'

# ---------------------------------------------------------------------------
# THE SERVE LINE. Transcribed from `docker inspect vllm-fn` on the kit that
# measured the numbers in the README, with this repo's two-node topology flags
# supplied by twonode.sh rather than repeated here.
# ---------------------------------------------------------------------------
MODEL_ARGS=(
    --model "$MODEL" --served-model-name "$SERVED"
    --tensor-parallel-size 2 --pipeline-parallel-size 1
    --distributed-executor-backend mp

    # REQUIRED for the NVFP4 experts, not a throughput preference. The
    # all2all backend is named explicitly because the default on this build
    # is not the one their measurements used.
    --enable-expert-parallel
    --all2all-backend "${ALL2ALL_BACKEND:-allgather_reducescatter}"

    # 0.835 of the 121.69 GiB CUDA sees, which their kit measured as 101.61
    # GiB budgeted, 68.52 GiB of weights+non-torch, and 32.02 GiB of KV. Their
    # own startup log reports headroom to 38.52 GiB, and they decline to chase
    # it because 13.93x concurrency already exceeds MAX_NUM_SEQS=8.
    #
    # UNVERIFIED HERE. The GLM-5.3 workspace had to come DOWN from its recipe's
    # number because a node running a desktop session missed the free-memory
    # check by under a GiB. Expect to do the same on a node that is not headless.
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.835}"

    # 262144 is NATIVE. Their .env.sample ships 1000000 with YaRN, and their
    # own README calls that combination oversubscribed at MAX_NUM_SEQS=8:
    # 8M cache tokens asked for against a 3.65M pool, which vLLM handles by
    # preempting and re-prefilling rather than by failing. That reads as "the
    # model got slow". Native context and an honest concurrency is the better
    # default; .env.example has the 1M path and what it costs.
    --max-model-len "${MAX_MODEL_LEN:-262144}"

    # auto (bf16), AND THAT IS NOT THE REFERENCE DEFAULT. Their kit runs fp8
    # and measures 1.70x the tokens per GiB for it (3,652,200 vs 2,131,159).
    # It is bf16 here because fp8 on this model requires patching the QSA
    # kernels - they declare supported_kv_cache_dtypes = ["auto", "bfloat16"]
    # and raise outright otherwise - and that patch is the one piece of the
    # upstream work this repo deliberately did not port: it is
    # AGPL-3.0-or-later against an MIT repository, and unlike the two mandatory
    # patches it buys capacity rather than the ability to load at all.
    # patches/README.md has the mechanism if someone writes a clean one.
    #
    # Setting KV_CACHE_DTYPE=fp8 without that patch does not degrade - it
    # refuses to start. When it does exist, treat fp8 as a QUALITY trade and
    # not just a capacity one: quantised keys change which blocks the sparse
    # indexer SELECTS, not merely the attention output. Measure it:
    #   ws up quant-quality-ab
    --kv-cache-dtype "${KV_CACHE_DTYPE:-auto}"

    --max-num-seqs "${MAX_NUM_SEQS:-8}"
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-8192}"
    --enable-chunked-prefill

    # Lazy safetensors: 133 GiB of shards, and the loader maps rather than
    # reads them up front. Their cold start is ~11 minutes with this on.
    --load-format safetensors --safetensors-load-strategy lazy

    --reasoning-parser qwen3
    --tool-call-parser qwen3_coder --enable-auto-tool-choice

    # mode 0 + FULL_DECODE_ONLY. Their measured capture is sizes 1-64 at
    # 0.54 GiB; full graphs over a hybrid attention stack are not captured here.
    --compilation-config "${COMPILATION_CONFIG:-{\"mode\":0,\"cudagraph_mode\":\"FULL_DECODE_ONLY\"}}"
)

# NVFP4 kernels want input features divisible by 16, and the vision MLP
# intermediate is 4304 - which is not, after TP=2 (4304/2 = 2152). "data"
# replicates the encoder per GPU; "weights" shards it and crashes at load.
MODEL_ARGS+=( --mm-encoder-tp-mode "${MM_ENCODER_TP_MODE:-data}" )

# MTP, and the ONE number that says whether it is working is acceptance - not
# tok/s and not correctness, because the target model verifies every draft, so
# a broken drafter costs speed and nothing else. Their kit measured 2.13x on
# batch-1 decode at 72.8% acceptance, decaying 89% / 74.5% / 60% by position.
# That decay is the check: a wrong expert block shape shows up as near-random
# acceptance rather than as a crash. Read it with `ws up spec-decode-accept`.
if (( MTP_TOKENS > 0 )); then
    MODEL_ARGS+=( --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$MTP_TOKENS}" )
fi

# --hf-overrides, and the NESTING is load-bearing. Their repo shipped these at
# the top level for months, where vLLM setattr'd them onto the parent config
# and they never reached text_config - so YaRN was a silent no-op and every
# "1M context" run was serving 1M positions on UNSCALED rope. Both keys go
# under text_config for that reason.
HF_OVERRIDES=""
if [[ ${YARN_ENABLE:-false} == true ]] && (( ${MAX_MODEL_LEN:-262144} > 262144 )); then
    HF_OVERRIDES=$(printf '{"text_config":{"rope_parameters":{"rope_type":"yarn","factor":%s,"original_max_position_embeddings":262144}%s}}' \
        "${YARN_FACTOR:-4.0}" \
        "${PLE_DTYPE:+,\"ple_embedding_dtype\":\"$PLE_DTYPE\"}")
elif [[ -n ${PLE_DTYPE:-} ]]; then
    HF_OVERRIDES=$(printf '{"text_config":{"ple_embedding_dtype":"%s"}}' "$PLE_DTYPE")
fi
# YaRN below native context costs accuracy and buys nothing, so it is refused
# rather than quietly passed through - their start.sh force-disables it and
# prints a note, which is the same call.
if [[ ${YARN_ENABLE:-false} == true ]] && (( ${MAX_MODEL_LEN:-262144} <= 262144 )); then
    echo "note    YARN_ENABLE=true ignored at MAX_MODEL_LEN=${MAX_MODEL_LEN:-262144} (<= native 262144)"
fi
[[ -n $HF_OVERRIDES ]] && MODEL_ARGS+=( --hf-overrides "$HF_OVERRIDES" )

# Split on whitespace deliberately - this is a string of FLAGS, not one
# argument. read -ra rather than a bare expansion so the intent is explicit and
# globbing stays off.
if [[ -n ${EXTRA_VLLM_ARGS:-} ]]; then
    read -ra _extra <<< "$EXTRA_VLLM_ARGS"
    MODEL_ARGS+=( "${_extra[@]}" )
fi

echo "model   $MODEL  TP=2+EP  NVFP4  (~133 GiB, ~64.5 GiB per node)"
echo "kv      ${KV_CACHE_DTYPE:-auto}  ctx ${MAX_MODEL_LEN:-262144}  mtp ${MTP_TOKENS}"
echo "ple     ${PLE_DTYPE:-declared by the checkpoint}"
echo "patches ${#REQUIRED_PATCHES[@]} mandatory, staged to $STAGE on both nodes"
twonode_up
echo
echo "COLD START IS ~11 MINUTES on the reference kit - weight load alone was"
echo "458 s, engine init 92 s. The first request after that is also slow while"
echo "FlashInfer autotunes. Neither is a hang."
echo
echo "confirm the KV pool vLLM actually allocated, which is the number every"
echo "capacity claim here depends on:"
echo "  docker logs $NAME 2>&1 | grep -E 'Available KV cache memory|GPU KV cache size'"
echo
echo "then ask the three questions a tok/s number cannot answer:"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up spec-decode-accept   # is MTP working?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate    # is it answering correctly?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up quant-quality-ab     # did fp8 KV change the answers?"
