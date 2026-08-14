# Runbook: serve and run models

**What** — run open-weight models on the GX10, locally or over the network.
**When** — after `make apply`; models need `make models` (long).

## Why vLLM runs in a container here

vLLM has **no official sm_121 support**. Its pip wheels carry kernels up to
sm_120 and link `libcudart.so.12`, while this box has CUDA 13 — so the wheel
installs and then crashes at startup. sm_120 and sm_121 are binary compatible,
which is why the CUDA-13 *image* works where the wheel does not.

The container also keeps a fast-moving, unsupported-on-this-arch dependency out
of the ML venv: a bad version is a tag change, not a rebuild.

## What fits

Measured against ~114 GB usable of the 121 GB unified pool.

| Model | Size | One node? |
|---|---|---|
| `Qwen/Qwen3-8B` | 15.3 GB | yes |
| `nvidia/Qwen3.6-27B-NVFP4` | 20.4 GB | yes |
| `nvidia/Qwen3.6-35B-A3B-NVFP4` | 21.9 GB | yes |
| `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 74.8 GB | yes, ~39 GB spare |
| `nvidia/Llama-3_3-Nemotron-Super-49B-v1` (bf16) | 92.9 GB | yes, tight |
| `NVIDIA-Nemotron-3-Super-120B-A12B-FP8` | 119.6 GB | **no** — weights alone exceed available |
| `NVIDIA-Nemotron-3-Super-120B-A12B-BF16` | 230.3 GB | **no** — needs both nodes |

**Prefer NVFP4.** It is the native format for GB10's Blackwell FP4 tensor
cores — the same reason llama.cpp compiles for `121a`. Smaller *and* faster
here, not a quality/size tradeoff in the usual sense.

## Three ways to run a model

**ollama** — quickest, good for chat and quick checks:

```bash
ollama run qwen3:8b
```

**llama.cpp** — GGUF, fine-grained control, best for quantized single-stream:

```bash
llama-server -m <model.gguf> --no-mmap -t 10   # --no-mmap: see below
llama-bench -m <model.gguf>
```

`--no-mmap` matters on unified memory: mmap'd weights are pageable, and pageable
host-to-device copies are much slower here than pinned ones.

**vLLM** — throughput serving with an OpenAI-compatible API:

```bash
vllm-serve nvidia/Qwen3.6-27B-NVFP4
vllm-serve nvidia/Qwen3.6-27B-NVFP4 --max-model-len 8192
```

Then:

```bash
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"nvidia/Qwen3.6-27B-NVFP4","messages":[{"role":"user","content":"hi"}]}'
```

As a service (survives logout, restarts on failure):

```bash
sudo systemctl start "vllm@$(systemd-escape 'nvidia/Qwen3.6-27B-NVFP4')"
journalctl -u "vllm@$(systemd-escape 'nvidia/Qwen3.6-27B-NVFP4')" -f
```

`systemd-escape` is not optional — model ids contain both `/` and `-`, and only
systemd's own escaping round-trips them correctly.

## Downloading weights

```bash
make models                      # the sets in group_vars/all.yml
ml && hf download <model-id>     # one off
```

Downloads are resumable, so an interrupted pull costs only time. The role
refuses to start if it would leave less than `model_min_free_gb` free.

To add a set, edit `model_sets` in `group_vars/all.yml`:

```yaml
model_sets: [smoke, nvfp4, large]   # large = the 49B bf16
```

## Both nodes: the 120B at full precision

This is the reason to cable the second box. 230.3 GB of BF16 weights do not fit
one node, but they fit across two (~242 GB combined) with tensor parallelism.

Prerequisites: [interconnect up](connect-cluster.md), and Ray, which vLLM uses
for multi-node TP:

```bash
make orchestrator TAGS=ray
~/venvs/ml/bin/ray status          # both nodes present?
```

Then on the head:

```bash
vllm-serve nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16 --tensor-parallel-size 2
```

Be honest about the margin: 230 GB of 242 GB leaves ~12 GB for KV cache and
activations, so context length will be tight. **FP8 across two nodes (119.6 GB)
is the comfortable version of this** and probably what you actually want.

## When it fails

| Symptom | Cause |
|---|---|
| `no kernel image is available` | Something used a pip vLLM/torch instead of the container or cu130 index |
| OOM at load, or the box crawls | Model exceeds the pool — check the table above; lower `vllm_gpu_memory_utilization` |
| `CUDA error: out of memory` mid-run | KV cache growth; lower `--max-model-len` |
| Port 8000 refused | Bound to localhost by design — `ssh -L 8000:localhost:8000 <node>` |

vLLM sizes its KV cache from NVML, which on GB10 reports **no framebuffer** —
so it profiles against a pool the OS also lives in. That is why
`vllm_gpu_memory_utilization` defaults to 0.85 here rather than the usual 0.9+.
