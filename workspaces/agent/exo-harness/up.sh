#!/usr/bin/env bash
# Exo - a recursive self-improving agent harness - pointed at a model THIS
# CLUSTER serves.
#
# NO CONTAINER FOR EXO ITSELF, and that is not laziness. Exo's design puts the
# host loop OUTSIDE the sandbox: the loop builds context and executes tool
# calls, and the tool calls land in a Docker container exo starts and owns.
# Running exo in a container would mean docker-in-docker, or a shared socket
# whose bind-mount paths mean different things on each side of it - and the
# path that would break first is /workspace/exo, the mount that lets exo read
# and rewrite its own source. So exo runs on the host, exactly as upstream
# ships it, and the sandbox it starts is the boundary that was always meant to
# be the boundary.
#
# THE OTHER HALF OF THAT SENTENCE. Exo can rebuild and restart itself. The
# checkout is therefore STATE, not a build artifact - .exo/ inside it holds
# every agent, conversation and event - so it lives at ~/src/exo alongside the
# other things this repo builds from source, and this script never deletes it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# .env is gitignored and optional, so shellcheck cannot see it.
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# ~/src/exo mirrors ~/src/verl in ray-verl and llama.cpp in roles/ml: one place
# for "the thing this repo builds from source".
EXO_SRC=${EXO_SRC:-$HOME/src/exo}
# Pinned like verl_version and llama_cpp_version, for the same reason: two
# boxes should come up identical, and `main` on the day you happened to clone
# is not that. Exo publishes no tags, so the pin is a commit.
EXO_REF=${EXO_REF:-7801005e6a1ab77008a05dbba80e0a2a7a56e35d}

