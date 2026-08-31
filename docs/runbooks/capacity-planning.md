# Runbook: will this model fit?

**What** — decide, before you download 150 GB, whether a model will run on this
cluster and at what context and concurrency.
**When** — before every `ws up` of something new, and every time you change
`--max-model-len` or `--max-num-seqs`.
**Risk** — none to answer. Real to get wrong: a late OOM on unified memory does
not fail politely, it takes the session with it.

## The one fact everything else follows from

**On GB10, host memory *is* GPU memory.** There is one pool of ~121 GB per node,
and it holds all of this at once:

- the model weights
- the KV cache
- the page cache (including the weights being read off NVMe)
- your shell, your editor, any desktop session (~1.2 GB for Xorg and
  gnome-shell)
- every other container on the box

`--gpu-memory-utilization 0.84` is not "84% of a framebuffer". It is 84% of the
same pool everything above lives in.

**`nvidia-smi` cannot answer memory questions here.** It reports `[N/A]`. The
authority is `MemAvailable`:

```bash
awk '/^MemAvailable:/ {printf "%d GB\n", $2/1048576}' /proc/meminfo
gx10-top                      # every node at once, live
ws check <workspace>          # reads MemAvailable, not nvidia-smi
```

## Numbers to plan against

| | Per node | Two nodes |
|---|---|---|
| Unified memory, total | ~121 GB | ~242 GB |
| Realistically available | **~110–114 GB** | ~220–228 GB |
| NVMe, stock node | ~1 TB (~515 GB free after the usual HF cache) | not pooled — each node has its own |

"Realistically available" is what is left with a normal login session and no
desktop. Reclaiming the desktop returns more than most tuning will:

```bash
sudo systemctl set-default multi-user.target
```

## The four-question method

### 1. Do the weights fit?

Take the **sum of the repo's shards**, not the parameter count. That is what has
to land on the disk and then in the pool.

| Format | Rough bytes/param |
|---|---|
| BF16/FP16 | 2 |
| FP8 | 1 |
| NVFP4 | ~0.5 |
| GGUF Q4 | ~0.5 |
| GGUF IQ2 | ~0.25 |
| GGUF IQ1 | ~0.2 |

Worked examples from this repo:

| Model | Format | Size | One node? |
|---|---|---|---|
| Qwen3.8-27B | NVFP4 | ~22.6 GB | comfortably |
| Qwen3.8-27B | GGUF Q4 | ~17–19 GB | comfortably |
| Nemotron-3-Super-120B | NVFP4 | 75 GB | fits — but see question 2 |
| Nemotron-3-Super-120B | BF16 | 231 GB | **no** — needs both nodes |
| DeepSeek-V4-Flash | FP8 | ~149 GiB | **no** — 75 GiB/node at TP=2 |
| DeepSeek-V4-Flash | GGUF UD-IQ2_M | 90.9 GB | yes, with ~21 GB left |
| DeepSeek-V4-Pro | GGUF IQ1_S | 337 GB | **no** — and no node count under 3 helps |

### 2. Is there enough left for KV cache?

**This is the question people skip, and it is the one that decides whether a
deployment is worth doing.**

```
KV budget  ≈  (available × gpu_memory_utilization)  −  weights
```

The 120B NVFP4 on one node:

```
110 GB available × 0.84  =  ~92 GB claimable
                          − 75 GB weights
                          = ~17 GB for KV        ← not worth doing
```

Across two nodes at TP=2:

```
~37 GB of weights per node, and the KV budget roughly triples
```

DeepSeek-V4-Flash at FP8 across two nodes:

| | |
|---|---|
| FP8 checkpoint | ~149 GiB |
| Split TP=2 | ~75 GiB per node |
| Claimable at `0.80` | ~97 GiB per node |
| **Left for KV** | **~22 GiB per node** |

That last line is why that workspace ships `--max-num-seqs 6` and
`--max-model-len 131072`. Both look absurdly timid next to a normal vLLM
deployment; both are the honest numbers for 22 GiB.

### 3. Context × concurrency — you buy one with the other

KV cache scales with **both**. `max_model_len × max_num_seqs` is the shape of
the budget you are spending.

| You want | Then |
|---|---|
| Long context | Fewer concurrent sequences |
| Many streams | Shorter context |
| Both | A smaller model, or more nodes |

**Raising `MAX_NUM_SEQS` without lowering `MAX_MODEL_LEN` does not buy
throughput — it buys preemption.** And preemption produces a
perfectly-normal-looking summary table, which is the entire argument for
watching a benchmark happen:
[`vllm-bench-serve`](../../workspaces/bench/vllm-bench-serve/README.md).

Two dtype levers, before you cut context:

- `--kv-cache-dtype fp8` — roughly halves KV against the default.
- Sparse-MLA KV dtypes (`nvfp4_ds_mla`, ~584 bytes/token) are what make 1M
  context on two GB10s arithmetically possible at all — and they are **not in
  upstream vLLM**. Asking for 1M without one does not fail at startup; it fails
  later, as preemption
  ([the trade](../decisions.md#dspark-1m-recipe)).

### 4. Does it fit the *disk*?

Separate question, and for large MoE models it is the binding one.

```bash
df -BG ~/.cache/huggingface
du -sh ~/.cache/huggingface/hub/* | sort -h | tail
```

`ws check` reads free space **at `HF_HOME`** — where the weights land — not
where you happen to be standing. A 1 TB NVMe sounds like plenty until a 500 GB
checkpoint meets a cache that already holds 133 GB, and a download that fills
the root filesystem takes the box down rather than just failing.

The `models` role guards this properly: it **subtracts the whole planned
download** from free space rather than checking a floor once
(`model_min_free_gb: 100`).

DeepSeek-V4-Pro is the case where the disk picks the quantisation: IQ1_S
(337 GB) fits a stock node with ~175 GB spare; every 2-bit build (569–587 GB)
does not fit at all.

## When more nodes is the answer — and when it is not

Adding nodes adds ~121 GB of pooled memory each **for tensor-parallel engines
that use the fabric** (vLLM). It does not help llama.cpp in the same way: its
multi-node path is RPC over TCP and does not use RoCE.

DeepSeek-V4-Pro, the worked case:

| Nodes | Unified | Smallest V4-Pro that fits in RAM |
|---|---|---|
| 2 | 242 GB | **none** |
| 3 | 363 GB | IQ1_S (337) — nothing left for KV |
| 4 | 484 GB | IQ1_S / IQ1_M — the first sane configuration |
| 5 | 605 GB | Q2_K (569), tight |

**The binding constraint there is node count, not quantisation.** Picking a
different quant does not move the line; adding nodes does
([the arithmetic](../decisions.md#deepseek-v4) ·
[how](add-a-node.md)).

## Things that do *not* work on this hardware, and look like they should

| Idea | Why it does nothing here |
|---|---|
| `--n-cpu-moe`, `-ot ".ffn_.*_exps.=CPU"` | They keep experts in system RAM when **VRAM** is scarce. Both sides of that split are the same 121 GB |
| `--no-mmap` "because unified memory is fast" | Worth testing on models that fit. **Fatal** on a 337 GB one — it means "read it all into memory" |
| Reading GPU memory from `nvidia-smi` | Reports `[N/A]`. Imported Grafana dashboards show blank tiles for the same reason |
| Adding swap to "make it fit" | On coherent memory swap is a **cliff, not a slope** |
| Running two serving workspaces at once | They do not co-exist at default settings. `kind: bench` and `kind: agent` do — they claim no GPU |

## Swap is the tripwire

```bash
gx10-top      # judges swap on GROWTH, not presence
```

A node holding swap from last week is not a problem. Swap **growing during a
run** means you are over the cliff — stop, do not tune. A benchmark taken while
swapping is not a measurement of the model.

## Quick reference: the ports and the memory each workspace wants

| Workspace | Nodes | Unified needed | Disk |
|---|---|---|---|
| [`llamacpp-qwen3.8-27b-gguf`](../../workspaces/inference/llamacpp-qwen3.8-27b-gguf/README.md) | 1 | ~24 GB | — |
| [`sglang-qwen3.8-27b-gguf`](../../workspaces/inference/sglang-qwen3.8-27b-gguf/README.md) | 1 | ~28 GB | — |
| [`vllm-qwen3.8-27b-nvfp4`](../../workspaces/inference/vllm-qwen3.8-27b-nvfp4/README.md) | 1 | ~40 GB | — |
| [`vllm-2node-tp2`](../../workspaces/inference/vllm-2node-tp2/README.md) | 2 | ~40 GB/node | — |
| [`ray-verl`](../../workspaces/rl/ray-verl/README.md) | 1 | ~90 GB | — |
| [`llamacpp-deepseek-v4-flash-gguf`](../../workspaces/inference/llamacpp-deepseek-v4-flash-gguf/README.md) | 1 | ~96 GB (108 with drafts) | ~110 GB |
| [`vllm-2node-deepseek-v4-flash`](../../workspaces/inference/vllm-2node-deepseek-v4-flash/README.md) | 2 | ~100 GB/node | ~170 GB |
| [`llamacpp-deepseek-v4-pro-gguf`](../../workspaces/inference/llamacpp-deepseek-v4-pro-gguf/README.md) | 1 | ~32 GB | **~360 GB** |
| [`vllm-2node-glm53-flash-exl3`](../../workspaces/inference/vllm-2node-glm53-flash-exl3/README.md) | 2 | **~106 GB/node** | ~180 GB/node |
| [`sglang-nemotron35-lightning-nvfp4`](../../workspaces/inference/sglang-nemotron35-lightning-nvfp4/README.md) | 1 | ~96 GB claimed | ~30 GB |
| [`vllm-nemotron35-lightning-nvfp4`](../../workspaces/inference/vllm-nemotron35-lightning-nvfp4/README.md) | 1 | ~98 GB claimed | ~30 GB |

`bench` and `agent` workspaces claim neither, by design.

### Two models' arithmetic does not follow the rules above

Both are **hybrids**, and a hybrid breaks the "KV scales with context ×
concurrency" model this page is built on. Mamba state is essentially
**length-independent**, so the pool is a large fixed floor plus a small slope.

[`vllm-2node-glm53-flash-exl3`](../../workspaces/inference/vllm-2node-glm53-flash-exl3/README.md)
— 12 MLA attention layers, 33 mamba. Two consequences, both counter-intuitive:

- **1M context fits in ~19 GB of KV.** Reported occupancy on the source kit:
  36k → 16%, 256k → ~25%, 300k → 26%. On a dense model those numbers would be
  nowhere near each other.
- **Lowering `--max-model-len` makes it worse, not better.** The logged pool is
  roughly concurrency × the cap; the floor underneath does not move. The usual
  "shrink the context to free KV" reflex shrinks the pool instead.

[`sglang-nemotron35-lightning-nvfp4`](../../workspaces/inference/sglang-nemotron35-lightning-nvfp4/README.md)
— 6 attention layers of 52, the rest 23 Mamba-2 and 23 MoE. It is the same
inversion taken further, and it is why a **1M window fits one node**:

- **~4.93M pool tokens in ~14.1 GiB**, because the target's K/V is FP8
  `e4m3fn` at ~3 KB/token and only six layers pay it. That budget is shared
  across every concurrent request — roughly 4–5 simultaneous *full* 1M
  contexts, or far more short ones.
- **The mamba cache is a flat 716 MiB** at any context length.
- **The speculative draft model's KV is a separate ~28.2 GiB bf16
  allocation** — larger than the weights, and the largest single item in the
  server. On this page's terms that is a fixed cost of speculative decoding
  that no context or concurrency setting touches. Turning the drafter off is
  the biggest single lever on the pool.

Do not generalise either way. Check whether the model is hybrid before applying
this page's arithmetic *or* these exceptions — and on a hybrid, check whether a
drafter is loaded before believing a KV figure.

### And one number that is never a constant

For both Nemotron workspaces the pool size, the KV size and
`max_running_requests` are **derived at startup** from a fraction of whatever
memory was free at that moment. The reference kit's "~4.93M tokens, 48
concurrent" is what *it* got. Read your own with
`workspaces/inference/sglang-nemotron35-lightning-nvfp4/report.sh` rather than
planning against someone else's boot.

## Failure modes

| Symptom | What it means | Fix |
|---|---|---|
| `ws check` fails on unified memory | Something is using the pool **right now** — not an Ansible problem | `gx10-top`, then `ws down` the other workspace |
| `ws check` fails on disk | The weights do not fit `HF_HOME` | Point `HF_HOME` at external NVMe, or [manage-models](manage-models.md) |
| Server boots, then dies under traffic | Speculative decoding allocates verify buffers on the **first real request** | Lower `GPU_MEMORY_UTILIZATION` by 0.02 |
| Throughput collapses at higher concurrency | Preemption — KV is full | Lower `MAX_MODEL_LEN` or `MAX_NUM_SEQS`, then re-measure |
| The box becomes unresponsive, then a process dies | Late OOM. The paging started long before the kill | This is what the pre-flight guards exist to prevent. Do not override them casually |
| A model server is killed with nothing in its log | `earlyoom` — it targets the largest-RSS process, which is **always** the server | `make verify` checks for this; `systemctl disable --now earlyoom` |
| Grafana GPU-memory tiles are blank | `nvidia-smi` reports no framebuffer here | Expected. [monitoring](monitoring.md) |

## Where the numbers in this runbook come from

The **hardware** figures (121 GB pool, ~1 TB NVMe, the perf-core layout, the
fabric measurements) are first-hand. The **model sizes** are read from each
repo's own file listing and labelled as such in the workspace that uses them.
The **serving** numbers — what a given `--max-num-seqs` actually sustains — are
`unverified`: no two-node serving run has been completed on this hardware.

See [provenance](../README.md#provenance) and
[hardware.md](../hardware.md).
