# vllm-qwen3.8-27b-nvfp4

> Qwen3.8-27B in **NVFP4** — the quantisation this hardware exists for — served
> by vLLM on a single GB10, with 1M context via YaRN and MTP speculative decoding.

| | |
|---|---|
| Kind | `inference` |
| Engine | vLLM (container) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8888/v1` |
| Needs | ~40 GB unified · Docker |
| Provenance | **`verified`** — run on this hardware, and it moved one default into a documented knob. [The MTP trade](#mtp-costs-the-entire-prefix-cache) |

## What

A single `docker compose` service running `vllm/vllm-openai:nightly-aarch64`
against `unsloth/Qwen3.8-27B-NVFP4` (~22.6 GB), served OpenAI-compatible on
:8888. The host HF cache is bind-mounted at `/hf`, so weights the `models` role
already pulled are reused rather than downloaded again into a container volume.

## Why

**NVFP4 is a Blackwell-only format, and GB10 is `sm_121`.** This is the
quantisation the hardware was built for — smaller *and* faster than the
alternatives on this box. If you run one model on one node, this is the
default choice.

Two container decisions worth knowing:

- **The `nightly-aarch64` tag, not a stable one.** NVFP4 support landed in
  vLLM 0.25.0 and the stable multi-arch tags lag it. This is the same bet the
  rest of the repo makes: track upstream rather than adopt a fork.
- **A container at all, rather than a wheel in the ML venv.** vLLM does not
  officially support `sm_121`; its pip wheels carry kernels up to `sm_120` and
  link `libcudart.so.12`, while this box has CUDA 13. `sm_120` and `sm_121` are
  binary compatible, which is why the CUDA-13 *container* works where the wheel
  does not.

## MTP costs the entire prefix cache

**Measured here, on this checkpoint, and it is the most important thing on this
page.** Qwen3.8-27B is a hybrid — `Qwen3_5ForConditionalGeneration`, mamba
groups plus attention — and vLLM says out loud what MTP does to it:

```
Speculative decoding (method=mtp) is enabled but no KV cache group could be
identified as the draft model's, so every group -- including Mamba groups
[0, 1, 2] -- will be treated as a draft group. A Mamba group cannot satisfy the
widened lookup window that implies, so prefix-cache reuse across requests will
be disabled
```

It means it. Two byte-identical requests back to back, on the shipped default:

| | `SPEC_METHOD=mtp` (default) | `SPEC_METHOD=none` |
|---|---|---|
| Prefix-cache hits | **0**, on 471,925 queried tokens | 1,568 of 4,032 |
| Cold 8k prefill | 5.83 s TTFT · 1364 tok/s | 3.34 s TTFT · 2384 tok/s |
| **Follow-up turn** (`ws up vllm-prefill-ladder`) | 3.53 s TTFT, **nothing reused** | **0.22 s TTFT**, 7840 of 7980 reused |
| Decode, concurrency 1 (`ws up vllm-bench-serve`) | **16.4 tok/s** | 10.6 tok/s |
| Acceptance (`ws up spec-decode-accept`) | 1.00 / 1.00 structured, k=2 | n/a |

**So it is a real trade and it genuinely goes both ways.** MTP is worth ~55% on
single-stream decode. Prefix caching is worth **15×** on the second turn of a
conversation — and chat resends the whole history every turn, so that is the
number most workloads here actually feel.

The default stays `mtp`, because that is what this workspace has always shipped
and it is the right answer for one-shot generation. **If you are pointing an
agent at this** — [`deepseek-harness`](../../agent/deepseek-harness/README.md),
or anything that holds a conversation — put `SPEC_METHOD=none` in `.env` and
measure it yourself:

```bash
SPEC_METHOD=none ws up vllm-qwen3.8-27b-nvfp4
BASE_URL=http://127.0.0.1:8888/v1 ws up vllm-prefill-ladder --rungs 8000
```

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want the best single-node throughput here | You want the memory back → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md) |
| You want NVFP4 specifically | You want SGLang's scheduler → [`sglang-qwen3.8-27b-int4`](../sglang-qwen3.8-27b-int4/README.md), on **GGUF** — see below |
| You are about to benchmark or gate a server | The model does not fit one node → [two-node serving](../../../docs/runbooks/two-node-serving.md) |

**SGLang cannot serve this checkpoint.** Its `lm_head` is quantised and SGLang
does not support that, which is why there is no SGLang variant of *this*
workspace. It is a fact about **this checkpoint**: SGLang serves NVIDIA's
Nemotron 3.5 Lightning NVFP4 on day 0
([`sglang-nemotron35-lightning-nvfp4`](../sglang-nemotron35-lightning-nvfp4/README.md)),
so do not read this row as "SGLang cannot do NVFP4".

## How

```bash
ws check vllm-qwen3.8-27b-nvfp4
ws up    vllm-qwen3.8-27b-nvfp4
ws logs  vllm-qwen3.8-27b-nvfp4 -f     # this one IS compose, so logs work
curl -s localhost:8888/health && echo ready
ws down  vllm-qwen3.8-27b-nvfp4
```

**Expect minutes of 503s after start.** 20 GB of NVFP4 off NVMe takes a while
to load, which is why the healthcheck's `start_period` is 15 minutes and why it
probes `/health` rather than `/v1/models` — the latter answers *before* the
weights finish loading, so anything depending on it would start talking to a
server that then 503s.

### Then prove it is right, not just up

```bash
ws up vllm-bench-serve        # how many streams before latency falls over
ws up vllm-quality-gate       # is it answering correctly
```

Those two ask genuinely different questions — see
[`vllm-bench-serve`](../../bench/vllm-bench-serve/README.md) and
[`vllm-quality-gate`](../../bench/vllm-quality-gate/README.md).

### Tuning, in `.env`

| Variable | Default | Note |
|---|---|---|
| `GPU_MEMORY_UTILIZATION` | `0.84` | 84% of the **same 121 GB** that holds the page cache and your shell |
| `MAX_MODEL_LEN` | `262144` | KV cache is not free; it comes out of that same pool |
| `KV_CACHE_DTYPE` | `fp8` | |
| `SPEC_TOKENS` | `2` | MTP speculative decoding |
| `PORT` | `8888` | |
| `SERVED_NAME` | `qwen3.8-27b` | The name clients ask for — **not** the HF repo id |

`SERVED_NAME` has a sharp edge worth knowing before you benchmark: a tokenizer
cannot be loaded from `qwen3.8-27b`, so
[`vllm-bench-serve`](../../bench/vllm-bench-serve/README.md) needs `TOKENIZER`
set to the HF repo id, or it dies several minutes in with a 404.

### Sampling is not a preference

| | temperature | top_p | top_k | presence_penalty |
|---|---|---|---|---|
| Thinking | 1.0 | 0.95 | 20 | 0.0 |
| Instruct | 0.7 | 0.80 | 20 | 1.5 |

Reasoning depth is separate, and is a request field rather than a server flag:
`--chat-template-kwargs '{"reasoning_effort":"medium"}'` (`xhigh` is the
default, then `medium`, `low`, `none`).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `Prefix cache hit rate: 0.0%` forever, and follow-up turns re-prefill the whole history | MTP disables prefix-cache reuse on this hybrid checkpoint — vLLM warns once, at startup | `SPEC_METHOD=none` in `.env`. [The trade](#mtp-costs-the-entire-prefix-cache) |
| 503 for minutes after start | Weights still loading | Expected. `ws logs -f` |
| OOM, or swap growing | Another workload holds the pool, or utilisation too high | `ws down` the other; lower `GPU_MEMORY_UTILIZATION` |
| Killed under load with no error in the log | `earlyoom` — it targets the largest-RSS process, which is *always* the model server | `make verify` checks for this; `systemctl disable --now earlyoom` |
| The image will not pull | The nightly tag moved or broke for `aarch64` | Pin `VLLM_IMAGE` to a digest that worked, or fall back to the llama.cpp workspace |
| A client sees a model name it did not expect | `SERVED_NAME` ≠ the HF repo id, by design | `curl -s localhost:8888/v1/models` |

## Sources

- <https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-RTX-6000>
- <https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4>

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[the engine × quant matrix](../../README.md) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
