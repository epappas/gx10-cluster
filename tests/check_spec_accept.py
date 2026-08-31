#!/usr/bin/env python3
"""The acceptance probe's parser and verdicts, exercised without a server.

`ws up spec-decode-accept` needs a running speculative server to say anything.
The two parts that can go wrong SILENTLY do not:

  parse_metrics   pure function over Prometheus text. If it stops recognising
                  a metric name it reports zero drafts, and the tool then
                  prints "speculative decoding is OFF for this server" - a
                  WRONG answer wearing the costume of a finding.
  verdict         pure function over the acceptance ladder. It is the whole
                  point of the tool: it separates a weak drafter from a broken
                  attention mask, which need different fixes. A verdict that
                  has drifted to "ok" for everything is worse than none.

There is now a THIRD way to go wrong, and it arrived with SGLang. That engine
publishes no per-position counter, so the tool degrades to accept length -
and a degraded path that degrades SILENTLY is the worst of the three, because
it would return a confident mask verdict about a shape it never measured. The
SGLang assertions below therefore check both halves: that the number is read
at all, and that `mask` is unreachable without a ladder to support it.

Same tier logic as the rest of the suite
(decisions.md#testing-is-tiered-because-the-hardware-cannot-be-faked): this
runs in CI, the serving half runs on the box.

    python3 tests/check_spec_accept.py
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOL = REPO / "workspaces" / "bench" / "spec-decode-accept" / "spec-accept"

spec = importlib.util.spec_from_loader(
    "spec_accept", importlib.machinery.SourceFileLoader("spec_accept", str(TOOL))
)
sa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sa)

# Real shapes, not invented ones: vLLM emits these with labels, and per-position
# counters carry a `position` label on the SAME metric name.
METRICS = """\
# HELP vllm:spec_decode_num_drafts_total Number of drafts.
# TYPE vllm:spec_decode_num_drafts_total counter
vllm:spec_decode_num_drafts_total{engine="0",model_name="m"} 100.0
vllm:spec_decode_num_draft_tokens_total{engine="0",model_name="m"} 700.0
vllm:spec_decode_num_accepted_tokens_total{engine="0",model_name="m"} 638.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",position="0"} 98.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",position="1"} 98.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",position="6"} 83.0
vllm:spec_decode_num_drafts_created 1.7e+09
vllm:num_requests_running{engine="0"} 3.0
"""


# SGLang's half, and it is a DIFFERENT SHAPE on purpose: these are gauges of
# the live configuration, not cumulative counters. A parser that treated them
# as counters would report a drafter that never accepts anything.
SGL_METRICS = """\
# HELP sglang:spec_num_draft_tokens Currently active speculative_num_draft_tokens
# TYPE sglang:spec_num_draft_tokens gauge
sglang:spec_num_draft_tokens{model_name="m"} 4.0
sglang:spec_num_steps{model_name="m"} 3.0
sglang:gen_throughput{model_name="m"} 124.2
sglang:num_running_reqs{model_name="m"} 2.0
"""


def ladder(cls: str, *vals: float) -> dict:
    """A measurement with the given per-position acceptance and nothing else.

    The class is part of the fixture because it is part of the TEST: a ladder
    that convicts on structured output is a healthy prose run.
    """
    return {"drafts": 100, "class": cls, "per_pos": list(enumerate(vals))}


# The two published healthy medians from the GLM-5.3-Flash kit, BOTH from the
# same working server. They are the whole reason the verdict is class-aware.
HEALTHY_STRUCTURED = (0.98, 0.98, 0.94, 0.94, 0.91, 0.83, 0.83)   # aggregate 0.92
HEALTHY_PROSE = (0.75, 0.58, 0.41, 0.28, 0.16, 0.09, 0.06)        # aggregate 0.33


def main() -> int:
    problems: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            problems.append(f"{name}: expected {want!r}, got {got!r}")

    # --- the parser ---------------------------------------------------------
    m = sa.parse_metrics(METRICS)
    check("drafts parsed", m.get("vllm:spec_decode_num_drafts_total"), 100.0)
    check("draft tokens parsed", m.get("vllm:spec_decode_num_draft_tokens_total"), 700.0)
    check("accepted parsed", m.get("vllm:spec_decode_num_accepted_tokens_total"), 638.0)
    check("position 0 parsed", m.get("pos:0"), 98.0)
    check("position 6 parsed", m.get("pos:6"), 83.0)
    # `_created` is a timestamp, not a count. Summing it into a counter would
    # produce an accept ratio in the billions and read as corruption.
    if any(k.endswith("_created") for k in m):
        problems.append("parser kept a _created series")
    # Non-spec metrics must not leak in - the tool assumes every key it deltas
    # is a spec-decode counter.
    if any("num_requests_running" in k for k in m):
        problems.append("parser kept an unrelated metric")

    # A server exposing the same counter for two engines must be SUMMED, not
    # last-wins. Getting this wrong halves every number on a multi-engine host
    # and looks exactly like a drafter that is underperforming.
    two = sa.parse_metrics(
        'vllm:spec_decode_num_drafts_total{engine="0"} 40.0\n'
        'vllm:spec_decode_num_drafts_total{engine="1"} 60.0\n'
    )
    check("multi-engine summed", two.get("vllm:spec_decode_num_drafts_total"), 100.0)

    # Unlabelled is legal Prometheus and some builds emit it.
    bare = sa.parse_metrics("vllm:spec_decode_num_drafts_total 7\n")
    check("unlabelled series parsed", bare.get("vllm:spec_decode_num_drafts_total"), 7.0)

    # --- /metrics is off the ROOT, and BASE_URL ends in /v1 -----------------
    check("v1 stripped", sa._metrics_url("http://h:8893/v1"), "http://h:8893/metrics")
    check("trailing slash", sa._metrics_url("http://h:8893/v1/"), "http://h:8893/metrics")
    check("root base", sa._metrics_url("http://h:8893"), "http://h:8893/metrics")

    # --- the verdicts, which are the reason this tool exists ----------------
    check("healthy structured",
          sa.verdict(ladder("structured", *HEALTHY_STRUCTURED))[0], "ok")

    # THE FALSE POSITIVE THAT WOULD GET THIS MUTED, and it is not hypothetical:
    # the published healthy PROSE ladder collapses to 0.06, which is exactly
    # the shape a broken mask makes. Judged as prose it must come back clean.
    check("healthy prose is not a mask",
          sa.verdict(ladder("prose", *HEALTHY_PROSE))[0], "ok")

    # ...and the same numbers, if they ever showed up on the STRUCTURED class
    # where a working drafter stays above 0.8, are the finding.
    check("that same ladder on structured IS the finding",
          sa.verdict(ladder("structured", *HEALTHY_PROSE))[0], "mask")

    # Weak everywhere is a different fix, and must not be reported as a mask.
    check("weak drafter on structured",
          sa.verdict(ladder("structured", 0.31, 0.22, 0.14, 0.09, 0.05, 0.03, 0.02))[0],
          "weak")

    # On prose, only a low HEAD says anything at all.
    check("weak drafter on prose",
          sa.verdict(ladder("prose", 0.22, 0.14, 0.09, 0.05, 0.03, 0.02, 0.01))[0],
          "weak")

    # No drafts at all is neither - it means the server has no speculator.
    check("no drafts", sa.verdict({"drafts": 0, "class": "structured", "per_pos": []})[0],
          "none")

    # A short ladder (k=2 MTP) has to reach a verdict too, not index-error.
    check("k=2 ladder", sa.verdict(ladder("structured", 0.95, 0.88))[0], "ok")

    # --- the SGLang half ----------------------------------------------------
    # SGLang publishes NO per-position counter, so this tool degrades to accept
    # length there. The risk in a degraded path is that it degrades SILENTLY -
    # returning a confident mask verdict about a shape it never measured - so
    # the two things asserted here are that it reads the number at all, and
    # that it refuses to convict a mask on it.
    g = sa.parse_sglang_metrics(SGL_METRICS)
    check("sglang window parsed", g.get("sglang:spec_num_draft_tokens"), 4.0)
    check("sglang steps parsed", g.get("sglang:spec_num_steps"), 3.0)
    if any(k.startswith("vllm:") for k in g):
        problems.append("sglang parser kept a vllm series")

    # The field has been spelled both ways across versions, and a probe that
    # answers "no speculative decoding" because a key was renamed is the exact
    # wrong answer this tool exists to avoid producing.
    check("accept length, avg_ spelling",
          sa.accept_length({"internal_states": [{"avg_spec_accept_length": 3.4}]}), 3.4)
    check("accept length, bare spelling",
          sa.accept_length({"internal_states": [{"spec_accept_length": 2.2}]}), 2.2)
    check("accept length absent",
          sa.accept_length({"internal_states": [{"max_running_requests": 48}]}), None)
    check("accept length, no internal states", sa.accept_length({}), None)

    def sgl(length, k=3):
        return {"engine": "sglang", "class": "structured", "drafts": 1,
                "per_pos": [], "accepted_per_step": length, "k": k}

    check("sglang healthy", sa.verdict(sgl(3.4))[0], "ok")
    # 1.0 is the floor: only the target's own bonus token survives every step.
    check("sglang floor is weak", sa.verdict(sgl(1.0))[0], "weak")
    check("sglang no reading", sa.verdict(sgl(None))[0], "none")
    # THE ONE THAT MATTERS: there is no ladder here, so `mask` must be
    # unreachable no matter what the length is.
    for length in (1.0, 1.2, 2.0, 3.9):
        if sa.verdict(sgl(length))[0] == "mask":
            problems.append(
                f"sglang verdict returned 'mask' at accept length {length} - "
                "there is no per-position data to support that"
            )

    # --- small helpers ------------------------------------------------------
    check("median even", sa.median([1.0, 3.0]), 2.0)
    check("median ignores None", sa.median([None, 4.0, None]), 4.0)
    check("median of nothing", sa.median([None]), None)
    check("bar full", sa.bar(1.0, 4), "####")
    check("bar empty", sa.bar(0.0, 4), "----")
    # Acceptance is a ratio, but a truncated counter window can produce a value
    # outside [0,1]. The bar must clamp rather than emit a ragged line.
    check("bar clamps high", sa.bar(1.4, 4), "####")
    check("bar clamps low", sa.bar(-0.2, 4), "----")

    for p in problems:
        print(f"spec-accept: {p}", file=sys.stderr)
    if problems:
        print("spec-accept: fix the tool, not the expectation - a probe that "
              "cannot distinguish the two failures is just a slower tok/s",
              file=sys.stderr)
        return 1

    print("spec-accept: both metric parsers, 7 ladder verdicts and the "
          "length-only fallback hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
