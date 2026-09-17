#!/usr/bin/env python3
"""Cap the sparse-indexer prefill workspace instead of sizing it on context.

vLLM sizes that workspace `max_model_len * 40` ENTRIES at 132 B, allocates it
during the memory profile - so it comes out of the KV pool - and never shrinks
it: ~0.65 GiB at 128k, ~3.93 GiB at 800k, ~4.92 GiB at 1M.

On this workspace, which has the smallest KV budget in the repo, that is most
of the budget. It is also why `MAX_MODEL_LEN=800000` was refused here:
workspace.yml records a 2.19 GiB shortfall, and 800k silently locks 3.93 GiB
in a buffer for a request shape this server cannot admit. The cap was not
competing with the model.

The workspace is sized in TOKENS and consumed in POOLS. Its only consumer
slices it to the summed COMPRESSED sequence lengths of one prefill chunk, and
GLM-5.3-Flash's indexer compress ratio is the kpool width, 4. So the most a
legal step can ask for is

    min(max_num_seqs, max_num_batched_tokens) * ceil(max_model_len / 4)

and never `max_model_len * 40`, which is no schedulable step at all.

`up.sh` computes that from the three numbers it already passes to vLLM and
hands it over in GX10_INDEXER_MAX_ENTRIES; this only ever wraps the stock
return in `min(...)`. So a wrong environment yields a workspace no smaller
than a correct one, and the patch's surface is one return statement.

UNVERIFIED ON THIS HARDWARE. The mechanism and the sizing are documented in
MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks `docs/DESIGN-indexer-workspace.md`
against a live container; that repo is AGPL-3.0-or-later and this is an
independent implementation of the documented mechanism. What has not happened
is a boot here with it on. Off by default.
See docs/decisions.md#glm53-indexer-workspace.

    GX10_INDEXER_MAX_ENTRIES=800000 python3 patch_indexer_workspace.py
"""
from __future__ import annotations

import ast
import os
import stat
import sys
from pathlib import Path

TARGET = Path(os.environ.get(
    "GX10_INDEXER_PY",
    "/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/backends/mla/indexer.py",
))
FUNC = "get_max_prefill_buffer_size"
MARK = "# [gx10-indexer-workspace]"

# The indexer's compress ratio for this model, which is the kpool width. A
# constant rather than a parameter: this file lives in a GLM-5.3-Flash
# workspace, and for another model the whole derivation needs re-reading, not
# a different argument.
INDEX_KPOOL = 4


def rightsize_entries(max_model_len: int, max_num_seqs: int,
                      max_num_batched_tokens: int) -> int:
    """The largest gather a single legal prefill step can ask for.

    Pure, because it is the whole claim this patch makes - and the one that
    would be embarrassing to get wrong downwards: too small overruns a buffer
    the indexer gathers INTO, which is a correctness bug that reads like a
    performance one.
    """
    if min(max_model_len, max_num_seqs, max_num_batched_tokens) < 1:
        raise ValueError("max_model_len, max_num_seqs and max_num_batched_tokens "
                         "must all be >= 1")
    rows = min(max_num_seqs, max_num_batched_tokens)
    return rows * -(-max_model_len // INDEX_KPOOL)  # ceil division


def locate_return(source: str) -> tuple[int, int]:
    """Byte offsets of the single `return` expression in FUNC.

    AST rather than a pinned source literal, unlike patch_kpool_tail_slotmap.py
    next door. That one rewrites the body of a Triton kernel, where the
    surrounding lines are the evidence you are editing the right thing. Here
    the target is one short return in one named function, and formatting drift
    between image builds is the likely reason a literal anchor would stop
    matching - failing closed into "not applied" on a perfectly good image.
    """
    fns = [n for n in ast.walk(ast.parse(source))
           if isinstance(n, ast.FunctionDef) and n.name == FUNC]
    if len(fns) != 1:
        raise ValueError(f"expected exactly one def {FUNC}(), found {len(fns)}")
    rets = [n for n in ast.walk(fns[0]) if isinstance(n, ast.Return) and n.value]
    if len(rets) != 1:
        raise ValueError(
            f"{FUNC}() has {len(rets)} value-returning `return`s, expected 1 - "
            "it has changed shape and this patch must be re-derived")
    node = rets[0].value
    offsets, pos = [0], 0
    for line in source.splitlines(keepends=True):
        pos += len(line)
        offsets.append(pos)
    return (offsets[node.lineno - 1] + node.col_offset,
            offsets[node.end_lineno - 1] + node.end_col_offset)


def prepare(source: str, entries: int) -> tuple[str, str]:
    if entries < 1:
        raise ValueError(f"entry cap must be >= 1, got {entries}")
    if MARK in source:
        return source, "already present"
    begin, end = locate_return(source)
    patched = (source[:begin]
               + f"min(  {MARK} never raises the stock value\n"
                 f"        ({source[begin:end]}),\n"
                 f"        {entries},\n"
                 f"    )"
               + source[end:])
    compile(patched, "<patched>", "exec")
    return patched, f"capped at {entries:,} entries (~{entries * 132 / 2**30:.2f} GiB)"


def main() -> int:
    raw = os.environ.get("GX10_INDEXER_MAX_ENTRIES", "").strip()
    if not raw:
        print("GX10_INDEXER_MAX_ENTRIES unset - leaving the stock workspace alone")
        return 0
    if not raw.isdigit():
        raise SystemExit(f"GX10_INDEXER_MAX_ENTRIES must be a positive integer, got {raw!r}")
    if not TARGET.is_file():
        raise SystemExit(f"missing {TARGET}")
    source = TARGET.read_text()
    try:
        patched, action = prepare(source, int(raw))
    except ValueError as exc:
        raise SystemExit(f"indexer workspace preflight failed: {exc}") from exc
    if patched != source:
        tmp = TARGET.with_name(f".{TARGET.name}.gx10-indexer.tmp")
        tmp.write_text(patched)
        os.chmod(tmp, stat.S_IMODE(TARGET.stat().st_mode))
        os.replace(tmp, TARGET)
        for pyc in (TARGET.parent / "__pycache__").glob(f"{TARGET.stem}*.pyc"):
            pyc.unlink(missing_ok=True)
    print(f"{TARGET.name}: indexer prefill workspace {action}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
