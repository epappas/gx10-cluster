#!/usr/bin/env python3
"""The prefill ladder's parser and verdicts, exercised without a server.

`ws up vllm-prefill-ladder` needs a live endpoint to say anything. The two
parts that can go wrong SILENTLY do not:

  parse_metrics   pure function over Prometheus text. Its job is to notice that
                  a "cold" rung hit the prefix cache. If the metric names drift
                  it reports zero hits for every rung - which is exactly what a
                  genuinely cold rung reports - so a broken parser makes a
                  CONTAMINATED run look clean. The failure is silent in the one
                  direction that matters.
  verdict         pure function over the finished rungs. Every finding it makes
                  is a case where the run LOOKS fine: a contaminated rung is
                  simply fast, a miscalibrated one is simply a different
                  number. Nothing raises on its own.

Same tier logic as the rest of the suite
(decisions.md#testing-is-tiered-because-the-hardware-cannot-be-faked): this
runs in CI, the measuring half runs on the box.

    python3 tests/check_prefill_ladder.py
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOL = REPO / "workspaces" / "bench" / "vllm-prefill-ladder" / "prefill-ladder"

spec = importlib.util.spec_from_loader(
    "prefill_ladder", importlib.machinery.SourceFileLoader("prefill_ladder", str(TOOL))
)
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)

# Real shapes. vLLM emits these with labels; `prompt_tokens_by_source_total`
# carries the source in a label on ONE metric name, and a multi-engine host
# repeats every series.
METRICS = """\
# HELP vllm:prefix_cache_hits_total Prefix cache hits.
# TYPE vllm:prefix_cache_hits_total counter
vllm:prefix_cache_hits_total{engine="0",model_name="m"} 21504.0
vllm:prefix_cache_queries_total{engine="0",model_name="m"} 732642.0
vllm:prompt_tokens_total{engine="0",model_name="m"} 732642.0
vllm:prompt_tokens_by_source_total{engine="0",source="local_compute"} 711138.0
vllm:prompt_tokens_by_source_total{engine="0",source="local_cache_hit"} 21504.0
vllm:num_requests_running{engine="0",model_name="m"} 0.0
vllm:gpu_cache_usage_perc{engine="0",model_name="m"} 0.26
vllm:request_success_total{engine="0",finished_reason="stop"} 7.0
"""

# The published 2026-08-29 ladder from the kit this protocol comes from. It is
# the fixture for "a clean run stays clean": every rung cold, every rung on
# target, the follow-up reusing exactly the two pages the model allows.
PUBLISHED = [
    {"label": "8k", "target": 8000, "prompt_tokens": 7995, "ttft": 10.355,
     "hits": 0, "queries": 7995, "compute": 7995, "running_before": 0.0, "text": "OK"},
    {"label": "12k", "target": 12000, "prompt_tokens": 11995, "ttft": 13.382,
     "hits": 0, "queries": 11995, "compute": 11995, "running_before": 0.0, "text": "OK"},
    {"label": "16k", "target": 16000, "prompt_tokens": 15995, "ttft": 17.911,
     "hits": 0, "queries": 15995, "compute": 15995, "running_before": 0.0, "text": "OK"},
]
PUBLISHED_APC = {
    "label": "follow-up", "prompt_tokens": 8004, "ttft": 1.298, "hits": 7168,
    "queries": 8004, "compute": 836, "running_before": 0.0, "text": "OK",
    "shared": 7995,
}


def levels(findings: list[tuple[str, str]]) -> list[str]:
    return [level for level, _ in findings]


def main() -> int:
    problems: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            problems.append(f"{name}: expected {want!r}, got {got!r}")

    # --- the parser ---------------------------------------------------------
    m = pl.parse_metrics(METRICS)
    check("hits parsed", m.get("hits"), 21504.0)
    check("queries parsed", m.get("queries"), 732642.0)
    check("local_compute parsed", m.get("local_compute"), 711138.0)
    check("local_cache_hit parsed", m.get("local_cache_hit"), 21504.0)
    check("running parsed", m.get("running"), 0.0)
    if "vllm:request_success_total" in m or any("success" in k for k in m):
        problems.append("parser kept an unrelated metric")

    # Counters SUM across engines; a level must not. Summing two engines'
    # `num_requests_running` reports a queue depth no engine ever had, and this
    # tool uses it to decide whether the box was idle.
    two = pl.parse_metrics(
        'vllm:prefix_cache_hits_total{engine="0"} 40.0\n'
        'vllm:prefix_cache_hits_total{engine="1"} 60.0\n'
        'vllm:num_requests_running{engine="0"} 1.0\n'
        'vllm:num_requests_running{engine="1"} 1.0\n'
    )
    check("multi-engine counter summed", two.get("hits"), 100.0)
    check("multi-engine level not summed", two.get("running"), 1.0)

    bare = pl.parse_metrics("vllm:prefix_cache_hits_total 7\n")
    check("unlabelled series parsed", bare.get("hits"), 7.0)

    # A source label this tool does not read must not be silently folded into
    # one it does - external_cache_hit is a different thing from local compute.
    ext = pl.parse_metrics(
        'vllm:prompt_tokens_by_source_total{source="external_cache_hit"} 500.0\n'
    )
    check("unknown source ignored", ext.get("local_compute"), None)

    # --- /metrics and /tokenize are off the ROOT, and BASE_URL ends in /v1 ---
    check("v1 stripped", pl._root("http://h:8893/v1"), "http://h:8893")
    check("trailing slash", pl._root("http://h:8893/v1/"), "http://h:8893")
    check("root base", pl._root("http://h:8893"), "http://h:8893")

    # --- the page model -----------------------------------------------------
    # The published observation: 7168 hits on an 8004-token follow-up is TWO
    # 3584-token pages, and 836 tokens of real compute. Not "89.6% of a hit".
    check("two whole pages", pl.page_expectation(8004, 3584), 7168)
    # The published follow-up rows are exactly 2 / 3 / 4 full pages, which is
    # the strongest evidence the page model is the right model at all.
    check("three whole pages", pl.page_expectation(12015, 3584), 10752)
    check("four whole pages", pl.page_expectation(16015, 3584), 14336)
    check("efficiency 1.0 on the published row",
          pl.hit_efficiency(7168, 8004, 3584), 1.0)
    # Shorter than one page allows nothing, and dividing by that would
    # manufacture a failure out of a prompt that was too short to test with.
    check("sub-page returns None", pl.hit_efficiency(0, 1000, 3584), None)
    check("page must be positive", _raises(pl.page_expectation, 100, 0), True)

    # A SET, not a guess. One observation cannot separate 3584 from 896, and
    # the tool is about to tell somebody their page size is wrong.
    cands = pl.page_candidates(7168, 8004)
    if 3584 not in cands or 896 not in cands:
        problems.append(f"page candidates lost a real possibility: {cands}")
    if any(c <= 8004 - 7168 for c in cands):
        problems.append(f"page candidates kept one smaller than the remainder: {cands}")
    check("no candidates without hits", pl.page_candidates(0, 8004), [])

    # --- the verdicts -------------------------------------------------------
    # THE FIXTURE THAT MUST STAY CLEAN. A check that fires on a healthy
    # published run gets muted, and a muted check catches nothing.
    check("published ladder is clean",
          pl.verdict(PUBLISHED, PUBLISHED_APC, 3584, 0.02), [])

    # THE FAILURE THIS TOOL EXISTS FOR: a rerun that silently reused the last
    # run's pages. It is not slow, it is not wrong, it is FAST - which is what
    # makes it dangerous. Measured on the source kit: 10.3 s -> 1.9 s.
    contaminated = [dict(PUBLISHED[0], ttft=1.9, hits=7168, compute=827)]
    check("contaminated cold rung is INVALID",
          levels(pl.verdict(contaminated, None, 3584, 0.02)), ["INVALID"])

    # A rung that missed its size measured different work than its label says,
    # so comparing it to another run of "the same" ladder is meaningless.
    drifted = [dict(PUBLISHED[0], prompt_tokens=6000)]
    check("size drift is INVALID",
          levels(pl.verdict(drifted, None, 3584, 0.02)), ["INVALID"])
    # ...and within tolerance it is not a finding. 7995 against 8000 is 0.06%.
    check("small drift is fine", pl.verdict([PUBLISHED[0]], None, 3584, 0.02), [])

    # Concurrency turns a prefill measurement into a queueing measurement, but
    # it does not invalidate the run - so it warns and still exits 0.
    busy = [dict(PUBLISHED[0], running_before=2.0)]
    check("busy server WARNs", levels(pl.verdict(busy, None, 3584, 0.02)), ["WARN"])

    # A server without prefix caching reports zero hits on every rung, which is
    # the same reading as a clean cold rung. Convicting there would condemn a
    # correctly-configured server, so it is a NOTE about the reuse row only.
    no_apc = [dict(r, queries=0) for r in PUBLISHED]
    check("prefix caching off is a NOTE",
          levels(pl.verdict(no_apc, None, 3584, 0.02)), ["NOTE"])

    # The page assumption being wrong is the tool's fault, not the server's,
    # and it must read that way: a WARN naming the alternatives. A server
    # aligning on 4096 reuses ONE page of a 7995-token prefix, not the two a
    # 3584-token page would allow.
    wrong_page = dict(PUBLISHED_APC, hits=4096)
    got = pl.verdict(PUBLISHED, wrong_page, 3584, 0.02)
    check("wrong page WARNs", levels(got), ["WARN"])
    if got and "4096" not in got[0][1]:
        problems.append(f"the wrong-page WARN does not name 4096: {got}")

    # ...and reuse that fits NO page model is a different message: there is
    # nothing honest to suggest, so it must not invent a page size to blame.
    lost = dict(PUBLISHED_APC, hits=896)
    got = pl.verdict(PUBLISHED, lost, 3584, 0.02)
    check("unexplainable loss still WARNs", levels(got), ["WARN"])
    if got and "consistent with a page" in got[0][1]:
        problems.append(f"named a page size that explains nothing: {got}")

    # Finer alignment than assumed is not a fault either - the ratio is simply
    # not the ratio the caller asked for.
    finer = dict(PUBLISHED_APC, hits=7995, shared=7995)
    check("finer alignment is a NOTE",
          levels(pl.verdict(PUBLISHED, finer, 3584, 0.02)), ["NOTE"])

    # A server that ignores "Reply with OK." is worth mentioning and is not a
    # timing problem, so it must not invalidate the ladder.
    chatty = [dict(PUBLISHED[0], text="Certainly! OK.")]
    check("off-script answer WARNs only",
          levels(pl.verdict(chatty, None, 3584, 0.02)), ["WARN"])

    for p in problems:
        print(f"prefill-ladder: {p}", file=sys.stderr)
    if problems:
        print("prefill-ladder: fix the tool, not the expectation - a ladder that "
              "cannot prove a rung was cold is a stopwatch with extra steps",
              file=sys.stderr)
        return 1

    print("prefill-ladder: metrics parser, page model and 10 verdicts hold")
    return 0


def _raises(fn, *args) -> bool:
    try:
        fn(*args)
    except ValueError:
        return True
    return False


if __name__ == "__main__":
    sys.exit(main())
