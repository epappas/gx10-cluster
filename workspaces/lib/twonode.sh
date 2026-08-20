#!/usr/bin/env bash
# Launch one vLLM server across BOTH nodes. Sourced by a workspace's up.sh,
# never executed.
#
# WHY THIS IS A LIBRARY AND THE REST OF workspaces/ IS NOT. Every other recipe
# here is deliberately standalone - read it, copy it, run it by hand. Two-node
# serving is the one case where that trade goes the other way, for the reason
# vllm-2node-tp2 already gives about its two ranks: the failure mode of a
# mismatch is SILENT. Ranks that disagree hang at init with no error, a
# container missing /dev/infiniband quietly runs at TCP speed, and a gloo
# interface variable set in one recipe and forgotten in another produces a
# cluster that works on Tuesday and not on Wednesday.
#
# That argument does not stop at the two ranks of one workspace. Two WORKSPACES
# that each carry their own copy of this wiring drift the same way, just more
# slowly and with nobody watching. So the wiring lives once, and a workspace
# supplies only what is genuinely model-specific.
#
# A workspace sets:
#   NAME          container name, on both nodes
#   IMAGE         same image on both ranks - a digest mismatch hangs at init
#   PORT          rank 0 serves here; rank 1 is headless
#   MODEL_ARGS    array of vLLM flags. Everything model-specific, and ONLY
#                 that: topology, rendezvous and RDMA are set here.
# and optionally MASTER_PORT, SHM_SIZE, PEER, MASTER_ADDR, MGMT_IFACE, IB_HCA.
#
# Then calls: twonode_up

twonode_resolve() {  # fills in whatever the workspace did not set
    NAME=${NAME:?twonode: NAME must be set}
    IMAGE=${IMAGE:?twonode: IMAGE must be set}
    PORT=${PORT:-8888}
    MASTER_PORT=${MASTER_PORT:-25000}
    SHM_SIZE=${SHM_SIZE:-32g}

    PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
    PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
    [[ -n ${PEER:-} ]] || { echo "no peer found; set PEER in .env" >&2; return 1; }

    # The rendezvous runs on the MANAGEMENT address, not the interconnect, and
    # the data path still uses RoCE. That is this repo's documented split and it
    # is NOT what the upstream recipes do (they point everything at the fabric
    # subnet): NCCL selects the RoCE data path independently through ibverbs,
    # while the bootstrap needs an address that is up even when the cable is not.
    # See docs/decisions.md#nccl-socket-ifname and #hosts-split.
    MGMT_IFACE=${MGMT_IFACE:-$(ip route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')}
    MASTER_ADDR=${MASTER_ADDR:-$(ip -4 addr show "$MGMT_IFACE" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')}
    [[ -n ${MASTER_ADDR:-} ]] || { echo "cannot determine MASTER_ADDR; set it in .env" >&2; return 1; }
}

twonode_common_env() {  # -> COMMON_ENV array
    # Env every rank needs. The RDMA-specific entries are the part that is easy
    # to omit and hard to diagnose - see the comments on each.
    COMMON_ENV=(
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
    # departure from the upstream recipes. MEASURED on this pair: with it unset,
    # NCCL discovered exactly the two ACTIVE devices and used both -
    #   NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE
    # - while correctly ignoring the two permanently-DOWN partitions. Pinning a
    # device list by hand is how you silently end up on one rail after a cable
    # moves. Set IB_HCA in .env only if a log shows the wrong device chosen.
    [[ -n ${IB_HCA:-} ]] && COMMON_ENV+=( -e "NCCL_IB_HCA=$IB_HCA" )

    # A workspace may add model-specific env the same way it adds flags.
    [[ -n ${EXTRA_ENV[*]:-} ]] && COMMON_ENV+=( "${EXTRA_ENV[@]}" )
    return 0
}

twonode_launch() {  # $1 = rank, $2 = "local"|<peer host>, $3 = this rank's IP
    local rank=$1 where=$2
    local args=(
        run -d --name "$NAME" --restart unless-stopped
        # host networking: the ranks address each other directly, and a bridge
        # would NAT the rendezvous.
        --network host --ipc host --shm-size "$SHM_SIZE"
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
        "${COMMON_ENV[@]}"
        # vLLM needs each rank's OWN address for distributed init.
        -e "VLLM_HOST_IP=${3:-}"
        -e "NODE_RANK=$rank"
        "$IMAGE"
        "${MODEL_ARGS[@]}"
        --nnodes 2 --node-rank "$rank"
        --master-addr "$MASTER_ADDR" --master-port "$MASTER_PORT"
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
        ssh -n -o BatchMode=yes "$where" "docker $(printf '%q ' "${args[@]}")" >/dev/null
    fi
}

twonode_up() {
    twonode_resolve || return 1
    twonode_common_env

    local peer_mgmt
    peer_mgmt=$(getent hosts "$PEER" | awk '{print $1; exit}')
    echo "rank 0  $(hostname)  $MASTER_ADDR   (serves :$PORT)"
    echo "rank 1  $PEER  ${peer_mgmt:-?}   (headless)"
    echo "image   $IMAGE"
    echo "master  $MASTER_ADDR:$MASTER_PORT"
    echo

    # Rank 1 first: rank 0 owns the rendezvous and a worker that arrives late is
    # fine, while a rank 0 with nobody to meet blocks until timeout.
    twonode_launch 1 "$PEER" "${peer_mgmt:-}"
    twonode_launch 0 local "$MASTER_ADDR"

    echo "started. loading tens of GB across two nodes takes MINUTES:"
    echo "  docker logs -f $NAME"
    echo "  curl -s localhost:$PORT/health && echo ready"
    echo
    echo "confirm it is on RoCE and not TCP - the failure that looks like slowness:"
    echo "  docker logs $NAME 2>&1 | grep -E 'NET/IB|NET/Socket'"
}

twonode_down() {
    local name=${1:?twonode_down: container name required} h
    local peers_file=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
    docker rm -f "$name" >/dev/null 2>&1 && echo "rank 0 stopped" || echo "rank 0 not running"
    [[ -r $peers_file ]] || return 0
    while read -r h; do
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" "docker rm -f $name >/dev/null 2>&1" 2>/dev/null \
            && echo "rank 1 on $h stopped" || echo "rank 1 on $h: unreachable or not running"
    done < <(awk '!/^#/ && NF {print $1}' "$peers_file" | sort -u)
}
