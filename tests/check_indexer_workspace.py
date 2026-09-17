#!/usr/bin/env python3
"""The indexer right-sizing bound, and the patch that applies it.

Two things here can be wrong without looking wrong, in opposite directions:

  rightsize_entries   sizes a buffer the sparse indexer gathers INTO. Too
                      large and the patch quietly gives back only a fraction
                      of the KV pool it exists to recover. TOO SMALL and a
                      legal prefill step overruns it - a correctness failure
                      wearing a performance costume.
  prepare             rewrites a return statement in a file CI cannot see. It
                      must cap, never raise, refuse a shape it does not
                      recognise, and be idempotent: a second run that wrapped
                      its own wrapper would halve the bound on every restart.

Same tier logic as the rest of the suite
(decisions.md#testing-is-tiered-because-the-hardware-cannot-be-faked): the
arithmetic and the rewrite run here, the boot runs on the box - and it has not
yet, which is why the workspace ships this off by default.

    python3 tests/check_indexer_workspace.py
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import importlib.machinery
import importlib.util
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOL = (REPO / "workspaces" / "inference" / "vllm-2node-glm53-flash-exl3"
        / "patch_indexer_workspace.py")

spec = importlib.util.spec_from_loader(
    "patch_indexer", importlib.machinery.SourceFileLoader("patch_indexer", str(TOOL))
)
pi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pi)

# The shape the mechanism is documented against.
STOCK = '''\
def get_max_prefill_buffer_size(vllm_config) -> int:
    max_model_len = vllm_config.model_config.max_model_len
    return max_model_len * 40
'''

BYTES_PER_ENTRY = 132
problems: list[str] = []


def check(name: str, got, want) -> None:
    if got != want:
        problems.append(f"{name}: expected {want!r}, got {got!r}")


def refuses(name: str, fn) -> None:
    try:
        fn()
    except ValueError:
        return
    problems.append(f"{name}: expected a refusal, got none")


def buffer_size(src: str, max_model_len: int) -> int:
    """Run the patched function the way the container will."""
    ns: dict = {}
    exec(compile(src, "<patched>", "exec"), ns)  # noqa: S102 - fixture
    cfg = type("C", (), {"model_config": type("M", (), {"max_model_len": max_model_len})})
    return ns["get_max_prefill_buffer_size"](cfg)


def main() -> int:
    # --- the bound ----------------------------------------------------------
    check("128k / 4 seqs", pi.rightsize_entries(131072, 4, 2048), 4 * 32768)
    check("800k / 4 seqs", pi.rightsize_entries(800000, 4, 2048), 800000)
    # A step cannot admit more sequences than it has tokens for.
    check("the chunk bounds the rows", pi.rightsize_entries(1000, 64, 8), 8 * 250)
    # Ceiling, not floor: a compressed length that rounds down leaves the last
    # sequence one row short of what it needs.
    check("ceil, not floor", pi.rightsize_entries(1001, 1, 1024), 251)
    check("exact multiple", pi.rightsize_entries(1000, 1, 1024), 250)

    refuses("zero context", lambda: pi.rightsize_entries(0, 4, 2048))
    refuses("zero seqs", lambda: pi.rightsize_entries(1000, 0, 2048))
    refuses("zero chunk", lambda: pi.rightsize_entries(1000, 4, 0))

    # THE CLAIM THIS CHANGE RESTS ON, asserted rather than described: at 800k
    # the stock buffer locks more than the 2.19 GiB by which that boot missed,
    # so the cap covers the shortfall rather than merely denting it.
    freed = (800000 * 40 - pi.rightsize_entries(800000, 4, 2048)) * BYTES_PER_ENTRY / 2**30
    if freed < 2.19:
        problems.append(
            f"right-sizing frees {freed:.2f} GiB at 800k, no longer covering the "
            "2.19 GiB shortfall workspace.yml records - re-read that note")

    # --- the rewrite --------------------------------------------------------
    patched, action = pi.prepare(STOCK, 800000)
    if "capped at" not in action:
        problems.append(f"prepare() reported {action!r} on a fresh file")
    check("caps at the bound", buffer_size(patched, 800000), 800000)
    # NEVER RAISES. A short context already asks for less than the cap, and a
    # patch that replaced rather than bounded would hand the profiler a BIGGER
    # buffer than stock on every small-context boot.
    check("does not raise a smaller stock value", buffer_size(patched, 1000), 40000)

    check("second run is a no-op", pi.prepare(patched, 800000)[0], patched)
    check("second run says so", pi.prepare(patched, 800000)[1], "already present")

    # Fail closed on a shape it does not recognise - both of these would
    # otherwise write something plausible into a file nobody re-reads.
    refuses("two returns", lambda: pi.prepare(
        "def get_max_prefill_buffer_size(c):\n"
        "    if c:\n        return 1\n    return 2\n", 10))
    refuses("function absent", lambda: pi.prepare("def other():\n    return 1\n", 10))
    refuses("cap below one", lambda: pi.prepare(STOCK, 0))

    for p in problems:
        print(f"  {p}", file=sys.stderr)
    if problems:
        print(f"indexer-workspace: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print("indexer-workspace: the per-step bound, the 800k shortfall claim and "
          "the capping rewrite hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
