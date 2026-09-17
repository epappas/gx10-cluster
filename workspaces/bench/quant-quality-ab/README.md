# quant-quality-ab

> Did this quantisation change the **answers**? Machine-graded tasks, A/B
> against a saved baseline. **Exits non-zero** only on a regression.

| | |
|---|---|
| Kind | `bench` — a **client**, not a server. Coexists with a serving workspace |
| Engine | any OpenAI-compatible endpoint |
| Reads | `http://127.0.0.1:8888/v1` by default — set `BASE_URL` |
| Writes | a JSON run file, when you pass `--save` |
| Exit status | **0** unless a task that passed in the baseline now fails |
| Provenance | `unverified` — but its **grading is tested offline** in `make check` |

## What

The fourth question, and the one nothing else here asks:

| | asks |
|---|---|
| `make bench` | is the **hardware** fit to run work? |
| `vllm-bench-serve` | how **fast** is this server? |
| `vllm-quality-gate` | is the **serving layer** faulty — garbled, empty, drifting? |
| **`quant-quality-ab`** | did this **quant** change what the model says? |

The gate deliberately hunts serving faults and says outright that it does not
judge model quality. That leaves a real gap, because the quant knobs this repo
hands people are not capacity knobs alone:

- **fp8 KV on sparse attention** — quantised *keys* change which blocks the
  indexer **selects**, not merely the attention output. The failure mode is a
  wrong answer, not a slow one.
- **FP8 dense projections** — ≈2.6% relative RMSE per tensor at the E4M3
  rounding floor.
- **reduced draft vocabulary** — output-safe by construction, but the
  acceptance it costs belongs beside the rest of the picture.

None of those moves a tok/s number, and none of them trips a serving detector.
A server that got 3% worse at arithmetic looks perfect on every other view in
this repo.

## Run it

```bash
# 1. baseline, on the configuration you trust
BASE_URL=http://127.0.0.1:8896/v1 ws up quant-quality-ab --save bf16.json

# 2. change the knob, restart the server

# 3. the same run, compared
BASE_URL=http://127.0.0.1:8896/v1 ws up quant-quality-ab --save fp8.json --compare bf16.json
```

A run with no `--compare` prints a score and exits 0. **It is a baseline, not a
verdict** — there is no defensible absolute score for "this model is correct".

```
quant-quality-ab  http://127.0.0.1:8896/v1  model=qwen3.8-flash-next
greedy, machine-graded, reasoning stripped before grading

reasoning  8 graded tasks, greedy
  arith_chain      pass  98
  trains           pass  20:00
  ...
needles    3 depths in ~8000 tokens of filler
  alpha     @  5%   pass  7391-CORAL
  bravo     @ 50%   pass  2648-INDIGO
  charlie   @ 95%   FAIL  I could not find a charlie code

10/11 tasks passed

against 2026-09-08T09:14:02+0100   11/11 -> 10/11
  - needle_charlie_95pct REGRESSED  I could not find a charlie code

1 regression(s). The quant changed the answers, not just the speed.
```

## Reasoning at depth, and why it is separate from needles

A needle proves the model can **find** a literal string. It does not prove the
model can **use** it. Extended rope and KV quantisation can both leave a single
sharp lookup intact while degrading a multi-step combination — so the suite
plants facts at 8 / 30 / 62 / 92% and asks questions that need at least two of
them combined: sums, a three-way total, a comparison, a difference, and an
ordering that pairs a number near the front with an audit date near the back.

**`absence_guard` is the one that holds the rest up.** It asks about a depot
that was never planted and accepts only a refusal. A model that confabulates
there would also "pass" the needle suite by confabulating, and this tool would
report a healthy server. `make check` asserts that task can never accept a bare
number, and that `"The delta depot holds 12 crates"` grades as a failure.

Measured on `vllm-2node-qwen38-flash-next` at 1M/YaRN: **17/17 at 8k, 128k,
400k and 985k**, with `deep_order` combining facts ~830,000 tokens apart.

## Why it is built this way

**Greedy, always.** Temperature 0 and a fixed seed. A comparison between two
*sampled* runs measures the sampler.

**Machine-graded.** Every task has an answer checkable by substring, so the
score is not another model's opinion.

**Reasoning stripped before grading.** A model that reasons its way to the right
answer and one that states it are the same result. More importantly, a model
that mentions the right answer inside its scratchpad and then states the wrong
one must **not** be credited — that is the check most likely to rot silently,
and `make check` pins it.

**Needles at depth are the point, not decoration.** Retrieval from a long
context is precisely what block selection decides, so it is the direct probe for
a KV-cache quantisation. The salt goes *first* in the prompt so the whole
prefix-cache block chain behind it is invalidated — a cached run measures
nothing about block selection.

**A/B, not a threshold.** The honest question is whether *this* server on *this*
checkpoint answers the same as before the knob moved. Regressions fail; an
improvement is reported and never punished, because a tool that fails on good
news gets run once and then never again.

## Reading a failure

- **`empty (raise --max-tokens?)`** — a reasoning model spends the budget
  *thinking* first. An empty `content` with `finish_reason: length` is a budget
  problem, not a quality one. Raise `--max-tokens` before believing a regression.
- **A needle failing only at 95%** points at block selection at depth, which is
  the expected shape of a KV-quantisation regression.
- **Reasoning tasks failing while needles pass** points at the dense path
  (weights, not cache).
- **`! different model`** — the comparison keys on task names, not on the
  server. Two different models is a category error, usually a `BASE_URL` left on
  the wrong port.

## What it does not do

It does not benchmark, and it does not judge whether an answer was *good* — only
whether it matched a fixed accepted answer. Eleven tasks is a smoke test for
regression, not an evaluation suite. If you need real numbers, run a real eval
harness; this exists to tell you that a knob you turned changed something a
tok/s number would never show.

## Upstream has since measured the cost side, independently

The argument this workspace exists to test — that quantising *keys* changes
which blocks a sparse indexer **selects**, so the failure mode is a wrong
answer rather than a slower one — now has a throughput measurement beside it.
MiaAI-Lab's three-arm re-run (2026-09-16) reports fp8 KV costing **−5.3% mean
decode** (−1.4% prose, −9.2% code, growing with concurrency) for **1.80×** the
cache, with `tok/step` falling in **8 of 8 cells** — consistent with exactly
the indexer perturbation described here, showing up as acceptance rather than
as an error.

So fp8 KV is a capacity trade, not a free win. That does not change what this
tool grades — quality is still the question, and their re-run does not measure
it — but it does mean the tokens-per-GiB argument for turning it on should be
quoted with its throughput cost attached.
→ [decisions.md#glm53-indexer-workspace](../../../docs/decisions.md#glm53-indexer-workspace)

## Sources

- [MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks) — the fp8-KV quality argument and the task shape (AGPL-3.0-or-later; this is an independent implementation)
- [vLLM quantization docs](https://docs.vllm.ai/en/latest/features/quantization/)
- [LLMTest_NeedleInAHaystack](https://github.com/gkamradt/LLMTest_NeedleInAHaystack) — the needle method
