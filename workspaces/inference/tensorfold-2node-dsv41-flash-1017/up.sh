#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 EXL3 on the pair, TensorFold's Zig engine: the
# Apache-2.0 kit at a pinned commit, its own launcher, one env block from this
# repo's inventory. This workspace is `blocked` on disk (workspace.yml has the
# arithmetic) - up.sh ENFORCES the gate it is blocked on rather than assuming
# the kit's own preflight will name the problem: the kit checks MemAvailable,
# not disk, until prepare.sh starts downloading 196 GiB into a full cache.
#
#   ws up   tensorfold-2node-dsv41-flash-1017              # when the disk is there
#   ws up   tensorfold-2node-dsv41-flash-1017 restart
#   ws logs tensorfold-2node-dsv41-flash-1017 -f
#   ws down tensorfold-2node-dsv41-flash-1017
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks.git}
KIT_SHA=31eea4608f8bb292a92e2f7a1db400e928620c78
KIT_NAME=dsv41-1017-tensorfold

export PORT=${PORT:-8903}
export CONTAINER_NAME=${CONTAINER_NAME:-dsv41-1017-exl3-tf}

PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
peer=${PEER:-$(awk '!/^#/ && NF {print $1; exit}' "$PEERS_FILE" 2>/dev/null)}
[[ -n $peer ]] || { echo "no interconnect peer in $PEERS_FILE - TP=2 needs the cabled pair" >&2; exit 1; }
export WORKER=${WORKER:-$USER@$peer}
# The kit wants the worker's address ON THE LINK when ssh goes elsewhere;
# both rails' addresses are in the peers file, first match is subnet 100.
export FABRIC_PEER=${FABRIC_PEER:-$(awk -v p="$peer" '!/^#/ && $1==p {print $2; exit}' "$PEERS_FILE")}

# THE DISK GATE - the reason this workspace is blocked, made loud early.
# Head: checkpoint 196 + Engram 203 + rank 0's weight file 106 + image 25.
# Worker: Engram copy 203 + rank 1's weight file 106 + image 25. (Engram
# cannot be shared over NFS: a decode round reads ~70 random 4 KiB rows and
# 940 us/read over NFS against 90 us local - prefill falls to ~790 tok/s.
# That is the kit's measured finding and the reason a "just export it"
# workaround is not offered.)
gb_free() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
head_gb=${HEAD_MIN_GB:-505}; worker_gb=${WORKER_MIN_GB:-340}
hf=${HF_HOME:-$HOME/.cache/huggingface}
here_gb=$(gb_free "$hf"); there_gb=$(ssh -n -o BatchMode=yes -o ConnectTimeout=6 "$WORKER" \
    "df -BG --output=avail $(printf '%q' "${WORKER_HF_CACHE:-$HOME/.cache/huggingface}") | tail -1 | tr -dc '0-9'" 2>/dev/null || echo 0)
if (( here_gb < head_gb || there_gb < worker_gb )); then
    cat >&2 <<MSG
DISK. This recipe needs ~${head_gb} GB free on $(hostname) and ~${worker_gb} GB
on $WORKER, for weights that CANNOT be deduplicated or exported:

    head:   checkpoint 196 + Engram 203 (local) + rank-0 weight file 106 + image 25
    worker: Engram 203 (local - NFS reads cost 10x and 2,200 tok/s becomes 790)
            + rank-1 weight file 106 + image 25

Free now: $(hostname) ${here_gb} GB, $WORKER ${there_gb} GB.
See README "The disk arithmetic" for what is on these NVMe drives and what a
reclaim decision looks like. HEAD_MIN_GB=/WORKER_MIN_GB= override this gate if
you know better (a smaller CONTEXT changes memory, never disk).
MSG
    exit 1
fi

kit_fetch || exit 1
cd "$KIT_DIR" || exit 1

echo
echo "model    Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw @ 6d54be4f"
echo "         + Engram tables from deepseek-ai/DeepSeek-V4.1-Flash-1017 @ 1bae0e10"
echo "         (the 1017 tables - the older release's must NOT be used; prepare.sh checks)"
echo "image    ghcr...deepseek-v4.1-flash-1017-2x-dgx-sparks-tensorfold:exl3-tp2-7c9bf5d36350 (or local build)"
echo "pair     rank 0 here :$PORT ; rank 1 (tf-dsv41-lanes) on $WORKER"
echo "engines  zig (default) or ENGINE=jl - the jl one checks memory AT RUN TIME"
echo "         (4 GiB admission floor, 2K segments, eager instead of a failed graph)"
echo
exec ./start.sh "$@"
