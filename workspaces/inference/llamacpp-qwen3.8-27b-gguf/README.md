# llamacpp-qwen3.8-27b-gguf

> Qwen3.8-27B at 4-bit GGUF, served over the OpenAI API by the `llama-server`
> `roles/ml` already built for `sm_121`. No container, smallest footprint here.

| | |
|---|---|
| Kind | `inference` |
| Engine | llama.cpp (host binary) |
| Nodes | **1** |
| Endpoint | `http://127.0.0.1:8899/v1` |
| Needs | ~24 GB unified · no Docker · no RDMA |
| Provenance | **`verified`** — run on this hardware. Needs `llama_cpp_version` ≥ the one that knows `qwen35`; see below |

## What

Starts `llama-server` in the background against
`unsloth/Qwen3.8-27B-GGUF` (`UD-Q4_K_XL`, ~17–19 GB), with a 256K context and
every layer on the GPU. It writes a pid to `.pid` and a log to
`~/.local/state/ws-llamacpp.log`; `ws down` kills it, after checking the pid is
still `llama-server` and not a recycled number.

There is **no compose file and no image pull**. `roles/ml` compiles llama.cpp
for `sm_121` on the host, and running that binary avoids a second CUDA
userspace inside a container.

**Which makes the host binary's version load-bearing**, in a way a container
recipe's is not. llama.cpp learns a model's architecture in the release that
learns the model, so a pin older than the checkpoint cannot load it:

```
error loading model architecture: unknown model architecture: 'qwen35'
```

That is what `llama_cpp_version: b6100` (2025-08-06) did here, **after
downloading 17.5 GB** — the pin is in `group_vars/all.yml` and it is now
`b10717`, which knows `qwen35`, `qwen35moe` and `deepseek4`. Two things follow:

- **Bumping the pin alone did not use to rebuild.** `roles/ml`'s build task is
  stamped with the version now, because a `creates:` on the binary path let a
  host sit a year behind its own pin with no task reported changed.
- **`up.sh` no longer reports a pid for a process that is already gone.** It
  waits a few seconds, and if `llama-server` exited it prints the end of the
  log and fails — rather than printing a port nothing is listening on.

**Weights land in `$HF_HOME/llama.cpp`, not `~/.cache/llama.cpp`.** `up.sh`
sets `LLAMA_CACHE` for it, so the free-space figure `ws check` measures is the
filesystem the download actually lands on — which matters the moment anyone
takes this repo's own advice and moves `HF_HOME` to a bigger disk.

## Why

Three reasons to reach for this over the vLLM workspace on the same model:

- **It is the cheapest thing here.** ~17–19 GB of weights against NVFP4's
  ~22.6 GB, on a box where every gigabyte you do not spend is a gigabyte the
  page cache, your shell or a second workload can use.
- **It starts in seconds.** No image, no container runtime, no 15-minute
  `start_period`.
- **It is the fallback when a container is the problem.** If the vLLM nightly
  breaks on `aarch64` for a week — which is the bet
  [`vllm-qwen3.8-27b-nvfp4`](../vllm-qwen3.8-27b-nvfp4/README.md) takes — this
  path has no such dependency.

What you give up is batch throughput. vLLM's scheduler is better at holding
many concurrent streams; llama.cpp is better at getting out of the way.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want most of the unified pool back for something else | You want maximum tokens/s under concurrency → [`vllm-qwen3.8-27b-nvfp4`](../vllm-qwen3.8-27b-nvfp4/README.md) |
| You want a served model *now*, with no image pull | You need structured output / a better scheduler → [`sglang-qwen3.8-27b-int4`](../sglang-qwen3.8-27b-int4/README.md) |
| Docker is broken, or you are debugging around it | The model does not fit one node → [two-node serving](../../../docs/runbooks/two-node-serving.md) |
| You are pairing it with an agent or a client workspace | |

## How

```bash
ws check llamacpp-qwen3.8-27b-gguf     # ~24 GB free, and llama-server present
ws up    llamacpp-qwen3.8-27b-gguf
tail -f ~/.local/state/ws-llamacpp.log # `ws logs` is compose-only; this logs to a file
curl -s localhost:8899/v1/models | jq .
ws down  llamacpp-qwen3.8-27b-gguf
```

First run downloads the GGUF into `HF_HOME`; that is the long part, not the
load.

### Sampling is not a preference

The defaults here are Qwen3.8's documented **thinking** parameters. Using the
instruct numbers on a thinking run — or the reverse — degrades output
measurably.

| | temperature | top_p | top_k | min_p |
|---|---|---|---|---|
| Thinking *(the default here)* | 1.0 | 0.95 | 20 | 0.0 |
| Instruct | 0.7 | 0.80 | 20 | 0.0 |

```bash
# .env, gitignored
TEMP=0.7
TOP_P=0.80
```

### Everything else worth setting

| Variable | Default | Note |
|---|---|---|
| `MODEL_REPO` / `MODEL_FILE` | `unsloth/Qwen3.8-27B-GGUF` / `UD-Q4_K_XL` | A different rung of the quant ladder |
| `PORT` | `8899` | Chosen not to collide with 8888/8890/8891 |
| `CTX` | `262144` | KV cache comes out of the same pool as the weights |
| `LOG` | `~/.local/state/ws-llamacpp.log` | |

### Two flags that are already right, and why

`-ngl 999` offloads every layer. On unified memory "offload" is bookkeeping
rather than a copy — there is one pool — but llama.cpp still has to be told,
and leaving layers on the CPU silently halves throughput.

`--n-cpu-moe` and `-ot ".ffn_.*_exps.=CPU"`, which every x86 MoE guide
recommends, are **deliberately absent**. They exist to keep experts in system
RAM when VRAM is scarce. There is no such split on GB10: both sides of it are
the same 121 GB.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `llama-server not found` | `roles/ml` has not run, or `build_llama_cpp` is off | `make apply TAGS=ml` |
| `ws logs` says "no compose.yml" | Correct — this logs to a file | `tail -f ~/.local/state/ws-llamacpp.log` |
| Long silence after `ws up` | First run is downloading ~18 GB | Watch the log |
| Output quality is oddly poor | Wrong sampling set for the mode | See the table above |
| Throughput halves for no reason | Layers left on CPU | `-ngl 999` is the default; check you did not override it |
| `pid … is not llama-server (stale file)` on `ws down` | The process already exited and the pid was recycled | Nothing to do — `down.sh` refuses to signal it, on purpose |

## Sources

- <https://unsloth.ai/docs/models/qwen3.8>

See also: [`workspace.yml`](workspace.yml) · [workspaces overview](../../README.md) ·
[runbook](../../../docs/runbooks/workspaces.md) ·
[capacity planning](../../../docs/runbooks/capacity-planning.md)
