#!/usr/bin/env bash
# Get 196 GiB of checkpoint and ~96 GiB of packed Engram tables onto two nodes
# that cannot both hold them.
#
# THIS SCRIPT IS THE PORT. Everything else in this workspace is upstream's
# flags with three lowered defaults; this is the part that exists because THIS
# cluster's disks are what they are. Upstream's ./start.sh downloads both trees
# to the head and NFS-exports them. That peaks at 385 GiB before a single byte
# of Engram is packed, and odysseus has 274 GiB free. So the order changes:
#
#   1. Engram source   (189.1 GiB)        <- build input, not a runtime file
#   2. pack rank 1     (~96 GiB)          <- this rank's rows only
#   3. ship rank 1 to the peer, delete it locally
#   4. pack rank 0     (~96 GiB)
#   5. DELETE the Engram source           <- the 189 GiB goes away here
#   6. EXL3 checkpoint (196.2 GiB)        <- only now, into the space just freed
#
# Peak ~285 GiB instead of ~385 GiB, and the checkpoint never coexists with the
# source it does not need. Steps are individually re-runnable and each one
# checks its own free space first, so an interrupted stage resumes rather than
# restarts.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

HF_MODEL_REPO=${HF_MODEL_REPO:-Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw}
HF_ENGRAM_REPO=${HF_ENGRAM_REPO:-deepseek-ai/DeepSeek-V4.1-Flash}
IMAGE=${IMAGE:-ghcr.io/miaai-lab/deepseek-v4.1-flash-exl3-2x-dgx-sparks:2.9bpw}
STAGE=${STAGE_DIR:-$HOME/.cache/dsv41-exl3}
ENGRAM_SRC=${ENGRAM_SRC:-$STAGE/engram-src}
ENGRAM_PACKED=${ENGRAM_PACKED:-$STAGE/engram-packed}
PEER=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' \
    "${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}" 2>/dev/null || true)}

# MEASURED off the Hub API on 2026-09-13, not read off upstream's README (which
# rounds to ~197 and ~190). Re-measure rather than trust these if a repo moves:
#   curl -s https://huggingface.co/api/models/<repo>/tree/main?recursive=1
MODEL_GIB=197
ENGRAM_GIB=190
PACKED_GIB=96

_free_gib() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
_need() {  # $1 = path, $2 = GiB, $3 = what for
    local have; have=$(_free_gib "$(dirname "$1")")
    (( have >= $2 )) || {
        echo "not enough disk for $3: need ${2} GiB, have ${have} GiB free" >&2
        echo "  docs/runbooks/manage-storage.md#reclaim is the classification" >&2
        return 1
    }
}

plan() {
    local here peer_free="-"
    here=$(_free_gib "$STAGE")
    [[ -n ${PEER:-} ]] && peer_free=$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 \
        "$PEER" "df -BG --output=avail ${STAGE@Q} 2>/dev/null || df -BG --output=avail /" \
        2>/dev/null | tail -1 | tr -dc '0-9')
    cat <<PLAN
staging into $STAGE
peer         ${PEER:-<none found>}

                                   this node        peer
free now                            ${here} GiB       ${peer_free} GiB

step                                 needs    peak on this node
 1 engram source  (hardlinked)       ${ENGRAM_GIB} GiB    ${ENGRAM_GIB} GiB
 2 pack rank 1                        ${PACKED_GIB} GiB    $((ENGRAM_GIB+PACKED_GIB)) GiB
 3 ship rank 1 to peer, delete here     0 GiB    $((ENGRAM_GIB+PACKED_GIB)) GiB
 4 pack rank 0                        ${PACKED_GIB} GiB    $((ENGRAM_GIB+PACKED_GIB)) GiB
 5 delete engram source              -${ENGRAM_GIB} GiB
 6 checkpoint                        ${MODEL_GIB} GiB    $((MODEL_GIB+PACKED_GIB)) GiB

steady state here  $((MODEL_GIB+PACKED_GIB)) GiB + ~30 GiB image
steady state peer  ${PACKED_GIB} GiB + ~30 GiB image, and the checkpoint over NFS

THE PEER DOES NOT GET A COPY OF THE CHECKPOINT. It does not fit there and it
is not meant to - rank 1 reads it from this node. That export is Ansible's
half; see docs/decisions.md#dsv41-flash-exl3.
PLAN
}

