# spec-decode-accept

> Is the speculative decoder working — and if not, **where** does it fail?
> Acceptance **per draft position**, against a server that is already up.

| | |
|---|---|
| Kind | `bench` — a client. It **coexists** with a serving workspace |
| Engine | vLLM (full ladder) · SGLang (accept **length** only — see below) |
| Reads | `$BASE_URL` (default `http://127.0.0.1:8888/v1`), `/metrics`, and on SGLang `/server_info` |
| Needs | python3. No GPU, no unified memory, no peer |
| Provenance | `unverified` — written from the sources below, never run on this hardware |

## What

Runs a fixed generation, reads the server's own `vllm:spec_decode_*` counters
before and after, and prints acceptance broken down by **draft position**.

```
  STRUCTURED  (3 runs, 400 tokens each)
    drafts                       812
    draft tokens               5,684   (k = 7)
    accepted                   5,218
    acceptance ratio           0.918
    accepted per step           6.43   of 8 possible
    decode                      61.7 tok/s   (median, TTFT 0.72s)

    ACCEPTANCE BY DRAFT POSITION - healthy stays above ~0.8 throughout
      pos 0  [####################]  0.98
      pos 1  [####################]  0.98
      pos 2  [###################-]  0.94
      pos 3  [###################-]  0.94
      pos 4  [##################--]  0.91
      pos 5  [#################---]  0.83
      pos 6  [#################---]  0.83

    [  ok  ] structured output stays high across the whole ladder - this is
             what a working drafter looks like
```

## Why

**A broken draft path costs acceptance and nothing else.** The target model
still verifies every token, so the output stays perfectly correct — you get
half the speed, with no error and no warning. Every workspace in this repo that
runs a speculative server says some version of *"this is the most misleading
failure in the file"*. This is the tool that resolves it.

### Why per-position, when `vllm-bench-serve` already shows acceptance

[`vllm-bench-serve`](../vllm-bench-serve/README.md) shows the **aggregate**
number live, which answers *is the drafter doing anything*. It cannot separate
the two ways one breaks, and the difference decides what you go and fix:

| Shape, **on the structured class** | Means |
|---|---|
| Every position low, including position 0 | A weak drafter — wrong draft weights, or weights that never loaded |
| Position 0 **healthy**, 1..k−1 **collapsed** | A **causal mask inside a non-causal draft block** |

On the prose class neither row applies, because a healthy prose ladder already
looks like the second one. See below.

The second is not a tuning problem. The first drafted token is predicted from
real context and is fine; every later one is predicted from a block it is not
allowed to see. Reported on the GLM-5.3-Flash kit, pinning the draft attention
backend to `TRITON_ATTN` took structured decode from ~62 to **~29 tok/s** and
aggregate acceptance from **0.92 to 0.31**, *"pos0 healthy, later positions
collapsed"*. The server reported nothing wrong.

### The prompt class is not a flavour — it is what makes the shape readable

Acceptance is a property of the **text**. Both of these are published medians
from the **same healthy server** on that kit:

| Class | pos 0 | 1 | 2 | 3 | 4 | 5 | 6 | aggregate | decode |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Structured | 0.98 | 0.98 | 0.94 | 0.94 | 0.91 | 0.83 | 0.83 | 0.92 | ~62 tok/s |
| Prose | 0.75 | 0.58 | 0.41 | 0.28 | 0.16 | 0.09 | 0.06 | 0.33 | ~27 tok/s |

**A healthy prose ladder collapses to 0.06 — the same shape a broken mask
makes.** So the collapse is evidence of nothing on prose, and evidence of
something on structured output, where a working drafter stays above ~0.8 all
the way out.

That is enforced, not just documented: the tool **only ever returns a mask
verdict for the structured class**, and `tests/check_spec_accept.py` asserts
that the published healthy prose ladder comes back clean. Condemning a working
server is the failure that gets a check muted, and a muted check catches
nothing.

### Why the token count comes from `usage`

Under speculative decoding a server emits at most **one SSE chunk per decode
*step***, carrying every token accepted in that step. Counting streamed deltas
measures *steps* per second and under-reports by exactly the acceptance
length — the number this tool exists to measure, so getting it wrong here would
hide its own error. Streaming is still used, but only for the first-token
timestamp; the count comes from `usage.completion_tokens`.

