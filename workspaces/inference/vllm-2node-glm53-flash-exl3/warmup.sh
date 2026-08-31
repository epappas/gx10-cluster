#!/usr/bin/env bash
# Burn the JIT shapes before the first real client does, then prove it worked.
#
# WHAT THIS IS FOR. Triton and TileLang compile per SHAPE, not per model. The
# persistent caches this workspace bind-mounts mean each shape compiles once
# per image - but "once" still has to happen somewhere, and if it happens
# inside a served request on TP=2 then the OTHER rank is sitting in a
# collective waiting for it. That is the same mechanism the JIT cache mounts
# exist to prevent, just moved from `docker rm` to the first user.
#
# The cost of not doing this is latency, never correctness, which is why it is
# a separate script rather than part of up.sh: nothing here is a precondition
# for a working server. Run it when the first request being slow would matter.
#
#   ./warmup.sh                       # waits for /health, then sweeps
#   ./warmup.sh http://host:8893 name # against something else
#
# It is non-fatal by construction and exits non-zero only to report that some
# shape was NOT warmed - the server is fine either way.
#
# Ported from MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks scripts/. The three
# things in it that are knowledge rather than plumbing are marked below: the
# BLOCK ladder is derived from THIS model's formula and must not be copied from
# a DSpark recipe, the sampler compiles three distinct constexpr variants and
# the obvious warmup only ever hits one of them, and a rung that is not
# tokenize-verified warms a block you did not mean to warm and reports success.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

BASE=${1:-http://127.0.0.1:${PORT:-8893}}
MODEL=${2:-${SERVED_NAME:-glm-5.3-flash-exl3}}
REQ_TIMEOUT=${WARMUP_REQ_TIMEOUT:-240}
MAX_CONCURRENCY=${MAX_NUM_SEQS:-4}
DFLASH_K=${DRAFT_TOKENS:-7}
HEALTH_WAIT=${WARMUP_HEALTH_WAIT:-1800}
TRITON_CACHE=${WARMUP_TRITON_CACHE:-${JIT_CACHE:-$HOME/.cache/vllm-glm53-exl3}/triton}

AUTH=()
[[ -n ${VLLM_API_KEY:-} ]] && AUTH=(-H "Authorization: Bearer $VLLM_API_KEY")

case $MAX_CONCURRENCY in ''|*[!0-9]*|0) MAX_CONCURRENCY=4 ;; esac
case $DFLASH_K in ''|*[!0-9]*) DFLASH_K=7 ;; esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
nonce="$$-$(date +%s)"

next_pow2() { local n=$1 p=1; while ((p < n)); do p=$((p * 2)); done; printf '%s' "$p"; }

# THE BLOCK LADDER, and the one number in it that is model-specific.
#
# This image sizes the DFlash2 draft block as
#     BLOCK = min(256, next_pow2(scheduled_tokens + num_query_per_req))
# with num_query_per_req = 1 + k. At k=7 that is +8, so BLOCK 8 is
# UNREACHABLE - the smallest schedule is 1 token, which is 9, which rounds to
# 16. A DSpark recipe's ladder is built on next_pow2(s + 6) and warms a
# different set; copying it warms shapes this server never asks for and misses
# the ones it does. One `s` per live BLOCK in {16,32,64,128,256}:
LADDER_S=(1 24 56 120 248)

wait_for_health() {
    local waited=0
    printf 'waiting for %s/health' "$BASE"
    while ((waited < HEALTH_WAIT)); do
        if curl -fsS --max-time 5 "${AUTH[@]}" "$BASE/health" >/dev/null 2>&1; then
            printf ' ok (%ss)\n' "$waited"; return 0
        fi
        sleep 10; waited=$((waited + 10)); printf '.'
    done
    printf '\n'
    echo "warmup: /health never came up in ${HEALTH_WAIT}s - is it still loading?" >&2
    echo "  docker logs -f ws-vllm-glm53-exl3" >&2
    return 1
}

filler() { local n=$1 out="hello" i; for ((i = 1; i < n; i++)); do out="$out hello"; done; printf '%s' "$out"; }

# A rung fires /completions at an EXACT token count, so /tokenize has to agree
# before it counts. Without this a tokenizer that costs a token more than the
# loop assumed pushes s past a power of two, a different BLOCK gets compiled,
# and the sweep reports a warm cache for a shape it never touched.
ladder_rung() {
    local s=$1 prompt want got resp
    prompt=$(filler "$s")
    want=$(next_pow2 $((s + DFLASH_K + 1))); ((want > 256)) && want=256
    resp=$(curl -fsS --max-time 30 "${AUTH[@]}" "$BASE/tokenize" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"prompt\":\"$prompt\"}" 2>>"$tmp/errors")
    got=$(printf '%s' "$resp" | grep -o '"count"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | head -1)
    if [[ -z $got || $got -ne $s ]]; then
        echo "  s=$s: /tokenize says ${got:-?}, need exactly $s - SKIPPED, BLOCK $want not warmed" >&2
        echo fail > "$tmp/ladder-$s"; return
    fi
    if curl -fsS --max-time "$REQ_TIMEOUT" "${AUTH[@]}" "$BASE/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"prompt\":\"$prompt\",\"max_tokens\":1,\"temperature\":0}" \
        >/dev/null 2>>"$tmp/errors"; then
        echo ok > "$tmp/ladder-$s"; echo "  s=$s -> BLOCK $want"
    else
        echo fail > "$tmp/ladder-$s"; echo "  s=$s -> BLOCK $want FAILED"
    fi
}

# THE SAMPLER ARMS, and why the obvious warmup misses two of three.
#
# The top-k/top-p kernel specialises on which tensors are None: k-only, p-only
# and k+p are three DIFFERENT compilations. This checkpoint's Hub
# generation_config.json stamps top_p=0.95, so a request that sets only top_k
# still arrives with a p tensor and compiles k+p - the k-only variant is never
# reached by any natural request. top_p=1.0 and top_k=0 are how this build
# drops the respective tensor, so they are the only way to ask for the other
# two shapes on purpose.
arm_payload() {
    local prompt=$1 profile=$2 think=$3 fields
    case $profile in
        serve-default) printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"temperature":0}' "$MODEL" "$prompt"; return ;;
        sampling-k)  fields='"top_k":40,"top_p":1.0' ;;
        sampling-p)  fields='"top_k":0,"top_p":0.9' ;;
        sampling-kp) fields='"top_k":40,"top_p":0.9' ;;
        *)           printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":24,"temperature":0,"chat_template_kwargs":{"enable_thinking":%s}}' "$MODEL" "$prompt" "$think"; return ;;
    esac
    printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":24,"temperature":0.8,%s,"chat_template_kwargs":{"enable_thinking":%s}}' \
        "$MODEL" "$prompt" "$fields" "$think"
}