fetch_engram() {
    _need "$ENGRAM_SRC" "$ENGRAM_GIB" "the Engram source"
    mkdir -p "$ENGRAM_SRC"
    # Two shards of a 48-shard tree. Without --include the loader's glob pulls
    # all 475.3 GiB, which is the mistake prepare_engram_src.py exists to stop.
    hf download "$HF_ENGRAM_REPO" --local-dir "$ENGRAM_SRC" \
        --include "model-00047-of-00048.safetensors" \
                  "model-00048-of-00048.safetensors" \
                  "model.safetensors.index.json" "config.json"
}

pack() {  # $1 = rank, $2 = output dir (defaults to the serving path)
    local rank=$1 out=${2:-$ENGRAM_PACKED}
    [[ -d $ENGRAM_SRC ]] || { echo "run --engram first" >&2; return 1; }
    _need "$ENGRAM_PACKED" "$PACKED_GIB" "the packed shard for rank $rank"
    mkdir -p "$out"
    # Runs in the serving image because engram_layout.py - which defines the
    # hash-head bucket ranges vLLM shards by - ships in the overlay and nowhere
    # else. Packing with a different [lo, hi) produces a shard
    # row_store_attach_packed rejects, so this must not be reimplemented here.
    docker run --rm \
        -v "$ENGRAM_SRC:/models:ro" -v "$out:/engram" \
        "$IMAGE" \
        python3 /opt/dsv41/scripts/pack_engram.py --rank "$rank" --tp 2 --out /engram
}

# THE MOUNT PATH IS THE SAME ON BOTH NODES AND THE CONTENTS ARE NOT. twonode.sh
# builds one docker command and runs it on both ranks, so `-v $ENGRAM_PACKED:...`
# has to resolve to rank 0's rows here and rank 1's rows there. Rank 1's shard is
# therefore packed into a scratch directory and rsynced ONTO the peer's
# $ENGRAM_PACKED - not into a rank1/ subdirectory, which would make the two
# ranks need different mount strings and defeat the reason the launcher is
# shared at all.
ship() {  # $1 = local scratch dir holding rank 1's shard
    [[ -n ${PEER:-} ]] || { echo "no peer; set PEER in .env" >&2; return 1; }
    # Over the cable, not the management NIC: the peers file is the
    # interconnect address, which is what makes this ~500 MB/s rather than
    # ~110. --partial so a dropped link resumes instead of restarting 96 GiB.
    ssh -n -o BatchMode=yes "$PEER" "mkdir -p $(printf '%q' "$ENGRAM_PACKED")"
    rsync -a --info=progress2 --partial "$1/" "$PEER:$ENGRAM_PACKED/"
}

fetch_model() {
    _need "$STAGE" "$MODEL_GIB" "the EXL3 checkpoint"
    hf download "$HF_MODEL_REPO" --local-dir "$STAGE/model"
    # MODEL must be a PATH, not a repo id - the overlay's loader joins the
    # model string with a filename instead of resolving through the Hub. Write
    # it where up.sh will read it, so the trap is paid once.
    touch .env
    grep -q '^MODEL=' .env && sed -i "s|^MODEL=.*|MODEL=$STAGE/model|" .env \
        || echo "MODEL=$STAGE/model" >> .env
    echo "MODEL=$STAGE/model written to .env"
}

case "${1:---plan}" in
  --plan)    plan ;;
  --engram)  fetch_engram ;;
  --pack)    pack "${2:-0}" "${3:-}" ;;
  --peer)    ship "${2:-$ENGRAM_PACKED.rank1}" ;;
  --model)   fetch_model ;;
  --all)
    # The order is the point. Do not reorder to "download everything first".
    plan
    read -r -p "proceed? [y/N] " a; [[ $a == y ]] || exit 1
    fetch_engram
    pack 1 "$ENGRAM_PACKED.rank1"
    ship "$ENGRAM_PACKED.rank1"
    rm -rf "$ENGRAM_PACKED.rank1"
    pack 0
    echo "deleting the ${ENGRAM_GIB} GiB Engram source - it is a build input, and"
    echo "the checkpoint does not fit until it is gone."
    read -r -p "delete $ENGRAM_SRC? [y/N] " a; [[ $a == y ]] || exit 1
    rm -rf "$ENGRAM_SRC"
    fetch_model
    ;;
  *) echo "usage: $0 [--plan|--engram|--pack RANK [DIR]|--peer [DIR]|--model|--all]" >&2; exit 1 ;;
esac
