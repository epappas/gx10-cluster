#!/usr/bin/env bash
# Runs a verl GRPO job. Interactive and blocking by design: an RL run is
# something you watch, not a service you background.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

IMAGE=${IMAGE:-verlai/verl:latest}
CONFIG=${CONFIG:-grpo-qwen3-8b.yaml}

[[ -f $CONFIG ]] || { echo "no config $CONFIG" >&2; exit 1; }

echo "verl GRPO  image=$IMAGE  config=$CONFIG"
echo "this holds the policy, a reference copy, optimiser state AND the rollout"
echo "engine in one 121 GB pool. Watch it: gx10-top"
echo

exec docker run --rm -it \
    --runtime nvidia --ipc host --shm-size "${SHM_SIZE:-32g}" \
    --network host \
    -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf" -e HF_HOME=/hf \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "$PWD:/work" -w /work \
    "$IMAGE" \
    python3 -m verl.trainer.main_ppo --config-path /work --config-name "${CONFIG%.yaml}"
