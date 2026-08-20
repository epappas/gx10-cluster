# Workspaces

Runnable recipes for inference, cluster and RL environments. **Not Ansible.**

```bash
./workspaces/ws list                        # what exists, and what has been run
./workspaces/ws check vllm-qwen3.8-27b-nvfp4  # does THIS machine qualify?
./workspaces/ws up    vllm-qwen3.8-27b-nvfp4
./workspaces/ws logs  vllm-qwen3.8-27b-nvfp4 -f
./workspaces/ws down  vllm-qwen3.8-27b-nvfp4
```

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
| **NVFP4** (~22.6 GB) | no | **yes** | **NO** — quantised `lm_head` |
| **GGUF Q4** (~17–19 GB) | **yes** | yes | yes |
| **MixedInt4-AutoRound** (20.8 GB) | no | **yes** | no |

GB10 is Blackwell (`sm_121`), so NVFP4 is the format this hardware exists for —
and it is exactly the one SGLang cannot load. Pick SGLang for its scheduler,
not to run NVFP4.

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
   Both two-node workspaces launch both ranks from one script so this cannot
   drift.

All three live in `workspaces/lib/twonode.sh`, which is the **one recipe here
that is not standalone**. Two workspaces each carrying their own copy of this
wiring would drift exactly the way two ranks do — slowly, and silently. A
workspace supplies `MODEL_ARGS` and nothing else
([why](../docs/decisions.md#twonode-lib)).

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

## Then use it: `deepseek-harness`

`kind: agent`. DeepSeek's own agent harness (`dsh`), configured against a model
**this cluster is serving** rather than against their API:

```bash
ws up vllm-2node-deepseek-v4-flash    # the model, on the cluster
ws up deepseek-harness                # the agent, talking to it  -> :3080
```

It claims no GPU and no unified memory, so unlike two inference workspaces,
these two coexist. Two things to know before running it: it is a **developer
preview** by its own README, and it is an **agent harness** — it executes tool
calls against whatever you mount at `/work`, on host networking. The default
mount is an empty `./work`, and that default is the security design rather than
an inconvenience to route around.

## Provenance

Same rule as the docs: **`verified` means it was run on this hardware.**
`ws list` colours it — green verified, yellow written-but-never-run.

Every workspace here is currently **unverified**. They are written from vendor
documentation and the sources listed in each `workspace.yml`, not from a
completed run. Expect to fix something the first time. When you do, fix the
recipe, flip `provenance`, and say what changed.

## Adding one

```
workspaces/<kind>/<name>/
  workspace.yml     required — manifest
  compose.yml       or up.sh/down.sh
  .env.example      optional; the real .env is gitignored
```

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
