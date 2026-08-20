#!/usr/bin/env bash
# DeepSeek-V4-Pro, 1.57T parameters, from NVMe.
#
# READ THIS BEFORE THE FLAGS. V4-Pro does not fit in memory on any GB10 and is
# not expected to. It runs anyway, mmapped off the NVMe, and the numbers say
# what that costs:
#
#   smallest published build   337 GB   (IQ1_S, one file)
#   free disk, stock node     ~515 GB   after the usual HF cache
#   unified memory             121 GB
#
# So the weights fit the DISK with ~175 GB to spare, and miss memory by 2.8x.
# That gap is survivable - llama.cpp mmaps the file and the page cache holds
# what it can - and it is also the entire performance story:
#
#   ~48B active params x ~1.63 bits / 8 = ~10 GB of expert weights per token
#
# against an NVMe that reads a few GB/s. That is SECONDS PER TOKEN, and it is
# offered as arithmetic - nobody here has run it. Expect the disk to be the
# bottleneck from the first token to the last, and watch it rather than the GPU.
#
# The 2-bit builds (569-587 GB) do NOT fit a stock node's disk. That is why the
# default is 1-bit rather than the more comfortable quantisation you would pick
# anywhere else - see workspace.yml for the full ladder and what it costs.
#
# If output quality matters more than running it at all, the answer is not a
# different quant. V4-Flash beats V4-Pro on every published agentic benchmark
# despite 13B active parameters against 48B:
#   ws up vllm-2node-deepseek-v4-flash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# The smallest V4-Pro GGUF published anywhere at the time of writing, and the
# only one that leaves real room on a 1 TB node. unsloth publish no 2-bit
# V4-Pro at all - their smallest is 850 GB - so the default comes from
# elsewhere. One file, not a shard set.
MODEL_REPO=${MODEL_REPO:-6block/DeepSeek-V4-Pro-0813-GGUF}
MODEL_FILE=${MODEL_FILE:-DeepSeek-V4-Pro-0813-IQ1_S.gguf}
PORT=${PORT:-8892}
CTX=${CTX:-8192}
LOG=${LOG:-$HOME/.local/state/ws-llamacpp-ds-v4-pro.log}

command -v llama-server >/dev/null || {
    echo "llama-server not found. roles/ml builds it: make apply TAGS=ml" >&2; exit 1; }

cache=${HF_HOME:-$HOME/.cache/huggingface}
avail=$(df -BG --output=avail "$cache" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1+0}')
need=${NEED_DISK_GB:-360}
if (( avail < need )); then
    cat >&2 <<EOF
$cache has ${avail} GB free and this needs ~${need}.

That is the honest blocker, and it is storage rather than memory: the model
does not fit in RAM either, but mmap makes that survivable and a full disk
does not. Options, in the order they are worth trying:

  1. Run V4-Flash instead. It beats V4-Pro on the published agentic
     benchmarks and this cluster can genuinely serve it:
       ws up vllm-2node-deepseek-v4-flash
  2. Attach external NVMe and point this at it:
       HF_HOME=/mnt/big/hf  in .env
  3. Reclaim space. 'du -sh \$HOME/.cache/huggingface/hub/*' first.
EOF
    exit 1
fi

mkdir -p "$(dirname "$LOG")"

# NOTE THE ABSENCE OF --no-mmap BELOW, which is the most important thing in
# this file. docs/hardware.md records the community claim that --no-mmap is
# faster on unified memory, and for every other model here that is worth
# testing. Here it is fatal: --no-mmap means "read all the weights into
# memory", and there are 337 GB of them against 121 GB. mmap is not a tuning
# choice in this workspace, it is the entire mechanism by which it runs.
nohup llama-server \
    --hf-repo "$MODEL_REPO" --hf-file "$MODEL_FILE" \
    --host 127.0.0.1 --port "$PORT" \
    --ctx-size "$CTX" \
    -ngl 999 \
    --temp "${TEMP:-1.0}" --top-p "${TOP_P:-1.0}" --min-p "${MIN_P:-0.01}" \
    --jinja \
    >>"$LOG" 2>&1 &

echo $! > .pid
echo "llama-server pid $(cat .pid), port $PORT, ctx $CTX, log $LOG"
echo
echo "337 GB downloads before anything loads, and then it pages from NVMe for"
echo "every token. Watch the disk, not the GPU:  iostat -x 2   /   gx10-top"
