#!/usr/bin/env bash
# NVIDIA Nemotron 3.5 Lightning 30B-A3B NVFP4 + DSpark, on ONE GB10.
#
# Ported from MiaAI-Lab/Nemotron3.5-Lightning-DGX-Spark-RTX-5090-6000-PRO,
# which is the only published DGX Spark operating point for this model with
# measured allocation numbers behind it, cross-checked against the NVIDIA-NeMo
# SGLang cookbook and the LMSYS day-0 post. What was taken and what was left
# behind is at docs/decisions.md#nemotron35-lightning.
#
# THE SHORT VERSION OF WHY THIS EXISTS AT ALL: this repo's engine x quant
# matrix USED TO SAY SGLang cannot serve NVFP4. That was measured on ONE
# checkpoint (unsloth's Qwen, quantised lm_head) and written down as a fact
# about the engine. It is a fact about the checkpoint. This one loads, and the
# matrix now says checkpoint-dependent because of it.
#
# NOT A COMPOSE WORKSPACE, on purpose: the three speculators take three
# different, non-overlapping flag sets, and a compose `command:` cannot branch.
# `docker logs -f ws-sglang-nemotron35` is the tail; the container name is
# stable so that line keeps working.
#
#   ws up sglang-nemotron35-lightning-nvfp4
#   ws up sglang-nemotron35-lightning-nvfp4 --download-only   # weights, no server
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

NAME=ws-sglang-nemotron35
# The day-0 image from the SGLang cookbook. It is a `dev-` tag, which is the
# same bet the rest of this repo makes on vllm:nightly-aarch64 - track upstream
# rather than adopt a fork - but it is a WEAKER guarantee than a release tag,
# because a dev tag can be rebuilt in place. Pin it by digest in .env if you
# want that in writing.
IMAGE=${IMAGE:-lmsysorg/sglang:dev-nemotron3-5-lightning}
PORT=${PORT:-8894}
HOST_BIND=${HOST_BIND:-0.0.0.0}
HF=${HF_HOME:-$HOME/.cache/huggingface}

MODEL=${MODEL:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4}
SERVED=${SERVED_NAME:-nemotron-3.5-lightning}
DSPARK_DRAFT=${DSPARK_DRAFT:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DSpark}
DFLASH_DRAFT=${DFLASH_DRAFT:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DFlash}

DOWNLOAD_ONLY=0
[[ ${1:-} == --download-only ]] && { DOWNLOAD_ONLY=1; shift; }

# ---------------------------------------------------------------------------
# Weights. `ws check` already WARNED if they are absent; this is where the
# warning becomes a download, so that a first run does not spend twenty minutes
# inside a container whose logs nobody is watching yet.
#
# SGLang resolves a Hub id itself, so the snapshot-path dance the upstream
# script does is not needed - it exists there to keep the container from
# touching the network, which the bind-mounted cache already achieves.
# ---------------------------------------------------------------------------
stage() {  # $1 = repo id
    local slug="models--${1//\//--}"
    [[ -d "$HF/hub/$slug" ]] && { echo "  cached  $1"; return 0; }
    echo "  fetch   $1"
    if command -v hf >/dev/null 2>&1; then
        HF_HOME=$HF hf download "$1" ${HF_TOKEN:+--token "$HF_TOKEN"}
    elif command -v huggingface-cli >/dev/null 2>&1; then
        HF_HOME=$HF huggingface-cli download "$1" ${HF_TOKEN:+--token "$HF_TOKEN"}
    else
        # No host-side CLI: borrow the one in the image rather than adding a
        # host dependency this repo's `ml` role does not promise.
        docker run --rm --entrypoint python3 \
            -e HF_HOME=/hf -e HF_TOKEN="${HF_TOKEN:-}" \
            -v "$HF:/hf" "$IMAGE" -c \
            "import os;from huggingface_hub import snapshot_download;snapshot_download('$1',token=os.environ.get('HF_TOKEN') or None)"
    fi
}

