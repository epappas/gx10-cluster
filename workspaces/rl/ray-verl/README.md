# ray-verl

> RL post-training (GRPO/PPO) with [verl](https://github.com/volcengine/verl) —
> vLLM rollouts, FSDP training, on one GB10. **The tightest memory fit in this
> repo.**

| | |
|---|---|
| Kind | `rl` |
| Engine | Ray + verl |
| Nodes | **2** — one GPU per box; `ray-cluster.sh` builds the cluster |
| Endpoint | `http://127.0.0.1:8265` — Ray dashboard, if you started the [`ray`](../../cluster/ray/README.md) workspace |
| Needs | ~90 GB unified · Docker |
| Provenance | `verified` — GRPO trained across both nodes, reward rising |

## What

Runs `verl.trainer.main_ppo` inside `gx10/verl:sm121` — built here on the vLLM image this repo already serves from — against
[`grpo-qwen3-1.7b.yaml`](grpo-qwen3-1.7b.yaml), with the workspace directory
bind-mounted at `/work` and the host HF cache at `/hf`.

**Interactive and blocking by design** (`docker run --rm -it`, `exec`). An RL
run is something you watch, not a service you background — which is also why
there is no `down.sh`: `Ctrl-C` is the teardown.

## What actually happens on a GB10

**It trains, across both nodes.** Measured here, `NNODES=2 ws up ray-verl`:

| | |
|---|---|
| Baseline `val-core/openai/gsm8k/acc/mean@1` | **0.0167** over all 1319 problems |
| step 1 | `critic/score/mean` **0.0078** · `actor/grad_norm` **0.248** |
| step 2 | `critic/score/mean` **0.0234** · `actor/grad_norm` **0.559** |
| step 3 | `critic/score/mean` **0.0313** · `actor/grad_norm` **1.061** |
| Actor memory | **16.09 GB** allocated / 23.55 GB reserved per rank |
| Throughput | **97–115 tok/s** · ~205 s per step at `n: 8` |

Reward rises monotonically and the gradient norm is non-zero. Both halves
matter: a run can complete every step and still train nothing, which is exactly
what the first three-step run did.

### Zero reward is the failure mode to know about

Three separate causes produced `critic/score/mean: 0.0` with
`actor/grad_norm: 0.0` — a loop that looks perfectly healthy and updates
nothing. GRPO's advantage is a sample's reward minus its **group** mean, so any
group whose members all score alike contributes no gradient at all.

| Cause | Symptom | Fix |
|---|---|---|
| Responses truncated mid-reasoning | `response_length/clip_ratio` 0.75 | `max_response_length: 2048` |
| Qwen3 thinking mode never emits `####` | clip_ratio 0.0, score still 0.0 | `apply_chat_template_kwargs.enable_thinking: false` |
| Group too small to vary | score 0.0 with a policy that does sometimes succeed | `rollout.n: 8` |

verl scores gsm8k with `method="strict"` — `re.findall("#### (\\-?[0-9\\.\\,]+)", …)`
against the **last 300 characters**. Nothing about a wrong answer and nothing
about an unparseable one look different in the metrics.

### Qwen3-8B does not fit, and a second node does not change that

This page used to say a second node would make 8B fit. It does not, and the
arithmetic is worth keeping. FSDP1 under mixed precision keeps an fp32 master
shard, so a full-parameter Adam step on 8.19B parameters costs **~65.6 GB per
rank**:

| Term | Per rank (2 ranks) |
|---|---|
| fp32 master weights | 16.4 GB — verl prints it: `After FSDP, memory allocated (GB): 15.26` |
| Adam `exp_avg` + `exp_avg_sq` | 32.8 GB |
| bf16 params + grads | 16.4 GB |

…on top of what is gone before the trainer allocates anything:
`Before FSDP, memory allocated (GB): 0.00 … device memory used/total (GB): 54.67/121.63`.
None of that 54.67 GB is the trainer — it is page cache from reading 16 GB of
safetensors, Ray's object store in `/dev/shm`, and the worker processes. On
unified memory none of it is subtracted from a separate GPU budget.

8B was measured OOMing **three independent ways**, all at `_update_actor`:

| Configuration | Outcome |
|---|---|
| Ray monitor at 0.95 (default) | killed at **116.34 / 121.63 GB** |
| Ray monitor at 0.97 | killed at **118.23 / 121.63 GB** |
| Ray monitor off | kernel OOM-killed the actor after eating all 15 GB of swap |

**LoRA is the supported way to fit it, and this image cannot serve the
adapter.** verl 0.9.0 syncs LoRA as an adapter rather than merging it, and
vLLM's `set_lora` in this nightly indexes `lora_a_i.shape[1]` on a tensor verl
hands over one-dimensional — `IndexError: tuple index out of range`. That is a
version skew between two pinned halves, not a setting. Full-parameter 8B needs
roughly double this cluster.

### Tied embeddings: fixed, not worked around

Every Qwen3 below 8B sets `tie_word_embeddings=true`, and verl's bucketed
weight transfer used to fail on all of them:

```
ValueError: 'lm_head.weight' was skipped because it is tied to
'model.embed_tokens.weight' in Qwen3ForCausalLM, but
'model.embed_tokens.weight' was not found in the checkpoint, so the tied
weight is uninitialized.
```

vLLM skips `lm_head.weight` on a tied model and then checks its tie partner was
loaded in the **same call** — but the trainer streams weights in buckets, so
`embed_tokens.weight` arrives in a different one.
[`patches/0002`](patches/) drops `lm_head.weight` from the transfer on tied
models, which is correct rather than merely quiet: vLLM's `lm_head` **is**
`embed_tokens` there, so the bucket carrying `embed_tokens.weight` already
updates both. That patch is why this workspace can run a 1.7B policy at all.

## Two nodes: what has to be on both

`ray-cluster.sh up` starts a head here and a worker on each peer, and stages two
things to every node first:

- **`~/src/verl`**, patches included. Every node runs verl out of its own
  bind-mount; if the trees differ, the two halves of one training step disagree
  about what the code is.
- **the workspace directory**, mounted at `/work`. verl creates its driver with
  a bare `task_runner_class.remote()` — no scheduling strategy — so **Ray may
  place the TaskRunner on any node**, and the node it picks is the one that
  opens the dataset and the config. Land it on a node without `/work` and the
  run dies with `FileNotFoundError: Unable to find '/work/data/gsm8k/train.parquet'`
  having read the config off the head, so nothing in the message points at the
  node that failed.

### Ray's OOM killer is wrong on this box, and is off by default

It compares psutil's used bytes against total. On GB10 that number includes
~25 GB of reclaimable page cache and ~20 GB of `/dev/shm`, so it kills workers
at a transient weight-sync spike the kernel would have absorbed:

```
5 Workers (tasks / actors) killed due to memory pressure (OOM),
0 Workers crashed due to other reasons
```

…leaving the driver blocked forever on actors that will not answer.
`ray-cluster.sh` sets `RAY_memory_monitor_refresh_ms=0`, caps the object store
at 4 GB (Ray defaults to 30% of RAM, and a GRPO step moves a few MB), and drops
`/dev/shm` to 4g. Those three together took ~20 GB of counted-but-idle memory
out of the peak. Set `RAY_MEM_MONITOR_MS` to a positive value to put the
monitor back.

### FlashAttention is not available, and does not need to be

verl imports `flash_attn.bert_padding` unconditionally on non-NPU hardware, and
there is no FlashAttention wheel for sm_121:

```
File "verl/utils/attention_utils.py", line 30, in _get_attention_functions
ModuleNotFoundError: No module named 'flash_attn'
```

Those four names are pure-tensor index/pad helpers, **not** attention kernels —
the sequence-packing path does not need FA2 at all.
[`patches/0001`](patches/) falls back to the equivalents in `transformers` plus
`einops.rearrange`, mirroring the NPU branch verl already has. `up.sh` applies
both patches to the checkout idempotently and refuses to start if one does not
apply.

## A wrong diagnosis, corrected

This page previously blamed **sm_121 kernels**, citing verl's image arch list.
**That was wrong**, and the check that disproves it is one command — the vLLM
image this repo serves from every day reports the *identical* list:

```
vllm/vllm-openai (works):  archs ['sm_80','sm_90','sm_100','sm_110','sm_120']  cc (12,1)
verlai/verl     (failed):  archs ['sm_80','sm_90','sm_100','sm_110','sm_120']  cc (12,1)
```

`sm_120` and `sm_121` are binary compatible — as this repo has documented since
the DeepSeek port. The real difference was vLLM's **own CUDA extensions**,
compiled without an `sm_121` target in verl's image and with one in this
repo's. [`docker/Dockerfile`](docker/Dockerfile) rebuilds verl on that base, and
`CUDA error: no kernel image is available` never appears again.

## The image ships the stack, not verl

**Three things had to change before this workspace could start at all**, and
none of them is a flag you would guess at.

**`verlai/verl:latest` does not exist.** The registry carries ~150 tags and every
one names its stack — `vllm023.aarch64.dev1`, `trtllm-1.3.0rc15`,
`uv.cu130.dev1`. The pull fails with `no such manifest`, which reads as a network
problem rather than a tag nobody published. Most tags are amd64-only, which
narrows the choice again on this hardware.

**And no `verlai/verl` image contains verl.** In every one of them:

```
python3 -c "import verl"   →  ModuleNotFoundError: No module named 'verl'
pip show verl              →  WARNING: Package(s) not found: verl
```

That is by design, and verl's own install docs say so: *"if you use the images
provided, you only need to install verl itself without dependencies."* The images
ship **torch, vLLM and Ray**; you bring the source and
`pip3 install --no-deps -e .`, which takes seconds because every dependency is
already there. The `uv.*` tags go further — `VIRTUAL_ENV` points at a `.venv`
that does not exist, so even `torch` is unimportable until `uv sync` has run.

So `up.sh` clones a **pinned** verl (`VERL_VERSION`, default `v0.9.0`) into
`~/src/verl`, mounts it at `/workspace/verl`, installs it without dependencies,
and only then runs the trainer. Verified here: verl 0.9.0 imports and
`verl.trainer.main_ppo` loads under `vllm023.aarch64.dev1` with
`torch 2.11.0+cu130`.

**And there was no dataset.** verl's data config defaults to
`~/data/rlhf/gsm8k/*.parquet` — `$HOME` *inside the container*, a path nothing in
this repo creates and no mount reaches. The shipped config now points at
`/work/data/gsm8k`, `up.sh` refuses before loading Ray if it is missing, and

```bash
ws up ray-verl --prepare-data
```

builds it with verl's own preprocessor (7,473 train / 1,319 test), written as
you rather than as root.

## Why

### The constraint is memory, not compute

A GRPO run holds **four** things at once:

1. the policy
2. a reference copy
3. optimiser state
4. the rollout engine (vLLM)

On unified memory all four come out of the same 121 GB that also holds the page
cache. The usual "the GPU has 80 GB, use 75" reasoning does not transfer.

### So the default policy is small, on purpose

The shipped config targets **Qwen3-1.7B**, which trains in 16.09 GB per rank.
That is not timidity: 8B was measured OOMing three ways above, and the config
carries the arithmetic for why. **Get a small run green end to end before
scaling** — and note that "green" means a rising `critic/score/mean`, not an
exit code of 0.

### `min_unified_gb` is 90, not 121

Below that you are into swap, and on coherent memory **swap is a cliff, not a
slope**.

### Every conservative number in the config is conservative on purpose

| Key | Value | Why |
|---|---|---|
| `rollout.gpu_memory_utilization` | `0.35` | The rollout engine is **co-resident with the trainer**. A serving-only workspace takes 0.84; here that fraction is of the *same* pool the trainer is using |
| `model.enable_gradient_checkpointing` | `true` | Not optional here — it is the difference between fitting and not |
| `fsdp_config.param_offload` / `optimizer_offload` | `true` | Offloading to "CPU" on a coherent box does not move bytes across PCIe — there is one pool — but it **does** let FSDP release its own allocator pressure, which is what OOMs first |
| `ppo_micro_batch_size_per_gpu` | `1` | |
| `max_prompt_length` / `max_response_length` | `1024` / `1024` | |
| `rollout.n` | `4` | Rollouts per prompt |

Treat it as a starting point that fits, then **raise one number at a time**.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You are doing RL post-training on a small policy | You want to *serve* a model → the inference workspaces |
| You want verl's pinned Ray, not the host's | You want a standing Ray cluster → `make optional TAGS=ray` |
| You can give the box its whole memory pool | Something else is serving — these do **not** coexist |

## How

```bash
ws check ray-verl                   # ~90 GB free, docker usable
ws up    ray-verl                   # blocking and interactive; Ctrl-C stops it
ws up    ray-verl                   # with CONFIG=my-run.yaml in .env
```

In another terminal, always:

```bash
gx10-top      # this run holds four things in one 121 GB pool
```

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| `CONFIG` | `grpo-qwen3-1.7b.yaml` | Must be in this directory — it is mounted at `/work` |
| `IMAGE` | `verlai/verl:vllm023.aarch64.dev1` | **verl publishes no `:latest`**, and no image contains verl. [Why](#the-image-ships-the-stack-not-verl) |
| `VERL_VERSION` | `v0.9.0` | The source pin. Both nodes should match, same reasoning as `llama_cpp_version` |
| `VERL_SRC` | `~/src/verl` | Cloned on first run, beside where `roles/ml` puts llama.cpp |
| `DATA_DIR` | `data/gsm8k` | Built by `ws up ray-verl --prepare-data` |
| `HF_TOKEN` | unset | Only for gated policies |
| `SHM_SIZE` | `32g` | |

### Pairing it with the Ray workspace

verl can drive its own local Ray. If you want a visible cluster and a dashboard:

```bash
ws up ray          # ephemeral, containerised, pinned by the image
ws up ray-verl
```

Do **not** run this alongside `roles/ray`'s standing systemd service — they
fight over ports ([why both exist](../../../docs/decisions.md#workspaces)).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| OOM early in training | Something else holds the pool, or the policy is too big | `ws down` the other workspace; drop to a 2B-class policy |
| Swap growing | You are over the cliff | Stop. Lower `rollout.gpu_memory_utilization` or the batch sizes |
| `critic/score/mean: 0.0` and `grad_norm: 0.0` | The loop is fine; the reward has no variance within a group | See the zero-reward table above — truncation, thinking mode, or `rollout.n` |
| `FileNotFoundError: /work/data/...` | Ray placed the driver on a node without `/work` | `./ray-cluster.sh up` stages it to every peer |
| Workers "killed due to memory pressure" | Ray's monitor counts page cache and `/dev/shm` | Off by default here; see `RAY_MEM_MONITOR_MS` |
| Killed with no error | `earlyoom` targets the largest-RSS process | `make verify` checks this; `systemctl disable --now earlyoom` |
| Rollouts are very slow | `rollout.n` and the response length multiply | Lower `n` first |
| A 27B run will not fit | Expected — it does not, on one node | Scale the policy down, not the flags up |

## Sources

- <https://verl.readthedocs.io/en/latest/start/quickstart.html>
- <https://github.com/volcengine/verl>

See also: [`workspace.yml`](workspace.yml) ·
[`grpo-qwen3-1.7b.yaml`](grpo-qwen3-1.7b.yaml) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
