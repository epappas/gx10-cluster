#!/usr/bin/env bash
# GLM-5.3-Flash at EXL3 4bpw across BOTH nodes, tensor-parallel over RoCE.
#
# Ported from MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks, which is the only
# published GLM-5.3-Flash configuration for this exact hardware. What was taken
# and what was deliberately left behind is at docs/decisions.md#glm53-flash.
# The short version: the FLAGS and the arithmetic behind them are ported; the
# launcher is ours, because theirs keeps a .env on each node and this repo's
# whole argument about two-node serving is that both ranks must come from one
# place.
#
# The launcher is shared (../../lib/twonode.sh). Only the flags below are ours.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

NAME=ws-vllm-glm53-exl3

# THE OVERLAY IMAGE, and this is the one place this repo takes a third-party
# build rather than an upstream one. Upstream vLLM cannot serve this checkpoint
# at all: it has no `exl3` quantisation method, and it dies on the first
# forward with `pe_dim must be 64 for fp8_ds_mla` because GLM-5.3-Flash is NoPE
# MLA (qk_rope_head_dim=0) and the only sparse-MLA backend on SM12x expects a
# 656-byte record with a RoPE section. That is not a flag we could pass.
#
# It is public, arm64, built FROM vllm/vllm-openai for CUDA 13.0 with
# TORCH_CUDA_ARCH_LIST=12.1a - the architecture-specific target this repo has
# had recorded as "check this first" since the DeepSeek port
# (docs/decisions.md#two-node-vllm). Digest-pin it in .env if you want the
# stronger guarantee; both ranks pull the same tag either way, which is the
# property that actually matters.
IMAGE=${IMAGE:-ghcr.io/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3}
PORT=${PORT:-8893}

MODEL=${MODEL:-Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw}
SERVED=${SERVED_NAME:-glm-5.3-flash-exl3}
DRAFT_MODEL=${DRAFT_MODEL:-incoai/GLM-5.3-Flash-DFlash2}

# JIT caches, on the host. Triton and TileLang compile kernels on first use and
# cache them under /root, which on an overlay filesystem does not survive
# `docker rm`. Recreating the container therefore re-JITs mid-collective on
# TP=2, and the OTHER rank sits in the collective waiting - for long enough to
# trip NCCL's 600 s watchdog, which reports a hang rather than a slow compile.
# Persisting them makes the second boot fast and the failure impossible.
JIT_CACHE=${JIT_CACHE:-$HOME/.cache/vllm-glm53-exl3}
PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' \
    "${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}" 2>/dev/null || true)}
mkdir -p "$JIT_CACHE/triton" "$JIT_CACHE/tilelang"
# An `if`, not `[[ ... ]] && ssh ... || true`. That form reads as if-then-else
# and is not one - the `|| true` catches a false TEST as readily as a failed
# ssh - and shellcheck flags it as SC2015 on some versions and not others,
# which is how this file passed locally and turned CI red.
if [[ -n ${PEER:-} ]]; then
    # Best effort by design: the peer may be down, and a missing cache there
    # costs a re-JIT on its first boot, never correctness. Do not fail launch.
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$PEER" \
        "mkdir -p $(printf '%q' "$JIT_CACHE/triton") $(printf '%q' "$JIT_CACHE/tilelang")" \
        2>/dev/null || true
