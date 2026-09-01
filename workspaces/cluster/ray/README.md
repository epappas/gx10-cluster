# ray (workspace)

> An **ephemeral** containerised Ray cluster — head here, a worker on each peer —
> started for one experiment and thrown away. Not `roles/ray`.

| | |
|---|---|
| Kind | `cluster` |
| Engine | Ray |
| Nodes | **2** (head + one worker per reachable peer) |
| Endpoints | `http://127.0.0.1:8265` (dashboard) · `ray://127.0.0.1:10001` (client) |
| Needs | ~16 GB unified · Docker · 1 reachable peer |
| Provenance | **`verified`** — 2 nodes, SPREAD tasks on both, and a real GB10 in a `num_gpus=1` task |

## What

`up.sh` starts `rayproject/ray:latest-py312-aarch64` as a head on this box, then
SSHes to every peer in `/etc/gx10/interconnect.peers` and starts a worker there
pointed at the head. `down.sh` removes all of them.

There is **no compose file**, and that is not laziness: the worker half runs on
a *different machine*, which compose has no notion of. Inventing a swarm or k8s
dependency to express "two boxes" would be far more machinery than the thing it
manages.

## Why

### This is not `roles/ray`, and the difference is deliberate

| | `roles/ray` (Ansible) | `workspaces/cluster/ray` |
|---|---|---|
| Lifetime | a **standing** systemd service, survives reboots | started for an experiment, thrown away |
| Ray version | whatever the host was provisioned with | whatever the image pins |
| Installed by | `make optional TAGS=ray` | `ws up ray` |

**They will fight over ports. Pick one.**

For RL work the ephemeral one is usually right: verl pins a Ray version and you
want *that* one for the run, not whatever the host was provisioned with a month
ago.

### Why the head binds the management address

`HEAD_IP` defaults to the address on the default route, not loopback, because
**the head must be reachable by the workers**. That is the same control/data
split the rest of the repo uses: bootstrap and control traffic on the always-up
NIC, collectives on the cable
([why](../../../docs/decisions.md#nccl-socket-ifname)).

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| An experiment needs a Ray cluster for an afternoon | You want a queue with fair-share and accounting → [`slurm`](../slurm/README.md) |
| You are running [`ray-verl`](../../rl/ray-verl/README.md) and want its pinned Ray | You want Ray to survive reboots → `make optional TAGS=ray` |
| You want to throw the whole thing away cleanly | You only need to run one job on both boxes → `torchrun` already does that, with no orchestrator |

## How

```bash
ws check ray
ws up    ray
docker exec ws-ray-head ray status     # both nodes listed?
ws down  ray
```

Dashboard at <http://127.0.0.1:8265>. From your laptop:
`ssh -L 8265:localhost:8265 <node>`.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| `HEAD_IP` | the default-route address | Set only if that is not the address peers use |
| `RAY_PORT` | `6379` | |
| `DASH_PORT` | `8265` | |
| `NUM_GPUS` | `1` | One GB10 per node |
| `IMAGE` | `rayproject/ray:latest-py312-aarch64` | |
| `SHM_SIZE` | `16g` | |

### A peer that is off is skipped, not fatal

A one-node Ray cluster is a legitimate thing to want, so an unreachable peer is
reported and skipped rather than failing the run.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Worker never joins | Head bound to loopback, or the peer cannot reach it | Set `HEAD_IP` in `.env`; check `gx10-interconnect` |
| Port already in use | `roles/ray`'s systemd service is running | `sudo systemctl stop ray` — pick one, not both |
| `unreachable, skipped` for a peer | SSH failed | `ssh <peer> true`; see [run-distributed](../../../docs/runbooks/run-distributed.md) |
| Ray sees the nodes but jobs are slow | Object transfers on the wrong interface | `roles/ray` binds `--node-ip-address` to the interconnect; this workspace binds management. For big object transfers, prefer the role |
| Only one node has the weights | The HF cache is per node — nothing is shared | `make models` on both |
| `libcuda.so.1: cannot open shared object file` inside a `num_gpus=1` task, on a cluster whose `ray status` shows `2.0 GPU` | `rayproject/ray` is not a CUDA base image, so it does not set `NVIDIA_VISIBLE_DEVICES` and `--runtime nvidia` injects nothing — while `--num-gpus=1` advertises a GPU anyway | Fixed in `up.sh`. If you copy the `docker run` by hand, carry `-e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility` with it |
| `nvidia-smi: command not found` in a task | Expected — the image ships the **driver** (injected), not the CUDA toolkit | Bring your own runtime (`torch`, `jax`); `ray status` and `libcuda` are the things that must work |

## Sources

- <https://docs.ray.io/en/latest/ray-core/starting-ray.html>

See also: [`workspace.yml`](workspace.yml) ·
[why Ray exists twice](../../../docs/decisions.md#workspaces) ·
[run-distributed](../../../docs/runbooks/run-distributed.md)
