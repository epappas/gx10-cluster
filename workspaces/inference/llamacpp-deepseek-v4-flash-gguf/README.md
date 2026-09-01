# llamacpp-deepseek-v4-flash-gguf

> DeepSeek-V4-Flash (284B total / 13B active) on **one** node at `UD-IQ2_M`,
> with just enough headroom left for the DSpark draft model.

| | |
|---|---|
| Kind | `inference` |
| Engine | llama.cpp (host binary) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8891/v1` |
| Needs | ~96 GB unified (108 with drafts) · ~110 GB disk · no Docker |
| Provenance | **`verified`** — 90.9 GB loads, ~15 tok/s, 96 GB resident, **no swap**. [One quality finding](#what-2-bit-costs) |

## What

`llama-server` against `unsloth/DeepSeek-V4-Flash-0731-GGUF`, quantised to
`UD-IQ2_M` (90.9 GB), 32K context, every layer offloaded. Backgrounded with a
pid in `.pid` and a log at `~/.local/state/ws-llamacpp-ds-v4-flash.log`.

This is the **compromised** way to run V4-Flash. The un-compromised way is
[`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md):
the FP8 checkpoint at ~149 GiB split across both nodes, at full precision, with
real KV cache.

## Why

Because sometimes you have one node — the peer is down, uncabled, or busy — and
the question is what fits on it.

**The quant is chosen against the memory budget, not against the model.** From
unsloth's own file listing, with what each leaves on a ~112 GB budget:

| Build | Size | Left over | | Build | Size |
|---|---|---|---|---|---|
| UD-IQ1_S | 82.5 GB | ~29 GB | | UD-IQ3_S | 116.1 GB | does not fit |
| UD-IQ1_M | 86.9 GB | ~25 GB | | UD-Q3_K_M | 128.1 GB | does not fit |
| UD-IQ2_XXS | 90.9 GB | ~21 GB | | UD-Q3_K_XL | 128.2 GB | does not fit |
| **UD-IQ2_M** | **90.9 GB** | **~21 GB** ← default | | UD-IQ4_NL | 136.7 GB | does not fit |
| UD-Q2_K_XL | 96.8 GB | ~15 GB | | UD-Q4_K_XL | 155.1 GB | does not fit |
| UD-IQ3_XXS | 104.2 GB | ~8 GB | | UD-Q8_K_XL | 161.9 GB | does not fit |

`UD-IQ2_M` is the default **for what it leaves behind**, not for what it costs.
~21 GB of headroom holds the DSpark draft model (10.9 GB) *and* a desktop
session; `UD-IQ3_XXS` leaves ~8 GB, which is enough for neither.

**Speculative decoding is worth more than one rung of quantisation on a
memory-bound box.** 90.9 + 10.9 = 101.8 GB still fits, and DSpark drafts
several tokens per forward pass. That is the entire argument for stopping the
ladder here.