# WHERE THE MODEL IS. Exo runs on the host, so this is simply the address you
# would curl - there is no container namespace in between.
#   8888  vllm-qwen3.8-27b-nvfp4 (served as qwen3.8-27b), vllm-2node-tp2
#   8890  vllm-2node-deepseek-v4-flash (deepseek-v4-flash)
#   8891  llamacpp-deepseek-v4-flash-gguf
#   8899  llamacpp-qwen3.8-27b-gguf (served under the HF repo id)
#   8900  sglang-qwen3.8-27b-int4
EXO_BASE_URL=${EXO_BASE_URL:-http://127.0.0.1:8888/v1}
# The SERVED name (--served-model-name), not the HF repo id. Exo calls this the
# "upstream model"; `curl -s ${EXO_BASE_URL}/models` prints exactly this.
EXO_UPSTREAM=${EXO_UPSTREAM:-qwen3.8-27b}
# What exo calls the binding locally. Kept DELIBERATELY unlike any OpenAI model
# name: exo picks the Responses API by NAME, for anything matching gpt-5-codex,
# gpt-5.3+, o1-pro, o3-pro or gpt-5-pro. Name a binding `gpt-5.3-local` and it
# will speak an API that vLLM and llama.cpp do not serve, and the failure is a
# 404 from a URL you never typed.
EXO_BINDING=${EXO_BINDING:-gx10-local}
# Any non-empty string: a locally served model ignores the value, but the
# OpenAI client refuses to send a request without one. Stored in exo's own
# keystore by `register-model`, so it is not needed again after the first run.
LOCAL_API_KEY=${LOCAL_API_KEY:-gx10}

# MINIMAL, NOT CANONICAL, AND THIS IS THE ONE CHOICE HERE WORTH ARGUING WITH.
# The `canonical` template wires up ExoChat - a chat UI hosted at
# exoharness.ai - which means the conversation with a model your own cluster is
# serving would travel through someone else's server. That is the exact thing
# the pairing exists to avoid, so the default is `minimal` plus an explicit
# Docker sandbox. Set EXO_TEMPLATE=canonical in .env if you want ExoChat and
# have decided that trade is fine.
EXO_TEMPLATE=${EXO_TEMPLATE:-minimal}
EXO_SANDBOX_IMAGE=${EXO_SANDBOX_IMAGE:-ubuntu:24.04}

# --- what the host has to provide ------------------------------------------
# None of these are things `requires:` can express, and all four are optional
# ansible roles rather than site.yml ones, so name the command that fixes each.
docker ps -q >/dev/null 2>&1 || {
    echo "docker not usable - re-login for the docker group, or: make apply TAGS=docker" >&2; exit 1; }
command -v git >/dev/null || { echo "git not found - make apply TAGS=base" >&2; exit 1; }

# Node lives in nvm, which is a shell function and not a binary, so a
# non-interactive shell has no node on PATH at all. Same two lines roles/editor
# and roles/dev_node use, and for the same reason.
if ! command -v node >/dev/null; then
    # shellcheck source=/dev/null
    [[ -s $HOME/.nvm/nvm.sh ]] && { . "$HOME/.nvm/nvm.sh"; nvm use default >/dev/null 2>&1 || true; }
fi
command -v node >/dev/null || {
    echo "node not found - make optional TAGS=node" >&2; exit 1; }
command -v pnpm >/dev/null || {
    echo "pnpm not found - it is in npm_globals: make optional TAGS=node" >&2; exit 1; }
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || {
    echo "cargo not found - make optional TAGS=rust" >&2; exit 1; }

# --- the source ------------------------------------------------------------
if [[ ! -d $EXO_SRC/.git ]]; then
    echo "==> cloning exo into $EXO_SRC (pinned at ${EXO_REF:0:12})"
    # Not --depth 1: the pin is a commit, and a shallow clone of a branch tip
    # cannot check one out. Exo's history is small enough that this is seconds.
    git clone https://github.com/exoharness/exo "$EXO_SRC"
    git -C "$EXO_SRC" checkout --quiet "$EXO_REF"
else
    have=$(git -C "$EXO_SRC" rev-parse HEAD)
    if [[ $have != "$EXO_REF" ]]; then
        # A WARNING, NOT A RESET. Exo rewrites its own source - that is the
        # entire premise - so an unexpected HEAD here is as likely to be the
        # agent's work as it is to be drift, and `git checkout` over it would
        # throw away the thing you ran this for.
        echo "!  $EXO_SRC is at ${have:0:12}, pin is ${EXO_REF:0:12}." >&2
        echo "!  Exo edits its own source, so this may be the agent's doing." >&2
        echo "!  Set EXO_REF in .env to adopt it, or check it out yourself." >&2
    fi
fi

# --- the build -------------------------------------------------------------
# `exo.sh build` is pnpm install + two cargo builds. Measured on a GB10 from a
# cold clone: 1m01s for the exo crate, 47s for the scheduler runner, and the
# tree it leaves behind is 11 GB - 9.6 GB of that is target/, which is a debug
# profile WITH debuginfo, for two binaries sharing one dependency graph.
if [[ ! -x $EXO_SRC/target/debug/exo || ! -x $EXO_SRC/target/debug/exo-scheduler-runner ]]; then
    echo "==> building exo (first run: a few minutes)"
    ( cd "$EXO_SRC" && ./exo.sh build )
fi

# --- is the model actually there? ------------------------------------------
# A WARNING, NOT A GATE, for the same reason as pi-harness: a two-node recipe
# that is still loading is worth starting an agent against, it just cannot
# answer yet.
if ! curl -fsS --max-time 3 "$EXO_BASE_URL/models" >/dev/null 2>&1; then
    echo "! nothing answering at $EXO_BASE_URL - start a model first, e.g." >&2
    echo "!   ws up vllm-qwen3.8-27b-nvfp4      (8888, served as qwen3.8-27b)" >&2
elif ! curl -fsS --max-time 3 "$EXO_BASE_URL/models" | grep -q "\"$EXO_UPSTREAM\""; then
    echo "! $EXO_BASE_URL answers, but does not serve '$EXO_UPSTREAM'. It serves:" >&2
    curl -fsS --max-time 3 "$EXO_BASE_URL/models" \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/!   \1/' >&2
    echo "! set EXO_UPSTREAM in .env." >&2
fi

# --- the model binding -----------------------------------------------------
# IDEMPOTENT BY ASKING, not by a marker file. `exo model list` is the state,
# and a re-register would mint a second binding with the same name rather than
# updating the first.
export LOCAL_API_KEY
if ( cd "$EXO_SRC" && ./target/debug/exo model list 2>/dev/null ) \
        | awk 'NR>1 {print $1}' | grep -qx "$EXO_BINDING"; then
    :
else
    echo "==> registering $EXO_BINDING -> $EXO_UPSTREAM at $EXO_BASE_URL"
    ( cd "$EXO_SRC" && ./exo.sh register-model \
        --model "$EXO_BINDING" \
        --upstream-model "$EXO_UPSTREAM" \
        --secret-name "${EXO_SECRET_NAME:-gx10}" \
        --secret-env LOCAL_API_KEY \
        --base-url "$EXO_BASE_URL" )
    echo "   (to repoint it later, register a NEW binding name - exo does not"
    echo "    update one in place, and a duplicate name is ambiguous)"
fi

echo
echo "scheduler log  $EXO_SRC/.exo/exo-scheduler.log"
echo "adapter log    $EXO_SRC/.exo/exo-adapters.log"
echo "event stream   (cd $EXO_SRC && pnpm events:tail)"
echo

# --provider docker is passed EXPLICITLY because --template minimal skips the
# defaults that would otherwise set it, and exo refuses to start with a sandbox
# required and no provider chosen rather than picking one.
args=(--template "$EXO_TEMPLATE"
      --model "$EXO_BINDING"
      --provider docker
      --sandbox-image "$EXO_SANDBOX_IMAGE")

# Pull ONLY when the image is missing. `--pull-sandbox` unconditionally is a
# registry round trip on every start of an agent you may be running precisely
# because you wanted nothing leaving the house.
docker image inspect "$EXO_SANDBOX_IMAGE" >/dev/null 2>&1 || args+=(--pull-sandbox)

# NO --skip-build, deliberately. exo.sh rebuilds when its own sources are newer
# than the binary, and for THIS agent that is not a convenience - rewriting its
# own source and restarting is the entire premise. Skipping the build would
# silently run yesterday's exo against today's code.
cd "$EXO_SRC"
exec ./exo.sh "${args[@]}" "$@"
