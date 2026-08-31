# vllm-nemotron35-lightning-nvfp4

> The same model, the same NVFP4 weights, the same DSpark drafter — on the
> engine where you can find out **why** a speculator is underperforming.

| | |
|---|---|
| Kind | `inference` |
| Engine | vLLM (container) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8895/v1` |
| Needs | ~98 GB unified claimed · ~30 GB disk · Docker |
| Provenance | `unverified` — written from the sources below, never run on this hardware |

## What

`vllm/vllm-openai:v0.27.1` serving
`nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` with the DSpark draft
model, OpenAI-compatible on :8895. A compose service, plus a thin `up.sh` that
computes the speculative flag — because the three published drafters take three
different JSON shapes and one of them is *no flag at all*, which a compose
`command:` cannot express.

## Why this exists next to the SGLang workspace

Both engines serve this checkpoint with DSpark. Neither is a fallback for the
other, and the split is about what you can **measure**:

| | [`sglang-…`](../sglang-nemotron35-lightning-nvfp4/README.md) | **this one** |
|---|---|---|
| Provenance of the flags | The published DGX Spark operating point, with a measured allocation table behind it | A published DGX Spark run, plus this repo's own vLLM conventions |
| Context | the full **1M** window | 256K by default — see below |
| Acceptance visibility | accept **length** only | `vllm:spec_decode_num_accepted_tokens_per_pos_total` — **the ladder** |
| Bench + gate workspaces | partial | all of them, natively |

The ladder is the reason. This is a model with **three** published drafters,
and a broken or mismatched draft path costs acceptance and **nothing else** —
the target still verifies every token, so the answers stay correct at half the
speed. Aggregate accept length tells you the drafter is doing *something*.
Only the per-position ladder separates *a weak drafter* from *a broken draft
mask*, and those need different fixes
([`spec-decode-accept`](../../bench/spec-decode-accept/README.md)).

So: **SGLang to run it the way its authors published it, vLLM to find out why
a speculator is underperforming**
([the record](../../../docs/decisions.md#nemotron35-lightning)).

## Two flags with no equivalent anywhere else in this repo

**`--moe-backend marlin`.** On GB10 the NVFP4 path is a **W4A16 Marlin**
kernel. Native FP4 tensor-core execution is GB200; the model card's own
hardware table lists DGX Spark under *Marlin*. This repo says "NVFP4 is the
format this hardware exists for" in several places — on `sm_121` that is a
claim about **memory footprint**, not about FP4 silicon, and this is the model
card that makes the distinction explicit.

**`--mamba-cache-mode align`** (with `--mamba-backend flashinfer`). The hybrid's
SSM state is a fixed allocation rather than a per-token one; `align` is what the
published DGX Spark run used.

And one spelling trap: the reasoning parser is **`nemotron_v3`** here and
**`nemotron_3`** in SGLang. Neither is a typo. Copying one into the other fails
at startup — which is the *good* outcome.

## Memory, and why 0.80 rather than NVIDIA's 0.91

| | |
|---|---|
| Weights (NVFP4) | 21.6 GB on disk, ~21.5 GB resident |
| DSpark draft | **1.3 GB on disk** — and it allocates its own KV |
| KV cache at `--gpu-memory-utilization 0.80` | ~75 GB |
| System memory left | ~12 GB |
| Engine init | ~2 minutes |
| Reported decode | 88–108 tok/s |
| Reported prefill | ~5,400 tok/s |

NVIDIA suggests 0.91. On unified memory that remaining ~12 GB is not spare
capacity — it holds the page cache, your shell and any desktop session — and
vLLM sizes its KV from NVML, **which reports no framebuffer on GB10**. It is
profiling against a pool the OS lives in. That is the same reason
`vllm_gpu_memory_utilization` defaults to 0.85 elsewhere in this repo, and why
0.80 is the default here.

**`MAX_MODEL_LEN` is 262144, not the checkpoint's 1,048,576.** The 1M window is
real — only 6 of 52 layers pay a growing K/V cost — but vLLM's pool arithmetic
is not SGLang's, and the published DGX Spark run reduced it for KV headroom. If
you want 1M on this model today, the [SGLang
sibling](../sglang-nemotron35-lightning-nvfp4/README.md) is the configuration
that was measured at it. Raise it here and **re-measure**; do not assume.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| A speculator is slower than published and you want the ladder | You want the 1M window as published → [SGLang sibling](../sglang-nemotron35-lightning-nvfp4/README.md) |
| You want to gate or benchmark it with this repo's tooling | You want the smallest footprint → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md) |
| You are comparing `dspark` / `dflash` / `mtp` / `none` empirically | The model does not fit → [two-node serving](../../../docs/runbooks/two-node-serving.md) |

## How

```bash
ws check vllm-nemotron35-lightning-nvfp4
ws up    vllm-nemotron35-lightning-nvfp4
ws logs  vllm-nemotron35-lightning-nvfp4 -f
curl -s localhost:8895/health && echo ready
ws down  vllm-nemotron35-lightning-nvfp4
```

Then the two questions `tok/s` cannot answer:

```bash
BASE_URL=http://127.0.0.1:8895/v1 ws up spec-decode-accept    # is the drafter working?
BASE_URL=http://127.0.0.1:8895/v1 ws up vllm-quality-gate     # is it answering correctly?
```

### Comparing the speculators, which is the point of this workspace

```bash
for m in none mtp dflash dspark; do
  ws down vllm-nemotron35-lightning-nvfp4
  SPEC_METHOD=$m ws up vllm-nemotron35-lightning-nvfp4
  BASE_URL=http://127.0.0.1:8895/v1 ws up spec-decode-accept --json /tmp/$m.json
