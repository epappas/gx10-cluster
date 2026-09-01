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

# THE GUARD IS ABOUT THE DOWNLOAD, SO IT ONLY APPLIES IF THERE IS ONE. 360 GB
# is "room for 337 GB of weights plus somewhere to land"; once the blob is
# actually here that space is SPENT, not needed again - and the check as
# written then refuses to start a workspace whose weights are sitting on the
# disk it is measuring. Observed exactly that: the download finished, took the
# free space from 400 GB to 86 GB, and the next `up.sh` refused with "has 86 GB
# free and this needs ~360".
#
# Resolving the blob by its symlink rather than trusting `du`: xet writes the
# file sparsely, so `du` under-reports a COMPLETE download by tens of GB (322
# against 337 here). The size on the inode is the honest number.
have_weights=0
_snap=$cache/hub/models--${MODEL_REPO//\//--}/snapshots
_f=$(compgen -G "$_snap/*/$MODEL_FILE" 2>/dev/null | head -1) || _f=""
[[ -n $_f && -f $_f ]] && have_weights=1

if (( ! have_weights )) && (( avail < need )); then
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

# ---------------------------------------------------------------------------
# THE DOWNLOAD CANNOT GO THROUGH llama.cpp HERE, and that is a property of the
# FILE rather than of this recipe. --hf-repo/--hf-file fetches over plain HTTP
# `resolve/`, and this one is a 337 GB Xet-backed blob that answers that
# endpoint with:
#
#   failed to download model: Download '.../DeepSeek-V4-Pro-0813-IQ1_S.gguf'
#   failed with status code: 400
#
# The repo is public and not gated - `curl -I` on the same URL is also a 400,
# while huggingface_hub (which speaks the Xet protocol) resolves the metadata
# and downloads it. The sibling workspaces are unaffected: their files are
# sharded and small enough to serve the ordinary way.
#
# So the weights are staged FIRST with the Xet-aware client, and llama-server
# is pointed at the resulting path with -m. That also makes the download
# resumable and interruptible on its own, which matters more at 337 GB than
# anywhere else in this repo.
# ---------------------------------------------------------------------------
hf_cli() {
    local c
    for c in hf huggingface-cli "${ML_VENV:-$HOME/venvs/ml}/bin/hf"              "${ML_VENV:-$HOME/venvs/ml}/bin/huggingface-cli"; do
        command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
        [[ -x $c ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

MODEL_PATH=${MODEL_PATH:-}
if [[ -z $MODEL_PATH ]]; then
    cli=$(hf_cli) || {
        echo "no hf CLI found, and llama.cpp cannot fetch this file itself." >&2
        echo "roles/ml puts one in ~/venvs/ml/bin:" >&2
        echo "  ml && hf download $MODEL_REPO $MODEL_FILE" >&2
        exit 1
    }
    echo "staging $MODEL_FILE (~337 GB) with $cli - llama.cpp's own downloader"
    echo "cannot fetch this Xet-backed blob; see the note in this script."
    MODEL_PATH=$(HF_HOME=$cache "$cli" download "$MODEL_REPO" "$MODEL_FILE"                      ${HF_TOKEN:+--token "$HF_TOKEN"} | tail -1) || {
        echo "download failed - it is resumable, just run this again" >&2; exit 1; }
    # `hf download` prints `path=<abs path>` on its last line, NOT a bare path.
    # The ${x#path=} is a no-op if a future version drops the prefix.
    MODEL_PATH=${MODEL_PATH#path=}
fi
[[ -f $MODEL_PATH ]] || { echo "no such model file: $MODEL_PATH" >&2; exit 1; }

# NOTE THE ABSENCE OF --no-mmap BELOW, which is the most important thing in
# this file. docs/hardware.md records the community claim that --no-mmap is
# faster on unified memory, and for every other model here that is worth
# testing. Here it is fatal: --no-mmap means "read all the weights into
# memory", and there are 337 GB of them against 121 GB. mmap is not a tuning
# choice in this workspace, it is the entire mechanism by which it runs.
# -ngl 0, AND THIS IS THE LINE THAT TAKES A NODE DOWN IF YOU GET IT WRONG.
# Every other llama.cpp workspace here uses -ngl 999 ("offload everything"),
# and copying that default to this recipe is not a slow configuration, it is a
# request for 314 GiB of resident memory on a 121 GB box. It was tried: the
# node stopped answering on all three of its networks - management and both
# RoCE links - and needed a power cycle. There is no error message, because
# there is no longer a machine to print one.
#
# The whole premise of this workspace is that the weights stay on NVMe and the
# kernel pages in what a token actually touches. -ngl 0 is what expresses that.
# Raise it ONE small step at a time if you want, watching gx10-top, and stop
# the moment swap moves.
NGL=${NGL:-0}

# NO CUDA DEVICE AT ALL, and this is the line that makes the workspace work.
#
# The failure it fixes:
#     llama_model_load: error loading model: unable to allocate CUDA_Host buffer
#
# GGML_CUDA_NO_PINNED=1 looks like the answer and is not. It does what it says
# - ggml_cuda_host_malloc returns nullptr, the device stops advertising
# host_buffer - but the loader then just asks the CPU backend for the same
# thing, and fails one line lower down:
#     ggml_backend_cpu_buffer_type_alloc_buffer: failed to allocate buffer
#     of size 337256033472
#     alloc_tensor_range: failed to allocate CUDA_Host buffer of size 337256033472
# 337256033472 is the whole model. The point is not WHICH allocator is asked
# for 314 GiB, it is that llama.cpp is not mmapping at all: while any CUDA
# device is visible it plans to copy tensors into a backend buffer, and that
# plan cannot be satisfied here at any -ngl.
#
# With no device visible, llama.cpp takes the pure-CPU path, maps the file, and
# pages in what a token touches. Measured on this hardware: loads in ~3 min,
# 7 GB resident with the rest in page cache, swap 0, and 17*23 comes back 391
# at 0.67 tok/s. Seconds per token IS the advertised behaviour - see README.
#
# Set GX10_V4PRO_CUDA=1 to skip this and watch it fail, which is the only
# reason you would.
[[ ${GX10_V4PRO_CUDA:-0} == 1 ]] || export CUDA_VISIBLE_DEVICES=""

nohup llama-server \
    -m "$MODEL_PATH" \
    --host 127.0.0.1 --port "$PORT" \
    --ctx-size "$CTX" \
    -ngl "$NGL" \
    --temp "${TEMP:-1.0}" --top-p "${TOP_P:-1.0}" --min-p "${MIN_P:-0.01}" \
    --jinja \
    >>"$LOG" 2>&1 &

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
echo
echo "337 GB downloads before anything loads, and then it pages from NVMe for"
echo "every token. Watch the disk, not the GPU:  iostat -x 2   /   gx10-top"
