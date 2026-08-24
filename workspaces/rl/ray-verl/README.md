# ray-verl

> RL post-training (GRPO/PPO) with [verl](https://github.com/volcengine/verl) —
> vLLM rollouts, FSDP training, on one GB10. **The tightest memory fit in this
> repo.**

| | |
|---|---|
| Kind | `rl` |
| Engine | Ray + verl |
| Nodes | **1** (the shipped config is `nnodes: 1`) |
| Endpoint | `http://127.0.0.1:8265` — Ray dashboard, if you started the [`ray`](../../cluster/ray/README.md) workspace |
| Needs | ~90 GB unified · Docker |
| Provenance | `unverified` — expect to fix at least one config key on first use |

## What

Runs `verl.trainer.main_ppo` inside `verlai/verl:latest` against
[`grpo-qwen3-8b.yaml`](grpo-qwen3-8b.yaml), with the workspace directory
bind-mounted at `/work` and the host HF cache at `/hf`.

**Interactive and blocking by design** (`docker run --rm -it`, `exec`). An RL
run is something you watch, not a service you background — which is also why
there is no `down.sh`: `Ctrl-C` is the teardown.

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

The shipped config targets a **Qwen3-8B-class** policy. A 27B GRPO run does not
fit on one node without offload and aggressive sharding, and pretending
otherwise wastes an afternoon discovering it.

**Get a small run green end to end before scaling.**

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
| `CONFIG` | `grpo-qwen3-8b.yaml` | Must be in this directory — it is mounted at `/work` |
| `IMAGE` | `verlai/verl:latest` | |
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
| OOM early in training | Something else holds the pool, or the policy is too big | `ws down` the other workspace; drop to an 8B-class policy |
| Swap growing | You are over the cliff | Stop. Lower `rollout.gpu_memory_utilization` or the batch sizes |
| An unknown config key | The manifest is `unverified` — written from verl's documented schema, not a completed run | Fix the key, and say what you changed (see [provenance](../../README.md)) |
| Killed with no error | `earlyoom` targets the largest-RSS process | `make verify` checks this; `systemctl disable --now earlyoom` |
| Rollouts are very slow | `rollout.n` and the response length multiply | Lower `n` first |
| A 27B run will not fit | Expected — it does not, on one node | Scale the policy down, not the flags up |

## Sources

- <https://verl.readthedocs.io/en/latest/start/quickstart.html>
- <https://github.com/volcengine/verl>

See also: [`workspace.yml`](workspace.yml) ·
[`grpo-qwen3-8b.yaml`](grpo-qwen3-8b.yaml) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
