#!/usr/bin/env bash
# Head here, worker on each peer, over SSH. No compose: the worker half runs on
# a DIFFERENT machine, which compose has no notion of, and inventing a
# swarm/k8s dependency to express "two boxes" would be far more machinery than
# the thing it manages.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

IMAGE=${IMAGE:-rayproject/ray:latest-py312-aarch64}
PORT=${RAY_PORT:-6379}
DASH=${DASH_PORT:-8265}
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}

# The head must be reachable BY THE WORKERS, so it binds the management
# address, not loopback. That is the same split the rest of the repo uses:
# control plane on the always-up NIC, data plane on the cable.
HEAD_IP=${HEAD_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}
[[ -n $HEAD_IP ]] || { echo "cannot determine head IP; set HEAD_IP in .env" >&2; exit 1; }

echo "==> head on $HEAD_IP:$PORT (dashboard :$DASH)"
docker run -d --name ws-ray-head --restart unless-stopped \
    --runtime nvidia --ipc host --shm-size "${SHM_SIZE:-16g}" \
    --network host \
    -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf" -e HF_HOME=/hf \
    "$IMAGE" \
    ray start --head --block \
        --node-ip-address="$HEAD_IP" --port="$PORT" \
        --dashboard-host=0.0.0.0 --dashboard-port="$DASH" \
        --num-gpus="${NUM_GPUS:-1}" >/dev/null
echo "    started"

# Workers. A peer that is off is reported and skipped rather than fatal - a
# one-node Ray cluster is a legitimate thing to want.
if [[ -r $PEERS_FILE ]]; then
    # -n on each ssh below: inside a `while read` loop ssh otherwise consumes
    # the loop's stdin and only the FIRST peer is ever started.
    while read -r h; do
        echo "==> worker on $h"
        if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null; then
            echo "    unreachable, skipped"; continue
        fi
        ssh -n -o BatchMode=yes "$h" \
            "docker rm -f ws-ray-worker >/dev/null 2>&1;
             docker run -d --name ws-ray-worker --restart unless-stopped \
               --runtime nvidia --ipc host --shm-size ${SHM_SIZE:-16g} --network host \
               -v \${HF_HOME:-\$HOME/.cache/huggingface}:/hf -e HF_HOME=/hf \
               $IMAGE ray start --block --address=$HEAD_IP:$PORT --num-gpus=${NUM_GPUS:-1}" >/dev/null
        echo "    started"
    done < <(awk '!/^#/ && NF {print $1}' "$PEERS_FILE" | sort -u)
fi

echo
echo "dashboard: http://127.0.0.1:$DASH"
echo "verify:    docker exec ws-ray-head ray status"
