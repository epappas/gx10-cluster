#!/usr/bin/env python3
"""The quant A/B's grading and comparison, exercised without a server.

`ws up quant-quality-ab` needs a running model to say anything. Its judgement
does not: grading is a pure function over text, and the comparison is a pure
function over two saved runs. Those are the halves that can go wrong SILENTLY -
a grader that stops stripping reasoning starts crediting a model for the right
answer appearing inside its own scratchpad, and a comparison that stops
detecting regressions reports "no regressions" forever.

The forever-green failure is the one that matters. A tool whose whole purpose
is to catch a quality regression is worthless the moment it cannot, and nothing
about its output would look different.

Same tier logic as the rest of the suite
(decisions.md#testing-is-tiered-because-the-hardware-cannot-be-faked): this
runs in CI, the serving half runs on the box.

    python3 tests/check_quant_ab.py
"""

from __future__ import annotations

import contextlib
# NO BYTECODE CACHE. SourceFileLoader writes __pycache__ NEXT TO THE TOOL, and
# a stale entry there makes this suite test the PREVIOUS version of the file -
# silently, and in the one direction that matters: a fix looks like it did not
# take, or worse, a broken file looks fine. Found the hard way when a corrected
# grader kept failing CI against its own old bytecode.
import sys

sys.dont_write_bytecode = True

import importlib.machinery
import io
import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOL = REPO / "workspaces" / "bench" / "quant-quality-ab" / "quant-ab"

spec = importlib.util.spec_from_loader(
    "quant_ab", importlib.machinery.SourceFileLoader("quant_ab", str(TOOL)))
qab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qab)


def check(label: str, got, want, problems: list[str]) -> None:
    if got != want:
        problems.append(f"{label}: got {got!r}, want {want!r}")


