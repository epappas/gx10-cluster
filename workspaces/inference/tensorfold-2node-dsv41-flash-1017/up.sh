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
#   1. gates        - the peer from the inventory, the host `hf` from roles/ml,
#                     the image (stage 1: no rank file can be named without
#                     it), then disk on both Sparks for what is still to
#                     write, and only that (the disk gate, below).
#   2. stages       - checkpoint, rank 0, rank 1 (built on the worker over
#                     NFS), Engram; then the kit's own prepare.sh, offline,
#                     to CONFIRM all of it.
#   3. boots        - ./start.sh: memory preflight with the await-memory
#                     re-read, both ranks, smoke test. The stage that needs
#                     the ~112 GB which only the old server's stopping frees.
#
# THE CHECKPOINT STAYS WHOLE. Until 2026-10-25 a stage deleted its 38 big
# shards once both rank files existed, on the premise that nothing reads them
# after. The kit does, at every prepare.sh run: it names each rank file by
# hashing `tf-dsv41-rank-cache --index-only`, which needs shard 1's
# embed.weight (measured: the post-purge layout fails "embed.weight|None:
# MissingTensor"), and prepare.sh:234-237 hashes it without pipefail, gets the
# empty input's name and deletes rank 0's file for not matching it - in the
# very run that purged. So the head holds image + checkpoint + rank 0 + Engram
# at once, ~558 GB from fresh, and the worker rank 1 + its Engram copy, ~346
# (docs/decisions.md#dsv41-1017-checkpoint-stays-whole). The rank files still
# come before Engram: rank 1 is built on the worker from the head's checkpoint
# over NFS (the kit's step 6 moved forward), and the kit skips its 150 GiB
# rank-1 spare once that file is there (prepare.sh:272-276). All of it lives
# inside ws up, because a second entry point a human must remember is the
# mistake this workspace shipped once already
# (docs/decisions.md#kit-runner-workspaces).
#
# The quoted commands are from the kit at commit 370daf0 with their
# prepare.sh line numbers, so a KIT_SHA re-pin must re-read them, same as the
# pin itself. Apache-2.0 (c) MiaAI-Lab; the stage order and the disk gate are
# this repo's.
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
# The pair, from the inventory (lib/kit.sh) - the SAME call down.sh makes, so
# what `ws up` stages on rank 1 is always what `ws down` can reach.
kit_pair || exit 1

# The kit's prepare.sh needs the HOST `hf` CLI; roles/ml keeps it in the ML
# venv, not the system python (docs/decisions.md#ml-lockfile). First boot died
# on exactly this - see README. Do not pip into the system env for it.
command -v hf >/dev/null 2>&1 || export PATH="${ML_VENV:-$HOME/venvs/ml}/bin:$HOME/.local/bin:$PATH"
command -v hf >/dev/null 2>&1 || {
    echo "no 'hf' CLI even with the ML venv on PATH - roles/ml puts it there: make apply TAGS=ml" >&2
    exit 1
}

# ---- 2. stages (each step prints [k/5] and skips what is in place) ---------
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
# prepare.sh calls this at its line 57 before anything touches NFS: it probes
# the link and fills LINK_HEAD_ADDR/LINK_WORKER_ADDR, and nfs_server() (its
# own words, nodes.sh:74) falls back to that table when NFS_SERVER is unset.
# Skipping it made stage 3 die with "no NFS server address" on a link that
# start.sh's own DRY output had just resolved perfectly - the kit's helpers
# depend on the kit's calling ORDER, not only its names. (Found by the first
# real staged run, 2026-10-21, after the checkpoint's 211 GB had landed.)
detect_links


SNAP="$(model_cache_dir)/snapshots/$(snapshot_rev)"
SNAP_C="/hf/hub/models--${MODEL_ID//\//--}/snapshots/$(snapshot_rev)"    # prepare.sh:147's container view
RANK0_DIR="$DATA_DIR/rank-cache"
ESNAP="$(engram_cache_dir)/snapshots/$(engram_rev)"
shards=(); read -r -a shards <<< "$ENGRAM_SHARDS"

