#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 EXL3 on the pair, TensorFold's Zig engine.
#
# ONE INTERFACE, as everywhere in this directory: `ws up` stages, completes
# and boots. It is guarded and idempotent at every step, so rerunning it is
# the resume, and there is nothing else to remember. `ws down` stops both
# ranks through the kit; `ws check` answers "may I".
#
# WHAT `ws up` DOES, in order, skipping whatever is already in place:
#
#   1. gates        - disk on both Sparks (this recipe's numbers, below), the
#                     peer from the inventory, the host `hf` from roles/ml.
#   2. stages       - in the ONE order that fits this pair's disk, then the
#                     kit's own prepare.sh, offline, to CONFIRM all of it.
#   3. boots        - ./start.sh: memory preflight with the await-memory
#                     re-read, both ranks, smoke test. The stage that needs
#                     the ~112 GB which only the old server's stopping frees.
#
# WHY THE STAGE ORDER IS OURS AND NOT PREPARE.SH'S: their fixed sequence
# (image, checkpoint, Engram, rank files) needs checkpoint+Engram+rank0 to
# COEXIST - a ~545 GB peak this pair does not have (541 head at the 2026-10-20
# reclaim measurement). But the checkpoint's 38 big shards are build inputs:
# once BOTH rank weight files exist, nothing on either Spark reads them - the
# runtime loads the rank files plus the small files plus vision shard 39,
# exactly the file set the kit's own "no NFS at all" layout documents. So the
# order is: image, checkpoint, rank 0, rank 1 (over NFS, from the worker),
# delete the shards, Engram onto the head, Engram copy to the worker - which
# also turns the worker's own 353 GB guard into a 213 GB one, because the kit
# skips its rank-1 spare once the file is there (prepare.sh:272-276). Same
# bytes, one 200 GB smaller footprint at every moment. The old vLLM port's
# stage-weights.sh made the same argument for its 385 GB peak
# (docs/decisions.md#dsv41-flash-exl3); here it lives inside ws up, because a
# second entry point a human must remember is the mistake this workspace
# shipped once already (docs/decisions.md#kit-runner-workspaces).
#
# The quoted commands are from the kit at commit 370daf0 with their
# prepare.sh line numbers, so a KIT_SHA re-pin must re-read them, same as the
# pin itself. Apache-2.0 (c) MiaAI-Lab; the reordering and the guarded purge
# are this repo's.
set -euo pipefail
SELF=$(readlink -f "$0"); cd "$(dirname "$SELF")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks.git}
# Re-pinned 2026-10-20 from 31eea46 after the checkpoint repo super-squashed
# its own history and erased the kit's model pin; 370daf0 carries the re-pin
# (45ee5d0f) plus the RDMA idle-nap and pool/window fixes.
KIT_SHA=370daf0cc38f348516a98ebab38f6053858eab1f
KIT_NAME=dsv41-1017-tensorfold

export PORT=${PORT:-8903}
export CONTAINER_NAME=${CONTAINER_NAME:-dsv41-1017-exl3-tf}

# ---- 1. gates --------------------------------------------------------------
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n $peer ]] || { echo "no interconnect peer in $PEERS_FILE - TP=2 needs the cabled pair" >&2; exit 1; }
export WORKER=${WORKER:-$USER@$peer}
export FABRIC_PEER=${FABRIC_PEER:-$(awk -v p="$peer" '!/^#/ && $1==p {print $2; exit}' "$PEERS_FILE")}

# The kit's prepare.sh needs the HOST `hf` CLI; roles/ml keeps it in the ML
# venv, not the system python (docs/decisions.md#ml-lockfile). First boot died
# on exactly this - see README. Do not pip into the system env for it.
command -v hf >/dev/null 2>&1 || export PATH="${ML_VENV:-$HOME/venvs/ml}/bin:$HOME/.local/bin:$PATH"
command -v hf >/dev/null 2>&1 || {
    echo "no 'hf' CLI even with the ML venv on PATH - roles/ml puts it there: make apply TAGS=ml" >&2
    exit 1
}