fi
# THE ONE PATCH THIS REPO CARRIES ITSELF, and the reason it is not optional.
#
# Every other patch below is already applied inside the image, so re-running it
# is a cheap repair and a missing file is harmless. This one is a CORRECTNESS
# fix that postdates the published `:exl3` tag: the generic paged slot-mapping
# kernel indexes past the K-pool tail group's single block-table entry, and the
# kpool kernels then write through a garbage block id. Most overruns land inside
# the shared pool, so the symptom is not a crash - it is another layer's indexer
# quietly corrupted, on generations of roughly 2k tokens and up. A request that
# finished is not evidence that its writes were in bounds.
#
# So `[ -f ... ] || true` is exactly the wrong shape for it: an image that does
# not ship the file would skip the fix silently, which is the failure the fix
# exists to prevent. It is vendored next to this script, staged to a FIXED path
# on both nodes so the mount string is identical on both ranks, and PRE_EXEC
# aborts the container if it does not apply. The patch itself is fail-closed and
# idempotent - it refuses to write if its pinned anchor has drifted.
KPOOL_SRC=$PWD/patch_kpool_tail_slotmap.py
KPOOL_PATH=/tmp/glm53-patch_kpool_tail_slotmap.py
[[ -f $KPOOL_SRC ]] || { echo "missing $KPOOL_SRC" >&2; exit 1; }
install -m 0644 "$KPOOL_SRC" "$KPOOL_PATH"
if [[ -n ${PEER:-} ]]; then
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$KPOOL_SRC" "$PEER:$KPOOL_PATH" \
        || { echo "cannot stage the kpool patch to $PEER - refusing to start" >&2
             echo "  half the ranks clamped and half not is worse than not starting" >&2
             exit 1; }
fi

EXTRA_MOUNTS=(
    -v "$JIT_CACHE/triton:/root/.triton/cache"
    -v "$JIT_CACHE/tilelang:/root/.tilelang/cache"
    -v "$KPOOL_PATH:/opt/glm53/patch_kpool_tail_slotmap.py:ro"
)

EXTRA_ENV=(
    # The `a` suffix is not cosmetic. Blackwell's FP4 instructions are not
    # forward-compatible, so a kernel built for 12.1 and a kernel built for
    # 12.1a are different objects - and the EXL3 trellis kernels in this image
    # are the latter. This repo has had "if a FlashInfer or CUTE-DSL kernel
    # ever misbehaves here, the arch suffix is the first thing to check"
    # written down since the DeepSeek port; this is the workspace where it
    # stops being a note and becomes a setting.
    -e "TORCH_CUDA_ARCH_LIST=12.1a"
    -e "FLASHINFER_CUDA_ARCH_LIST=12.1a"
    -e "FLASHINFER_DISABLE_VERSION_CHECK=1"
    -e "TRITON_CACHE_DIR=/root/.triton/cache"
    -e "TILELANG_CACHE_DIR=/root/.tilelang/cache"

    # Client `stop` strings stay dormant until </think>. Thinking is ON by
    # default in this model, so a client that stops on a common token can
    # truncate the server inside the reasoning block and return an empty
    # answer with a normal finish_reason. 0 restores stock behaviour.
    -e "GLM53_SUPPRESS_STOPS_IN_REASONING=${SUPPRESS_STOPS_IN_REASONING:-1}"

    # Do not mix a peer's prefill into a step where another sequence is
    # decoding. The cost is visible and honest - concurrent cold prefills
    # SERIALISE, and the second caller waits - and the alternative is that one
    # long prefill lands in a decode step and stalls every stream in flight.
    # `skip` = decode-only steps, N>0 = cap mixed prefill tokens, 0 = stock.
    -e "GLM53_MIXED_PREFILL_CHUNK=${MIXED_PREFILL_CHUNK:-skip}"

    # EngineCore's stock 300 s execute timeout is shorter than a cold
    # Triton/TileLang JIT on TP=2, so the stock value turns a slow compile into
    # a reported hang. NCCL's own 600 s watchdog still backstops a real one.
    -e "VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=${EXECUTE_MODEL_TIMEOUT:-1800}"

    # vLLM subtracts a PREDICTED CUDA-graph footprint from the KV pool before
    # capturing. Where the prediction overshoots what the graphs actually use,
    # 0 hands that memory back to KV with graphs still on. Left at the upstream
    # default because nobody has published the delta and this is the workspace
    # with the least headroom to absorb an under-estimate - it is here as a
    # named knob to try when the pool is the binding constraint, not as advice.
    -e "VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=${CG_ESTIMATE:-1}"
)

