#!/usr/bin/env bash
# Deploy the harness to the node that should run it, and point it at a model
# this cluster serves. Called by `ws up deepseek-harness`; also runnable by
# hand, which is the rule for every recipe here.
#
# WHERE. The harness is a CLIENT: it needs no GPU and no unified memory, so it
# belongs on a node that is not holding a rank. On this cluster that is
# gb10-homer. The server stays on the head (odysseus) and the harness reaches
# it over the network - see README, "Where the harness runs".
#
#   HARNESS_HOST=gb10-homer   the ssh target (key-based). `local` runs here.
#   HARNESS_ENDPOINT=...      scheme://host:port of the server, WITHOUT /v1.
#                             Unset: the recipe's loopback URL when local,
#                             else the head's nordlynx address (the mesh path
#                             ufw already allows). README has the LAN rule.
#   HARNESS_SETTINGS=<name>   a file in settings/, default the 1017 recipe.
#
# What lands on the node is compose.yml, .env and dsh-home/settings.yaml.
# dsh-home/ is the node's own state; nothing here deletes it.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

[[ -f .env ]] && { set -a; # shellcheck disable=SC1091
                   source .env; set +a; }

HARNESS_HOST=${HARNESS_HOST:-gb10-homer}
HARNESS_SETTINGS=${HARNESS_SETTINGS:-tensorfold-2node-dsv41-flash-1017}
REMOTE_DIR=${REMOTE_DIR:-ws-deepseek-harness}
PROJECT=ws-deepseek-harness

# The settings writer lives in use.sh and is the ONLY place the endpoint line
# is rendered. Sourced rather than re-implemented: two copies of that rewrite
# is how a workspace ends up pointing at two different servers.
# shellcheck source-path=SCRIPTDIR source=use.sh
source ./use.sh

# use.sh's errors say "use.sh:"; this script's should say where they came from.
die() { printf 'up.sh: %s\n' "$*" >&2; exit 1; }

settings="settings/$HARNESS_SETTINGS.yaml"
[[ -f $settings ]] || die "no settings for '$HARNESS_SETTINGS' (settings/ has: $(available | tr '\n' ' '))"

ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }

endpoint=$(endpoint_for "$settings")

if ! is_local; then
    # The client is on another node, so the reachability that matters is ITS,
    # not ours. A server that answers here and not there is a firewall, and
    # the first message in the UI would be the thing that told you.
    remote "curl -sf --max-time 6 '$endpoint/v1/models' >/dev/null" \
        || die "$HARNESS_HOST cannot reach $endpoint/v1/models.
  mesh path: nordlynx up on both nodes (this is what ufw already allows)
  LAN path:  a ufw rule on the head for :$(sed -n 's#.*baseURL: *https\?://[^:/]*:\([0-9]\+\)/v1.*#\1#p' "$settings" | head -1) - README, 'Reaching the server'"
    ok "$HARNESS_HOST reaches $endpoint"
fi

# use.sh writes the live settings file - locally or on the node - with the
# endpoint rewritten, and verifies the id against the running server.
cmd_use "$HARNESS_SETTINGS"

if is_local; then
    docker compose --project-name "$PROJECT" up -d
else
    files=(compose.yml)
    [[ -f .env ]] && files+=(.env)
    remote "mkdir -p '$REMOTE_DIR/work'"
    rsync -az "${files[@]}" "$HARNESS_HOST:$REMOTE_DIR/"
    remote "cd '$REMOTE_DIR' && docker compose --project-name '$PROJECT' up -d"
fi

ok "started on $HARNESS_HOST, pointed at $endpoint ($HARNESS_SETTINGS)"
echo
ui_port=${DSH_PORT:-3080}
if is_local; then
    echo "  web UI: http://127.0.0.1:$ui_port  (token: ws logs deepseek-harness | grep token=)"
else
    echo "  the UI binds 127.0.0.1:$ui_port ON $HARNESS_HOST, so tunnel to it:"
    echo "    ssh -L $ui_port:127.0.0.1:$ui_port $HARNESS_HOST"
    echo "  then open the URL in the container log:"
    echo "    ssh $HARNESS_HOST docker logs ws-deepseek-harness | grep -o 'http://[^ ]*token=[^ ]*'"
fi
echo "  first start resolves the npm tree: up to 12 minutes before :$ui_port binds."
