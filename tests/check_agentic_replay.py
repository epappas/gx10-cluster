#!/usr/bin/env python3
"""agentic-replay, exercised without a model server.

No stub inference server exists here, by rule. Workload, scoring, file tools and
compare are real code on real inputs. The two streams below are hand-written
samples that test the parser only; they are not evidence about any server.

Docker and sshd sections run for real where they can, and print NOT PROVEN where
they cannot. A section that did not run never counts as a pass.

    python3 tests/check_agentic_replay.py
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOL_DIR = REPO / "workspaces" / "bench" / "agentic-replay"
sys.path.insert(0, str(TOOL_DIR))

from agentic_replay import (compare, fstools, modes, recall, sampler, sandbox,  # noqa: E402
                            task_mode, tooldefs)
from agentic_replay.client import Reply, parse_stream  # noqa: E402
from agentic_replay.core import Sampling, render_body, token_worth  # noqa: E402
from agentic_replay.corpus import CorpusError, iter_pieces, load_corpus  # noqa: E402
from agentic_replay.results import Run  # noqa: E402
from agentic_replay.workload import (ReplaySpec, SoakSpec, replay_requests,  # noqa: E402
                                     soak_requests)

CLI = TOOL_DIR / "agentic-replay"
SAMPLING = Sampling(0.0, 1.0, 40, 64)
not_proven: list[str] = []

# Hand-written. Parser test only.
SAMPLE_A = [
    b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n',
    b'data: {"choices":[{"delta":{"reasoning_content":"think"}}]}\n',
    b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":'
    b'{"name":"read_file","arguments":"{\\"pa"}}]}}]}\n',
    b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":'
    b'{"arguments":"th\\":\\"a\\"}"}}]},"finish_reason":"tool_calls"}]}\n',
    b'data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":4,'
    b'"prompt_tokens_details":{"cached_tokens":3}}}\n',
    b"data: [DONE]\n",
]
SAMPLE_B = [
    b'data: {"choices":[{"delta":{"content":"other words"},"finish_reason":"stop"}]}\n',
    b'data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}\n',
    b"data: [DONE]\n",
]


def parsed(lines: list[bytes]) -> Reply:
    ticks = iter(range(1, 100))
    reply = Reply(started=0.0)
    assert parse_stream(lines, reply, lambda: float(next(ticks)))
    return reply


def spec() -> ReplaySpec:
    size = token_worth(4000)
    return ReplaySpec(size * 3, size, (size * 2,), 3, SAMPLING, interleave=True,
                      response_format=True, sampling_check=True)


def bodies(corpus, model: str, seed: int) -> list[bytes]:
    return [p.body for p in replay_requests(spec(), corpus, model, seed, 0, True)]


def without_model(body: bytes) -> dict:
    doc = json.loads(body)
    doc.pop("model")
    return doc


def check_ac1(corpus) -> None:
    a, b = bodies(corpus, "model-a", 11), bodies(corpus, "model-b", 11)
    assert len(a) == len(b) > 8
    assert [without_model(x) for x in a] == [without_model(x) for x in b]
    assert a == bodies(corpus, "model-a", 11), "same inputs must give the same bytes"
    assert a != bodies(corpus, "model-a", 12), "a different seed must change the bodies"
    with_a, with_b = [], []
    for sample, out in ((SAMPLE_A, with_a), (SAMPLE_B, with_b)):
        for planned in replay_requests(spec(), corpus, "m", 11, 0, True):
            out.append(planned.body)
            modes.annotate(planned, 11, parsed(sample))
    assert with_a == with_b, "a recorded reply reached a later request"
    doc = json.loads(a[0])
    assert doc["messages"][0]["content"].startswith("session "), "the salt must come first"
    for key in ("temperature", "top_p", "top_k", "max_tokens"):
        assert key in doc, key
    assert not {k for k in doc if "reasoning" in k or "thinking" in k}


def check_corpus(corpus) -> None:
    paths = {f.path for f in corpus.files}
    assert not [p for p in paths if p.startswith("workspaces/bench/agentic-replay/")]
    assert all("\0" not in f.text for f in corpus.files)
    assert load_corpus(REPO, corpus.rev).digest == corpus.digest
    try:
        load_corpus(REPO, "no-such-revision")
    except CorpusError:
        pass
    else:
        raise AssertionError("a bad revision must refuse")
    needed = corpus.size_bytes + 1
    grown, reused = 0, False
    for piece in iter_pieces(corpus, 5, 65536):
        grown += len(piece.text.encode())
        reused = piece.reused
        if grown > needed:
            break
    assert reused, "reuse past the corpus size must be reported"


def tool_call(name: str, arguments: str) -> dict:
    return {"id": "c", "type": "function", "function": {"name": name, "arguments": arguments}}


def check_ac2() -> None:
    tools = tooldefs.TOOLS
    assert tooldefs.check_call(tool_call("read_file", '{"path":"a"}'), tools).valid
    cases = {
        "truncated_json": tool_call("read_file", '{"path":"a'),
        "unknown_tool": tool_call("rm_rf", '{"path":"a"}'),
        "missing_argument": tool_call("write_file", '{"path":"a"}'),
        "wrong_type": tool_call("read_file", '{"path":1}'),
    }
    for reason, call in cases.items():
        verdict = tooldefs.check_call(call, tools)
        assert not verdict.valid and verdict.reason == reason, (reason, verdict)
    assert not tooldefs.check_call(tool_call("read_file", '{"path":"a","offset":true}'), tools).valid
    hostile = {"unparseable_arguments": [
        '{"path":"a","offset":' + "9" * 5000 + "}", "[" * 200000]}
    for reason, payloads in hostile.items():
        for payload in payloads:
            assert tooldefs.check_call(tool_call("read_file", payload), tools).reason == reason
    assert tooldefs.check_call(tool_call("run_tests", ""), tools).valid, "empty means no arguments"
    assert tooldefs.check_call(tool_call("read_file", ""), tools).reason == "truncated_json"
    started = time.monotonic()
    assert not tooldefs.syntax_in_content("<" + " " * 160000 + "x")
    assert time.monotonic() - started < 1, "the syntax scan must stay linear on model content"
    leaked = tooldefs.check_reply([], '<tool_call>{"name":"read_file"}</tool_call>', tools)
    assert [v.reason for v in leaked] == ["syntax_in_content"]
    assert tooldefs.check_reply([], "Done, all tests pass.", tools) == []


def apply_reference(project: Path) -> None:
    shutil.copytree(task_mode.FIXTURE / "reference", project, dirs_exist_ok=True)


def host_hidden(root: Path, module: str) -> subprocess.CompletedProcess[str]:
    """The fixture is repo code. Only the fixture runs on the host, never model output."""
    return subprocess.run(
        [sys.executable, "-B", "-m", "unittest", "discover", "-s", "hidden", "-p", module, "-t", "."],
        cwd=root, capture_output=True, text=True, timeout=120)


def check_ac3() -> int:
    fixture = task_mode.load_fixture()
    assert len(fixture.tasks) >= 6
    assert sum(1 for t in fixture.tasks if t["early_constraints"]) >= 3
    with tempfile.TemporaryDirectory() as tmp:
        plain, solved = Path(tmp, "plain"), Path(tmp, "solved")
        task_mode.prepare_scratch(plain)
        task_mode.prepare_scratch(solved)
        apply_reference(solved)
        for root in (plain, solved):
            shutil.copytree(task_mode.FIXTURE / "hidden", root / "hidden")
        for task in fixture.tasks:
            bad = host_hidden(plain, task["hidden"])
            assert bad.returncode != 0, f"{task['hidden']} passes on the unmodified fixture"
            good = host_hidden(solved, task["hidden"])
            assert good.returncode == 0, good.stderr[-800:]
            assert f"Ran {task['expected_tests']} test" in good.stderr, good.stderr[-300:]
            assert "skipped" not in good.stderr
    return len(fixture.tasks)


def check_reference_stays_private() -> None:
    fixture = task_mode.load_fixture()
    reference = {p.read_bytes() for p in (fixture.root / "reference").rglob("*.py") if p.stat().st_size}
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp, "s")
        task_mode.prepare_scratch(scratch)
        names = {p.relative_to(scratch).parts[0] for p in scratch.rglob("*")}
        assert "hidden" not in names and "reference" not in names
        seen = {p.read_bytes() for p in scratch.rglob("*.py")}
    assert not (reference - {b""}) & seen, "a reference file reached scratch"
    assert all(t["hidden"] not in fixture.brief for t in fixture.tasks)


def tools_on(scratch: Path, path: str) -> dict:
    return {
        "read_file": lambda: fstools.read_file(scratch, path),
        "write_file": lambda: fstools.write_file(scratch, path, "x"),
        "list_dir": lambda: fstools.list_dir(scratch, path),
        "grep": lambda: fstools.grep(scratch, "secret", path),
    }


def assert_refused(scratch: Path, path: str) -> None:
    for name, call in tools_on(scratch, path).items():
        try:
            result = call()
        except fstools.ToolError:
            continue
        raise AssertionError(f"{name} on {path!r} returned {result!r}")


def assert_hostile_arguments_stay_tool_errors(scratch: Path) -> None:
    """Values a model can send that once raised past the tools."""
    verdict = tooldefs.CallVerdict
    calls = [
        ("write_file", {"path": "pipe/under-a-fifo", "content": "x"}),
        ("write_file", {"path": "lone.txt", "content": "\ud83d"}),
        ("read_file", {"path": "\ud83d"}),
        ("read_file", {"path": "x" * 5000}),
        ("write_file", {"path": "/".join(["d"] * 1100) + "/f", "content": "x"}),
    ]
    for name, arguments in calls:
        result = task_mode.execute(verdict(True, "ok", name, arguments), scratch)
        assert result.startswith("tool error"), (name, result)
    assert fstools.read_file(scratch, "pkg/a.txt", 1 << 70) == "", "a huge offset must read nothing"
    json.loads(render_lone_surrogate())


def render_lone_surrogate() -> bytes:
    message = {"role": "assistant", "content": "\ud83d"}
    return render_body("m", [message], SAMPLING, None)


def check_ac5() -> None:
    with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as outside:
        scratch = Path(tmp)
        secret = Path(outside, "secret.txt")
        secret.write_text("secret\n")
        Path(outside, "dir").mkdir()
        (scratch / "pkg").mkdir()
        (scratch / "pkg" / "a.txt").write_text("secret here\n")
        os.symlink(secret, scratch / "file_link")
        os.symlink(outside, scratch / "dir_link")
        os.mkfifo(scratch / "pipe")
        for path in ("../" + secret.name, "pkg/../../x", str(secret), "file_link",
                     "dir_link", "dir_link/secret.txt", "pipe"):
            assert_refused(scratch, path)
        assert secret.read_text() == "secret\n", "a tool wrote through a link"
        assert fstools.read_file(scratch, "pkg/a.txt") == "secret here\n"
        assert "a.txt" in fstools.list_dir(scratch, "pkg")
        assert "pkg/a.txt:1:secret here" in fstools.grep(scratch, "secret", "pkg")
        assert "wrote" in fstools.write_file(scratch, "pkg/new/b.txt", "hello")
        assert (scratch / "pkg/new/b.txt").read_text() == "hello"
        assert_hostile_arguments_stay_tool_errors(scratch)
        for n in range(fstools.MAX_LIST_ENTRIES + 5):
            (scratch / "pkg" / f"n{n}").touch()
        assert "[truncated: 7 more entries]" in fstools.list_dir(scratch, "pkg")
        for n in range(fstools.MAX_LIST_ENTRIES + 5):
            (scratch / "pkg" / f"n{n}").unlink()
        assert "[truncated at 10 bytes]" in fstools.cap_text("y" * 50, 10)
        whole = fstools.grep(scratch, "secret", ".")
        assert "outside" not in whole and whole.count("\n") == 0, whole
        try:
            fstools.write_file(scratch, "big", "x" * (fstools.MAX_WRITE_BYTES + 1))
        except fstools.ToolError:
            pass
        else:
            raise AssertionError("size limit not applied")


def write_run(root: Path, name: str, cached: int | None, digest: str) -> Path:
    path = root / name
    path.mkdir()
    workload = {"corpus_hash": digest, "seeds": [1], "sampling": {"temperature": 0.0}}
    row = {"kind": "step", "seed": 1, "conv": 0, "step": 1, "prompt_tokens": 100,
           "cached_tokens": cached, "ttft_s": 1.5, "decode_tps": None, "finish_reason": "stop"}
    (path / "manifest.json").write_text(json.dumps({"model": name, "workload": workload}))
    (path / "summary.json").write_text(json.dumps({"requests": [row], "memory": {"sampler": "not run"}}))
    (path / "snapshot-start.json").write_text(json.dumps({"models": {"body": {"max_model_len": 524288}}}))
    return path


def check_ac6() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        a = compare.load_result(write_run(root, "a", 80, "same"))
        b = compare.load_result(write_run(root, "b", None, "same"))
        compare.refuse_mismatch(a, b)
        table = compare.render(a, b)
        line = next(x for x in table.splitlines() if "cached_tokens" in x)
        assert line.split()[-2:] == ["80", "missing"], line
        assert "decode_tps" in table and " 0.00" not in table
        assert "max_model_len=524288" in table
        other = compare.load_result(write_run(root, "c", 80, "different"))
        try:
            compare.refuse_mismatch(a, other)
        except compare.CompareRefused as exc:
            assert "corpus_hash" in str(exc)
        else:
            raise AssertionError("a corpus mismatch must refuse")
        out = subprocess.run([sys.executable, "-B", str(CLI), "compare", str(a.path), str(other.path)],
                             capture_output=True, text=True)
        assert out.returncode == 2 and "refused" in out.stdout, out.stdout


def check_ac7() -> None:
    facts = recall.make_facts(7, 1000, 3)
    probes = recall.probes_at(1000, facts)
    single = probes[0]
    other = facts[1].code
    wrong = "9999-WRONG"
    combo = next(p for p in probes if p.kind == "combo")
    absent = next(p for p in probes if p.kind == "absent")
    assert recall.score(single, single.expected) == 1
    assert recall.score(single, wrong) == 0
    assert recall.score(single, f"Sure! The code you want is {single.expected}, as noted.") == 1
    assert recall.score(single, f"{single.expected} or maybe {wrong}") == 0
    assert recall.score(single, other) == 0
    assert recall.score(absent, "NOT PRESENT") == 1
    assert recall.score(absent, f"It is {other}") == 0
    assert recall.score(absent, "The code is purple") == 0
    assert recall.score(combo, combo.expected) == 1
    assert recall.score(combo, f"{combo.allowed[0]} + {combo.allowed[1]} = {combo.expected}") == 1
    assert recall.score(combo, f"{combo.expected} or 1") == 0
    assert recall.score(combo, "1") == 0
    assert recall.score(combo, f"The 2 depots hold {combo.expected} crates in total.") == 1
    assert recall.score(combo, f"1. first depot\n2. second depot\nTotal {combo.expected}") == 1
    assert recall.score(combo, f"{combo.expected}.0") == 1
    assert recall.score(absent, "7712 CORAL, though not found elsewhere") == 0
    assert recall.score(absent, "There is no bittern depot in the audit notes.") == 1
    assert recall.make_facts(7, 1000, 3) == facts and recall.make_facts(8, 1000, 3) != facts


def variant(name: str, text: str, error: str | None = None) -> dict:
    return {"variant": name, "content": text, "error": error, "completion_tokens": 32}


def check_sampling_verdict() -> None:
    """A failed variant once read as honoured: its empty text differed from greedy."""
    failed = [variant("greedy", "aa"), variant("hot", "", "server error"),
              variant("hot_top_k_1", "aa"), variant("hot_top_p_tiny", "", "server error")]
    verdict = modes.sampling_verdict(failed)
    assert (verdict["temperature"], verdict["top_k"], verdict["top_p"]) == ("not shown",) * 3
    assert verdict["errors"]["hot"] == "server error"
    good = [variant("greedy", "aa"), variant("hot", "bb"), variant("hot_top_k_1", "aa"),
            variant("hot_top_p_tiny", "aa")]
    verdict = modes.sampling_verdict(good)
    assert (verdict["temperature"], verdict["top_k"], verdict["top_p"]) == ("honoured",) * 3
    ignored = [variant("greedy", "aa"), variant("hot", "bb"), variant("hot_top_k_1", "cc"),
               variant("hot_top_p_tiny", "dd")]
    verdict = modes.sampling_verdict(ignored)
    assert (verdict["top_k"], verdict["top_p"]) == ("not shown", "not shown")


def check_probe_score_labels() -> None:
    probe = recall.probes_at(1000, recall.make_facts(7, 1000, 1))[-1]
    assert modes.probe_score(probe, Reply(finish_reason="length")) == "budget"
    called = Reply(tool_calls=[tool_call("grep", '{"pattern":"x"}')], finish_reason="tool_calls")
    assert modes.probe_score(probe, called) == "tool_call"
    assert modes.probe_score(probe, Reply(content="NOT PRESENT", finish_reason="stop")) == 1
    assert compare._recall_cell([1, 0, "tool_call", "budget"]) == "1/2 budget 1 tool_call 1"


def check_failures_are_reported() -> None:
    """Hand-built replies and records: pure reporting logic, no server involved."""
    probe = recall.probes_at(1000, recall.make_facts(7, 1000, 1))[-1]
    assert modes.probe_score(probe, Reply(status=500, error="boom")) == "error"
    assert modes.probe_score(probe, Reply(error="reset", dead=True)) == "error"
    assert compare._recall_cell(["error", 1]) == "1/1 error 1"
    assert not Reply(status=200, error="refused inside the stream").ok
    assert Reply(status=200).ok and not Reply(status=400).ok
    planned = next(p for p in replay_requests(spec(), load_corpus(REPO, "HEAD"), "m", 11, 0, True)
                   if p.kind == "response_format")
    refused = modes.annotate(planned, 11, Reply(status=200, error="no"))
    assert refused["response_format"] == "refused", "an error chunk at 200 is not served"
    records = [{"kind": "seed_probe", "error": "x"}, {"kind": "sampling", "error": "x"},
               {"kind": "step", "error": None}]
    assert modes.request_errors(records) == 0, "probes exist to be refused"
    assert modes.request_errors([*records, {"kind": "short", "error": "HTTP 500"}]) == 1
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(Path(tmp), "http://127.0.0.1:1/v1", "")
        run.add_request({"kind": "short", "error": "HTTP 500", "started": 1.0, "ended": 2.0})
        assert modes._finish_soak(run, False, []) == 1, "every request failed and it exited 0"
        summary = json.loads(Path(tmp, "summary.json").read_text())
        assert summary["clean"] is False and summary["request_errors"] == 1


def check_task_bounds() -> None:
    """Real code on a real scratch. The Reply is hand-built and no request is sent."""
    fixture = task_mode.load_fixture()
    with tempfile.TemporaryDirectory() as tmp:
        scratch, run_dir = Path(tmp, "s"), Path(tmp, "r")
        run_dir.mkdir()
        task_mode.prepare_scratch(scratch)
        run = Run(run_dir, "http://127.0.0.1:1/v1", "")
        args = argparse.Namespace(max_turns=5)
        session = task_mode.Session(args, run, "m", 1, None, scratch, "s", [], 0,
                                    time.monotonic() + 60)
        calls = [tool_call("read_file", '{"path":"ledger/money.py"}') for _ in range(400)]
        tally = {"repeated": 0, "invalid": 0, "refused": 0}
        task_mode._answer_calls(session, Reply(tool_calls=calls), set(), tally)
        assert len(session.messages) == 400, "every call needs an answer"
        assert tally["refused"] >= 400 - task_mode.MAX_CALLS_PER_REPLY
        size = len(json.dumps(session.messages))
        assert size < task_mode.MAX_RESULT_BYTES_PER_REPLY + 400 * 200, size
        session.messages.clear()
        session.deadline = time.monotonic() - 1
        session.results.clear()
        task_mode._run_tasks(session, fixture, fixture.tasks)
        table = task_mode.task_table(fixture, session.results)
        assert session.stopped == "hard timeout"
        assert [row["status"] for row in table] == ["missing"] * len(fixture.tasks)
        assert all(row["status_at_end"] == "missing" for row in table)


def check_compare_covers_the_workload() -> None:
    assert len(modes.code_digest()) == 64
    source = (TOOL_DIR / "agentic_replay" / "modes.py").read_text()
    for key in ('"response_format": spec.response_format', '"sampling_check": spec.sampling_check',
                '"code_sha": code_digest()'):
        assert key in source, key
    with tempfile.TemporaryDirectory() as tmp:
        done = subprocess.run(
            [sys.executable, "-B", str(CLI), "replay", "--corpus-rev", "HEAD",
             "--target-tokens", "20000", "--results-root", tmp],
            capture_output=True, text=True, timeout=30)
        assert done.returncode == 2 and "grow past" in done.stdout, done.stdout
        assert not list(Path(tmp).iterdir()), "a refused run must touch nothing"


def check_soak_salts(corpus) -> None:
    soak = SoakSpec(token_worth(100), token_worth(200), 3, SAMPLING)
    def first(seed: int) -> list:
        stream = soak_requests(soak, corpus, "m", seed, False)
        return [next(stream) for _ in range(30)]
    one, again = first(5), first(5)
    salts = [p.salt for p in one]
    assert len(set(salts)) == 30, "soak salts must be distinct"
    assert [p.body for p in one] == [p.body for p in again]
    assert salts != [p.salt for p in first(6)]
    assert [p.kind for p in one[:3]] == ["short", "short", "long"]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def check_closed_port() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        url = f"http://127.0.0.1:{free_port()}/v1"
        runs = {"replay": ["--target-tokens", "1000", "--step-tokens", "1000", "--probe-tokens", ""],
                "soak": ["--duration", "2"]}
        for mode, extra in runs.items():
            done = subprocess.run(
                [sys.executable, "-B", str(CLI), mode, "--corpus-rev", "HEAD", "--base-url", url,
                 "--model", "m", "--label", mode, "--results-root", tmp, *extra],
                capture_output=True, text=True, timeout=60)
            assert done.returncode != 0, (mode, done.stdout, done.stderr)
            run = next(Path(tmp).glob(f"{mode}-*"))
            lines = (run / "requests.jsonl").read_text().splitlines()
            assert lines and any(json.loads(x).get("error") for x in lines), mode
            assert "error" in (run / "snapshot-start.json").read_text()
            assert (run / "summary.json").exists()


def check_parser() -> None:
    reply = parsed(SAMPLE_A)
    assert reply.reasoning == {"reasoning_content": "think"} and reply.content is None
    assert json.loads(reply.tool_calls[0]["function"]["arguments"]) == {"path": "a"}
    assert (reply.prompt_tokens, reply.cached_tokens, reply.completion_tokens) == (9, 3, 4)
    assert reply.first == 1.0 + 1 and reply.decode_tps is not None
    broken = Reply()
    parse_stream([b'data: [1, 2]\n', b'data: {"choices":[{"delta":{"tool_calls":'
                  b'[{"index":null}]}}]}\n', b"data: [DONE]\n"], broken, lambda: 1.0)
    assert broken.error and "malformed chunk" in broken.error
    message = reply.assistant_message()
    assert message["reasoning_content"] == "think" and message["tool_calls"] == reply.tool_calls
    assert parsed(SAMPLE_B).cached_tokens is None, "absent must stay absent, not 0"
    burst = Reply(first=10.0, last=10.0005, completion_tokens=75)
    assert burst.decode_tps is None, "a burst has no decode rate"
    assert Reply(first=10.0, last=11.0, completion_tokens=75).decode_tps == 75.0
    assert Reply(finish_reason="length").budget_stop and not Reply(finish_reason="stop").budget_stop


def docker_ready() -> str | None:
    if socket.gethostname() != sandbox.ALLOWED_HOST:
        return f"host is {socket.gethostname()}, sandbox runs on {sandbox.ALLOWED_HOST} only"
    if shutil.which("docker") is None:
        return "docker is absent"
    if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
        return "docker is not usable"
    if subprocess.run(["docker", "image", "inspect", sandbox.IMAGE], capture_output=True).returncode:
        return f"image not pulled: {sandbox.IMAGE}"
    return None


KILLED_TOOL = """
import sys
sys.path.insert(0, {tool!r})
from pathlib import Path
from agentic_replay import sandbox
def announce(proc):
    print(proc.args[-1], flush=True)
