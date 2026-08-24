#!/usr/bin/env bash
# DeepSeek-V4-Flash across BOTH nodes, tensor-parallel over RoCE.
#
# This is the model-specific sibling of vllm-2node-tp2. That workspace took the
# GENERIC half of the published 2x DGX Spark recipes - container RDMA, the gloo
# interface variables, the rendezvous split - and deliberately left the
# DeepSeek half behind (docs/decisions.md#two-node-vllm). This is where the
# DeepSeek half belongs: the v4 tokenizer mode, the reasoning and tool parsers,
# the FP4 indexer cache, DSpark speculative decoding, and a `--max-num-seqs`
# low enough to be honest about the KV budget.
#
# The launcher is shared (../../lib/twonode.sh). Only the flags below are ours.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh

NAME=ws-vllm-ds-v4-flash
# Upstream, not the Anemll/Stage-C fork, and this is a considered choice rather
# than an oversight. vLLM gained a dedicated deepseek_v4 package with NVFP4
# fused MoE in 0.22.0 and DSpark speculative decoding in 0.25.0, so the model
# no longer NEEDS a fork - which was the whole reason the repo declined one.
# The fork remains measurably faster on this exact hardware (its own README
# reports newer vLLM at 8-9% slower on decode) and .env.example says how to
# switch. Taking it by default means inheriting one project's release cadence
# for every future model; that trade is still not worth it.
IMAGE=${IMAGE:-vllm/vllm-openai:nightly-aarch64}
PORT=${PORT:-8890}

MODEL=${MODEL:-deepseek-ai/DeepSeek-V4-Flash-DSpark}
SERVED=${SERVED_NAME:-deepseek-v4-flash}

# 284B total / 13B activated. The FP8 checkpoint is ~149 GiB, so TP=2 puts
# ~75 GiB of weights on each node against ~97 GiB claimable at 0.80 - which
# leaves roughly 22 GiB per node for KV, and that number is what every other
# default here is derived from.
MODEL_ARGS=(
    --model "$MODEL" --served-model-name "$SERVED"
    --trust-remote-code
    --tensor-parallel-size 2 --pipeline-parallel-size 1
    --distributed-executor-backend mp
    # THE ONE VALUE HERE THAT CANNOT BE VALIDATED BY STARTING THE SERVER.
    # Speculative decoding allocates its verify buffers on the FIRST REAL
    # REQUEST, not at boot - so a utilisation that is slightly too high boots
    # cleanly, passes a smoke test, serves a few requests and then dies under
    # traffic. Every quick check you would run says it is fine. If that is the
    # shape of your failure, this is the first knob, not the last: the
    # published 2x Spark profile moved 0.80 -> 0.78 for exactly this, on a
    # 1M-context nvfp4 config that reserves more than this one does.
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.80}"

    # 256, not the default 16. DeepSeek's MLA attention reads a compressed
    # latent per block, and the published recipes are unanimous on this one -
    # every V4 configuration from the model card to the ROCm ones sets it.
    --block-size 256

    # NOT 1M, which is what the model supports and what the fork recipes run.
    # A 1M context here rests entirely on `nvfp4_ds_mla`, a KV dtype whose
    # 584-byte sparse-MLA envelope is what makes the arithmetic work; upstream
    # takes fp8, which is several times larger per token. Asking for 1M on fp8
    # does not fail at startup - it fails later, as preemption, which reads as
    # "the model got slow" rather than "the context was a lie".
    --max-model-len "${MAX_MODEL_LEN:-131072}"
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"

    # Six concurrent sequences, which looks absurdly low next to a normal vLLM
    # deployment and is the honest number for ~22 GiB of KV at this context.
    # It is also what the measured 2x DGX Spark profile uses. Raise it only
    # together with a lower --max-model-len.
    --max-num-seqs "${MAX_NUM_SEQS:-6}"
    --max-num-batched-tokens "${MAX_BATCHED_TOKENS:-8192}"
    --enable-chunked-prefill
    # Caps how much of one long prompt may prefill before other requests get a
    # turn. Without it a single 128K prompt serialises the whole server and
    # concurrent chats appear to hang.
    --long-prefill-token-threshold "${LONG_PREFILL_THRESHOLD:-1024}"

    # v4 ships no Jinja chat template - it encodes with Python - so the
    # tokenizer mode is load-bearing, not cosmetic. The parsers are what turn
    # reasoning traces and tool calls into structured fields instead of raw
    # text in the content.
    --tokenizer-mode deepseek_v4
    --reasoning-parser deepseek_v4
    --tool-call-parser deepseek_v4 --enable-auto-tool-choice

    # The FP4 indexer cache belongs to v4's compressed/heavily-compressed
    # attention. It is in every official launch line for this model.
    --attention-config '{"use_fp4_indexer_cache": true}'

    # DSpark is why the -DSpark checkpoint exists: a draft module shipped in
    # the same repo. 5 tokens, not the model card's 7 - the card is written for
    # a 4xGB300 node, and rejected drafts are wasted compute that a GB10 has
    # much less of to waste. On the fork lineage 5 is also the only safe value
    # for a different reason: the draft block is sized from the checkpoint's
    # dspark_block_size=5, so 7 is rejected at boot there, and patching the
    # guard out moves the failure to the first generation. Reported on that
    # runtime, not measured here.
    #
    # `draft_sample_method` is carried because the published recipes carry it,
    # NOT because it is doing anything: the DSpark proposer only populates
    # draft probabilities under VLLM_DSPARK_EXPORT_DRAFT_PROBS=1, so greedy and
    # probabilistic take the same rejection-sampler path. The claim that
    # probabilistic is worth ~50% more throughput circulated widely and was
    # withdrawn by its authors after a re-measurement. Do not spend a day here.
    #
    # WHETHER ANY OF IT IS WORKING is one number, and it is on the bench view:
    # `ws up vllm-bench-serve` reports draft acceptance live. A draft path that
    # is silently broken - skipped weights, a clamped draft length - costs
    # acceptance and nothing else, because the target model still verifies
    # every token. Output stays perfectly correct at half the speed, which is
    # the most misleading failure in this file.
    --speculative-config "${SPEC_CONFIG:-{\"method\":\"dspark\",\"num_speculative_tokens\":5,\"draft_sample_method\":\"greedy\"}}"

    # Prefer vLLM's sampling defaults over the checkpoint's generation_config.
    # DeepSeek ships one tuned for their API, and silently inheriting someone
    # else's temperature is how two "identical" servers disagree.
    --generation-config vllm
)

echo "model   $MODEL  TP=2  (284B total / 13B active)"
twonode_up
echo
echo "~149 GiB of weights split two ways, off a cold cache the FIRST run also"
echo "downloads them. Expect tens of minutes before /health answers."
echo
echo "sampling: temperature 1.0, top_p 1.0 (0.95 for agentic). Reasoning effort"
echo "is a request field: --chat-template-kwargs '{\"reasoning_effort\":\"high\"}'"
echo
echo "once /health answers, ask whether it is answering CORRECTLY - this model"
echo "is the one in this repo most exposed to cold-prefill and concurrency"
echo "faults, and they do not move a tok/s number:"
echo "  ws up vllm-quality-gate     # BASE_URL=http://127.0.0.1:$PORT/v1"
