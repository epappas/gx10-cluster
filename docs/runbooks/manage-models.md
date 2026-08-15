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
make models                        # every set in model_sets, on both nodes
ml && hf download <model-id>       # one off
```

Downloads are resumable and idempotent: an interrupted pull costs only time,
and re-running verifies what is already local.

### The disk guard projects; it does not check a floor

The role refuses to start unless **`free − sum(size_gb) ≥ model_min_free_gb`**
(default 100 GB) — that is, unless the floor still holds *after* everything in
`model_sets` has landed. A static floor checked once in front of a 134 GB
download passes at 130 GB free and the box runs out somewhere around the third
model.

The failure shows its working, so you do not have to reconstruct it — shape,
with the default sets:

```
134 GB free minus 134 GB of planned weights (4 model(s) from sets smoke, nvfp4)
leaves 0 GB, under the 100 GB floor.
```

Drop a set from `model_sets`, reclaim space, or lower `model_min_free_gb`
deliberately.

## Choose what gets pulled

`group_vars/all.yml` defines sets, and `model_sets` selects them:

```yaml
model_sets: [smoke, nvfp4]     # default
model_sets: [smoke, nvfp4, large]   # adds the 49B bf16
```

Totals below are the catalog's `size_gb` values — rounded up from measurement,
and what the guard actually sums.

| Set | Contents | Total |
|---|---|---|
| `smoke` | Qwen3-8B | 16 GB |
| `nvfp4` | Qwen3.6-27B, Qwen3.6-35B-A3B, Nemotron-120B — all NVFP4 | 118 GB |
| `large` | Llama-3_3-Nemotron-Super-49B bf16 — **gated** | 93 GB |
| `cluster` | Nemotron-120B BF16 — **only usable across both nodes** | 231 GB |

### Adding a model

One entry in `model_catalog`, and it is a **dict**, not a bare string:

```yaml
model_catalog:
  nvfp4:
    - { id: "nvidia/Qwen3.6-27B-NVFP4", size_gb: 21 }
```

`size_gb` is data, not documentation — the guard above subtracts it. Measure the
repo (`hf` reports it, or the model card does), round **up**, and keep the table
in [what fits](#what-fits) in step. Entries are de-duplicated by `id`, so a
model listed in two sets is neither downloaded nor counted twice.

## Gated models

Some repos require accepting a licence. `hf download` then fails with 401/403.
Two ways to supply a token, and they are for different things.

**Interactively, for your own use:**

```bash
ml && hf auth login          # paste a token from huggingface.co/settings/tokens
hf auth whoami
```

The token lands in `$HF_HOME/token`. It is **not** in this repo and must not be.

**For `make models`,** which runs unattended and needs the token in the
environment, set `hf_token`. Put it in a vault file, never in
`group_vars/all.yml`:

```bash
ansible-vault create host_vars/odysseus.vault.yml   # hf_token: hf_...
```

The models role builds the download environment as a fact so the key is genuinely
absent rather than present-and-empty when no token is set, and marks the
download `no_log`. The cost of that is worth knowing: a **failed** download
prints `censored` and nothing else. Reproduce it by hand with

```bash
HF_HOME=~/.cache/huggingface ~/venvs/ml/bin/hf download <repo>
```

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
| Role aborts before downloading | The projection lands under `model_min_free_gb` | Drop a set, reclaim space, or lower the floor deliberately |
| 401 / 403 | Gated repo | `hf auth login`, or set `hf_token` in a vault file |
| A download task fails and prints only `censored` | `no_log`, because the env carries `HF_TOKEN` | Re-run the `hf download` by hand, as above |
| `Skipped … is not a directory` warnings on a fresh box | The blob-measuring task reading a cache that does not exist yet | Expected; it returns 0 and that is the right answer |
| Download stalls near the end | Large shard over a slow link | Re-run; it resumes |
| Model loads but the box crawls | Exceeds the pool → swap cliff | Check the table; prefer NVFP4 |
| `No space left on device` mid-pull | A `size_gb` understates the repo, so the guard let it through | Correct the catalog entry; `hf cache delete`, then re-run |
| The download task reports `changed` every run | It should not — it compares blob bytes | [troubleshoot](troubleshoot.md#ansible) |

## A note on the disk

The 916 GB NVMe also holds the 16 GB swap file. Filling it does not merely stop
downloads — it removes the emergency valve on a box where swapping is already a
[performance cliff](../hardware.md#unified-memory). Keep real headroom; the
100 GB floor is deliberately generous.
