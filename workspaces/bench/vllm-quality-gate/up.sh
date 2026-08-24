#!/usr/bin/env bash
# Run the correctness gate against a server that is already up. All the work is
# in quality-gate, next to this file; this is the `ws up` entry point.
#
# Arguments pass straight through, so both of these work:
#   ws up vllm-quality-gate
#   ws up vllm-quality-gate -c 1,8 -n 8
#
# The exit status is the gate's, so `ws up vllm-quality-gate && deploy` means
# what it looks like it means.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# `ws up` sources .env before calling this; quality-gate reads the environment
# rather than the file, so sourcing here covers the run-it-directly case too.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

command -v python3 >/dev/null || { echo "quality-gate needs python3" >&2; exit 1; }
exec python3 ./quality-gate "$@"
