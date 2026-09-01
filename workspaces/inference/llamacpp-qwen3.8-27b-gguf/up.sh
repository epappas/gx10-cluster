#!/usr/bin/env bash
# No compose: roles/ml builds llama.cpp natively for sm_121, and running the
# host binary avoids a second CUDA userspace inside a container.
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

MODEL_REPO=${MODEL_REPO:-unsloth/Qwen3.8-27B-GGUF}
MODEL_FILE=${MODEL_FILE:-Qwen3.8-27B-UD-Q4_K_XL.gguf}
PORT=${PORT:-8899}
CTX=${CTX:-262144}
LOG=${LOG:-$HOME/.local/state/ws-llamacpp.log}

command -v llama-server >/dev/null || {
    echo "llama-server not found. roles/ml builds it: make apply TAGS=ml" >&2; exit 1; }

mkdir -p "$(dirname "$LOG")"

# -ngl 999 offloads every layer. On unified memory "offload" is bookkeeping
# rather than a copy - there is one pool - but llama.cpp still needs telling,
# and leaving layers on CPU silently halves throughput.
nohup llama-server \
    --hf-repo "$MODEL_REPO" --hf-file "$MODEL_FILE" \
    --host 127.0.0.1 --port "$PORT" \
    --ctx-size "$CTX" -ngl 999 \
    --temp "${TEMP:-1.0}" --top-p "${TOP_P:-0.95}" --top-k "${TOP_K:-20}" --min-p "${MIN_P:-0.0}" \
    --jinja \
    >>"$LOG" 2>&1 &

pid=$!
echo "$pid" > .pid
echo "llama-server pid $(cat .pid), port $PORT, log $LOG"

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
echo "sampling defaults are Qwen3.8 THINKING mode (temp 1.0 / top_p 0.95)."
echo "for instruct mode set TEMP=0.7 TOP_P=0.80 in .env - see workspaces/README.md"
