# vllm-2node-glm53-flash-exl3

> GLM-5.3-Flash at **EXL3 4bpw**, tensor-parallel across **both** GX10s over
> RoCE, **1M context**, vision on, DFlash2 speculative decoding. **The default
> way to run GLM on this cluster** — and the only workspace here that does not
> run an upstream image.

| | |
|---|---|
| Kind | `inference` |
| Engine | vLLM (overlay container, both nodes) |
| Nodes | **2** — rank 0 serves, rank 1 is headless |
| Endpoint | `http://127.0.0.1:8893/v1` **on the rank-0 node** |
| Model id | `glm-5.3-flash-exl3` |
| Needs | **~106 GB unified *per node*** · ~180 GB disk *per node* · Docker · ACTIVE RDMA · 1 peer |
| Provenance | **`verified`** — kpool patch applied, DFlash2 acceptance **0.985**, gate 4/4. [Three things this box needed](#three-things-this-box-needed) |

## What

[GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) quantised to
**EXL3/TR3 4 bits per weight** on the routed experts — dense layers, shared
experts, attention, embeddings and `lm_head` stay native. ~164 GiB across 120
shards, which is ~82 GiB of weights per node at TP=2.

Ported from
[MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks),
the only published configuration for this model on this hardware. What was
taken, what was left, and what this repo does differently:
[decisions#glm53-flash](../../../docs/decisions.md#glm53-flash).

**Full two-node mechanism, prerequisites and debugging:
[the two-node serving runbook](../../../docs/runbooks/two-node-serving.md).**

## Why

### Why EXL3, when this hardware exists for NVFP4

Everywhere else in this repo the answer is NVFP4 — it is the native format for
GB10's Blackwell FP4 tensor cores. Here it is not, and the reason is measured
rather than architectural. From an independent teacher-logit panel over 25
sealed windows (51,175 positions), KLD against the FP16 teacher:

| Checkpoint | Mean KLD (nats) | Size |
|---|---:|---:|
| TR3 K6 (6bpw) | 0.013723 | 254 GB |
| Official FP8 | 0.020615 | 328 GB |
| **This one — EXL3 4bpw** | **0.024555** | **176 GB** |
| NVFP4 | 0.060535 | ~180 GB |

**NVFP4 is ~2.5× the divergence of EXL3 at the same size.** 4bpw matches
official FP8 quality at 54% of the bytes, and it is the only row that leaves
enough of two nodes free to hold a KV cache. *(Confidence: published panel, not
measured here — [source](https://huggingface.co/brandonmusic/GLM-5.3-Flash-tr3-4bpw/discussions/1#6a9144846b0bdba943bfe86f).)*

### The arithmetic

| | |
|---|---|
| EXL3/TR3 4bpw checkpoint | ~164 GiB (120 shards) |
| Split TP=2 | ~82 GiB of weights **per node** |
| Claimable at `0.87` | ~105 GiB per node (of 121 GiB unified) |
| **Left for KV** | **~19 GiB per node** |

That is the smallest KV budget in this repo, and **1M context still allocates
on it**. That is not a contradiction, and understanding why is the difference
between tuning this model and fighting it.

### Why 1M fits in 19 GiB, and why 256k does not fit better

GLM-5.3-Flash is a **hybrid**: 12 MLA attention layers and 33 mamba layers.

| Piece | Cost | Scales with context? |
|---|---|---|
| Target MLA, 12 layers | packed `fp8_ds_mla`, 656 B/token/layer | **yes** |
| Mamba, 33 layers | window / state | **no** — essentially fixed |
| DFlash2 drafter, 5 SWA layers | bf16, ~2 KB/token | window-bounded |

So the pool is a **large fixed floor plus a small per-token slope**. A 1M cap
costs far less than the same number would on a dense model, and shrinking the
cap does not refund the floor. Reported occupancy on the source kit: 36k
context → 16%, 256k → ~25%, 300k → 26%.

**This is why `MAX_MODEL_LEN=256000` is the first wrong move.** The logged pool
is roughly *concurrency × the cap*, so a smaller cap shrinks the number it was
supposed to grow, and the floor stays exactly where it was.

### Why `--kv-cache-dtype fp8` has no alternative

The SM12x sparse-MLA kernel accepts **only** packed `fp8_ds_mla`.

- **bf16 KV has no sparse kernel on this architecture at all.**
- **NVFP4 KV exists on SM12x and is the wrong kernel** — FlashInfer's NVFP4
  paths are dense MHA, not sparse MLA. A working NVFP4-KV recipe for another
  model is not evidence it applies here, and `nvfp4_ds_mla` (which
  [`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md)
  mentions) belongs to a different fork lineage and a different model.

### Why an overlay image, when this repo declines forks

[decisions#two-node-vllm](../../../docs/decisions.md#two-node-vllm) says taking
a fork means inheriting one project's release cadence for every future model,
and that trade was refused for DeepSeek. It is accepted here because the
situation is not the same one:

| DeepSeek-V4 | GLM-5.3-Flash |
|---|---|
| Upstream vLLM **can** serve it — the fork is faster | Upstream vLLM **cannot** serve it at all |
| Declining the fork costs ~8–9% decode | Declining the image costs the model |

Upstream has no `exl3` quantisation method, and it dies on the first forward
with `pe_dim must be 64 for fp8_ds_mla` because this model is **NoPE MLA**
(`qk_rope_head_dim=0`) while the only SM12x sparse-MLA backend expects a
656-byte record with a RoPE section. Neither is reachable from a flag. The
image is public, arm64, built `FROM vllm/vllm-openai` for CUDA 13.0 at
`TORCH_CUDA_ARCH_LIST=12.1a`, and this workspace is the only place in the repo
that uses it.

## When to reach for this one

| | Use |
|---|---|
| You want GLM-5.3-Flash, and both nodes are free | **This** |
| You want a long-context agentic model and do not care which | This or [`vllm-2node-deepseek-v4-flash`](../vllm-2node-deepseek-v4-flash/README.md) — Flash is 128K here, this is 1M |
| One node is busy | Neither. This needs ~106 GB on **each** |
| You want to serve something on an upstream image | Anything else in this directory |

## How

```bash
# Once: get 164 GiB onto BOTH nodes without paying for it twice
ml && hf download Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw
ml && hf download incoai/GLM-5.3-Flash-DFlash2
./stage-weights.sh                 # rsync to the peer over the CABLE

ws check vllm-2node-glm53-flash-exl3      # on BOTH nodes
ws up    vllm-2node-glm53-flash-exl3
docker logs -f ws-vllm-glm53-exl3

# ALWAYS, before believing any number:
docker logs ws-vllm-glm53-exl3 2>&1 | grep -E 'NET/IB|NET/Socket'

# Optional: burn the JIT shapes so the first real client is not the first
# compile. Waits for /health itself, so it can follow `ws up` immediately.
./warmup.sh

ws down  vllm-2node-glm53-flash-exl3
```

Loading ~82 GiB per node and warming up takes **minutes**, and the first run
after a fresh image also JITs kernels. `curl -s localhost:8893/health`.

### Talking to it

```bash
curl -s http://127.0.0.1:8893/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "glm-5.3-flash-exl3",
    "messages": [{"role": "user", "content": "hello!"}],
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

**Thinking is ON by default.** Turn it off with the **top-level**
`chat_template_kwargs` field shown above. Do not send a literal nested
`extra_body` object over raw HTTP — `extra_body` is an OpenAI *Python SDK*
option that merges its contents into the top level, and a server receiving it
verbatim ignores it.

The checkpoint's `generation_config.json` stamps `temperature=1.0` /
`top_p=0.95` unless the request overrides them.

### Then ask the three questions a tok/s number cannot answer

```bash
BASE_URL=http://127.0.0.1:8893/v1 ws up spec-decode-accept   # is the drafter working?
BASE_URL=http://127.0.0.1:8893/v1 ws up vllm-quality-gate    # is it answering correctly?
BASE_URL=http://127.0.0.1:8893/v1 ws up vllm-prefill-ladder --chunk-tokens 2048
```

The third is the one to run **before and after** touching
`MAX_NUM_BATCHED_TOKENS`. It is also the only check here that refuses to
believe its own numbers: prefix caching turns a rerun of the same prompt into a
5× "improvement" that is entirely an artefact, so it salts every cold prompt
and reads the cache counters to prove the rung was cold.

### The one patch this workspace carries itself

`patch_kpool_tail_slotmap.py` sits next to `up.sh`, gets staged to both nodes
and is applied **inside** each container before `vllm serve`. It is the only
third-party file this repo vendors, and it is not optional: without it the
generic paged slot-mapping kernel indexes past the K-pool tail group's single
block-table entry, and the kpool kernels write through a garbage block id.
Most overruns land inside the shared pool, so nothing crashes — another layer's
indexer is quietly corrupted instead, on generations of roughly 2k tokens and
up. If it does not apply, the container exits rather than serve.
[Why it is vendored](../../../docs/decisions.md#glm53-second-pass).

## What it costs

Published on the source kit — **not measured here**, and quoted for calibration
rather than as a target. DFlash2 k=7, temp 0, thinking off, warm.

Cold **prefill** on the same kit, for the other half of a request: ~895 tok/s at
8k (8.9 s TTFT), ~975 at 100k, ~940 at 300k — all at `MAX_NUM_BATCHED_TOKENS=2048`,
which is this workspace's default because it won a measured ladder
([#glm53-second-pass](../../../docs/decisions.md#glm53-second-pass)).

| Concurrency | TTFT | Per-stream tok/s | Aggregate tok/s |
|---|---:|---:|---:|
| ×1 | 719 ms | 62.9 | 62.9 |
| ×2 | 6.62 s | 51.7 | 103.3 |
| ×4 | 6.30 s | 37.1 | 146.5 |

Decode speed depends heavily on **what** it is generating, because that is what
draft acceptance depends on: structured output ~62 tok/s at 0.92 acceptance,
prose ~27 tok/s at 0.33. MTP instead of DFlash2 is ~24.6. A single number for
"how fast is this model" is not meaningful here.

The per-position ladders behind those two, both from the same healthy server:

| Class | pos 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Structured | 0.98 | 0.98 | 0.94 | 0.94 | 0.91 | 0.83 | 0.83 |
| Prose | 0.75 | 0.58 | 0.41 | 0.28 | 0.16 | 0.09 | 0.06 |

**A healthy prose ladder collapses.** Read a suspected draft-path fault off the
*structured* run, where a working drafter stays above ~0.8 the whole way.

## Three things this box needed

The overlay image, the mandatory kpool patch and the DFlash2 drafter all work
exactly as written. Getting there took three changes the published recipe does
not mention.

### 1. `MODEL` must be a path, not a repo id

```
FileNotFoundError: [Errno 2] No such file or directory:
  'Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw/processor_config.json'
```

**The file is present** — in the local snapshot *and* on the Hub. The overlay's
multimodal loader joins the model string with a filename instead of resolving
through the Hub, so a repo id becomes a bogus relative path. Point `MODEL` at
the snapshot directory **as the container sees it**:

```bash
SHA=$(basename "$(ls -d ~/.cache/huggingface/hub/models--Mia-AiLab--GLM-5.3-Flash-EXL3-TR3-4bpw/snapshots/*/ | head -1)")
MODEL=/hf/hub/models--Mia-AiLab--GLM-5.3-Flash-EXL3-TR3-4bpw/snapshots/$SHA \
  ws up vllm-2node-glm53-flash-exl3
```

Both nodes resolved the **same** snapshot sha, which is what makes a shared
path safe here. Check that before assuming it.

### 2. `0.87` does not fit — by 0.95 GiB

Exactly as this workspace's own note predicts:

```
ValueError: Free memory on device cuda:0 (104.87/121.63 GiB) on startup is
less than desired GPU memory utilization (0.87, 105.82 GiB)
```

### 3. And `800000` still did not fit at `0.86`

```
16.44 GiB KV cache is needed, which is larger than the
available KV cache memory (14.25 GiB)
```

**`600000` does**, at 602,033 pool tokens. So the headline 1M figure is a
property of the reference kit's headroom, not of the model — the arithmetic in
[`workspace.yml`](workspace.yml) stays correct, the free memory on *this* pair
is simply lower.

```bash
MODEL=$CSNAP GPU_MEMORY_UTILIZATION=0.86 MAX_MODEL_LEN=600000 \
  ws up vllm-2node-glm53-flash-exl3
```

### What it measured once up

| | |
|---|---|
| kpool correctness patch | `block_table.py: kpool tail slot-map patched` |
| Transport | RoCE, both rails at 200 Gb/s |
| KV pool | 602,033 tokens |
| **DFlash2, structured** | **1.00 1.00 1.00 1.00 1.00 0.95 0.95** (k=7) — aggregate **0.985** vs. 0.92 published |
| Decode | 67.4 tok/s, TTFT 0.54 s |
| DFlash2, prose | 0.358 aggregate vs. 0.33 published — the documented healthy decay |
| Quality gate | **4/4 clean** at concurrency 1, 2 |
| Cold prefill | 990–1024 tok/s at 8k/16k, ~1.95 s/chunk |

**One number left open:** prefix-cache reuse measured **0.50** efficiency (3584
of 7168 allowed) rather than the ~1.0 the hybrid-page argument predicts. Not
chased — it is a throughput question, not a correctness one, and the ladder
reports it honestly rather than rounding it up.

## When it fails

| Symptom | Cause | Fix |
|---|---|---|
| `FileNotFoundError: '<repo-id>/processor_config.json'` | The overlay's mm loader treats the repo id as a directory | Pass `MODEL` as the container-visible snapshot path |
| `Free memory … less than desired GPU memory utilization (0.87, …)` | This pair has under a GiB less headroom than the reference kit | `GPU_MEMORY_UTILIZATION=0.86` |
| `16.44 GiB KV cache is needed … available (14.25 GiB)` | 800k context does not fit the KV left at 0.86 | `MAX_MODEL_LEN=600000` |
| Startup memory check refuses, by a hair | 0.87 needs ~106 GiB free *after* vLLM's ~9 GiB init; a desktop session or dashboard is holding it | `gx10-top` to find it, or `GPU_MEMORY_UTILIZATION=0.86` + `MAX_MODEL_LEN=800000` |
| `pe_dim must be 64 for fp8_ds_mla` | You are on an upstream vLLM image, not the overlay | Do not override `IMAGE` |
| Weights load as BF16 and OOM | `--quantization` is not `exl3` | Never `marlin`, never NVFP4 weights |
| You followed the checkpoint's own Hub card and nothing works | That card documents a **different image** — the SM120 B12X build, with TP2/EP2/DCP2 and calibrated NVFP4 MLA KV. It is not this overlay, and its flags do not transfer | Follow this workspace, not the model card. `arm64` + `sm_121a` + packed `fp8_ds_mla` is the combination that runs here |
| Worker rank dies ~60 s in, `ibv_modify_qp` errno 61 | A pinned `NCCL_IB_GID_INDEX` names an all-zero GID on one card | Leave `IB_GID_INDEX` unset — NCCL selects RoCEv2 itself. `gx10-interconnect` prints the table |
| Correct output at half the speed | The draft path is broken. It costs **acceptance and nothing else** — the target still verifies every token | `ws up spec-decode-accept`. On the **structured** ladder, a healthy position 0 over a collapsed tail means something pinned `TRITON_ATTN` |
| Log says `NET/Socket` | RDMA never reached the container | [two-node-serving](../../../docs/runbooks/two-node-serving.md#the-three-things-that-fail-quietly) |
| Container restart-loops, log says `kpool tail slot-map patch did not apply` | The vendored patch could not find its anchor — the image's vLLM moved | Deliberate: it fails closed. Re-derive the patch against the new image rather than removing the call |
| `cannot stage the kpool patch to <peer>` and `up.sh` refuses | SSH to the peer failed before either rank started | Fix the peer link. Half the ranks clamped and half not is worse than not starting |
| A prefill "got faster" after a config change | The rerun hit the prefix cache — measured elsewhere as 10.3 s → 1.9 s for free | `ws up vllm-prefill-ladder`, which salts each prompt and reports `INVALID` on a rung that hit the cache |
| Reported hang after `docker rm` + restart | JIT caches were lost, one rank re-compiles mid-collective, the other trips NCCL's 600 s watchdog | Keep `JIT_CACHE` (it is on by default) |
| Long prefill crashes near 300k tokens | `--max-num-batched-tokens` at 8192 oversubscribes the GB10 indexer top-k's shared memory | Stay at the default 2048; never go to 8192 |
| Server OOMs at init with vision on | The max-size multimodal dummy profile | `--skip-mm-profiling` is on by default; do not remove it |
| Concurrent cold prefills serialise | `GLM53_MIXED_PREFILL_CHUNK=skip`, deliberately | That is the trade — the alternative stalls every stream in flight |
| Empty answer, normal `finish_reason` | A client `stop` string fired inside the reasoning block | `GLM53_SUPPRESS_STOPS_IN_REASONING=1` is on by default |

## Licensing

The recipe is this repo's. The **weights are not MIT**: the EXL3/TR3 checkpoint
is under [ShapleyMCG License 1.0](https://huggingface.co/Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw/blob/main/LICENSE),
and the DFlash2 drafter is **[CC BY-NC-ND 4.0](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
— non-commercial, research and evaluation only**. `SPEC_METHOD=mtp` drops the
drafter entirely if that matters to you.

## Provenance

`unverified` means what it means everywhere in this repo: **nobody has served
this model on these boxes.** Expect to fix something on the first run.

What *was* checked on this cluster, so the parts that are cheap to get wrong are
not:

| Claim | Checked | Result |
|---|---|---|
| The weights exist at the pinned revision | HF API | `25a44fdb…`, **120 safetensors shards, 163.6 GiB** — matches the arithmetic above |
| The drafter exists and is small enough to sit on rank 0 | HF API | **2.18 GiB** |
| The overlay image is public and pullable | GHCR manifest | HTTP 200, no login |
| This node meets `requires:` | `ws check` | ready — 112 GB unified available against the 106 needed, 242 GB free disk against 180 |
| Both ranks get identical flags | `up.sh` under a stubbed `docker`/`ssh` | Confirmed: only `--node-rank`, `VLLM_HOST_IP` and `--headless` vs `--host/--port` differ |
| The vendored kpool patch is fail-closed and idempotent | read, and its pure helpers exercised | Refuses to write when its pinned anchor has drifted; re-running it is a no-op |
| The prefill ladder's verdicts do not fire on a healthy run | `make prefill-ladder`, against the published 2026-08-29 ladder | Clean — the fixture that keeps this check from being muted |

Everything else here — the decode figures, the KLD panel, the acceptance
ladders, the KV pool sizes — is **published by the source repo and reproduced
without re-measurement**. Each is labelled where it appears. See
[provenance](../../../docs/README.md#provenance).

Note the memory line is tight: 112 GB available against 106 needed leaves ~6 GB
of headroom on an idle box, and a desktop session is ~1.2 GB of that. Check
`gx10-top` before starting rather than after it refuses.

## Sources

- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks) — the recipe this is ported from
- [Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw](https://huggingface.co/Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw) · [brandonmusic/GLM-5.3-Flash-tr3-4bpw](https://huggingface.co/brandonmusic/GLM-5.3-Flash-tr3-4bpw) — the weights and their origin
- [incoai/GLM-5.3-Flash-DFlash2](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2) — the drafter
- [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) — the base model
- [turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3) — the EXL3 format and kernels
