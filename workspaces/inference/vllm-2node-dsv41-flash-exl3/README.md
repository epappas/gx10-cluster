# `vllm-2node-dsv41-flash-exl3`

**DeepSeek-V4.1-Flash at EXL3 mul1 2.9 bpw, tensor-parallel across both Sparks.**

> **`provenance: unverified`.** The flags below were measured by their authors
> on this exact hardware — 2× GB10, `sm_121a`, CX7. They have **not** been run
> on odysseus and poseidon, and the reason is disk, not doubt. Read
> [What blocks it](#what-blocks-it) before you read anything else.

Ported from
[MiaAI-Lab/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks),
the fourth recipe from that lab this repo has mined. What was taken and what
was left is at [decisions.md#dsv41-flash-exl3](../../../docs/decisions.md#dsv41-flash-exl3).

## What it is

The largest model this repo has attempted. A 196 GiB EXL3 checkpoint split
TP=2 puts **~99.5 GiB of resident weights on each 121.7 GiB node** — which
leaves about four gigabytes of headroom once CUDA, NCCL, the KV pool and vLLM's
own processes are in. That is the whole character of this workspace: it is not
a throughput problem, it is a *fitting* problem, twice over — once in memory and
once on disk.

Upstream's published numbers, for scale:

| | |
|---|---|
| decode, one stream | 31.6 tok/s |
| decode, two streams | 42.5 tok/s aggregate |
| prefill, 8k | 970.8 tok/s, TTFT 8.46 s |
| prefill, 256k | 872.6 tok/s, TTFT 300.4 s |
| 601k context | 810 tok/s prefill, 22.3 tok/s decode |

**These are theirs, not ours.** Nothing in this repo has reproduced them. When
it does, they move into `workspace.yml` with a log behind them, and the
provenance flips — the standard
[`vllm-2node-glm53-flash-exl3`](../vllm-2node-glm53-flash-exl3/README.md) set
after publishing a number nobody could open.

## What blocks it

Two things, and only the first is interesting.

### 1. The worker cannot hold the checkpoint

Measured, 2026-09-13, from the Hub API and from `df`:

```
EXL3 checkpoint     196.2 GiB   39 shards
Engram source       189.1 GiB   shards 47+48 of a 475.3 GiB tree
packed Engram        ~96 GiB    per rank — layers 1 and 14, ~48 GiB each

steady state, rank 0   196.2 + 96 + ~30 (image)  =  ~322 GiB
steady state, rank 1           96 + ~30 (image)  =  ~126 GiB

odysseus   349 GiB free   (after removing an 80.4 GB re-downloadable checkpoint)
poseidon   127 GiB free   + 43.0 reclaimable + 71 in an RL archive
```

**`docker system prune` is not the 42.6 GiB `docker system df` advertises.** Of
the 102 GB of unused images on odysseus, **86 GB were built on this box and
pushed nowhere** — `docker pull` cannot bring them back. `gx10-storage`
classifies them correctly and its auto tier frees 1.3 GB, which is
[the point of that tier](../../../docs/runbooks/manage-storage.md#local-images).

poseidon's ceiling is **241 GiB** against the **322 GiB** a full replica needs.
So the plan this repo would normally reach for — rsync the weights over the
cable, the idiom
[`stage-weights.sh`](../vllm-2node-glm53-flash-exl3/stage-weights.sh)
established at a measured 487–534 MB/s — **does not apply**. There is no second
copy to ship.

That makes upstream's `WEIGHT_SYNC=nfs` a **prerequisite** rather than a
preference: rank 1 reads the checkpoint from rank 0 over the cable and stores
none of it. An NFS export is machine state and Ansible owns machine state, so
that half is [`roles/nfs`](../../../roles/README.md) — opt-in, behind the
`never` tag:

```bash
make optional TAGS=nfs -e nfs_export_path=$HOME/.cache/dsv41-exl3/model
```

Nothing in this workspace creates that mount. It *checks* for it and refuses —
a workspace that mounts a filesystem is precisely the coupling
[the two halves](../../README.md#why-this-is-separate-from-roles) exist to
prevent.

### 2. Rank 0 fits, but only in the right order

The naive order — download both trees, then pack — peaks at 385 GiB and fails
on a node with 274 GiB free. [`stage-weights.sh`](stage-weights.sh) reorders it
so the 189 GiB Engram source is **deleted before** the checkpoint is fetched:

```
1 engram source  189 GiB      build input, not a runtime file
2 pack rank 1     96 GiB      peak 285 GiB
3 ship rank 1 to the peer, delete locally
4 pack rank 0     96 GiB
5 delete engram source        −189 GiB
6 checkpoint     196 GiB      peak 292 GiB
```

`./stage-weights.sh --plan` prints that table against the node's actual `df`
rather than against these numbers, which will age.

## Run it

```bash
./stage-weights.sh --plan     # what it needs, against real free space
./stage-weights.sh --all      # the ordered stage, with two confirmations

# once the checkpoint is staged, export it to the peer (Ansible's half)
make -C ../../.. optional TAGS=nfs -e nfs_export_path=$HOME/.cache/dsv41-exl3/model

ws up vllm-2node-dsv41-flash-exl3
ws logs vllm-2node-dsv41-flash-exl3 -f
```

`up.sh` refuses to launch if the peer cannot read the checkpoint or is missing
its packed shard — a check that costs a second, against a worker init error
seven minutes into a load that says nothing about a missing directory.

## Three defaults that are ours, not upstream's

| | upstream | here | why |
|---|---|---|---|
| `--gpu-memory-utilization` | 0.88 | **0.86** | With `--kv-cache-memory-bytes` pinned this is a startup *assertion*, not a budget: `MemAvailable` at init must clear `util × 121.69 GiB`. 0.88 asks for 107.1 GiB. GLM-5.3 measured **0.87 being refused on these nodes at 104.87 GiB free** |
| `--max-model-len` | 600000 | **131072** | 600k is their *validated* profile, reached by raising one knob at a time against 4 GiB of headroom. 128k is their own stated "first clean boot" target, and this repo does not ship a ceiling it has not climbed to |
| `--max-num-batched-tokens` | 1024 | **2048** | Their 1024 belongs *with* 600k — the indexer's activation peak grows with chunk × context. At 128k the chunk can be larger. Raising context without lowering this moves two things at once |

## Things that would have been silent

- **Their CX7 interface pins would hang NCCL here.** `HEAD_CX7_IF=enp1s0f1np1`
  is `DOWN`/`NO-CARRIER` on **both** our nodes; the cabled ports are
  `enp1s0f0np0` and `enP2p1s0f0np0`. `lib/twonode.sh` discovers both rails
  rather than naming one, which is the same disagreement
  [#two-node-vllm](../../../docs/decisions.md#two-node-vllm) already records.
- **`MODEL` must be a path, not a repo id** — the overlay's loader joins the
  string with a filename instead of resolving through the Hub, and fails on a
  file that is present both locally and on the Hub. The same trap GLM-5.3 paid
  for; `stage-weights.sh` writes the path into `.env` so it is paid once.
- **`--block-size 64`, and only 32 or 64 are valid.** The SM12x DeepGEMM paged
  indexer takes 32 or 64 states per block; vLLM's default of 128 dies on the
  first decode of the ratio-1 indexer layers. Architecture, not tuning.
- **`--quantization exl3`, never `marlin`.** The wrong method does not fall
  back — it loads the routed experts as BF16 and the model stops fitting on two
  nodes.
- **Do not copy GLM-5.3's `--kv-cache-dtype fp8`.** That is a NoPE-MLA envelope
  for a different model. V4.1's native KV is CSA2 FP4 at ~890 B/token.
- **DSpark is a workload choice, not a win.** Upstream measured k=3 at 28 tok/s
  against 23 for one stream — and `none` at 54 aggregate against 42 for four.
  The crossover is inside this workspace's supported concurrency.

## Then ask the questions a tok/s number cannot answer

```bash
BASE_URL=http://127.0.0.1:8897/v1 ws up spec-decode-accept   # is DSpark working?
BASE_URL=http://127.0.0.1:8897/v1 ws up vllm-quality-gate    # is it correct?
BASE_URL=http://127.0.0.1:8897/v1 ws up vllm-prefill-ladder --chunk-tokens 2048
```