def main() -> int:
    problems: list[str] = []

    # --- grading -----------------------------------------------------------
    check("substring hit", qab.graded("The answer is 98.", ["98"]), True, problems)
    check("substring miss", qab.graded("The answer is 99.", ["98"]), False, problems)
    check("case folded", qab.graded("CAROL has it", ["carol"]), True, problems)
    check("empty answer", qab.graded("", ["98"]), False, problems)

    # THE ONE THAT MATTERS MOST. A reasoning model that talks its way past the
    # right answer and then states the wrong one must not be credited for the
    # trace. If this stops holding, every score silently inflates.
    leaked = qab.strip_reasoning(
        "<think>the alpha code is 7391-CORAL, or maybe not</think> I could not find it.")
    check("reasoning stripped before grading",
          qab.graded(leaked, ["7391-coral"]), False, problems)
    check("answer outside the block survives",
          qab.graded(qab.strip_reasoning("<think>hmm</think> It is 7391-CORAL."),
                     ["7391-coral"]), True, problems)
    check("unclosed block is not swallowed",
          "still here" in qab.strip_reasoning("<think>open forever still here"), True, problems)

    # --- haystack ----------------------------------------------------------
    salt, hay = qab.build_haystack(8000, None)
    check("salt is first", hay.startswith(f"Session {salt}."), True, problems)
    lines = hay.splitlines()
    for depth, label, secret in qab.NEEDLES:
        if secret not in hay:
            problems.append(f"needle {label} missing from the haystack")
            continue
        at = next(i for i, ln in enumerate(lines) if secret in ln)
        frac = at / max(len(lines), 1)
        # Planted depth is the whole point of the needle tasks - a needle that
        # drifts to the front stops probing block selection at depth.
        if abs(frac - depth) > 0.1:
            problems.append(f"needle {label} at {frac:.2f}, wanted {depth:.2f}")
    if len(set(qab.build_haystack(8000, None)[0] for _ in range(5))) != 5:
        problems.append("salt is not unique per call - runs would hit the prefix cache")

    # --- comparison --------------------------------------------------------
    base = {"when": "t0", "model": "m",
            "rows": [{"task": "a", "passed": True}, {"task": "b", "passed": False}]}
    regressed = {"when": "t1", "model": "m",
                 "rows": [{"task": "a", "passed": False, "sample": ""},
                          {"task": "b", "passed": False, "sample": ""}]}
    improved = {"when": "t1", "model": "m",
                "rows": [{"task": "a", "passed": True, "sample": ""},
                         {"task": "b", "passed": True, "sample": ""}]}
    # compare() reports to stdout by design; swallow it so a PASSING test does
    # not print a red "1 regression(s)" that reads as a failure.
    with contextlib.redirect_stdout(io.StringIO()):
        rc_regressed = qab.compare(regressed, base)
        # An improvement is reported, never punished: a tool that fails on good
        # news gets run once and then never again.
        rc_improved = qab.compare(improved, base)
        rc_same = qab.compare(base | {"rows": base["rows"]}, base)
    check("regression exits 1", rc_regressed, 1, problems)
    check("improvement exits 0", rc_improved, 0, problems)
    check("identical exits 0", rc_same, 0, problems)

    # --- THE GRADER ITSELF MUST BE RIGHT -----------------------------------
    # `counting` shipped with ["5"] as the accepted answer for a word that has
    # six r's, and the first real run against a healthy server reported a
    # failure. A grader that is wrong is worse than no grader: it invents a
    # regression, and a tool that cries wolf gets muted - which is the one
    # outcome a quality gate cannot survive.
    #
    # So every accepted answer that CAN be computed here IS, rather than
    # trusted. These are deliberately independent restatements of the task, not
    # copies of the answer.
    truth = {
        "arith_chain": str(int(((17 * 23) + 149) / 4 - 37)),
        "units": str(int(3.5 * 1000)),
        "counting": str("strawberry-preserver".count("r")),
        "order_of_ops": str(int(2 + 3 * 4 ** 2 - 6 / 3)),
        "indirection": str((lambda x: (x * 3 - x) * 2)(7)),
    }
    by_name = {name: accepted for name, _, accepted in qab.REASONING_TASKS}
    for name, want in truth.items():
        if name not in by_name:
            problems.append(f"{name}: task disappeared - drop it from the truth table too")
        elif not any(want == a or want in a for a in by_name[name]):
            problems.append(
                f"{name}: accepted answers {by_name[name]} do not contain the "
                f"computed truth {want!r} - THE GRADER IS WRONG")

    # --- reasoning at depth ------------------------------------------------
    # Same rule as above: the arithmetic in the DEEP task answers is recomputed
    # here from the planted facts rather than trusted, because a grader that is
    # wrong invents a regression.
    crates = {}
    for _, fact in qab.FACTS:
        for depot in ("alpha", "bravo", "gamma"):
            if depot in fact and "crates" in fact:
                crates[depot] = int(
                    [w for w in fact.split() if w.isdigit()][0])
    deep_truth = {
        "deep_sum": str(crates["alpha"] + crates["bravo"]),
        "deep_three_sum": str(sum(crates.values())),
        "deep_compare": max(crates, key=crates.get),
        "deep_difference": str(crates["alpha"] - crates["gamma"]),
    }
    deep_by_name = {n: a for n, _, a in qab.DEEP_TASKS}
    for name, want in deep_truth.items():
        if name not in deep_by_name:
            problems.append(f"{name}: deep task missing")
        elif not any(want == a or want in a for a in deep_by_name[name]):
            problems.append(
                f"{name}: accepted {deep_by_name[name]} does not contain "
                f"computed truth {want!r} - THE GRADER IS WRONG")

    # Every deep task must need facts from at least TWO different depths, or it
    # is a retrieval test wearing a reasoning label.
    depths = [d for d, _ in qab.FACTS]
    if len(set(depths)) < 2:
        problems.append("FACTS are not spread across depths")
    if max(depths) - min(depths) < 0.5:
        problems.append(
            f"FACTS span only {max(depths) - min(depths):.2f} of the context - "
            "too narrow to prove anything about long-range combination")

    # THE ABSENCE GUARD IS THE LOAD-BEARING ONE. If it ever starts accepting a
    # number, a confabulating model passes the whole suite.
    name, _, accepted = qab.ABSENCE_TASK
    if any(a.strip().isdigit() for a in accepted):
        problems.append(f"{name}: accepts a bare number - it must accept only refusals")
    check("absence guard rejects a fabricated number",
          qab.graded("The delta depot holds 12 crates.", accepted), False, problems)
    check("absence guard accepts a refusal",
          qab.graded("NOT MENTIONED", accepted), True, problems)
    check("absence guard accepts a phrased refusal",
          qab.graded("The delta depot is not mentioned in the text.", accepted),
          True, problems)

    # --- haystack plants every fact, and loses none -------------------------
    _, hay = qab.build_haystack(8000, None)
    for _, fact in qab.FACTS:
        if fact not in hay:
            problems.append(f"planted fact missing from haystack: {fact[:40]}")
    # Small contexts round two depths onto one line; the placer must displace
    # rather than overwrite, or a fact vanishes and reads as a model failure.
    _, tiny = qab.build_haystack(500, None)
    missing = [f for _, f in qab.FACTS if f not in tiny]
    missing += [s for _, _, s in qab.NEEDLES if s not in tiny]
    if missing:
        problems.append(f"small-context haystack dropped {len(missing)} plant(s)")

    # --- task hygiene ------------------------------------------------------
    names = [t[0] for t in qab.REASONING_TASKS]
    if len(names) != len(set(names)):
        problems.append("duplicate task names - the comparison keys on them")
    for name, prompt, accepted in qab.REASONING_TASKS:
        if not accepted or any(a != a.lower() for a in accepted):
            problems.append(f"{name}: accepted answers must be non-empty and lowercase")
        if len(prompt) < 20:
            problems.append(f"{name}: prompt looks truncated")

    for p in problems:
        print(f"quant-ab: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"quant-ab: grading, {len(qab.NEEDLES)} needle depths, "
          f"{len(qab.DEEP_TASKS) + 1} deep-reasoning tasks (incl. the absence "
          f"guard), comparison and {len(qab.REASONING_TASKS)} task definitions "
          f"all sound")
    return 0


if __name__ == "__main__":
    sys.exit(main())
