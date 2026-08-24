#!/usr/bin/env python3
"""The quality gate's detectors, exercised without a server.

`ws up vllm-quality-gate` needs a running model to say anything. Its
detectors do not: they are pure functions over text, and they are the half
that can go wrong silently. A regex that stops matching full-width special
tokens, or a novelty threshold that drifts, turns the gate green forever -
which is worse than not having it, because a green gate is trusted.

Two directions matter equally and both are here:

  MISSES  a real failure the detector stops catching
  CRIES   clean output the detector starts flagging - a gate with false
          positives gets muted, and a muted gate catches nothing

Same tier logic as the rest of the suite (decisions.md#testing-is-tiered-because-the-hardware-cannot-be-faked):
this runs in CI, the serving half runs on the box.

    python3 tests/check_detectors.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
GATE = REPO / "workspaces" / "bench" / "vllm-quality-gate" / "quality-gate"

spec = importlib.util.spec_from_loader(
    "quality_gate", importlib.machinery.SourceFileLoader("quality_gate", str(GATE))
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def clean_prose(words: int) -> str:
    """Long, varied, healthy text. The control for every novelty assertion."""
    return " ".join(
        f"The scheduler admitted request {i} while the cache held {i * 7 % 97} "
        f"blocks, and the operator noted deviation {i * 13 % 89} in the log."
        for i in range(words // 20)
    )


def templated_loop(passes: int) -> str:
    """The shape that fools uniqueness checks.

    Not a verbatim repeat: a small set of stock phrases recombined with one
    element varying each pass. Character-block uniqueness reads this as mostly
    novel text; recycled word 8-grams read it correctly.

    The varying element is drawn from a SMALL POOL, which is what makes this a
    loop rather than slow progress. A monotonically increasing counter would
    mint a genuinely new 8-gram on every pass and never converge - it would
    also be the wrong fixture, because a model that keeps producing values it
    has never produced before is not looping.
    """
    stock = [
        "Let me reconsider the problem from the beginning once more",
        "Wait, I need to double-check that assumption carefully again",
        "So the answer should be consistent with what I derived above",
    ]
    return " ".join(f"{stock[i % 3]} at step {i % 5}." for i in range(passes))


def main() -> int:
    problems: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            problems.append(f"{name}: expected {want!r}, got {got!r}")

    # --- loop vs heavy tail -------------------------------------------------
    # A length-capped request is either still saying new things (raise the
    # budget) or recycling (raising the budget changes only the bill). Getting
    # this backwards sends people to the wrong fix, which is the whole reason
    # the verdict exists.
    check("templated loop", gate.length_verdict(clean_prose(600) + templated_loop(900)), "loop")
    check("healthy long tail", gate.length_verdict(clean_prose(4000)), "heavy-tail")
    check("too short to judge", gate.length_verdict("a few words only"), "short")

    # A single collapsed stretch that RECOVERS is a long verbatim quote, not a
    # loop. Calling it one teaches people to ignore the verdict.
    recovered = clean_prose(900) + templated_loop(400) + clean_prose(3000)
    check("transient repetition is not a loop", gate.length_verdict(recovered), "heavy-tail")

    # --- per-detector -------------------------------------------------------
    cases: list[tuple[str, dict, list[str]]] = [
        (
            "clean prose passes",
            dict(nonce="n1", shape="prose", content="Unified memory means the "
                 "model server and the page cache draw on one pool, so sizing "
                 "one without the other is how a box starts swapping.",
                 reasoning="", finish="stop", completion_tokens=42),
            [],
        ),
        (
            # The silent one. Empty text carries no special tokens, no script
            # drift and no markup, so it passes every other detector.
            "empty reply with tokens billed",
            dict(nonce="n2", shape="prose", content="   ", reasoning="thinking...",
                 finish="stop", completion_tokens=1024),
            ["empty-with-1024-tokens-billed"],
        ),
        (
            # Full-width forms. A regex written from the ASCII spelling alone
            # misses every real leak on the DeepSeek tokenizer family.
            "full-width special token leak",
            dict(nonce="n3", shape="prose", content="<｜begin▁of▁sentence｜>Here is the answer.",
                 reasoning="", finish="stop", completion_tokens=20),
            ["special-token-leak"],
        ),
        (
            "prompt echo",
            dict(nonce="abc123", shape="prose",
                 content="sentinel-abc123 the context block says ctxabc123w4",
                 reasoning="", finish="stop", completion_tokens=20),
            ["prompt echo"],
        ),
        (
            "starts mid-sentence",
            dict(nonce="n4", shape="prose", content="s, and the tools available.",
                 reasoning="", finish="stop", completion_tokens=20),
            ["starts mid-sentence"],
        ),
        (
            # A lowercase FIRST WORD is ordinary and correct. Flagging it is
            # the false positive that would get this detector muted.
            "lowercase opening is not mid-sentence",
            dict(nonce="n5", shape="prose", content="unified memory is one pool, which changes sizing.",
                 reasoning="", finish="stop", completion_tokens=20),
            [],
        ),
        (
            "script drift against an English-only contract",
            dict(nonce="n6", shape="prose", content="The answer is 統一記憶體 in one pool.",
                 reasoning="", finish="stop", completion_tokens=20),
            ["script drift"],
        ),
        (
            "tool markup leaking into the reply",
            dict(nonce="n7", shape="prose", content="<available_skills>bash</available_skills> ok",
                 reasoning="", finish="stop", completion_tokens=20),
            ["prompt/tool markup"],
        ),
        (
            "json contract honoured",
            dict(nonce="n8", shape="json", content='{"name": "gx10", "nodes": 2, "notes": "fine"}',
                 reasoning="", finish="stop", completion_tokens=20),
            [],
        ),
        (
            "json contract broken",
            dict(nonce="n9", shape="json", content="Sure! Here is the object you asked for.",
                 reasoning="", finish="stop", completion_tokens=20),
            ["asked for JSON only"],
        ),
    ]

    for name, kwargs, expected in cases:
        found = gate.detect(**kwargs)
        if not expected and found:
            problems.append(f"{name}: false positive {found}")
        for want in expected:
            if not any(want in f for f in found):
                problems.append(f"{name}: expected a {want!r} finding, got {found}")

    # A length-capped reply is always a finding, and the verdict says which fix
    # applies. Both branches must reach the caller.
    looped = gate.detect(nonce="nA", shape="prose", content="", reasoning=templated_loop(1200),
                         finish="length", completion_tokens=1024)
    if not any("reasoning loop" in f for f in looped):
        problems.append(f"length+loop: expected a loop finding, got {looped}")
    tailed = gate.detect(nonce="nB", shape="prose", content=clean_prose(4000), reasoning="",
                         finish="length", completion_tokens=1024)
    if not any("HEALTHY tail" in f for f in tailed):
        problems.append(f"length+tail: expected a heavy-tail finding, got {tailed}")

    for p in problems:
        print(f"detectors: {p}", file=sys.stderr)
    if problems:
        print("detectors: fix the detector, not the expectation - a gate that "
              "cannot fail is not a gate", file=sys.stderr)
        return 1

    print(f"detectors: {len(cases)} cases and 6 novelty verdicts hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
