#!/usr/bin/env bash
# Exo is meant to be long-running: `/exit` from the REPL leaves the scheduler
# and adapter loops running, which is the point - the agent keeps working and
# you reconnect later. This is how you actually stop it.
#
# STATE IS PRESERVED. `stop-all` stops the runners; every agent, conversation
# and event stays in $EXO_SRC/.exo. Throwing that away is `./exo.sh fresh` in
# the checkout, and it is not wired up here on purpose.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

EXO_SRC=${EXO_SRC:-$HOME/src/exo}

[[ -x $EXO_SRC/exo.sh ]] || { echo "no checkout at $EXO_SRC - nothing to stop"; exit 0; }

if ! command -v node >/dev/null; then
    # shellcheck source=/dev/null
    [[ -s $HOME/.nvm/nvm.sh ]] && { . "$HOME/.nvm/nvm.sh"; nvm use default >/dev/null 2>&1 || true; }
fi
export PATH="$HOME/.cargo/bin:$PATH"

cd "$EXO_SRC" && ./exo.sh stop-all

# The SANDBOX container is exo's, not ours: it holds whatever the agent
# installed and can be snapshotted and rewound by the agent itself. Removing it
# here would silently discard work, so it is left running. `docker ps` shows
# it; remove it by hand if you mean to.
