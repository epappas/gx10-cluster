# vllm-2node-tp2

> One vLLM server, tensor-parallel across **both** GX10s over RoCE. The generic
> two-node recipe: for any model that does not fit one node with useful KV cache.

| | |
|---|---|
| Kind | `inference` |
| Engine | vLLM (container, both nodes) |
| Nodes | **2** — rank 0 serves, rank 1 is headless |
| Endpoint | `http://127.0.0.1:8888/v1` **on the rank-0 node** |
| Needs | ~40 GB unified *per node* · Docker · an ACTIVE RDMA port · 1 reachable peer |
| Provenance | `unverified` — written from the sources below, never run on this hardware |

## What

`up.sh` launches **both ranks from this one script**: rank 1 on the peer over
SSH first, then rank 0 locally. The two containers run the same image with the
same flags, meet at a rendezvous on the management network, and shard one model
across the two GPUs over the ConnectX-7 cable.

The default model is the 120B NVFP4 already cached on both nodes by the `models`
role. Only `MODEL_ARGS` lives in this workspace — the topology, rendezvous and
RDMA wiring live in [`workspaces/lib/twonode.sh`](../../lib/twonode.sh).

**Full mechanism, prerequisites and debugging:
[the two-node serving runbook](../../../docs/runbooks/two-node-serving.md).**

## Why

**A model that does not fit one GB10 with useful KV cache.** The 120B NVFP4 is
the worked example: 75 GB of weights against ~110 GB available leaves ~35 GB
for KV on one node, which is not worth doing. Split across two, each node holds
~37 GB and the KV budget roughly triples.

Ported from
[MiaAI-Lab's DeepSeek-v4-Flash 2× DGX Spark recipe](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark),
the only published two-node GB10 serving configuration we found. This workspace
deliberately takes only the **generic** half of it — container RDMA, the gloo
interface variables, the rendezvous split — and leaves the DeepSeek-specific
half to
[`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md)
([what was taken and what was not](../../../docs/decisions.md#two-node-vllm)).

### Both ranks come from one script, on purpose

The upstream recipe keeps a `.env` on each node and warns you to sync it before
restarting, with both ranks needing an identical image digest. That is a real
operational hazard with a **silent** failure mode: mismatched ranks hang at
init with no error. Generating both command lines from one place removes the
class of bug rather than documenting it.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| The model does not fit one node with useful KV | It fits → a single-node workspace is simpler and involves no fabric |
| You want a **generic** two-node recipe for your own model | You want DeepSeek-V4-Flash → [`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md), which carries the V4 flags this one refuses |
| Both nodes are free | The peer is busy, down or uncabled — `ws check` will say so |

## How

```bash
ws check vllm-2node-tp2      # checks THIS node only — see the caveat below
ws up    vllm-2node-tp2
docker logs -f ws-vllm-2node
curl -s localhost:8888/health && echo ready
ws down  vllm-2node-tp2      # stops both ranks
```

`ws logs` does not work here — this is not a compose workspace. Use
`docker logs ws-vllm-2node` on rank 0, and `ssh <peer> docker logs
ws-vllm-2node` for rank 1.

**`ws check` can only measure the node you typed on.** The peer needs the same
free memory and nothing here can confirm that. Run `ws check` on both, or watch
both with `gx10-top`.

### Confirm it is on RoCE and not TCP — always

This is the failure that looks like a slow model rather than a broken config:

```bash
docker logs ws-vllm-2node 2>&1 | grep -E 'NET/IB|NET/Socket'
```

`NET/IB` is ibverbs and covers RoCE — that is what you want. `NET/Socket` means
NCCL fell back to TCP and you are running at a fraction of the speed.

### Tuning, in `.env` — read on rank 0 only

There is no second `.env` to keep in step; that is the point.

| Variable | Default | Note |
|---|---|---|
| `MODEL` | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | Must be cached (or downloadable) on **both** nodes |
| `MAX_MODEL_LEN` | `131072` | Deliberate, not the model's ceiling — KV shares the pool |
| `GPU_MEMORY_UTILIZATION` | `0.80` | Per node |
| `MASTER_ADDR` / `PEER` | auto-detected from the default route and `/etc/gx10/interconnect.peers` | Set only if the peers reach each other over something else |
| `IB_HCA` | *unset, deliberately* | See below |
| `PORT` | `8888` | |

**Leave `IB_HCA` unset** unless a log shows the wrong device chosen. Measured on
this pair, NCCL discovers exactly the two ACTIVE ports and correctly skips the
two permanently-DOWN partitions:
`NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE`. Pinning a device
list by hand is how you silently end up on one rail after a cable moves.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Hangs at init, no error | Ranks never met — gloo picked `docker0` or the VPN, or the flags differ | The library sets `GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME`; if you hand-rolled it, set them |
| Hangs before the first step | ufw dropping NCCL's bootstrap (ephemeral ports) | `sudo ufw status verbose \| grep 'gx10 peer node'`, then `make apply TAGS=remote` |
| Works, but slow | Fell back to TCP — container missing `/dev/infiniband` or `memlock` | `grep -E 'NET/IB\|NET/Socket'` in the logs |
| `no peer found; set PEER in .env` | `/etc/gx10/interconnect.peers` is missing | `make apply TAGS=cluster` |
| Rank 1 never starts | SSH to the peer failed | `ssh <peer> true`; see [run-distributed](../../../docs/runbooks/run-distributed.md) |
| One node OOMs, the other is fine | The peer had less free memory | `ws check` on both; `gx10-top` |
| Only one node has the weights | The HF cache is **per node** — nothing is shared | `make models` on both, or `rsync` over `<peer>.cluster` |

Everything above, with the mechanism behind it, is in
[the two-node serving runbook](../../../docs/runbooks/two-node-serving.md).

## Sources

- <https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark>
- <https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-RTX-6000>

See also: [`workspace.yml`](workspace.yml) ·
[`lib/twonode.sh`](../../lib/twonode.sh) ·
[why the launcher is a library](../../../docs/decisions.md#twonode-lib)