gb_free() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
# Head: image 25 + checkpoint 211 + rank 0 106 is the worst moment of the
# reordered stages (342); the 360 default keeps margin. Worker: Engram copy
# (203) + its rank file, the copy guard's spare already counted by its own
# logic - 340. Both overridable to re-measure, never to skip.
head_min=${HEAD_MIN_GB:-360}; worker_min=${WORKER_MIN_GB:-340}
head_cache=${HF_HOME:-$HOME/.cache/huggingface}   # NOT the kit's HF_CACHE (defined after sourcing
                                                          # its config.sh); a near-duplicate name here is
                                                          # exactly what shellcheck SC2153 caught once
here_gb=$(gb_free "$head_cache")
there_gb=$(ssh -n -o BatchMode=yes -o ConnectTimeout=6 "$WORKER" \
    "df -BG --output=avail '${WORKER_HF_CACHE:-$HOME/.cache/huggingface}' | tail -1 | tr -dc '0-9'" 2>/dev/null || echo 0)
if (( here_gb < head_min || there_gb < worker_min )); then
    cat >&2 <<MSG
DISK, and the reordered stages cannot dodge all of it: ~${head_min} GB free on
$(hostname) (checkpoint 211 + rank-0 file 106 + image 25) and ~${worker_min} GB
on $WORKER (Engram copy 203 + rank-1 file 106). Engram CANNOT be shared over
NFS - a decode round reads ~70 random 4 KiB rows and 940 us/read over NFS cost
~690-890 tok/s against 90 us and ~2,200 local (kit README, measured). Now:
$(hostname) ${here_gb} GB, $WORKER ${there_gb} GB. gx10-storage classifies
what is on these drives; a reclaim is an operator decision this repo will not
make. HEAD_MIN_GB=/WORKER_MIN_GB= override with a measured reason.
MSG
    exit 1
fi

