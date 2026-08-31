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
# and optionally MASTER_PORT, SHM_SIZE, PEER, MASTER_ADDR, MGMT_IFACE, IB_HCA,
# IB_GID_INDEX, VLLM_API_KEY, EXTRA_ENV, EXTRA_MOUNTS, PRE_EXEC.
#
# Then calls: twonode_up
#
# EXTRA_MOUNTS and PRE_EXEC exist for one narrow case and should stay narrow.
# An image that needs a step run INSIDE the container before `vllm serve` -
# applying a patch that ships in the image but is not applied at build - cannot
# express that through MODEL_ARGS, because MODEL_ARGS are arguments to the
# entrypoint rather than a replacement for it. PRE_EXEC replaces the entrypoint
# with `bash -c "<PRE_EXEC>; exec vllm serve \"$@\""`, so the serve line is
# still assembled here, still identical on both ranks, and still the only thing
# a reader has to trust. If you find yourself reaching for these to set an env
# var or a flag, use EXTRA_ENV or MODEL_ARGS instead.

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
      # Not a privacy gesture - a crash. vLLM's usage reporter shells out to
      # py-cpuinfo, which returns EMPTY output on Grace/aarch64 and is then
      # JSON-parsed: the stats thread dies with JSONDecodeError in the middle
      # of an otherwise healthy boot, which reads as a model failure. Off is
      # also the right default for a private cluster.
      -e "VLLM_NO_USAGE_STATS=1"
      -e "DO_NOT_TRACK=1"
    )

    # OPTIONAL BEARER AUTH, and it is here rather than in a workspace's
    # MODEL_ARGS for one reason: vLLM reads VLLM_API_KEY natively as the
    # fallback for `--api-key`, so passing it this way keeps the key out of
    # argv - out of `ps`, out of the container's command line, and out of the
    # `non-default args` line vLLM logs at every boot. `--api-key <secret>`
    # puts it in all three. Empty means unauthenticated, which stays the
    # default: these servers listen on a private cluster and every other
    # workspace here assumes that.
    #
    # Only rank 0 serves an API, so only rank 0 needs it - it goes in the
    # common env anyway, because a variable that differs between ranks is the
    # class of thing this library exists to not have.
    [[ -n ${VLLM_API_KEY:-} ]] && COMMON_ENV+=( -e "VLLM_API_KEY=$VLLM_API_KEY" )

    # NCCL_IB_GID_INDEX is likewise NOT pinned here, and that IS the fix rather
    # than an omission. Pinning an index (upstream recipes pin 3) fails when
    # that entry is all-zero on one of the two cards - the launch survives
    # every preflight and then kills the WORKER rank about a minute in with
    # `ibv_modify_qp` errno 61. NCCL_IB_ROCE_VERSION_NUM=2 +
    # NCCL_IB_ADDR_FAMILY=AF_INET above ask NCCL to SELECT the RoCEv2 IPv4 GID
    # itself, on each card, which is the same answer without the failure mode.
    # `gx10-interconnect` prints the table if you ever need to pick by hand.
    [[ -n ${IB_GID_INDEX:-} ]] && COMMON_ENV+=( -e "NCCL_IB_GID_INDEX=$IB_GID_INDEX" )

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
    )
    [[ -n ${EXTRA_MOUNTS[*]:-} ]] && args+=( "${EXTRA_MOUNTS[@]}" )

    # The serve line, assembled ONCE for both ranks. Only the rank number and
    # who owns the API differ - everything else being identical is what stops
    # the silent init hang this library exists to prevent.
    local serve_args=(
        "${MODEL_ARGS[@]}"
        --nnodes 2 --node-rank "$rank"
        --master-addr "$MASTER_ADDR" --master-port "$MASTER_PORT"
    )
    # Only rank 0 serves the API; rank 1 is a headless worker.
    if [[ $rank == 0 ]]; then
        serve_args+=( --host 0.0.0.0 --port "$PORT" )
    else
        serve_args+=( --headless )
    fi

    if [[ -n ${PRE_EXEC:-} ]]; then
        # `bash -c SCRIPT NAME ARGS...` puts ARGS in "$@", so the serve line
        # stays a real argv rather than a string this file has to re-quote.
        args+=(
            --entrypoint bash "$IMAGE"
            -c "$PRE_EXEC"$'\n''exec vllm serve "$@"' twonode "${serve_args[@]}"
        )
    else
        args+=( "$IMAGE" "${serve_args[@]}" )
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
    [[ -n ${VLLM_API_KEY:-} ]] && {
        echo
        echo "auth is ON: send 'Authorization: Bearer <VLLM_API_KEY>' to /v1."
        echo "  the bench workspaces read API_KEY from the environment."
    }
    return 0
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

# Copy an already-downloaded HF repo to the peer, over the CABLE.
#
# Each rank loads weights from its own disk. Nothing about the HF cache is
# shared, so a two-node model has to land twice - and for the small checkpoints
# the other workspaces run, letting each node fetch its own copy from the Hub is
# fine and is what they do. It stops being fine at 164 GiB: the second copy is
# hours of WAN for bytes that are already sitting on a peer at the end of a
# 200 Gb/s cable that is cabled, trusted and idle.
#
# So this rsyncs over `<peer>.cluster`, which is the interconnect address
# (docs/decisions.md#hosts-split) rather than the management NIC every other
# SSH in this library uses. That is the one place in this repo where asking for
# the fast path explicitly is worth it, because this is bulk transfer rather
# than control traffic. Set STAGE_HOST to override if the cable is down and you
# would rather wait on the management link than on the Hub.
#
# rsync is resumable and idempotent: an interrupted run costs only time, and
# re-running verifies what is already there.
twonode_stage_model() {  # $1 = HF repo id (org/name)
    local repo=${1:?twonode_stage_model: HF repo id required}
    local slug="models--${repo//\//--}"
    local hf=${HF_HOME:-$HOME/.cache/huggingface}
    local src="$hf/hub/$slug"

    [[ -d $src ]] || {
        echo "not in this node's cache yet: $repo" >&2
        echo "  download it here first:  hf download $repo" >&2
        return 1
    }

    local peers_file=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
    local peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$peers_file" 2>/dev/null)}
    [[ -n ${peer:-} ]] || { echo "no peer found; set PEER" >&2; return 1; }
    local host=${STAGE_HOST:-$peer.cluster}

    # Both nodes run the SAME account (inventory.yml pins ansible_user for the
    # whole gx10 group), so $HOME is the same string on both sides and the
    # destination needs no translation. If that ever stops being true this is
    # the line that has to know.
    echo "staging $repo"
    echo "  from  $src"
    echo "  to    $host:$src"
    echo "  over  the interconnect, not the management NIC"
    echo
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "mkdir -p $(printf '%q' "$hf/hub")" || {
        echo "cannot reach $host - is the cable up? try: gx10-interconnect" >&2
        echo "  or stage over management instead: STAGE_HOST=$peer $0" >&2
        return 1
    }
    # --partial so an interrupted 164 GiB transfer resumes rather than restarts.
    rsync -a --partial --info=progress2 --human-readable \
        -e "ssh -o BatchMode=yes" "$src/" "$host:$src/"
}
