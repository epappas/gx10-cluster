#!/usr/bin/env bash
# Stage the 1017's ~545 GB of build inputs in an ORDER the kit itself cannot,
# so a 520 GB head fits - and do it while the current vLLM server keeps
# running, because none of this needs a GPU or host memory: only disk.
#
# WHY THIS EXISTS. scripts/prepare.sh runs its steps in one fixed order -
# image, checkpoint, Engram, RoPE/bias, rank 0's weight file, worker's copy,
# rank 1's weight file - and that order needs checkpoint+Engram+rank 0 to
# COEXIST: peak ~545 GB. odysseus has 520 (measured 2026-10-20). The same
# wall, met from the other side, is what the old vLLM port's stage-weights.sh
# solved for its 385 GB peak (docs/decisions.md#dsv41-flash-exl3): the
# checkpoint's 38 big shards are BUILD INPUTS. Once BOTH rank weight files
# exist, nothing on either Spark reads them any more - the servers load the
# rank files, and the kit's own "no NFS at all" layout documents the runtime
# file set as "the small files and its vision shard (model-00039, the only
# shard read at run time)". So the dodge is an ordering, not a hack:
#
#   stage 1  image + checkpoint                      520 -> ~284
#   stage 2  worker NFS volume; rank 0; rank 1        head -> ~178, worker -106
#   purge    delete the 38 big shards (link AND blob), keep small files + 39   +191
#   stage 3  Engram's tables onto the head            -> ~166 free
#   stage 4  the kit's OWN prepare.sh with HF_HUB_OFFLINE=1 - its two hf
#            download calls take prepare.sh's documented offline paths
#            ("using the snapshot already here", prepare.sh:113-131), and
#            every other step (RoPE, bias, MANIFEST, served folder, worker
#            file check, Engram size checks, both rank skips) runs as
#            upstream wrote it and writes the prepared-state marker.
#
# On switch day, `ws up` then does the only part that ever needed the memory -
# booting two ranks - in MINUTES instead of hours.
#
# The quoted commands are from the kit at commit 370daf0 with line numbers, so
# a future re-pin must re-read this file against the new prepare.sh, exactly
# like the KIT_SHA it mirrors. Apache-2.0 (c) MiaAI-Lab; the purge is ours.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh
command -v hf >/dev/null 2>&1 || export PATH="${ML_VENV:-$HOME/venvs/ml}/bin:$HOME/.local/bin:$PATH"

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks.git}
KIT_SHA=370daf0cc38f348516a98ebab38f6053858eab1f
KIT_NAME=dsv41-1017-tensorfold

PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n $peer ]] || { echo "no interconnect peer in $PEERS_FILE" >&2; exit 1; }
export WORKER=${WORKER:-$USER@$peer}
export FABRIC_PEER=${FABRIC_PEER:-$(awk -v p="$peer" '!/^#/ && $1==p {print $2; exit}' "$PEERS_FILE")}

