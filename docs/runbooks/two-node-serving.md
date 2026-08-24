# Runbook: serve one model across both nodes

**What** — run a single vLLM server whose weights are tensor-parallel across
**both** GX10s, over the RoCE fabric, from one command on one node.
**When** — the model does not fit one node with useful KV cache.
**Risk** — low to the machines. High to your afternoon: every one of the three
things that can be wrong here **fails quietly**, not loudly.

```bash
ws up   vllm-2node-deepseek-v4-flash    # or vllm-2node-tp2
docker logs -f ws-vllm-ds-v4-flash
docker logs ws-vllm-ds-v4-flash 2>&1 | grep -E 'NET/IB|NET/Socket'   # ALWAYS
ws down vllm-2node-deepseek-v4-flash
```

## Should you be here at all?

Two-node serving is strictly more machinery than one node. It earns that only
when the model does not fit.

| | Use |
|---|---|
| Model fits one node **with useful KV cache** | A single-node workspace. No fabric involved, no peer to keep alive |
| Model does not fit, or KV is starved | Two nodes |

The 120B NVFP4 is the worked example: 75 GB of weights against ~110 GB
available leaves ~35 GB for KV on one node, which is not worth doing. Split
across two, each node holds ~37 GB and the KV budget roughly **triples**.

Do the arithmetic before you start:
[capacity-planning](capacity-planning.md).

## The two workspaces, and why there are two

| Workspace | It is |
|---|---|
| [`vllm-2node-tp2`](../../workspaces/inference/vllm-2node-tp2/README.md) | The **generic** recipe. Topology and RDMA only — bring your own model |
| [`vllm-2node-deepseek-v4-flash`](../../workspaces/inference/vllm-2node-deepseek-v4-flash/README.md) | The **DeepSeek-V4** recipe. Adds the v4 tokenizer mode, parsers, FP4 indexer cache and DSpark drafts |

