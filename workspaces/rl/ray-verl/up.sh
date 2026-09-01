#!/usr/bin/env bash
# Runs a verl GRPO job. Interactive and blocking by design: an RL run is
# something you watch, not a service you background.
#
#   ws up ray-verl                  train
#   ws up ray-verl --prepare-data   build the dataset, then exit
#
# THE SHAPE OF THIS SCRIPT IS NOT A PREFERENCE, and the version it replaced
# could not have worked. It used to be
#
#   docker run verlai/verl:latest python3 -m verl.trainer.main_ppo ...
#
# and three separate things were wrong with that line:
#
#   1. `verlai/verl:latest` DOES NOT EXIST. ~150 tags, every one named after
#      its stack (vllm023.aarch64.dev1, trtllm-1.3.0rc15, uv.cu130.dev1), and
#      no `latest` among them. The pull fails with "no such manifest", which
#      reads as a network problem rather than a tag nobody published. Most of
#      them are also amd64-only, which narrows the choice further here.
#
#   2. NO verlai/verl IMAGE CONTAINS verl. `import verl` is a
#      ModuleNotFoundError in every one of them, and `pip show verl` finds
#      nothing. That is by design and verl's own install docs say so: "if you
#      use the images provided, you only need to install verl itself without
#      dependencies". The images ship the STACK - torch, vLLM, Ray - and you
#      bring the source. The `uv.*` tags go further and ship no .venv at all,
#      so even torch is unimportable until `uv sync` has run.
#
#   3. NO DATASET. See the guard below.
#
# So: a pinned SOURCE checkout, mounted where the image expects it, installed
# with --no-deps (seconds, because every dependency is already in the image),
# and only then the trainer. Verified on this hardware: verl 0.9.0 imports and
# verl.trainer.main_ppo loads under vllm023.aarch64.dev1 with torch 2.11.0+cu130.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# The newest tag that publishes an arm64 manifest AND is a stable stack image
# rather than a uv build environment. `ws check` reports it as an image like
# any other; what it does NOT contain is verl, which is the point above.
IMAGE=${IMAGE:-gx10/verl:sm121}
# Pinned like llama_cpp_version, and for the same reason: both boxes should
# come up identical, and `main` on the day you happened to clone is not that.
VERL_VERSION=${VERL_VERSION:-v0.9.0}
VERL_SRC=${VERL_SRC:-$HOME/src/verl}
CONFIG=${CONFIG:-grpo-qwen3-1.7b.yaml}
# NNODES=2 attaches to the cluster ./ray-cluster.sh built instead of starting a
# private single-node Ray. On one GB10 the trainer leaves the rollout 24.57 GiB
# and that is not enough; splitting it across both nodes is what the arithmetic
# asks for and why this cluster has a second box.
NNODES=${NNODES:-1}
DATA_DIR=${DATA_DIR:-data/gsm8k}

PREPARE_ONLY=0
[[ ${1:-} == --prepare-data ]] && { PREPARE_ONLY=1; shift; }

# Anything left over is passed straight to Hydra, which is how verl itself is
# meant to be steered - `ws up ray-verl trainer.val_before_train=false` skips
# the 15-minute baseline eval on a re-run, `... trainer.total_training_steps=1`
# proves the loop without waiting for an epoch.

[[ -f $CONFIG ]] || { echo "no config $CONFIG" >&2; exit 1; }

# --- the source ------------------------------------------------------------
# ~/src/verl mirrors where roles/ml puts llama.cpp, so both "the thing this
# repo builds from source" live in one place.
if [[ ! -d $VERL_SRC/.git ]]; then
    echo "==> cloning verl $VERL_VERSION into $VERL_SRC"
    git clone --depth 1 --branch "$VERL_VERSION" \
        https://github.com/volcengine/verl "$VERL_SRC"
else
    have=$(git -C "$VERL_SRC" describe --tags --always 2>/dev/null || echo unknown)
    [[ $have == "$VERL_VERSION" ]] || \
        echo "!  $VERL_SRC is at $have, not $VERL_VERSION - set VERL_VERSION or re-checkout" >&2
fi

