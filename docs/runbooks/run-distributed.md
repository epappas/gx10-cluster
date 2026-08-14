# Runbook: run jobs across both nodes

**What** — run training or inference on both GX10s.
**When** — after the [interconnect is up](connect-cluster.md).
**Risk** — none to the machines; jobs fail loudly, not quietly.

## Pick the smallest thing that works

| You want | Use | Install needed |
|---|---|---|
| A 2-node training run | **torchrun** | none |
| Multi-node vLLM (a model too big for one node) | **Ray** | `make optional TAGS=ray` |
| A queue, fair-share, job accounting | **Slurm** | `make optional TAGS=slurm` |

Neither orchestrator is installed by default, and neither is needed to run
across both boxes — `torchrun` already does that. Reach for one when you want
a cluster that *outlives a single job*.

## torchrun — no orchestrator

Run the same command on both boxes, changing only `--node_rank`. torch lives
in the shared venv, so use its `torchrun` (or run `ml` first).

```bash
# node A                                   # node B
~/venvs/ml/bin/torchrun \                  ~/venvs/ml/bin/torchrun \
  --nnodes 2 --nproc_per_node 1 \            --nnodes 2 --nproc_per_node 1 \
  --node_rank 0 \                            --node_rank 1 \
  --master_addr gx10-a --master_port 29500 \ --master_addr gx10-a --master_port 29500 \
  train.py                                   train.py
```

`gx10-a` resolves over the interconnect — the cluster role puts both nodes in
`/etc/hosts` on the `192.168.100` subnet, so collectives do not go over WiFi.

Sanity-check the fabric before blaming your script:

```bash
~/venvs/ml/bin/torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
  --master_addr gx10-a --master_port 29500 ~/cluster/allreduce_test.py
```

Expect ~10 GB/s busbw. Anything much lower is the fabric, not the model —
see [connect-cluster](connect-cluster.md#reading-the-result).

## Ray

```bash
make optional TAGS=ray
~/venvs/ml/bin/ray status          # both nodes listed?
```

Rank 0 runs the head, the other joins it, both bound to the interconnect
address so object transfers use the 200G link. The service is enabled, so the
cluster comes back after a reboot.

Its main use here is a model that does not fit one node:

```bash
vllm-serve nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16 --tensor-parallel-size 2
```

230 GB of weights across ~242 GB of combined memory leaves roughly 12 GB for KV
cache — real, but tight. **FP8 across two nodes (119.6 GB) is the comfortable
version** and probably what you want.

Dashboard on the head at `:8265`, bound to localhost:
`ssh -L 8265:localhost:8265 gx10-a`.

## Slurm

```bash
make optional TAGS=slurm
sinfo                      # both nodes idle?
srun -N2 hostname          # smoke test
sbatch job.sh
```

Honest assessment: a controller, a daemon and munge key distribution to queue
jobs across two machines is a lot of apparatus. It earns its place when you
want queueing, fair-share or accounting — not merely to run something on both
boxes.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Hangs before the first step | NCCL bootstrap cannot connect | Check `mgmt_iface` is up and reachable **both ways** |
| `busbw` single-digit GB/s | Collective fell back to TCP | `NCCL_DEBUG=INFO`, look for `NET/IB` not `NET/Socket` |
| ~1.6 GB/s (13 Gbps) | CX-7 firmware power throttle | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| Ray worker never joins | Head unreachable on the interconnect | `ping 192.168.100.10`; `journalctl -u ray` |
| `srun` hangs, no error mentioning munge | Munge keys differ between nodes | Re-run the full play so the key is distributed |
| Only one node has the model | The HF cache is per-node | `make models` on both, or `--limit` each in turn |
| Job runs but is slow, one node idle | Ranks not both launched | Both boxes need the command; only `--node_rank` differs |

## What is *not* shared between the nodes

There is no shared filesystem. Each box has its own HF cache, its own venv, its
own checkpoints. Provision both with the same playbook and they match, but a
model downloaded on node A is not visible on node B — pull it on both, or
`rsync` the cache over the interconnect.
