# vllm-quality-gate

> Is the server answering **correctly**? Fast and wrong is a real state, and
> nothing else here notices it. **Exits non-zero** if any request tripped a
> detector.

| | |
|---|---|
| Kind | `bench` — a **client**, not a server |
| Engine | any OpenAI-compatible endpoint |
| Nodes | one endpoint covers the whole deployment |
| Reads | `http://127.0.0.1:8888/v1` by default — set `BASE_URL` |
| Exit status | **0 only if every request passed every detector** |
| Provenance | `unverified` — but its **detectors are tested offline** in `make check` |

## What

Sends a concurrency ladder of deliberately **cold, long, unique** prompts and
runs pure-function detectors over the replies. It looks for serving-layer
faults, not model quality:

- replies that open mid-word, or echo the prompt back
- replies that are **empty while the whole token budget was billed**
- script drift (the reply wanders out of the language or format asked for)
- reasoning that never terminates
- looping and heavy-tail repetition

Then it **checks it really got the cold run it claims**, off
`vllm:prefix_cache_hits` — because an assertion nobody verifies is a comment.

## Why

### The third question

| | `make bench` | [`vllm-bench-serve`](../vllm-bench-serve/README.md) | **this** |
|---|---|---|---|
| Asks | is the **hardware** fit? | how **fast** is the server? | is it **right**? |
| Fails when | RDMA/NCCL/fio underperform | throughput collapses | a reply is garbled, empty, looping or off-contract |
| Exit status | gates | informational | **non-zero on any detection** |

The faults it hunts are scheduler, speculative-decoder and reasoning-parser
faults. **None of them moves a tok/s number.** A server can be perfectly fast
and quietly wrong, and the two benchmarks above will both say it is fine.

### A five-prompt smoke test cannot find them, and that is structural

Both conditions that produce these failures are ones a smoke test does not
create:

- **Cold prefill.** The corruption attaches to the last chunk of a long
  *first* prefill. A prefix-cache **hit never fails**, so asking the same
  question twice makes it look self-healing — and the clean second answer is the
  one you believe.
- **Concurrency.** Several appear only with more than one sequence in flight.

So the gate forces both. Every request carries a **unique nonce as the first
thing in the prompt**, which invalidates the whole prefix-cache block chain
behind it; the filler is long enough to be genuinely chunk-prefilled; and the
run climbs a ladder.

### Two things it does that are easy to get wrong by hand

- **It reads `usage.completion_tokens` from a non-streamed reply.** Under
  speculative decoding a server emits at most one SSE chunk per decode *step*,
  carrying every token accepted in it — so counting streamed deltas measures
  steps/s and under-reports by the acceptance length.
- **It reads `reasoning` *or* `reasoning_content`.** This family of runtimes
  returns the first; OpenAI-compatible clients expect the second.

### The detectors are tested offline

They are pure functions over text, so `tests/check_detectors.py` runs them in
`make check` with no server at all. **A gate that has quietly stopped being
able to fail is worse than no gate.**

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| In front of a deployment: `ws up vllm-quality-gate && <promote>` | You want a capacity curve → [`vllm-bench-serve`](../vllm-bench-serve/README.md) |
| After starting a speculative or two-node server | You want to know if the hardware is healthy → `make bench` |
| A server "works" but users report odd replies | You are evaluating *model* quality — that is not what this measures |

`requires: {}` — it needs a running endpoint, not a free GPU, so it coexists
with the serving workspace it is pointed at.

## How

```bash
ws up vllm-2node-deepseek-v4-flash
BASE_URL=http://127.0.0.1:8890/v1 ws up vllm-quality-gate

ws up vllm-quality-gate -c 1,8 -n 8     # wider ladder, more requests per rung
ws up vllm-quality-gate --warm          # the control run, which should PASS
ws up vllm-quality-gate --json          # machine-readable summary on stdout
```

`--warm` is the control: it drops the cold-prefill forcing, so a **failure
there** means something other than cold prefill is wrong.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| `BASE_URL` | `http://127.0.0.1:8888/v1` | Two-node servers answer here too — rank 0 serves |
| `MODEL` | discovered from `/v1/models` | Set only if the server exposes several |
| `CONCURRENCY` | `1,2,4` | Rungs are cheap; each is another chance for a concurrency-only fault to show |
| `PER_RUNG` | `6` | Requests per rung |
| **`MAX_TOKENS`** | `1024` | **A detector setting, not a performance one** — see below |
| `PREFILL_WORDS` | `1800` | Long enough to be genuinely chunk-prefilled |
| `TIMEOUT` | `600` | |

**`MAX_TOKENS` is the one to understand before disbelieving a result.** With
reasoning enabled, a budget that runs out before `</think>` arrives makes the
parser emit neither content nor reasoning: the caller gets `""` and is billed
for the lot. Measured on that failure, thinking on at temperature 0.5:

| budget | empty replies |
|---|---|
| 256 | 83% |
| 512 | 50% |
| 768 | 17% |
| **1024** | **0 / 18** |

So 1024 is the floor at which an empty reply means something is actually wrong
rather than that your budget was too small. **If a run comes back all-empty,
raise `MAX_TOKENS` before believing it.**

`PREFILL_WORDS` should be raised to match your real prompts — the originally
reported reproducer used ~18k tokens of system prompt and tool schemas.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Everything empty | `MAX_TOKENS` below the reasoning budget | Raise it above ~1024 |
| Gate fails, `--warm` passes | A genuine **cold-prefill** fault | That is the finding. Do not promote |
| Gate fails at concurrency ≥ 2 only | A scheduler/batching fault | Same — that is the finding |
| It reports the run was **not** cold | `vllm:prefix_cache_hits` moved when it should not have | The nonce is not invalidating the chain — raise `PREFILL_WORDS`, or check for a proxy caching in front |
| Nothing answers on `BASE_URL` | No server up | Start a serving workspace first |
| Throughput is fine and the gate still fails | **That is the entire point of this workspace** | |

## Reasoning models and `--max-tokens`

`MAX_TOKENS` defaults to 1024, and on a model that thinks at length that is not
always enough for `</think>` to arrive. When it does not, the reply is genuinely
empty while the whole budget was billed — which is a real detector, and one of
the failures this gate exists for — so the gate reports it and exits non-zero.

**It also tells you which case you are in.** A budget artefact carries a second
line:

```
- empty-with-2048-tokens-billed (reasoning never closed)
- hit max_tokens=2048, too short to classify
```

That second line is the tell. Raise `--max-tokens` and re-run before reading it
as a server fault; an empty reply that finished *without* hitting the cap has no
such line and is the real thing. Measured here: Nemotron 3.5 Lightning needs
more than 2048 on some prompts, Qwen3.8-27B more than 1024.

## Sources

- <https://github.com/tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark>
- <https://docs.vllm.ai/en/latest/design/metrics/>
- <https://docs.vllm.ai/en/latest/features/spec_decode/>

See also: [`workspace.yml`](workspace.yml) ·
[why a third check exists](../../../docs/decisions.md#quality-gate) ·
[runbook](../../../docs/runbooks/workspaces.md)
