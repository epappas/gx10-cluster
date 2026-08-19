# Runbook: run inference and RL environments

**What** — start a served model, a Ray cluster, or an RL training run on a
machine Ansible has already made ready.
**When** — the box is provisioned and you want to *use* it.
**Risk** — low for the tooling, real for memory. These workloads claim most of
the unified pool, and two of them at once will not fit.

```bash
./workspaces/ws list                          # what exists
./workspaces/ws check vllm-qwen3.8-27b-nvfp4  # does this machine qualify?
./workspaces/ws up    vllm-qwen3.8-27b-nvfp4
./workspaces/ws logs  vllm-qwen3.8-27b-nvfp4 -f
./workspaces/ws down  vllm-qwen3.8-27b-nvfp4
```

## The split, in one line

**Ansible makes the machine ready; workspaces run things on it.** The only
coupling is each workspace's `requires:` block, which `ws check` tests against
the actual machine ([why](../decisions.md#workspaces)).

So when `ws check` fails, the fix is almost always an Ansible one — it will say
so — and when a workspace fails *after* checks pass, the machine is fine and
the recipe or the model is not.

## Choosing an engine

| | llama.cpp | vLLM | SGLang |
|---|---|---|---|
| **NVFP4** ~22.6 GB | no | **yes** | **NO** |
| **GGUF Q4** ~17–19 GB | **yes** | yes | yes |
| **MixedInt4-AutoRound** 20.8 GB | no | **yes** | no |

**SGLang cannot serve the NVFP4 build.** Its `lm_head` is quantised and SGLang
does not support that — so on Blackwell hardware, whose whole advantage is
NVFP4, SGLang is the one engine that cannot use it. That is not a bug to work
around; pick vLLM for NVFP4, or SGLang with GGUF.

**One node or two?** Use `vllm-2node-tp2` when the model does not fit one node
with useful KV cache — the 120B NVFP4 is the worked example. Two-node serving
adds three requirements that all fail *quietly*: the container needs
`/dev/infiniband` and unlimited memlock or NCCL silently falls back to TCP;
`GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME` must be set because gloo ignores
`NCCL_SOCKET_IFNAME`; and both ranks need identical flags or they hang at init.
Confirm the transport with
`docker logs ws-vllm-2node 2>&1 | grep -E 'NET/IB|NET/Socket'`
([what was ported and why](../decisions.md#two-node-vllm)).

Rough guidance:

- **vLLM + NVFP4** — best throughput, highest memory. The default choice here.
- **llama.cpp + GGUF** — smallest footprint, no container, uses the
  `sm_121` build `roles/ml` already made. Best when you want the memory back.
- **SGLang + GGUF** — for its scheduler and structured output.

## Sampling parameters are not a preference

| | temperature | top_p | top_k | presence_penalty |
|---|---|---|---|---|
| Thinking | 1.0 | 0.95 | 20 | 0.0 |
| Instruct | 0.7 | 0.80 | 20 | 1.5 |

Using the wrong set degrades output measurably. Reasoning depth is separate:
`--chat-template-kwargs '{"reasoning_effort":"medium"}'` — `xhigh` is the
default, then `medium`, `low`, `none`.

## Memory: one pool, and everything shares it

Host memory **is** GPU memory. `--gpu-memory-utilization 0.84` claims 84% of
the same 121 GB holding the page cache, your shell and any desktop session
(~1.2 GB of Xorg and gnome-shell).

Consequences worth internalising:

- **Two serving workspaces do not co-exist** at default settings.
- **`nvidia-smi` cannot tell you the budget** — it reports `[N/A]`. `ws check`
  reads `MemAvailable`; watch it live with `gx10-top`.
- **Swap is a cliff, not a slope.** If `gx10-top` shows swap *growing*, stop.
- **A desktop session is worth reclaiming**: `sudo systemctl set-default
  multi-user.target` returns more than most tuning will.

## RL is the tight one

`ray-verl` holds the policy, a reference copy, optimiser state **and** the
rollout engine simultaneously — all in that same pool. The shipped config
therefore targets a **Qwen3-8B-class policy**, not 27B, with
`gpu_memory_utilization: 0.35` for rollouts and both param and optimizer
offload on.

Get a small run green end to end before scaling. A 27B GRPO run does not fit on
one node without heavy sharding, and discovering that costs an afternoon.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `ws check` fails on GPU/memory/docker | The machine is not ready | It names the fix — usually `make apply` |
| `ws: no workspace 'x'` | Typo | `ws list` |
| Image "not pulled yet" | Normal on first run | `ws up` pulls it |
| Weights "NOT cached" | Normal on first run | The engine downloads; 20 GB takes a while |
| vLLM 503s for minutes after start | Weights still loading | Expected; `start_period` is 15m. Watch `ws logs -f` |
| SGLang refuses the NVFP4 model | Quantised `lm_head`, unsupported | Use vLLM, or the GGUF build |
| OOM / swap growing | Two workloads, or utilisation too high | `ws down` the other; lower `GPU_MEMORY_UTILIZATION` in `.env` |
| Ray worker never joins | Head bound to loopback, or peer unreachable | Set `HEAD_IP` in `.env`; check `gx10-interconnect` |
| 2-node vLLM hangs at init | Ranks never met — gloo picked the wrong interface, or flags differ | Both are handled by `vllm-2node-tp2`; if hand-rolling, set `GLOO_SOCKET_IFNAME` |
| 2-node vLLM works but is slow | Fell back to TCP — container missing `/dev/infiniband` or memlock | `grep -E 'NET/IB\|NET/Socket'` in the logs |
| Model server killed under load, no error | `earlyoom` — it targets the largest-RSS process, which is always the server | `make verify` checks this; `systemctl disable --now earlyoom` |

## Provenance

**Every workspace here is currently `unverified`** — written from vendor docs
and the sources in each `workspace.yml`, not from a completed run on this
hardware. `ws list` shows this in yellow.

Expect to fix something on first use. When you do: fix the recipe, flip
`provenance: verified`, and note what changed. That is the same rule the rest
of these docs follow ([provenance](../README.md#provenance)).
