#!/usr/bin/env bash
# What the server ACTUALLY allocated, rather than what you asked for.
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN THE README. Every capacity number for
# this model is a startup-time OUTCOME of --mem-fraction-static, not a
# constant: the token pool, the KV cache size and max_running_requests are all
# derived at boot from a fraction of whatever memory was free at that moment.
# So "~4.93M tokens, 48 concurrent" is what the reference kit got, not what
# YOUR box got - and the difference is exactly the desktop session or the
# dashboard that happened to be resident when it started.
#
# /server_info is the endpoint; /get_server_info is its deprecated alias, still
# present and still what every published recipe calls. Both are tried.
#
#   ./report.sh
#   PORT=8894 ./report.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }
PORT=${PORT:-8894}
ADDR=${REPORT_HOST:-127.0.0.1}

raw=$(curl -fsS "http://$ADDR:$PORT/server_info" 2>/dev/null) \
  || raw=$(curl -fsS "http://$ADDR:$PORT/get_server_info" 2>/dev/null) \
  || { echo "no answer from http://$ADDR:$PORT/server_info - is it up?" >&2; exit 1; }

# The JSON goes in through the ENVIRONMENT, not a pipe: the heredoc below is
# already on stdin, and a pipe into it would be silently discarded (shellcheck
# SC2259). /server_info is a few hundred bytes, so the env is the simplest
# channel that cannot be overridden.
RAW="$raw" BASE_URL="http://$ADDR:$PORT/v1" python3 - <<'PY'
import json
import os

d = json.loads(os.environ["RAW"])
st = (d.get("internal_states") or [{}])[0]
mem = st.get("memory_usage") or {}


def row(label, value, note=""):
    if value in (None, "", "?"):
        return
    print("  %-24s %14s   %s" % (label, value, note))


print()
print("  " + str(d.get("model_path", "?")))
print()
row("pool tokens", st.get("token_capacity") or mem.get("token_capacity"),
    "the shared paged cache, ACROSS all concurrent requests")
row("KV cache GiB", mem.get("kvcache"), "FP8 e4m3fn here, ~3 KB/token")
row("weights GiB", mem.get("weight"), "NVFP4, target + draft")
row("cuda graph GiB", mem.get("cuda_graph"))
row("max running reqs", d.get("max_running_requests"),
    "DERIVED from mem-fraction-static, not set by you")
row("context length", d.get("max_total_num_tokens") or d.get("context_length"))
print()

# Accept length is the ONE number that says the drafter is working. SGLang
# smooths it with an EMA over verify passes, so it means nothing until the
# server has actually verified a batch - a fresh boot reports 0 or nothing.
acc = next((st[k] for k in st if "accept_length" in k), None)
steps = st.get("speculative_num_steps") or st.get("spec_num_steps")
if acc is None:
    print("  no accept length reported - either speculative decoding is off, or")
    print("  nothing has been verified yet. Send it traffic, then re-run.")
else:
    row("avg accept length", acc, "1.0 means every draft is REJECTED")
    row("speculative steps", steps)
    print()
    print("  That is the AGGREGATE, and it cannot separate a weak drafter from a")
    print("  broken draft mask - which need different fixes:")
    print("    BASE_URL=%s ws up spec-decode-accept" % os.environ.get("BASE_URL", ""))
print()
PY
