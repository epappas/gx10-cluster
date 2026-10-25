#!/usr/bin/env bash
# Run an upstream recipe repository at a PINNED commit, without vendoring it.
# Sourced by a workspace's up.sh / down.sh; never executed.
#
# WHY THIS EXISTS. MiaAI-Lab's TensorFold recipes are whole launch systems -
# config layering, image builds with a 6-minute Zig compile, per-rank weight
# file writers, memguard, smoke tests - written for and measured on this exact
# hardware, under MIT or Apache-2.0. Re-implementing them here would fork ~2
# thousand lines of somebody else's fast-moving engine plumbing, silently
# diverge from the tree their numbers were taken on, and buy nothing: the
# reason those lines exist at all is that they are what makes a Spark not
# freeze. So these workspaces do what the READMEs tell a normal user to do -
# run the kit - and add what only this repo can add: a pinned commit, a port
# that does not collide, the environment wired from the inventory, and the
# house's habit of printing what will actually run.
#
# The pin is the whole point. `git fetch --depth 1 origin <sha>` only succeeds
# when that commit exists on the remote, and the checkout is verified against
# it, so "the kit" is one immutable commit - as reproducible as a vendored
# file, without pretending we reviewed 107 patches line by line. A rebuild
# of the recipe lands as a NEW pin plus a fresh reading, never as a silent
# drift under a running server. This is the mutable-tag lesson of
# docs/decisions.md#glm53-indexer-workspace applied to the recipe layer:
# upstream has rebuilt behind tags before; a full sha cannot.
#
# A workspace sets:
#   KIT_URL     the repository
#   KIT_SHA     the full commit sha it was read at - and the SAME string in
#               every script of the workspace: tests/check_workspaces.py
#               refuses a pin that moved in up.sh but not in down.sh, because
#               down's HEAD check then fails forever and its fallback silently
#               loses the kit's stop.sh (1017, 2026-10-20..24)
#   KIT_NAME    short name for the cache directory and the log lines
# and calls kit_fetch, which exports KIT_DIR (the checked-out tree), and
# kit_pair, which resolves the two Sparks from the inventory - the SAME call
# in up.sh and down.sh, for the same reason as the pin rule: the pair is one
# setting read by two scripts, and down.sh without WORKER cannot stop rank 1
# any more than up.sh without it can stage rank 1 (2026-10-24: `ws down` did
# exactly that, one WARN line, and left rank 1 alone on the worker).

# kit_pair: the two Sparks, from the inventory, exported, exactly once - so
# a workspace's up.sh and down.sh cannot disagree about what `ws down` must
# reach. WORKER is rank 1's ssh target and FABRIC_PEER its address ON the
# link; the peers file exists for exactly this mapping (the same first-line
# lookup lib/twonode.sh does, and the same reason: ranks whose addresses
# arrive from two different sources hang at init in silence). The kit's own
# config.sh lets the environment win over scripts/local.sh, so these exports
# are what start.sh/stop.sh/prepare.sh see without touching machine state.
# A workspace's own .env still overrides (every value is ${VAR:-...}).
kit_pair() {
    local peers_file=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers} peer
    peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$peers_file" 2>/dev/null)}
    [[ -n $peer ]] || {
        echo "no interconnect peer in $peers_file - TP=2 needs the cabled pair" >&2
        return 1
    }
    export WORKER=${WORKER:-$USER@$peer}
    export FABRIC_PEER=${FABRIC_PEER:-$(awk -v p="$peer" '!/^#/ && $1==p {print $2; exit}' "$peers_file")}
}

kit_dir() {  # resolves the kit tree path WITHOUT fetching - for stop/down
    local name=${KIT_NAME:-$(basename "${KIT_URL:-}" .git)}
    [[ -n $name ]] || { echo "kit: KIT_URL or KIT_NAME must be set" >&2; return 1; }
    printf '%s' "${KIT_DIR:-${KIT_CACHE_ROOT:-$HOME/.cache/gx10-kits}/$name}"
}

kit_fetch() {
    : "${KIT_URL:?kit: KIT_URL must be set}" "${KIT_SHA:?kit: KIT_SHA must be set}"
    local name=${KIT_NAME:-$(basename "$KIT_URL" .git)}
    KIT_DIR=${KIT_DIR:-${KIT_CACHE_ROOT:-$HOME/.cache/gx10-kits}/$name}
    [[ -n ${KIT_SHA_FILE_OVERRIDE:-} ]] && KIT_SHA=$(cat "$KIT_SHA_FILE_OVERRIDE")

    [[ "${KIT_SHA:0:40}" == "$KIT_SHA" && "$KIT_SHA" =~ ^[0-9a-f]{40}$ ]] || {
        echo "kit: KIT_SHA must be a full 40-hex commit sha, not '$KIT_SHA'" >&2
        return 1
    }

    mkdir -p "$(dirname "$KIT_DIR")" || return 1
    if [[ ! -d $KIT_DIR/.git ]]; then
        rm -rf "${KIT_DIR:?}" 2>/dev/null
        git init -q "$KIT_DIR" || return 1
        git -C "$KIT_DIR" remote add origin "$KIT_URL" || return 1
    elif [[ $(git -C "$KIT_DIR" remote get-url origin) != "$KIT_URL" ]]; then
        echo "kit: $KIT_DIR belongs to another URL:" >&2
        echo "  $(git -C "$KIT_DIR" remote get-url origin) != $KIT_URL" >&2
        return 1
    fi

    # Already at the pin? Do nothing - the tree may be the one the server
    # currently running was started from, and touching it under a live server
    # is exactly the drift this file exists to prevent.
    if [[ $(git -C "$KIT_DIR" rev-parse HEAD 2>/dev/null) == "$KIT_SHA" ]]; then
        echo "kit     $name @ ${KIT_SHA:0:7}  ($KIT_DIR)"
        return 0
    fi

    echo "kit     $name: fetching ${KIT_SHA:0:7}"
    # --depth 1 and only the pin: no history to age, no branches to disagree
    # with the sha. GitHub and GHCR-hosted repos answer this request; a server
    # without uploadpack.allowReachableSHA1InWant would need a full clone, and
    # saying so beats a "couldn't parse remote reply" error.
    if ! git -C "$KIT_DIR" fetch -q --depth 1 origin "$KIT_SHA" 2>/dev/null; then
        echo "kit: cannot fetch $KIT_SHA from $KIT_URL - the server may reject" >&2
        echo "  single-commit fetches; fall back with:" >&2
        echo "  git -C $KIT_DIR fetch --unshallow origin && git -C $KIT_DIR checkout $KIT_SHA" >&2
        return 1
    fi
    git -C "$KIT_DIR" checkout -q --detach FETCH_HEAD || return 1
    [[ $(git -C "$KIT_DIR" rev-parse HEAD) == "$KIT_SHA" ]] || {
        echo "kit: $KIT_DIR is at $(git -C "$KIT_DIR" rev-parse HEAD), wanted $KIT_SHA" >&2
        return 1
    }
    echo "kit     $name @ ${KIT_SHA:0:7}  ($KIT_DIR)"
}
