# vllm-bench-serve

> A concurrency sweep with `vllm bench serve`, rendered **live** in the
> terminal — because on unified memory the numbers that decide whether a result
> is valid are transient and absent from the summary table.

| | |
|---|---|
| Kind | `bench` — a **client**, not a server |
| Engine | vLLM |
| Nodes | covers **every** node, from wherever you run it |
| Reads | `http://127.0.0.1:8888/v1` by default — set `BASE_URL` |
| Writes | `~/.local/state/gx10-bench` — JSON + an HTML timeline per point |
| Provenance | `unverified` |

## What

Drives `vllm bench serve` across a concurrency ladder (`1,2,4,8,16,32` by
default), one run per rung, and renders the run while it happens: server-side
KV occupancy and queue depth off the server's own `/metrics`, GPU/memory/swap
off **every** node, and completed sweep points accumulating underneath.

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

## Why

### It is not `make bench`

| | `make bench` | `ws up vllm-bench-serve` |
|---|---|---|
| Measures | the **hardware** — NCCL, RDMA, fio, DCGM | a **model server** |
| Answers | is this cluster fit to run work? | how many concurrent streams before latency falls over? |

Same word, different question, no overlap in what they run.

### Why a live view, when `--plot-timeline` exists

The HTML timeline is good, and this workspace turns it on. It is also a
**post-mortem**.

On unified memory that is not enough, for a specific reason: **a run that
swapped and a run that did not produce the same shaped summary table.** Nothing
in the JSON says which one you have.

| Signal | Source | What it means if you miss it |
|---|---|---|
| KV cache occupancy | `vllm:kv_cache_usage_perc` | Pegged at 100% → you measured **preemption**, not throughput |
| Queue depth | `vllm:num_requests_waiting` | Deep → the server never reached steady state |
| Swap growth | `/proc/meminfo`, every node | Growing → you measured **paging**. On coherent memory that is a cliff |

So the honest conclusion — *this point is not a measurement* — is visible at the
time rather than inferred later.

### It watches every node, not just the one you typed on

A tensor-parallel server has **one** endpoint: rank 0 serves, rank 1 is
headless. So the load generator and `/metrics` already describe the whole
deployment. Host telemetry does not — and **rank 1 swapping invalidates a run
exactly as much as rank 0 swapping does**.

```
  NODES (all 2 - a peer that swaps invalidates the run too)
    odysseus  gpu [#########-] 96%   mem [########--] 82%   89.3W  71C  no swap
    poseidon  gpu [#########-] 94%   mem [########--] 80%   86.1W  69C  swap 120 MB, not growing
```

Nodes come from `/etc/gx10/interconnect.peers`, so a third and fourth Spark
appear with **no configuration**. Swap is judged on **growth**, not presence — a
node holding swap from last week is not a failing benchmark, and flagging it
trains you to ignore the row that matters.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| A server is up and you want its capacity curve | You want to know if the *hardware* is healthy → `make bench` |
| You are choosing `--max-num-seqs` / `--max-model-len` | You want to know if the server is **correct** → [`vllm-quality-gate`](../vllm-quality-gate/README.md) |
| You suspect a speculative-decode path is broken | Nothing is serving yet — this needs an endpoint, not a GPU |

`kind: bench` means it claims no GPU and no unified memory, so it **coexists
with the serving workspace it is pointed at**, which no two `inference`
workspaces do.

## How

```bash
ws up vllm-qwen3.8-27b-nvfp4          # something to bench
ws up vllm-bench-serve                # the default ladder 1,2,4,8,16,32
ws up vllm-bench-serve -c 1,4,16      # an explicit ladder
ws up vllm-bench-serve -1             # one point, no sweep
ws down vllm-bench-serve              # only needed if the TUI was SIGKILLed
```

`q` or `Ctrl-C` quits and stops the in-flight bench.

### Read the live pane, not just the table

| On screen | What you actually measured |
|---|---|
| KV cache bar pegged at 100% | Preemption, not throughput |
| `swap N MB - RESULTS ARE NOT VALID` | Paging |
| Streams in flight well below the concurrency asked for | A client-side limit, not a slow model |
| A `NODES` row showing `no sample` | SSH to that peer failed, or it is restarting |