done
```

Published ranking on a DGX Spark (code generation; single stream / 8 concurrent):

| `SPEC_METHOD` | conc. 1 | conc. 8 | vs. none |
|---|---:|---:|---|
| `none` | 81.3 tok/s | 241.7 tok/s | — |
| `dflash` | 95.5 | 268.6 | +17% / +11% |
| `mtp` | 111.4 | 302.3 | +37% / +25% |
| `dspark` | **124.2** | **354.6** | **+53% / +47%** |

Those are code-generation numbers with thinking **off** and a 64K window. That
matters: acceptance is a property of the **text**, so this ranking is not a
constant — it is why `spec-decode-accept` runs both a structured and a prose
class and refuses to draw a conclusion from one alone.

### `SPEC_TOKENS` is 3, not 7

Depth 3 measured better than depth 7 for single-stream use on this class of
box — a deeper ladder costs a longer draft pass for tokens the target then
rejects. This repo has been bitten before by inheriting a `k` from a model card
([the record](../../../docs/decisions.md#dspark-1m-recipe)). If you change it,
prove it with `spec-decode-accept` before and after.

## Sampling

NVIDIA's card says **temperature 1.0, top_p 0.95**; the DGX Spark recipe this
family was ported from says 0.6 / 0.95 / top_k 20 / repetition_penalty 1.08.
Use NVIDIA's as the default and the tighter set when you want less exploratory
output. Do not average them. Thinking is a request field:

```json
{"chat_template_kwargs": {"enable_thinking": true}}
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| 503 for minutes after start | ~2 minutes of engine init, then graph capture | Expected. `ws logs -f` |
| **Boots fine, dies on the first burst of traffic** | Speculative verify buffers are allocated on the **first real request**, not at boot | Lower `GPU_MEMORY_UTILIZATION` by 0.02. Every quick check passes before this happens |
| `--reasoning-parser nemotron_3: invalid choice` | SGLang's spelling on a vLLM server | `nemotron_v3` here |
| Loads as BF16, then OOMs | `MOE_BACKEND` changed away from `marlin` | On GB10 the NVFP4 path **is** Marlin |
| Acceptance near zero | Draft checkpoint does not match the target, or `SPEC_METHOD=mtp` with a `model` key | `ws up spec-decode-accept` — read the structured ladder |
| `vllm-bench-serve` dies minutes in with a 404 | `SERVED_NAME` is not a repo id, so no tokenizer loads from it | Set `TOKENIZER` to the HF id |
| Killed with nothing in the log | `earlyoom` targets the largest-RSS process, always the server | `make verify` checks for this; `systemctl disable --now earlyoom` |

## Sources

- [Nemotron 3.5 Lightning on DGX Spark](https://blog.kubesimplify.com/nemotron-3-5-lightning-on-dgx-spark) — the vLLM flag set, 0.80 vs 0.91, the ~75 GB KV figure
- [DSpark vs DFlash vs MTP on DGX Spark](https://dev.classmethod.jp/en/articles/nvidia-nemotron-3-5-lightning-dspark-dflash-mtp-dgx-spark/) — the measured ranking
- [Model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4) — architecture, the Marlin row, sampling
- [SGLang day-0 post](https://www.lmsys.org/blog/2026-08-11-nemotron-3-5-lightning) — the three speculators
- [vLLM speculative decoding](https://docs.vllm.ai/en/latest/features/spec_decode/)

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[`up.sh`](up.sh) · [`.env.example`](.env.example) ·
[the SGLang sibling](../sglang-nemotron35-lightning-nvfp4/README.md) ·
[the port record](../../../docs/decisions.md#nemotron35-lightning)
