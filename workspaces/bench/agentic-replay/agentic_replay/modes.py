"""replay and soak. Both send planned bodies and record what comes back."""

from __future__ import annotations

import argparse
import threading
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from .client import Reply, post_chat
from .core import Sampling, sha256_of, token_worth
from .corpus import Corpus, load_corpus
from .recall import Probe, score
from .results import Run, new_run_dir, per_minute, reply_record, request_rows
from .tooldefs import TOOLS, check_reply
from .workload import (PIECE_BYTES, SYSTEM_PROMPT, Planned, ReplaySpec, ScriptedHistory, SoakSpec,
                       opening, replay_requests, salt_for, seed_probe_body, soak_requests)

REPO = Path(__file__).resolve().parents[4]


def open_run(args: argparse.Namespace) -> Run:
    run = Run(new_run_dir(Path(args.results_root), args.label), args.base_url, args.api_key,
              args.nodes, args.memguard_log)
    run.start_sampler(args.ssh_config)
    return run


def sampling_of(args: argparse.Namespace) -> Sampling:
    return Sampling(args.temperature, args.top_p, args.top_k, args.max_tokens)


def discover_model(args: argparse.Namespace, snapshot: dict[str, Any]) -> str | None:
    if args.model:
        return args.model
    body = snapshot["models"].get("body") or {}
    data = body.get("data") or []
    return data[0].get("id") if data else None


def probe_seed(run: Run, args: argparse.Namespace, model: str, seed: int) -> Reply:
    body = seed_probe_body(model, sampling_of(args), seed)
    reply = post_chat(args.base_url, args.api_key, body, args.request_timeout)
    run.add_request({"kind": "seed_probe", "seed": seed, **reply_record(reply)})
    return reply


def base_workload(args: argparse.Namespace, corpus: Corpus, seeds: list[int], sent: bool) -> dict[str, Any]:
    """Everything compare refuses to mix. The model is deliberately not here."""
    return {
        "mode": args.mode, "seeds": seeds, "corpus_rev": corpus.rev, "corpus_hash": corpus.digest,
        "sampling": sampling_of(args).as_body(), "seed_sent": sent,
        "tools_sha": sha256_of(TOOLS), "system_sha": sha256_of(SYSTEM_PROMPT),
        "piece_bytes": PIECE_BYTES,
    }


def probe_score(probe: Probe, reply: Reply) -> int | str:
    """A reply with no answer in it is neither right nor wrong."""
    if reply.budget_stop:
        return "budget"
    if reply.tool_calls and not (reply.content or "").strip():
        return "tool_call"
    return score(probe, reply.content or "")


def annotate(planned: Planned, seed: int, reply: Reply) -> dict[str, Any]:
    verdicts = check_reply(reply.tool_calls, reply.content, TOOLS)
    record: dict[str, Any] = {
        "kind": planned.kind, "seed": seed, "conv": planned.conv, "step": planned.step,
        "target_bytes": planned.target_bytes, "salt": planned.salt, "variant": planned.variant,
        "request_bytes": len(planned.body), "tool_valid": [v.valid for v in verdicts],
        "tool_reasons": [v.reason for v in verdicts], **reply_record(reply),
    }
    if planned.kind == "step" and planned.step == 1:
        cached = reply.cached_tokens
        record["not_cold"] = None if cached is None else cached > 0
    if planned.probe:
        probe = planned.probe
        record["probe"] = {"kind": probe.kind, "depth_bytes": probe.depth_bytes}
        record["score"] = probe_score(probe, reply)
    if planned.kind == "response_format":
        answered = "refused" if reply.status else "no answer"
        record["response_format"] = "served" if reply.status == 200 else answered
    return record


def _replay_conversation(
    run: Run, args: argparse.Namespace, requests: Iterator[Planned], seed: int,
) -> bool:
    """True if the server stayed up. An HTTP refusal is recorded and the run goes on."""
    for planned in requests:
        reply = post_chat(args.base_url, args.api_key, planned.body, args.request_timeout)
        run.add_request(annotate(planned, seed, reply))
        if reply.dead:
            return False
    return True


def replay_spec(args: argparse.Namespace) -> ReplaySpec:
    return ReplaySpec(
        token_worth(args.target_tokens), token_worth(args.step_tokens),
        tuple(token_worth(t) for t in args.probe_tokens), args.fact_count, sampling_of(args),
        args.interleave, args.response_format, args.sampling_check)


