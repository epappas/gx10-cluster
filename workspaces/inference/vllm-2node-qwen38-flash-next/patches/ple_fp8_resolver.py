#!/usr/bin/env python3
"""Let the FP8 PLE embedding table load out of an NVFP4 checkpoint.

THE FAILURE THIS PREVENTS. The NVFP4 checkpoints store the 51 B-parameter
N-gram/PLE embedding table as FP8 shards plus one global ``weight_scale``, but
the ModelOpt quant config that describes the checkpoint is NVFP4 and lists
``*.ple.*`` among its excluded layers. vLLM's resolver
(``_get_ple_embedding_quant_method``) therefore refuses the FP8 path on three
separate guards, all of which are true here and none of which is wrong on its
own::

    if not isinstance(quant_config, Fp8Config):        return None   # NVFP4 config
    if not quant_config.is_checkpoint_fp8_serialized:  return None   # not a whole-FP8 ckpt
    if is_layer_skipped(prefix, ignored_layers, ...):  return None   # *.ple.* excluded

With no quant method the table is built as a BF16 embedding - roughly 102 GB -
and the load dies.

THE FIX. When ``PLE_QUANT_OVERRIDE`` is set to ``fp8``, short-circuit to the
image's own ``Qwen3_8FlashNextPLEFp8EmbeddingMethod``, which already implements
exactly this "FP8 shards + one global weight_scale" layout. Nothing is
invented: the correct method is in the image and this only changes which branch
reaches it.

The dtype itself still has to be declared, because the layer dispatches on
``text_config.ple_embedding_dtype`` - and ``nvidia/Qwen3.8-Flash-Next-NVFP4``
records it only inside ``quantization_config.config_groups``. ``up.sh``
recovers it with ``detect-ple-dtype.py`` and re-injects it via
``--hf-overrides``. Both halves are needed; neither works alone.

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
    "/usr/local/lib/python3.12/dist-packages/vllm/models/"
    "qwen3_8_flash_next/nvidia/ple_layer.py"
)

MARKER = "# --- gx10: PLE_QUANT_OVERRIDE ---"

# The anchor is the resolver's docstring line, which is the last thing before
# the first guard. Pinning the docstring rather than the guards means an image
# that REORDERS or REWORDS the guards still gets the override inserted ahead of
# all of them - the property that actually matters - while an image that
# renames or removes the function fails loudly here instead of silently
# serving a 102 GB embedding.
ANCHOR = '    """Select global-scale FP8 only for quantized PLE checkpoint shards."""\n'

INJECT = f'''{MARKER}
    # An explicit operator override, ahead of every guard below. The three
    # guards are each correct in isolation and each false here: the config is
    # ModelOpt-NVFP4 rather than Fp8Config, the checkpoint is not wholly
    # FP8-serialised, and *.ple.* is in ignored_layers. The table on disk is
    # still FP8 shards + one global weight_scale, which is precisely what
    # Qwen3_8FlashNextPLEFp8EmbeddingMethod below implements.
    import os as _gx10_os

    if _gx10_os.environ.get("PLE_QUANT_OVERRIDE", "").lower().startswith("fp8"):
        return Qwen3_8FlashNextPLEFp8EmbeddingMethod()
'''


def main() -> int:
    if not TARGET.is_file():
        print(f"ple_fp8_resolver: no such file: {TARGET}", file=sys.stderr)
        return 1

    src = TARGET.read_text()

    if MARKER in src:
        print("ple_fp8_resolver: already applied")
        return 0

    if src.count(ANCHOR) != 1:
        print(f"ple_fp8_resolver: anchor matched {src.count(ANCHOR)} times, wanted 1.",
              file=sys.stderr)
        print("  The resolver's docstring has drifted. Re-read", file=sys.stderr)
        print("  _get_ple_embedding_quant_method in the image and re-pin.", file=sys.stderr)
        return 1

    # The method this hands back must exist, and it must be defined ABOVE the
    # resolver or the injected return is a NameError at call time rather than
    # at import. Both are cheap to verify and neither is safe to assume.
    if "class Qwen3_8FlashNextPLEFp8EmbeddingMethod" not in src:
        print("ple_fp8_resolver: Qwen3_8FlashNextPLEFp8EmbeddingMethod is gone "
              "- refusing to inject a call to it", file=sys.stderr)
        return 1
    if src.index("class Qwen3_8FlashNextPLEFp8EmbeddingMethod") > src.index(ANCHOR):
        print("ple_fp8_resolver: the FP8 method is defined AFTER the resolver "
              "- injection would NameError", file=sys.stderr)
        return 1

    TARGET.write_text(src.replace(ANCHOR, ANCHOR + INJECT, 1))
    print("ple_fp8_resolver: applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