# TWO KINDS OF PATCH, and they get opposite failure handling.
#
# The kpool clamp is mounted from the host above and is MANDATORY: if it does
# not apply, the container exits rather than serve a model that corrupts its own
# indexer. `--restart unless-stopped` then loops it, which is noisy on purpose -
# `docker logs` names the reason on every attempt, and a loud restart loop is
# the cheaper failure.
#
# The rest ship in the image. ONE of them is not applied at build time - the
# video placeholder alignment - so it has to run here, before the server starts.
# The others are already applied; re-running them is idempotent, costs a second,
# and repairs a rebuilt or retagged image that skipped one rather than leaving
# the ranks silently different. Missing files are skipped, so this stays correct
# if the image drops a patch it no longer needs.
# patch_hybrid_prefix_hit is the one worth naming: `dflash` reports itself as
# EAGLE, and GLM never sets `is_eagle_group` (that annotator is DeepSeek-only),
# so the stock hybrid coordinator flags EVERY group - which makes the MLA cache
# drop its last 3584-token page on every prefix-cache lookup. The patch flags
# only the drafter's sliding-window group, so the drafter cannot shrink the
# MLA+mamba hit. That is why an 8k follow-up reuses 7168 tokens and not 3584.
# shellcheck disable=SC2016  # $p must expand in the CONTAINER, not here
PRE_EXEC='python3 /opt/glm53/patch_kpool_tail_slotmap.py || {
    echo "kpool tail slot-map patch did not apply - refusing to serve" >&2
    exit 1
}
for p in patch_glm_video_placeholders patch_suppress_stops_in_reasoning \
         patch_scheduler_decode_floor patch_glm5_drafter_group \
         patch_hybrid_prefix_hit patch_xgrammar_termination; do
    [ -f "/opt/glm53/$p.py" ] && python3 "/opt/glm53/$p.py" || true
done'

# 4-bit EXL3 trellis weights for the routed experts; dense layers, shared
# experts, attention, embeddings and lm_head stay native. ~164 GiB total, so
# TP=2 puts ~82 GiB on each node against ~105 GiB claimable at 0.87.
MODEL_ARGS=(
    --model "$MODEL" --served-model-name "$SERVED"
    --tensor-parallel-size 2 --pipeline-parallel-size 1
    --distributed-executor-backend mp

    # NEVER `marlin`, and never NVFP4 weights. `exl3` is a method this image
    # registers; the wrong one here does not fall back, it loads the routed
    # experts as BF16 and the model no longer fits on two nodes.
    --quantization "${QUANTIZATION:-exl3}"

    # 0.87 of 121 GiB, and the tightest utilisation in this repo. It needs
    # ~106 GiB free AFTER vLLM's own ~9 GiB of init - kits that run a desktop
    # session or a resident dashboard miss it by under a GiB and fail the
    # startup memory check. The documented fallback is 0.86 with
    # MAX_MODEL_LEN=800000, which fits with margin.
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.87}"

    # 1M, and it allocates - see the arithmetic in workspace.yml. Lowering this
    # to "free" KV is the first wrong move: logged pool tokens are roughly
    # concurrency x this cap, and the hybrid floor (mamba state + the drafter's
    # sliding window) is mostly length-independent, so a smaller cap shrinks
    # the pool it was supposed to enlarge.
    --max-model-len "${MAX_MODEL_LEN:-1000000}"

    # REQUIRED, and the one value here with no alternative. The SM12x
    # sparse-MLA kernel accepts only packed `fp8_ds_mla`. bf16 KV has no sparse
    # kernel on this architecture at all, and NVFP4 KV - which does exist on
    # SM12x - is a DENSE MHA kernel, not sparse MLA. Do not read a working
    # NVFP4 recipe for another model as evidence it applies here.
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"

    # Four IN-FLIGHT generations, not four parked chat sessions: the OpenAI API
    # is stateless and idle conversations reserve nothing.
    --max-num-seqs "${MAX_NUM_SEQS:-4}"

    # 2048, not the 8192 that is normal elsewhere, and not the 1024 this
    # workspace shipped first. Two separate facts, and only one of them is a
    # preference:
    #
    #   the CEILING is hardware. At 8192-token chunks the GB10 indexer's top-k
    #   oversubscribes shared memory on a long prefill and crashes around 300k
    #   tokens. Never raise this to 8192, whatever a throughput table says.
    #
    #   the VALUE under that ceiling is measured. The published ladder runs
    #   1024 -> 2048 -> 3584 -> 4096 on cold prefill, prompt_tokens taken from
    #   the server's own usage block, one request at a time, unique salt so the
    #   prefix cache cannot cheat:
    #
    #     MNBT     8k        16k     100k       verdict
    #     1024     772       893     947        baseline
    #     2048     895 +16%  953 +7% 975  +3%   KEEP
    #     3584     777 -13%  950     929  -2%   revert
    #     4096     755 -16%  948     987  +4%   revert
    #
    # 3584 is the interesting loss: it is the hybrid page (4x896), so chunk
    # boundaries land exactly on prefix-cache pages and it "should" win. It does
    # not, because a bigger chunk makes the routed-expert fat path hotter - at
    # 1024 tokens the hottest expert is already in top-8 for ~90% of them - and
    # the LinearEXL3 reconstruct loop it falls back to costs more than the
    # chunks saved. The alignment argument is real and it is simply outweighed.
    #
    # The cost of 2048 is honest and it is not throughput: with
    # GLM53_MIXED_PREFILL_CHUNK=skip a prefill chunk is a step no decoder gets,
    # so doubling the chunk doubles the worst-case stall a streaming client
    # sees while somebody else's prompt is going in. `ws up vllm-prefill-ladder`
    # is how you re-take this table if you want to trade the other way.
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-2048}"

    # Prefix caching earns its keep here because the client resends the whole
    # history every turn. Hits are BLOCK-ALIGNED only (3584-token hybrid
    # align), which still reuses ~93% of a 7.7k follow-up. Raising
    # --max-num-batched-tokens does not improve it and costs the line above.
    --enable-prefix-caching
    --no-enable-flashinfer-autotune

    # Reasoning and tool calls become structured fields instead of raw text in
    # the content. The parser names are GLM-family and version-skewed on
    # purpose - glm47 for tools, glm45 for reasoning - which looks like a typo
    # and is what this model's runtime expects.
    --tool-call-parser glm47 --enable-auto-tool-choice
    --reasoning-parser glm45

    # Ships in the image. The checkpoint's own jinja is language-only and
    # silently drops <|image|> / <|video|> blocks.
    --chat-template "${CHAT_TEMPLATE:-/opt/glm53/chat_template.jinja}"
)

