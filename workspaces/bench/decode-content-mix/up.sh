#!/usr/bin/env bash
# Decode speed by content type, against a server that is already up. All the
# work is in content-mix, next to this file; this is the `ws up` entry point.
#
#   ws up decode-content-mix
#   ws up decode-content-mix --decode 600 --tasks prose,code
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
command -v python3 >/dev/null || { echo "decode-content-mix needs python3" >&2; exit 1; }
exec python3 ./content-mix "$@"
