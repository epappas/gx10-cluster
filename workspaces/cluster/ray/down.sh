#!/usr/bin/env bash
set -euo pipefail
PEERS_FILE=${GX10_PEERS_FILE:-/etc/gx10/interconnect.peers}
docker rm -f ws-ray-head >/dev/null 2>&1 && echo "head stopped" || echo "head not running"
if [[ -r $PEERS_FILE ]]; then
    while read -r h; do
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" \
            'docker rm -f ws-ray-worker >/dev/null 2>&1' 2>/dev/null \
            && echo "worker on $h stopped" || echo "worker on $h: unreachable or not running"
    done < <(awk '!/^#/ && NF {print $1}' "$PEERS_FILE" | sort -u)
fi