[[ -n ${MODEL_REVISION:-} ]] && MODEL_ARGS+=( --revision "$MODEL_REVISION" )

# Vision on by default. --skip-mm-profiling is not an optimisation: vLLM's
# max-size multimodal dummy profile allocates a worst-case image+video batch at
# init and OOMs this unified pool before the server ever answers.
if [[ ${LANGUAGE_MODEL_ONLY:-0} == 1 ]]; then
    MODEL_ARGS+=( --language-model-only )
else
    # Written out rather than inlined into a ${VAR:-...} default: bash does
    # handle the nested braces, but a JSON blob inside a parameter expansion is
    # the kind of line people "fix" and break.
    limit_mm='{"image":4,"video":1}'
    MODEL_ARGS+=( --limit-mm-per-prompt "${LIMIT_MM:-$limit_mm}" )
    MODEL_ARGS+=( --skip-mm-profiling )
fi

# DFlash2 k=7, and the ONE number that tells you whether it is working is
# acceptance - not tok/s, and not correctness. A broken draft path costs
# acceptance and nothing else, because the target model still verifies every
# token: the output stays perfectly right at half the speed, which reads as bad
# hardware. `ws up spec-decode-accept` reads it per draft POSITION, which is
# the resolution this model needs - pinning the draft attention backend to
# TRITON_ATTN leaves position 0 healthy and collapses the rest, and no
# aggregate number shows that. Read it off the STRUCTURED ladder - a
# healthy PROSE ladder collapses too, and convicting on that is how a
# working server gets condemned.
#
# draft_tensor_parallel_size=2 SHARDS the drafter across both ranks, and on
# this workspace that is a memory decision rather than a speed one. At 1 the
# ~2.3 GiB drafter sits entirely on rank 0 - but vLLM sizes one KV pool for the
# whole server, so the pool is bounded by the tighter rank and every node pays
# the 2.3 GiB. Sharding gives ~1.15 GiB of it back to a KV budget of about 19
# GiB, which is the smallest in this repo. The price is that a draft step now
# crosses the cable, and the published A/B is a no-regression result rather than
# a win: idle cold prefill 8k 895 -> 938 tok/s, 100k 975 -> 997, both decode
# classes unchanged, which upstream itself characterises as HELD. So the
# latency evidence only has to show no harm and the memory argument carries it.
# DRAFT_TP=1 rolls it back if a draft step ever shows up as latency on a link
# that is busy with something else.
#
# Do NOT add "attention_backend": the image picks FLASH_ATTN for the non-causal
# sliding-window draft block, and the TRITON_ATTN mask is causal inside that
# block on this build.
case "${SPEC_METHOD:-dflash}" in
  dflash)
    dflash_cfg=$(printf '{"method":"dflash","model":"%s","num_speculative_tokens":%s,"kv_cache_dtype":"auto","draft_sample_method":"probabilistic","rejection_sample_method":"standard","draft_tensor_parallel_size":%s}' \
        "$DRAFT_MODEL" "${DRAFT_TOKENS:-7}" "${DRAFT_TP:-2}")
    MODEL_ARGS+=( --speculative-config "${SPEC_CONFIG:-$dflash_cfg}" )
    # The drafter is dense and has no MLA FP8 backend on SM121, so its KV is
    # bf16 while the target's stays packed fp8. Two dtypes in one server is
    # correct here, not a mistake to tidy up.
    ;;
  mtp)
    # The rollback path: the checkpoint's own multi-token-prediction head, no
    # second model to download. Slower (~24.6 vs ~62 tok/s structured on the
    # source kit) and one less moving part.
    MODEL_ARGS+=( --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${MTP_TOKENS:-2}}" )
    ;;
  none) ;;
  *) echo "SPEC_METHOD must be dflash, mtp or none" >&2; exit 1 ;;
