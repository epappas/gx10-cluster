# Runbook: manage model weights

**What** — download, budget, inspect and remove open-weight models.
**When** — before serving anything; when the disk fills; when adding a model.
**Risk** — low, except that weights are large and the disk holds swap too.

To *run* a model once it is here, see [serve-models](serve-models.md).

## What fits

Measured from the HF API, against ~114 GB usable of the 121 GB unified pool.
On this hardware "GPU memory" and "host memory" are the same pool, so this
table is the whole story — there is no separate VRAM budget.

| Model | On disk | One node? |
|---|---|---|
| `Qwen/Qwen3-8B` | 15.3 GB | yes |
| `nvidia/Qwen3.6-27B-NVFP4` | 20.4 GB | yes |
| `nvidia/Qwen3.6-35B-A3B-NVFP4` | 21.9 GB | yes |
| `Qwen/Qwen3.8-27B` | 51.8 GB | yes |
| `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 74.8 GB | yes, ~39 GB spare |
| `nvidia/Llama-3_3-Nemotron-Super-49B-v1` (bf16) | 92.9 GB | yes, tight |
| `…-120B-A12B-FP8` | 119.6 GB | **no** — weights alone exceed available |
| `…-120B-A12B-BF16` | 230.3 GB | **no** — needs both nodes |

**Prefer NVFP4.** It is the native format for GB10's Blackwell FP4 tensor
cores — the same reason llama.cpp compiles for `121a`. Smaller *and* faster
here, which is not the usual quantisation tradeoff.

## Download

```bash
make models                        # every set in model_sets
ml && hf download <model-id>       # one off
```

Downloads are resumable and idempotent: an interrupted pull costs only time,
and re-running verifies what is already local. The role refuses to start if it
would leave less than `model_min_free_gb` (default 100 GB) free.

## Choose what gets pulled

`group_vars/all.yml` defines sets, and `model_sets` selects them:

```yaml
model_sets: [smoke, nvfp4]     # default
model_sets: [smoke, nvfp4, large]   # adds the 49B bf16
```

| Set | Contents | Total |
|---|---|---|
| `smoke` | Qwen3-8B | 15 GB |
| `nvfp4` | Qwen3.6-27B, Qwen3.6-35B-A3B, Nemotron-120B — all NVFP4 | 117 GB |
| `large` | Llama-3_3-Nemotron-Super-49B bf16 | 93 GB |
| `cluster` | Nemotron-120B BF16 — **only usable across both nodes** | 230 GB |

Adding a model is one line in `model_catalog`. Put the measured size in a
comment beside it; the table above is only useful because it is maintained.

## Gated models

Some repos require accepting a licence. `hf download` then fails with 401/403.

```bash
ml && hf auth login          # paste a token from huggingface.co/settings/tokens
hf auth whoami
```

The token lands in `$HF_HOME/token`. It is **not** in this repo and must not
be — add it per node.

## Inspect and reclaim

```bash
du -sh ~/.cache/huggingface                      # total
hf cache scan                                    # per-model, with revisions
hf cache delete                                  # interactive eviction
df -h /                                          # remember swap lives here too
```

Weights land in `~/.cache/huggingface/hub`. Deleting a model directory by hand
works but leaves dangling refs; `hf cache delete` is the tidy path.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Role aborts before downloading | Below the `model_min_free_gb` floor | Reclaim space, or lower the floor deliberately |
| 401 / 403 | Gated repo | `hf auth login` |
| Download stalls near the end | Large shard over a slow link | Re-run; it resumes |
| Model loads but the box crawls | Exceeds the pool → swap cliff | Check the table; prefer NVFP4 |
| `No space left on device` mid-pull | Floor set too low for this model | `hf cache delete`, then re-run |

## A note on the disk

The 916 GB NVMe also holds the 16 GB swap file. Filling it does not merely stop
downloads — it removes the emergency valve on a box where swapping is already a
[performance cliff](../hardware.md#unified-memory). Keep real headroom; the
100 GB floor is deliberately generous.
