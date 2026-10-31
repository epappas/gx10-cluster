"""task: one long conversation over the fixture, scored by hidden tests.

Here model output and tool results do enter later requests. The task list,
system prompt, fixture, sampling and budgets stay identical across models.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import fstools, sandbox
from .client import Reply, post_chat
from .core import canonical_bytes, render_body, token_worth
from .corpus import Corpus, load_corpus
from .modes import (REPO, annotate, base_workload, discover_model, fail, open_run, probe_seed,
                    sampling_of, task_prefix)
from .results import Run, request_rows
from .tooldefs import TOOLS, CallVerdict, check_call, syntax_in_content
from .workload import Planned

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "ledger"
NUDGE = "Continue with the task. Call tools through the API, not in plain text."
# --max-turns and the request size mean nothing unless one reply is bounded too.
MAX_CALLS_PER_REPLY = 16
MAX_RESULT_BYTES_PER_REPLY = 128 * 1024


class SandboxFailure(Exception):
    """The sandbox itself failed. Never a test result."""


@dataclass(frozen=True)
class Fixture:
    root: Path
    brief: str
    allowlist: list[str]
    tasks: list[dict[str, Any]]


def load_fixture(root: Path = FIXTURE) -> Fixture:
    spec = json.loads((root / "tasks.json").read_text())
    return Fixture(root, spec["brief"], spec["source_allowlist"], spec["tasks"])


def fixture_digest(root: Path = FIXTURE) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts):
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def prepare_scratch(dest: Path, root: Path = FIXTURE) -> None:
    """project/ only. Hidden tests and the reference never enter scratch."""
    shutil.copytree(root / "project", dest, ignore=shutil.ignore_patterns("__pycache__"))


def execute(verdict: CallVerdict, scratch: Path) -> str:
    """Runs one validated call. A refused path comes back as a tool error."""
    args = verdict.arguments or {}
    try:
        if verdict.name == "read_file":
            return fstools.read_file(scratch, args["path"], args.get("offset", 0))
        if verdict.name == "write_file":
            return fstools.write_file(scratch, args["path"], args["content"])
        if verdict.name == "list_dir":
            return fstools.list_dir(scratch, args["path"])
        if verdict.name == "grep":
            return fstools.grep(scratch, args["pattern"], args.get("path", "."))
    except (fstools.ToolError, OSError, ValueError, OverflowError, RecursionError) as exc:
        return f"tool error: {exc}"
    result = sandbox.run_sandboxed(scratch, sandbox.VISIBLE_TESTS)
    if result.sandbox_error:
        raise SandboxFailure(result.sandbox_error)
    note = "\n[run_tests timed out]\n" if result.timed_out else ""
    note = "\n[run_tests killed: memory limit]\n" if result.killed_early else note
    return result.output + note


@dataclass
class Session:
    args: argparse.Namespace
    run: Run
    model: str
    seed: int
    wire_seed: int | None
    scratch: Path
    salt: str
    messages: list[dict[str, Any]]
    grown: int
    deadline: float
    stopped: str | None = None
    turn_no: int = 0
    results: list[dict[str, Any]] = field(default_factory=list)


def _refusal(session: Session, index: int, spent: int) -> str | None:
    if index >= MAX_CALLS_PER_REPLY:
        return "too many calls in one reply"
    if spent >= MAX_RESULT_BYTES_PER_REPLY:
        return "too much tool output in one reply"
    if time.monotonic() >= session.deadline:
        return "hard timeout"
    return None


def _answer_calls(session: Session, reply: Reply, seen: set[str], tally: dict[str, int]) -> None:
    """Every call gets an answer, because the next request must pair them all."""
    spent = 0
    cut = reply.finish_reason == "length"  # a call the budget truncated is not a bad call
    for index, call in enumerate(reply.tool_calls):
        verdict = check_call(call, TOOLS)
        key = canonical_bytes([verdict.name, call.get("function", {}).get("arguments")]).decode()
        tally["repeated"] += 1 if key in seen else 0
        seen.add(key)
        refusal = _refusal(session, index, spent)
        if refusal:
            tally["refused"] += 1
            content = f"tool error: {refusal}"
        elif verdict.valid:
            content = fstools.cap_text(execute(verdict, session.scratch), sandbox.OUTPUT_CAP)
        elif cut:
            tally["budget"] += 1
            content = "tool error: reply was cut at the token budget"
        else:
            tally["invalid"] += 1
            content = f"tool error: invalid call ({verdict.reason})"
        spent += len(content.encode("utf-8", "replace"))
        session.messages.append(
            {"role": "tool", "tool_call_id": call.get("id"), "content": content})


def _turn(session: Session, task_id: int) -> Reply:
    args = session.args
    body = render_body(session.model, session.messages, sampling_of(args), session.wire_seed, TOOLS)
    session.turn_no += 1
    planned = Planned("turn", task_id, session.turn_no, session.grown, session.salt, body)
    remaining = max(1.0, session.deadline - time.monotonic())
    timeout = min(args.request_timeout, remaining)
    reply = post_chat(args.base_url, args.api_key, body, timeout)
    session.run.add_request(annotate(planned, session.seed, reply))
    return reply


def plain_reply_goes_on(reply: Reply, tally: dict[str, int]) -> bool:
    """A reply with no tool call. finish_reason comes first: a length stop is the budget."""
    if reply.finish_reason == "length":
        tally["budget"] += 1
        return True
    if syntax_in_content(reply.content):
        tally["invalid"] += 1
        return True
    return False


def task_status(score: str, stopped: str | None) -> str:
    """A task cut off by a dead server was not failed by the model."""
    return "aborted" if score == "fail" and stopped else score


def _attempt(session: Session, task: dict[str, Any]) -> dict[str, Any]:
    """Limited by turns, not wall time, so speed does not contaminate quality."""
    started = time.monotonic()
    tally = {"turns": 0, "answered": 0, "invalid": 0, "budget": 0, "repeated": 0, "refused": 0}
    seen: set[str] = set()
    prompt_tokens: int | None = None
    session.messages.append({"role": "user", "content": task["prompt"]})
    for _ in range(session.args.max_turns):
        if time.monotonic() >= session.deadline:
            session.stopped = "hard timeout"
            break
        reply = _turn(session, task["id"])
        tally["turns"] += 1
        prompt_tokens = reply.prompt_tokens if reply.prompt_tokens is not None else prompt_tokens
        if reply.error or reply.dead:
            late = time.monotonic() >= session.deadline
            session.stopped = "hard timeout" if late else f"server error: {reply.error}"
            break
        tally["answered"] += 1
        session.messages.append(reply.assistant_message())
        if reply.tool_calls:
            _answer_calls(session, reply, seen, tally)
            continue
        if not plain_reply_goes_on(reply, tally):
            break
        session.messages.append({"role": "user", "content": NUDGE})
    return {"id": task["id"], "title": task["title"], **tally, "prompt_tokens_end": prompt_tokens,
            "wall_s": time.monotonic() - started}


def score_through(session: Session, fixture: Fixture, upto: int) -> dict[int, str]:
    """Hidden tests for task N and reruns of 1 to N-1, each in a fresh container."""
    scores: dict[int, str] = {}
    for task in fixture.tasks[:upto]:
        try:
            result = sandbox.run_hidden(session.scratch, fixture.root / "hidden",
                                        fixture.allowlist, task["hidden"])
        except Exception as exc:  # scoring must never take the run and its results down
            raise SandboxFailure(f"hidden run failed: {type(exc).__name__}: {exc}") from exc
        if result.sandbox_error:
            raise SandboxFailure(result.sandbox_error)
        passed = sandbox.hidden_passed(result, task["expected_tests"])
        scores[task["id"]] = "pass" if passed else "fail"
    return scores


def scored_attempt(session: Session, fixture: Fixture, number: int, attempt: dict[str, Any]) -> None:
    """Results are written whether scoring worked or not."""
    results = session.results
    task = fixture.tasks[number - 1]
    try:
        scores = score_through(session, fixture, number)
    except SandboxFailure:
        results.append({**attempt, "status": "sandbox_error"})
        session.run.write_json(f"tasks-{session.seed}.json", results)
        raise
    attempt.update(status=task_status(scores[task["id"]], session.stopped), hidden_after=scores)
    results.append(attempt)
    session.run.write_json(f"tasks-{session.seed}.json", results)


def _run_tasks(session: Session, fixture: Fixture, tasks: list[dict[str, Any]]) -> None:
    results = session.results
    for number, task in enumerate(tasks, 1):
        attempt = _attempt(session, task)
        if not attempt["answered"]:  # the model never replied, so nothing was attempted
            results.append({**attempt, "status": "missing"})
            session.run.write_json(f"tasks-{session.seed}.json", results)
            session.stopped = session.stopped or "no reply"
            return
        scored_attempt(session, fixture, number, attempt)
        if session.stopped:
            return


def task_table(fixture: Fixture, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Unattempted tasks are missing, not failed."""
    done = {r["id"]: r for r in results}
    scored = [r["hidden_after"] for r in results if "hidden_after" in r]
    last = scored[-1] if scored else {}
    table = []
    for task in fixture.tasks:
        row = done.get(task["id"], {"id": task["id"], "title": task["title"], "status": "missing"})
        table.append({**row, "status_at_end": last.get(task["id"], "missing"),
                      "early_constraints": task["early_constraints"]})
    return table


