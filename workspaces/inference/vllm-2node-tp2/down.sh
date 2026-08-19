#!/usr/bin/env bash
set -euo pipefail
NAME=ws-vllm-2node
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
docker rm -f "$NAME" >/dev/null 2>&1 && echo "rank 0 stopped" || echo "rank 0 not running"
if [[ -r $PEERS_FILE ]]; then
    while read -r h; do
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" "docker rm -f $NAME >/dev/null 2>&1" 2>/dev/null \
            && echo "rank 1 on $h stopped" || echo "rank 1 on $h: unreachable or not running"
    done < <(awk '!/^#/ && NF {print $1}' "$PEERS_FILE" | sort -u)
fi
