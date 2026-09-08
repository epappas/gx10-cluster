#!/usr/bin/env python3
"""The Flash-Next checkpoint helpers, exercised without a checkpoint.

Both helpers run on the host before a launch and decide two things that fail
LATE and quietly if they are wrong: which PLE dtype gets re-injected, and
whether the MTP draft layer's quantization metadata is reachable at the
absolute index vLLM looks it up by.

THE CASE THAT IS HERE BECAUSE IT WAS ALREADY WRONG ONCE. `quantized_layers`
has three spellings across the two config files, and the reader originally knew
only two - so on the real nvidia/Qwen3.8-Flash-Next-NVFP4 checkpoint it patched
config.json and silently skipped hf_quant_config.json, which is the legacy file
vLLM reads on the draft-model path. That is exactly the "stale mapping left in
play" failure the alias exists to prevent, and nothing about the output looked
different. Measured, fixed, pinned here.

    python3 tests/check_checkpoint_config.py
"""

from __future__ import annotations

# NO BYTECODE CACHE. SourceFileLoader writes __pycache__ NEXT TO THE TOOL, and
# a stale entry there makes this suite test the PREVIOUS version of the file -
# silently, and in the one direction that matters: a fix looks like it did not
# take, or worse, a broken file looks fine. Found the hard way when a corrected
# grader kept failing CI against its own old bytecode.
import sys

sys.dont_write_bytecode = True

import importlib.machinery
import importlib.util
import json
import pathlib
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
WS = REPO / "workspaces" / "inference" / "vllm-2node-qwen38-flash-next"


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_loader(
        name, importlib.machinery.SourceFileLoader(name, str(path)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ple = load("detect_ple", WS / "detect-ple-dtype.py")
cfg = load("patch_cfg", WS / "patch-checkpoint-config.py")


def check(label, got, want, problems):
    if got != want:
        problems.append(f"{label}: got {got!r}, want {want!r}")


def main() -> int:
    problems: list[str] = []

    # --- PLE dtype, in the shape the real checkpoint records it -------------
    # nvidia/... declares the FP8 PLE ONLY as a config_group targeting the
    # ngram embedding; text_config.ple_embedding_dtype is absent.
    real_shape = {
        "text_config": {"num_hidden_layers": 48},
        "quantization_config": {"config_groups": {
            "group_0": {"targets": ["model.language_model.layers.0.mlp.experts"],
                        "weights": {"num_bits": 4, "type": "float", "group_size": 16}},
            "group_2": {"targets": ["model.language_model.layers.1.ple.ple_embedding.ngram_embedding"],
                        "weights": {"num_bits": 8, "type": "float"}},
        }},
    }
    check("fp8 PLE recovered from config_groups",
          ple.ple_dtype(real_shape), "fp8", problems)
    # A checkpoint that declares it properly needs NO override - re-injecting
    # what the config already says is one more thing to keep in step.
    check("declared dtype needs no override",
          ple.ple_dtype({"text_config": {"ple_embedding_dtype": "fp8"}}), None, problems)
    check("no PLE group at all", ple.ple_dtype({"text_config": {}}), None, problems)

    # --- depth is READ, never assumed to be 48 -----------------------------
    with tempfile.TemporaryDirectory() as td:
        snap = pathlib.Path(td)
        (snap / "config.json").write_text(json.dumps(real_shape))
        check("depth from text_config", cfg.mtp_depth(snap), 48, problems)
        (snap / "config.json").write_text(json.dumps({"num_hidden_layers": 32}))
        check("depth from top level", cfg.mtp_depth(snap), 32, problems)

    # --- THE THREE SPELLINGS, and the one that was missed ------------------
    layers = {"mtp.layers.0.mlp.experts": {"quant_algo": "FP8_PB_WO", "group_size": 128}}
    for label, doc in (
        ("quantization_config nesting", {"quantization_config": {"quantized_layers": dict(layers)}}),
        ("quantization nesting (legacy file)", {"quantization": {"quantized_layers": dict(layers)}}),
        ("top-level", {"quantized_layers": dict(layers)}),
    ):
        found = cfg.quantized_layers(doc)
        if not isinstance(found, dict) or "mtp.layers.0.mlp.experts" not in found:
            problems.append(f"{label}: quantized_layers not found")

    # --- alias, on the real metadata shape ---------------------------------
    with tempfile.TemporaryDirectory() as td:
        snap, out = pathlib.Path(td) / "s", pathlib.Path(td) / "o"
        snap.mkdir()
        doc = dict(real_shape)
        doc["quantization_config"] = dict(doc["quantization_config"])
        doc["quantization_config"]["quantized_layers"] = dict(layers)
        (snap / "config.json").write_text(json.dumps(doc))
        # The legacy file, in ITS spelling.
        (snap / "hf_quant_config.json").write_text(
            json.dumps({"producer": "x", "quantization": {"quantized_layers": dict(layers)}}))

        written = []
        import contextlib, io
        with contextlib.redirect_stderr(io.StringIO()):
            sys.argv = ["x", str(snap), str(out)]
            with contextlib.redirect_stdout(io.StringIO()) as so:
                cfg.main()
            written = so.getvalue().split()

        if set(written) != {"config.json", "hf_quant_config.json"}:
            problems.append(f"alias: rewrote {written}, wanted BOTH config files")
        for name in written:
            d = json.loads((out / name).read_text())
            h = d.get("quantization_config") or d.get("quantization") or d
            if "mtp.layers.48.mlp.experts" not in h["quantized_layers"]:
                problems.append(f"alias: mtp.layers.48 missing from {name}")

    # --- the preflight's supported set tracks the patches ------------------
    # FP8_PB_WO is what nvidia/Qwen3.8-Flash-Next-NVFP4 actually records (NOT
    # the FP8_BLOCK_SCALES its upstream write-up names), and it is buildable
    # ONLY because patches/fp8_block_moe.py is mandatory in up.sh. Those two
    # facts have to move together: if that patch ever becomes optional, the
    # algo must leave this set, or the preflight green-lights a load that dies
    # seven minutes in.
    ws_up = (WS / "up.sh").read_text()
    patch_mandatory = ("fp8_block_moe.py" in ws_up
                       and "fp8_block_moe" in ws_up.split("PRE_EXEC=")[-1])
    for algo in ("FP8_PB_WO", "FP8_BLOCK_SCALES"):
        check(f"{algo} buildable iff fp8_block_moe is mandatory",
              algo in cfg.SUPPORTED_MOE_ALGOS, patch_mandatory, problems)
    check("NVFP4 is buildable",
          "NVFP4" in cfg.SUPPORTED_MOE_ALGOS, True, problems)
    # An algo nobody has written a branch for must still be refused, or the
    # preflight stops being a preflight.
    check("an unknown algo is refused",
          "SOME_FUTURE_ALGO" in cfg.SUPPORTED_MOE_ALGOS, False, problems)

    for p in problems:
        print(f"checkpoint-config: {p}", file=sys.stderr)
    if problems:
        return 1
    print("checkpoint-config: PLE recovery, depth reading, all three "
          "quantized_layers spellings, the alias and the MoE preflight hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
