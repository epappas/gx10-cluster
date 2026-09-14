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
# It runs INSIDE the already-running container, so it uses the same
# settings.yaml, the same cached npm tree and the same /work mount as the web
# UI - `ws up deepseek-harness` first. Each call is a fresh session: headless
# persists it but never resumes one, so this is not a conversation.
#
# It has the SAME TOOL ACCESS as the web UI: whatever DSH_WORKSPACE mounts at
# /work. That is the boundary, and it is the only one.
set -euo pipefail

CONTAINER=ws-deepseek-harness

docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true || {
    echo "ask.sh: $CONTAINER is not running. start it with:" >&2
    echo "  ws up deepseek-harness" >&2
    exit 1
}

prompt=${1:-}
[[ -n $prompt ]] || prompt=$(cat)
[[ -n $prompt ]] || { echo "ask.sh: nothing to ask. try: ./ask.sh \"...\"" >&2; exit 1; }

# -i, not -it: the answer is meant to be pipeable, and a TTY would have dsh
# decorate it. The version follows .env so this cannot drift from the profile
# the container booted.
exec docker exec -i "$CONTAINER" \
    npx -y "@deepseek-ai/dsh@${DSH_VERSION:-latest}" --profile headless "$prompt"
