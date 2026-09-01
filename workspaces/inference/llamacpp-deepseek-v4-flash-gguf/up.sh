#!/usr/bin/env bash
# DeepSeek-V4-Flash on ONE node, 3-bit GGUF, no container.
#
# One node, and the quantisation is chosen against the memory budget rather
# than against the model. The ladder, from unsloth's own file listing:
#
#   UD-IQ1_S     82.5 GB      UD-Q3_K_M    128.1 GB
#   UD-IQ1_M     86.9 GB      UD-Q3_K_XL   128.2 GB
#   UD-IQ2_XXS   90.9 GB      UD-IQ4_NL    136.7 GB
#   UD-IQ2_M     90.9 GB  <-  UD-IQ4_XS    136.7 GB
#   UD-Q2_K_XL   96.8 GB      UD-Q4_K_XL   155.1 GB
#   UD-IQ3_XXS  104.2 GB      UD-Q8_K_XL   161.9 GB
#   UD-IQ3_S    116.1 GB      dspark draft  10.9 GB (Q8_0)
#
# UD-IQ2_M is the default because of what it leaves behind, not what it costs:
# 90.9 GB against ~112 GB available is ~21 GB of headroom, which is enough for
# the DSpark draft model AND a desktop session. UD-IQ3_XXS at 104.2 GB leaves
# ~8 GB, which is enough for neither.
#
# That headroom buys speculative decoding, which is worth more than one rung of
# quantisation on a memory-bound box: 90.9 + 10.9 = 101.8 GB still fits, and
# DSpark drafts several tokens per forward pass. Set DRAFT_FILE to turn it on.
#
# For DeepSeek-V4-Flash without any of these compromises, use both nodes - the
# FP8 checkpoint at ~149 GiB splits two ways with room for real KV:
#   ws up vllm-2node-deepseek-v4-flash
#
# If gx10-top shows swap growing, stop. On coherent memory swap is a cliff.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# WHERE THE WEIGHTS LAND, and it is not where the rest of this repo puts them.
# `llama-server --hf-repo/--hf-file` caches under $LLAMA_CACHE, which defaults
# to ~/.cache/llama.cpp - a DIFFERENT filesystem from $HF_HOME the moment
# anyone moves the HF cache. That matters twice:
#
#   `ws check` measures min_disk_gb at $HF_HOME. Left alone, it would clear a
#   download that then fills a disk it never looked at - and this repo's own
#   advice for "not enough room" is HF_HOME=/mnt/big/hf, which without this
#   line moves the check and not the bytes.
#
#   `ws check` also reports "weights cached" by looking under $HF_HOME/hub. A
#   model downloaded here would never show up there, so an already-cached
#   ~91 GB reads as "first run downloads them" forever.
#
# One cache directory answers both. LLAMA_CACHE is still honoured if set.
export LLAMA_CACHE=${LLAMA_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/llama.cpp}
mkdir -p "$LLAMA_CACHE"

MODEL_REPO=${MODEL_REPO:-unsloth/DeepSeek-V4-Flash-0731-GGUF}
# The first shard. llama.cpp follows the -0000N-of-0000M naming and fetches the
# rest itself; naming any other shard fails in a confusing way.
MODEL_FILE=${MODEL_FILE:-UD-IQ2_M/DeepSeek-V4-Flash-0731-UD-IQ2_M-00001-of-00003.gguf}
PORT=${PORT:-8891}
CTX=${CTX:-32768}
LOG=${LOG:-$HOME/.local/state/ws-llamacpp-ds-v4-flash.log}

command -v llama-server >/dev/null || {
    echo "llama-server not found. roles/ml builds it: make apply TAGS=ml" >&2; exit 1; }

