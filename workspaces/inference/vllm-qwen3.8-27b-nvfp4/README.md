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
| Provenance | `unverified` — written from the sources below, never run on this hardware |

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

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want the best single-node throughput here | You want the memory back → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md) |
| You want NVFP4 specifically | You want SGLang's scheduler → [`sglang-qwen3.8-27b-gguf`](../sglang-qwen3.8-27b-gguf/README.md), on **GGUF** — see below |
| You are about to benchmark or gate a server | The model does not fit one node → [two-node serving](../../../docs/runbooks/two-node-serving.md) |

**SGLang cannot serve this checkpoint.** Its `lm_head` is quantised and SGLang
does not support that — so on Blackwell hardware, whose entire advantage here is
NVFP4, SGLang is the one engine that cannot use it. That is not a bug to work
around; it is why there is no SGLang variant of *this* workspace.

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
