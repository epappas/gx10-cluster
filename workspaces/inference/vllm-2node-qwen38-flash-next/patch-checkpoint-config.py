#!/usr/bin/env python3
"""Two checkpoint-metadata fixes, and a preflight that saves seven minutes.

THE ALIAS. vLLM builds the MTP draft layer at the ABSOLUTE index that continues
the main stack - ``mtp.layers.48`` for ``num_hidden_layers: 48`` - and matches
quantization metadata against ``quantized_layers`` by exact string. Some
publishers of these weights record only ``mtp.layers.0``, so the lookup misses,
the MTP MoE is built unquantized, and its FP8 ``weight_scale_inv`` tensors fail
to load about seven minutes in with::

    Layer mtp.layers.48.mlp.experts has no parameter 'w2_weight_scale_inv'

The alias goes into BOTH ``config.json`` and the legacy ``hf_quant_config.json``.
The HF cache is never modified: patched copies are written to an output
directory and bind-mounted over the snapshot's own files by ``up.sh``.

**MEASURED, AND IT IS NOT ENOUGH ON ITS OWN.** With the alias present and
correct in both files on disk, the dispatch still received ``quant_algo=None``
for ``mtp.layers.48.mlp.experts``: ``apply_vllm_mapper`` rewrites
``quantized_layers`` on the draft-model path, so the alias is gone by the time
``get_quant_method`` looks. The fix that actually works collapses
``mtp.layers.<N>`` to ``mtp.layers.0`` inside the dispatch itself - see
``patches/fp8_block_moe.py``. This file is kept because it is cheap, it is
correct for every code path that reads the config directly, and it costs
nothing; but do not expect it alone to make MTP load.

THE PREFLIGHT. ``ModelOptMixedPrecisionConfig.get_quant_method`` builds
``RoutedExperts`` for FP8 / NVFP4 / W4A16_NVFP4 / MXFP8 and returns ``None`` for
anything else - which yields a silently UNQUANTIZED MoE that dies late in the
load rather than at startup. Upstream vLLM has no ``FP8_BLOCK_SCALES`` branch
either, so this does not age out by upgrading. Checking it costs milliseconds.

    ./patch-checkpoint-config.py <snapshot> <outdir>      # prints files rewritten
    ./patch-checkpoint-config.py --check-mtp-moe-algo <snapshot>

Mechanism re-implemented from the description in
MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks (AGPL-3.0-or-later); no code from
that repository is used here. See docs/decisions.md#qwen38-flash-next.

UNVERIFIED against a real checkpoint. It is fail-closed in the direction that
matters: it refuses to write when it cannot find what it expects, rather than
emitting a config that claims an alias it did not actually add.
"""

from __future__ import annotations

import json
import pathlib
import sys

# What the mixed-precision dispatch can build for RoutedExperts.
#
# The first four are upstream's own coverage. The last two are added by
# patches/fp8_block_moe.py, which up.sh applies on both ranks before the server
# starts - so they belong here ONLY as long as that patch stays mandatory. If it
# is ever made optional, move them back out: the point of this preflight is to
# refuse in milliseconds what would otherwise die seven minutes into a load.
#
# MEASURED: nvidia/Qwen3.8-Flash-Next-NVFP4 records FP8_PB_WO, not the
# FP8_BLOCK_SCALES its upstream write-up names. Both are accepted.
SUPPORTED_MOE_ALGOS = {"FP8", "NVFP4", "W4A16_NVFP4", "MXFP8",
                       "FP8_PB_WO", "FP8_BLOCK_SCALES"}

CONFIGS = ("config.json", "hf_quant_config.json")