sandbox.run_sandboxed(Path({scratch!r}), "python probe.py", sandbox.Limits(seconds=8), announce)
"""


def check_sweep() -> None:
    """A created container is what a killed tool leaves. Young ones are left alone."""
    name = f"agentic-replay-sweeptest-{os.getpid()}"
    subprocess.run(["docker", "create", "--name", name, sandbox.IMAGE, "true"],
                   check=True, capture_output=True)
    try:
        assert name not in sandbox.sweep_stale(), "a fresh container must survive the sweep"
        assert name in sandbox.sweep_stale(max_age_s=0), "a stale container must go"
        assert not sandbox._exists(name)
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def check_exists_fails_closed() -> None:
    saved = os.environ.get("DOCKER_HOST")
    os.environ["DOCKER_HOST"] = "unix:///nonexistent/docker.sock"
    try:
        sandbox._exists("anything")
    except subprocess.CalledProcessError:
        return
    finally:
        os.environ.pop("DOCKER_HOST")
        if saved:
            os.environ["DOCKER_HOST"] = saved
    raise AssertionError("an unreachable daemon read as a container that has gone")


def is_running(name: str) -> bool:
    """Running, not merely created: a created container has nothing to outlive the tool."""
    done = subprocess.run(["docker", "ps", "-q", "--filter", f"name=^{name}$", "--filter",
                           "status=running"], capture_output=True, text=True, timeout=30, check=True)
    return bool(done.stdout.strip())


def check_tool_killed() -> None:
    """The tool itself dies: the container's own `timeout` must still end it."""
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "probe.py").write_text(sandbox.SLEEP_PROBE)
        code = KILLED_TOOL.format(tool=str(TOOL_DIR), scratch=tmp)
        tool = subprocess.Popen([sys.executable, "-B", "-c", code], stdout=subprocess.PIPE,
                                text=True, start_new_session=True)
        assert tool.stdout is not None
        name = tool.stdout.readline().strip()
        assert name, "the run never started"
        assert wait_for(lambda: is_running(name), 30), "the container never started"
        os.killpg(tool.pid, signal.SIGKILL)
        tool.wait()
        assert wait_for(lambda: not sandbox._exists(name), 30), "container outlived the killed tool"