`UD-IQ2_M` and `UD-IQ2_XXS` are the same size to a tenth of a gigabyte, so
`IQ2_M` is strictly the better pick between those two.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You have **one** node and want V4-Flash anyway | Both nodes are up → [`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md), which is better in every way |
| You want to try DSpark speculative decoding cheaply | You want V4-**Pro** → [`llamacpp-deepseek-v4-pro-gguf`](../llamacpp-deepseek-v4-pro-gguf/README.md), and read its warning first |
| You are fine with 32K context | You need long context — KV comes out of the ~21 GB that is left |

## How

```bash
ws check llamacpp-deepseek-v4-flash-gguf
ws up    llamacpp-deepseek-v4-flash-gguf
tail -f ~/.local/state/ws-llamacpp-ds-v4-flash.log
gx10-top                                   # watch this one; see below
ws down  llamacpp-deepseek-v4-flash-gguf
```

**Watch the memory, not the log.** This is the workspace here most likely to
run the box out of it. If `gx10-top` shows swap *growing*, stop — on coherent
memory swap is a cliff, not a slope.

### Turning on DSpark drafts

Off by default only because it needs a file this script will not download for
you.

```bash
# .env
DRAFT_FILE=/path/to/DeepSeek-V4-Flash-DSpark-Q8_0.gguf   # 10.9 GB
SPEC_N=3
```

`up.sh` then raises its own memory guard from 96 GB to 108 GB, because 10.9 GB
is exactly the difference between fitting and paging on this box.

### The guard, and overriding it

Before starting anything, `up.sh` reads `MemAvailable` and refuses if there is
less than `NEED_GB` (96, or 108 with drafts). That number is deliberately the
same as `min_unified_gb` in the manifest — two numbers for one requirement is
how `ws check` ends up passing something `ws up` then refuses.

A late OOM here does not fail politely: it takes the session with it, and the
paging starts long before the kill. Override with `NEED_GB=` in `.env` only if
you genuinely know better.

### Sampling

DeepSeek's own numbers, not the Qwen table: **temperature 1.0, top_p 1.0,
min_p 0.01**. Use `top_p 0.95` for agentic work.

## What the run measured

| | |
|---|---|
| Weights | 90.9 GB UD-IQ2_M, all layers offloaded (`-ngl 999`) |
| Resident | **96 GB of 121 — and no swap**, which is the claim that mattered |
| Decode | ~15 tok/s (78 tokens in 5.1 s) |
| Needs | `llama_cpp_version` ≥ **b10717** — b6100 downloads all 90.9 GB and then dies on `unknown model architecture: 'deepseek4'` |

The header's memory arithmetic holds exactly. This is the workspace most likely
to run the box out of memory, and at the shipped quant it does not.

## What 2-bit costs

`ws up vllm-quality-gate` came back **1/2**:

```
CONC   OK   TOK/S  SHAPE  DETAIL
   1  1/2       7  json   empty-with-58-tokens-billed (reasoning never closed)
```

**58 is not the token cap** — the reply ended on its own, empty, with the
reasoning block never closed. So this is a genuine detector hit, not the
`max_tokens` artefact the gate documents separately. The prose shape passed.

UD-IQ2_M is the most aggressive quantisation in this repo at ~2 bits, and this
is what that buys you. **For output quality the answer is not a different
single-node quant** — it is both nodes at FP8:

```bash
ws up vllm-2node-deepseek-v4-flash    # verified: 6/6 gate clean, acceptance 1.00
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| 90.9 GB downloads, then `unknown model architecture: 'deepseek4'` | `llama_cpp_version` predates the release that learned this model | Pin ≥ `b10717` in `group_vars/all.yml`, then `make apply TAGS=ml` |
| Empty replies with the reasoning block unclosed, well under `max_tokens` | 2-bit quantisation on a reasoning model | Expected at UD-IQ2_M. Use both nodes at FP8 for quality |
| `only N GB available and this needs ~96` | Something else holds the pool | `ws down` the other workspace, or `gx10-top` to find it |
| `llama-server not found` | `roles/ml` has not run | `make apply TAGS=ml` |
| Swap growing during generation | The draft model, a desktop session, or both | Drop `DRAFT_FILE`, or `sudo systemctl set-default multi-user.target` |
| First run takes an hour before anything answers | ~91 GB off a cold cache | Expected. It is downloading, then loading |
| Tokens/s far below expectations with drafts on | Draft path silently broken — acceptance costs nothing else | The target still verifies every token, so output stays *correct*. Compare with `DRAFT_FILE` unset |

## Sources

- <https://unsloth.ai/docs/models/deepseek-v4>
- <https://huggingface.co/unsloth/DeepSeek-V4-Flash-0731-GGUF>
- <https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731>

See also: [`workspace.yml`](workspace.yml) ·
[the V4 ladders](../../../docs/decisions.md#deepseek-v4) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
