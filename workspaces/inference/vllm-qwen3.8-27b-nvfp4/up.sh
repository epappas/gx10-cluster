#!/usr/bin/env bash
# Qwen3.8-27B NVFP4 on one GB10.
#
# A THIN WRAPPER OVER compose.yml, not a hand-rolled launcher - the same shape
# as vllm-nemotron35-lightning-nvfp4's, and here for the same reason: a compose
# `command:` cannot branch, and one of the speculator's settings is "pass no
# flag at all". It computes SPEC_FLAG and hands over to compose using the SAME
# project name `ws` uses, so `ws logs` and `ws down` keep working.
#
# WHY THERE IS A SWITCH AT ALL, and it is not a preference. Measured on this
# box, on this checkpoint: with MTP on, vLLM logs
#
#   Speculative decoding (method=mtp) is enabled but no KV cache group could be
#   identified as the draft model's, so every group -- including Mamba groups
#   [0, 1, 2] -- will be treated as a draft group. A Mamba group cannot satisfy
#   the widened lookup window that implies, so prefix-cache reuse across
#   requests will be disabled
#
# and it means it: 471,925 queried prefix-cache tokens, ZERO hits, including
# two byte-identical requests back to back. Qwen3.8-27B is a hybrid
# (Qwen3_5ForConditionalGeneration - mamba groups plus attention), and MTP on a
# hybrid costs the whole prefix cache.
#
# THAT IS A REAL TRADE AND IT GOES BOTH WAYS:
#
#   SPEC_METHOD=mtp    ~2.4 tokens per decode step at ~70% acceptance, and
#                      every follow-up turn re-prefills the entire history.
#   SPEC_METHOD=none   prefix caching works, so turn 2 of a conversation skips
#                      the prefill it already paid for. Slower per token.
#
# Chat resends the whole history every turn, so `none` usually wins there and
# `mtp` usually wins on one-shot generation. Neither default is right for
# everyone, which is why this is a knob rather than a decision - and why
# `ws up vllm-prefill-ladder` exists to measure YOUR side of it.
#
#   ws up   vllm-qwen3.8-27b-nvfp4
#   ws logs vllm-qwen3.8-27b-nvfp4 -f
#   ws down vllm-qwen3.8-27b-nvfp4
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

PORT=${PORT:-8888}

# TWO THINGS COMPOSE DOES TO THIS STRING, and both bite silently - the same
# note as the Nemotron sibling, because it is the same trap.
#
#   1. It SPLITS a string `command:` on whitespace after interpolation, so a
#      space anywhere in the JSON becomes a second argv entry and vLLM rejects
#      the fragment. Hence no spaces below.
#   2. It then runs the result through shell-like quote removal, which EATS the
#      double quotes - {"method":"mtp"} reaches vLLM as {method:mtp}, which is
#      not JSON and fails with a parser error naming neither compose nor this
#      file.
spec_flag() {
    local json=$1
    printf -- '--speculative-config %s' "${json//\"/\\\"}"
}

K=${SPEC_TOKENS:-2}
case "${SPEC_METHOD:-mtp}" in
  mtp)
    # The checkpoint's own prediction heads - model_mtp.safetensors ships in
    # the repo. NO `model` key: there is no second checkpoint to name.
    SPEC_FLAG=$(spec_flag "{\"method\":\"mtp\",\"num_speculative_tokens\":$K}")
    ;;
  none)
    # Empty, so compose emits nothing at all - and the prefix cache comes back.
    SPEC_FLAG=""
    ;;
  *) echo "SPEC_METHOD must be mtp or none" >&2; exit 1 ;;
esac
export SPEC_FLAG

echo "model   ${MODEL:-unsloth/Qwen3.8-27B-NVFP4}   (NVFP4 via Marlin on GB10 - not native FP4)"
if [[ ${SPEC_METHOD:-mtp} == none ]]; then
    echo "spec    none  - PREFIX CACHING IS ON. Right for chat, where every turn"
    echo "                resends the history."
else
    echo "spec    mtp  k=$K  - PREFIX CACHING IS OFF on this hybrid checkpoint,"
    echo "                and vLLM says so in the log. SPEC_METHOD=none in .env"
    echo "                trades ~2.4 tok/step back for it."
fi
echo

# The project name MUST match what `ws` computes, or `ws logs` and `ws down`
# address a project this script never created - a running container that
# `ws status` cannot see and `ws down` cannot stop. `ws up` exports it for
# exactly that reason; the fallback is only for running this script by hand,
# and it pipes through printf rather than basename because `tr -c` translates
# a trailing NEWLINE as readily as a dot, which is how the two sides came to
# disagree by one character in the first place.
docker compose --project-name \
    "${WS_PROJECT:-ws-$(printf '%s' "$(basename "$PWD")" \
        | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')}" \
    up -d "$@"

cat <<NEXT

endpoint  http://127.0.0.1:$PORT/v1
logs      ws logs vllm-qwen3.8-27b-nvfp4 -f

Expect minutes of 503s: ~22 GB of NVFP4 off NVMe, FlashInfer autotune and
CUDA-graph capture. /health is the readiness signal, not /v1/models.

then ask the questions tok/s cannot answer:
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate     # is it right?
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-prefill-ladder   # and is the
                                                                 # prefix cache
                                                                 # actually reusing?
NEXT
