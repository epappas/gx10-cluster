#!/usr/bin/env python3
"""Build the MTP routed experts when they are block-scaled FP8.

THE FAILURE THIS PREVENTS. ``ModelOptMixedPrecisionConfig.get_quant_method``
dispatches ``RoutedExperts`` for exactly four algos::

    FP8 / NVFP4 / W4A16_NVFP4 / MXFP8   ->  a FusedMoE method
    anything else                       ->  return None

``nvidia/Qwen3.8-Flash-Next-NVFP4`` records its MTP experts as::

    "mtp.layers.0.mlp.experts": {"quant_algo": "FP8_PB_WO", "group_size": 128}

which is none of the four. `None` does not fail - it yields a silently
UNQUANTIZED MoE, and the load then dies roughly seven minutes in with
``Layer mtp.layers.48.mlp.experts has no parameter 'w2_weight_scale_inv'``.

(Upstream's write-up calls this algo "128x128 block-scaled FP8"; the string
actually on disk is FP8_PB_WO - per-block weight-only. Same thing, different
name, and the name is what the dispatch matches on.)

THE FIX. Add the missing branch, routing to vLLM's own ``Fp8MoEMethod`` with
``weight_block_size`` taken from the checkpoint's own ``group_size``.

IT REFUSES TO GUESS THE BLOCK SHAPE. A wrong block size does not raise - it
applies misaligned scales and produces quietly wrong numerics, which is worse
than the crash it replaces. If ``group_size`` is missing, this raises.

This gap is in UPSTREAM vLLM too, not only this image, so it does not age out
by upgrading. Without this patch, serve with MTP_NUM_SPECULATIVE_TOKENS=0 -
up.sh's preflight refuses in milliseconds rather than letting the load die.

Fail-closed, idempotent, preflights its anchor. Runs inside the container from
up.sh's PRE_EXEC, on both ranks.

Mechanism described in MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks
(AGPL-3.0-or-later); independent implementation against the image's source.
See docs/decisions.md#qwen38-flash-next.
"""

from __future__ import annotations

import pathlib
import sys

TARGET = pathlib.Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/"
    "layers/quantization/modelopt.py"
)

MARKER = "# --- gx10: FP8 block-scaled routed experts ---"

# The final fallthrough of the RoutedExperts dispatch. Anchoring on the MXFP8
# branch plus its `return None` keeps the insertion after every branch that
# already works, so this can only ever catch what would otherwise be dropped.
ANCHOR = """            if quant_algo == "MXFP8":
                return ModelOptMxFp8FusedMoE(
                    quant_config=self.mxfp8_config,
                    moe_config=layer.moe_config,
                )
            return None
"""

REPLACEMENT = '''            if quant_algo == "MXFP8":
                return ModelOptMxFp8FusedMoE(
                    quant_config=self.mxfp8_config,
                    moe_config=layer.moe_config,
                )
{marker}
            # Block-scaled FP8 weight-only. The four branches above are the
            # whole of upstream's coverage, and this checkpoint's MTP experts
            # are none of them - so without this the method is None, the MoE is
            # built unquantized, and the load dies minutes later looking for
            # w2_weight_scale_inv.
            # THE MTP INDEX, resolved HERE rather than by rewriting config.json.
            #
            # vLLM builds the draft layer at the ABSOLUTE index that continues
            # the main stack (mtp.layers.48 for 48 hidden layers) while the
            # checkpoint records only mtp.layers.0. Aliasing the config file
            # does NOT fix it: apply_vllm_mapper rewrites quantized_layers on
            # the draft-model path, so the alias is gone by the time the
            # dispatch looks - MEASURED, quant_algo arrived as None with the
            # alias present in both config files on disk.
            #
            # Collapsing any mtp.layers.<N> to mtp.layers.0 for the lookup is
            # the same fact expressed where it survives. It is scoped to MTP
            # prefixes so nothing else can be caught by it.
            if quant_algo is None and re.match(r"^(.*[.])?mtp[.]layers[.][0-9]+[.]", prefix):
                _gx10_alias = re.sub(r"mtp[.]layers[.][0-9]+[.]", "mtp.layers.0.", prefix, count=1)
                quant_algo = self._resolve_quant_algo(_gx10_alias)
                if quant_algo is not None:
                    logger.info(
                        "gx10: resolved %s via %s -> %s",
                        prefix, _gx10_alias, quant_algo,
                    )
                    prefix = _gx10_alias

            if quant_algo in ("FP8_PB_WO", "FP8_BLOCK_SCALES"):
                from vllm.model_executor.layers.quantization.fp8 import (
                    Fp8Config as _Gx10Fp8Config,
                    Fp8MoEMethod as _Gx10Fp8MoEMethod,
                )

                _gx10_gs = None
                for _cand in self._quantized_layer_prefix_candidates(prefix):
                    _entry = self.quantized_layers.get(_cand)
                    if isinstance(_entry, dict) and _entry.get("group_size"):
                        _gx10_gs = int(_entry["group_size"])
                        break
                if _gx10_gs is None:
                    for _k, _v in self.quantized_layers.items():
                        if _k.startswith(prefix + ".") and isinstance(_v, dict) \\
                                and _v.get("group_size"):
                            _gx10_gs = int(_v["group_size"])
                            break
                # REFUSE TO GUESS. A wrong block shape applies misaligned
                # scales silently rather than failing, which is strictly worse
                # than the crash this patch exists to remove.
                if _gx10_gs is None:
                    raise ValueError(
                        f"{{quant_algo}} experts at {{prefix}} declare no group_size; "
                        "refusing to guess the FP8 block shape."
                    )
                logger.info(
                    "Building %s routed experts at %s via Fp8MoEMethod with "
                    "weight_block_size=[%d, %d]",
                    quant_algo, prefix, _gx10_gs, _gx10_gs,
                )
                return _Gx10Fp8MoEMethod(
                    _Gx10Fp8Config(
                        is_checkpoint_fp8_serialized=True,
                        weight_block_size=[_gx10_gs, _gx10_gs],
                    ),
                    layer,
                )
            logger.warning(
                "gx10: RoutedExperts at %s fell through with quant_algo=%r "
                "-> UNQUANTIZED MoE", prefix, quant_algo,
            )
            return None
'''.format(marker=MARKER)


def main() -> int:
    if not TARGET.is_file():
        print(f"fp8_block_moe: no such file: {TARGET}", file=sys.stderr)
        return 1

    src = TARGET.read_text()
    if MARKER in src:
        print("fp8_block_moe: already applied")
        return 0

    if src.count(ANCHOR) != 1:
        print(f"fp8_block_moe: anchor matched {src.count(ANCHOR)} times, wanted 1.",
              file=sys.stderr)
        print("  The RoutedExperts dispatch has drifted. Re-read "
              "ModelOptMixedPrecisionConfig.get_quant_method and re-pin.",
              file=sys.stderr)
        return 1

    if "\nimport re\n" not in src:
        src = src.replace("\nimport torch\n", "\nimport re\n\nimport torch\n", 1)
        if "\nimport re\n" not in src:
            print("fp8_block_moe: could not add `import re` - refusing", file=sys.stderr)
            return 1

    for needed, why in (
        ("def _quantized_layer_prefix_candidates", "prefix candidate helper"),
        ("logger = init_logger", "module logger"),
    ):
        if needed not in src:
            print(f"fp8_block_moe: {why} not found - refusing", file=sys.stderr)
            return 1

    TARGET.write_text(src.replace(ANCHOR, REPLACEMENT, 1))
    print("fp8_block_moe: applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
