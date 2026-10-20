#!/usr/bin/env bash
# Qwen3.8-Flash-Next on ONE Spark: MiaAI-Lab's TensorFold kit, at a pinned
# commit, with this repo's port and nothing else changed.
#
# WHAT THIS DOES NOT RE-IMPLEMENT, and why: scripts/config.sh (checkpoint
# presets, YaRN rule, PARALLEL cap, mem_need_gib arithmetic), scripts/
# prepare.sh (the engine image: TensorFold db28187 + patches 0001-0015, Zig
# 0.17.0, the 320-kernel AOT sm_121 set), start.sh's argument pre-check, load
# monitor and mem-floor stop, and stop.sh's log archival ALL live in the kit.
# They are MIT, they are measured on this exact hardware, and their failure
# behaviour - the one that matters on unified memory, "a rank that takes all
# of it freezes the box" - is engineered for it. docs/decisions.md#kit-runner
# workspaces has the argument; ../lib/kit.sh is the mechanism.
#
# WHAT THIS FILE adds: the pin, the port (8901, so it never collides with a
# still-running vLLM server while you decide), the environment the inventory
# knows and the kit cannot guess, and a preflight that reads as this repo.
#
#   ws up   tensorfold-qwen38-flash-next-spark              # first run: builds
#   ws up   tensorfold-qwen38-flash-next-spark restart      # after a .env edit
#   ws logs tensorfold-qwen38-flash-next-spark -f
#   ws down tensorfold-qwen38-flash-next-spark
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
# shellcheck source-path=SCRIPTDIR source=../../lib/kit.sh
source ../../lib/kit.sh

KIT_URL=${KIT_URL:-https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold.git}
KIT_SHA=656879fd752749bbd11a6e1a065a326c00940911
KIT_NAME=qwen38-flash-next-tf

# 8901, NOT the kit's 8888: 8888 is this repo's well-known endpoint (the
# generic vllm-2node-tp2 recipe answers there), and during the decision window
# both servers may exist on one head. The SERVED_NAME stays the kit default,
# "Qwen3.8-Flash-Next" - note the case: ../vllm-2node-qwen38-flash-next serves
# `qwen3.8-flash-next`, lowercase, and clients that key on the model id must
# pass the right one. Set SERVED_NAME in .env to match your clients instead.
export PORT=${PORT:-8901}

# The one preflight the kit cannot do for us: the 2-node vLLM server must be
# down before anything can want 108 GiB of MemAvailable. `ws check` reads
# requires.min_unified_gb and refuses while the pair serves; this says WHY in
# the same breath, pointing at the door to walk through.
avail=$(awk '/^MemAvailable:/{print int($2/1048576)}' /proc/meminfo)
if (( avail < 108 )) && docker ps --format '{{.Names}}' | grep -q 'ws-vllm-qwen38-fn'; then
    cat >&2 <<MSG
Only ${avail} GiB MemAvailable and ws-vllm-qwen38-fn is running: the 2-node
vLLM server is holding the pool this recipe needs (~108 GiB at the default
262,144-token window).

  ws down vllm-2node-qwen38-flash-next      # stop the pair first - THIS
                                            # session's own inference is
                                            # behind it; nothing here will do
                                            # it for you.
Or read the trade first: ../vllm-2node-qwen38-flash-next/README.md.
MSG
    exit 1
fi

kit_fetch || exit 1
cd "$KIT_DIR" || exit 1

echo
echo "checkpoint ${CHECKPOINT:-nvfp4}  (nvidia/Qwen3.8-Flash-Next-FP4-Local, ~96 GiB,"
echo "           loading ~81 GiB of MemAvailable; CHECKPOINT=int4 is the optional INT4-AutoRound)"
echo "image      the first run BUILDS locally: the tag this tree's patches hash to"
echo "           (zig-db28187-c0a2df4c680d) is not on ghcr - the newest published"
echo "           image is the 1.0.0 one (4144696f21e3, patches 0001-0009, INT4-era)."
echo "           ~6 min of Zig compile on the Spark, base nvcr.io 26.07-py3."
echo "port       $PORT   (the kit's own memory preflight and load monitor run inside)"
echo
# DRY_RUN, restart, and any extra tensorfold-native serve args pass straight
# through - start.sh documents them and its argument pre-check validates them
# against the image before anything is stopped.
exec ./start.sh "$@"
