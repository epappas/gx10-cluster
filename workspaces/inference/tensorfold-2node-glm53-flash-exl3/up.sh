#!/usr/bin/env bash
# GLM-5.3-Flash EXL3 across the pair on TensorFold's engine: the Apache-2.0
# kit at a pinned commit, its image pulled by DIGEST, one env block from this
# repo's inventory. The kit is the launcher - do not re-implement 107 patches'
# worth of serve flags here; docs/decisions.md#kit-runner-workspaces.
#
#   ws up   tensorfold-2node-glm53-flash-exl3            # first run: prepare both Sparks
#   ws up   tensorfold-2node-glm53-flash-exl3 restart    # after a .env change
#   ws logs tensorfold-2node-glm53-flash-exl3 -f         # rank 0 (rank 1: ssh worker docker logs)
#   ws down tensorfold-2node-glm53-flash-exl3
# Restart through `ws up ... restart`, not the kit's ./start.sh restart: only
# `ws up` starts the memory guards (README, "Memory guard").
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh
# shellcheck source-path=SCRIPTDIR source=memory_guard.sh
source ./memory_guard.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git}
KIT_SHA=3fd60dfc836fab0f1ed0fd4f0afaf2a1d62b2aab
KIT_NAME=glm53-flash-tensorfold

export PORT=${PORT:-8902}          # 8893 is the vLLM GLM server's port; both may exist while you compare
export CONTAINER_NAME=${CONTAINER_NAME:-glm53-flash-tf}

# ---- the pair, from the inventory, exactly once -----------------------------
# kit_pair (lib/kit.sh) - the SAME call down.sh makes, so what `ws up` stages
# on rank 1 is always what `ws down` can reach. WORKER stays an ssh target on
# the MANAGEMENT name (roles/base owns /etc/hosts, so ssh never depends on the
# very link the launch is about to use); FABRIC_PEER is the worker's address
# ON the link.
kit_pair || exit 1

# ---- how the weights reach the worker ---------------------------------------
# copy (the kit's default) rsyncs ~166 GiB into the worker's own cache. That
# is a fine choice for a worker with room and a BAD one here: poseidon's free
# space was 125 GB at the 2026-10-20 measurement - it cannot hold the tree
# twice. nfs is the kit's own alternative - rank 1 reads the head's HF_CACHE
# over the cable through a read-only docker volume prepare.sh creates with no
# sudo on the worker - and it is what this cluster's disk arithmetic selects.
export WORKER_WEIGHTS=${WORKER_WEIGHTS:-nfs}
export HF_CACHE=${HF_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}}
export NFS_PATH=${NFS_PATH:-$HF_CACHE}
export NFS_SERVER=${NFS_SERVER:-$(ip -4 addr show "${CLUSTER_IFACE:-enp1s0f0np0}" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')}

if [[ $WORKER_WEIGHTS == nfs ]]; then
    # An export is machine state and Ansible owns machine state
    # (workspaces/README.md): this workspace CHECKS for it and says how to
    # turn it on, and does not mount or export anything itself. root-owned and
    # world-readable, so the check needs no sudo. grep the directory, not the
    # whole line: options and comments follow it.
    if ! grep -qF "$NFS_PATH" /etc/exports 2>/dev/null; then
        cat >&2 <<MSG
WORKER_WEIGHTS=nfs needs the head exporting $NFS_PATH to the worker, and it
is not in /etc/exports. One command (roles/nfs, opt-in like every optional
role - it stops the peer's inference? no: it changes nothing live):

    make optional TAGS=nfs LIMIT=odysseus EXTRA='-e nfs_export_path=$NFS_PATH'

Or take the kit's default and give the worker the disk: WORKER_WEIGHTS=copy.
MSG
        exit 1
    fi
fi

# The kit's prepare.sh needs the HOST `hf` CLI; roles/ml keeps it in the ML
# venv, not the system python (docs/decisions.md#ml-lockfile). The DeepSeek
# recipe's first boot died on exactly this. Do not pip into the system env for it.
command -v hf >/dev/null 2>&1 || export PATH="${ML_VENV:-$HOME/venvs/ml}/bin:$HOME/.local/bin:$PATH"
command -v hf >/dev/null 2>&1 || {
    echo "no 'hf' CLI even with the ML venv on PATH - roles/ml puts it there: make apply TAGS=ml" >&2
    exit 1
}

kit_fetch || exit 1
cd "$KIT_DIR" || exit 1

echo
echo "model    Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold @ 078455ff (Apache-2.0)"
echo "image    v0.6.0-e66c657a433d pulled BY DIGEST (sha256:14b5072e...ccf) - 107 patches inside"
echo "pair     rank 0 here :$PORT ; rank 1 on $WORKER over the link ($FABRIC_PEER)"
echo "weights  $WORKER_WEIGHTS$([[ $WORKER_WEIGHTS == nfs ]] && echo " - the worker stores none of the 164 GiB")"
echo "defaults PARALLEL=4, CONTEXT=1,048,576, KV=fp8, DENSE=q4, DFlash2+copy drafts"
echo "         - the lossy-throughput point the kit's README states outright;"
echo "           KV=bf16 DENSE=bf16 are the exact arms, at a 196,608 window."
echo
# Everything else - the download (~176 GB on first run), the image pull, the
# RoCE GID discovery, both ranks' launch, the smoke test - is the kit's, and
# it refuses loudly (argument pre-check against the image's capabilities)
# BEFORE stopping a running server. DRY_RUN=1 passes straight through.
#
# Arm both startup supervisors before preparation/loading. Arguments, environment
# and a failing start.sh exit code are unchanged; interruption reports guard state.
memory_guard_launch "$@"
