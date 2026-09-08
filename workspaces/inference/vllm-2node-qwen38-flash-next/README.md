# vllm-2node-qwen38-flash-next

> Qwen3.8-Flash-Next NVFP4 across both Sparks — TP2 + expert parallel + MTP3.
> **Two mandatory patches are not written yet**, and `up.sh` refuses to launch
> until they are.

| | |
|---|---|
| Kind | `inference` — starts a model; no two of these co-exist |
| Engine | vLLM, on a **day-0 image this repo did not choose** |
| Nodes | **2** |
| Memory | ~64.5 GiB of weights + ~32 GiB of KV per node |
| Port | 8896 (rank 0) |
| Provenance | `verified` on odysseus + poseidon — [numbers below](#measured-here) |

## What

The 48-layer hybrid Flash-Next checkpoint split across both nodes: NVFP4 routed
experts, a 51 GB FP8 PLE n-gram table, BF16 dense, and a multi-token-prediction
draft head worth ~2.13× on batch-1 decode.

Every number on this page is attributed to the reference kit in
[sources](#sources). None of it was measured here.

## <a name="measured-here"></a>Measured here

Cold, from nothing on either node: no image, no checkpoint, no `.env`. Every
number below was taken on odysseus + poseidon; the reference-kit column is from
[the upstream recipe](#sources) and is *their* hardware, not ours.

**Configuration under test**

| | |
|---|---|
| Model | `nvidia/Qwen3.8-Flash-Next-NVFP4` — 124 GB on disk, 11 shards |
| Nodes | odysseus + poseidon, GB10 sm_121, 121.7 GiB unified each |
| Topology | TP=2 + expert parallel (256/512 experts per rank), MTP=3 |
| Image | `vllm/vllm-openai:qwen38-flash-next`, 20.6 GB arm64 |
| Settings | GMU 0.80, ctx 262144, `max-num-seqs` 8, KV dtype `auto` (bf16) |

### Startup and memory

| Metric | MTP off | MTP=3 | Reference kit |
|---|---|---|---|
| Cold start to `/health` | **10m56s** | — | 10m55s |
| Weight load | 379.3s | 490.6s | 458s |
| Weights resident/node | 62.53 GiB | **64.07 GiB** | 64.46 / 64.3 GiB |
| Engine init | 126.6s | 135.0s | 92.4s |
| KV pool | 32.03 GiB | 28.99 GiB | 31.70 GiB |
| KV tokens | 2,426,193 | 1,731,567 | 2,131,159 |
| Concurrency @ 262K | 9.26× | 6.61× | 8.13× |

### Decode by content type — MTP=3, prefill excluded

| Task | 1k ctx | 32k ctx | Acceptance | Accepted/step |
|---|---|---|---|---|
| **copy** | **61.2** | **61.6** | 88.7% | 2.66 |
| code | 37.4 | 40.1 | 51.3% | 1.54 |
| entropy (t=0.8) | 40.6 | 28.2 | 48.5% | 1.45 |
| prose | 33.1 | 37.7 | 42.9% | 1.29 |
| **spread** | **1.85×** | **2.18×** | | |

### MTP off vs on

| | MTP off | MTP=3 |
|---|---|---|
| content spread | 1.11× | 1.85× |
| fastest task | prose (26.1) | copy (61.2) |
| slowest task | copy (23.6) | prose (33.1) |
| acceptance, overall | — | 0.638 |
| acceptance by draft position | — | **0.82 / 0.63 / 0.46** |

> **The MTP-off column predates two fixes to the measuring tool** (see
> [below](#two-measurement-bugs-found-by-pushing-the-tool)), so treat its
> absolute tok/s as approximate — at 1k the error is small but real. The
> *shape* result is unaffected and is the point: with no drafter all four tasks
> land within 1.11× of each other and `copy` is the **slowest**.

### Concurrency — prose, 300 tokens, MTP=3

| Streams | 1 | 2 | 4 | **8** | 16 | 32 |
|---|---|---|---|---|---|---|
| Aggregate tok/s | 40.5 | 62.4 | 89.6 | **179.1** | 147.8 | 159.2 |
| Per stream | 41.8 | 32.3 | 24.5 | 23.7 | 19.8 | 21.4 |
| TTFT | 0.23s | 0.28s | 0.45s | **0.41s** | 7.74s | 21.62s |

**The knee is exactly `--max-num-seqs=8`.** Past it the aggregate *falls* and
TTFT rises 19–53× — requests are queueing, not running. The ceiling here is the
**scheduler**, not the KV pool, which still reports 6.61× headroom at 262K. That
flag is the knob if you want more concurrency; the cache is not the constraint.

### Prefill

| Rung | MTP off | MTP=3 | Reference kit |
|---|---|---|---|
| 8k | 3450 | 3256 | 2875 |
| 12k | 3440 | 3253 | 2962 |
| 16k | 3477 | 3286 | 2962 |

~17% ahead of the reference kit; the drafter costs ~5%.

### 1M context via YaRN — measured, and it retrieves

`MAX_MODEL_LEN=1000000`, `YARN_ENABLE=true`, `YARN_FACTOR=4.0`,
`MAX_NUM_SEQS=2`, MTP=3. Three needles per rung at 5 / 50 / 95% depth, one
haystack per rung so the first request pays the cold prefill and the other two
ride the prefix cache.

| Rung | Prompt tokens | TTFT | Prefill tok/s | Decode tok/s | Needles |
|---|---|---|---|---|---|
| 128k | 128,079 | 49.7s | 2578 | 37.6 | **3/3** |
| 256k | 256,079 | 111.1s | 2305 | 51.7 | **3/3** |
| 400k | 400,080 | 204.6s | 1955 | 62.2 | **3/3** |
| **985k** | **985,078** | **904s** | **1090** | **43.0** | **3/3** |

KV pool at this configuration: **28.91 GiB → 1,953,560 tokens, 1.95× at 1M** —
so two resident 1M requests, which is what `MAX_NUM_SEQS=2` is sized for. Note
the pool holds *more* tokens here than at 262K (1.95M vs 1.73M): vLLM re-sizes
the attention page for the longer context.

**Retrieval is clean the whole way up, including at 3.76× native context.** The
model's native window is 262,144, so everything above the 256k rung is running
on YaRN-extended rope. As far as we can tell this is the **first** validation of
that for this model: upstream emitted the YaRN override at the top level of
`--hf-overrides`, where vLLM `setattr`'d it onto the parent config and it never
reached `text_config`, so every published "1M context" run before the fix was
serving 1M positions on *unscaled* rope. This workspace nests it correctly
(confirmed in the launch args), so these are real extended-rope numbers.

**Prefill is the whole cost, and it is not linear.** Throughput falls 2578 →
1090 tok/s from 128k to 985k (−58%), so TTFT goes 50s → **15 minutes**. Decode
stays roughly flat and does not explain any of it.

> **Two caveats on this table.** The decode column is measured over a ~15-token
> answer, so it is noisy — read it as "decode did not collapse", not as a rate.
> And retrieval passing is not the same as *reasoning* holding up at 1M; these
> needles prove the model can find a literal string, which is the necessary
> condition, not the sufficient one.

> **The 1M ceiling is exact and includes the output.** A 999,937-token prompt
> with `max_tokens: 64` is rejected at 1,000,001 — the first attempt here failed
> by one token. Size prompts to leave room for the answer.

### Reasoning at depth — not just retrieval

A needle proves the model can find a literal string. It does **not** prove the
model can *use* what it found. Extended rope and KV quantisation can both leave
a single sharp lookup intact while degrading a multi-step combination, so the
two questions are asked separately.

Facts planted at **8% / 30% / 62% / 92%** of the context, questions that each
require combining at least two of them:

| Task | Needs | 8k | 128k | 400k | **985k** |
|---|---|---|---|---|---|
| `deep_sum` | 47 + 23 across 8%→30% | ✅ | ✅ | ✅ | **✅** |
| `deep_three_sum` | three depots, 8%→62% | ✅ | ✅ | ✅ | **✅** |
| `deep_compare` | largest of three | ✅ | ✅ | ✅ | **✅** |
| `deep_difference` | 47 − 15 across 8%→62% | ✅ | ✅ | ✅ | **✅** |
| `deep_order` | crates + an audit fact at 92% | ✅ | ✅ | ✅ | **✅** |
| **`absence_guard`** | **must refuse to invent** | ✅ | ✅ | ✅ | **✅** |
| **total (with needles + short tasks)** | | **17/17** | **17/17** | **17/17** | **17/17** |

At 985k those spans are large in absolute terms: `deep_order` combines facts
about **830,000 tokens apart**, and `deep_three_sum` spans ~530,000. A correct
answer means both operands survived the whole window, not one attention
neighbourhood.

**`absence_guard` is the load-bearing task.** It asks for a depot that was never
planted, and the model answered `NOT MENTIONED` at every rung including 985k. A
model that confabulates there would also "pass" the needle suite by
confabulating, and the whole harness would report a healthy server. `make check`
asserts this task can never accept a bare number, and that a fabricated
`"The delta depot holds 12 crates"` is graded as a failure.

> **What this does and does not establish.** It establishes that retrieval,
> multi-fact combination and refusal all survive to 3.76× native context on
> YaRN factor 4.0. It does not establish that *hard* reasoning does — these are
> small-integer arithmetic and comparison, deliberately, so that a wrong answer
> is unambiguous. Long-context quality on your own workload still needs
> measuring on your own workload.

### Correctness

| Test | Result |
|---|---|
| `quant-quality-ab`, MTP off | **11/11** |
| `quant-quality-ab`, MTP=3 | **11/11**, no regressions vs the MTP-off baseline |
| `quant-quality-ab`, needles @ 32k | **11/11** — all depths retrieved, including 95% |
| `vllm-quality-gate` @ `max_tokens` 1024 | 12/18 |
| `vllm-quality-gate` @ `max_tokens` 4096 | **17/18** — survivor flagged `HEALTHY tail` by the gate itself |

Speculative decoding changing no answer is the bar MTP has to clear, and it
cleared it. The 1024 → 4096 jump was **tested, not assumed**: thinking is billed
against the budget first, so this model needs 4k+.

### Infrastructure

| | |
|---|---|
| Transport | RoCE, **both rails**, 200 Gb/s — NCCL discovered them itself, unpinned |
| Checkpoint download | 123.6 GiB at ~103 MB/s over WAN |
| Staging to peer | **132.7 GB in 4m59s, 422 MB/s** over the interconnect |
| Image pull | 9.7 GB compressed → 20.6 GB, both nodes in parallel |

### The content spread is acceptance, not hardware

Two things fall out of the decode table:

**Decode is flat from 1k to 32k.** `copy` moves 61.2 → 61.6, `code` 37.4 → 40.1.
That is the hybrid design showing up in measurement: only every 4th of 48 layers
is full attention, and the other 36 are Gated-DeltaNet whose state is constant
per *request* rather than per token. Long context costs prefill, not decode.

**The spread is acceptance.** With MTP off all four tasks sit within 1.11× and
`copy` is slowest. Turn the drafter on and `copy` nearly doubles while prose
gains a quarter — in proportion to how predictable the text is. A single "decode
tok/s" for this cluster is therefore a claim about a corpus, which is why
[`decode-content-mix`](../../bench/decode-content-mix/README.md) exists.

### <a name="two-measurement-bugs-found-by-pushing-the-tool"></a>Two measurement bugs, found by pushing the tool to 32k

Both were in our own benchmark and both produced *plausible* wrong numbers,
which is the dangerous kind:

1. **`--context` was prepended only to the task that quotes from it.** At 32k
   that meant `copy` decoded against 32k of KV while the other three attended
   over ~50 tokens. It surfaced as `copy` holding the **highest** acceptance
   (82.2%) and the **lowest** throughput — which reads as "acceptance does not
   predict throughput" and was really "these four numbers were not taken under
   the same conditions".
2. **The rate included prefill.** About 9s of a 22s request at 32k, so the
   headline "decode tok/s" was ~40% a prefill measurement.

Fixed: context is applied to every task, and decode is measured first-token to
last-token over a stream with TTFT reported separately. Post-fix, throughput and
acceptance rank **identically** across all four tasks at 1k. Every decode number
on this page is post-fix.

> **TTFT inside the content table is order-dependent** and must not be compared
> across rows: the tasks share one context, so the first pays the cold prefill
> and the rest hit the prefix cache (measured at 32k: 9.92s, then 2.34 / 1.11 /
> 0.79). Use [`vllm-prefill-ladder`](../../bench/vllm-prefill-ladder/README.md)
> for real TTFT.

### Why decode trails the reference kit

Attributable rather than mysterious: they run fp8 KV (worth 1.70× tokens per
GiB, [not ported here](#kv-dtype-the-default-here-is-not-the-reference-default))
plus a reduced MTP draft vocabulary, at GMU 0.835 against our 0.80. On prefill,
where none of those apply, we are ~17% ahead.

## What is still not measured

fp8 KV (deliberately not ported — AGPL), vision, and `--max-num-seqs` above 8.
Long-context *reasoning* is now measured to 985k, but only on small-integer
arithmetic and comparison — hard reasoning at depth is still open.

## The three patches

All three are written and mandatory; `up.sh` refuses to launch without them and
stages them to both ranks. `./extract-sources.sh` re-pulls the image sources if
you need to re-anchor them after an image update.

| patch | what it does | measured |
|---|---|---|
| `ple_fp8_resolver` | lets the FP8 PLE table load out of an NVFP4 checkpoint | without it vLLM builds a ~102 GB BF16 embedding |
| `mxfp8_kernel_fallback` | routes shapes `mm_mxfp8` cannot run to BF16 emulation | **present but not exercised** by this checkpoint — no shape tripped it |
| `fp8_block_moe` | builds the block-scaled FP8 MTP experts | **required for MTP**; without it the load dies at `w2_weight_scale_inv` |

Two things the upstream write-up gets differently, both measured here:

- the MTP expert algo on disk is **`FP8_PB_WO`**, not `FP8_BLOCK_SCALES`;
- **the config-file MTP alias does not reach the dispatch** — `apply_vllm_mapper`
  rewrites `quantized_layers` on the draft-model path, so the fix has to live
  inside `get_quant_method`. [Detail](patches/README.md).

## Run it

```bash
ws check vllm-2node-qwen38-flash-next     # on BOTH nodes - it can only see one
ws up    vllm-2node-qwen38-flash-next
ws logs  vllm-2node-qwen38-flash-next -f
```

`up.sh` downloads the checkpoint on a cold cache and stages it to the peer over
the interconnect rather than paying the WAN twice — ~534 MB/s measured on the
sibling workspace against ~56 MB/s per rank from the Hub.

Cold start on the reference kit was **~11 minutes**: NCCL setup ~40 s, weight
load 458 s, engine init 92 s, graph capture ~7 s. The first request after that
is also slow while FlashInfer autotunes. Neither is a hang.

## The arithmetic, which inverts the usual advice

```
NVFP4 checkpoint           ~133 GiB on disk (11 shards)
per-GPU weights at TP2+EP   ~64.5 GiB    experts ~34 + PLE shard ~25 + dense ~10
budgeted at GMU 0.835      ~101.6 GiB    of the 121.69 GiB CUDA sees
left for KV                  ~32 GiB
```

**Weights, not KV, are what eats this box** — which is the opposite of every
other two-node workspace here. Of 48 layers only every 4th is `full_attention`
(`full_attention_interval: 4`), so there are **12 KV-bearing layers plus 1 MTP
draft layer**. The other 36 are Gated-DeltaNet linear attention, whose state is
constant per *request* rather than per token.

That is why 32 GiB of pool holds 2.13M bf16 tokens — a 262K context over eight
times — while `--max-num-seqs` is 8. At these defaults **the scheduler, not the
cache, is the limit**, so raising concurrency is cheap here and raising context
is what costs.

## KV dtype: the default here is not the reference default

`auto` (bf16), where the reference kit runs `fp8` and measures **1.70× the
tokens per GiB** (3,652,200 against 2,131,159 — not 2×, because the QSA indexer
and compressor stay BF16 and only the main K/V halve).

fp8 needs a patch to the QSA kernels, which declare
`supported_kv_cache_dtypes = ["auto", "bfloat16"]` and **raise rather than
degrade**. That patch is the one piece of the upstream work this repo
deliberately did not port — it is AGPL-3.0-or-later against an MIT repository,
and unlike the two mandatory patches it buys capacity rather than the ability to
load at all. [Why that call went the way it did](../../../docs/decisions.md#qwen38-flash-next).

When someone writes a clean one, treat fp8 as a **quality** trade and not only a
capacity one: quantised keys change which blocks the sparse indexer *selects*,
not merely the attention output. `ws up quant-quality-ab` is the harness for
exactly that question.

## Once it is up, ask what a tok/s number cannot answer

```bash
BASE_URL=http://127.0.0.1:8896/v1 ws up spec-decode-accept   # is MTP working?
BASE_URL=http://127.0.0.1:8896/v1 ws up vllm-quality-gate    # answering correctly?
BASE_URL=http://127.0.0.1:8896/v1 ws up quant-quality-ab     # did a quant change answers?
```

Acceptance is the only number that proves the drafter. The reference kit reports
72.8% overall, decaying **89% / 74.5% / 60%** by draft position — and that decay
is the check that matters, because a wrong expert block shape shows up as
near-random acceptance rather than as a crash.

## Gotchas

- **`--mm-encoder-tp-mode data`, not `weights`.** NVFP4 kernels want input
  features divisible by 16; the vision MLP intermediate is 4304, which is not,
  after TP=2 (4304/2 = 2152). Sharding it crashes at load.
- **The `--hf-overrides` nesting is load-bearing.** Upstream shipped these at
  the top level for months, where vLLM `setattr`'d them onto the parent config
  and they never reached `text_config` — so YaRN was a silent no-op and every
  earlier "1M context" run served 1M positions on *unscaled* rope. `up.sh` nests
  them, which means 1M here has genuinely never been measured by anyone.
- **`PLE_OFFLOAD` is not exposed**, deliberately. It needs ~51 GB of free CPU
  RAM and the reference kit measured 44.92 GiB available at target-weight load —
  offloading there OOMs or thrashes swap. The FP8 PLE shard fits on the GPU.
- **Drop page caches before a launch** that hits a `CUDA out of memory` which
  "worked yesterday" on unified memory:
  `sync && echo 3 | sudo tee /proc/sys/vm/drop_caches`.
- **`.env` beats the environment.** `FOO=x ./up.sh` is silently ignored for any
  key `.env` already defines.

## <a name="sources"></a>Sources

- [MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks) — the two-node recipe every measurement here comes from (AGPL-3.0-or-later)
- [getrefined/Qwen3.8-Flash-Next-NVFP4-vLLM-DGX-Spark](https://github.com/getrefined/Qwen3.8-Flash-Next-NVFP4-vLLM-DGX-Spark) — the single-node base it builds on
- [nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4) · [RadixArk/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/RadixArk/Qwen3.8-Flash-Next-NVFP4)
