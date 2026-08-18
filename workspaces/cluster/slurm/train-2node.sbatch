#!/bin/bash
# Two-node distributed training over the RoCE interconnect.
#
#   sbatch train-2node.sbatch your_script.py
#
#SBATCH --job-name=train2
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --time=12:00:00
#SBATCH --output=%x-%j.log
set -euo pipefail

SCRIPT=${1:?usage: sbatch train-2node.sbatch <script.py>}

# The rendezvous runs on the MANAGEMENT name, not the .cluster interconnect
# name. This looks like leaving performance on the table and does not: NCCL
# picks the RoCE data path independently via ibverbs, while the bootstrap needs
# an address that is up even when the cable is not.
# See docs/decisions.md#nccl-socket-ifname and #hosts-split.
MASTER=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -1)

srun bash -c "
  ~/venvs/ml/bin/torchrun \
    --nnodes=$SLURM_NNODES --nproc_per_node=1 \
    --node_rank=\$SLURM_PROCID \
    --master_addr=$MASTER --master_port=29500 \
    $SCRIPT
"
