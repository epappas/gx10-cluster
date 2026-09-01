#!/usr/bin/env bash
# Stand up a Ray cluster made of THE VERL IMAGE, across both nodes.
#
# WHY THIS EXISTS SEPARATELY FROM workspaces/cluster/ray. That workspace runs
# rayproject/ray, which is the right image for a general-purpose cluster and the
# wrong one here: every Ray worker in an RL run imports verl, torch and vLLM, so
# the workers have to BE the training image. Same shape, different image, and
# the GPU env is the same lesson - see cluster/ray/up.sh for why
# NVIDIA_VISIBLE_DEVICES has to be set explicitly.
#
# WHY TWO NODES AT ALL. On ONE GB10 the FSDP trainer holds ~97 GiB of the 121
# and the co-resident vLLM rollout is left 24.57 GiB - which is not enough, and
# the only utilisation that reaches the rollout phase gets there by swapping.
# Splitting the trainer across two nodes is the fix the arithmetic asks for,
# and it is the whole reason this cluster has a second box.
#
#   ./ray-cluster.sh up     head here, worker on the peer
#   ./ray-cluster.sh down
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

IMAGE=${IMAGE:-gx10/verl:sm121}
PORT=${RAY_PORT:-6379}
DASH=${DASH_PORT:-8265}
VERL_SRC=${VERL_SRC:-$HOME/src/verl}
HF=${HF_HOME:-$HOME/.cache/huggingface}
# The memory monitor that kills workers runs in the RAYLET, so this has to be
# set on `ray start` - setting it on the process that submits the job is too
# late and too far away. Default 0.95 leaves 6GB unusable on a 121GB box, and
# an 8B actor update lands inside that margin.
# RAY'S OOM KILLER IS WRONG ON THIS BOX, so it is off by default here.
# It compares psutil's used bytes against total and kills workers past a
# fraction of it. On a discrete-GPU node that tracks something real. On GB10
# there is one pool, and the number it reads includes ~25GB of page cache from
# streaming safetensors off NVMe plus ~20GB of /dev/shm - the first is
# reclaimable on demand and the second is not the trainer's. The result is
# workers killed at a transient weight-sync spike the kernel would have
# absorbed by dropping cache:
#     5 Workers (tasks / actors) killed due to memory pressure (OOM),
#     0 Workers crashed due to other reasons
# leaving the driver blocked forever on actors that will not answer.
# refresh_ms=0 disables the monitor; the kernel OOM killer and 15GB of swap
# remain as the real backstop. Set RAY_MEM_MONITOR_MS to a positive number of
# milliseconds to put it back.
MONITOR_MS=${RAY_MEM_MONITOR_MS:-0}
MEM_THRESHOLD=${RAY_MEM_THRESHOLD:-0.97}
# Ray sizes its object store at 30% of RAM - 36GB here - and it lives in
# /dev/shm, which is NOT reclaimable and therefore counts against the threshold
# above. A GRPO step moves a few MB of prompts and rollouts, so the default is
# 20-odd GB of headroom spent on nothing.
OBJ_STORE=${RAY_OBJECT_STORE_BYTES:-4000000000}
WORK_STAGE=${WORK_STAGE:-$HOME/.cache/gx10/ws-verl-work}
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
HEAD_IP=${HEAD_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}

# Same two variables as cluster/ray: --runtime nvidia injects nothing unless
# NVIDIA_VISIBLE_DEVICES is set, and this image's base does not set it.
GPU_ENV=(-e NVIDIA_VISIBLE_DEVICES=all -e "NVIDIA_DRIVER_CAPABILITIES=compute,utility")

down() {
    docker rm -f ws-verl-ray-head >/dev/null 2>&1 && echo "head stopped" || echo "head not running"
    [[ -r $PEERS_FILE ]] || return 0
    while read -r h; do
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" \
            'docker rm -f ws-verl-ray-worker >/dev/null 2>&1' 2>/dev/null \
            && echo "worker on $h stopped" || echo "worker on $h: not running"
    done < <(awk '!/^#/ && NF {print $1}' "$PEERS_FILE" | sort -u)
}

