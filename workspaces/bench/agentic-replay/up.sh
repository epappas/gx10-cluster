#!/usr/bin/env bash
# Agentic head-to-head bench, against a server that is already up. All the work
# is in agentic-replay, next to this file; this is the `ws up` entry point.
#
#   BASE_URL=http://HOST:8903/v1 ws up agentic-replay replay --corpus-rev REV --label dsv41
#   ws up agentic-replay compare DIR_A DIR_B
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
command -v python3 >/dev/null || { echo "agentic-replay needs python3" >&2; exit 1; }
exec python3 -B ./agentic-replay "$@"
