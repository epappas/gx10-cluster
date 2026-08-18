#!/bin/bash
# Serve a model under Slurm so the queue owns the GPU, rather than a stray
# container holding it after you log out.
#
#   sbatch serve-vllm.sbatch
#
#SBATCH --job-name=vllm-serve
#SBATCH --nodes=1
#SBATCH --gpus=1
#SBATCH --time=08:00:00
#SBATCH --output=%x-%j.log
set -euo pipefail

MODEL=${MODEL:-unsloth/Qwen3.8-27B-NVFP4}
PORT=${PORT:-8888}

echo "node=$(hostname)  model=$MODEL  port=$PORT"

# Reuses the same image and flags as the vllm workspace deliberately: two
# recipes that drift apart are worse than one you have to read twice.
exec docker run --rm --runtime nvidia --ipc host --shm-size 16g \
    -v "${HF_HOME:-$HOME/.cache/huggingface}:/hf" -e HF_HOME=/hf \
    -p "${PORT}:8000" \
    vllm/vllm-openai:nightly-aarch64 \
    --model "$MODEL" --host 0.0.0.0 --port 8000 \
    --gpu-memory-utilization 0.84 --max-model-len 262144 \
    --kv-cache-dtype fp8 --reasoning-parser qwen3 --trust-remote-code
