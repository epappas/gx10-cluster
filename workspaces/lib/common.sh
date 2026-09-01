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
# Are every model this manifest names already on disk? Used by the disk guard
# to tell "no room to download" apart from "nothing left to download". Same two
# cache layouts as the weights report further down, for the same reason.
ws_weights_cached() {
    local m=$1 v any=0
    local hf=${HF_HOME:-$HOME/.cache/huggingface}
    local lc=${LLAMA_CACHE:-$hf/llama.cpp}
    while read -r v; do
        [[ -z $v ]] && continue
        any=1
        [[ -d "$hf/hub/models--${v//\//--}" ]] && continue
        compgen -G "$lc/${v//\//_}_*" >/dev/null && continue
        return 1
    done < <(ws_list_field "$m" models)
    (( any ))
}

ws_preflight() {
    local m=$1 fail=0 v need have

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
        # where people look first.
        if (( ${have:-0} >= need )); then ok "disk ${have} GB free at $cache (needs ${need})"
        elif ws_weights_cached "$m"; then
            ok "disk ${have} GB free at $cache (under ${need}, but the weights are already here)"
        else bad "disk: needs ${need} GB free at $cache, has ${have:-0} GB"; fail=1; fi
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
        # TWO CACHE LAYOUTS, because two downloaders write here.
        #
        #   transformers/vLLM/SGLang   $HF_HOME/hub/models--<org>--<name>/
        #   llama.cpp                  $LLAMA_CACHE/<org>_<repo>_<file>.gguf
        #
        # The llama.cpp workspaces point LLAMA_CACHE inside HF_HOME so both
        # live on the filesystem min_disk_gb above actually measured - but the
        # NAMING still differs, and checking only the hub layout reports a
        # cached 91 GB GGUF as "first run downloads them" every time.
        #
        # Absence is a warning either way, not a failure: the engine downloads
        # on first run, it just takes a while.
        local hf=${HF_HOME:-$HOME/.cache/huggingface}
        local slug="models--${v//\//--}"
        local lc=${LLAMA_CACHE:-$hf/llama.cpp}
        if [[ -d "$hf/hub/$slug" ]]; then ok "weights cached: $v"
        elif compgen -G "$lc/${v//\//_}_*" >/dev/null; then ok "weights cached: $v (llama.cpp)"
        else warn "weights NOT cached: $v (first run downloads them)"; fi
    done < <(ws_list_field "$m" models)

    return $fail
}

ws_peers() {  # peer management names, from the file roles/cluster writes
    local f=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
    [[ -r $f ]] || return 0
    awk '!/^#/ && NF { print $1 }' "$f" | sort -u
}
