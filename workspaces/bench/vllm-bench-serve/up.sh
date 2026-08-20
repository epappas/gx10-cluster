#!/usr/bin/env bash
# Sweep a running model server and render it live. All the work is in
# bench-tui, next to this file; this is the `ws up` entry point.
#
# Arguments pass straight through, so both of these work:
#   ws up vllm-bench-serve
#   ws up vllm-bench-serve -c 1,4,16
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# `ws up` sources .env before calling this, and bench-tui sources it again when
# run directly. Sourcing twice is harmless; not sourcing at all is not.
exec ./bench-tui "$@"
