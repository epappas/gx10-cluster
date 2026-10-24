#!/usr/bin/env bash
# Shared by the `ws` runner. Sourced, never executed.
#
# File-level: the colour variables and several helpers are consumed by `ws`,
# which sources this file. shellcheck analyses it standalone and cannot see
# those uses.
# shellcheck disable=SC2034
#
# Everything here is deliberately plain bash and docker/compose. Workspaces are
# NOT ansible: ansible's job ends at "the machine is ready", and a recipe you
# can read, copy and run by hand is worth more than one that only a playbook
# can drive. See workspaces/README.md for the contract.

WS_ROOT=${WS_ROOT:?}

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'
c_bold=$'\033[1m'; c_off=$'\033[0m'

die()  { printf '%sws: %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
warn() { printf '%s! %s%s\n'  "$c_yel" "$*" "$c_off" >&2; }
ok()   { printf '%s✓%s %s\n'  "$c_grn" "$c_off" "$*"; }
bad()  { printf '%s✗%s %s\n'  "$c_red" "$c_off" "$*"; }

# --- manifest access ------------------------------------------------------
# yq is not assumed - it is not in the base image and this repo does not
# install it. These readers handle the flat subset of YAML the schema allows,
# which is why the schema forbids nesting beyond one level.
ws_dir() {  # $1 = name -> path, or empty
    local d
    for d in "$WS_ROOT"/*/"$1"; do
        [[ -f "$d/workspace.yml" ]] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

ws_field() {  # $1 = manifest path  $2 = top-level key
    awk -v k="$2" '
        $0 ~ "^"k":" { sub("^"k":[[:space:]]*", ""); gsub(/^"|"$/, ""); print; exit }
    ' "$1"
}

ws_list_field() {  # $1 = manifest  $2 = key of a "key:" block with "  - item"
    awk -v k="$2" '
        $0 ~ "^"k":" { inb = 1; next }
        inb && /^[[:space:]]+-[[:space:]]/ { sub(/^[[:space:]]+-[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; next }
        inb && /^[^[:space:]]/ { inb = 0 }
    ' "$1"
}

ws_req() {  # $1 = manifest  $2 = key under `requires:`
    awk -v k="$2" '
        /^requires:/ { inb = 1; next }
        inb && $0 ~ "^[[:space:]]+"k":" { sub(".*"k":[[:space:]]*", ""); gsub(/^"|"$/, ""); print; exit }
        inb && /^[^[:space:]]/ { inb = 0 }
    ' "$1"
}

ws_all() {  # every workspace name, kind-sorted
    local m
    for m in "$WS_ROOT"/*/*/workspace.yml; do
        [[ -f $m ]] || continue
        printf '%s\n' "$(basename "$(dirname "$m")")"
    done | sort
}

# --- the seam with ansible -------------------------------------------------
# A workspace declares what it needs; this checks the machine ansible produced
# actually provides it. That contract is the entire coupling between the two
# halves of this repo - no workspace imports anything from roles/, and no role
# knows a workspace exists.
#
# Returns 0 if every requirement holds. Prints one line per requirement either
# way, because "what exactly is missing" is the only useful output here.

# WHERE ONE MODEL IS ON DISK, IF IT IS. Prints its cached paths, one per line
# (usually one; the flat layout is several files), and returns 0; prints
# nothing and returns 1 if the model is not cached under any of them.
#
# THREE LAYOUTS, because two downloaders write here and one of them changed its
# mind:
#
#   transformers/vLLM/SGLang    $HF_HOME/hub/models--<org>--<name>/
#   llama.cpp, current builds   $LLAMA_CACHE/models--<org>--<name>/
#   llama.cpp, older builds     $LLAMA_CACHE/<org>_<repo>_<file>.gguf
#
# THE MIDDLE ONE IS THE FIX. llama.cpp's downloader moved to the HF hub layout
# and this only knew the flat one, so a fully cached 17.5 GB GGUF sitting in
# $LLAMA_CACHE/models--unsloth--Qwen3.8-27B-GGUF/ read as "first run downloads
# them" on EVERY `ws check` - on the one workspace whose whole pitch is that it
# starts in seconds. Measured with llama.cpp b10717 on odysseus, where that
# directory is the only layout present.
#
# The flat form is kept rather than replaced: it costs one glob, and a box
# whose cache predates the switch is exactly the box you do not want telling
# you to re-download 91 GB.
#
# The llama.cpp workspaces point LLAMA_CACHE inside HF_HOME so all three live
# on the filesystem min_disk_gb actually measured - but the NAMING still
# differs, which is what this function exists to absorb.
ws_model_cache_paths() {  # $1 = model id -> cached paths, one per line
    local v=$1
    local hf=${HF_HOME:-$HOME/.cache/huggingface}
    local lc=${LLAMA_CACHE:-$hf/llama.cpp}
    local slug="models--${v//\//--}"
    [[ -d "$hf/hub/$slug" ]]                    && { printf '%s\n' "$hf/hub/$slug"; return 0; }
    [[ -d "$lc/$slug" ]]                        && { printf '%s\n' "$lc/$slug";     return 0; }
    compgen -G "$lc/${v//\//_}_*"
}

# Which layout the model was found in, for reporting.
ws_model_cache_layout() {  # $1 = model id -> prints "hub" | "llama.cpp"
    local hf p
    hf=${HF_HOME:-$HOME/.cache/huggingface}
    p=$(ws_model_cache_paths "$1" | head -1) || return 1
    [[ -n $p ]] || return 1
    [[ $p == "$hf/hub/"* ]] && printf hub || printf llama.cpp
}

# Are every model this manifest names already on disk? Used by the disk guard
# to tell "no room to download" apart from "nothing left to download" - the
# all-landed case. The partial case is ws_weights_landed_gb below, and the
# guard and the report share ws_model_cache_paths, so the three can no longer
# disagree about what "cached" means - which they did, silently, for as long
# as each carried its own copy of the globs.
ws_weights_cached() {
    local m=$1 v any=0
    while read -r v; do
        [[ -z $v ]] && continue
        any=1
        ws_model_cache_paths "$v" >/dev/null || return 1
    done < <(ws_list_field "$m" models)
    (( any ))
}

# How many GB of the manifest's models are ALREADY on the filesystem the disk
# guard measures. This is docs/decisions.md#the-model-disk-guard-subtracts-the-whole-plan
# brought to `ws check`: min_disk_gb reserves room for the download, so the
# bytes that already landed are not what the reservation is for anymore -
# subtract them per model, not all-or-nothing.
#
# Two honest limits. The credit is by PRESENCE, not revision: a hub dir at the
# wrong pin gets credited here and refused by the workspace's own stage gate
# (up.sh's HEAD_MIN_GB, the kit's prepare.sh), which is the authority that
# actually reads revisions - `ws check` only asks "is there room to try". And
# bytes on another filesystem are not credited: the guard measures free space
# on one device, and a model on the USB stick frees nothing on the NVMe.
#
# WHAT "on disk" MEANS IS ITSELF A LAYOUT PROBLEM, and `du` was the first
# answer that died on it: the newer `hf` CLI content-addresses blobs into a
# shared store (hub/blobs/<xx>/<sha>) and replaces the per-repo entries with
# SYMLINKS, so du without -L measured 1 GB for the 211 GB checkpoint (it saw
# only the links and the small real files), while du -L would count every
# blob twice over - once via blobs/, once via snapshots/. So the count is
# UNIQUE CONTENT REACHABLE by following links: find -L reports each final
# file under every path that reaches it, and INODE dedup makes each real file
# count exactly once - correct for all three layouts at once, including
# hardlinks, and a dangling link is not data and is skipped. Each path is
# device-gated before it is walked, so inode numbers cannot collide across
# filesystems. (find's %d is DEPTH, not device - %D is the device: the first
# draft keyed on %d:%i, one shard then "deduped" as two files at two depths,
# and the guard measured the 211 GB checkpoint at 422 - the cache's own shape,
# three link generations deep, is what taught this line.)
ws_weights_landed_gb() {  # $1 = manifest  $2 = probe dir on the measured fs
    local m=$1 probe=$2 v p gb total=0 dev
    dev=$(stat -c %d "$probe" 2>/dev/null) || { printf '0'; return; }
    while read -r v; do
        [[ -z $v ]] && continue
        while read -r p; do
            [[ -n $p && $(stat -c %d "$p" 2>/dev/null) == "$dev" ]] || continue
            gb=$(find -L "$p" -type f -printf '%D:%i %s\n' 2>/dev/null |
                 sort -u | awk '{s+=$2} END {printf "%d", (s + 999999999) / 1000000000}' || true)
            total=$(( total + ${gb:-0} ))
        done < <(ws_model_cache_paths "$v")
    done < <(ws_list_field "$m" models)
    printf '%s' "$total"
}

ws_preflight() {
    local m=$1 fail=0 v need have landed left fully

    need=$(ws_req "$m" gpu_arch)
    if [[ -n $need ]]; then
        have=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
        if [[ $have == "$need" ]]; then ok "GPU compute capability $have"
        else bad "GPU compute capability: need $need, found ${have:-none}"; fail=1; fi
    fi

    need=$(ws_req "$m" min_unified_gb)
    if [[ -n $need ]]; then
        # Unified memory: on GB10 host memory IS GPU memory, so MemAvailable is
        # the real budget. nvidia-smi reports [N/A] and cannot answer this.
        have=$(awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo)
        if (( have >= need )); then ok "unified memory ${have} GB available (needs ${need})"
        else bad "unified memory: needs ${need} GB, ${have} GB available"; fail=1; fi
    fi

    need=$(ws_req "$m" min_disk_gb)
    if [[ -n $need ]]; then
        # Free space where the WEIGHTS land, not where you happen to be stood.
        # A 1 TB NVMe sounds like plenty until a 500 GB checkpoint meets a HF
        # cache that already holds 133 GB, and a download that fills the root
        # filesystem takes the box down rather than just failing.
        local cache=${HF_HOME:-$HOME/.cache/huggingface}
        # Walk up to something that exists rather than creating the cache dir:
        # `ws check` is a question, and a question should not leave anything
        # behind on a machine it decided was unsuitable.
        local probe=$cache
        while [[ ! -d $probe && $probe == */* ]]; do probe=${probe%/*}; done
        have=$(df -BG --output=avail "${probe:-/}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1+0}')
        # min_disk_gb IS ROOM FOR THE DOWNLOAD, and once the download has
        # happened that room is spent - by the very file it was reserved for.
        # Enforcing it afterwards fails a workspace whose weights are sitting
        # on the disk it just measured, which is how llamacpp-deepseek-v4-pro
        # reported "needs 360 GB free, has 242" on the one node that could
        # actually serve it. up.sh has skipped the guard on a present file
        # since that was found; this is the same rule in `ws check`, which is
        # where people look first. And the rule subtracts per model: when the
        # guard only exempted an ALL-landed cache, a partially staged recipe
        # refused its own resume - tensorfold-2node-dsv41-flash-1017 failed
        # `ws up` with "needs 360, has 323" while its 211 GB checkpoint sat in
        # the cache it was measuring and up.sh was ready to run what remained
        # at 140. What remains to download is all the guard reserves for.
        landed=$(ws_weights_landed_gb "$m" "${probe:-/}")
        fully=0; ws_weights_cached "$m" && fully=1
        left=$(( need > landed ? need - landed : 0 ))
        if (( ${have:-0} >= need )); then ok "disk ${have} GB free at $cache (needs ${need})"
        elif (( fully )); then
            ok "disk ${have} GB free at $cache (under ${need}, but the weights are already here)"
        elif (( ${have:-0} >= left )); then
            ok "disk ${have} GB free at $cache (needs ${left} of ${need}; ${landed} GB already on disk)"
        else bad "disk: needs ${left} GB free at $cache, has ${have:-0} GB"; fail=1; fi
    fi

    if [[ $(ws_req "$m" docker) == "true" ]]; then
        if docker ps -q >/dev/null 2>&1; then ok "docker usable without sudo"
        else bad "docker not usable - re-login for the docker group, or: make apply TAGS=docker"; fail=1; fi
    fi

    if [[ $(ws_req "$m" rdma) == "true" ]]; then
        if grep -qxs '4: ACTIVE' /sys/class/infiniband/*/ports/1/state; then ok "RDMA link active"
        else bad "no ACTIVE RDMA port - see docs/runbooks/connect-cluster.md"; fail=1; fi
    fi

    need=$(ws_req "$m" peers)
    if [[ -n $need ]] && (( need > 0 )); then
        local reach=0 h
        for h in $(ws_peers); do
            ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null && reach=$((reach + 1))
        done
        if (( reach >= need )); then ok "$reach peer(s) reachable over SSH (needs $need)"
        else bad "needs $need reachable peer(s), found $reach - see docs/runbooks/run-distributed.md"; fail=1; fi
    fi

    while read -r v; do
        [[ -z $v ]] && continue
        if docker image inspect "$v" >/dev/null 2>&1; then ok "image $v"
        else warn "image $v not pulled yet (ws up will pull it)"; fi
    done < <(ws_list_field "$m" images)

    while read -r v; do
        [[ -z $v ]] && continue
        # The layouts, and why there is more than one, are in
        # ws_model_cache_layout. Absence is a warning either way, not a
        # failure: the engine downloads on first run, it just takes a while.
        local layout
        if layout=$(ws_model_cache_layout "$v"); then
            if [[ $layout == hub ]]; then ok "weights cached: $v"
            else ok "weights cached: $v ($layout)"; fi
        else warn "weights NOT cached: $v (first run downloads them)"; fi
    done < <(ws_list_field "$m" models)

    return $fail
}

ws_peers() {  # peer management names, from the file roles/cluster writes
    local f=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
    [[ -r $f ]] || return 0
    awk '!/^#/ && NF { print $1 }' "$f" | sort -u
}
