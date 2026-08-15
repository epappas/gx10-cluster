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
  --master_addr odysseus --master_port 29500 \ --master_addr odysseus --master_port 29500 \
  train.py                                   train.py
```

### What `--master_addr odysseus` actually selects

`odysseus` is the **management** address. The cluster role puts the bare node name
in `/etc/hosts` pointing at `ansible_host`, and `odysseus.cluster` pointing at
`192.168.100.10` on the interconnect.

That is deliberate, and it does not cost you the fast link, because **the
rendezvous address does not decide the collective transport**. Two planes, chosen
separately:

| Plane | Carries | Chosen by |
|---|---|---|
| Control | torchrun rendezvous, NCCL bootstrap, `ssh` to launch workers | `--master_addr`, and `NCCL_SOCKET_IFNAME` in `/etc/nccl.conf` — both the management NIC |
| Data | the collectives themselves | NCCL, independently: RoCE over ibverbs on the ConnectX-7 |

So control traffic goes over the management link and the all-reduce goes over
the cable, whichever name you rendezvous on. Putting the node names on the
interconnect — which this repo used to do — moved control traffic onto the cable
and changed nothing about the data path, while breaking `ssh poseidon` and every
health check on an uncabled pair
([why](../decisions.md#hosts-split)).

Use `odysseus.cluster` when you explicitly want the 200G path for something —
`rsync` of a checkpoint or an HF cache, for instance.

Sanity-check the fabric before blaming your script:

```bash
~/venvs/ml/bin/torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
  --master_addr odysseus --master_port 29500 ~/cluster/allreduce_test.py
```

Expect ~10 GB/s busbw. Anything much lower is the fabric, not the model —
see [connect-cluster](connect-cluster.md#reading-the-result).

## Ray

```bash
make optional TAGS=ray
~/venvs/ml/bin/ray status          # both nodes listed?
```

The `cluster_controller` node — rank 0, derived from `cluster_rank` and never
from inventory order — runs the head; the other joins it. Both bind
`--node-ip-address` to their interconnect address so object transfers use the
200G link. The service is enabled, so the cluster comes back after a reboot.

**Ray refuses to install without the cable.** The role asserts that
`192.168.100.<index>` is actually configured on the node, because binding to an
address the box does not hold is `EADDRNOTAVAIL` and `ray start` reports it as
an addressing error with nothing about cabling. Falling back to the management
interface is deliberately not offered: it would put every object transfer on
WiFi and still report success.

Its main use here is a model that does not fit one node:

```bash
vllm-serve nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16 --tensor-parallel-size 2
```

230 GB of weights across ~242 GB of combined memory leaves roughly 12 GB for KV
cache — real, but tight. **FP8 across two nodes (119.6 GB) is the comfortable
version** and probably what you want.

Dashboard on the head at `:8265`, bound to localhost:
`ssh -L 8265:localhost:8265 odysseus`.

## Slurm

```bash
make optional TAGS=slurm   # no LIMIT: the controller must run first
sinfo                      # both nodes idle?
srun -N2 hostname          # smoke test
sbatch job.sh
```

Same interconnect prerequisite as Ray — `slurm.conf` gives every node a
`NodeAddr` on the first interconnect subnet, and the role asserts that address
exists rather than letting the controller mark a node down for reasons that
never mention cabling.

**Do not `--limit` a worker.** The munge key is generated on
`cluster_controller` and copied; a run that excludes it would install slurmd
with a key no other node shares, and the failure surfaces as slurm being unable
to talk to the controller, not as anything naming munge. The role fails loudly
instead of skipping.

Honest assessment: a controller, a daemon and munge key distribution to queue
jobs across two machines is a lot of apparatus. It earns its place when you
want queueing, fair-share or accounting — not merely to run something on both
boxes.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Hangs before the first step | **ufw dropping the NCCL bootstrap** | `sudo ufw status \| grep 'gx10 peer node'` — see below |
| Hangs before the first step | `mgmt_iface` down or not reachable both ways | `ip -br link show "$(ip route show default \| awk '{print $5; exit}')"` on both |
| `busbw` single-digit GB/s | Collective fell back to TCP | `NCCL_DEBUG=INFO`, look for `NET/IB` not `NET/Socket` |
| ~1.6 GB/s (13 Gbps) | CX-7 firmware power throttle | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| Ray worker never joins | Head unreachable on the interconnect | `ping 192.168.100.10`; `journalctl -u ray` |
| `srun` hangs, no error mentioning munge | Munge keys differ between nodes | Re-run `make optional TAGS=slurm` with no `--limit` |
| Only one node has the model | The HF cache is per-node | `make models` on both, or `LIMIT=` each in turn |
| Job runs but is slow, one node idle | Ranks not both launched | Both boxes need the command; only `--node_rank` differs |

### Hangs before the first step, in detail

This is the failure worth knowing by heart, because it looks exactly like a
broken fabric and gets debugged as one.

NCCL's bootstrap listener on rank 0 binds an **ephemeral** port on the
management NIC — there is no fixed port to open. With `allow 22/tcp` plus a
default deny, the peer's bootstrap connection is dropped and every collective
hangs at init, on a cable you just seated correctly. `roles/remote` therefore
allows *all* traffic from each peer's management address
([why](../decisions.md#ufw-peers)):

```bash
sudo ufw status verbose | grep -A2 'gx10 peer node'   # want a rule per peer
make apply TAGS=remote                                # re-applies it
```

`cluster_peer_mgmt_addrs` is derived from inventory, so a node added to
`inventory.yml` without a re-run of `--tags remote` on the *others* is the way
this comes back.

## What is *not* shared between the nodes

There is no shared filesystem. Each box has its own HF cache, its own venv, its
own checkpoints. Provision both with the same playbook and they match, but a
model downloaded on node A is not visible on node B — pull it on both, or copy
it over the interconnect, which is what the `.cluster` name is for:

```bash
rsync -a ~/.cache/huggingface/hub/ poseidon.cluster:.cache/huggingface/hub/
```

What *is* checked across the nodes is version drift: `make verify` compares
driver, kernel and torch version between them, because ranks that disagree fail
in ways that read like a fabric problem.