They share one launcher, `workspaces/lib/twonode.sh`, and nothing else. The test
of that split: **anything whose value depends on the model stays in the
workspace; anything whose value depends on the topology lives in the library**
([why](../decisions.md#twonode-lib)).

## How it actually works

```
        YOU TYPE THIS                          NOTHING IS TYPED HERE
   ┌─────────────────────────┐            ┌─────────────────────────┐
   │  rank 0   (this node)   │            │  rank 1   (the peer)    │
   │  serves :8890           │            │  --headless             │
   │                         │            │                         │
   │  docker run …           │            │  docker run …           │
   └───────────┬─────────────┘            └───────────┬─────────────┘
               │                                      │
               │  ── control: rendezvous, NCCL bootstrap, ssh ──
               │     over the MANAGEMENT NIC, MASTER_ADDR:25000
               │                                      │
               │  ══ data: the collectives ═══════════│
               │     RoCE v2 over the ConnectX-7, chosen by NCCL
               │     independently through ibverbs
```

Five things follow from that picture, and each is a step below.

1. `up.sh` runs on **one** node and launches **both** ranks — rank 1 over SSH
   first, then rank 0 locally. Rank 0 owns the rendezvous; a worker that
   arrives late is fine, a rank 0 with nobody to meet blocks until timeout.
2. Both ranks get the **same image and the same flags**, generated from one
   place. There is no second `.env` to keep in step.
3. Rank 0 gets `--host 0.0.0.0 --port $PORT`; rank 1 gets `--headless`. **The
   deployment has exactly one endpoint.**
4. The **rendezvous** runs on the management address. The **data path** is RoCE,
   selected separately by NCCL. Getting this backwards looks like tuning and
   costs you the interconnect
   ([why](../decisions.md#nccl-socket-ifname)).
5. `ws down` removes the container on rank 0 **and** on every peer.

## Before you start

| Requirement | Check | If it fails |
|---|---|---|
| Both nodes provisioned identically | `make verify` | It compares driver, kernel and torch **across** nodes |
| The cable is up | `gx10-interconnect` | [connect-cluster](connect-cluster.md) |
| SSH to the peer works without a password | `ssh <peer> true` | [run-distributed](run-distributed.md) |
| ufw trusts the peer wholesale | `sudo ufw status verbose \| grep 'gx10 peer node'` | `make apply TAGS=remote` — see below |
| The peer list exists | `cat /etc/gx10/interconnect.peers` | `make apply TAGS=cluster` |
| **Both** nodes have the weights | `ws check <name>` **on each node** | The HF cache is per node. Nothing is shared |
| Both nodes have the memory | `ws check` on each, or `gx10-top` | `ws check` can only measure the node you typed on |

**The ufw one is the failure worth knowing by heart**, because it looks exactly
like a broken fabric and gets debugged as one. NCCL's bootstrap listener on
rank 0 binds an **ephemeral** port on the management NIC — there is no fixed
port to open. With `allow 22/tcp` plus a default deny, the peer's bootstrap
connection is dropped and every collective hangs at init, on a cable you just
seated correctly. `roles/remote` therefore allows *all* traffic from each peer's
management address ([why](../decisions.md#ufw-peers)).

## Steps

### 1. Check both nodes

```bash
ws check vllm-2node-deepseek-v4-flash
ssh <peer> 'cd ~/gx10-cluster && ./workspaces/ws check vllm-2node-deepseek-v4-flash'
```

Expected: every line green on **both**. `ws check` deliberately does not reach
across to the peer — a check that silently half-ran is worse than one that says
what it covered.

### 2. Start it

```bash
ws up vllm-2node-deepseek-v4-flash
```

Expected, immediately:

```
model   deepseek-ai/DeepSeek-V4-Flash-DSpark  TP=2  (284B total / 13B active)
rank 0  odysseus  192.168.1.70   (serves :8890)
rank 1  poseidon  192.168.1.71   (headless)
image   vllm/vllm-openai:nightly-aarch64
master  192.168.1.70:25000
```

### 3. Wait, and know how long

**Tens of minutes**, not seconds. ~149 GiB of weights split two ways, and off a
cold cache the first run also *downloads* them.

```bash
docker logs -f ws-vllm-ds-v4-flash
curl -s localhost:8890/health && echo ready
```

### 4. Confirm the transport — do not skip this

```bash
docker logs ws-vllm-ds-v4-flash 2>&1 | grep -E 'NET/IB|NET/Socket'
```

| You see | Means |
|---|---|
| `NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE` | **Correct.** `NET/IB` is NCCL's name for ibverbs and covers RoCE — it is *not* evidence of InfiniBand |
| `NET/Socket` | **TCP fallback.** It works, at a fraction of the speed. This is the failure that reads as "a slow model" |

Only one device listed instead of two means one partition is addressed — you are
at roughly half the fabric.

### 5. Confirm it is right, not just fast

```bash
BASE_URL=http://127.0.0.1:8890/v1 ws up vllm-quality-gate
ws up vllm-bench-serve       # and read the NODES pane, not just the table
```

The bench view samples **every** node, because rank 1 swapping invalidates a run
exactly as much as rank 0 swapping does.

### 6. Stop it

```bash
ws down vllm-2node-deepseek-v4-flash
```

Expected:

```
rank 0 stopped
rank 1 on poseidon stopped
```

A peer reported as "unreachable or not running" after a successful start means
the container is still there. Check it: `ssh <peer> docker ps`.

## The three things that fail quietly

These are the whole reason this runbook exists. **None of them produces an
error message that names the cause.**

### 1. RDMA is not visible inside the container

```
--device /dev/infiniband:/dev/infiniband
--ulimit memlock=-1
```

Without the device nodes, ibverbs finds no adapter **inside the container** and
NCCL falls back to TCP. It still works — so it looks like a disappointing model,
not a misconfiguration. Without unlimited memlock, queue-pair registration fails
outright.

**Symptom:** everything runs, throughput is a fraction of what it should be.
**Detection:** step 4 above.

### 2. gloo does not read `NCCL_SOCKET_IFNAME`

```
-e NCCL_SOCKET_IFNAME=$MGMT_IFACE
-e TP_SOCKET_IFNAME=$MGMT_IFACE
-e GLOO_SOCKET_IFNAME=$MGMT_IFACE
```

vLLM's distributed init is `torch.distributed`, and **gloo has its own
variable**. Unset, it picks an interface by its own heuristic — on this box that
can be `docker0` or the VPN — and the ranks never meet.

**Symptom:** hangs at init, forever, with no error.
**Detection:** nothing in the log names it. This is why the library sets it.

### 3. Mismatched ranks

Different image digests, different flags, a `.env` synced on one node and not
the other: **mismatched ranks hang at init rather than erroring.**

The upstream recipe this was ported from keeps a `.env` per node and warns you
to sync it. Both workspaces here launch both ranks from one script, so the class
of bug does not exist rather than being documented
([what was ported and what was not](../decisions.md#two-node-vllm)).

**If you hand-roll two-node serving, this is the one to get right.**

## Two more that are set correctly and worth knowing

- **`NCCL_IB_ROCE_VERSION_NUM=2` and `NCCL_IB_ADDR_FAMILY=AF_INET`.** The GID
  table on this card carries **both** RoCE v1 and v2 entries for every port, and
  only v2 is routable.
- **`NCCL_NVLS_ENABLE=0`.** There is no NVLink between two Sparks, so NVLS has
  nothing to accelerate.

## `NCCL_IB_HCA` is deliberately unset

The upstream recipes pin the RDMA device list. This repo does not, and that is a
**measured** disagreement rather than a preference: with it unset, NCCL here
discovered exactly the two ACTIVE devices and used both, while correctly
ignoring the two permanently-DOWN partitions.

Pinning a device list by hand is how you silently end up on one rail after a
cable moves. Set `IB_HCA=` in the workspace's `.env` **only** if a log actually
shows the wrong device chosen.

## Overrides, and where they live

Everything below goes in the workspace's `.env`, **on rank 0 only**.

| Variable | Default | When to set it |
|---|---|---|
| `PEER` | first entry in `/etc/gx10/interconnect.peers` | More than one peer, or a different one |
| `MASTER_ADDR` | this node's address on the default route | The peers reach each other over something else |
| `MASTER_PORT` | `25000` | Collision |
| `MGMT_IFACE` | the default-route interface | Same |
| `IB_HCA` | *unset* | Only when a log shows the wrong device |
| `IMAGE` | `vllm/vllm-openai:nightly-aarch64` | Pinning a digest, or taking the fork path |
| `SHM_SIZE` | `32g` | |
| `EXTRA_ENV` | *unset* | A bash array of `-e VAR=value`, handed to **both** ranks |

## Running it by hand, without `ws`

Every recipe in this repo is meant to be readable and copyable. Two-node
serving is the **one** exception to "standalone", because the wiring lives in
`workspaces/lib/twonode.sh` — but the library is still plain bash you can read
top to bottom, and a workspace's `up.sh` is just `MODEL_ARGS` plus
`twonode_up`.

```bash
cd workspaces/inference/vllm-2node-tp2
bash -x ./up.sh          # see exactly the two docker command lines it generates
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Hangs at init, no error, forever | Ranks never met — gloo on the wrong interface | `GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME`. Set by the library |
| Hangs before the first step | **ufw dropping NCCL's ephemeral bootstrap port** | `sudo ufw status verbose \| grep 'gx10 peer node'`; `make apply TAGS=remote` |
| Hangs, and `ufw` looks fine | `mgmt_iface` down, or not reachable both ways | `ip -br link show "$(ip route show default \| awk '{print $5; exit}')"` on both |
| Runs, but slow | TCP fallback — no `/dev/infiniband` or no memlock | Step 4. Then check the container flags |
| Half the expected fabric | One partition addressed | `gx10-interconnect`; [connect-cluster](connect-cluster.md#reading-the-result) |
| ~1.6 GB/s (13 Gbps) | CX-7 firmware power throttle | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| `no peer found; set PEER in .env` | `/etc/gx10/interconnect.peers` missing | `make apply TAGS=cluster` |
| `cannot determine MASTER_ADDR` | No default route, or an odd interface | Set `MASTER_ADDR` in `.env` |
| Rank 1 never starts | SSH to the peer failed | `ssh <peer> true` |
| One node OOMs, the other is fine | The peer had less free memory | `ws check` on **both** |
| Only one node has the weights | The HF cache is per node | `make models` on both, or `rsync -a ~/.cache/huggingface/hub/ <peer>.cluster:.cache/huggingface/hub/` |
| Boots clean, dies under real traffic | Speculative verify buffers allocate on the **first real request** | Lower `GPU_MEMORY_UTILIZATION` — `0.80 → 0.78` |
| Correct output at half the speed | Draft path silently broken — costs acceptance and nothing else | Watch acceptance in `ws up vllm-bench-serve` |
| "The model got slow" at long context | Preemption — 1M context asked for on an `fp8` KV | Lower `MAX_MODEL_LEN` |
| Killed under load, nothing in the log | `earlyoom` targets the largest-RSS process, always the server | `make verify` checks this; `systemctl disable --now earlyoom` |
| `ws logs` says there is no compose file | Correct — these are not compose workspaces | `docker logs ws-vllm-2node`, and `ssh <peer> docker logs …` |

## What is *not* shared between the nodes

There is **no shared filesystem**. Each box has its own HF cache, its own venv,
its own checkpoints. Provision both with the same playbook and they match, but a
model downloaded on node A is not visible on node B.

```bash
rsync -a ~/.cache/huggingface/hub/ poseidon.cluster:.cache/huggingface/hub/
```

`<node>.cluster` is the interconnect name — use it when you explicitly want the
200G path for a bulk copy ([why the names split](../decisions.md#hosts-split)).

## Adding a third and fourth node

Nothing above is two-specific except `--tensor-parallel-size 2` and `--nnodes 2`
in the launcher. The peer list, the bench view and `ws check` already read
`/etc/gx10/interconnect.peers` and handle N.

See [add-a-node](add-a-node.md) — and note that for DeepSeek-V4-Pro, node count
is the *only* thing that moves the memory line
([the arithmetic](../decisions.md#deepseek-v4)).

## Provenance

Both two-node workspaces are `unverified`: written from the vendor docs and the
published 2× DGX Spark recipes cited in their manifests, not from a completed
run on this hardware. The **fabric** measurements in this runbook are
first-hand — 22.7 GB/s busbw, the NCCL device discovery, the MTU results — the
**serving** ones are not. See [provenance](../README.md#provenance).
