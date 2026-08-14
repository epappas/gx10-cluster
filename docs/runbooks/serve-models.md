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

Sizes and the disk budget live in [manage-models](manage-models.md#what-fits).
The short version: prefer **NVFP4** — it is the native format for GB10's
Blackwell FP4 tensor cores, so it is smaller *and* faster here. The 120B fits
one node at NVFP4 (74.8 GB) but not at FP8 or BF16.

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

## Both nodes

A model too big for one box is served with Ray plus
`--tensor-parallel-size 2`; see [run-distributed](run-distributed.md#ray).

## When it fails

| Symptom | Cause |
|---|---|
| `no kernel image is available` | Something used a pip vLLM/torch instead of the container or cu130 index |
| OOM at load, or the box crawls | Model exceeds the pool — see [what fits](manage-models.md#what-fits); lower `vllm_gpu_memory_utilization` |
| `CUDA error: out of memory` mid-run | KV cache growth; lower `--max-model-len` |
| Port 8000 refused | Bound to localhost by design — `ssh -L 8000:localhost:8000 <node>` |

vLLM sizes its KV cache from NVML, which on GB10 reports **no framebuffer** —
so it profiles against a pool the OS also lives in. That is why
`vllm_gpu_memory_utilization` defaults to 0.85 here rather than the usual 0.9+.
