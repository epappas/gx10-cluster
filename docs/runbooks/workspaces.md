# Runbook: run inference and RL environments

**What** — start a served model, a Ray cluster, an RL training run, a serving
benchmark or an agent harness on a machine Ansible has already made ready.
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

**This runbook is the cross-cutting view — how to choose between workspaces and
what they share.** Each workspace also has its own README with its flags, its
tuning knobs and its own failure table; the
[catalogue](../../workspaces/README.md) links all of them.

Two questions have their own runbooks because they are bigger than any one
recipe:

| | |
|---|---|
| **Will this model fit?** | [capacity-planning](capacity-planning.md) |
| **How do I run one across both nodes?** | [two-node-serving](two-node-serving.md) |

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
| **NVFP4** | no | **yes** | **checkpoint-dependent** |
| **GGUF Q4** ~17–19 GB | **yes** | yes | yes |
| **MixedInt4-AutoRound** 20.8 GB | no | **yes** | no |

**"SGLang cannot serve NVFP4" was a claim about the wrong noun**, and this page
used to make it. It is true of `unsloth/Qwen3.8-27B-NVFP4` — a quantised
`lm_head`, which SGLang does not support — and false of NVIDIA's Nemotron 3.5
Lightning NVFP4, which SGLang serves on day 0 on this hardware. Check the
checkpoint, not the engine ([the correction](../decisions.md#nemotron35-lightning)).

| Checkpoint | SGLang |
|---|---|
| `unsloth/Qwen3.8-27B-NVFP4` | **no** — quantised `lm_head`. Use vLLM, or SGLang with GGUF |
| `nvidia/…-Nemotron-3.5-Lightning-30B-A3B-NVFP4` | **yes** — and it is the published GB10 recipe |

**NVFP4 on `sm_121` is a claim about footprint, not about FP4 silicon.** Native
FP4 tensor-core execution is GB200; NVIDIA's hardware table routes DGX Spark
through a W4A16 **Marlin** kernel. NVFP4 is still the right default here — it is
what fits and what is published — but "the format this hardware exists for"
means *small*, not *natively executed*.

**One node or two?** Use `vllm-2node-tp2` when the model does not fit one node
with useful KV cache — the 120B NVFP4 is the worked example. Two-node serving
adds three requirements that all fail *quietly*: the container needs
`/dev/infiniband` and unlimited memlock or NCCL silently falls back to TCP;
`GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME` must be set because gloo ignores
`NCCL_SOCKET_IFNAME`; and both ranks need identical flags or they hang at init.
Confirm the transport with
`docker logs ws-vllm-2node 2>&1 | grep -E 'NET/IB|NET/Socket'`
([what was ported and why](../decisions.md#two-node-vllm)).

**The full procedure — prerequisites, the mechanism, verification and the three
quiet failures — is in [two-node-serving](two-node-serving.md).**

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

## Which DeepSeek-V4, and which quant

| Workspace | Fits? | Use it when |
|---|---|---|
| `vllm-2node-deepseek-v4-flash` | **yes** | The default. FP8 ~149 GiB split TP=2 over RoCE |
| `llamacpp-deepseek-v4-flash-gguf` | **yes** | One node. UD-IQ2_M at 90.9 GB, ~21 GB left |
| `llamacpp-deepseek-v4-pro-gguf` | **from disk** | You want V4-Pro anyway. 1-bit, mmapped, seconds per token |

**V4-Flash: the quant is picked for what it leaves behind.** UD-IQ2_M (90.9 GB)
leaves ~21 GB of a ~112 GB budget — enough for the DSpark draft model (10.9 GB)
*and* a desktop session. UD-IQ3_XXS (104.2 GB) leaves ~8 GB, which is enough for
neither, and speculative decoding is worth more than one rung of quantisation on
a memory-bound box. The full ladder is in the workspace's `.env.example`.

**V4-Pro: the binding constraint is node count, not quantisation.** The smallest
build published anywhere is IQ1_S at 337 GB, against 242 GB of unified memory
across two nodes. No quant closes that gap; 4 nodes (484 GB) is the first sane
configuration. So the workspace mmaps it off NVMe instead — 337 GB fits a stock
1 TB node with ~175 GB spare, while the 2-bit builds (569–587 GB) do not fit at
all. Expect seconds per token, and watch the **disk**, not the GPU.

**V4-Flash-0731 beats V4-Pro on every published agentic benchmark** despite 13B
active parameters against 48B, so choosing Flash is not a downgrade
([the ladders](../decisions.md#deepseek-v4)).

Three things about the two-node Flash recipe that are not guesses:

- **`--max-num-seqs 6`.** Looks absurd next to a normal vLLM deployment. It is
  the honest number for ~22 GiB of KV per node, and it matches the measured
  2× DGX Spark profile.
- **`--max-model-len 131072`, not 1M.** The model supports 1M; that context on
  two GB10s rests entirely on `nvfp4_ds_mla`, which upstream vLLM does not
  have. Asking for 1M on `fp8` does not fail at startup — it fails later, as
  preemption, and reads as "the model got slow".
- **`--tokenizer-mode deepseek_v4` is load-bearing.** V4 ships no Jinja chat
  template; it encodes with Python.

Sampling for V4 is not the Qwen table above: **temperature 1.0, top_p 1.0**
(0.95 for agentic). Reasoning effort is a request field, not a flag:
`--chat-template-kwargs '{"reasoning_effort":"high"}'`.

## Nemotron 3.5 Lightning: 1M context on **one** node

The only 1M-context recipe here that does not need both nodes, and the reason is
architectural. Of 52 layers, **6** are attention (the rest are 23 Mamba-2 and 23
MoE), so only six pay a K/V cost that grows with length and the mamba state is a
flat 716 MiB. At `mem-fraction-static 0.78` the reference GB10 kit reports
**~4.93M pool tokens in ~14.1 GiB** of FP8 KV, ~21 GiB of NVFP4 weights, and 48
concurrent requests.

**The DSpark draft model's KV cache is a separate ~28.2 GiB in bf16 — larger
than the weights, and the biggest single allocation in the server.** So
`SPEC_METHOD=none` is not "give up speed", it is "recover 28 GiB", and it is the
first lever when the pool is the constraint. Lowering `mem-fraction-static` is
the second.

| Workspace | Use it when |
|---|---|
| `sglang-nemotron35-lightning-nvfp4` | You want it as published: 1M window, the measured allocation, DSpark |
| `vllm-nemotron35-lightning-nvfp4` | You want to find out **why** a speculator underperforms — this is the only one with the per-position acceptance ladder |

Three published speculators, ranked by measurement on a DGX Spark (code
generation, single stream / 8 concurrent): `none` 81.3/241.7, `dflash`
95.5/268.6, `mtp` 111.4/302.3, `dspark` **124.2/354.6** tok/s. `dspark` wins on
both axes, which is unusual; `mtp` is the value pick — +37% with no second
checkpoint and no extra KV.

Two traps worth knowing before you copy a flag between them: the reasoning
parser is `nemotron_3` in SGLang and `nemotron_v3` in vLLM, and SGLang serves
**no `/metrics` at all** without `--enable-metrics` — without which
`spec-decode-accept` reports a healthy DSpark server as having no speculative
decoding.

Sampling is not the Qwen table above either. NVIDIA's card says temperature
**1.0**, top_p 0.95; the DGX Spark recipe says 0.6 / 0.95 / top_k 20 /
repetition_penalty 1.08. Use NVIDIA's as the default. Thinking is a request
field: `"chat_template_kwargs": {"enable_thinking": true}`.

## Benchmarking a server (not `make bench`)

`make bench` measures the **hardware**. `ws up vllm-bench-serve` measures a
**model server** — a `vllm bench serve` concurrency sweep against a running
endpoint, rendered live.

```bash
ws up vllm-qwen3.8-27b-nvfp4        # something to bench
ws up vllm-bench-serve              # the default ladder: 1,2,4,8,16,32
ws up vllm-bench-serve -c 1,4,16    # or an explicit one
ws down vllm-bench-serve            # only needed if the TUI was SIGKILLed
```

**Read the live pane, not just the table.** Two states make a result invalid
while leaving the summary JSON looking completely normal:

| On screen | What you actually measured |
|---|---|
| KV cache bar pegged at 100% | Preemption, not throughput |
| `swap N MB - RESULTS ARE NOT VALID` | Paging. On coherent memory this is a cliff |
| Streams in flight well below the concurrency asked for | A client-side limit, not a slow model |

**The `NODES` pane covers every Spark, including the ones you are not sitting
at.** A two-node server has one endpoint, so the load and the `/metrics`
counters already describe the whole deployment — but GPU, memory and swap are
per-machine, and rank 1 swapping invalidates a run exactly as much as rank 0
does. Nodes come from `/etc/gx10/interconnect.peers`, so a third and fourth node
appear with no configuration. Swap is judged on **growth**: `swap 120 MB, not
growing` is fine, `swap +N MB SINCE START` is not.

The one setting worth knowing: `TOKENIZER`. `MODEL` is the **served** name and
is discovered from `/v1/models`, but a tokenizer cannot be loaded from
`qwen3.8-27b`. If the server was started with `--served-model-name`, set
`TOKENIZER` to the HF repo id in `.env` — otherwise the run dies several
minutes in with a HF 404.

Results land in `~/.local/state/gx10-bench`: JSON per point plus an HTML
timeline, which is better than the TUI at per-request forensics.

**On a speculative server, read the acceptance row.** A broken draft path costs
acceptance and nothing else — the target model still verifies every token — so
the server stays perfectly correct at half the speed, which reads as bad
hardware rather than a bad draft.

## Which GLM, and why it is the odd one out

There is one: [`vllm-2node-glm53-flash-exl3`](../../workspaces/inference/vllm-2node-glm53-flash-exl3/README.md).
It is worth knowing two things before reaching for it.

**It is the only workspace here that does not run an upstream image.** Upstream
vLLM cannot serve this checkpoint at all — no `exl3` quantisation method, and it
dies on the first forward because the model is NoPE MLA while the only SM12x
sparse-MLA backend expects a RoPE section. Neither is reachable from a flag, so
declining the overlay image costs the model rather than a few percent of decode
([the full argument](../decisions.md#glm53-flash)).

**Its context budget is hybrid**, so the usual tuning move is backwards: 1M
context allocates on ~19 GB of KV per node, and dropping `MAX_MODEL_LEN` to
"free" KV shrinks the pool ([why](capacity-planning.md#two-models-arithmetic-does-not-follow-the-rules-above)).

Two values have no alternative on this hardware: `--kv-cache-dtype fp8` (the
SM12x sparse-MLA kernel takes nothing else — **not** bf16, and **not** the NVFP4
KV that exists on this arch as a *dense* kernel), and
`--max-num-batched-tokens 2048` (8192-token prefill chunks oversubscribe the
GB10 indexer top-k and crash a long prompt around 300k).

## Gating a server: right, not just fast

```bash
ws up vllm-quality-gate                 # BASE_URL, or the default :8888
ws up vllm-quality-gate -c 1,8 -n 8     # wider ladder, more requests per rung
ws up vllm-quality-gate --warm          # the control run, which should pass
```

Different question from the benchmark above: not *how fast*, but *is the answer
usable*. It looks for serving-layer faults that move no tok/s number — replies
that open mid-word or echo the prompt, replies that are empty while the whole
budget was billed, script drift, reasoning that never terminates.

**It forces the conditions a smoke test cannot.** These failures need a cold
prefill (a prefix-cache hit never fails, so asking twice looks self-healing) or
concurrency. So every request carries a unique nonce at the *front* of the
prompt to invalidate the cache chain behind it, and the run climbs a ladder.
It then checks it really was cold, off `vllm:prefix_cache_hits`.

It **exits non-zero** if anything tripped a detector, so it belongs in front of
a deployment: `ws up vllm-quality-gate && <promote>`.

If a run comes back all-empty, raise `MAX_TOKENS` before believing it — with
reasoning on, a budget that expires before `</think>` yields an empty reply and
a full bill. Below ~1024 you are measuring your own cap
([detail](serve-models.md#the-answers-are-wrong-not-slow)).

## Proving the drafter: acceptance per position

```bash
BASE_URL=http://127.0.0.1:8893/v1 ws up spec-decode-accept
```

The third failure a serving stack can have, and the quietest. A **broken draft
path costs acceptance and nothing else** — the target model still verifies every
token, so the answers stay correct and you simply get half the speed. The
benchmark above shows the aggregate number; this breaks it down by draft
**position**, which is what separates the two causes:

| Shape, **on structured output** | Means |
|---|---|
| Every position low, position 0 included | Weak drafter — wrong draft weights, or weights that never loaded |
| Position 0 **healthy**, 1..k−1 **collapsed** | A causal mask inside a *non-causal* draft block |

**The class qualifier is load-bearing.** Acceptance is a property of the text: a
healthy server measures ~0.92 on structured output and ~0.33 on prose, and its
healthy *prose* ladder decays to 0.06 — the same shape a broken mask makes. So
the collapse convicts only on structured output, and the tool refuses to return
a mask verdict for any other class.
[Full detail](../../workspaces/bench/spec-decode-accept/README.md).

## The other half of a request: cold prefill

```bash
BASE_URL=http://127.0.0.1:8893/v1 ws up vllm-prefill-ladder --chunk-tokens 2048
```

Everything above measures **decode**. On a long-context server that is not where
the time goes — a 100k-token prompt spends roughly a hundred seconds in prefill
before a single character appears, and then decodes at whatever the benchmark
already told you. This puts a number on the wait.

**The reason it is a check and not a stopwatch:** every serving workspace here
runs with `--enable-prefix-caching`, so sending the same prompt twice does not
measure prefill twice. Measured on the kit the protocol comes from, rerunning a
"cold" ladder unchanged took TTFT from **10.3 s to 1.9 s** — a 5× improvement
produced by nothing, which looks exactly like a flag that worked. So each cold
prompt carries a fresh UUID salt *first* in the message (position matters — a
salt at the end shares every preceding block), and the prefix-cache counters are
read across every request. A rung that hit the cache is reported `INVALID`, not
fast.

The follow-up row measures the opposite: reuse, against a **page model** rather
than as a percentage. Hits are block-aligned, so a 7.7k-token conversation
reuses `floor(7717/3584) × 3584 = 7168` tokens and computes the rest every turn.
`hit_efficiency` of 1.00 means nothing is being lost; anything else usually
means the page size assumed is not this server's, and the tool prints the sizes
consistent with what it saw.

`--chunk-tokens` adds a **seconds per chunk** column, which is the quantity to
A/B when tuning `--max-num-batched-tokens`.
[Full detail](../../workspaces/bench/vllm-prefill-ladder/README.md).

## Using it: the agent harness

```bash
ws up vllm-2node-deepseek-v4-flash    # the model
cd workspaces/agent/deepseek-harness
cp settings.example.yaml dsh-home/settings.yaml   # then edit baseURL + model
cd -
ws up deepseek-harness                # -> http://127.0.0.1:3080
ws logs deepseek-harness -f
```

`kind: agent` claims no GPU and no unified memory, so it coexists with a
serving workspace — unlike two inference workspaces. `settings.yaml` is the
whole point of it: a custom provider whose `baseURL` is your own server, so no
token leaves the house.

It is an **agent harness on host networking**: it executes tool calls against
whatever is mounted at `/work`. The default is an empty `./work` directory.
Point `DSH_WORKSPACE` at a project, not at `$HOME`.

If the UI sits on "Thinking…" until the whole answer lands, that is a field
name, not a stall: these runtimes stream the trace as `reasoning` while
OpenAI-compatible clients read `reasoning_content`.

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
| SGLang refuses **that** NVFP4 model | Quantised `lm_head`, unsupported — checkpoint-specific, not an SGLang limit | Use vLLM, or the GGUF build. Nemotron 3.5 Lightning NVFP4 loads fine there |
| OOM / swap growing | Two workloads, or utilisation too high | `ws down` the other; lower `GPU_MEMORY_UTILIZATION` in `.env` |
| Ray worker never joins | Head bound to loopback, or peer unreachable | Set `HEAD_IP` in `.env`; check `gx10-interconnect` |
| 2-node vLLM hangs at init | Ranks never met — gloo picked the wrong interface, or flags differ | Both are handled by `vllm-2node-tp2`; if hand-rolling, set `GLOO_SOCKET_IFNAME` |
| 2-node vLLM works but is slow | Fell back to TCP — container missing `/dev/infiniband` or memlock | `grep -E 'NET/IB\|NET/Socket'` in the logs |
| Model server killed under load, no error | `earlyoom` — it targets the largest-RSS process, which is always the server | `make verify` checks this; `systemctl disable --now earlyoom` |
| `ws check` fails on disk, not memory | The weights do not fit the NVMe — a 2-bit V4-Pro is ~570 GB | Use the default 1-bit (337 GB), point `HF_HOME` at external storage, or run V4-Flash |
| A peer shows `no sample` in the bench NODES pane | SSH to it failed, or it is still starting | `ssh <peer> true`; a rebooting node recovers on its own |
| Bench dies minutes in with a HF 404 | `--served-model-name` ≠ the HF repo id, so the tokenizer cannot be fetched | Set `TOKENIZER` in the bench workspace's `.env` |
| Bench numbers look great but KV was pegged at 100% | You measured preemption | Lower `--max-model-len` or `--max-num-seqs`, then re-run |
| Bench keeps loading the server after you quit | The TUI was SIGKILLed, so its cleanup never ran and the container outlived it | `ws down vllm-bench-serve` |
| `dsh` web UI never answers on :3080 | First start downloads the npm tree; `start_period` is 3m | `ws logs deepseek-harness -f` |
| `dsh` cannot reach the model | `baseURL` in `dsh-home/settings.yaml`, or an empty API key | It is host networking — if `curl` works from your shell, the same URL works |

## Provenance

**Every workspace here is currently `unverified`** — written from vendor docs
and the sources in each `workspace.yml`, not from a completed run on this
hardware. `ws list` shows this in yellow.

Expect to fix something on first use. When you do: fix the recipe, flip
`provenance: verified`, and note what changed. That is the same rule the rest
of these docs follow ([provenance](../README.md#provenance)).