case "${1:-up}" in
  down) down; exit 0 ;;
  up)   : ;;
  *)    echo "usage: ray-cluster.sh [up|down]" >&2; exit 2 ;;
esac

[[ -n $HEAD_IP ]] || { echo "cannot determine head IP; set HEAD_IP in .env" >&2; exit 1; }
down >/dev/null 2>&1 || true

echo "==> head on $HEAD_IP:$PORT (dashboard :$DASH)"
docker run -d --name ws-verl-ray-head --restart unless-stopped \
    --runtime nvidia "${GPU_ENV[@]}" --ipc host --shm-size "${SHM_SIZE:-4g}" \
    --network host \
    -v "$VERL_SRC:/workspace/verl" -w /workspace/verl \
    -v "$HF:/hf" -e HF_HOME=/hf -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "$PWD:/work" \
    -e RAY_memory_usage_threshold="$MEM_THRESHOLD" \
    -e RAY_memory_monitor_refresh_ms="$MONITOR_MS" \
    "$IMAGE" \
    bash -c "pip3 install --no-deps -e . -q 2>/dev/null;
             exec ray start --head --block \
                  --node-ip-address=$HEAD_IP --port=$PORT \
                  --dashboard-host=0.0.0.0 --dashboard-port=$DASH --num-gpus=1 \
                  --object-store-memory=$OBJ_STORE" >/dev/null
echo "    started"

if [[ -r $PEERS_FILE ]]; then
    while read -r h; do
        echo "==> worker on $h"
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null || {
            echo "    unreachable, skipped"; continue; }
        # Every node runs verl out of its own bind-mount, so the worker needs the
        # same tree as the head - same tag AND the same patches/ applied, or the
        # two halves of one training step disagree about what the code is.
        echo "    staging $VERL_SRC"
        rsync -a --delete --exclude .git/ \
            "$VERL_SRC/" "$h:$VERL_SRC/" || {
            echo "    rsync failed, skipped"; continue; }
        # /work has to exist on EVERY node, not just this one. verl creates its
        # driver with a bare `task_runner_class.remote()` - no scheduling
        # strategy - so Ray is free to place the TaskRunner on any node in the
        # cluster, and the node it picks is the one that opens the dataset and
        # the config. Land it on a node without /work and the run dies before
        # the first step with:
        #   FileNotFoundError: Unable to find '/work/data/gsm8k/train.parquet'
        # ...having read the config off the head, so nothing about the message
        # points at the node that failed. Staged to a cache path rather than
        # mirrored to $PWD so this cannot overwrite a checkout on the peer.
        echo "    staging $PWD -> $h:$WORK_STAGE"
        ssh -n -o BatchMode=yes "$h" "mkdir -p $(printf '%q' "$WORK_STAGE")" || continue
        rsync -a --delete "$PWD/" "$h:$WORK_STAGE/" || {
            echo "    rsync failed, skipped"; continue; }
        ssh -n -o BatchMode=yes "$h" \
          "docker rm -f ws-verl-ray-worker >/dev/null 2>&1;
           docker run -d --name ws-verl-ray-worker --restart unless-stopped \
             --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all \
             -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
             --ipc host --shm-size ${SHM_SIZE:-4g} --network host \
             -v $(printf '%q' "$VERL_SRC"):/workspace/verl -w /workspace/verl \
             -v $(printf '%q' "$HF"):/hf -e HF_HOME=/hf \
             -v $(printf '%q' "$WORK_STAGE"):/work \
             -e RAY_memory_usage_threshold=$MEM_THRESHOLD \
             -e RAY_memory_monitor_refresh_ms=$MONITOR_MS \
             $IMAGE \
             bash -c 'pip3 install --no-deps -e . -q 2>/dev/null;
                      exec ray start --block --address=$HEAD_IP:$PORT --num-gpus=1 --object-store-memory=$OBJ_STORE'" >/dev/null
        echo "    started"
    done < <(awk '!/^#/ && NF {print $1}' "$PEERS_FILE" | sort -u)
fi

echo
echo "verify:  docker exec ws-verl-ray-head ray status"
echo "then:    NNODES=2 ws up ray-verl"
