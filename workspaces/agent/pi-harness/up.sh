#!/usr/bin/env bash
# Pi - a terminal coding harness - pointed at a model THIS CLUSTER serves.
#
# NO COMPOSE, AND THE REASON IS THE SHAPE OF THE TOOL. The sibling
# deepseek-harness is a web UI: a long-running service that compose starts
# detached and you visit in a browser. Pi is a TUI. `docker compose up -d`
# gives a detached process with no terminal, which for pi means a container
# that starts, finds no tty, and is useless. So this is `docker run -it`, and
# `ws up pi-harness` puts you IN it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# The pin is also the image tag, so bumping PI_VERSION builds a new image
# instead of silently reusing the old one under the same name.
PI_VERSION=${PI_VERSION:-0.84.4}
NODE_IMAGE=${NODE_IMAGE:-node:24-bookworm-slim}
IMAGE=${PI_IMAGE:-ws-pi-harness:$PI_VERSION}
CONTAINER=${PI_CONTAINER:-ws-pi-harness}

# WHERE THE MODEL IS. Host networking means this address means the same thing
# inside the container as it does in your shell, so if `curl` works, pi works.
#   8888  vllm-qwen3.8-27b-nvfp4 (served as qwen3.8-27b), vllm-2node-tp2
#   8890  vllm-2node-deepseek-v4-flash (deepseek-v4-flash)
#   8891  llamacpp-deepseek-v4-flash-gguf
#   8899  llamacpp-qwen3.8-27b-gguf (served under the HF repo id)
#   8900  sglang-qwen3.8-27b-int4
PI_BASE_URL=${PI_BASE_URL:-http://127.0.0.1:8888/v1}
# The SERVED name, which --served-model-name set - not the HF repo id.
# `curl -s ${PI_BASE_URL}/models` prints exactly this.
PI_MODEL_ID=${PI_MODEL_ID:-qwen3.8-27b}
PI_PROVIDER_ID=${PI_PROVIDER_ID:-gx10}
# Any non-empty string. A locally served model ignores the value, but pi hides
# a provider with no configured auth from /model entirely - so the models load
# and then never appear, which reads as a broken models.json.
LOCAL_API_KEY=${LOCAL_API_KEY:-gx10}
# THE ONE SETTING WORTH THINKING ABOUT. Pi has read, write, edit and bash, and
# upstream's README says plainly that it ships no permission system. This is
# the boundary. It defaults to an empty directory, not to $HOME.
PI_WORKSPACE=${PI_WORKSPACE:-$PWD/work}
# Startup network calls only: update checks, package updates, telemetry. Model
# requests are unaffected, which is why this can default to on.
PI_OFFLINE=${PI_OFFLINE:-1}

docker ps -q >/dev/null 2>&1 || {
    echo "docker not usable - re-login for the docker group, or: make apply TAGS=docker" >&2; exit 1; }

mkdir -p pi-agent "$PI_WORKSPACE"

# --- is the model actually there? ------------------------------------------
# A WARNING, NOT A GATE. Pi is still worth starting against a server that has
# not finished loading - it just cannot answer yet - and `ws up` on a two-node
# recipe that is mid-load should not refuse. But "no models in /model" with no
# other explanation costs ten minutes every time, so say it here.
if ! curl -fsS --max-time 3 "$PI_BASE_URL/models" >/dev/null 2>&1; then
    echo "! nothing answering at $PI_BASE_URL - start a model first, e.g." >&2
    echo "!   ws up vllm-qwen3.8-27b-nvfp4      (8888, served as qwen3.8-27b)" >&2
    echo "! pi will start, but /model will be empty." >&2
elif ! curl -fsS --max-time 3 "$PI_BASE_URL/models" | grep -q "\"$PI_MODEL_ID\""; then
    echo "! $PI_BASE_URL answers, but does not serve '$PI_MODEL_ID'. It serves:" >&2
    curl -fsS --max-time 3 "$PI_BASE_URL/models" \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/!   \1/' >&2
    echo "! set PI_MODEL_ID in .env - and delete pi-agent/models.json if it" >&2
    echo "! already exists, since the seed below only writes a file that does not." >&2
fi

# --- the model binding -----------------------------------------------------
# SEEDED, NOT TEMPLATED. A tracked models.example.json plus a copy step means
# two files that say the same thing and drift apart; the port and model name
# already live in .env, so rendering them here keeps one source of truth.
# Written once - after that the file is yours and this never touches it again.
if [[ ! -f pi-agent/models.json ]]; then
    cat > pi-agent/models.json <<JSON
{
  "providers": {
    "$PI_PROVIDER_ID": {
      "baseUrl": "$PI_BASE_URL",
      "api": "openai-completions",
      "apiKey": "\$LOCAL_API_KEY",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        { "id": "$PI_MODEL_ID" }
      ]
    }
  }
}
JSON
    echo "wrote pi-agent/models.json: $PI_PROVIDER_ID -> $PI_BASE_URL, model $PI_MODEL_ID"
    echo "  (edit it, or delete it and set PI_BASE_URL/PI_MODEL_ID in .env to re-seed)"
fi

# --- the image -------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building $IMAGE (once per PI_VERSION)..."
    docker build -t "$IMAGE" \
        --build-arg "NODE_IMAGE=$NODE_IMAGE" \
        --build-arg "PI_VERSION=$PI_VERSION" .
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "container '$CONTAINER' already exists. Stop it with:" >&2
    echo "  ws down pi-harness" >&2
    echo "or run a second one with PI_CONTAINER=ws-pi-2 in .env." >&2
    exit 1
fi

# -t only when there IS a terminal, so `ws up pi-harness -p 'hello'` works in a
# pipe or from a script. -i always: print mode reads piped stdin.
tty_flags=(-i); [[ -t 0 && -t 1 ]] && tty_flags+=(-t)

exec docker run --rm "${tty_flags[@]}" \
    --name "$CONTAINER" \
    --network host \
    --user "$(id -u):$(id -g)" \
    -e "LOCAL_API_KEY=$LOCAL_API_KEY" \
    -e "PI_OFFLINE=$PI_OFFLINE" \
    -e "TERM=${TERM:-xterm-256color}" \
    -v "$PWD/pi-agent:/pi" \
    -v "$PI_WORKSPACE:/work" \
    "$IMAGE" \
    pi "$@"
