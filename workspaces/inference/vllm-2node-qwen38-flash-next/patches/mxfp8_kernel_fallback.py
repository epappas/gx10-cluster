#!/usr/bin/env python3
"""Route MXFP8 shapes FlashInfer's mm_mxfp8 cannot run to BF16 emulation.

THE FAILURE THIS PREVENTS. On GB10 the MXFP8 linear layers select
``FlashInferCutlassMxfp8LinearKernel``, whose ``can_implement()`` returns
``(True, None)`` UNCONDITIONALLY - it does not look at the shape at all. The
real constraints live in ``apply_weights`` as bare asserts, plus a deeper
"Problem size is not supported for mm_mxfp8" inside FlashInfer itself:

    N >= 128,  N % 32 == 0,  K >= 128,  K % 32 == 0

Two shapes in these checkpoints miss that:

    language_model.layers.*.linear_attn.in_proj_a / in_proj_b   [48, 2560]
        -> N < 128       AssertionError: mm_mxfp8 requires N >= 128, got N=48
    visual.blocks.*.mlp.linear_fc1                              [4304, 1152]
        -> 4304 % 32 == 16   ValueError: Problem size is not supported

Because the check is at APPLY time rather than at SELECTION time, the first one
is fatal on the very first forward pass - during
``determine_available_memory()``, roughly seven minutes into the launch and
after the weights are already resident. That timing is the whole reason this
patch is mandatory rather than an optimisation.

THE FIX. Check the POST-TP-SPLIT (N, K) in ``create_weights`` - the numbers the
kernel will actually be handed, not the unsharded ones - and swap this layer's
kernel for ``EmulationMxfp8LinearKernel``. Emulation dequantises MXFP8 -> BF16
once at load time, so those layers then run as plain BF16 linears (~17 MB extra
across all 72 in_proj_a/b). Each layer gets its OWN quant-method instance, so
the downgrade is strictly per-layer: everything else keeps the native kernel.

One line is logged per distinct shape. A silent fallback is indistinguishable
from a fast path, and the two differ by a lot of bandwidth.

Fail-closed, idempotent, preflights its anchor before writing. Runs inside the
container from up.sh's PRE_EXEC, on both ranks.

Mechanism described in MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks
(AGPL-3.0-or-later); this is an independent implementation written against the
image's own source. See docs/decisions.md#qwen38-flash-next.
"""

from __future__ import annotations

import pathlib
import sys

TARGET = pathlib.Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/"
    "layers/quantization/modelopt.py"
)

MARKER = "# --- gx10: MXFP8 kernel shape fallback ---"

# Anchored on the three assignments that establish the post-TP-split shape.
# They are NOT unique in this file - six of the seven create_weights methods
# here share the idiom, and an early version of this patch matched all six and
# refused (correctly). So the search is SCOPED to the enclosing class first,
# and only then required to be unique. Uniqueness inside one class is the
# property that actually makes the edit safe.
ANCHOR = """        layer.logical_widths = output_partition_sizes
        layer.input_size_per_partition = input_size_per_partition
        layer.output_size_per_partition = output_size_per_partition
"""

INJECT = f'''
{MARKER}
        # FlashInfer's mm_mxfp8 takes N,K >= 128 and both divisible by 32, but
        # FlashInferCutlassMxfp8LinearKernel.can_implement() returns True
        # unconditionally - the constraint is only enforced by asserts inside
        # apply_weights, i.e. on the FIRST FORWARD, during the memory profile,
        # after the weights are resident. Check it here, where a fallback is
        # still free.
        _gx10_n = output_size_per_partition
        _gx10_k = input_size_per_partition
        _gx10_bad = (
            _gx10_n < 128 or _gx10_n % 32 != 0 or _gx10_k < 128 or _gx10_k % 32 != 0
        )
        if _gx10_bad and type(self.kernel).__name__ != "EmulationMxfp8LinearKernel":
            from vllm.model_executor.kernels.linear.mxfp8.emulation import (
                EmulationMxfp8LinearKernel as _Gx10Emulation,
            )

            _gx10_seen = globals().setdefault("_GX10_MXFP8_FALLBACK_SHAPES", set())
            if (_gx10_n, _gx10_k) not in _gx10_seen:
                _gx10_seen.add((_gx10_n, _gx10_k))
                logger.warning(
                    "MXFP8 layer [N=%d, K=%d] is not supported by %s "
                    "(needs N,K >= 128 and divisible by 32); falling back to "
                    "BF16 emulation for this shape.",
                    _gx10_n,
                    _gx10_k,
                    type(self.kernel).__name__,
                )
            # Per-layer: this method instance serves exactly one layer, so the
            # downgrade cannot leak to any other.
            self.kernel = _Gx10Emulation()
'''


def main() -> int:
    if not TARGET.is_file():
        print(f"mxfp8_kernel_fallback: no such file: {TARGET}", file=sys.stderr)
        return 1

    src = TARGET.read_text()

    if MARKER in src:
        print("mxfp8_kernel_fallback: already applied")
        return 0

    # SCOPE TO THE CLASS FIRST. The anchor idiom appears in six of the seven
    # create_weights methods in this file, so a file-wide replace would patch
    # whichever came first - which is not this one.
    cls_at = src.find("class ModelOptMxFp8LinearMethod")
    if cls_at < 0:
        print("mxfp8_kernel_fallback: ModelOptMxFp8LinearMethod is gone",
              file=sys.stderr)
        return 1
    next_cls = src.find("\nclass ", cls_at + 1)
    cls_end = next_cls if next_cls > 0 else len(src)
    body = src[cls_at:cls_end]

    if body.count(ANCHOR) != 1:
        print(f"mxfp8_kernel_fallback: anchor matched {body.count(ANCHOR)} times "
              f"inside ModelOptMxFp8LinearMethod, wanted 1.", file=sys.stderr)
        print("  create_weights has drifted. Re-read it in the image and re-pin.",
              file=sys.stderr)
        return 1

    # The fallback kernel has to exist, and `logger` has to be in scope for the
    # warning. Both are assumptions worth failing on rather than discovering at
    # load time.
    if "EmulationMxfp8LinearKernel" not in pathlib.Path(
        "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/kernels/"
        "linear/mxfp8/emulation.py"
    ).read_text():
        print("mxfp8_kernel_fallback: EmulationMxfp8LinearKernel not found",
              file=sys.stderr)
        return 1
    if "logger = init_logger" not in src:
        print("mxfp8_kernel_fallback: module logger not found", file=sys.stderr)
        return 1

    patched_body = body.replace(ANCHOR, ANCHOR + INJECT, 1)
    TARGET.write_text(src[:cls_at] + patched_body + src[cls_end:])
    print("mxfp8_kernel_fallback: applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
