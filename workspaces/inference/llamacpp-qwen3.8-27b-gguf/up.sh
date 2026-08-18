#!/usr/bin/env bash
# No compose: roles/ml builds llama.cpp natively for sm_121, and running the
# host binary avoids a second CUDA userspace inside a container.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

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

echo $! > .pid
echo "llama-server pid $(cat .pid), port $PORT, log $LOG"
echo "sampling defaults are Qwen3.8 THINKING mode (temp 1.0 / top_p 0.95)."
echo "for instruct mode set TEMP=0.7 TOP_P=0.80 in .env - see workspaces/README.md"
