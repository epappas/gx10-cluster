# The patches

Five gaps sit between this image and these checkpoints. Three are checkpoint
bookkeeping and are already written, in the scripts one level up. **Two are not
written**, because they rewrite Python that ships *inside* the image, and a
patch written against source nobody has read is a guess.

`up.sh` refuses to launch until both exist. That refusal is the feature: without
them the model does not load, and both failures arrive *late* — one after the
weights are already resident — so a silent skip costs an afternoon.

```bash
./extract-sources.sh     # ~20.6 GB pull, then patches/src/*.py
```

## What each one must do

### `ple_fp8_resolver.py` — mandatory, fatal without

**Target:** `models/qwen3_8_flash_next/nvidia/ple_layer.py`

The NVFP4 checkpoints store the 51 B-parameter N-gram/PLE embedding table as
FP8 shards plus one global `weight_scale`, but declare `*.ple.*` **excluded** in
the ModelOpt NVFP4 quant config. vLLM's PLE resolver enables its FP8 path only
when the *whole* checkpoint is FP8-serialised, so it takes neither branch,
builds a BF16 embedding of roughly **102 GB**, and dies.

Install a shim in the quant-method lookup for the PLE embedding: when
`PLE_QUANT_OVERRIDE=fp8` is set in the environment, short-circuit to the image's
own `Qwen3_8FlashNextPLEFp8EmbeddingMethod` — which already handles exactly this
"FP8 shards + one global weight_scale" layout — bypassing both the
FP8-checkpoint test and the `ignored_layers` test.

Nothing is being invented; the correct method is already in the image and the
patch only changes which branch reaches it.

### `mxfp8_kernel_fallback.py` — mandatory, fatal without

**Target:** `model_executor/layers/quantization/modelopt.py`

`FlashInferCutlassMxfp8LinearKernel`'s `mm_mxfp8` accepts only **N ≥ 128,
N % 32 == 0, K ≥ 128, K % 32 == 0**. Two shapes in these checkpoints miss it:

| Layer | `[N, K]` | Why it fails |
|---|---|---|
| `language_model.layers.*.linear_attn.in_proj_a` / `in_proj_b` (×72) | `[48, 2560]` | `N < 128` |
| `visual.blocks.*.mlp.linear_fc1` (×27) | `[4304, 1152]` | `4304 % 32 == 16` |

The first is fatal at engine start — it fires on the very first forward pass,
during `determine_available_memory()`, **about seven minutes in and after the
weights are resident**.

Rewrite `ModelOptMxFp8LinearMethod.create_weights` to check the **post-TP-split**
`(N, K)` it is about to hand the kernel and substitute `EmulationMxfp8LinearKernel`
when the native GEMM cannot take them. Emulation dequantises MXFP8 → BF16 once
at load time, so those layers run as plain BF16 linears (≈17 MB extra across all
72 `in_proj_a/b`). Each layer gets its own quant-method instance, so the
downgrade is **per layer** — everything else keeps the native kernel.

Additionally route **all** `visual.*` MXFP8 layers to emulation by prefix. That
is the verified multimodal configuration, and emulating only `visual.*` rather
than the whole model is what keeps the load-time BF16 dequant from OOMing.

Log one line per distinct shape. A silent fallback here is indistinguishable
from a fast path, and the two differ by a lot of bandwidth.

### `fp8_block_moe.py` — **written, mandatory**, and it is what MTP needs

**Target:** `model_executor/layers/quantization/modelopt.py` (a second concern
in the same file — write it as one patch or two, but do not let both rewrite
the file blindly)

`ModelOptMixedPrecisionConfig.get_quant_method` builds `RoutedExperts` only for
`FP8` / `NVFP4` / `W4A16_NVFP4` / `MXFP8`; anything else returns `None`, giving a
silently unquantized MoE. `nvidia/Qwen3.8-Flash-Next-NVFP4` records its MTP
routed experts as 128×128 block-scaled FP8, which is none of those.

Add the missing branch, routing to vLLM's own `Fp8MoEMethod` with
`weight_block_size` read from the checkpoint's `group_size`. **Do not guess the
block shape** — a wrong one applies misaligned scales silently rather than
failing.

**MEASURED on `nvidia/Qwen3.8-Flash-Next-NVFP4`.** Two findings the upstream
write-up does not have:

1. **The algo string is `FP8_PB_WO`, not `FP8_BLOCK_SCALES`.** That is what the
   checkpoint records and what `_resolve_quant_algo` normalises it to. The patch
   accepts both.
2. **The config-file alias does not reach this dispatch.** With
   `mtp.layers.48.mlp.experts` aliased correctly in *both* config files,
   `get_quant_method` still received `quant_algo=None` — `apply_vllm_mapper`
   rewrites `quantized_layers` on the draft-model path. So the patch collapses
   `mtp.layers.<N>` → `mtp.layers.0` for the lookup itself, which is the same
   fact expressed where it survives.

With it: MTP=3 loads, acceptance decays **0.82 / 0.63 / 0.46** by draft
position, and batch-1 prose decode goes 26.1 → 32.9 tok/s. Without it the load
dies with `Layer mtp.layers.48.mlp.experts has no parameter 'w2_weight_scale_inv'`.

> This gap is in **upstream vLLM** as well, not just this image, so it does not
> age out by upgrading.

### Not ported: FP8 KV cache for the QSA kernels

The stock QSA kernels declare `supported_kv_cache_dtypes = ["auto", "bfloat16"]`
and raise `Qwen3.8-Flash-Next QSA requires a BF16 main KV cache` on anything
else. Teaching them to read an FP8 e4m3 cache is worth **1.70× tokens per GiB**
(3,652,200 vs 2,131,159 on the reference kit).

It is **deliberately absent**. The upstream implementation is AGPL-3.0-or-later
and this repository is MIT ([why that matters](../../../../docs/decisions.md#qwen38-flash-next)),
and unlike the two mandatory patches above it is a capacity optimisation rather
than a load-time requirement.

**So `KV_CACHE_DTYPE=fp8` will not work until someone writes it.** `up.sh`
ships that default because it is the reference configuration; set
`KV_CACHE_DTYPE=auto` in `.env` for bf16 until the patch exists.

## House rules for writing them

Both mandatory patches follow the shape `patch_kpool_tail_slotmap.py` in
`../../vllm-2node-glm53-flash-exl3/` already sets:

- **Fail closed.** Refuse to write if the pinned anchor has drifted. An exit
  code is a good outcome; a wrong edit is not.
- **Idempotent.** `up.sh` runs them on every launch, on both ranks.
- **Preflight the anchor before writing**, and name what it expected when it
  does not match. "Patch did not apply" with no detail is one bisect too many.
- **Re-implemented, not copied.** The mechanisms above are described precisely
  enough to write from. Do not paste AGPL source into this MIT repository.