kit_fetch || exit 1
KD=$(kit_dir)
cd "$KD"
# Their own layer of settings and node helpers, sourced the way prepare.sh
# sources them. in_hf() is defined INSIDE prepare.sh (line 148), not in
# nodes.sh - reproduced here verbatim so stage 2 uses the same container view.
# shellcheck source=/dev/null
source ./scripts/config.sh
# shellcheck source=/dev/null
source ./scripts/nodes.sh
mkdir -p "$STATE_DIR"
in_hf() { docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$HF_CACHE:/hf" "$@"; }

SNAP="$(model_cache_dir)/snapshots/$(snapshot_rev)"
SNAP_C="/hf/hub/models--${MODEL_ID//\//--}/snapshots/$(snapshot_rev)"   # prepare.sh:147's container view
RANK0_DIR="$DATA_DIR/rank-cache"
ESNAP="$(engram_cache_dir)/snapshots/$(engram_rev)"
CKPT_KEEP='model-00039-of-00039.safetensors'    # the only shard runtime reads

df_head() { df -BG --output=avail "$HF_CACHE" | tail -1 | tr -dc '0-9'; }
say() { printf '%-8s %s   (head free: %s GB)\n' "[stage]" "$*" "$(df_head)"; }
rank0_ok() { [[ -n "$(find "$RANK0_DIR" -maxdepth 1 -name 'rank0of2-*.bin' -size +100G -print -quit 2>/dev/null)" ]]; }
rank1_ok() { worker 1 "find \"\${WORKER_CACHE_DIR:-$HOME/.cache/dsv41-tensorfold/rank-cache-${MODEL_REVISION:0:8}}\" 2>/dev/null | grep -q 'rank1of2-.*\.bin'"; }
big_shard_links() { find "$SNAP" -maxdepth 1 -name 'model-*-of-00039.safetensors' ! -name "$CKPT_KEEP" 2>/dev/null; }

case "${1:---status}" in
  --status)
    echo "head free   $(df_head) GB"
    echo "worker free $(worker 1 "df -BG --output=avail \"\$HOME/.cache\" | tail -1 | tr -dc '0-9'" 2>/dev/null || echo ?) GB"
    echo "image       $(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo 'not built')"
    echo "checkpoint  $([[ -f $SNAP/model.safetensors.index.json ]] && echo present || echo MISSING)"
    echo "rank 0      $(rank0_ok && echo ready || echo no)"
    echo "rank 1      $(rank1_ok && echo ready || echo 'no (or worker shell differs)')"
    echo "ckpt shards $(big_shard_links | wc -l) of 38 still on disk"
    echo "engram      $([[ -s $ESNAP/model-00048-of-00048.safetensors ]] && echo present || echo missing)"
    echo; echo "run in order (each resumable):  --stage1 --stage2 --purge --stage3 --stage4   or: --all"
    ;;
  --all)  shift
    for s in --stage1 --stage2 --purge --stage3 --stage4; do "$0" "$s" ${1+"$@"} || exit 1; done ;;
  --stage1)
    # prepare.sh:80-84 verbatim in effect. ~6 min of Zig on this Spark.
    docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || { say "pulling $BASE_IMAGE (~25 GB)"; docker pull -q "$BASE_IMAGE" >/dev/null; }
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then say "image $IMAGE already built"
    else
      say "building $IMAGE"
      ctx=$(mktemp -d "$STATE_DIR/build.XXXXXX"); trap 'rm -rf -- "$ctx"' EXIT
      mkdir -p "$ctx/zig"; cp -r zig/patches "$ctx/zig/patches"; cp zig/Dockerfile "$ctx/Dockerfile"
      docker build -t "$IMAGE" -f "$ctx/Dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg TF_REPO="$TF_REPO" --build-arg TF_REF="$TF_REF" --build-arg INPUTS_REF="$INPUTS_REF" \
        --build-arg ZIG_VERSION="$ZIG_VERSION" --build-arg ZIG_SHA256="$ZIG_SHA256" --build-arg PATCHES_HASH="$(image_hash)" "$ctx" >/dev/null
      rm -rf -- "$ctx"; trap - EXIT
    fi
    say "downloading the checkpoint (196 GiB; hours; hf resumes)"
    # prepare.sh:114 verbatim.
    hf download "$MODEL_ID" ${MODEL_REVISION:+--revision "$MODEL_REVISION"} --cache-dir "$HF_CACHE/hub" >/dev/null
    [[ -f "$SNAP/model.safetensors.index.json" ]] || { echo "snapshot incomplete - rerun --stage1" >&2; exit 1; }
    say "checkpoint present"
    ;;
  --stage2)
    [[ -f "$SNAP/model.safetensors.index.json" ]] || { echo "--stage1 first" >&2; exit 1; }
    ensure_nfs_volume 1; worker_files_check 1        # prepare.sh step 6, needed early for rank 1
    want=$(in_hf --entrypoint bash "$IMAGE" -c "tf-dsv41-rank-cache $SNAP_C /tmp/x 0 2 --index-only | sha256sum | cut -c1-20")   # prepare.sh:234
    if [[ -f "$RANK0_DIR/rank0of2-$want.bin" ]]; then say "rank 0 ready"
    else
      say "writing rank 0's weight file (~106 GB, minutes, no GPU)"    # prepare.sh:237-239
      mkdir -p "$RANK0_DIR"; rm -f "$RANK0_DIR"/rank0of2-*.bin "$RANK0_DIR/.rank0of2.partial"
      in_hf --entrypoint tf-dsv41-rank-cache "$IMAGE" "$SNAP_C" "/hf/$DATA_SUB/rank-cache" 0 2 >/dev/null
      rank0_ok || { echo "rank 0 file short/absent after write - disk?" >&2; exit 1; }
    fi
    wwant=$(worker 1 "docker run --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' --entrypoint bash '$IMAGE' -c 'tf-dsv41-rank-cache $SNAP_C /tmp/x 1 2 --index-only | sha256sum | cut -c1-20'")   # prepare.sh:281
    if worker 1 "[[ -f $WORKER_CACHE_DIR/rank1of2-$wwant.bin ]]"; then say "rank 1 ready on $(worker_host 1)"
    else
      say "writing rank 1's weight file on $(worker_host 1) (~106 GB, reads the checkpoint over NFS)"   # prepare.sh:285-291
      worker 1 "mkdir -p $WORKER_CACHE_DIR && find $WORKER_CACHE_DIR -maxdepth 1 -name 'rank1of2-*.bin' -delete && rm -f $WORKER_CACHE_DIR/.rank1of2.partial"
      worker 1 "docker run --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' -v $WORKER_CACHE_DIR:/out --entrypoint tf-dsv41-rank-cache '$IMAGE' '$SNAP_C' /out 1 2" >/dev/null
    fi
    ;;
  --purge)
    # The only destructive step, and it is gated twice: BOTH rank files must
    # exist, full-size, before any build input goes away. Undo = hf re-downloads
    # the checkpoint (that is the whole point of them being re-downloadable).
    rank0_ok || { echo "refusing: rank 0's weight file not in place (--stage2)" >&2; exit 1; }
    rank1_ok || { echo "refusing: rank 1's weight file not verified on $(worker_host 1) (--stage2)" >&2; exit 1; }
    n=$(big_shard_links | wc -l)
    (( n == 0 )) && { say "already purged"; exit 0; }
    say "purging $n shards (link AND blob - the snapshot's files are links into blobs/; freeing the link alone would free nothing)"
    while IFS= read -r link; do
        tgt=$(readlink -f "$link"); rm -f "$link"
        [[ -f $tgt ]] && rm -f "$tgt"
    done < <(big_shard_links)
    find "$(model_cache_dir)/blobs" -maxdepth 1 -name '*.incomplete' -delete 2>/dev/null || true
    say "purged (+$(df_head) GB free now)"
    ;;
  --stage3)
    if ! rank0_ok || ! rank1_ok; then
        echo "purge gates first: run --stage2 then --purge before --stage3 (Engram needs the freed shards' space)" >&2
        exit 1
    fi
    say "downloading Engram's tables (~203 GB; hours; hf resumes)"
    # read -a, not the kit's bare ($ENGRAM_SHARDS): same answer for these
    # glob-free names, and this repo's shellcheck gate stays clean.
    shards=(); read -r -a shards <<< "$ENGRAM_SHARDS"
    inc=(--include model.safetensors.index.json --include config.json)
    for f in "${shards[@]}"; do inc+=(--include "$f"); done
    # prepare.sh:126 verbatim, include-patterned so the rest of the 475 GB base tree is never fetched.
    hf download "$ENGRAM_ID" ${ENGRAM_REVISION:+--revision "$ENGRAM_REVISION"} --cache-dir "$HF_CACHE/hub" "${inc[@]}" >/dev/null
    for f in model.safetensors.index.json config.json "${shards[@]}"; do [[ -s "$ESNAP/$f" ]] || { echo "engram incomplete: $f - rerun --stage3" >&2; exit 1; }; done
    say "engram present; sizes checked next by the kit itself"
    ;;
  --stage4)
    say "the kit's own prepare.sh, offline, to completion"
    # HF_HUB_OFFLINE=1 makes BOTH hf calls fail fast into their documented
    # "revision pinned + files here -> warn and proceed" fallbacks
    # (prepare.sh:113-131); PULL=0 keeps it off the unpublished ghcr tag and
    # lets the save|load copy reach the worker. Exit status is the kit's word
    # on readiness; on success it leaves its prepared-state marker.
    HF_HUB_OFFLINE=1 PULL=0 ./scripts/prepare.sh
    say "READY. Switch day:"
    echo "    ws down vllm-2node-qwen38-flash-next && sleep 60 && ws up tensorfold-2node-dsv41-flash-1017"
    ;;
  *) echo "usage: $0 --status | --stage1 | --stage2 | --purge | --stage3 | --stage4 | --all" >&2; exit 2 ;;
esac