def sampling_verdict(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Do request values win? A failed variant shows nothing, whatever its text.

    Greedy and hot differ only in temperature. hot_top_k_1 and hot_top_p_tiny narrow
    hot back to the top token, so each must equal greedy if its value was applied.
    """
    variants = {r["variant"]: r for r in records if r.get("variant")}
    text = {name: (r.get("content") or "") + "".join((r.get("reasoning") or {}).values())
            for name, r in variants.items()}
    usable = {name for name, r in variants.items() if text[name] and not r.get("error")}
    base = {"max_tokens": {n: r.get("completion_tokens") for n, r in variants.items()},
            "errors": {n: r["error"] for n, r in variants.items() if r.get("error")},
            "replies": text}
    if not {"greedy", "hot"} <= usable or text["hot"] == text["greedy"]:
        return {"temperature": "not shown", "top_k": "not shown", "top_p": "not shown", **base}

    def narrowed(name: str) -> str:
        return "honoured" if name in usable and text[name] == text["greedy"] else "not shown"

    return {"temperature": "honoured", "top_k": narrowed("hot_top_k_1"),
            "top_p": narrowed("hot_top_p_tiny"), **base}


def replay_summary(run: Run, corpus_reused: bool, stopped: str | None) -> dict[str, Any]:
    memory = run.memory_summary()
    records = run.records
    probes = [r for r in records if r["kind"] == "probe"]
    return {
        "stopped": stopped, "corpus_reused": corpus_reused,
        "requests": request_rows(records), "memory": memory,
        "recall": [{"size_bytes": r["target_bytes"], **r["probe"], "score": r["score"]}
                   for r in probes],
        "response_format": [r["response_format"] for r in records if "response_format" in r],
        "sampling_check": sampling_verdict(records) if any(r.get("variant") for r in records) else None,
    }


def corpus_was_reused(corpus: Corpus, size_bytes: int) -> bool:
    return size_bytes > corpus.size_bytes


def run_replay(args: argparse.Namespace) -> int:
    run = open_run(args)
    snapshot = run.snapshot("start")
    model = discover_model(args, snapshot)
    seeds = args.seeds[:args.repeats]
    if model is None:
        return fail(run, f"no model: {snapshot['models'].get('error')}")
    corpus = load_corpus(REPO, args.corpus_rev)
    probe = probe_seed(run, args, model, seeds[0])
    if probe.dead:
        return fail(run, f"server unreachable: {probe.error}")
    sent = probe.status == 200
    spec = replay_spec(args)
    run.write_json("manifest.json", {
        "model": model, "base_url": args.base_url,
        "workload": {**base_workload(args, corpus, seeds, sent), "target_bytes": spec.target_bytes,
                     "step_bytes": spec.step_bytes, "probe_bytes": list(spec.probe_bytes),
                     "fact_count": spec.fact_count, "conversations": args.conversations,
                     "interleave": spec.interleave}})
    alive = _replay_all(run, args, spec, corpus, model, seeds, sent)
    summary = replay_summary(run, corpus_was_reused(corpus, spec.target_bytes),
                             None if alive else "server died")
    run.snapshot("end")
    run.close(summary)
    print(f"results: {run.path}")
    return 0 if alive else 1


def _replay_all(
    run: Run, args: argparse.Namespace, spec: ReplaySpec, corpus: Corpus, model: str,
    seeds: list[int], sent: bool,
) -> bool:
    for seed in seeds:
        streams = [replay_requests(spec, corpus, model, seed, c, sent)
                   for c in range(args.conversations)]
        with ThreadPoolExecutor(args.conversations) as pool:
            alive = list(pool.map(lambda s: _replay_conversation(run, args, s, seed), streams))
        if not all(alive):
            return False
    return True


def fail(run: Run, reason: str) -> int:
    """Partial results stay on disk and the exit status says it failed."""
    run.add_request({"kind": "run_error", "error": reason, "started": time.time(),
                     "ended": time.time()})
    run.close({"stopped": reason, "memory": run.memory_summary()})
    print(f"failed: {reason}\nresults: {run.path}")
    return 1


def _soak_worker(
    run: Run, args: argparse.Namespace, requests: Iterator[Planned], lock: threading.Lock,
    deadline: float, seed: int, dead: threading.Event,
) -> None:
    while time.monotonic() < deadline and not dead.is_set():
        with lock:
            planned = next(requests)
        reply = post_chat(args.base_url, args.api_key, planned.body, args.request_timeout)
        run.add_request(annotate(planned, seed, reply))
        if reply.dead:
            dead.set()
        elif reply.error:
            time.sleep(1)  # an instant refusal must not become a hot loop


def run_soak(args: argparse.Namespace) -> int:
    run = open_run(args)
    snapshot = run.snapshot("start")
    model = discover_model(args, snapshot)
    seed = args.seeds[0]
    if model is None:
        return fail(run, f"no model: {snapshot['models'].get('error')}")
    corpus = load_corpus(REPO, args.corpus_rev)
    probe = probe_seed(run, args, model, seed)
    if probe.dead:
        return fail(run, f"server unreachable: {probe.error}")
    sent = probe.status == 200
    spec = SoakSpec(token_worth(args.short_tokens), token_worth(args.long_tokens),
                    args.long_every, sampling_of(args))
    run.write_json("manifest.json", {"model": model, "base_url": args.base_url, "workload": {
        **base_workload(args, corpus, [seed], sent), "short_bytes": spec.short_bytes,
        "long_bytes": spec.long_bytes, "long_every": spec.long_every, "streams": args.streams,
        "duration_s": args.duration}})
    requests = soak_requests(spec, corpus, model, seed, sent)
    lock, dead = threading.Lock(), threading.Event()
    deadline = time.monotonic() + args.duration
    with ThreadPoolExecutor(args.streams) as pool:
        for _ in range(args.streams):
            pool.submit(_soak_worker, run, args, requests, lock, deadline, seed, dead)
    memory = run.memory_summary()
    run.snapshot("end")
    run.close({"stopped": "server died" if dead.is_set() else None, "memory": memory,
               "per_minute": per_minute(run.records), "requests": request_rows(run.records),
               "clean": not dead.is_set()})
    print(f"results: {run.path}")
    return 1 if dead.is_set() else 0


def task_prefix(corpus: Corpus, seed: int, brief: str, prefix_bytes: int) -> tuple[ScriptedHistory, str]:
    """The early rules go first, then the D-A1 prefix, so they sit deep in the context."""
    salt = salt_for(seed, "task")
    messages = opening(salt)
    messages[1] = {"role": "user", "content": brief}
    history = ScriptedHistory(corpus, seed, "task", messages=messages)
    history.grow_to(prefix_bytes)
    return history, salt

