#!/usr/bin/env bash
# Stop an in-flight bench.
#
# Nothing here is long-lived, so this exists for one case: bench-tui was killed
# in a way that skipped its EXIT trap - SIGKILL, a closed terminal, a dropped
# SSH session - and left the benchmark container running. It then keeps loading
# a server you believe is idle, which is a genuinely confusing state to debug.
# `ws down` should always be the answer to "make it stop".
set -euo pipefail
NAME=ws-bench-run

if [[ -n $(docker ps -q --filter "name=^${NAME}$" 2>/dev/null) ]]; then
    docker rm -f "$NAME" >/dev/null
    echo "stopped the in-flight bench ($NAME)"
else
    echo "no bench running"
fi

# Deliberately NOT deleting $RESULT_DIR. Results are the output of this
# workspace, and a `down` that silently discards the thing you just spent
# twenty minutes measuring is a bad trade for a tidy directory.
