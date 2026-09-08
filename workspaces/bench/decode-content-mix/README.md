# decode-content-mix

> Decode tok/s by **content type** — the axis a concurrency sweep cannot show,
> and the reason a single "decode tok/s" for this cluster is a half-truth.

| | |
|---|---|
| Kind | `bench` — a **client**. Coexists with a serving workspace |
| Engine | any OpenAI-compatible endpoint; acceptance needs vLLM `/metrics` |
| Reads | `http://127.0.0.1:8888/v1` by default — set `BASE_URL` |
| Needs | python3. No GPU, no unified memory, no peer |
| Provenance | `unverified` — written from the source below, never run here |

## What

Four fixed tasks, batch 1, exactly N decoded tokens each, with speculative
acceptance read as a **delta** around each one.

On the reference kit these varied by more than 70% on **one server with one
configuration**:

| task | tok/s | why |
|---|---|---|
| `copy` | ~70 | the drafter predicts quoted text almost perfectly |
| `code` | ~43 | |
| `entropy` | ~40 | at temperature 0.8 |
| `prose` | ~40 | genuine narrative — the honest typical case |

**That spread is speculative-decode acceptance, not the hardware.** Quoting the
copy-heavy number as "decode speed" is the specific mistake this exists to make
hard, so the tool prints the spread and says so when it exceeds 1.3×.

## Run it

```bash
BASE_URL=http://127.0.0.1:8896/v1 ws up decode-content-mix
ws up decode-content-mix --decode 600 --tasks prose,code
ws up decode-content-mix --context 32000     # does the spread hold at depth?
```

```
decode-content-mix  http://127.0.0.1:8896/v1  model=qwen3.8-flash-next
400 tokens per run, ignore_eos, batch 1

  task       temp    tok/s   accept  per step
  prose       0.0     40.1    56.5%      2.26
  code        0.0     43.2    61.0%      2.44
  entropy     0.8     40.1    54.8%      2.19
  copy        0.0     70.4    88.1%      3.52

  1.76x spread between copy (70.4) and prose (40.1)
  Do not quote one of these as 'decode tok/s' for this cluster.
```

## Why this is not a flag on `vllm-bench-serve`

That workspace wraps `vllm bench serve --dataset-name random`, and **random
tokens are the problem rather than an implementation detail**: they have no
structure for a drafter to predict, so every measurement taken through them
understates acceptance — identically, which is why the sweep still ranks
configurations correctly and still misses this entirely.

The axis cannot be expressed by varying the arguments to a tool whose corpus is
noise. So this is a direct client, like `vllm-quality-gate`,
`spec-decode-accept` and `vllm-prefill-ladder`. `vllm-bench-serve` wrapping an
upstream tool is the exception in this directory, not the rule.

## Two things that would otherwise mislead

**`entropy` runs at temperature 0.8, and that is not a preference.** At
temperature 0 it degenerates into repetition, which the drafter then predicts
easily — so it reads as the *fastest* task for exactly the wrong reason.
Temperature travels with the task here rather than being one flag over all of
them, so this cannot be turned into a footgun from the command line.

**Every run sets `ignore_eos`,** so each decodes exactly `--decode` tokens. A
task that stops early otherwise reports its rate over a shorter, easier window
than the others, which is not a comparison.

## Reading it

- **A flat spread across all four** on a server with speculative decoding
  enabled means the drafter is not contributing — check
  `ws up spec-decode-accept` for per-position acceptance.
- **`accept` and `per step` blank** means the server exposes no
  `vllm:spec_decode_*` counters: either speculative decoding is off, or it is
  not a vLLM server. The tok/s column is still valid.
- **`copy` not being fastest** is the interesting result, and it usually means
  the prompt is not actually being retrieved from context — raise `--context`
  and check the reply is quoting rather than inventing.

## Sources

- [MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks) — the task set and the finding (AGPL-3.0-or-later; independent implementation)
- [vLLM metrics design](https://docs.vllm.ai/en/latest/design/metrics/)