fire() {
    local tag=$1 words=$2 profile=$3 think=$4 out=$5 prompt
    prompt="[warmup $nonce $tag] ignore this filler: $(filler "$words") Reply with OK."
    if curl -fsS --max-time "$REQ_TIMEOUT" "${AUTH[@]}" "$BASE/v1/chat/completions" \
        -H 'Content-Type: application/json' -d "$(arm_payload "$prompt" "$profile" "$think")" \
        >/dev/null 2>>"$tmp/errors"; then echo ok > "$out"; else echo fail > "$out"; fi
}

burst() {
    local arm=$1 c=$2 words=$3 profile=${4:-bounded} think=${5:-false} i t0
    t0=$SECONDS
    for ((i = 1; i <= c; i++)); do fire "$arm-$i" "$words" "$profile" "$think" "$tmp/$arm-$i" & done
    wait
    echo "  arm $arm: C=$c x ~$words tok, $profile, think=$think, $((SECONDS - t0))s"
}

# THE POSTCONDITION, and the reason the sweep is not self-reporting. Every
# request above can return 200 while a variant was never compiled - the arm
# went through a path that already had a cache entry. The only direct evidence
# is the cache itself: one .ttir per compilation, and which of %K / %P it
# references says which constexpr combination it was built for.
sampler_combos() {
    local ttir k p
    for ttir in "$TRITON_CACHE"/*/_topk_topp_kernel.ttir; do
        [[ -f $ttir ]] || continue
        k=$(grep -cE '%K[^A-Za-z0-9_]' "$ttir"); p=$(grep -cE '%P[^A-Za-z0-9_]' "$ttir")
        if ((k > 1 && p > 1)); then echo k+p
        elif ((k > 1)); then echo k-only
        elif ((p > 1)); then echo p-only
        else echo neither; fi
    done | sort -u
}

curl -fsS --max-time 10 "${AUTH[@]}" "$BASE/v1/models" >/dev/null 2>&1 || wait_for_health || exit 1

echo "warmup  $BASE  model=$MODEL  k=$DFLASH_K  concurrency<=$MAX_CONCURRENCY"
t0=$SECONDS

echo "draft BLOCK ladder:"
for s in "${LADDER_S[@]}"; do ladder_rung "$s"; done

echo "sampler and batch arms:"
expected=6
burst c1        1 32 bounded false
burst think-c1  1 16 bounded true
burst short-c1  1 8  serve-default
burst samp-k    1 8  sampling-k
burst samp-p    1 8  sampling-p
burst samp-kp   1 8  sampling-kp
((MAX_CONCURRENCY >= 2)) && { burst short-c2   2 8 serve-default; expected=$((expected + 2)); }
((MAX_CONCURRENCY >= 3)) && { burst samp-kp-c3 3 8 sampling-kp;   expected=$((expected + 3)); }
((MAX_CONCURRENCY >= 4)) && { burst short-c4   4 8 serve-default; expected=$((expected + 4)); }
((MAX_CONCURRENCY > 4)) && echo "  note: batch shapes above C=4 are not pre-warmed" >&2

total=0 ok=0
for f in "$tmp"/*-*; do
    [[ -f $f ]] || continue
    total=$((total + 1)); [[ $(cat "$f") == ok ]] && ok=$((ok + 1))
done
echo "warmup  $ok/$total requests ok in $((SECONDS - t0))s"

rc=0
if ((ok < total)); then
    echo "warmup: $((total - ok)) request(s) failed - those shapes may JIT mid-serve" >&2
    sed -n '1,5p' "$tmp/errors" 2>/dev/null >&2
    rc=1
fi

if [[ -d $TRITON_CACHE ]]; then
    combos=$(sampler_combos)
    missing=""
    for want in k-only p-only k+p; do
        printf '%s\n' "$combos" | grep -qx "$want" || missing="$missing $want"
    done
    if [[ -z $missing ]]; then
        echo "warmup  sampler cache holds all three constexpr variants"
    else
        echo "warmup: sampler variants missing:$missing - they may JIT mid-serve" >&2
        rc=1
    fi
else
    echo "warmup  sampler postcondition SKIPPED ($TRITON_CACHE is not a directory)"
fi
exit $rc
