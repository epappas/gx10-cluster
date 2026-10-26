#!/usr/bin/env bash
# One question to the harness, from a terminal. Answer to stdout, then exit.
#
# THERE IS NO TUI. dsh ships five profiles - web, headless, sdk, sdk-minimal
# and acp - and none of them is a terminal UI. Its own README shows
# `--profile tui` only as a hypothetical ("assuming the tui profile is
# installed"), and no terminal-app bundle is published: @deepseek-ai/dsh-tui,
# -dsh-tui-app, -dsh-terminal-app and -dsh-cli-app are all 404 on npm, and the
# shipped bundle list is base / web-app / headless / sdk-app / sdk-minimal /
# acp-app. So `headless` IS the terminal mode, and this wraps it.
#
#   ./ask.sh "summarise the README in three lines"
#   ./ask.sh < prompt.txt
#   echo "what does up.sh do?" | ./ask.sh
#
# It runs INSIDE the already-running container - on this node, or on the one
# HARNESS_HOST names (default gb10-homer) - so it uses the same settings.yaml,
# the same cached npm tree and the same /work mount as the web UI.
# `ws up deepseek-harness` first. Each call is a fresh session: headless
# persists it but never resumes one, so this is not a conversation.
#
# It has the SAME TOOL ACCESS as the web UI: whatever DSH_WORKSPACE mounts at
# /work. That is the boundary, and it is the only one.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

[[ -f .env ]] && { set -a; # shellcheck disable=SC1091
                   source .env; set +a; }

HARNESS_HOST=${HARNESS_HOST:-gb10-homer}
CONTAINER=ws-deepseek-harness
# Same default as compose.yml: 0.2.1 moved provider config out of
# settings.yaml, so the catalogue this script's container reads needs 0.1.5.
VERSION=${DSH_VERSION:-0.1.5-rc.1}

running() {
    case $HARNESS_HOST in
        local|localhost|"$(hostname)"|"$(hostname -s)")
            docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null ;;
        *)
            ssh -o BatchMode=yes "$HARNESS_HOST" \
                "docker inspect -f '{{.State.Running}}' $CONTAINER" 2>/dev/null ;;
    esac
}

running | grep -qx true || {
    echo "ask.sh: $CONTAINER is not running on $HARNESS_HOST. start it with:" >&2
    echo "  ws up deepseek-harness" >&2
    exit 1
}

prompt=${1:-}
[[ -n $prompt ]] || prompt=$(cat)
[[ -n $prompt ]] || { echo "ask.sh: nothing to ask. try: ./ask.sh \"...\"" >&2; exit 1; }

# -i, not -it: the answer is meant to be pipeable, and a TTY would have dsh
# decorate it. The version follows .env so this cannot drift from the profile
# the container booted.
case $HARNESS_HOST in
    local|localhost|"$(hostname)"|"$(hostname -s)")
        exec docker exec -i "$CONTAINER" \
            npx -y "@deepseek-ai/dsh@$VERSION" --profile headless "$prompt"
        ;;
    *)
        # One remote shell string, so the prompt has to survive it: %q quotes
        # it for the remote shell rather than letting a quote or a newline
        # become syntax there.
        q=$(printf '%q' "$prompt")
        exec ssh -o BatchMode=yes "$HARNESS_HOST" \
            "docker exec -i $CONTAINER npx -y @deepseek-ai/dsh@$VERSION --profile headless $q"
        ;;
esac
