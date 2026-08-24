# sglang-qwen3.8-27b-gguf

> Qwen3.8-27B served by SGLang — on the **GGUF** build, because SGLang cannot
> load the NVFP4 one. Pick it for the scheduler, not for the quantisation.

| | |
|---|---|
| Kind | `inference` |
| Engine | SGLang (container) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8900/v1` |
| Needs | ~28 GB unified · Docker |
| Provenance | `unverified` — and the image tag is the reason; see below |

## What

`lmsysorg/sglang:latest` launching `sglang.launch_server` against
`unsloth/Qwen3.8-27B-GGUF`, 256K context, `--mem-fraction-static 0.80`, served
on :8900 (mapped from the container's 30000). Host HF cache bind-mounted at
`/hf`.

## Why

SGLang's reason to exist here is its **scheduler and structured-output work** —
RadixAttention prefix reuse, constrained decoding, its own batching. Those are
real and they are what you would come for.

## When to use it — and when not

> **Read this before reaching for SGLang on this hardware.**
>
> **SGLang cannot serve `unsloth/Qwen3.8-27B-NVFP4`.** The checkpoint has a
> quantised `lm_head`, which SGLang does not support. So the model that this
> Blackwell box is otherwise ideal for is exactly the one SGLang will not load.
> The GGUF build works, which is what this workspace uses.

| Use it when | Use something else when |
|---|---|
| You want SGLang's scheduler or structured output | You want NVFP4 → [`vllm-qwen3.8-27b-nvfp4`](../vllm-qwen3.8-27b-nvfp4/README.md) |
| You are comparing engines on the same weights | You want the smallest footprint → [`llamacpp-qwen3.8-27b-gguf`](../llamacpp-qwen3.8-27b-gguf/README.md), same GGUF, no container |
| | You want the best throughput on this box → vLLM |

That trade is discoverable only by trying and failing, which is why it is
recorded in three places: here, in
[`workspace.yml`](workspace.yml), and in
[the engine × quant matrix](../../README.md).

## How

```bash
ws check sglang-qwen3.8-27b-gguf
ws up    sglang-qwen3.8-27b-gguf
ws logs  sglang-qwen3.8-27b-gguf -f
curl -s localhost:8900/health && echo ready
ws down  sglang-qwen3.8-27b-gguf
```

### Tuning, in `.env`

| Variable | Default | Note |
|---|---|---|
| `MEM_FRACTION` | `0.80` | SGLang's equivalent of `--gpu-memory-utilization`. Same one pool |
| `CTX` | `262144` | |
| `PORT` | `8900` | Deliberately clear of 8888/8890/8891/8899 |
| `SGLANG_IMAGE` | `lmsysorg/sglang:latest` | See the caveat below |
| `SHM_SIZE` | `16g` | |

### The image caveat, stated plainly

**No `aarch64` tag is published as reliably as vLLM's**, so this pins `:latest`
and the manifest is marked `unverified` partly for that reason. If the image
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
| It refuses the NVFP4 checkpoint | Quantised `lm_head`, unsupported | Use vLLM, or stay on GGUF. This is not configurable |
| `no matching manifest for linux/arm64` | No `aarch64` image published for that tag | Pin an older tag that has one, or use another engine |
| 503 for minutes after start | Weights still loading; `start_period` is 15m | `ws logs -f` |
| OOM, or swap growing | Another workload holds the pool | `ws down` the other; lower `MEM_FRACTION` |
| Killed under load with no error | `earlyoom` targets the largest-RSS process | `systemctl disable --now earlyoom` |

## Sources

- <https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4>
- <https://unsloth.ai/docs/models/qwen3.8>

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[runbook](../../../docs/runbooks/workspaces.md)