def check_reference_in_sandbox() -> None:
    fixture = task_mode.load_fixture()
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp, "s")
        task_mode.prepare_scratch(scratch)
        first = fixture.tasks[0]
        plain = sandbox.run_hidden(scratch, fixture.root / "hidden", fixture.allowlist, first["hidden"])
        assert not sandbox.hidden_passed(plain, first["expected_tests"])
        apply_reference(scratch)
        for task in fixture.tasks:
            result = sandbox.run_hidden(scratch, fixture.root / "hidden", fixture.allowlist,
                                        task["hidden"])
            assert sandbox.hidden_passed(result, task["expected_tests"]), result.output[-600:]


def check_ac4() -> str:
    reason = docker_ready()
    if reason:
        not_proven.append(f"AC4 sandbox: {reason}")
        return "AC4 NOT PROVEN"
    failed = [p for p in sandbox.containment_probes() if not p.ok]
    assert not failed, failed
    check_sweep()
    check_exists_fails_closed()
    check_tool_killed()
    check_reference_in_sandbox()
    return "AC4 containment held on live docker"


SSHD_CONFIG = """Port {port}
ListenAddress 127.0.0.1
HostKey {tmp}/host_key
PidFile {tmp}/sshd.pid
AuthorizedKeysFile {tmp}/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
"""
SSH_CONFIG = """Host loopback-node
  HostName 127.0.0.1
  Port {port}
  User {user}
  IdentityFile {tmp}/client_key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
"""
SAMPLER_CLIENT = """
import sys, time
sys.path.insert(0, {tool!r})
from agentic_replay.sampler import Sampler
Sampler(["loopback-node"], {log!r}, {config!r}, lambda s: print(s, flush=True))
time.sleep(600)
"""