esac

# CUDA graphs on, with capture sizes that must include the DECODE BATCH SHAPE
# the speculator produces: k=7 emits 8 tokens per sequence, so 1..4 sequences
# are 8/16/24/32. Capture the wrong ladder and every decode step falls back to
# eager, which looks like the graphs are simply not helping.
if [[ ${ENFORCE_EAGER:-0} == 1 ]]; then
    MODEL_ARGS+=( --enforce-eager )
elif [[ ${SPEC_METHOD:-dflash} == mtp ]]; then
    MODEL_ARGS+=( --cudagraph-capture-sizes 1 2 3 4 6 8 12 )
else
    MODEL_ARGS+=( --cudagraph-capture-sizes 1 2 4 8 16 24 32 )
fi

echo "model   $MODEL  TP=2  EXL3 4bpw  (~164 GiB, ~82 GiB per node)"
echo "spec    ${SPEC_METHOD:-dflash}  (acceptance is the only number that proves it)"
twonode_up
echo
echo "~164 GiB of weights split two ways. Both nodes need their OWN copy - off"
echo "a cold cache each rank downloads it, which is twice the WAN for bytes"
echo "already on the peer. ./stage-weights.sh rsyncs them over the cable."
echo
echo "thinking is ON by default. Turn it off per request with the TOP-LEVEL"
echo "field, not a nested extra_body object:"
echo "  \"chat_template_kwargs\": {\"enable_thinking\": false}"
echo
echo "optional, once /health is green: ./warmup.sh burns the JIT shapes so the"
echo "first real client is not the first compile inside a TP=2 collective."
echo
echo "then ask the three questions a tok/s number cannot answer:"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up spec-decode-accept   # is the drafter working?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate    # is it answering correctly?"
echo "  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-prefill-ladder --chunk-tokens ${MAX_NUM_BATCHED_TOKENS:-2048}"
echo "                                                              # how long until the FIRST character?"