# --- the patches -----------------------------------------------------------
# verl imports flash_attn.bert_padding unconditionally on non-NPU hardware, and
# there is no FlashAttention wheel for sm_121. patches/ carries the fallbacks.
# Applied to the checkout rather than the image because the checkout is what the
# containers bind-mount. Re-runs are a no-op: a patch that reverse-applies
# cleanly is already in.
apply_patches() {
    local p
    for p in "$PWD"/patches/*.patch; do
        [[ -e $p ]] || continue
        if git -C "$VERL_SRC" apply --reverse --check "$p" >/dev/null 2>&1; then
            continue                              # already applied
        elif git -C "$VERL_SRC" apply --check "$p" >/dev/null 2>&1; then
            git -C "$VERL_SRC" apply "$p"
            echo "==> applied $(basename "$p")"
        else
            echo "!  $(basename "$p") does not apply to $VERL_SRC ($VERL_VERSION)" >&2
            exit 1
        fi
    done
}
apply_patches

# --- the dataset -----------------------------------------------------------
# verl's data config defaults to ~/data/rlhf/gsm8k/*.parquet - $HOME inside the
# CONTAINER, so nothing on this host reaches it and nothing in this repo creates
# it. A run without these files gets as far as loading Ray and the trainer and
# then dies on a missing path, which is an expensive way to find out. The
# shipped config points at /work/data/gsm8k instead, because /work is this
# directory bind-mounted.
prepare_data() {
    echo "==> building $DATA_DIR with verl's own preprocessor"
    mkdir -p "$DATA_DIR"
    docker run --rm \
        -v "$VERL_SRC:/workspace/verl" -w /workspace/verl \
        -v "$PWD:/work" \
        -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf" -e HF_HOME=/hf -e HOME=/hf \
        -e HF_TOKEN="${HF_TOKEN:-}" \
        --user "$(id -u):$(id -g)" \
        "$IMAGE" \
        bash -c "PYTHONPATH=/workspace/verl python3 examples/data_preprocess/gsm8k.py --local_dir /work/$DATA_DIR"
}

if (( PREPARE_ONLY )); then
    prepare_data
    echo; echo "ready:"; ls -la "$DATA_DIR"
    exit 0
fi

if [[ ! -f $DATA_DIR/train.parquet || ! -f $DATA_DIR/test.parquet ]]; then
    echo "no dataset at $PWD/$DATA_DIR - verl needs train.parquet and test.parquet." >&2
    echo "  ws up ray-verl --prepare-data" >&2
    echo >&2
    echo "Any parquet with a 'prompt' column works - point DATA_DIR at it, or" >&2
    echo "edit data.train_files in $CONFIG." >&2
    exit 1
fi

echo "verl      $VERL_VERSION from $VERL_SRC"
echo "image     $IMAGE   (ships the stack; verl is installed from the mount)"
echo "config    $CONFIG"
echo "data      $DATA_DIR"
echo
echo "this holds the policy, a reference copy, optimiser state AND the rollout"
echo "engine in one 121 GB pool. Watch it: gx10-top"
echo

# --user is deliberately NOT set here, unlike prepare_data above: the trainer
# writes checkpoints and Ray's session state under paths the image owns, and
# the outputs that land in /work are ones you want anyway. The preprocessor
# only writes the parquet, so there it is free.
# -t ONLY WHEN THERE IS A TERMINAL. This workspace is interactive by design, and
# a hardcoded `-it` made that design a hard requirement: piping `ws up ray-verl`
# into a log, or running it from anything without a tty, died on
#   the input device is not a TTY
# after the preflight had already passed and printed a banner. -i is kept
# unconditionally so Ctrl-C still reaches the trainer, which is this
# workspace's documented teardown.
TTY=()
[[ -t 1 ]] && TTY=(-t)

# RAY'S OOM KILLER COUNTS THE WRONG THING ON COHERENT MEMORY. Its monitor
# trips on the node's total "used" at 95%, and on a GB10 that figure includes
# the page cache and /dev/shm - neither of which is the trainer's working set,
# and both of which the kernel reclaims under pressure. Measured: killed at
# 118.19/121.63 GB with the actual allocation still fitting.
#
# 0.98 gives the run the last 3% back. It is NOT a licence to overcommit: on
# coherent memory swap is a cliff, so if `gx10-top` shows swap GROWING, lower
# rollout.gpu_memory_utilization rather than raising this again.
RAY_MEM_THRESHOLD=${RAY_MEM_THRESHOLD:-0.98}

# TWO-NODE: RUN INSIDE THE HEAD CONTAINER, not beside it.
#
# The obvious shape - a fresh container with RAY_ADDRESS pointing at the head -
# does not work, and the reason is worth writing down because it costs an hour
# otherwise. A Ray CLIENT is not just a TCP connection to the GCS port: it needs
# the head's session state, and a sibling container has its own /tmp/ray.
# Measured here, with the head demonstrably healthy and :6379 listening:
#
#   ConnectionError: Failed to connect to Ray cluster at 192.168.1.70:6379
#
# while INSIDE the head, ray.init(address="auto") reports the whole cluster:
#   {'GPU': 2.0, 'CPU': 40.0, 'node:192.168.1.70': 1.0, 'node:192.168.1.68': 1.0}
#
# So the trainer runs there. workspaces/cluster/ray verifies itself the same way
# (`docker exec ws-ray-head ray status`), and the head already carries all of
# this: verl installed, the source mount, the HF cache and /work.
if (( NNODES > 1 )); then
    docker ps --format '{{.Names}}' | grep -qx ws-verl-ray-head || {
        echo "NNODES=$NNODES but no ray head is running - start it first:" >&2
        echo "  ./ray-cluster.sh up" >&2; exit 1; }
    echo "cluster   running inside ws-verl-ray-head, nnodes=$NNODES"
    echo
    exec docker exec -i "${TTY[@]}" \
        ws-verl-ray-head \
        bash -c "cd /workspace/verl && exec python3 -m verl.trainer.main_ppo \
                 --config-path /work --config-name '${CONFIG%.yaml}' \
                 trainer.nnodes=$NNODES $*"
fi

exec docker run --rm -i "${TTY[@]}" \
    -e RAY_memory_usage_threshold="$RAY_MEM_THRESHOLD" \
    --runtime nvidia --ipc host --shm-size "${SHM_SIZE:-32g}" \
    --network host \
    -v "$VERL_SRC:/workspace/verl" \
    -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf" -e HF_HOME=/hf \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "$PWD:/work" \
    -w /workspace/verl \
    "$IMAGE" \
    bash -c "pip3 install --no-deps -e . -q 2>/dev/null; \
             exec python3 -m verl.trainer.main_ppo \
                  --config-path /work --config-name '${CONFIG%.yaml}'"
