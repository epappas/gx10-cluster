#!/usr/bin/env bash
# Run the quant A/B against a server that is already up. All the work is in
# quant-ab, next to this file; this is the `ws up` entry point.
#
# Arguments pass straight through:
#   ws up quant-quality-ab --save bf16.json
#   ws up quant-quality-ab --save fp8.json --compare bf16.json
#
# The exit status is the tool's, so `ws up quant-quality-ab --compare x.json &&
# deploy` means what it looks like it means.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
command -v python3 >/dev/null || { echo "quant-quality-ab needs python3" >&2; exit 1; }
exec python3 ./quant-ab "$@"
