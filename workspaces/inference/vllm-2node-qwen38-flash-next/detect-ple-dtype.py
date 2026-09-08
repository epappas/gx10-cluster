#!/usr/bin/env python3
"""Recover the PLE embedding dtype this checkpoint failed to declare properly.

The patched ``ple_layer.py`` resolver dispatches on
``text_config.ple_embedding_dtype``. Not every publisher of these weights
records it there: ``nvidia/Qwen3.8-Flash-Next-NVFP4`` declares its FP8 PLE
table only inside ``quantization_config.config_groups``, so the resolver reads
nothing, leaves the stock quant-method lookup in place, and vLLM builds a BF16
embedding of roughly 102 GB for a table that is FP8 on disk.

This reads the value back out of wherever it was recorded so ``up.sh`` can
re-inject it through ``--hf-overrides``. Two modes::

    ./detect-ple-dtype.py --snapshot-dir <org/repo>   # resolve the cache path
    ./detect-ple-dtype.py <snapshot dir>              # print the dtype, or nothing

Printing NOTHING is a correct and common answer: a checkpoint that declares
``ple_embedding_dtype`` itself needs no override, and an override that merely
restates what the config already says is one more thing to keep in step.

Mechanism re-implemented from the description in
MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks (AGPL-3.0-or-later); no code from
that repository is used here. See docs/decisions.md#qwen38-flash-next.

UNVERIFIED against a real checkpoint - neither the weights nor the image were
present when this was written. It fails closed: an unrecognised layout prints
nothing and exits 0, which leaves the checkpoint's own declaration in force
rather than asserting a dtype that might be wrong.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys

# What the resolver knows how to dispatch on. Anything else is not something to
# guess at - a wrong dtype here applies the wrong quant method to a 51 GB table.
KNOWN_DTYPES = {"fp8", "fp8_e4m3", "nvfp4", "bf16", "bfloat16"}


def hf_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("HF_HOME") or pathlib.Path.home() / ".cache/huggingface")


def resolve_snapshot(repo: str) -> pathlib.Path | None:
    """The snapshot with the most files in it - the one that finished.

    A container that died mid-load leaves a stub snapshot beside the real one,
    and taking the first directory gets the stub. This is the same rule the
    GLM-5.3 workspace arrived at the hard way.
    """
    if repo.startswith("/"):
        return pathlib.Path(repo)
    snaps = hf_home() / "hub" / f"models--{repo.replace('/', '--')}" / "snapshots"
    if not snaps.is_dir():
        return None
    rev = os.environ.get("MODEL_REVISION")
    if rev and (snaps / rev).is_dir():
        return snaps / rev
    best = sorted(
        (d for d in snaps.iterdir() if d.is_dir()),
        key=lambda d: len(list(d.iterdir())),
        reverse=True,
    )
    return best[0] if best else None


def read_config(snapshot: pathlib.Path) -> dict:
    cfg = snapshot / "config.json"
    if not cfg.is_file():
        return {}
    try:
        return json.loads(cfg.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def ple_dtype(cfg: dict) -> str | None:
    """Where the dtype is, in the two layouts that exist."""
    # 1. Declared properly. Nothing to re-inject.
    text = cfg.get("text_config") or {}
    if text.get("ple_embedding_dtype"):
        return None

    # 2. Recorded only as a quantization group that targets the PLE tensors.
    #    config_groups is a dict of {group_name: {targets: [...], weights: {...}}};
    #    the group wanted is the one whose targets mention `ple`.
    quant = cfg.get("quantization_config") or {}
    for group in (quant.get("config_groups") or {}).values():
        if not isinstance(group, dict):
            continue
        targets = group.get("targets") or []
        if not any("ple" in str(t).lower() for t in targets):
            continue
        weights = group.get("weights") or {}
        # ModelOpt spells it either as a num_bits/type pair or as a plain name.
        name = str(weights.get("dtype") or weights.get("type") or "").lower()
        if name in KNOWN_DTYPES:
            return "fp8" if name.startswith("fp8") else name
        if weights.get("num_bits") == 8 and "float" in name:
            return "fp8"
    return None


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--snapshot-dir"]:
        snap = resolve_snapshot(args[1])
        if snap is None or not snap.is_dir():
            print(f"no snapshot found for {args[1]}", file=sys.stderr)
            return 1
        print(snap)
        return 0

    if not args:
        print(__doc__, file=sys.stderr)
        return 2

    snap = pathlib.Path(args[0])
    dtype = ple_dtype(read_config(snap))
    if dtype:
        print(dtype)
    return 0


if __name__ == "__main__":
    sys.exit(main())
