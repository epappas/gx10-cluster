#!/usr/bin/env bash
# Nemotron 3.5 Lightning NVFP4 + DSpark under vLLM, on one GB10.
#
# THIS IS A COMPOSE WORKSPACE WITH A THIN WRAPPER, not a hand-rolled launcher.
# Everything that can live declaratively is in compose.yml; this file exists
# for the one thing a compose `command:` cannot express - three published
# drafters that take three different JSON shapes, one of which is "pass no flag
# at all". It computes SPEC_FLAG, then hands over to compose using the SAME
# project name `ws` uses, so `ws logs` and `ws down` keep working.
#
#   ws up   vllm-nemotron35-lightning-nvfp4
#   ws logs vllm-nemotron35-lightning-nvfp4 -f
#   ws down vllm-nemotron35-lightning-nvfp4
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

MODEL=${MODEL:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4}
DSPARK_DRAFT=${DSPARK_DRAFT:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DSpark}
DFLASH_DRAFT=${DFLASH_DRAFT:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DFlash}
PORT=${PORT:-8895}

# ONE JSON BLOB, WHERE THE SOURCE USED DOTTED FLAGS. The published DGX Spark
# run writes `--speculative_config.method dspark --speculative_config.model ...`;
# vLLM accepts both and every other workspace here uses the JSON form, so this
# one does too rather than introducing a second convention for one recipe.
#
# TWO THINGS COMPOSE DOES TO THIS STRING, and both bite silently.
#
#   1. It SPLITS a string `command:` on whitespace after interpolation, so a
#      space anywhere in the JSON becomes a second argv entry and vLLM rejects
#      the fragment. Hence no spaces below.
#   2. It then runs the result through shell-like quote removal, which EATS the
#      double quotes - `{"method":"dspark"}` reaches vLLM as
#      `{method:dspark}`, which is not JSON and fails with a parser error that
#      names neither compose nor this file.
#
# So the quotes are backslash-escaped on the way out. `spec_flag` builds
# readable JSON and escapes it in one place, rather than writing \" by hand
# four times and getting one of them wrong.
spec_flag() {
    local json=$1
    printf -- '--speculative-config %s' "${json//\"/\\\"}"
}

# num_speculative_tokens: 3, not 7. Measured on this box, depth 3 beats depth 7
# for single-stream use - a deeper ladder costs a longer draft pass for tokens
# the target then rejects. This repo has already been bitten by inheriting a
# `k` from a model card (docs/decisions.md#dspark-1m-recipe), so the number is
# the one someone measured here, not the one the card suggests.
K=${SPEC_TOKENS:-3}
case "${SPEC_METHOD:-dspark}" in
  dspark)
    SPEC_FLAG=$(spec_flag "{\"method\":\"dspark\",\"model\":\"$DSPARK_DRAFT\",\"num_speculative_tokens\":$K}")
    ;;
  dflash)
    SPEC_FLAG=$(spec_flag "{\"method\":\"dflash\",\"model\":\"$DFLASH_DRAFT\",\"num_speculative_tokens\":$K}")
    ;;
  mtp)
    # The checkpoint's own prediction heads. NO `model` key - there is no second
    # checkpoint to name, and supplying one is how you get a confusing loader
    # error instead of a clear config one.
    SPEC_FLAG=$(spec_flag "{\"method\":\"mtp\",\"num_speculative_tokens\":$K}")
    ;;
  none)
    # Empty, so compose emits nothing at all. This is the THROUGHPUT-optimal
    # setting on the published comparison, and it also frees the draft model's
    # separate KV cache - the largest allocation in any of the other three.
    SPEC_FLAG=""
    ;;
  *) echo "SPEC_METHOD must be dspark, dflash, mtp or none" >&2; exit 1 ;;
esac
export SPEC_FLAG

echo "model   $MODEL   (NVFP4 via Marlin on GB10 - not native FP4)"
if [[ ${SPEC_METHOD:-dspark} == none ]]; then
    echo "spec    none   (throughput-optimal, and it frees the draft KV cache)"
else
    echo "spec    ${SPEC_METHOD:-dspark}   k=$K   (acceptance is what proves it works)"
fi
echo

# The project name MUST match what `ws` computes, or `ws logs` and `ws down`
# would address a project this script never created. `ws up` exports it; the
# fallback covers running this script by hand. (This directory's name happens
# to need no sanitising - the dotted ones next to it do, which is why the
# canonical mapping lives in `ws` and is passed down rather than re-derived.)
docker compose --project-name "${WS_PROJECT:-ws-$(basename "$PWD")}" up -d "$@"

cat <<NEXT

endpoint  http://127.0.0.1:$PORT/v1
logs      ws logs vllm-nemotron35-lightning-nvfp4 -f

Expect minutes of 503s: ~2 minutes of engine init, and speculative verify
buffers are allocated on the FIRST REAL REQUEST rather than at boot - so a
server that starts cleanly can still die on the first burst of traffic. If it
does, lower GPU_MEMORY_UTILIZATION by 0.02 rather than anything else.

This is the workspace where the acceptance LADDER works. Use it:
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up spec-decode-accept
  BASE_URL=http://127.0.0.1:$PORT/v1 ws up vllm-quality-gate
NEXT
