#!/usr/bin/env bash
# Measure cold prefill against a server that is already up. All the work is in
# prefill-ladder, next to this file; this is the `ws up` entry point.
#
# Arguments pass straight through:
#   ws up vllm-prefill-ladder
#   ws up vllm-prefill-ladder --rungs 8000,16000,100000 --chunk-tokens 2048
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# `ws up` sources .env before calling this; prefill-ladder reads the
# environment rather than the file, so sourcing here covers running it directly.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

command -v python3 >/dev/null || { echo "prefill-ladder needs python3" >&2; exit 1; }
exec python3 ./prefill-ladder "$@"
