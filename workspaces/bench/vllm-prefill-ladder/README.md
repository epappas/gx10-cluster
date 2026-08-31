# vllm-prefill-ladder

> How long does the **first** character take, and is that number real?
> Cold prefill throughput and prefix-cache reuse, against a server already up.

| | |
|---|---|
| Kind | `bench` — a client. It **coexists** with a serving workspace |
| Engine | any OpenAI-compatible vLLM server with `/metrics` and `/tokenize` |
| Reads | `$BASE_URL` (default `http://127.0.0.1:8888/v1`), plus `/metrics` and `/tokenize` at the **root** |
| Needs | python3. No GPU, no unified memory, no peer |
| Provenance | `unverified` — the protocol is published, the verdicts are ours, neither has been run on this hardware |

## What

Sends a ladder of prompts of known size, one at a time, and reports the time to
the first **content** token — with the prefix-cache counters read across every
request so a "cold" rung can be *proven* cold rather than assumed.

```
prefill ladder   http://127.0.0.1:8893/v1   model=glm-5.3-flash-exl3
  every cold prompt is salted FIRST, and the prefix-cache counter is
  read across each request to PROVE the rung was cold
      8k  calibrated to 7995 tokens, sending...
     12k  calibrated to 11995 tokens, sending...
     16k  calibrated to 15995 tokens, sending...
   reuse  same history plus one turn...

    rung  prompt tok    TTFT s    tok/s     hits   compute  s/chunk
  ------------------------------------------------------------------
      8k        7995     10.36      772        0      7995    2.072
     12k       11995     13.38      896        0     11995    2.230
     16k       15995     17.91      893        0     15995    2.238
follow-up       8004      1.30     6167     7168       836    0.325

  reuse: 7168 of 7168 allowed by a 3584-token page (1.00 efficiency),
  836 tokens still computed

  every rung was cold, on target and idle - the numbers above compare
```

`--chunk-tokens` adds the `s/chunk` column. `--rungs 8000,100000,300000` walks
out to the long end; those rungs cost **minutes each**, which is why they are
not the default.

## Why

Every other bench in this repo measures **decode**. On a long-context server
that is not where the time goes: a 100k-token prompt spends roughly a hundred
seconds in prefill before a single character appears, and then decodes at
whatever tok/s `vllm-bench-serve` already told you. TTFT on a fresh
conversation is the number a user actually experiences, and nothing here
measured it.

### The measurement destroys itself if you let it

Every serving workspace here runs with `--enable-prefix-caching`. Send the same
prompt twice and the second one is not a prefill — it is a cache hit wearing a
prefill's clothes. Measured on the kit this protocol comes from: rerunning a
"cold" ladder without changing the prompt took TTFT from **10.3 s to 1.9 s**.

That is a 5× improvement produced by nothing at all, and it looks exactly like
a successful optimisation. It is the single easiest way to convince yourself a
flag helped when it did nothing.

Two things prevent it here:

- **A fresh UUID salt, first in the message.** Position is the whole point.
  Prefix caching hashes a *prefix*: a salt appended at the end still shares
  every preceding block with the last run. Ahead of the shared text, the very
  first block differs and nothing after it can match.
- **The counters, not faith.** `vllm:prefix_cache_hits_total` is read before and
  after each request. A cold rung that reports **any** hits is printed as
  `INVALID`, not as a fast result.

### Reuse is a ratio against a page model, not a percentage

Prefix-cache hits are **block-aligned**. A 7.7k-token conversation does not
reuse 7.7k tokens — it reuses `floor(7717 / 3584) × 3584 = 7168` of them, and
the 549-token remainder is real compute on every single turn.

Reporting that as "93% hit" reads as though 7% is being lost, and sends
somebody looking for it. `hit_efficiency` — measured hits over what the page
model *allows* — says the true thing instead:

| | |
|---|---|
| `1.00` | reusing everything block alignment permits. Nothing is wrong |
| `< 1.00` | the page assumed here (`--page`, default 3584) is not this server's, **or** reuse really is being lost |
| `> 1.00` | this server aligns finer than 3584 — pass `--page` for an honest ratio |

When it is not 1.00 the tool prints the page sizes **consistent with what it
observed**, as a set. One measurement genuinely cannot pick between them —
7168 hits on an 8004-token prompt fits a 3584-token page and an 896-token one
equally well — and naming one would be a guess presented as a measurement.

### What it is actually for: A/B-ing `--max-num-batched-tokens`

Pass `--chunk-tokens` and each rung also reports **seconds per chunk**. That is
the quantity to watch: it stays flat across rungs when prefill is compute-bound,
and what a larger chunk buys is fewer of them, not cheaper ones.

The GLM-5.3-Flash workspace's `2048` default is the output of exactly this
ladder, run at 1024 / 2048 / 3584 / 4096 — including the result that the
page-aligned 3584 *lost*, which is the kind of finding that only exists because
somebody measured instead of reasoning about alignment.
See [`docs/decisions.md#glm53-second-pass`](../../../docs/decisions.md#glm53-second-pass).

## How

```bash
# against whichever server is on the default port
ws up vllm-prefill-ladder

# against the GLM workspace, with its chunk size, and archived
BASE_URL=http://127.0.0.1:8893/v1 \
  ws up vllm-prefill-ladder --chunk-tokens 2048 --json before.json

# the long end, when you want the shape rather than the TTFT
ws up vllm-prefill-ladder --rungs 16000,100000,300000
```

| Flag / env | Default | |
|---|---|---|
| `BASE_URL` | `http://127.0.0.1:8888/v1` | the OpenAI-compatible endpoint |
| `MODEL` | discovered from `/v1/models` | |
| `API_KEY` | unset | sent as `Authorization: Bearer` when the server has `VLLM_API_KEY` set |
| `--rungs` | `8000,12000,16000` | target `prompt_tokens` per rung |
| `--page` | `3584` | prefix-cache page for the reuse expectation |
| `--chunk-tokens` | `$MAX_NUM_BATCHED_TOKENS` | adds the `s/chunk` column |
| `--tolerance` | `0.02` | how far a rung's size may miss its target |
| `--no-apc` | off | skip the follow-up turn |
| `--json PATH` | unset | archive the raw numbers |

Exit status is non-zero when a rung was **invalid** — contaminated by the
cache, or miscalibrated. Never because a number was low: this tool has no
opinion about what fast is.

## What it cannot tell you

- **Whether the answer is right.** `ws up vllm-quality-gate`.
- **Whether the drafter is working.** `ws up spec-decode-accept`. Speculative
  decoding does not touch prefill, so a broken drafter is invisible here.
- **Throughput under concurrency.** `ws up vllm-bench-serve`. Everything here is
  one request at a time on purpose; a prefill measured next to another prefill
  is a queueing measurement.
- **Whether a slow rung is the model or the box.** It reports the time, not the
  cause. `docs/runbooks/diagnose-interconnect.md` for the box.

## Sources

- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks)
  — `docs/cold-prefill.md` and `docs/improve-prefill.md`, where this protocol,
  the 3584-token page and the self-contaminating-rerun failure are published
- [vLLM metrics](https://docs.vllm.ai/en/latest/design/metrics/)
- [vLLM automatic prefix caching](https://docs.vllm.ai/en/latest/features/automatic_prefix_caching.html)
