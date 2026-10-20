# `tensorfold-qwen38-flash-next-spark` — Qwen3.8-Flash-Next on ONE Spark

**Nodes: 1** · **Memory: ~108 GiB at start** · **Port: 8901** · **Engine: TensorFold (native Zig)** · **Status: `unverified` — not booted here; nothing in the memory arithmetic is ours yet.**

Serves Qwen3.8-Flash-Next with [MiaAI-Lab's single-Spark TensorFold
kit](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
(MIT) at a pinned commit: TensorFold's `tensorfold-native` Zig engine, NVIDIA's
quantization-aware-distilled
[`Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
checkpoint by default, INT4-AutoRound optional. It exists because one Spark can
now carry the model this cluster serves across two — and because it cannot
carry everything the two-node server carries. The whole workspace is a trade;
this page is the terms.

## Why reach for this

The decode numbers, upstream's, sparkDash on a Spark with the kit's default
configuration (FP4, 262,144-token window, fp8 KV, vision on, MTP depth 6):

| | this workspace (1 Spark) | [`vllm-2node-qwen38-flash-next`](../vllm-2node-qwen38-flash-next/README.md) (2 Sparks, vLLM) |
|---|---|---|
| prose decode, 1 stream | **46–55 tok/s** | 33.1 tok/s |
| code decode, 1 stream | **67.9 tok/s** | 37.7 tok/s |
| aggregate decode | 132.7 (5 streams) | **179.1 (8 streams)** |
| prefill, 16k–131k | 2,197–2,501 tok/s | **3,253–3,286 tok/s** |
| window | 262,144 native (1M with auto-YaRN, scratch unbudgeted) | 262,144 native, **985,510 validated with YaRN** |
| concurrency | 5 (refused, not queued) | 8 |
| second Spark | **free for another model** | spent |

So: for one reader at a time — a terminal, a harness, this repo's own
`agent/` workspaces pointed at its model — a single Spark is FASTER than the
pair, and the pair's second node opens up for
[`tensorfold-2node-glm53-flash-exl3`](../tensorfold-2node-glm53-flash-exl3/README.md)-shaped
work or a second model. For concurrency, long cold prefills, and the 985k
retrieval this repo measured, the pair still wins. It is a different point on
the curve, not a smaller version of the same one.

**And it is a different checkpoint.** The kit serves NVIDIA's QAD FP4 export
(model card: GPQA Diamond 91.5% / ToolEvalBench 88.7% vs 92.2 / 89.4 bf16,
upstream's numbers) with all 512 experts and the n-gram table loaded off-GPU;
the vLLM pair serves the `...-NVFP4` export (92.6 GPQA band) with its 51 GB FP8
table resident. fp8 KV is lossy (~98.8% top-1 agreement with bf16). Decide it
on your own corpus with `vllm-quality-gate` and `quant-quality-ab` — they read
any OpenAI endpoint.

## Requirements

- **One Spark, alone.** ~108 GiB of MemAvailable at start (81 weights+table,
  4.4 fp8 cache for one 262k window, 8 prefill scratch, 2 vision, 10 reserve
  floor, 2 slack). With the 2-node vLLM up there is ~6 GiB free, so this
  refuses — correctly. `ws down vllm-2node-qwen38-flash-next` first; that
  server answers your running sessions, so nothing in this repo will do it
  for you.
- **Disk ~160 GB** on the node you run it from: 96 GiB checkpoint + 18, and
  40 for the image. `odysseus` clears this; `poseidon` (125 GB free at the
  2026-10-20 measurement) does not today.
- **First run builds the image.** The FP4 loader is patches 0011–0013 and the
  tuning is 0013–0015; the published `:latest` image is 1.0.0 (patches ≤0010,
  INT4-era) and CANNOT serve the FP4 checkpoint. `scripts/prepare.sh` runs
  automatically: the `nvcr.io/nvidia/pytorch:26.07-py3` base plus a ~6-minute
  Zig 0.17.0 compile on the Spark, AOT Triton sm_121 kernel set included.
  `CHECKPOINT=int4` instead pulls the published image.

## Running it

```bash
ws up tensorfold-qwen38-flash-next-spark            # clone, build, download, serve
ws up tensorfold-qwen38-flash-next-spark restart    # after a .env change
ws logs tensorfold-qwen38-flash-next-spark -f
ws down tensorfold-qwen38-flash-next-spark
```

`ws up` first run: fetches the pinned kit to `~/.cache/gx10-kits/`, then hands
to the kit's own `start.sh`, which downloads the checkpoint (~96 GiB —
hours on a cold cache), builds the image, prints the memory verdict
(`~108 GiB`), loads, and smoke-tests. The 90-second of logs you will want to
watch: `docker logs -f qwen38-flash-next-tf`. `DRY_RUN=1 ws up
tensorfold-qwen38-flash-next-spark` prints the exact `docker run` first.

Then the usual questions, pointed at 8901 - with one engine-specific
substitution. `tensorfold-native` returns **no token probabilities**: it
answers `logprobs: true` with HTTP 400 (kit README:503), and
`bench/spec-decode-accept` reads them, so that workspace has nothing to
measure here. Acceptance on this engine is proven differently, by the kit's
own tool: drafted replies must equal plain ones, by token hash.

```bash
BASE_URL=http://127.0.0.1:8901/v1 ws up vllm-quality-gate    # chat only - no logprobs
BASE_URL=http://127.0.0.1:8901/v1 ws up decode-content-mix   # tok/s by corpus
python3 tools/exact.py http://127.0.0.1:8901 record ...      # DRAFTS=0 vs DRAFTS=1 hashes
python3 tools/toolcheck.py                                   # from the kit checkout
```

## Configuration

Everything lives in the kit's `scripts/config.sh`; this workspace's `.env` is
read by `up.sh` and exported, and the kit honours the environment above its
own defaults and its own `.env`. The knobs that matter here (kit defaults
shown):

| | default | notes |
|---|---|---|
| `CHECKPOINT` | `nvfp4` | `int4` = azampatti's GPTQ INT4-AutoRound: faster still on this hardware (prose 64.4 @1 stream, per the kit), ~10% lower capability on the authors' harness, and its 51→26.8 GiB table stays GPU-resident |
| `CONTEXT` | `262144` | native. `1048576` engages auto YaRN x4; a full-1M prompt's scratch is not budgeted on one Spark |
| `PARALLEL` | `5` | 1–16; five full 262k windows (21.9 GiB fp8) fit the measured 24.36 GiB pool, six do not |
| `KV_DTYPE` | `fp8` | 17,888 B/token vs bf16's 30,784; `bf16` is exact |
| `TF_FLASHNEXT_DEPTH` | `6` | MTP drafts a round; deeper (the engine's 15) loses 5–20% at 3–5 streams |
| `TF_FLASHNEXT_FILL_FAIR` | `0` | opt-in sliced prompt fills: a short request behind five 100k prompts waits ~2 s instead of minutes, for ~20% of mixed-load time |
| `SERVED_NAME` | `Qwen3.8-Flash-Next` | **the 2-node vLLM server uses lowercase `qwen3.8-flash-next`** — set this to match your clients, or expect `model not found` after a swap |
| `PORT` | `8901` (here) | the kit's own default 8888 is the generic two-node recipe's port |

## What is NOT verified, and what would falsify it

Nothing above is a number this repo took. The first boot must reproduce, in
order: the memory verdict (108), load with no
`NV_ERR_NO_MEMORY` kernel spam (the kit's patches 0010 exists for
580.173.02/6.17.0-1029-nvidia — our exact kernel), a clean smoke, and the
drafted-equals-plain check (`tools/exact.py` above). If prose decode lands in
the 46–55 band here, the trade in the table above is real for this pair.
Known upstream limits, recorded as found: single-rank only (patches
0014/0015 explicitly target one rank), no logprobs, and the `...FP4-Local`
card's quality figures are theirs, not a local measurement.

## Licence

The kit is MIT (c) 2026 MiaAI-Lab; TensorFold itself is Apache-2.0 from
v0.6.0 / MIT before (the pinned `db281878` zig branch is pre-0.6.0-era); the
FP8-KV mechanism in its patches descends from the AGPL GLM recipe, which the
kit's own NOTICE carries — run the kit, do not lift its patch files into
this repo. Checkpoint: NVIDIA Open Model Agreement (+ Qwen Community License
1.0); the INT4 option: Qwen Community License 1.0. The `nvcr.io` base image
carries NVIDIA's SLA on pull.

## Sources

- [`MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold`](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold) @ `656879f`
- [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local) @ `b9ce18a6`
- `docs/decisions.md#kit-runner-workspaces` — why this runs the kit rather than re-implementing it
