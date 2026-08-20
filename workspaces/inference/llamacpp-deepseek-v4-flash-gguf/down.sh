#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[[ -f .pid ]] || { echo "not running (no .pid)"; exit 0; }
pid=$(cat .pid)
# Verify it is still OUR process before signalling: pids are recycled, and a
# stale .pid pointing at whatever now owns that number is how a cleanup script
# kills someone's training run.
if kill -0 "$pid" 2>/dev/null && grep -qa llama-server "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid"; echo "stopped $pid"
else
    echo "pid $pid is not llama-server (stale file); not signalling"
fi
rm -f .pid