### On SGLang there is no ladder, and the tool says so

Everything above rests on
`vllm:spec_decode_num_accepted_tokens_per_pos_total`. **SGLang publishes no
per-position counter at all** — the best it offers is an EMA of accept
*length* on `/server_info`. So against an SGLang server this degrades, on
purpose and out loud:

| | vLLM | SGLang |
|---|---|---|
| Acceptance by draft position | **yes** — the ladder | no |
| Aggregate acceptance | yes | derived: `(accept_length − 1) / k` |
| Can convict a **weak drafter** | yes | **yes** |
| Can convict a **broken mask** | yes | **no** |

The derivation is stated wherever it is printed: a verify step accepts
`length` tokens of which one is the target's own bonus token, out of `k`
drafted — so `1.0` means every draft was rejected and `k + 1` means all were
taken.

**The `mask` verdict is unreachable on that path**, and
[`tests/check_spec_accept.py`](../../../tests/check_spec_accept.py) asserts it
at four different accept lengths. A degraded probe that degrades *silently*
would return a confident verdict about a shape it never measured — which is
worse than not running at all, and is the same discipline that keeps a prose
ladder from convicting a healthy server.

If you need the ladder for a checkpoint SGLang is serving, serve it under vLLM
instead. For Nemotron 3.5 Lightning that is
[`vllm-nemotron35-lightning-nvfp4`](../../inference/vllm-nemotron35-lightning-nvfp4/README.md),
which exists partly for this reason.

**SGLang serves no `/metrics` without `--enable-metrics`.** Without it a
perfectly healthy DSpark server reads as having *no speculative decoding* —
a wrong answer wearing the costume of a finding.
[`sglang-nemotron35-lightning-nvfp4`](../../inference/sglang-nemotron35-lightning-nvfp4/README.md)
passes it for exactly that reason.

## When to reach for this one

| | Use |
|---|---|
| A speculative server is slower than published and you do not know why | **This** |
| You want to know how many streams it holds | [`vllm-bench-serve`](../vllm-bench-serve/README.md) |
| You want to know whether it is answering correctly | [`vllm-quality-gate`](../vllm-quality-gate/README.md) |
| You changed `SPEC_CONFIG` and want to know if it helped | **This**, before and after |

## How

```bash
ws up vllm-2node-glm53-flash-exl3                              # a server
BASE_URL=http://127.0.0.1:8893/v1 ws up spec-decode-accept     # then this

ws up spec-decode-accept --class structured --runs 5
ws up spec-decode-accept --json /tmp/accept.json
```

**Run it against an otherwise idle endpoint.** The counters are cumulative and
this reads deltas, so other traffic during the window lands in your numbers.

## When it fails

| Symptom | Cause |
|---|---|
| `no speculative decoding on this server` | `SPEC_METHOD=none`, or the server never loaded a drafter. Exit status 1 |
| `cannot read .../metrics` | `BASE_URL` points somewhere without a metrics endpoint, or the server is not up |
| Every position is 0.00 but drafts are non-zero | The drafter is producing tokens the target rejects wholesale — usually a drafter that does not match the target checkpoint |
| Numbers move between identical runs | Something else is using the server. Deltas are not isolated from other traffic |
| A prose run looks collapsed | **That is healthy.** A working drafter reaches 0.06 by the last position on prose — read the structured run instead |
| No per-position ladder at all, and a note saying so | You are on **SGLang**, which does not publish one. Not a fault — see above |
| `no accept length reported` on an SGLang server that is clearly drafting | The EMA is only populated after a verify pass. Send it traffic, then re-run |

## Sources

- [vLLM metrics reference](https://docs.vllm.ai/en/latest/design/metrics/) — where `vllm:spec_decode_*` comes from
- [vLLM speculative decoding](https://docs.vllm.ai/en/latest/features/spec_decode/)
- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks) — the per-position ladders quoted above
- [SGLang production metrics](https://docs.sglang.io/references/production_metrics.html) — what that engine does and does not publish, and why `--enable-metrics` is not optional