# A late OOM here does not fail politely - it takes the session with it, and on
# unified memory the paging starts long before the kill. Refuse early instead.
avail=$(awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo)
# Same 96 as the manifest's min_unified_gb, deliberately - two numbers for one
# requirement is how `ws check` ends up passing something `ws up` then refuses.
# The draft model is 10.9 GB, and on this box that is exactly the difference
# between fitting and paging, so the guard has to know about it.
need=${NEED_GB:-96}
[[ -n ${DRAFT_FILE:-} ]] && need=${NEED_GB:-108}
if (( avail < need )); then
    echo "only ${avail} GB available and this needs ~${need} GB." >&2
    echo "close what you can, or run it across both nodes:" >&2
    echo "  ws up vllm-2node-deepseek-v4-flash" >&2
    echo "override with NEED_GB= in .env if you know better than this check." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG")"

args=(
    --hf-repo "$MODEL_REPO" --hf-file "$MODEL_FILE"
    --host 127.0.0.1 --port "$PORT"
    --ctx-size "$CTX"
    # -ngl 999 offloads every layer. On unified memory "offload" is bookkeeping
    # rather than a copy - there is one pool - but llama.cpp still needs
    # telling, and leaving layers on CPU silently halves throughput.
    #
    # This is also why the --n-cpu-moe and -ot ".ffn_.*_exps.=CPU" flags that
    # every x86 MoE guide recommends do NOTHING useful here. They exist to keep
    # experts in system RAM when VRAM is the scarce resource. There is no such
    # split on GB10; both sides of it are the same 121 GB.
    -ngl 999
    # DeepSeek's own numbers: temperature 1.0, top_p 1.0, min_p 0.01. top_p
    # 0.95 for agentic use. These are not preferences.
    --temp "${TEMP:-1.0}" --top-p "${TOP_P:-1.0}" --min-p "${MIN_P:-0.01}"
    --jinja
)

# DSpark speculative decoding. Off by default only because it needs a file this
# script will not download for you - at UD-IQ2_M it FITS (90.9 + 10.9 =
# 101.8 GB) and it is the single biggest speedup available here. It would not
# have fitted at UD-IQ3_XXS, which is most of why that is not the default.
if [[ -n ${DRAFT_FILE:-} ]]; then
    args+=(
        -md "$DRAFT_FILE"
        --spec-type draft-dspark
        --spec-draft-n-max "${SPEC_N:-3}"
        -ngld 99
    )
fi

nohup llama-server "${args[@]}" >>"$LOG" 2>&1 &

pid=$!
echo "$pid" > .pid
echo "llama-server pid $(cat .pid), port $PORT, ctx $CTX, log $LOG"

# DID IT SURVIVE THE FIRST FEW SECONDS? `nohup ... &` always succeeds, so
# without this the script prints a pid and a port for a process that is
# already gone and exits 0 - and the caller only finds out by reading a log
# nobody mentioned was the point. The observed case: a GGUF whose architecture
# this build of llama.cpp does not know dies about a second after launch, and
# `ws up` reported it started.
#
# NOT a wait for /health. A first run downloads tens to hundreds of GB and then
# loads it, which is legitimately an hour on the bigger recipes; a readiness
# gate there would time out on every healthy cold start. Dying is the only
# thing that is unambiguous this early, so that is all this checks.
settled=0
for _ in $(seq 1 "${SETTLE_STEPS:-10}"); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo >&2
        echo "llama-server exited $(( SECONDS )) s after launch. Last lines of $LOG:" >&2
        # \r, because llama.cpp's download progress is one enormous CR-joined
        # line - tail on the raw file shows that and nothing else.
        tr '\r' '\n' < "$LOG" | grep -v '^ *[0-9]' | tail -15 >&2
        echo >&2
        echo "'unknown model architecture' means this llama.cpp is older than the" >&2
        echo "model. The pin is llama_cpp_version in group_vars/all.yml, and the" >&2
        echo "build task will NOT redo itself on a bump - see roles/ml." >&2
        rm -f .pid
        exit 1
    fi
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { settled=1; break; }
    sleep 1
done
if (( settled )); then
    echo "ready: http://127.0.0.1:$PORT/v1"
else
    echo "still starting - weights download and load before /health answers."
    echo "  tail -f $LOG"
fi
echo "~91 GB off a cold cache is a long first download AND a long first load."
echo
echo "watch the memory, not the log - this is the workspace most likely to run"
echo "the box out of it:  gx10-top"
