# llamacpp-deepseek-v4-pro-gguf

> DeepSeek-V4-Pro (1.57T total / 48B active) at 1-bit, **mmapped off the NVMe**.
> It runs. It runs at seconds per token, and that is the design, not a bug.

| | |
|---|---|
| Kind | `inference` |
| Engine | llama.cpp (host binary) |
| Nodes | **1** — and more nodes would not help; see below |
| Endpoint | `http://127.0.0.1:8892/v1` |
| Needs | ~32 GB unified · **~360 GB disk** · no Docker |
| Provenance | `unverified` — the performance figures below are *arithmetic*, not measurements |

## What

`llama-server` against `6block/DeepSeek-V4-Pro-0813-GGUF`, file
`DeepSeek-V4-Pro-0813-IQ1_S.gguf` — one 337 GB file, not a shard set — with an
8K context.

**The weights are never resident.** llama.cpp mmaps the file and the page cache
holds what it can. 121 GB of unified memory against 337 GB of weights is 2.8×
oversubscribed at the smallest published build.

## Why

Mostly so that "can this cluster run V4-Pro?" has a real answer instead of a
shrug. The honest answer is *yes, from disk, slowly* — and the arithmetic that
gets you there is worth writing down.

### The published ladder

Sizes are the sum of every shard, which is what has to land on the disk:

| Build | Size | Publisher | | Build | Size | Publisher |
|---|---|---|---|---|---|---|
| **IQ1_S** | **337 GB** | 6block ← default | | Q3_K_M | 652 GB | 6block |
| IQ1_M | 372 GB | 6block | | UD-Q4_K_XL | 850 GB | unsloth |
| Q2_K | 569 GB | DevQuasar | | NVFP4 | 913 GB | nvidia (vLLM, not llama.cpp) |
| Q2_K-XL | 574 GB | teamblobfish | | Q4_K_M | 951 GB | DevQuasar |
| Q2_K | 587 GB | 6block | | Q8_0 | 1672 GB | teamblobfish |
| IQ3_XXS | 620 GB | 6block | | native | 1650 GB | deepseek-ai |

### Why 1-bit, when you would never choose it elsewhere

**The disk picks the quant.** A stock 1 TB node has ~515 GB free once the usual
HF cache is accounted for. IQ1_S (337 GB) fits with ~175 GB to spare; every
2-bit build (569–587 GB) does not fit *at all*, so `ws check` would simply
refuse and that would be the whole answer.

Choosing 1-bit also halves the per-token disk traffic: ~48B active params at
~1.63 bits is **~10 GB touched per token** rather than ~17 GB, against an NVMe
that reads a few GB/s. That is the entire performance story, and it is
arithmetic — nobody here has run it.

### Why more nodes is the real fix, and why this repo cannot apply it

| Nodes | Unified | Smallest V4-Pro that fits in RAM |
|---|---|---|
| 2 | 242 GB | **none** |
| 3 | 363 GB | IQ1_S (337) — nothing left for KV |
| 4 | 484 GB | IQ1_S / IQ1_M — the first sane configuration |
| 5 | 605 GB | Q2_K (569), tight |

**The binding constraint is node count, not quantisation.** Picking a different
quant does not move that line; adding nodes does. But llama.cpp's multi-node
path is RPC over TCP, which does not use the RoCE fabric this cluster is built
around — so more nodes changes the *memory* answer without changing the "this
is not how you serve V4-Pro" answer
([the arithmetic](../../../docs/decisions.md#deepseek-v4)).

## When to use it — and when not

**Read this before the flags.** V4-Flash-0731 beats V4-Pro on every published
agentic benchmark, despite 13B active parameters against 48B. If output quality
matters more than running V4-Pro specifically, the answer is not a different
quant — it is
[`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md).

| Use it when | Use something else when |
|---|---|
| You want V4-Pro **as such**, and are content with seconds per token | You want the best answers this cluster can give → V4-Flash |
| You are measuring what NVMe-resident MoE inference actually costs | You want throughput of any kind |
| You have ~360 GB of free NVMe and time | You have a full disk — this is the check that decides usability |

The cost stated plainly: this is a **1-bit quantisation of a 1.65T model**.
Dynamic 1-bit builds of very large MoE models hold up better than the name
suggests, but nobody here has measured *this* one, and 1.63 bits/param is the
most aggressive trade in this repo.

## How

```bash
ws check llamacpp-deepseek-v4-pro-gguf     # this is mostly a disk check
ws up    llamacpp-deepseek-v4-pro-gguf
tail -f ~/.local/state/ws-llamacpp-ds-v4-pro.log
iostat -x 2                                # watch the DISK, not the GPU
ws down  llamacpp-deepseek-v4-pro-gguf
```

337 GB downloads before anything loads, and then it pages from NVMe for every
token.

### If the disk check fails

`up.sh` prints the options in the order they are worth trying:

1. **Run V4-Flash instead** — it wins on the benchmarks and this cluster can
   genuinely serve it.
2. **Attach external NVMe**: `HF_HOME=/mnt/big/hf` in `.env`.
3. **Reclaim space**: `du -sh $HOME/.cache/huggingface/hub/*` first, then
   [manage-models](../../../docs/runbooks/manage-models.md).

### Two flags that mislead in opposite directions

- **`--no-mmap` is absent, and that is the most important thing in this
  workspace.** `docs/hardware.md` records the community claim that `--no-mmap`
  is faster on unified memory, and for every *other* model here it is worth
  testing. Here it is fatal: it means "read 337 GB into memory". mmap is not a
  tuning choice in this recipe, it is the mechanism by which it runs at all.
- **`--n-cpu-moe` / `-ot ".ffn_.*_exps.=CPU"` do nothing.** Every x86 MoE guide
  recommends them; they keep experts in system RAM when VRAM is scarce. On GB10
  both sides of that split are the same 121 GB.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `ws check` fails on **disk**, not memory | The weights do not fit the NVMe | The three options above |
| Seconds per token | Working as designed | Nothing. This is NVMe-bound MoE inference |
| The box feels unresponsive during generation | Page cache thrash | Expected. Lower `CTX`, or accept it |
| You added `--no-mmap` and it OOMs instantly | See above | Remove it |
| Answers are noticeably weak | 1-bit is 1-bit | Run V4-Flash |

## Sources

- <https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro-0813>
- <https://huggingface.co/6block/DeepSeek-V4-Pro-0813-GGUF>
- <https://huggingface.co/teamblobfish/DeepSeek-V4-Pro-GGUF>
- <https://huggingface.co/unsloth/DeepSeek-V4-Pro-0813-GGUF>
- <https://huggingface.co/nvidia/DeepSeek-V4-Pro-NVFP4>
- <https://unsloth.ai/docs/models/deepseek-v4>

See also: [`workspace.yml`](workspace.yml) ·
[the V4 ladders](../../../docs/decisions.md#deepseek-v4) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