def load(path: pathlib.Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return None


def quantized_layers(doc: dict) -> dict | None:
    """The per-tensor map, wherever this file keeps it.

    Three spellings, all three seen on real checkpoints:

        config.json            quantization_config.quantized_layers
        hf_quant_config.json   quantization.quantized_layers
        (either)               quantized_layers at the top level

    MEASURED on nvidia/Qwen3.8-Flash-Next-NVFP4: the legacy file uses the
    `quantization` spelling, and a reader that knows only the other two patches
    config.json alone - which is precisely the "stale mapping left in play"
    case the alias exists to prevent, since vLLM reads the legacy file on the
    draft-model path. Returning the live dict rather than a copy is deliberate:
    callers mutate it.
    """
    for holder in (doc.get("quantization_config"), doc.get("quantization"), doc):
        if isinstance(holder, dict) and isinstance(holder.get("quantized_layers"), dict):
            return holder["quantized_layers"]
    return None


def mtp_depth(snapshot: pathlib.Path) -> int | None:
    """The absolute index vLLM will look for: num_hidden_layers.

    Read rather than hardcoded to 48 - a variant with a different depth would
    otherwise get an alias pointing at a layer that does not exist, which is a
    worse failure than the one being fixed because it looks like it worked.
    """
    cfg = load(snapshot / "config.json") or {}
    for holder in (cfg.get("text_config") or {}, cfg):
        n = holder.get("num_hidden_layers")
        if isinstance(n, int) and n > 0:
            return n
    return None


def add_alias(layers: dict, depth: int) -> int:
    """Alias mtp.layers.0.* to mtp.layers.<depth>.*, returning how many added."""
    added = 0
    for key, value in list(layers.items()):
        if not key.startswith("mtp.layers.0"):
            continue
        target = key.replace("mtp.layers.0", f"mtp.layers.{depth}", 1)
        if target not in layers:
            layers[target] = value
            added += 1
    return added


def mtp_moe_algo(snapshot: pathlib.Path) -> str | None:
    """The quantization algo recorded for the MTP routed experts."""
    for name in CONFIGS:
        doc = load(snapshot / name)
        if doc is None:
            continue
        layers = quantized_layers(doc)
        if not layers:
            continue
        for key, value in layers.items():
            if "mtp.layers." in key and ".mlp.experts" in key:
                if isinstance(value, dict):
                    algo = value.get("algorithm") or value.get("quant_algo")
                    if algo:
                        return str(algo).upper()
                elif isinstance(value, str):
                    return value.upper()
    return None


def main() -> int:
    args = sys.argv[1:]

    if args[:1] == ["--check-mtp-moe-algo"]:
        if len(args) < 2:
            print(__doc__, file=sys.stderr)
            return 2
        algo = mtp_moe_algo(pathlib.Path(args[1]))
        if algo is None:
            # Not recorded is not the same as unsupported. Say so and pass:
            # refusing to launch on an absent key would block every checkpoint
            # that does not use this metadata style at all.
            print("MTP experts: no quantization recorded (nothing to check)", file=sys.stderr)
            return 0
        if algo in SUPPORTED_MOE_ALGOS:
            print(f"MTP experts: {algo} (supported)", file=sys.stderr)
            return 0
        print(f"MTP experts: {algo} - not in {sorted(SUPPORTED_MOE_ALGOS)}", file=sys.stderr)
        return 3

    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    snapshot, outdir = pathlib.Path(args[0]), pathlib.Path(args[1])
    depth = mtp_depth(snapshot)
    if depth is None:
        print(f"cannot read num_hidden_layers from {snapshot}/config.json", file=sys.stderr)
        return 1
    outdir.mkdir(parents=True, exist_ok=True)

    written: list[str] = []
    for name in CONFIGS:
        doc = load(snapshot / name)
        if doc is None:
            continue
        layers = quantized_layers(doc)
        if layers is None:
            continue
        if any(k.startswith(f"mtp.layers.{depth}") for k in layers):
            continue  # already absolute; nothing to do
        if not add_alias(layers, depth):
            continue
        dest = outdir / name
        dest.write_text(json.dumps(doc, indent=2) + "\n")
        written.append(name)

    # Stdout is the machine-readable half - up.sh mounts exactly what is named
    # here - so the human note goes to stderr.
    if written:
        print(f"MTP layer alias -> mtp.layers.{depth} in {', '.join(written)}", file=sys.stderr)
    else:
        print("checkpoint already declares absolute MTP layer indices", file=sys.stderr)
    print(" ".join(written))
    return 0


if __name__ == "__main__":
    sys.exit(main())