# ---------------------------------------------------------------------------
# THE SPECULATOR. Three are published for this checkpoint and they are not
# interchangeable; the measured ranking on a DGX Spark (vLLM, code generation,
# single stream / 8 concurrent) is:
#
#   none     81.3 / 241.7 tok/s      the throughput-optimal choice
#   DFlash   95.5 / 268.6 tok/s      +17% / +11%
#   MTP     111.4 / 302.3 tok/s      +37% / +25%
#   DSpark  124.2 / 354.6 tok/s      +53% / +47%   <- default
#
# So DSpark wins on BOTH axes on that workload, which is why it is the default
# and why upstream recommends it for latency on this class of box. It is also
# the one that costs ~28 GiB of bf16 draft KV, so `none` is the move when the
# pool is the binding constraint - not a lower mem-fraction.
#
# BLOCK SIZE IS GAMMA, NOT THE VERIFY WINDOW. SGLang's own help: the verify
# window is gamma + 1, i.e. --speculative-num-draft-tokens = gamma + 1. Block
# size 3 therefore drafts 3 and verifies 4. Omit it entirely and SGLang infers
# gamma from the draft checkpoint's own block_size, which is the safer default
# if a future draft revision changes it.
# ---------------------------------------------------------------------------
SPEC_ARGS=()
case "${SPEC_METHOD:-dspark}" in
  dspark)
    SPEC_ARGS=(
        --speculative-algorithm DSPARK
        --speculative-draft-model-path "$DSPARK_DRAFT"
        --speculative-dspark-block-size "${DSPARK_BLOCK_SIZE:-3}"
    )
    DRAFT_REPO=$DSPARK_DRAFT
    ;;
  dflash)
    SPEC_ARGS=(
        --speculative-algorithm DFLASH
        --speculative-draft-model-path "$DFLASH_DRAFT"
        --speculative-dflash-block-size "${DFLASH_BLOCK_SIZE:-4}"
    )
    DRAFT_REPO=$DFLASH_DRAFT
    ;;
  mtp)
    # The checkpoint's OWN multi-token-prediction heads, driven through
    # SGLang's EAGLE path - so the "draft model path" is the target model
    # itself and there is no second download. That looks like a typo and is
    # what the cookbook specifies.
    SPEC_ARGS=(
        --speculative-algorithm EAGLE
        --speculative-draft-model-path "$MODEL"
        --speculative-num-steps "${MTP_STEPS:-5}"
        --speculative-eagle-topk "${MTP_TOPK:-1}"
        --speculative-num-draft-tokens "${MTP_DRAFT_TOKENS:-6}"
    )
    DRAFT_REPO=
    ;;
  none)
    DRAFT_REPO=
    ;;
  *) echo "SPEC_METHOD must be dspark, dflash, mtp or none" >&2; exit 1 ;;
esac

echo "staging weights into $HF"
stage "$MODEL"
[[ -n ${DRAFT_REPO:-} ]] && stage "$DRAFT_REPO"
(( DOWNLOAD_ONLY )) && { echo; echo "weights are cached. exiting (--download-only)."; exit 0; }

# ---------------------------------------------------------------------------
# The serve line. Every value here is the published DGX Spark operating point
# unless the comment says otherwise.
# ---------------------------------------------------------------------------
SERVE_ARGS=(
    --model-path "$MODEL"
    --served-model-name "$SERVED"
    # 0.0.0.0 like the upstream recipe. The container is on --network host, so
    # this reaches the LAN - which is what makes the peer node and a laptop on
    # the same network able to use it, and what ufw is expected to bound.
    --host "$HOST_BIND"
    --port "$PORT"

    # float16, NOT bfloat16 and not auto. The mamba state is a fixed ~716 MiB
    # allocation whatever the context length, and this is the dtype the
    # published configuration measured it at.
    --mamba-ssm-dtype "${MAMBA_SSM_DTYPE:-float16}"

    # `auto` resolves to FP8 e4m3fn for THIS checkpoint - the model card ships
    # FP8 per-tensor dynamic KV scales - which is what makes ~4.93M pool tokens
    # fit in ~14 GiB at ~3 KB/token. Forcing bf16 here does not make it more
    # accurate, it makes the pool four times smaller.
    --kv-cache-dtype "${KV_CACHE_DTYPE:-auto}"

    # THE ONE KNOB THAT DECIDES EVERYTHING ELSE. 0.78 of 121 GiB unified is
    # ~94 GiB reserved at startup, and both the token pool and the derived
    # max_running_requests (48 on the reference kit) scale with it. It is a
    # fraction of THIS box's memory, so it does not transfer to a 32 GiB 5090 -
    # see the README's memory table before copying it anywhere.
    --mem-fraction-static "${MEM_FRACTION_STATIC:-0.78}"

    # 4, against 16 on an H100. This caps decode-graph scratch AND acts as a
    # decode concurrency cap; raising it on this box buys batch throughput out
    # of the same pool the KV cache lives in.
    --cuda-graph-max-bs-decode "${CUDA_GRAPH_MAX_BS_DECODE:-4}"

    # nemotron_3 here. vLLM spells the same parser `nemotron_v3`, which is not
    # a typo in either place - see the vLLM sibling workspace.
    --reasoning-parser "${REASONING_PARSER:-nemotron_3}"
    --tool-call-parser "${TOOL_CALL_PARSER:-qwen3_coder}"

    # OFF by default in SGLang, and without it there is no /metrics at all -
    # which means `spec-decode-accept` cannot see the drafter and reports a
    # working server as having no speculative decoding. Costs nothing.
    --enable-metrics
)