def remote_alive(marker: str) -> list[str]:
    alive = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes()
        except OSError:
            continue
        if marker.encode() in cmdline and b"while :" in cmdline and b"ssh\0" not in cmdline:
            alive.append(entry.name)
    return alive


def start_sshd(tmp: str) -> tuple[subprocess.Popen[bytes], int]:
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    for key in ("host_key", "client_key"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", f"{tmp}/{key}"], check=True)
    shutil.copy(f"{tmp}/client_key.pub", f"{tmp}/authorized_keys")
    port = free_port()
    Path(tmp, "sshd_config").write_text(SSHD_CONFIG.format(port=port, tmp=tmp))
    process = subprocess.Popen([sshd, "-D", "-e", "-f", f"{tmp}/sshd_config"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return process, port


def wait_for(condition, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return condition()


def exercise_sampler(tmp: str, config: str) -> None:
    log = Path(tmp, "guard.log")
    log.write_text("old: killed container before this run\n")
    code = SAMPLER_CLIENT.format(tool=str(TOOL_DIR), log=str(log), config=config)
    out = Path(tmp, "client.out")
    with out.open("w") as sink:
        client = subprocess.Popen([sys.executable, "-B", "-c", code], stdout=sink, text=True,
                                  stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        assert wait_for(lambda: "available_kib" in out.read_text(), 15), "no samples arrived"
        assert remote_alive(str(log)), "remote sampler not found"
        with log.open("a") as guard:
            guard.write("memguard: killed container x\nrecovered: no kill\n")
        assert wait_for(lambda: "recovered" in out.read_text(), 10), "guard lines did not arrive"
        text = out.read_text()
        assert "'kill': True" in text and "'kill': False" in text and "old:" not in text
        os.killpg(client.pid, signal.SIGKILL)
        client.wait()
        assert wait_for(lambda: not remote_alive(str(log)), 5), "remote sampler outlived the client"
    finally:
        if client.poll() is None:
            os.killpg(client.pid, signal.SIGKILL)


def check_ac8() -> str:
    if not shutil.which("ssh") or not shutil.which("ssh-keygen") or not (
            shutil.which("sshd") or Path("/usr/sbin/sshd").exists()):
        not_proven.append("AC8 sampler: sshd or ssh is unavailable")
        return "AC8 NOT PROVEN"
    with tempfile.TemporaryDirectory() as tmp:
        process, port = start_sshd(tmp)
        try:
            config = Path(tmp, "ssh_config")
            config.write_text(SSH_CONFIG.format(port=port, user=os.environ.get("USER") or
                                                subprocess.getoutput("id -un"), tmp=tmp))
            config.chmod(0o600)
            exercise_sampler(tmp, str(config))
        finally:
            process.terminate()
            process.wait(10)
    return "AC8 remote sampler ended within 5 s of the client dying"


def check_sampler_logic() -> None:
    args = sampler.ssh_argv("n", "/x y/log", None)
    assert "BatchMode=yes" in args and "/x y/log" in args[-1]
    for word in (">", "tee", "rm ", "mkdir"):
        assert word not in sampler.remote_script(None), f"remote script writes: {word}"
    sample = [{"node": "n", "t": 1.0, "available_kib": 5}, {"node": "n", "t": 2.0, "available_kib": 3}]
    summary = sampler.summarise_memory(sample, ["n"], None)
    assert summary["n"]["guard"] == "no guard log" and summary["n"]["low_kib"] == 3
    logged = sampler.summarise_memory(sample, ["n"], "/log")
    assert logged["n"]["guard"] == {"kill_lines": []}
    assert sampler.low_in_window(sample, sampler.Window(1.5, 2.5)) == {"n": 3}
    assert sampler.parse_line("n", "G recovered: no kill\n", 0.0)["kill"] is False


def main() -> int:
    corpus = load_corpus(REPO, "HEAD")
    check_ac1(corpus)
    check_corpus(corpus)
    check_ac2()
    tasks = check_ac3()
    check_reference_stays_private()
    check_ac5()
    check_ac6()
    check_ac7()
    check_sampling_verdict()
    check_failures_are_reported()
    check_task_bounds()
    check_compare_covers_the_workload()
    check_probe_score_labels()
    check_soak_salts(corpus)
    check_closed_port()
    check_parser()
    check_sampler_logic()
    ac4 = check_ac4()
    ac8 = check_ac8()
    print(f"agentic-replay: workload, validator, {tasks} fixture tasks, file tools, compare, "
          f"scorer, salts and dead-server runs hold; {ac4}; {ac8}")
    for line in not_proven:
        print(f"agentic-replay: NOT PROVEN - {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
