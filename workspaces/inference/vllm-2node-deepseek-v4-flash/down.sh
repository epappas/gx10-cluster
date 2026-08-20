#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source-path=SCRIPTDIR source=../../lib/twonode.sh
source ../../lib/twonode.sh
twonode_down ws-vllm-ds-v4-flash