### On a speculative server, read acceptance

It is the number that explains the throughput, and its absence is what makes
the worst failure here so hard to place: **a broken draft path costs acceptance
and nothing else**, because the target model still verifies every token. Output
stays perfectly correct at half the speed — which reads as bad hardware or a bad
recipe.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| `BASE_URL` | `http://127.0.0.1:8888/v1` | Two-node servers answer here too — rank 0 serves |
| `MODEL` | discovered from `/v1/models` | The **served** name |
| **`TOKENIZER`** | `$MODEL` | **The one setting worth knowing.** See below |
| `CONCURRENCY` | `1,2,4,8,16,32` | Each rung is a separate `vllm bench serve` run |
| `PROMPTS_PER_STREAM` | `8` | `num_prompts = concurrency × this` |
| `INPUT_LEN` / `OUTPUT_LEN` | `1024` / `128` | `8192/128` for prefill-bound, `128/2048` for decode-bound |
| `BACKEND` | `vllm` | `openai-chat` to include the chat template in what is measured |
| `BENCH_LOCAL` | unset | Run from a host install instead of the container |
| `RESULT_DIR` | `~/.local/state/gx10-bench` | |

**`TOKENIZER` is the one that bites.** `MODEL` is the *served* name and is
discovered from `/v1/models` — but a tokenizer cannot be loaded from
`qwen3.8-27b`. If the server was started with `--served-model-name`, set
`TOKENIZER` to the HF repo id, or the run dies several minutes in with a HF 404.

### Why `num_prompts` scales with concurrency

A fixed count measures a different thing at each rung: 64 prompts at
concurrency 1 is 64 sequential requests; at concurrency 32 it is two batches,
most of which is **ramp**. Ramp is exactly what a steady-state throughput number
must not contain.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Dies minutes in with a HF 404 | `--served-model-name` ≠ the HF repo id | Set `TOKENIZER` |
| Numbers look great but KV was pegged | You measured preemption | Lower `--max-model-len` / `--max-num-seqs` on the **server**, re-run |
| A peer shows `no sample` | SSH failed, or the node is restarting | `ssh <peer> true`; it recovers on its own |
| The bench keeps loading a server you quit | The TUI was SIGKILLed so its EXIT trap never ran | `ws down vllm-bench-serve` |
| Nothing answers on `BASE_URL` | No server up. `ws check` cannot ask this — it is not a property of the machine | Start a serving workspace first |

`ws down` deliberately does **not** delete `RESULT_DIR`. Results are the output
of this workspace; a tidy directory is a bad trade for twenty minutes of
measurement.

## On a speculative server, this measures the FLOOR

`vllm bench serve` drives `--dataset-name random`, and **random tokens are
unpredictable by construction** — so a drafter accepts almost none of them. The
live view says so plainly, and it is not a fault:

```
draft accepted   0%   1.00 tok/step   below ~25% -> draft path, not config
```

Measured here on the same servers, same day:

| Server | This sweep (random) | `spec-decode-accept` (real text) |
|---|---|---|
| `vllm-2node-deepseek-v4-flash` | 6.5 tok/s @ conc 1 | **79.9 tok/s**, acceptance 1.00 |
| `vllm-nemotron35-lightning-nvfp4` | 41.6 tok/s @ conc 1 | **160.0 tok/s**, acceptance 1.00 |

**Both numbers are true and they answer different questions.** Use this sweep
to find the concurrency knee and to catch preemption or paging; use
[`spec-decode-accept`](../spec-decode-accept/README.md) for the throughput a
user actually feels. Quoting a random-dataset tok/s as "the model's speed" on a
speculative server understates it by 2–12×.

## Sources

- <https://docs.vllm.ai/en/latest/cli/bench/serve/>
- <https://docs.vllm.ai/en/latest/benchmarking/cli/>
- <https://docs.vllm.ai/en/latest/design/metrics/>

See also: [`workspace.yml`](workspace.yml) ·
[why a TUI](../../../docs/decisions.md#serving-bench) ·
[runbook](../../../docs/runbooks/workspaces.md)
