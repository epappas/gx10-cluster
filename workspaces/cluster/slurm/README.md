# slurm (workspace)

> Batch submission recipes for the Slurm that **Ansible** installs. Job scripts
> only — the daemons deliberately live on the other side of the line.

| | |
|---|---|
| Kind | `cluster` |
| Engine | Slurm |
| Nodes | **2** |
| Endpoint | `sbatch` / `squeue` on the controller node |
| Needs | 1 reachable peer — **and `make optional TAGS=slurm` already run** |
| Provenance | **`verified`** — daemons installed, `srun -N2` green, two-rank `torchrun` confirmed. [What the run changed](#what-running-it-changed) |

## What

Two `sbatch` scripts, and nothing else. There is no `up.sh` and no
`compose.yml`; `ws up slurm` has nothing to start, which is why
`tests/check_workspaces.py` exempts `kind: cluster` from the "something must
run" rule.

| Script | Does |
|---|---|
| [`serve-vllm.sbatch`](serve-vllm.sbatch) | Serves a model under the queue, so the **queue** owns the GPU rather than a stray container that outlives your login |
| [`train-2node.sbatch`](train-2node.sbatch) | Two-node `torchrun` over the RoCE interconnect, rendezvous derived from `SLURM_JOB_NODELIST` |

## Why

### Slurm is the one thing here that is *not* containerised

That is a considered exception, not an oversight.

**A scheduler is infrastructure.** It owns munge keys, a controller with state,
a daemon on every node and a shared clock. Running it per-experiment defeats the
point of having a queue, and a containerised `slurmd` that cannot see host
processes cannot account for them either.

So the split lands here:

| | Lives in | Because |
|---|---|---|
| `slurmctld`, `slurmd`, munge | **Ansible** — `make optional TAGS=slurm` | Infrastructure, converged once |
| The job scripts | **this workspace** | They change per experiment |

That is the same rule as everywhere else in this repo — Ansible converges the
machine, workspaces run the work. It just lands on the other side of the line
from [Ray](../ray/README.md), where the ephemeral option is genuinely useful.

### Honest assessment

A controller, a daemon and munge key distribution to queue jobs across **two**
machines is a lot of apparatus. It earns its place when you want queueing,
fair-share or accounting — **not** merely to run something on both boxes.
`torchrun` already does that with no orchestrator at all.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want a queue, fair-share or job accounting | You just want to run one job on both nodes → `torchrun` |
| Several people share the cluster | You want an interactive experiment → [`ray`](../ray/README.md) |
| A long serving job must survive your logout | You want to iterate on flags quickly → the inference workspaces |

## How

```bash
make optional TAGS=slurm     # install the daemons — NO --limit, see below
sinfo                        # both nodes idle?
srun -N2 hostname            # smoke test

sbatch workspaces/cluster/slurm/serve-vllm.sbatch
sbatch workspaces/cluster/slurm/train-2node.sbatch my_train.py
squeue
```

### Do **not** `--limit` a worker

The munge key is generated on `cluster_controller` and copied from there. A run
that excludes it installs `slurmd` with a key no other node shares — and the
failure surfaces as Slurm being unable to talk to the controller, with nothing
in the message naming munge. The role fails loudly instead of skipping.

### The rendezvous is on the management name, on purpose

`train-2node.sbatch` derives `MASTER` from `scontrol show hostnames`, which
gives the **management** name, not the `.cluster` interconnect name.

That looks like leaving performance on the table and does not: NCCL picks the
RoCE data path independently through ibverbs, while the bootstrap needs an
address that is up even when the cable is not
([why](../../../docs/decisions.md#hosts-split)).

### `serve-vllm.sbatch` reuses the inference flags on purpose

Same image, same `--gpu-memory-utilization`, same `--kv-cache-dtype` as
[`vllm-qwen3.8-27b-nvfp4`](../../inference/vllm-qwen3.8-27b-nvfp4/README.md).
Two recipes that drift apart are worse than one you have to read twice.

## What running it changed

**Both sbatch scripts were unsubmittable against the Slurm this repo
installs.** Every `sbatch` returned:

```
sbatch: error: Invalid generic resource (gres) specification
```

because they asked for `--gpus-per-node=1` / `--gpus=1`, and `--gpus*` is a
**GRES** request. `roles/slurm` configures no GRES, deliberately — its
`slurm.conf.j2` says *"not the full cgroup/GRES apparatus"* in as many words.
The two halves of the repo disagreed and the workspace half was wrong: on a
GB10 each node has exactly **one** GPU, so `--nodes` already allocates it and
GRES would be bookkeeping for a choice there is nothing to choose. The flags
are gone.

If you ever add GPUs per node, add `GresTypes`/`Gres` to the **role** first,
then put the flags back — in that order.

### What the verified run looks like

```bash
make optional TAGS=slurm     # 15 tasks, 0 failed, both nodes
sinfo                        # gx10* up infinite 2 idle odysseus,poseidon
srun -N2 hostname            # odysseus / poseidon
sbatch --chdir=/tmp workspaces/cluster/slurm/train-2node.sbatch /tmp/your.py
```

```
rank=0 host=odysseus master=odysseus:29500 world=2
rank=1 host=poseidon master=odysseus:29500 world=2
```

**That one line is the whole hosts-split argument, visible.** `MASTER` is the
*management* name from `scontrol show hostnames`, while `scontrol show node`
reports `NodeAddr=192.168.100.10` on the *interconnect* — the rendezvous uses
the always-up NIC, and NCCL picks the RoCE data path independently.

### There is no shared filesystem

`train-2node.sbatch` runs your script **by path on every node**, so the path
must resolve on both. Submitting from a directory the peer does not have also
produces:

```
slurmstepd-poseidon: error: couldn't chdir to `/home/epappas/gx10-cluster':
No such file or directory: going to /tmp instead
```

Harmless for `hostname`, not harmless for a script with relative paths. `scp`
the script to both nodes and pass `--chdir` to somewhere that exists on both.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `sbatch: error: Invalid generic resource (gres) specification` | A `--gpus*` flag against a Slurm with no GRES configured | Fixed in both shipped scripts. Do not re-add `--gpus*` without adding `Gres` to `roles/slurm` first |
| `couldn't chdir to <dir>: going to /tmp instead` | The submitting directory does not exist on the peer — there is no shared filesystem | `--chdir` to a path both nodes have, and `scp` your script there |
| Your script runs on rank 0 and `No such file or directory` on rank 1 | Same cause: the script exists on one node only | `scp` it to both |
| `srun` hangs, no error mentioning munge | Munge keys differ between nodes | Re-run `make optional TAGS=slurm` with **no** `--limit` |
| A node is marked down for no stated reason | `NodeAddr` points at an interconnect address the node does not hold | The role asserts this; `gx10-interconnect` |
| `sinfo`: command not found | The daemons were never installed | `make optional TAGS=slurm` |
| The serving job holds the GPU after you expected it to end | `--time=08:00:00` in the script | `scancel <jobid>` |
| Two-node training is slow, one node idle | Ranks not both launched | `--nodes=2 --ntasks-per-node=1` is already in the script; check `squeue` |

## Sources

- <https://slurm.schedmd.com/sbatch.html>

See also: [`workspace.yml`](workspace.yml) ·
[run-distributed](../../../docs/runbooks/run-distributed.md) ·
[roles/slurm](../../../roles/README.md)
