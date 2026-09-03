# Workspaces

Runnable recipes for inference, cluster and RL environments. **Not Ansible.**

```bash
./workspaces/ws list                        # what exists, and what has been run
./workspaces/ws check vllm-qwen3.8-27b-nvfp4  # does THIS machine qualify?
./workspaces/ws up    vllm-qwen3.8-27b-nvfp4
./workspaces/ws logs  vllm-qwen3.8-27b-nvfp4 -f
./workspaces/ws down  vllm-qwen3.8-27b-nvfp4
```

## The catalogue

**Every workspace has its own README** answering what it is, why it exists, when
to reach for it and how to run it. Start there — this page is the map, those are
the territory.

### `inference` — these start a model, and no two co-exist

| Workspace | Nodes | Memory | Port | For |
|---|---|---|---|---|
| [`vllm-qwen3.8-27b-nvfp4`](inference/vllm-qwen3.8-27b-nvfp4/README.md) | 1 | ~40 GB | 8888 | **The single-node default.** NVFP4, the format this hardware exists for |
| [`llamacpp-qwen3.8-27b-gguf`](inference/llamacpp-qwen3.8-27b-gguf/README.md) | 1 | ~24 GB | 8899 | Cheapest here. No container, host binary, starts in seconds |
| [`sglang-qwen3.8-27b-int4`](inference/sglang-qwen3.8-27b-int4/README.md) | 1 | ~40 GB | 8900 | SGLang's scheduler on this model. INT4 W4A16 — [the only format of three that loads](inference/sglang-qwen3.8-27b-int4/README.md#three-formats-and-only-one-of-them-works) |
| [`vllm-2node-tp2`](inference/vllm-2node-tp2/README.md) | **2** | ~40 GB/node | 8888 | The **generic** two-node recipe. Bring your own model |
| [`vllm-2node-deepseek-v4-flash`](inference/vllm-2node-deepseek-v4-flash/README.md) | **2** | ~100 GB/node | 8890 | **The DeepSeek default.** FP8 across the cable, DSpark drafts |
| [`llamacpp-deepseek-v4-flash-gguf`](inference/llamacpp-deepseek-v4-flash-gguf/README.md) | 1 | ~96 GB | 8891 | V4-Flash on one node at 2-bit, with room for drafts |
| [`llamacpp-deepseek-v4-pro-gguf`](inference/llamacpp-deepseek-v4-pro-gguf/README.md) | 1 | ~32 GB + **360 GB disk** | 8892 | 1-bit V4-Pro straight off the NVMe — 0.67 tok/s, 7 GB resident. [How](inference/llamacpp-deepseek-v4-pro-gguf/README.md#four-blockers-and-what-each-one-actually-was) |
| [`vllm-2node-glm53-flash-exl3`](inference/vllm-2node-glm53-flash-exl3/README.md) | **2** | **~106 GB/node** | 8893 | **The GLM default.** EXL3 4bpw, **1M context**, vision, DFlash2 drafts |
| [`sglang-nemotron35-lightning-nvfp4`](inference/sglang-nemotron35-lightning-nvfp4/README.md) | 1 | ~96 GB | 8894 | **1M context on ONE node.** NVFP4 + DSpark, as published |
| [`vllm-nemotron35-lightning-nvfp4`](inference/vllm-nemotron35-lightning-nvfp4/README.md) | 1 | ~98 GB | 8895 | The same model where the **acceptance ladder** works |

### `bench` and `agent` — clients, which **do** co-exist with a server

| Workspace | For |
|---|---|
| [`vllm-bench-serve`](bench/vllm-bench-serve/README.md) | How many streams before latency falls over — rendered **live**, because the numbers that invalidate a run are transient |
| [`vllm-quality-gate`](bench/vllm-quality-gate/README.md) | Is it answering **correctly**? Exits non-zero if not |
| [`spec-decode-accept`](bench/spec-decode-accept/README.md) | Is the **speculative decoder** working? Acceptance per draft **position** — the one failure that costs speed and nothing else |
| [`vllm-prefill-ladder`](bench/vllm-prefill-ladder/README.md) | How long until the **first** character? Cold prefill tok/s, **proven** cold — the prefix cache makes a rerun look like an optimisation |
| [`deepseek-harness`](agent/deepseek-harness/README.md) | An agent harness pointed at your own server. **Then use the thing you built** |
| [`pi-harness`](agent/pi-harness/README.md) | The same idea **in your terminal**, and in a pipe: `-p`, JSON and RPC modes |
| [`exo-harness`](agent/exo-harness/README.md) | An agent that **rewrites itself** — its own source, mounted in its own sandbox |

### `cluster` and `rl`

| Workspace | For |
|---|---|
| [`ray`](cluster/ray/README.md) | An **ephemeral** containerised Ray cluster. Not `roles/ray` |
| [`slurm`](cluster/slurm/README.md) | Job scripts for the Slurm Ansible installs. Daemons stay with Ansible |
| [`ray-verl`](rl/ray-verl/README.md) | **`blocked`** — the stack runs; Qwen3-8B + a co-resident rollout does not fit 121 GB. [The measurements](rl/ray-verl/README.md#what-actually-happens-on-a-gb10) |

**Running across two nodes?** The mechanism, the prerequisites and the three
things that fail *quietly* are in
[the two-node serving runbook](../docs/runbooks/two-node-serving.md).
**Not sure it will fit?**
[capacity-planning](../docs/runbooks/capacity-planning.md).

## Why this is separate from `roles/`

Two different jobs on two different clocks:

| | `roles/` (Ansible) | `workspaces/` |
|---|---|---|
| Converges | a **machine** to a state | nothing — it **runs** things |
| Frequency | rare, privileged, slow | constant, unprivileged, fast |
| Answers | "is this box ready?" | "what am I running today?" |
| Failure | the node is broken | today's experiment is broken |

What you run changes far more often than the machine does. Coupling them means
every experiment needs a playbook run, and every recipe is reproducible only
through Ansible. So Ansible stops at *ready* and workspaces take it from there.

**The only coupling is the `requires:` block**, checked by `ws check`. No
workspace reads anything from `roles/`, and no role knows a workspace exists.
Every recipe is plain `docker`/`compose` or a plain command — read it, copy it,
run it by hand without `ws` if you prefer.

## The engine × quantisation matrix

The single most expensive thing to learn the hard way here:

| | llama.cpp | vLLM | SGLang |
|---|---|---|---|
| **NVFP4** | no | **yes** | **checkpoint-dependent** — see below |
| **GGUF Q4** (~17–19 GB) | **yes** | yes | **architecture-dependent** — see below |
| **MixedInt4-AutoRound** (20.8 GB) | no | **yes** | no |
| **EXL3 / TR3** (4 bpw) | no | **overlay image only** | no |

GB10 is Blackwell (`sm_121`), so NVFP4 is the format this hardware exists for.
**On `sm_121` that is a claim about memory footprint, not about FP4 silicon** —
native FP4 tensor-core execution is GB200, and NVIDIA's own hardware table
routes DGX Spark through a **W4A16 Marlin** kernel. It is still the right
default: smaller, published everywhere, and no third-party image needed.

**The SGLang cell used to read "NO — quantised `lm_head`", and that was a claim
about the wrong noun.** It is true of `unsloth/Qwen3.8-27B-NVFP4` — which is
why [`sglang-qwen3.8-27b-int4`](inference/sglang-qwen3.8-27b-int4/README.md)
exists — and false of NVIDIA's Nemotron 3.5 Lightning NVFP4, which SGLang
serves on day 0 on this hardware. A negative result measured on one checkpoint
is not a capability claim about an engine
([the correction](../docs/decisions.md#nemotron35-lightning)).

| Checkpoint | SGLang | Because |
|---|---|---|
| `unsloth/Qwen3.8-27B-NVFP4` | **no** | quantised `lm_head` |
| `unsloth/Qwen3.8-27B-GGUF` | **no** | `transformers`' GGUF reader has no `qwen35` |
| `RedHatAI/Qwen3.8-27B-INT4` | **yes** | compressed-tensors W4A16, SGLang's own quant path, unquantised `lm_head` |
| `Qwen/Qwen3.8-27B` (BF16) | **yes** | but 4.3 tok/s — 54 GB against ~273 GB/s |
| `nvidia/…-Nemotron-3.5-Lightning-30B-A3B-NVFP4` | **yes** | day-0 support, published GB10 operating point |

**The GGUF cell is architecture-dependent for the same shape of reason.**
SGLang reads GGUF through `transformers`, whose `GGUF_CONFIG_MAPPING` knows 25
architectures — `qwen2`, `qwen2_moe`, `qwen3`, `qwen3_moe`, and not `qwen35`.
That refusal was measured here, after the 17.5 GB file downloaded. **But the
architecture was never the problem** — the NVFP4 attempt failed while matching
parameter *names*, which means SGLang had already built
`Qwen3_5ForConditionalGeneration`, so any format whose weights it can read was
always going to serve. `sglang-qwen3.8-27b-int4` is `verified` on
`RedHatAI/Qwen3.8-27B-INT4` at 13.2 tok/s single-stream and 142 tok/s at 16
([the detail](inference/sglang-qwen3.8-27b-int4/README.md#three-formats-and-only-one-of-them-works)).
llama.cpp has the same class of limit and it is a **version** rather than a
wall — `qwen35` landed there, which is why `llama_cpp_version` is pinned past
it.

**EXL3 is the one row upstream vLLM cannot do at all**, which is why the last
row says *overlay image*. It is not a fallback for when NVFP4 is unavailable —
on the one model here where both exist, a published KLD panel puts EXL3 4bpw at
**~2.5× less divergence than NVFP4 at the same size**
([the numbers](inference/vllm-2node-glm53-flash-exl3/README.md#why-exl3-when-this-hardware-exists-for-nvfp4)).
NVFP4 remains the right default everywhere it is published, because it is
native, fast and needs no third-party image; this is the exception, and it is
the only one ([why](../docs/decisions.md#glm53-flash)).

## Nemotron 3.5 Lightning: a 1M window that fits **one** node

Every other 1M-context recipe here needs both nodes. This one does not, and the
reason is architectural rather than a quantisation trick: of its 52 layers only
**6** are full attention (23 Mamba-2 SSM + 23 MoE + 6 attention), and only those
six pay a K/V cost that grows with sequence length. The mamba state is a fixed
716 MiB whatever you ask for.

| | On one GB10, at `mem-fraction-static 0.78` |
|---|---|
| Weights (NVFP4, target + DSpark draft) | ~21.0 GiB — **21.6 + 1.3 GB on disk** |
| Target KV, **FP8 `e4m3fn`**, ~3 KB/token | ~14.1 GiB → **~4.93M pool tokens** |
| **DSpark draft KV, `bf16`, separate** | **~28.2 GiB** |
| Mamba/SSM cache | 716 MiB |
| Concurrency, derived at boot | **48** |

**A 1.3 GB draft model allocates a 28 GiB KV cache** — the largest single
allocation in the server, bigger than the 30B target it drafts for. So
`SPEC_METHOD=none` is not "give up speed", it is "recover 28 GiB", and it is
the right first move when the pool is the binding constraint. Lowering
`mem-fraction-static` is the second.

**None of those numbers are constants.** They are startup-time outcomes of
`mem-fraction-static` computed against whatever was free at boot, which is why
the workspace ships `./report.sh` rather than a table to quote.

### Three published speculators, and they are not interchangeable

Measured on a DGX Spark, code generation, single stream / 8 concurrent:

| | conc. 1 | conc. 8 | Costs |
|---|---:|---:|---|
| `none` | 81.3 tok/s | 241.7 tok/s | nothing. **Throughput-optimal** |
| `dflash` | 95.5 | 268.6 | a second checkpoint |
| `mtp` | 111.4 | 302.3 | **nothing extra** — the model's own heads |
| `dspark` | **124.2** | **354.6** | ~28 GiB of bf16 draft KV |

`dspark` wins on **both** axes, which is unusual — speculative decoding
normally trades throughput for latency. Those are code-generation numbers with
thinking off; acceptance is a property of the text, so re-measure before
treating the ranking as general.

### Which of the two workspaces

| | Use |
|---|---|
| Run it the way its authors published it — 1M window, measured allocation | [`sglang-nemotron35-lightning-nvfp4`](inference/sglang-nemotron35-lightning-nvfp4/README.md) |
| Find out **why** a speculator is underperforming | [`vllm-nemotron35-lightning-nvfp4`](inference/vllm-nemotron35-lightning-nvfp4/README.md) — the only one with the per-position ladder |

SGLang publishes accept **length** and no per-position counters, so
[`spec-decode-accept`](bench/spec-decode-accept/README.md) degrades honestly
there: it can convict an idle drafter, not a broken draft mask. And SGLang
serves no `/metrics` at all without `--enable-metrics`, which that workspace
passes for exactly this reason.

## One node or two?

| | Use |
|---|---|
| Model fits one node with useful KV cache | `vllm-qwen3.8-27b-nvfp4` — simpler, no fabric involved |
| Model does **not** fit, or KV cache is starved | `vllm-2node-tp2` — tensor-parallel across the cable |

The 120B NVFP4 is the worked example: 75 GB of weights against ~110 GB
available leaves ~35 GB for KV on one node, which is not worth doing. Split
across two, each holds ~37 GB and the KV budget roughly triples.

**Two-node serving has three requirements single-node does not**, and all three
fail quietly rather than loudly:

1. **`--device /dev/infiniband` and `--ulimit memlock=-1` on the container.**
   Without the device nodes, ibverbs finds no adapter *inside the container* and
   NCCL falls back to TCP. It still works — at a fraction of the speed — so it
   looks like a slow model, not a broken config.
2. **`GLOO_SOCKET_IFNAME` and `TP_SOCKET_IFNAME`.** vLLM's distributed init is
   `torch.distributed`, and gloo does **not** read `NCCL_SOCKET_IFNAME`. Unset,
   it can pick `docker0` or the VPN and the ranks never meet.
3. **Identical image and flags on both ranks.** Mismatched ranks hang at init.
   Every two-node workspace launches both ranks from one script so this cannot
   drift.

All three live in `workspaces/lib/twonode.sh`, which is the **one recipe here
that is not standalone**. Two workspaces each carrying their own copy of this
wiring would drift exactly the way two ranks do — slowly, and silently. A
workspace supplies `MODEL_ARGS` and nothing else
([why](../docs/decisions.md#twonode-lib)) — plus, for the one image that needs a
step run *inside* the container before `vllm serve`, a `PRE_EXEC` snippet the
library splices in front of a serve line it still assembles itself.

Always confirm the transport rather than assuming it:

```bash
docker logs ws-vllm-2node 2>&1 | grep -E 'NET/IB|NET/Socket'
```

`NET/IB` is ibverbs and covers RoCE — that is what you want. `NET/Socket` means
you are on TCP.

## Sampling: thinking vs instruct is not a preference

Qwen3.8 ships two documented parameter sets and using the wrong one degrades
output quality measurably:

| | temperature | top_p | top_k | presence_penalty |
|---|---|---|---|---|
| Thinking | 1.0 | 0.95 | 20 | 0.0 |
| Instruct | 0.7 | 0.80 | 20 | 1.5 |

Reasoning depth is separate: `--chat-template-kwargs '{"reasoning_effort":"medium"}'`
(`xhigh` default, then `medium`, `low`, `none`).

## Memory is the constraint, and it is one pool

On GB10 host memory **is** GPU memory. A serving workspace taking
`--gpu-memory-utilization 0.84` is claiming 84% of the same 121 GB that holds
the page cache, your shell, and any desktop session (~1.2 GB for Xorg and
gnome-shell). Two workspaces at those settings do not co-exist.

This is why `ws check` reads `MemAvailable` rather than asking `nvidia-smi`,
which reports `[N/A]` for memory on this hardware and cannot answer the
question. Watch it with `gx10-top`.

## DeepSeek-V4: the quant is chosen by the memory budget

Sizes are the sum of a repo's shards, from its own file listing:

| | Params (active) | Smallest published | On 2× GB10 (242 GB) |
|---|---|---|---|
| **V4-Flash** | 284B (13B) | UD-IQ1_S 82.5 GB · FP8 ~149 GiB | **fits** |
| **V4-Pro** | 1.57T (48B) | **IQ1_S 337 GB** | **no — not at any quant** |

| Workspace | Use it when |
|---|---|
| `vllm-2node-deepseek-v4-flash` | **The default.** FP8 across both nodes, TP=2 over RoCE, DSpark drafts |
| `llamacpp-deepseek-v4-flash-gguf` | One node. UD-IQ2_M at 90.9 GB, with ~21 GB left — enough for the draft model too |
| `llamacpp-deepseek-v4-pro-gguf` | You want V4-Pro anyway. 1-bit, mmapped off NVMe, seconds per token |

**For V4-Pro the binding constraint is node count, not quantisation.** Even
1-bit is 337 GB against 242 GB of unified memory — two nodes cannot hold it, and
no smaller build exists. Adding nodes moves that line: 4 nodes (484 GB) is the
first sane configuration. Picking a different quant does not.

| Nodes | Unified | Smallest V4-Pro that fits in RAM |
|---|---|---|
| 2 | 242 GB | none |
| 3 | 363 GB | IQ1_S (337), nothing left for KV |
| 4 | 484 GB | IQ1_S / IQ1_M |
| 5 | 605 GB | Q2_K (569), tight |

So the V4-Pro workspace runs it from **NVMe** instead, and the quant is chosen by
the disk: 337 GB fits a stock 1 TB node with ~175 GB spare, while the 2-bit
builds (569–587 GB) do not fit at all. That is also the performance ceiling —
~10 GB of expert weights read per token, which is *arithmetic, not a
measurement*.

**V4-Flash-0731 beats V4-Pro on every published agentic benchmark** despite 13B
active against 48B. If quality matters more than running it at all, the answer
is not a different quant — it is Flash. Full ladders and reasoning:
[#deepseek-v4](../docs/decisions.md#deepseek-v4).

Two flags that mislead in opposite directions here:

- **`--no-mmap`** is worth testing on every other model and is *fatal* for
  V4-Pro — it means "read 337 GB into memory".
- **`--n-cpu-moe` / `-ot ".ffn_.*_exps.=CPU"`**, which every x86 MoE guide
  recommends, do nothing on GB10. They keep experts in system RAM when VRAM is
  scarce; here both sides of that split are the same 121 GB.

## GLM-5.3-Flash: 1M context on 19 GB of KV, and the one third-party image

`vllm-2node-glm53-flash-exl3` is the odd one out here twice over, and both are
worth understanding before you reach for it.

**It does not run an upstream image.** Everything else in this directory runs
`vllm/vllm-openai` or a distro binary. Upstream vLLM cannot serve this
checkpoint at all — it has no `exl3` quantisation method, and it dies on the
first forward with `pe_dim must be 64 for fp8_ds_mla` because GLM-5.3-Flash is
NoPE MLA while the only SM12x sparse-MLA backend expects a record with a RoPE
section. Neither is reachable from a flag. This repo declines forks by default
and [says why](../docs/decisions.md#two-node-vllm); the difference here is that
declining costs the model rather than 8% of its decode speed
([the full argument](../docs/decisions.md#glm53-flash)).

**Its context arithmetic does not work like the others.** ~164 GiB of weights
split two ways leaves ~19 GB of KV per node — the smallest budget in this repo
— and **1M context still allocates on it**:

| Piece | Cost | Scales with context? |
|---|---|---|
| Target MLA, 12 layers | packed `fp8_ds_mla`, 656 B/token/layer | **yes** |
| Mamba, 33 layers | window / state | **no** |
| DFlash2 drafter, 5 layers | bf16, ~2 KB/token | window-bounded |

A hybrid model's pool is a **large fixed floor plus a small slope**, so a big
cap is much cheaper here than on a dense model — and shrinking the cap does not
refund the floor. Reported occupancy: 36k → 16%, 256k → ~25%, 300k → 26%.

**So `MAX_MODEL_LEN=256000` is the first wrong move.** The logged pool is
roughly *concurrency × the cap*: a smaller cap shrinks the number it was
supposed to grow, and everything underneath stays where it was.

Two more values with no alternative on this hardware:

- **`--kv-cache-dtype fp8`**, because the SM12x sparse-MLA kernel accepts only
  packed `fp8_ds_mla`. bf16 KV has **no sparse kernel on this arch**, and NVFP4
  KV — which does exist on SM12x — is a **dense MHA** kernel, not sparse MLA.
- **`--max-num-batched-tokens` capped well below 8192**, because 8192-token
  prefill chunks oversubscribe the GB10 indexer top-k's shared memory and crash
  a long prompt around 300k tokens. That ceiling is a kernel limit, not a
  throughput preference. The value *under* it is measured rather than chosen:
  the shipped default is **2048**, which the published cold-prefill ladder puts
  +16% over 1024 at 8k — and 3584 and 4096 both below it
  ([the table](inference/vllm-2node-glm53-flash-exl3/README.md)).

## Benchmarking a server, which is not `make bench`

| | `make bench` | `ws up vllm-bench-serve` |
|---|---|---|
| Measures | the **hardware** — NCCL, RDMA, fio, DCGM | a **model server** |
| Answers | is this cluster fit to run work? | how many concurrent streams before latency falls over? |

`vllm-bench-serve` drives `vllm bench serve` across a concurrency ladder and
renders the run live, because on unified memory the numbers that decide whether
a result is *valid* are transient and absent from the summary table:

```
  LIVE
    streams in flight     [########--] 80%    8 of 10, 2 queued
    KV cache              [#########-] 91%
                                       ▁▂▄▅▆▇▇█
    decode tok/s                            412  ▃▅▇▇▆▇██
    GPU util              [#########-] 96%   89.3W  71C
    unified memory        [########--] 82%   no swap

  CONC  OUT TOK/S        tok/s   TTFT ms   ITL ms   req/s
  1     [##--------]     142.3     118.0     12.1    0.71   16/16 ok
  2     [####------]     286.1     151.0     12.9    1.38   16/16 ok
  4     [#######---]     498.4     168.4     14.2    2.61   32/32 ok
```

A KV bar pegged at 100% means that point measured **preemption**, not
throughput. Swap growing means it measured **paging**. Both produce a
perfectly normal-looking summary JSON, which is the whole argument for watching
it happen ([why](../docs/decisions.md#serving-bench)).

**It covers every Spark, not just the one you typed on.** A tensor-parallel
server has one endpoint — rank 0 serves, rank 1 is headless — so the load and
the `/metrics` counters already describe the whole deployment. Host telemetry
does not, and *rank 1 swapping invalidates a run exactly as much as rank 0
swapping does*. The `NODES` pane therefore samples this host plus everything in
`/etc/gx10/interconnect.peers`, so a third and fourth node need no
configuration:

```
  NODES (all 2 - a peer that swaps invalidates the run too)
    odysseus  gpu [#########-] 96%   mem [########--] 82%   89.3W  71C  no swap
    poseidon  gpu [#########-] 94%   mem [########--] 80%   86.1W  69C  swap 120 MB, not growing
```

Swap is judged on **growth**, not presence — a node holding swap from last week
is not a failing benchmark, and flagging it trains you to ignore the row that
matters.

The HTML timeline (`--plot-timeline`) is still written per point — it is better
than this at per-request forensics, and this is better at watching the machine.

**On a speculative server, watch acceptance.** It is the number that explains
the throughput, and its absence is what makes the worst failure here so hard to
place: a broken draft path costs acceptance and *nothing else*, because the
target model still verifies every token. Output stays perfectly correct at half
the speed — which reads as bad hardware or a bad recipe, and sends people to
rewrite flags.

## Fast is not the same as correct: `vllm-quality-gate`

| | `vllm-bench-serve` | `vllm-quality-gate` |
|---|---|---|
| Asks | how many streams before latency falls over | is it answering **correctly** |
| Fails when | throughput collapses | a reply is garbled, empty, looping or off-contract |
| Exit status | informational | **non-zero if any request tripped a detector** |

The failures it looks for are serving-layer, not model quality — scheduler,
speculative decoder, reasoning parser — and none of them moves a tok/s number:
replies that open mid-word or echo the prompt, replies that are empty while the
whole budget was billed, script drift, reasoning that never terminates.

**A five-prompt smoke test cannot find them**, and that is the whole design:

- **Cold prefill.** The corruption attaches to the last chunk of a long *first*
  prefill. A prefix-cache hit never fails, so asking twice makes it look
  self-healing — and the clean second answer is the one you believe.
- **Concurrency.** Several appear only with more than one sequence in flight.

So every request carries a unique nonce as the *first* thing in the prompt,
which invalidates the whole prefix-cache block chain behind it, the filler is
long enough to be genuinely chunk-prefilled, and the gate runs a concurrency
ladder. Then it checks it got the cold run it claims, off
`vllm:prefix_cache_hits` — an assertion nobody verifies is a comment.

```bash
ws up vllm-2node-deepseek-v4-flash
BASE_URL=http://127.0.0.1:8890/v1 ws up vllm-quality-gate
ws up vllm-quality-gate --warm      # the control run, which should pass
```

Two things it does that are easy to get wrong by hand. It reads
`usage.completion_tokens` from a **non-streamed** reply, because under
speculative decoding a server emits at most one SSE chunk per decode *step*
carrying every token accepted in it — counting streamed deltas measures
steps/s and under-reports by the acceptance length. And it reads `reasoning`
**or** `reasoning_content`, because this family of runtimes returns the first
and OpenAI-compatible clients expect the second.

The detectors are pure functions over text, so they are tested offline in
`make check` ([why](../docs/decisions.md#quality-gate)) — a gate that has
quietly stopped being able to fail is worse than no gate.

## Fast, correct — and actually *drafting*: `spec-decode-accept`

There is a third way for a serving stack to be wrong, and it is the quietest of
the three. A **broken draft path costs acceptance and nothing else**: the target
model still verifies every token, so the answers stay perfectly correct and the
server reports no error. You get half the speed, which reads as bad hardware or
a bad recipe.

| | measures | notices a broken drafter? |
|---|---|---|
| `vllm-bench-serve` | throughput | it shows the aggregate number — so, partly |
| `vllm-quality-gate` | correctness | **no** — the output is correct |
| `spec-decode-accept` | acceptance **per draft position** | **yes, and says which kind** |

The per-position ladder is the resolution the aggregate cannot give, because it
separates the two failures that need different fixes:

| Shape, **on structured output** | Means |
|---|---|
| Every position low, position 0 included | Weak drafter — wrong draft weights, or weights that never loaded |
| Position 0 **healthy**, 1..k−1 **collapsed** | A causal mask inside a *non-causal* draft block |

```bash
ws up vllm-2node-glm53-flash-exl3
BASE_URL=http://127.0.0.1:8893/v1 ws up spec-decode-accept
```

**The class qualifier in that table is load-bearing.** Acceptance is a property
of the text, and both of these are published medians from the *same healthy
server*:

| Class | pos 0 → 6 | aggregate |
|---|---|---:|
| Structured | 0.98 0.98 0.94 0.94 0.91 0.83 0.83 | 0.92 |
| Prose | 0.75 0.58 0.41 0.28 0.16 0.09 0.06 | 0.33 |

A healthy **prose** ladder collapses to 0.06 — the same shape a broken mask
makes. So the collapse convicts only on structured output, the tool returns a
mask verdict for no other class, and `make check` asserts that the published
healthy prose ladder comes back clean.

## Then use it: the three `agent` workspaces

`kind: agent`. Every other recipe here gives you an **endpoint**; these are the
only ones that give you something to *use* it with. All three take a custom
OpenAI-compatible provider, which is exactly what a GB10 running vLLM is — so
the pairing is the point, and **no token leaves the house**:

```bash
ws up vllm-qwen3.8-27b-nvfp4    # the model, on the cluster
ws up pi-harness                # the agent, talking to it
```

They claim no GPU and no unified memory, so unlike two inference workspaces,
an agent and a server coexist. They are three genuinely different tools:

| | Shape | Sandbox | Reach for it when |
|---|---|---|---|
| [`deepseek-harness`](agent/deepseek-harness/README.md) | Web UI on `:3080` | The container | You want a browser |
| [`pi-harness`](agent/pi-harness/README.md) | **TUI**, and `-p`/JSON/RPC | The container | You want it in a **pipe** |
| [`exo-harness`](agent/exo-harness/README.md) | REPL, host-side, long-running | **Exo starts its own** | You want it to **rewrite itself** |

**Read the warning in each README before running it.** The short version:
`dsh` is a **developer preview** by its own admission; `pi` ships **no
permission system** by its own admission; and `exo` is built to **modify its
own source** and can clone itself. All three execute tool calls, so what you
mount is the security decision — which is why `deepseek-harness` and
`pi-harness` both default to an **empty `./work`** rather than to `$HOME`, and
why `exo-harness` defaults to the `minimal` template rather than to upstream's
`canonical`, whose ExoChat would route the conversation through
`exoharness.ai`.

## Provenance

Same rule as the docs: **`verified` means it was run on this hardware.**
`ws list` colours it — green verified, yellow written-but-never-run.

Three values, and `ws list` colours all three:

| | Means | `ws list` |
|---|---|---|
| `verified` | run on this hardware, and it worked | green |
| `unverified` | written from vendor docs and the manifest's sources, never run | yellow |
| `blocked` | **run here, and something outside this repo refused it** | red |

`blocked` is a measurement, not pessimism, and it exists so that "this cannot
work today" is visible in the catalogue rather than buried in a README nobody
reads before starting a 17.5 GB download. When a blocker lifts, re-run and flip
it back.

Most workspaces here are still **unverified** — written from vendor
documentation and the sources listed in each `workspace.yml`, not from a
completed run. Expect to fix something the first time. When you do, fix the
recipe, flip `provenance`, and say what changed.

## Adding one

```
workspaces/<kind>/<name>/
  workspace.yml     required — manifest
  README.md         required — what / why / when / how, and the failure table
  compose.yml       or up.sh/down.sh
  .env.example      optional; the real .env is gitignored
```

`README.md` is not decoration. A manifest says *what* a recipe needs and a
script says *what it does*; neither says **when you should reach for this one
instead of the one next to it**, and that is the question people actually
arrive with. `make check` fails if a workspace has no README, or if
`workspaces/README.md` does not link it — a catalogue that has gone stale
denies the existence of a recipe, confidently.

`<kind>` is a directory and a manifest field, and they must agree with the set
`ws` colours: `inference`, `cluster`, `rl`, `bench`, `agent`. Shared code lives
in `workspaces/lib/` and is the exception rather than the pattern — see the
two-node note above before adding to it.

`workspace.yml` is deliberately a flat subset of YAML (`ws` parses it with awk
rather than depending on `yq`, which this repo does not install):

```yaml
name: my-thing            # must equal the directory name
kind: inference           # inference | cluster | rl | bench | agent
engine: vllm
provenance: unverified    # verified once you have run it
summary: one line, shown in `ws list`
requires:                 # all optional; each is checked by `ws check`
  gpu_arch: "12.1"        # compute capability
  min_unified_gb: 40      # against MemAvailable
  min_disk_gb: 170        # free space at HF_HOME — where the weights land
  docker: true
  rdma: true              # an ACTIVE RoCE port
  peers: 1                # SSH-reachable peer nodes
images:   [...]           # warned about if not pulled
models:   [...]           # HF ids; warned about if not cached
endpoints: [...]
sources:  [...]           # where the flags came from — required in practice
```

`bench` and `agent` are **clients**: they need a running endpoint rather than a
free GPU, so they carry almost no `requires:` and they coexist with a serving
workspace, which no two `inference` ones do.

`make check` validates every manifest, so a typo in a key fails offline rather
than at 3am.

## Secrets and local values

Same three tiers as the Ansible half
([why](../docs/decisions.md#private-vars)): tracked defaults in the recipe, a
gitignored `.env` per workspace for what is yours, and nothing secret in the
repo. `.env.example` is the tracked template.

## Relationship to `roles/ray` and `roles/slurm`

Both exist, and they are not duplicates:

- **Ray** — `roles/ray` installs a *standing* systemd service;
  `workspaces/cluster/ray` starts an *ephemeral* containerised cluster for one
  experiment. They will fight over ports. Pick one. For RL, prefer the
  ephemeral one: verl pins a Ray version and you want that one, not whatever
  the host was provisioned with.
- **Slurm** — the daemons stay with Ansible on purpose. A scheduler is
  infrastructure: munge keys, controller state, a daemon per node, a shared
  clock. `workspaces/cluster/slurm` ships only the part that changes per
  experiment — the job scripts.
