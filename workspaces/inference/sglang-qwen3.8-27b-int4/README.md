# sglang-qwen3.8-27b-int4

> Qwen3.8-27B on SGLang at **INT4 W4A16** — the one format of the three this
> box can actually serve. **13.2 tok/s** single-stream, **142 tok/s** at 16.

| | |
|---|---|
| Kind | `inference` |
| Engine | SGLang (container) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8900/v1` |
| Needs | ~40 GB unified · Docker |
| Provenance | `verified` — served and answered here. [Numbers](#measured-here) |

## What

`lmsysorg/sglang:latest` launching `sglang.launch_server` against
[`RedHatAI/Qwen3.8-27B-INT4`](https://huggingface.co/RedHatAI/Qwen3.8-27B-INT4)
— compressed-tensors W4A16, 19 GB on disk — 64K context,
`--mem-fraction-static 0.60`, served on :8900 (mapped from the container's
30000). Host HF cache bind-mounted at `/hf`.

## Measured here

```
  1 stream     117 tok    8.85s     13.2 tok/s
  4 streams    462 tok   10.05s     46.0 tok/s   (11.5 per stream)
 16 streams   1860 tok   13.10s    142.0 tok/s   ( 8.9 per stream)
```

`17*23` comes back `391`, so it is generating rather than merely listening.
Throughput scales ~10.8x from 1 to 16 streams while per-stream latency falls
only 33% — the shape you want from a batching server.

### What `vllm-quality-gate` says

```bash
BASE_URL=http://127.0.0.1:8900/v1 ws up vllm-quality-gate
```

**Before `--reasoning-parser`: 0/18.** Every request failed
`special-token-leak ['</think>']`, and the "prompt echo" failures were the same
cause — the model restates the prompt while reasoning, and that reasoning was
being served as the answer.

**After: 12/18.** The six that still fail are all the `json` task, all
`empty-with-1024-tokens-billed (reasoning never closed)`: this model reasons
past the gate's 1024-token ceiling on structured output and never reaches the
answer. That is a thinking-budget limit, not a serving fault — the prose and
code tasks pass at every concurrency. Raise `max_tokens`, or drive structured
output with thinking off.

## Three formats, and only one of them works

This workspace used to be `sglang-qwen3.8-27b-gguf` and used to be `blocked`.
Both of the formats it named were run on this hardware and both refused:

| Checkpoint | SGLang | Because |
|---|---|---|
| `unsloth/Qwen3.8-27B-NVFP4` | **no** | quantised `lm_head` — `Parameter lm_head.weight_scale not found in params_dict`, then every layer's `k_scale`/`v_scale`. Never reaches a served endpoint |
| `unsloth/Qwen3.8-27B-GGUF` | **no** | `ValueError: GGUF model with architecture qwen35 is not supported yet.` |
| `RedHatAI/Qwen3.8-27B-INT4` | **yes** | compressed-tensors W4A16, loaded through SGLang's own quantisation path; `lm_head` is not quantised |

**The GGUF refusal is `transformers`, not SGLang.** SGLang reads GGUF through
`transformers.modeling_gguf_pytorch_utils`, and the `GGUF_CONFIG_MAPPING` in
5.12.1 lists 25 architectures whose Qwen entries are `qwen2`, `qwen2_moe`,
`qwen3` and `qwen3_moe`. `qwen35` is not one of them, and no `transformers`
commit adds it. **That is not a stale image to bump** — which is why this
workspace changed format rather than waiting.

### The architecture was never the problem

That is the observation that made this fixable, and it was sitting in the NVFP4
error the whole time. Failing while matching parameter **names** means SGLang
had already constructed `Qwen3_5ForConditionalGeneration` — so any format whose
*weights* it can read was always going to serve.

BF16 confirms it directly: `Qwen/Qwen3.8-27B` loads and answers correctly, at
**4.3 tok/s**. That is not a misconfiguration to tune away — 54 GB of weights
against this box's ~273 GB/s of bandwidth is ~5 tok/s, and no flag changes
arithmetic. INT4 moves 19 GB instead and gets 3x the throughput for the same
answers.

### `--mem-fraction-static` is 0.60 because of the page cache

SGLang sizes its pool as a fraction of **total** memory and `cudaMalloc`s it in
one allocation. On unified memory the page cache shares that pool, and after
pulling ~50 GB of weights it is holding most of it:

```
free -g  ->  used 11   buff/cache 90   available 110
```

That cache is reclaimable, but one large `cudaMalloc` does not force the kernel
to reclaim it, so `0.80` (97 GB) dies at startup with
`torch.AcceleratorError: CUDA error: out of memory` **on a machine reporting
110 GB available**. 0.60 is 73 GB and fits comfortably. Raise it on a
freshly-booted box, and watch it with `gx10-top`.

## Why

SGLang's reason to exist here is its **scheduler and structured-output work** —
RadixAttention prefix reuse, constrained decoding, its own batching. Those are
real and they are what you would come for.

## When to use it — and when not

> **The format matters more than the engine here.** SGLang serves this model
> at INT4 and refuses it at NVFP4 and GGUF — see
> [three formats](#three-formats-and-only-one-of-them-works). Neither refusal
> is a fact about SGLang in general: NVIDIA's Nemotron 3.5 Lightning NVFP4
> loads there on day 0
> ([`sglang-nemotron35-lightning-nvfp4`](../sglang-nemotron35-lightning-nvfp4/README.md)),
> and the matrix that used to say otherwise was
> [corrected](../../../docs/decisions.md#nemotron35-lightning).

| Use it when | Use something else when |
|---|---|
| You want SGLang's scheduler or structured output | You want NVFP4 → [`vllm-qwen3.8-27b-nvfp4`](../vllm-qwen3.8-27b-nvfp4/README.md) |
| You are comparing engines on the same model | You want the smallest footprint → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md), the GGUF, no container |
| | You want the best throughput on this box → vLLM |

That trade is discoverable only by trying and failing, which is why it is
recorded in three places: here, in
[`workspace.yml`](workspace.yml), and in
[the engine × quant matrix](../../README.md).

## How

```bash
ws check sglang-qwen3.8-27b-int4
ws up    sglang-qwen3.8-27b-int4
ws logs  sglang-qwen3.8-27b-int4 -f
curl -s localhost:8900/health && echo ready
ws down  sglang-qwen3.8-27b-int4
```

### Tuning, in `.env`

| Variable | Default | Note |
|---|---|---|
| `MEM_FRACTION` | `0.60` | SGLang's equivalent of `--gpu-memory-utilization`. Same one pool — and see [why 0.60](#--mem-fraction-static-is-060-because-of-the-page-cache) |
| `CTX` | `65536` | |
| `MODEL` | `RedHatAI/Qwen3.8-27B-INT4` | Two other formats were tried; both refused |
| `PORT` | `8900` | Deliberately clear of 8888/8890/8891/8899 |
| `SGLANG_IMAGE` | `lmsysorg/sglang:latest` | See the caveat below |
| `SHM_SIZE` | `16g` | |

### The image caveat, stated plainly

**No `aarch64` tag is published as reliably as vLLM's**, so this pins
`:latest`. It pulled and ran here, but a future `:latest` may not: if the image
does not exist for `arm64` on the day you try, that is the first thing to
check — and it is easy to misread, because `ws check` reports the image as
"not pulled", which looks identical to "not yet downloaded".

```bash
docker manifest inspect lmsysorg/sglang:latest | grep -i arm64
```

### Sampling

Same Qwen3.8 table as everywhere else — thinking `1.0 / 0.95 / 20`, instruct
`0.7 / 0.80 / 20` with `presence_penalty 1.5`. These are documented parameter
sets, not preferences.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `GGUF model with architecture qwen35 is not supported yet` | `transformers`' GGUF reader does not know `qwen35`, at any version | Keep the INT4 default, or use llama.cpp for the GGUF |
| It refuses the NVFP4 checkpoint | Quantised `lm_head`, unsupported | Keep the INT4 default, or use vLLM for NVFP4 |
| `CUDA error: out of memory` with GBs "available" | Page cache holds the pool; one big `cudaMalloc` will not reclaim it | Lower `MEM_FRACTION` — [why](#--mem-fraction-static-is-060-because-of-the-page-cache) |
| ~4 tok/s | You pointed `MODEL` at the BF16 checkpoint | Expected: 54 GB at ~273 GB/s. Use INT4 |
| `no weights found` on a repo full of `.gguf` | `--model-path` named the repo, not a file | Name the file: `owner/repo/Some-Model.gguf` |
| `no matching manifest for linux/arm64` | No `aarch64` image published for that tag | Pin an older tag that has one, or use another engine |
| 503 for minutes after start | Weights still loading; `start_period` is 15m | `ws logs -f` |
| OOM, or swap growing | Another workload holds the pool | `ws down` the other; lower `MEM_FRACTION` |
| Killed under load with no error | `earlyoom` targets the largest-RSS process | `systemctl disable --now earlyoom` |

## Sources

- <https://huggingface.co/RedHatAI/Qwen3.8-27B-INT4>
- <https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4>
- <https://unsloth.ai/docs/models/qwen3.8>

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[runbook](../../../docs/runbooks/workspaces.md)
