#!/bin/bash
# Two-node distributed training over the RoCE interconnect.
#
#   sbatch train-2node.sbatch your_script.py
#
#SBATCH --job-name=train2
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=12:00:00
#SBATCH --output=%x-%j.log
set -euo pipefail

# NO --gpus-per-node, AND THAT IS NOT AN OVERSIGHT. It was here, and it made
# this script unsubmittable against the Slurm this repo installs:
#
#   sbatch: error: Invalid generic resource (gres) specification
#
# `--gpus*` is a GRES request, and roles/slurm deliberately configures none -
# its slurm.conf.j2 says so in as many words ("not the full cgroup/GRES
# apparatus"). The two halves of the repo disagreed, and the workspace half was
# wrong: on a GB10 each node has exactly ONE GPU, so --nodes=2 with
# --ntasks-per-node=1 already gives each rank a whole node and its whole GPU.
# GRES would be bookkeeping for a choice there is nothing to choose.
#
# If you ever add GPUs per node, add GresTypes/Gres to the role FIRST, then put
# the flag back - in that order, or you get this error again.
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