# ---- 2. stages (each step prints [k/6] and skips what is in place) ---------
kit_fetch || exit 1
KD=$(kit_dir)
cd "$KD"
# Their own layered settings and node helpers, sourced exactly as prepare.sh
# sources them (config.sh first - it defines die, DATA_DIR, snapshot_rev;
# nodes.sh next - worker(), ensure_nfs_volume, worker_files_check). in_hf() is
# defined inside prepare.sh itself (line 148) and not exported to a source, so
# it is reproduced here verbatim; a re-pin must re-check it.
# shellcheck source=/dev/null
source ./scripts/config.sh
# shellcheck source=/dev/null
source ./scripts/nodes.sh
mkdir -p "$STATE_DIR"
in_hf() { docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$HF_CACHE:/hf" "$@"; }

SNAP="$(model_cache_dir)/snapshots/$(snapshot_rev)"
SNAP_C="/hf/hub/models--${MODEL_ID//\//--}/snapshots/$(snapshot_rev)"    # prepare.sh:147's container view
RANK0_DIR="$DATA_DIR/rank-cache"
ESNAP="$(engram_cache_dir)/snapshots/$(engram_rev)"
CKPT_KEEP='model-00039-of-00039.safetensors'    # the only shard the runtime reads
shards=(); read -r -a shards <<< "$ENGRAM_SHARDS"

say()  { printf '%-9s %s   (head free: %s GB)\n' "[stage$1]" "$2" "$(gb_free "$HF_CACHE")"; }
rank0_ok() { [[ -n "$(find "$RANK0_DIR" -maxdepth 1 -name 'rank0of2-*.bin' -size +100G -print -quit 2>/dev/null)" ]]; }
rank1_ok() { worker 1 "find \"\$(eval echo $WORKER_CACHE_DIR)\" -maxdepth 1 -name 'rank1of2-*.bin' -size +100G 2>/dev/null | grep -q ."; }
big_shards() { find "$SNAP" -maxdepth 1 -name 'model-*-of-00039.safetensors' ! -name "$CKPT_KEEP" 2>/dev/null; }
have_ckpt() { [[ -f "$SNAP/model.safetensors.index.json" ]]; }
have_engram() { [[ -s "$ESNAP/${shards[1]}" ]]; }

# DRY_RUN reports the state and hands to start.sh, whose own DRY_RUN prints
# both ranks' docker lines. No stage runs, nothing is written.
if [[ "${DRY_RUN:-0}" == 1 ]]; then
    printf 'stages    image %s | checkpoint %s | rank0 %s | rank1 %s | shards %s | engram %s\n' \
        "$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo ok || echo missing)" \
        "$(have_ckpt && echo ok || echo missing)" "$(rank0_ok && echo ok || echo missing)" \
        "$(rank1_ok && echo ok || echo missing)" "$(big_shards | wc -l)" \
        "$(have_engram && echo ok || echo missing)"
    exec ./start.sh "$@"
fi

# [1/6] image - prepare.sh:80-84 verbatim in effect (~6 min of Zig).
if docker image inspect "$IMAGE" >/dev/null 2>&1; then say 1 "image built ($IMAGE)"
else
    docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || { say 1 "pulling $BASE_IMAGE"; docker pull -q "$BASE_IMAGE" >/dev/null; }
    say 1 "building $IMAGE (~6 min of Zig, twice)"
    ctx=$(mktemp -d "$STATE_DIR/build.XXXXXX")
    mkdir -p "$ctx/zig"; cp -r zig/patches "$ctx/zig/patches"; cp zig/Dockerfile "$ctx/Dockerfile"
    docker build -t "$IMAGE" -f "$ctx/Dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg TF_REPO="$TF_REPO" --build-arg TF_REF="$TF_REF" --build-arg INPUTS_REF="$INPUTS_REF" \
        --build-arg ZIG_VERSION="$ZIG_VERSION" --build-arg ZIG_SHA256="$ZIG_SHA256" \
        --build-arg PATCHES_HASH="$(image_hash)" "$ctx" >/dev/null
    rm -rf -- "$ctx"
fi

# [2/6] checkpoint whole at the pin - prepare.sh:114; hf resumes. Hours.
if have_ckpt; then say 2 "checkpoint present ($(du -shL "$SNAP" 2>/dev/null | cut -f1))"
else
    say 2 "downloading $MODEL_ID @ ${MODEL_REVISION:0:8} (196 GiB; hours; rerun this command to resume)"
    hf download "$MODEL_ID" --revision "$MODEL_REVISION" --cache-dir "$HF_CACHE/hub" >/dev/null
    have_ckpt || { echo "checkpoint snapshot incomplete at $SNAP - rerun ws up" >&2; exit 1; }
fi

# [3/6]+[4/6] both rank weight files. The NFS volume exists before rank 1
# because rank 1 is built ON THE WORKER from the head's cache over it - the
# kit's own step 6 moved forward; ensure_nfs_volume + worker_files_check are
# theirs (nodes.sh:78,94).
if rank0_ok && rank1_ok; then say 3 "both rank weight files present"
else
    ensure_nfs_volume 1; worker_files_check 1
    want=$(in_hf --entrypoint bash "$IMAGE" -c "tf-dsv41-rank-cache $SNAP_C /tmp/x 0 2 --index-only | sha256sum | cut -c1-20")   # prepare.sh:234
    if [[ -f "$RANK0_DIR/rank0of2-$want.bin" ]]; then say 3 "rank 0 ready"
    else
        say 3 "writing rank 0's weight file (~106 GB, minutes, no GPU)     # prepare.sh:237-239"
        mkdir -p "$RANK0_DIR"; rm -f "$RANK0_DIR"/rank0of2-*.bin "$RANK0_DIR/.rank0of2.partial"
        in_hf --entrypoint tf-dsv41-rank-cache "$IMAGE" "$SNAP_C" "/hf/$DATA_SUB/rank-cache" 0 2 >/dev/null
    fi
    # [4/6] rank 1 - prepare.sh:281-291. Needs 130 GB free on the worker (their
    # own guard, mirrored) because it reads the whole checkpoint over the cable.
    wwant=$(worker 1 "docker run --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' --entrypoint bash '$IMAGE' -c 'tf-dsv41-rank-cache $SNAP_C /tmp/x 1 2 --index-only | sha256sum | cut -c1-20'")
    if worker 1 "[[ -f $WORKER_CACHE_DIR/rank1of2-$wwant.bin ]]"; then say 4 "rank 1 ready on $(worker_host 1)"
    else
        wfree=$(worker 1 "mkdir -p $WORKER_CACHE_DIR && df -B1 --output=avail \$(eval echo $WORKER_CACHE_DIR) | tail -1" | tr -dc '0-9')
        (( wfree > 130 * 1024 * 1024 )) || {
            echo "$(worker_host 1) has $(( wfree / 1024 / 1024 / 1024 )) GiB free for rank 1's weight file; it needs ~106 GB (prepare.sh:287)" >&2
            exit 1
        }
        say 4 "writing rank 1's weight file on $(worker_host 1) (~106 GB over NFS)"
        worker 1 "find $WORKER_CACHE_DIR -maxdepth 1 -name 'rank1of2-*.bin' -delete && rm -f $WORKER_CACHE_DIR/.rank1of2.partial"
        worker 1 "docker run --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' -v $WORKER_CACHE_DIR:/out --entrypoint tf-dsv41-rank-cache '$IMAGE' '$SNAP_C' /out 1 2" >/dev/null
    fi
fi

# [5/6] the guarded purge - the ONLY destructive step in this workspace, and
# it is gated twice: both rank files present AND full-size. What it deletes,
# hf re-downloads (that is the whole reason build inputs get deleted -
# weights are re-downloadable, measurements are not). The snapshot's files are
# LINKS into blobs/ (prepare.sh:147), so both link and blob go; deleting the
# link alone frees nothing.
if ! big_shards | grep -q .; then say 5 "shards already purged"
elif ! rank0_ok || ! rank1_ok; then say 5 "REFUSING purge: a rank weight file is not in place - rerun ws up"
else
    n=$(big_shards | wc -l)
    say 5 "purging $n checkpoint shards (build inputs; keeping small files + $CKPT_KEEP)"
    while IFS= read -r link; do
        tgt=$(readlink -f "$link"); rm -f "$link"; [[ -f $tgt ]] && rm -f "$tgt"
    done < <(big_shards)
    find "$(model_cache_dir)/blobs" -maxdepth 1 -name '*.incomplete' -delete 2>/dev/null || true
fi

# [6/6] Engram onto the head - prepare.sh:124-131's own include pattern, so
# the rest of the 475 GB base tree is never fetched. Hours; hf resumes.
if have_engram; then say 6 "engram present on the head (kit re-verifies sizes)"
else
    if (( $(gb_free "$HF_CACHE") < 215 )); then
        echo "less than 215 GB free for Engram's 203 GB - rerun ws up after the purge ran (it precedes this stage)" >&2
        exit 1
    fi
    say 6 "downloading Engram's tables (${ENGRAM_SHARDS// /, }; ~203 GB; hours; rerun to resume)"
    inc=(--include model.safetensors.index.json --include config.json)
    for f in "${shards[@]}"; do inc+=(--include "$f"); done
    hf download "$ENGRAM_ID" --revision "$ENGRAM_REVISION" --cache-dir "$HF_CACHE/hub" "${inc[@]}" >/dev/null
fi

# The kit's OWN prepare.sh, offline, to completion: RoPE tables, the image
# bias, the MANIFEST check, the worker's file check, the served folder, the
# Engram size (and optional sha) checks, the worker's Engram copy, rank-1 and
# rank-0 skips - every confirmation upstream wrote, and the prepared-state
# marker that lets start.sh's auto-prepare stand down. HF_HUB_OFFLINE makes
# its two hf download calls take their documented fallback paths
# (prepare.sh:113-131: pinned revision + files present -> warn and proceed),
# which is the POINT: the purged shards must NOT silently re-download here.
say "" "the kit's own prepare.sh, offline, confirming all of it"
HF_HUB_OFFLINE=1 PULL=0 ./scripts/prepare.sh || {
    echo "the kit's completion run refused something - read the line above; it is upstream's verdict, not ours" >&2
    exit 1
}

# ---- 3. boot ---------------------------------------------------------------
# start.sh's MIN_AVAIL_GIB=112 check on both Sparks is the memory gate this
# workspace deliberately does NOT duplicate in the manifest (workspace.yml
# explains): staging must run beside the old server; booting cannot. If the
# shards are purged, keep the host offline too, so an auto-reprepare inside
# start.sh (stale marker) can never re-fetch 191 GB it no longer needs.
[[ -z "$(big_shards 2>/dev/null)" ]] && export HF_HUB_OFFLINE=1
exec ./start.sh "$@"
