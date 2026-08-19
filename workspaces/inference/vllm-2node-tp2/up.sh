#!/usr/bin/env bash
# Two-node tensor-parallel vLLM. Rank 0 here, rank 1 on the peer.
#
# BOTH RANKS ARE LAUNCHED FROM THIS ONE SCRIPT, on purpose. The recipe this is
# ported from keeps a .env file on each node and warns you to sync it before
# restarting, with both ranks needing an identical image digest - a real
# operational hazard with a silent failure mode (mismatched ranks hang at
# init). Generating both command lines from a single place removes the class of
# bug rather than documenting it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

IMAGE=${IMAGE:-vllm/vllm-openai:nightly-aarch64}
MODEL=${MODEL:-nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4}
SERVED=${SERVED_NAME:-nemotron-120b}
PORT=${PORT:-8888}
MASTER_PORT=${MASTER_PORT:-25000}
GPU_UTIL=${GPU_MEMORY_UTILIZATION:-0.80}
MAX_LEN=${MAX_MODEL_LEN:-131072}
NAME=ws-vllm-2node

PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n ${PEER:-} ]] || { echo "no peer found; set PEER in .env" >&2; exit 1; }

# The rendezvous runs on the MANAGEMENT address, not the interconnect, and the
# data path still uses RoCE. That is this repo's documented split and it is NOT
# what the upstream recipe does (it points everything at the fabric subnet):
# NCCL selects the RoCE data path independently through ibverbs, while the
# bootstrap needs an address that is up even when the cable is not.
# See docs/decisions.md#nccl-socket-ifname and #hosts-split.
MGMT_IFACE=${MGMT_IFACE:-$(ip route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')}
MASTER_ADDR=${MASTER_ADDR:-$(ip -4 addr show "$MGMT_IFACE" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')}
[[ -n ${MASTER_ADDR:-} ]] || { echo "cannot determine MASTER_ADDR; set it in .env" >&2; exit 1; }

# Env every rank needs. The RDMA-specific entries are the part that is easy to
# omit and hard to diagnose - see the comments on each.
common_env=(
  -e "HF_HOME=/hf"
  -e "HF_TOKEN=${HF_TOKEN:-}"
  -e "PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
  # NCCL bootstrap. Management NIC, per the split above.
  -e "NCCL_SOCKET_IFNAME=$MGMT_IFACE"
  # vLLM's distributed init is torch.distributed, and GLOO DOES NOT READ
  # NCCL_SOCKET_IFNAME. Without these two it picks an interface by its own
  # heuristic - on this box that can be docker0 or the VPN - and the ranks
  # never meet. This is the single least obvious line in the file.
  -e "TP_SOCKET_IFNAME=$MGMT_IFACE"
  -e "GLOO_SOCKET_IFNAME=$MGMT_IFACE"
  # RoCE v2 explicitly: the GID table on this card carries BOTH v1 and v2
  # entries for every port, and only v2 is routable.
  -e "NCCL_IB_ROCE_VERSION_NUM=2"
  -e "NCCL_IB_ADDR_FAMILY=AF_INET"
  # There is no NVLink between two Sparks, so NVLS has nothing to accelerate.
  -e "NCCL_NVLS_ENABLE=0"
  -e "NCCL_DEBUG=${NCCL_DEBUG:-WARN}"
)

# NCCL_IB_HCA is deliberately NOT set by default, which is a considered
# departure from the upstream recipe. MEASURED on this pair: with it unset,
# NCCL discovered exactly the two ACTIVE devices and used both -
#   NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE
# - while correctly ignoring the two permanently-DOWN partitions. Pinning a
# device list by hand is how you silently end up on one rail after a cable
# moves. Set IB_HCA in .env only if a log shows the wrong device chosen.
[[ -n ${IB_HCA:-} ]] && common_env+=( -e "NCCL_IB_HCA=$IB_HCA" )

launch() {  # $1 = rank, $2 = "local"|<peer host>
    local rank=$1 where=$2
    local args=(
        run -d --name "$NAME" --restart unless-stopped
        # host networking: the ranks address each other directly, and a bridge
        # would NAT the rendezvous.
        --network host --ipc host --shm-size "${SHM_SIZE:-32g}"
        --runtime nvidia
        # THE TWO LINES THAT MAKE RDMA WORK INSIDE A CONTAINER, and the two
        # most commonly missing. Without the device nodes ibverbs finds no
        # adapter and NCCL falls back to TCP - which WORKS, just at a fraction
        # of the speed, so it looks like a slow model rather than a
        # misconfiguration. Without unlimited memlock the QPs cannot pin
        # memory and registration fails outright.
        --device /dev/infiniband:/dev/infiniband
        --ulimit memlock=-1
        -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf"
        "${common_env[@]}"
        # vLLM needs each rank's OWN address for distributed init.
        -e "VLLM_HOST_IP=${3:-}"
        -e "NODE_RANK=$rank"
        "$IMAGE"
        --model "$MODEL" --served-model-name "$SERVED"
        --trust-remote-code
        --tensor-parallel-size 2 --pipeline-parallel-size 1
        --distributed-executor-backend mp
        --nnodes 2 --node-rank "$rank"
        --master-addr "$MASTER_ADDR" --master-port "$MASTER_PORT"
        --gpu-memory-utilization "$GPU_UTIL"
        --max-model-len "$MAX_LEN"
        --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"
        --enable-prefix-caching --enable-chunked-prefill
    )
    # Only rank 0 serves the API; rank 1 is a headless worker.
    if [[ $rank == 0 ]]; then
        args+=( --host 0.0.0.0 --port "$PORT" )
    else
        args+=( --headless )
    fi

    if [[ $where == local ]]; then
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        docker "${args[@]}" >/dev/null
    else
        ssh -n -o BatchMode=yes "$where" "docker rm -f $NAME >/dev/null 2>&1 || true"
        # printf %q so the peer's shell sees exactly these argv elements.
        # shellcheck disable=SC2016
        ssh -n -o BatchMode=yes "$where" "docker $(printf '%q ' "${args[@]}")" >/dev/null
    fi
}

peer_mgmt=$(getent hosts "$PEER" | awk '{print $1; exit}')
echo "rank 0  $(hostname)  $MASTER_ADDR   (serves :$PORT)"
echo "rank 1  $PEER  ${peer_mgmt:-?}   (headless)"
echo "model   $MODEL  TP=2  master $MASTER_ADDR:$MASTER_PORT"
echo

# Rank 1 first: rank 0 owns the rendezvous and a worker that arrives late is
# fine, while a rank 0 with nobody to meet blocks until timeout.
launch 1 "$PEER" "${peer_mgmt:-}"
launch 0 local "$MASTER_ADDR"

echo "started. loading 75 GB across two nodes takes MINUTES:"
echo "  docker logs -f $NAME"
echo "  curl -s localhost:$PORT/health && echo ready"
echo
echo "confirm it is on RoCE and not TCP - the failure that looks like slowness:"
echo "  docker logs $NAME 2>&1 | grep -E 'NET/IB|NET/Socket'"