# Sizes in decimal GB, as `df -BGB` reports them, measured on the pair
# 2026-10-25: image 24.9, checkpoint 210.7 (39 shards), a rank file 106.1,
# Engram 203.1. The guards met on the way count too: stage 4's 130 GiB
# (139.6 GB), the kit's worker Engram copy at 203.1 + its 10 GiB spare
# (prepare.sh:276), stage 5's 215.
IMG_GB=25 CKPT_GB=211 RANK_GB=107 HEAD_SPARE_GB=12
RANK1_FREE_GB=140 ENGRAM_WORKER_GB=214 ENGRAM_HEAD_GB=215
CKPT_SHARDS=39

gb_free() { local v; v=$(df -BGB --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'); echo "${v:-0}"; }
say()  { printf '%-9s %s   (head free: %s GB)\n' "[stage$1]" "$2" "$(gb_free "$HF_CACHE")"; }
have_image() { docker image inspect "$IMAGE" >/dev/null 2>&1; }
ckpt_shards() { find -L "$SNAP" -maxdepth 1 -type f -name 'model-*-of-00039.safetensors' 2>/dev/null | wc -l; }
ckpt_whole() { [[ -f "$SNAP/model.safetensors.index.json" ]] && (( $(ckpt_shards) == CKPT_SHARDS )); }
ckpt_left_gb() {   # what the checkpoint download still writes; hf resumes
    local have
    have=$(find -L "$SNAP" -maxdepth 1 -type f -printf '%s\n' 2>/dev/null | awk '{ s += $1 } END { printf "%d", s / 1e9 }')
    echo $(( have < CKPT_GB ? CKPT_GB - have : 0 ))
}
have_engram() { local f; for f in "${shards[@]}"; do [[ -s "$ESNAP/$f" ]] || return 1; done; }
# The worker's Engram copy fits when each shard's size is the head's - the kit's
# own test (prepare.sh section 7), per file instead of summed.
engram_sizes() { (cd "$ESNAP" && stat -L -c '%n %s' "${shards[@]}"); }
worker_engram_ok() {
    have_engram || return 1
    [[ "$(worker 1 "cd $WORKER_ENGRAM_DIR 2>/dev/null && stat -L -c '%n %s' ${shards[*]} 2>/dev/null")" == "$(engram_sizes)" ]]
}

# A rank file's NAME is the hash of tf-dsv41-rank-cache's index listing
# (prepare.sh:234), so the name says whether it fits THIS checkpoint and THIS
# image's tool. The listing reads the shards, so naming needs the image and the
# whole checkpoint; until both are here no rank file on disk can be judged, and
# none counts as present - or as stale. The head names both ranks: same image,
# same index, the same names the worker computes over NFS (measured 2026-10-25:
# rank0of2-274304f9..., rank1of2-f4b9c7e9..., ~1 s each). pipefail INSIDE the
# container: without it a failing tool exits 0 with the empty input's hash,
# and every real rank file would look stale.
EMPTY_NAME=e3b0c44298fc1c149afb    # sha256 of nothing, cut to 20
RANK0_WANT=""; RANK1_WANT=""
rank_hash() {
    local h
    if ! h=$(in_hf --entrypoint bash "$IMAGE" -c "set -o pipefail; tf-dsv41-rank-cache $SNAP_C /tmp/x $1 2 --index-only | sha256sum | cut -c1-20") \
        || [[ ! $h =~ ^[0-9a-f]{20}$ || $h == "$EMPTY_NAME" ]]; then
        die "tf-dsv41-rank-cache --index-only failed for rank $1 in $IMAGE: its weight file cannot be named"
    fi
    printf '%s' "$h"
}
rank_wants() {
    [[ -z $RANK0_WANT ]] && have_image && ckpt_whole || return 0
    RANK0_WANT=$(rank_hash 0) || exit 1
    RANK1_WANT=$(rank_hash 1) || exit 1
}
# A rank weight file is 106.1 GB, which is 98.83 GiB - and `find -size` counts
# GiB: the +100G this replaced never matched a complete file (2026-10-24).
# +90G still refuses a truncated write and accepts the real size.
RANK_MIN=+90G
rank0_ok() { [[ -n $RANK0_WANT && -n "$(find "$RANK0_DIR" -maxdepth 1 -name "rank0of2-$RANK0_WANT.bin" -size "$RANK_MIN" -print -quit 2>/dev/null)" ]]; }
# Rank 1 is asked over ssh, and no answer is not "absent": stage 4 deletes
# before it rebuilds, so a dropped connection must stop the run instead.
rank1_ok() {
    local a
    [[ -n $RANK1_WANT ]] || return 1
    a=$(worker 1 "find \"\$(eval echo $WORKER_CACHE_DIR)\" -maxdepth 1 -name 'rank1of2-$RANK1_WANT.bin' -size $RANK_MIN 2>/dev/null | grep -q . && echo yes || echo no") || true
    [[ $a == yes ]] && return 0
    [[ $a == no ]] && return 1
    die "no answer from $(worker_host 1) over ssh about rank 1's weight file"
}

# [1/5] image - prepare.sh:80-84 verbatim in effect (~6 min of Zig), plus
# prepare.sh:86-99: BOTH images on the worker, content-identical
# (image_ident/worker_image_ident, nodes.sh:192-198). Rank 1 runs $IMAGE there
# and the kit's completion run executes $BASE_IMAGE there (prepare.sh:262,278);
# a base missing on the worker makes prepare.sh die saying the worker "does not
# see every file over NFS" - the red herring of 2026-10-24's morning attempt.
# save|load ships only the layers the worker lacks. It runs BEFORE the disk
# gate: without the image no rank file can be named, and the gate would ask
# for room to rebuild files that are already there.
docker_free_gb() { gb_free "$(docker info -f '{{.DockerRootDir}}')"; }
worker_docker_free_gb() {
    local v; v=$(worker 1 "df -BGB --output=avail \$(docker info -f '{{.DockerRootDir}}') | tail -1" | tr -dc '0-9'); echo "${v:-0}"
}
stage_image() {
    local img ident ctx
    if have_image; then say 1 "image built ($IMAGE)"
    else
        (( $(docker_free_gb) >= IMG_GB )) || die "under $IMG_GB GB free for docker on this Spark: $IMAGE needs ~$IMG_GB"
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
    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        say 1 "pulling $BASE_IMAGE (the worker runs it: prepare.sh:262,278)"
        docker pull -q "$BASE_IMAGE" >/dev/null
    fi
    for img in "$BASE_IMAGE" "$IMAGE"; do
        ident=$(image_ident "$img")
        [[ "$(worker_image_ident 1 "$img")" == "$ident" ]] && continue
        (( $(worker_docker_free_gb) >= IMG_GB )) || die "$(worker_host 1) has under $IMG_GB GB free for docker: cannot copy $img there"
        say 1 "copying $img to $(worker_host 1) (docker save | load; missing layers only)"
        docker save "$img" | worker 1 docker load >/dev/null
        [[ "$(worker_image_ident 1 "$img")" == "$ident" ]] || die "$(worker_host 1)'s $img differs from this Spark's (prepare.sh:98)"
    done
    say 1 "images $BASE_IMAGE and $IMAGE identical on both Sparks"
}
[[ "${DRY_RUN:-0}" == 1 ]] || stage_image

# THE DISK GATE asks only for what is still to be written. Every weight file
# already on disk is judged against the pins - checkpoint and Engram by their
# pinned snapshots, a rank file by its name, the worker's Engram copy by the
# head's sizes, the worker's images by content - and one that fits is used as
# it is. This workspace's OWN files that do not fit (a rank file under another
# name or cut short, a half-written one, a worker Engram shard of the wrong
# size, an interrupted copy's .part) are deleted first: the stage that owns
# each would rebuild it anyway. DRY_RUN names them and credits their bytes.
# Why: on 2026-10-25 a flat 140/340 refused a pair with every file in place
# (head 35 GB free, worker 118). Fresh: head 558 (image 25 + checkpoint 211 +
# rank 0 107 + Engram's 215), worker 346 (image 25 + rank 1 107 + the kit's
# Engram copy 214). Overridable to re-measure, never to skip.
stale_head() {   # "bytes path" of rank-0 files that are not RANK0_WANT, whole
    [[ -n $RANK0_WANT ]] || return 0
    find "$RANK0_DIR" -maxdepth 1 \( -name 'rank0of2-*.bin' -o -name '.rank0of2.partial' \) \
        ! \( -name "rank0of2-$RANK0_WANT.bin" -size "$RANK_MIN" \) -printf '%s %p\n' 2>/dev/null || true
}
stale_worker() {   # the same for rank 1, plus Engram shards not the head's size
    local f
    [[ -z $RANK1_WANT ]] || worker 1 "find $WORKER_CACHE_DIR -maxdepth 1 \\( -name 'rank1of2-*.bin' -o -name '.rank1of2.partial' \\) ! \\( -name 'rank1of2-$RANK1_WANT.bin' -size $RANK_MIN \\) -printf '%s %p\\n' 2>/dev/null; true"
    have_engram || return 0
    worker 1 "find -L $WORKER_ENGRAM_DIR -maxdepth 1 -name '*.part' -printf '%s %p\\n' 2>/dev/null; true"
    for f in "${shards[@]}"; do
        worker 1 "find -L $WORKER_ENGRAM_DIR -maxdepth 1 -name '$f' ! -size $(stat -L -c %s "$ESNAP/$f")c -printf '%s %p\\n' 2>/dev/null; true"
    done
}
# <head|worker> <"bytes path" lines>: deletes them (DRY_RUN: names them) and
# prints the GB to credit - DRY_RUN only, a real delete already shows in df.
drop_stale() {
    local where=$1 list=$2 verb=deleting paths
    [[ -n $list ]] || { echo 0; return 0; }
    [[ ${DRY_RUN:-0} == 1 ]] && verb="would delete"
    awk -v w="$where" -v v="$verb" '{ printf "stale     %s: %s %s (%.1f GB, does not fit the pins)\n", w, v, $2, $1 / 1e9 }' <<<"$list" >&2
    if [[ ${DRY_RUN:-0} == 1 ]]; then awk '{ s += $1 } END { printf "%d\n", s / 1e9 }' <<<"$list"; return 0; fi
    mapfile -t paths < <(awk '{ print $2 }' <<<"$list")
    if [[ $where == head ]]; then rm -f -- "${paths[@]}"; else worker 1 "rm -f -- ${paths[*]}"; fi
    echo 0
}
gate_state() {   # one look at every file, as 0/1 flags for the arithmetic
    s_image=0 s_wimage=0 s_ckpt=0 s_r0=0 s_r1=0 s_engram=0 s_wengram=0
    have_image && s_image=1
    (( s_image )) && [[ "$(worker_image_ident 1 "$IMAGE")" == "$(image_ident "$IMAGE")" ]] && s_wimage=1
    ckpt_whole && s_ckpt=1
    rank0_ok && s_r0=1
    rank1_ok && s_r1=1
    have_engram && s_engram=1
    worker_engram_ok && s_wengram=1
    return 0
}
stage_state() {
    local f=(missing ok)
    printf 'image %s, checkpoint %s (%s/%s shards), rank0 %s, engram %s | worker: image %s, rank1 %s, engram %s' \
        "${f[s_image]}" "${f[s_ckpt]}" "$(ckpt_shards)" "$CKPT_SHARDS" "${f[s_r0]}" "${f[s_engram]}" \
        "${f[s_wimage]}" "${f[s_r1]}" "${f[s_wengram]}"
}
# Head, in stage order: everything stays, so the need is the sum; stage 5's
# own 215 carries Engram's spare, HEAD_SPARE_GB covers the rest.
head_need_gb() {
    local w=0
    (( s_image )) || w=$(( w + IMG_GB ))
    (( s_ckpt )) || w=$(( w + $(ckpt_left_gb) ))
    (( s_r0 )) || w=$(( w + RANK_GB ))
    if (( !s_engram )); then w=$(( w + ENGRAM_HEAD_GB )); elif (( w )); then w=$(( w + HEAD_SPARE_GB )); fi
    echo "$w"
}
# Worker, in stage order: image (stage 1), rank 1 (stage 4), Engram (prepare.sh).
worker_need_gb() {
    local img=0 rank=0 need=0
    (( s_wimage )) || img=$IMG_GB
    (( s_r1 )) || rank=$RANK_GB
    (( rank )) && need=$(( img + RANK1_FREE_GB ))
    if (( !s_wengram && img + rank + ENGRAM_WORKER_GB > need )); then need=$(( img + rank + ENGRAM_WORKER_GB )); fi
    (( img > need )) && need=$img
    echo "$need"
}

rank_wants
credit_head=$(drop_stale head "$(stale_head)")
credit_worker=$(drop_stale worker "$(stale_worker)")
gate_state
head_min=${HEAD_MIN_GB:-$(head_need_gb)}
worker_min=${WORKER_MIN_GB:-$(worker_need_gb)}
here_gb=$(( $(gb_free "$HF_CACHE") + credit_head ))
there_gb=$(ssh -n -o BatchMode=yes -o ConnectTimeout=6 "$WORKER" \
    "df -BGB --output=avail '${WORKER_HF_CACHE:-$HOME/.cache/huggingface}' | tail -1 | tr -dc '0-9'" 2>/dev/null || true)
there_gb=$(( ${there_gb:-0} + credit_worker ))
if (( here_gb < head_min || there_gb < worker_min )); then
    cat >&2 <<MSG
DISK: what is still to write needs ~${head_min} GB free on $(hostname) and
~${worker_min} GB on $WORKER; they have ${here_gb} and ${there_gb}.
On disk, judged against the pins: $(stage_state)
Engram CANNOT be shared over NFS - a decode round reads ~70 random 4 KiB rows
and 940 us/read over NFS cost ~690-890 tok/s against 90 us and ~2,200 local
(kit README, measured). gx10-storage classifies these drives; reclaiming
anything that is not this workspace's own is an operator decision this repo
will not make. HEAD_MIN_GB=/WORKER_MIN_GB= override with a measured reason.
MSG
    exit 1
fi
echo "gates     head ${here_gb} GB free (needs ${head_min}), worker ${there_gb} GB free (needs ${worker_min})"
echo "on disk   $(stage_state)"

# Rank 1 is built ON THE WORKER from this Spark's cache over the link (the
# kit's docker NFS volume), and the worker's volume can only mount what the
# head exports. The export is machine state - Ansible's half, opt-in role,
# and NOTE the EXTRA= form: a bare `make ... -e` is eaten by make as
# --environment-overrides and the variable never arrives (the Makefile says
# so in its own words; our first application of this prerequisite proved it
# the long way, 2026-10-23: the export play ran, silently skipped everything,
# and stage 3 would have died on a mount of a path that was never exported).
if ! grep -qF "${NFS_PATH:-$HF_CACHE}" /etc/exports 2>/dev/null; then
    cat >&2 <<MSG
The head exports nothing yet, and stage [4/5]'s worker volume needs
${NFS_PATH:-$HF_CACHE} exported to the worker over the link. Once (needs root):

    make optional TAGS=nfs LIMIT=odysseus EXTRA='-e nfs_export_path=${NFS_PATH:-$HF_CACHE}'

(That EXTRA= form is load-bearing; a bare -e is swallowed by make, the role
runs, prints nothing, and exports nothing.)
MSG
    exit 1
fi

# DRY_RUN: the gate has printed what is on disk; start.sh's own DRY_RUN prints
# both ranks' docker lines. No stage runs, nothing is written or deleted.
[[ "${DRY_RUN:-0}" == 1 ]] && exec ./start.sh "$@"

# [2/5] checkpoint whole at the pin - prepare.sh:114; hf resumes. Hours.
if ckpt_whole; then say 2 "checkpoint present ($(du -shL "$SNAP" 2>/dev/null | cut -f1))"
else
    say 2 "downloading $MODEL_ID @ ${MODEL_REVISION:0:8} (211 GB; hours; rerun this command to resume)"
    hf download "$MODEL_ID" --revision "$MODEL_REVISION" --cache-dir "$HF_CACHE/hub" >/dev/null
    ckpt_whole || die "checkpoint snapshot incomplete at $SNAP - rerun ws up"
fi
rank_wants
[[ -n $RANK0_WANT ]] || die "the rank files cannot be named: no $IMAGE or no whole checkpoint"

# [3/5] rank 0's weight file, on the head - prepare.sh:237-239.
if rank0_ok; then say 3 "rank 0 ready (rank0of2-$RANK0_WANT.bin)"
else
    say 3 "writing rank 0's weight file (~106 GB, minutes, no GPU)     # prepare.sh:237-239"
    mkdir -p "$RANK0_DIR"; rm -f "$RANK0_DIR"/rank0of2-*.bin "$RANK0_DIR/.rank0of2.partial"
    in_hf --entrypoint tf-dsv41-rank-cache "$IMAGE" "$SNAP_C" "/hf/$DATA_SUB/rank-cache" 0 2 >/dev/null
    rank0_ok || die "rank 0's weight file is not rank0of2-$RANK0_WANT.bin after writing it"
fi

# [4/5] rank 1's, built ON THE WORKER from the head's cache over the link (the
# kit's docker NFS volume, its step 6 moved forward; ensure_nfs_volume is
# theirs, nodes.sh:78) - prepare.sh:281-291.
if rank1_ok; then say 4 "rank 1 ready on $(worker_host 1) (rank1of2-$RANK1_WANT.bin)"
else
    # NOT the kit's worker_files_check: upstream it lives in prepare.sh:261,
    # section "6. the worker's NFS volume" - AFTER section 4 has created the
    # kit dir + MANIFEST and section 5 the token map, none of which exist
    # this early (the lifted-ahead check died on 2026-10-24 over a MANIFEST
    # nothing had written yet, while its own first file - the checkpoint's
    # config.json - had already read through the mount fine). The completion
    # run does the FULL check, in its own order, when its preconditions are
    # on disk. Here, test only what this stage reads over the volume.
    ensure_nfs_volume 1
    worker_nfs 1 sh -ec "[ -s '$SNAP_C/config.json' ]" || die "$(worker_host 1) cannot read the checkpoint through $NFS_VOLUME (NFS :$NFS_PATH from $(nfs_server 1)) - check the export and the NFS server (README: NFS); a stale volume: docker volume rm $NFS_VOLUME on $(worker_host 1)"
    # 130 GiB free, the kit's own guard (prepare.sh:287), mirrored. It read
    # 130 MiB here until 2026-10-25: bytes against 130 * 1024 * 1024.
    wfree=$(worker 1 "mkdir -p $WORKER_CACHE_DIR && df -B1 --output=avail \$(eval echo $WORKER_CACHE_DIR) | tail -1" | tr -dc '0-9')
    (( ${wfree:-0} > 130 * 1024 ** 3 )) || die "$(worker_host 1) has $(( ${wfree:-0} / 1024 ** 3 )) GiB free for rank 1's weight file; it needs ~106 GB (prepare.sh:287)"
    say 4 "writing rank 1's weight file on $(worker_host 1) (~106 GB over NFS)"
    worker 1 "find $WORKER_CACHE_DIR -maxdepth 1 -name 'rank1of2-*.bin' -delete && rm -f $WORKER_CACHE_DIR/.rank1of2.partial"
    worker 1 "docker run --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' -v $WORKER_CACHE_DIR:/out --entrypoint tf-dsv41-rank-cache '$IMAGE' '$SNAP_C' /out 1 2" >/dev/null
    rank1_ok || die "rank 1's weight file on $(worker_host 1) is not rank1of2-$RANK1_WANT.bin after writing it"
fi

# [5/5] Engram onto the head - prepare.sh:124-131's own include pattern, so
# the rest of the 475 GB base tree is never fetched. Hours; hf resumes.
if have_engram; then say 5 "engram present on the head (kit re-verifies sizes)"
else
    (( $(gb_free "$HF_CACHE") >= ENGRAM_HEAD_GB )) || die "under $ENGRAM_HEAD_GB GB free on this Spark for Engram's 203 GB"
    say 5 "downloading Engram's tables (${ENGRAM_SHARDS// /, }; ~203 GB; hours; rerun to resume)"
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
# (prepare.sh:113-131: pinned revision + files present -> warn and proceed):
# stages 2 and 5 fetched everything, so this run confirms and fetches nothing.
say "" "the kit's own prepare.sh, offline, confirming all of it"
HF_HUB_OFFLINE=1 PULL=0 ./scripts/prepare.sh || {
    echo "the kit's completion run refused something - read the line above; it is upstream's verdict, not ours" >&2
    exit 1
}

# ---- 3. boot ---------------------------------------------------------------
# start.sh's MIN_AVAIL_GIB=112 check on both Sparks is the memory gate this
# workspace deliberately does NOT duplicate in the manifest (workspace.yml
# explains): staging must run beside the old server; booting cannot.
exec ./start.sh "$@"