def _one_repeat(
    args: argparse.Namespace, run: Run, fixture: Fixture, corpus: Corpus, model: str, seed: int,
    sent: bool, deadline: float,
) -> dict[str, Any]:
    scratch = run.path / f"scratch-{seed}"
    prepare_scratch(scratch)
    history, salt = task_prefix(corpus, seed, fixture.brief, token_worth(args.prefix_tokens))
    session = Session(args, run, model, seed, seed if sent else None, scratch, salt,
                      history.messages, history.grown, deadline)
    tasks = fixture.tasks[:args.task_limit] if args.task_limit else fixture.tasks
    try:
        _run_tasks(session, fixture, tasks)
    except (SandboxFailure, subprocess.SubprocessError) as exc:
        session.stopped = f"sandbox error: {exc}"
    return {"seed": seed, "stopped": session.stopped, "prefix_bytes": history.grown,
            "tasks": task_table(fixture, session.results)}


def refuse_unless_contained() -> str | None:
    try:
        sandbox.require_host()
    except sandbox.SandboxRefused as exc:
        return str(exc)
    failed = [p for p in sandbox.containment_probes() if not p.ok]
    if failed:
        return "containment not proven: " + "; ".join(f"{p.name}: {p.detail}" for p in failed)
    return None


def run_task(args: argparse.Namespace) -> int:
    refusal = refuse_unless_contained()
    if refusal:
        print(f"task refused: {refusal}")
        return 2
    run = open_run(args)
    snapshot = run.snapshot("start")
    model = discover_model(args, snapshot)
    seeds = args.seeds[:args.repeats]
    if model is None:
        return fail(run, f"no model: {snapshot['models'].get('error')}")
    corpus = load_corpus(REPO, args.corpus_rev)
    fixture = load_fixture()
    probe = probe_seed(run, args, model, seeds[0])
    if probe.dead:
        return fail(run, f"server unreachable: {probe.error}")
    sent = probe.ok
    run.write_json("manifest.json", {"model": model, "base_url": args.base_url, "workload": {
        **base_workload(args, corpus, seeds, sent), "fixture_sha": fixture_digest(),
        "prefix_bytes": token_worth(args.prefix_tokens), "max_turns": args.max_turns,
        "task_limit": args.task_limit, "hard_timeout_s": args.hard_timeout}})
    deadline = time.monotonic() + args.hard_timeout
    repeats: list[dict[str, Any]] = []
    for seed in seeds:
        repeats.append(_one_repeat(args, run, fixture, corpus, model, seed, sent, deadline))
        if repeats[-1]["stopped"]:  # unrun repeats stay absent, so compare prints missing
            break
    memory = run.memory_summary()
    run.snapshot("end")
    stopped = next((r["stopped"] for r in repeats if r["stopped"]), None)
    run.close({"stopped": stopped, "memory": memory, "repeats": repeats,
               "requests": request_rows(run.records)})
    print(f"results: {run.path}")
    return 1 if stopped else 0