# Unset by default, deliberately. The checkpoint's own config.json already says
# 1,048,576, and the reference DGX Spark run - the one the memory numbers above
# come from - does not pass this flag. Set it to test a smaller window, not to
# "free" KV: on a hybrid model the floor is mamba state plus the draft cache,
# and neither moves with the cap.
[[ -n ${CONTEXT_LENGTH:-} ]] && SERVE_ARGS+=( --context-length "$CONTEXT_LENGTH" )
[[ -n ${MAX_RUNNING_REQUESTS:-} ]] && SERVE_ARGS+=( --max-running-requests "$MAX_RUNNING_REQUESTS" )

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker pull "$IMAGE"

echo
echo "model   $MODEL   (NVFP4, 21.6 GB + a 1.3 GB draft on disk)"
echo "spec    ${SPEC_METHOD:-dspark}   (acceptance is the only number that proves it works)"
echo "claim   mem-fraction-static ${MEM_FRACTION_STATIC:-0.78} of 121 GiB = ~94 GiB"
echo

docker run -d --name "$NAME" \
    --restart unless-stopped \
    --network host \
    --ipc host \
    --shm-size "${SHM_SIZE:-32g}" \
    --ulimit memlock=-1:-1 \
    --cap-add=IPC_LOCK \
    --gpus all \
    -e HF_HOME=/hf \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "$HF:/hf" \
    "$IMAGE" \
    sglang serve "${SERVE_ARGS[@]}" "${SPEC_ARGS[@]}" >/dev/null

echo "started $NAME"
echo "logs    docker logs -f $NAME"
echo

# Readiness. /v1/models answers before the weights finish loading on some
# builds, so wait on /health - the same distinction the vllm workspaces draw,
# and the same reason: a dependent client that starts on /v1/models talks to a
# server that then 503s.
echo -n "waiting for http://127.0.0.1:$PORT/health "
ready=0
for _ in $(seq 1 "${READY_TIMEOUT_STEPS:-450}"); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        ready=1; echo; echo "ready."
        break
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
        echo; echo "container exited before becoming ready:" >&2
        docker logs --tail 40 "$NAME" >&2
        exit 1
    fi
    printf .
    sleep 2
done
# Timing out is NOT the same as failing, and saying nothing here would let it
# read as either. The container is still running and still loading; ~23 GB off
# NVMe plus CUDA-graph capture is minutes. Exit non-zero anyway, so a script
# that chains on `ws up` does not proceed to talk to a server that is not there.
if (( ! ready )); then
    echo
    echo "still not answering /health after $(( ${READY_TIMEOUT_STEPS:-450} * 2 ))s." >&2
    echo "the container is STILL RUNNING - this is a timeout, not a crash:" >&2
    echo "  docker logs -f $NAME" >&2
    echo "raise READY_TIMEOUT_STEPS in .env if this box is simply slow." >&2
    exit 1
fi
echo

cat <<NEXT
endpoint  http://127.0.0.1:$PORT/v1   (served as "$SERVED")

what it ACTUALLY allocated - pool tokens, KV GiB, concurrency, accept length:
  ./report.sh

then ask the two questions tok/s cannot answer:
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up spec-decode-accept   # is the drafter working?
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate    # is it answering correctly?

the gate's TEXT detectors work anywhere, but its "was the run actually cold"
line comes from vllm:prefix_cache_* and SGLang does not publish it - so on this
server that reassurance is simply absent, not passing.

sampling: NVIDIA's card says temperature 1.0 / top_p 0.95. The DGX Spark recipe
this was ported from says 0.6 / 0.95 / top_k 20 / repetition_penalty 1.08. They
disagree; the README says which to use when. Thinking is a REQUEST field:
  "chat_template_kwargs": {"enable_thinking": true}
NEXT
