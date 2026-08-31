#!/usr/bin/env bash
# Measure per-position draft acceptance against a server that is already up.
# All the work is in spec-accept, next to this file; this is the `ws up` entry
# point.
#
# Arguments pass straight through:
#   ws up spec-decode-accept
#   ws up spec-decode-accept --class structured --runs 5
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# `ws up` sources .env before calling this; spec-accept reads the environment
# rather than the file, so sourcing here covers the run-it-directly case too.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

command -v python3 >/dev/null || { echo "spec-accept needs python3" >&2; exit 1; }
exec python3 ./spec-accept "$@"
