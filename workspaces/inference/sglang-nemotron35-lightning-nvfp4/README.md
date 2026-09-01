# sglang-nemotron35-lightning-nvfp4

> NVIDIA Nemotron 3.5 Lightning 30B-A3B in **NVFP4**, with **DSpark**
> speculative decoding and a **1M-token context**, on **one** GB10.
> The workspace that proves "SGLang cannot serve NVFP4" was never true.

| | |
|---|---|
| Kind | `inference` |
| Engine | SGLang (container) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8894/v1` |
| Needs | ~96 GB unified claimed · ~30 GB disk · Docker |
| Provenance | **`verified`** — `./report.sh` on this box: 4,557,963 pool tokens, 13.04 GiB KV, **48** concurrent |

## What

One container running `lmsysorg/sglang:dev-nemotron3-5-lightning` against
`nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4`, with NVIDIA's own
**DSpark** draft model attached, served OpenAI-compatible on :8894. The host HF
cache is bind-mounted at `/hf`, so weights already on disk are reused.

A 30B-parameter MoE with ~3B active, a native **1,048,576-token** window, and
it fits one node with room to spare. That is not a quantisation trick — it is
the architecture, and the arithmetic is the whole design.

## Why this is the workspace that breaks the matrix

[The engine × quantisation matrix](../../README.md#the-engine--quantisation-matrix)
says **SGLang cannot run NVFP4**. That claim came from exactly one checkpoint —
`unsloth/Qwen3.8-27B-NVFP4`, whose quantised `lm_head` SGLang does not
support — and it got written down as a property of the *engine*.

It is a property of the *checkpoint*. NVIDIA's NVFP4 build of this model has
day-0 SGLang support, on this exact hardware, with a published DGX Spark
operating point. The matrix now reads **checkpoint-dependent**, which costs
nothing and stops the next person concluding SGLang is off the table here
([why](../../../docs/decisions.md#nemotron35-lightning)).

**On GB10 the NVFP4 path is Marlin, not native FP4.** The model card's own
hardware table gives native FP4 tensor-core execution to GB200 and lists DGX
Spark as **Marlin** — a W4A16 kernel. NVFP4 is still the right format here
(it is what fits and what is published), but the reason is footprint and
kernel maturity, not "Blackwell FP4 silicon". This repo has said "NVFP4 is the
format this hardware exists for" in several places; on `sm_121` that is a
claim about *memory*, and this is the model card that says so.

## The arithmetic, which is the whole design

| | On disk | Resident |
|---|---|---|
| Target checkpoint, NVFP4 | **21.6 GB** | ~21.0 GiB (with the draft) |
| DSpark draft | **1.3 GB** | — |
| Target KV cache, **FP8 `e4m3fn`**, ~3 KB/token | — | ~14.1 GiB → **~4.93M pool tokens** |
| **DSpark draft KV, `bf16`, a separate allocation** | — | **~28.2 GiB** |
| Mamba/SSM cache, `float16` | — | 716 MiB |
| Claimed at `--mem-fraction-static 0.78` of 121 GiB | — | ~94 GiB |
| Derived `max_running_requests` | — | **48** |
| Max input | — | ~1,048,570 tokens |

**Why a 30B model holds a 1M window in ~14 GiB.** Of its 52 layers, only **6**
are full attention — the rest are 23 Mamba-2 SSM and 23 MoE. Attention layers
pay a K/V cost that grows with sequence length; the mamba state is a fixed 716
MiB whatever you ask for. So the pool is a large fixed floor plus a small
per-token slope, and the ~4.93M-token budget covers roughly **4–5 simultaneous
full 1M contexts**, or far more short ones.

This is the same hybrid inversion
[`vllm-2node-glm53-flash-exl3`](../vllm-2node-glm53-flash-exl3/README.md)
documents, and it has the same counter-intuitive consequence: **lowering
`CONTEXT_LENGTH` to "free" KV does not work.** The floor does not move.

**A 1.3 GB draft model allocates a 28 GiB KV cache.** That is the largest
single allocation in the server — larger than the 30B target it drafts for —
and it is `bf16` while the target's KV is FP8. Two dtypes in one server is
correct here; the drafter has no FP8 KV path.

It also means `SPEC_METHOD=none` hands back ~28 GiB, *more than every weight in
the server*. If the pool is your binding constraint, **that** is the first
knob, not a lower `MEM_FRACTION_STATIC`.

**None of these numbers are constants.** They are startup-time outcomes of
`--mem-fraction-static` computed against whatever memory was free at boot. That
is what `./report.sh` is for.

## Three speculators, and they are not interchangeable

Measured on a DGX Spark, code-generation workload, single stream and 8
concurrent (the source ran these under vLLM; the ranking is a property of the
drafters, the absolute numbers are not portable between engines):

| `SPEC_METHOD` | conc. 1 | conc. 8 | vs. none | Costs |
|---|---:|---:|---|---|
| `none` | 81.3 tok/s | 241.7 tok/s | — | nothing. **The throughput-optimal choice** |
| `dflash` | 95.5 | 268.6 | +17% / +11% | a second checkpoint |
| `mtp` | 111.4 | 302.3 | +37% / +25% | **nothing extra** — the model's own heads |
| `dspark` | **124.2** | **354.6** | **+53% / +47%** | ~28 GiB of bf16 draft KV |

`dspark` is the default because it wins on **both** axes, which is unusual —
speculative decoding normally trades throughput for latency. `mtp` is the
interesting fallback: no second download, no extra KV allocation, and still
+37%.

**Block size is gamma, not the verify window.** SGLang's own help says the
verify window is `gamma + 1`, i.e. `--speculative-num-draft-tokens = gamma + 1`.
`DSPARK_BLOCK_SIZE=3` therefore drafts 3 and verifies 4. Omit it and SGLang
infers gamma from the draft checkpoint's own `block_size`, which is safer if a
future revision changes it.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want a 1M context on **one** node | You want 1M across two → [`vllm-2node-glm53-flash-exl3`](../vllm-2node-glm53-flash-exl3/README.md) |
| You want the fastest single-stream decode here | You want this model where **our** bench tooling is strongest → [`vllm-nemotron35-lightning-nvfp4`](../vllm-nemotron35-lightning-nvfp4/README.md) |
| You want SGLang's scheduler **and** NVFP4 | You want maximum aggregate throughput → same workspace, `SPEC_METHOD=none` |
| You are pointing an agent at a long-context reasoner | You need the smallest footprint → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md) |

**Two nodes buy nothing here.** The whole thing — weights, both KV caches,
mamba state — is ~64 GiB resident on one GB10. Tensor-parallel across the cable
would add a collective to every layer to solve a problem that does not exist.
Two nodes is the answer when a model does *not* fit
([capacity-planning](../../../docs/runbooks/capacity-planning.md)); this one
does.

## How

```bash
ws check sglang-nemotron35-lightning-nvfp4
ws up    sglang-nemotron35-lightning-nvfp4
docker logs -f ws-sglang-nemotron35          # not compose, so not `ws logs`
curl -s localhost:8894/health && echo ready
ws down  sglang-nemotron35-lightning-nvfp4
```

Pre-stage the weights without starting anything:

```bash
ws up sglang-nemotron35-lightning-nvfp4 --download-only
```

### Then find out what it actually allocated

```bash
./report.sh          # pool tokens, KV GiB, weights GiB, concurrency, accept length
```

Every capacity number for this model is an *outcome* of `MEM_FRACTION_STATIC`,
not a setting. `~4.93M tokens / 48 concurrent` is what the reference kit got;
what **your** box got depends on what was resident at boot. A desktop session
is the usual difference.

### Then prove it, because "up" is not "right" and "fast" is not "working"

```bash
BASE_URL=http://127.0.0.1:8894/v1 ws up spec-decode-accept    # is the drafter working?
BASE_URL=http://127.0.0.1:8894/v1 ws up vllm-quality-gate     # is it answering correctly?
```

**`--enable-metrics` is passed for exactly this reason.** SGLang serves no
`/metrics` without it, and
[`spec-decode-accept`](../../bench/spec-decode-accept/README.md) would then
report a perfectly healthy DSpark server as having *no speculative decoding* —
a wrong answer wearing the costume of a finding.

Two things degrade on this engine, and both degrade *out loud*:

| | On SGLang |
|---|---|
| `spec-decode-accept`'s **per-position ladder** | absent — SGLang publishes no per-position counter. The probe falls back to accept **length**, which still separates "the drafter is doing something" from "doing nothing", but cannot convict a broken draft mask |
| `vllm-quality-gate`'s **"the run was actually cold"** line | absent — it is derived from `vllm:prefix_cache_*`. Every *text* detector still works; only that reassurance is missing, and missing is not passing |

If you need either, serve the same checkpoint under the
[vLLM sibling](../vllm-nemotron35-lightning-nvfp4/README.md) — which is a large
part of why it exists.

## Sampling: two published sets that disagree

| Source | temperature | top_p | top_k | repetition_penalty |
|---|---|---|---|---|
| NVIDIA model card / NeMo cookbook | **1.0** | 0.95 | — | — |
| MiaAI-Lab DGX Spark recipe | **0.6** | 0.95 | 20 | 1.08 |

They are not reconcilable and both are cited here, so: **use NVIDIA's 1.0/0.95
as the default** — it is the model author's number and the one the published
evals were run at — and reach for 0.6/0.95/20/1.08 when you want tighter,
less exploratory output from a reasoning trace. Do not average them.

Thinking is a **request field**, not a server flag:

```json
{"chat_template_kwargs": {"enable_thinking": true}}
```

Reasoning traces come back as `reasoning_content` via `--reasoning-parser
nemotron_3`. Note the spelling: vLLM calls the same parser `nemotron_v3`. That
is not a typo in either place, and copying one into the other fails at startup.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| 503 for minutes after start | Weights loading, then CUDA-graph capture | Expected. `docker logs -f ws-sglang-nemotron35` |
| `spec-decode-accept` says "no speculative decoding" on a working server | `--enable-metrics` missing, or an image that renamed the counters | This workspace passes it. Confirm with `curl -s localhost:8894/metrics \| head` |
| OOM at startup | Something else holds the pool — 0.78 needs ~94 GiB free | `gx10-top`, `ws down` the other workspace |
| Pool is tiny but the server is up | `MEM_FRACTION_STATIC` too low for the weights + draft KV floor | `./report.sh`, then raise it — or `SPEC_METHOD=none` to free ~28 GiB |
| Killed under load with nothing in the log | `earlyoom` targets the largest-RSS process, which is always the server | `make verify` checks for this; `systemctl disable --now earlyoom` |
| `--reasoning-parser nemotron_v3: invalid choice` | vLLM's spelling on an SGLang server | `nemotron_3` here, `nemotron_v3` there |
| Long prompts are slow to first token | Prefill is chunked at 8192 tokens. TTFT grows with prompt size | Expected. Decode after prefill is fast |
| The image tag moved under you | `dev-` tags can be rebuilt in place | Pin `IMAGE` to a digest that worked |

## Other GPUs, if you copy this elsewhere

`--mem-fraction-static` is a fraction of *that* card's memory, so 0.78 does not
transfer. Starting points, then confirm with `./report.sh`:

| GPU | Memory | Start at | Note |
|---|---|---|---|
| DGX Spark / GB10 | 121 GiB unified | **0.78** | the reference configuration |
| RTX PRO 6000 Blackwell | 96 GiB | 0.60–0.70 | |
| RTX 6000 PRO / Ada | 48 GiB | 0.45–0.55 | `CUDA_GRAPH_MAX_BS_DECODE=2` |
| RTX 5090 | 32 GiB | 0.30–0.45 | **0.78 will OOM.** `CUDA_GRAPH_MAX_BS_DECODE=2`, and consider `SPEC_METHOD=none` — the draft KV alone is bigger than the card |

## Sources

- [MiaAI-Lab/Nemotron3.5-Lightning-DGX-Spark-RTX-5090-6000-PRO](https://github.com/MiaAI-Lab/Nemotron3.5-Lightning-DGX-Spark-RTX-5090-6000-PRO) — the DGX Spark operating point and the measured allocation table
- [SGLang day-0 post](https://www.lmsys.org/blog/2026-08-11-nemotron-3-5-lightning) — the three speculators, and W4A16 draft-head quantisation
- [NVIDIA-NeMo SGLang cookbook](https://github.com/NVIDIA-NeMo/Nemotron/blob/main/usage-cookbook/Nemotron-3.5-Lightning/sglang_cookbook.ipynb) — the per-hardware flag sets
- [Model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4) — architecture, the Marlin row, sampling, OpenMDW-1.1
- [DSpark draft](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DSpark)
- [SGLang production metrics](https://docs.sglang.io/references/production_metrics.html) — why `--enable-metrics` is not optional

See also: [`workspace.yml`](workspace.yml) · [`up.sh`](up.sh) ·
[`report.sh`](report.sh) · [`.env.example`](.env.example) ·
[the vLLM sibling](../vllm-nemotron35-lightning-nvfp4/README.md) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md) ·
[the port record](../../../docs/decisions.md#nemotron35-lightning)
