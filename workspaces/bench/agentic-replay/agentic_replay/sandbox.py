"""Runs model-written code in a container. Never on the host.

Scratch is mounted read-only and copied to a tmpfs inside, so nothing the
container writes reaches a path the host-side tools read. Time is enforced
twice: `timeout` inside, `docker kill` by name outside, because killing the
docker client leaves the container running.
"""

from __future__ import annotations

import glob
import os
import re
import select
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import fstools

IMAGE = "python@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913"
ALLOWED_HOST = "devbox"
OUTPUT_CAP = 64 * 1024
TERM_GRACE_S = 2
HOST_GRACE_S = 15
STALE_AFTER_S = 3600.0
CREATE_TIMEOUT_S = 60
GONE_WAIT_S = 15
LATE_START_WATCH_S = 3
VISIBLE_TESTS = "python -m unittest discover -s tests"
HIDDEN_NAME = re.compile(r"^test_task\d+\.py$")


class SandboxRefused(Exception):
    pass


@dataclass(frozen=True)
class Limits:
    seconds: int = 60
    memory: str = "512m"
    cpus: str = "1"
    pids: int = 64
    cap_bytes: int = OUTPUT_CAP


@dataclass(frozen=True)
class RunResult:
    output: str
    returncode: int | None
    truncated: bool
    timed_out: bool
    sandbox_error: str | None
    container: str


def docker_argv(name: str, scratch: Path, inner: str, limits: Limits) -> list[str]:
    """Create, not run. With `docker run` a client killed during startup left the daemon
    to start the container after we had confirmed it gone (proven). Create returns once
    the name exists, so kill and rm by name cannot miss it.
    """
    return [
        "docker", "create", "--rm", "--init", "--name", name,
        "--network", "none", "--read-only", "--tmpfs", "/work",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--pids-limit", str(limits.pids), "--memory", limits.memory, "--cpus", limits.cpus,
        "--user", f"{os.getuid()}:{os.getgid()}",
        "--mount", f"type=bind,src={scratch},dst=/scratch,readonly",
        IMAGE, "sh", "-c", inner,
    ]


def inner_command(command: str, seconds: int, marker: str) -> str:
    """The marker prints only after the copy, before any model code can run."""
    return (f"cp -r /scratch/. /work/ && cd /work && echo {marker} && "
            f"exec timeout -k {TERM_GRACE_S} {seconds} {command} 2>&1")


def _read_capped(proc: subprocess.Popen[bytes], cap: int, deadline: float) -> tuple[bytes, bool, bool]:
    """Returns (data, over cap, past deadline)."""
    assert proc.stdout is not None
    fd = proc.stdout.fileno()
    data = bytearray()
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return bytes(data), False, True
        ready, _, _ = select.select([fd], [], [], min(left, 0.25))
        if not ready:
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            return bytes(data), False, False
        data += chunk
        if len(data) > cap:
            return bytes(data[:cap]), True, False


def _docker_quiet(*args: str) -> str:
    done = subprocess.run(["docker", *args], capture_output=True, timeout=30)
    return done.stdout.decode().strip()


def _exists(name: str) -> bool:
    """Fails closed: an unreachable daemon must not read as a container that has gone."""
    done = subprocess.run(["docker", "ps", "-aq", "--filter", f"name=^{name}$"],
                          capture_output=True, timeout=30, check=True)
    return bool(done.stdout.strip())


def sweep_stale(max_age_s: float = STALE_AFTER_S) -> list[str]:
    """Removes what a killed tool left: a created container, or one whose timeout was stopped."""
    done = subprocess.run(
        ["docker", "ps", "-a", "--filter", "name=^agentic-replay-",
         "--format", "{{.Names}}\t{{.CreatedAt}}"],
        capture_output=True, text=True, timeout=30, check=True)
    now = datetime.now(timezone.utc)
    removed: list[str] = []
    for line in done.stdout.splitlines():
        name, created = line.split("\t", 1)
        stamp = datetime.strptime(" ".join(created.split()[:3]), "%Y-%m-%d %H:%M:%S %z")
        if (now - stamp).total_seconds() >= max_age_s:
            _docker_quiet("rm", "-f", name)
            removed.append(name)
    return removed


def _stop_and_confirm(name: str) -> bool:
    _docker_quiet("kill", name)
    _docker_quiet("rm", "-f", name)  # a created container that never started
    deadline = time.monotonic() + GONE_WAIT_S
    while time.monotonic() < deadline:
        if not _exists(name):
            return True
        time.sleep(0.1)
    return False


def _finish(raw: bytes, marker: str, rc: int | None, over: bool, late: bool, name: str,
            gone: bool, limit: int) -> RunResult:
    text = raw.decode("utf-8", "replace")
    head = marker + "\n"
    if not gone:
        return RunResult(text, rc, over, late, f"container {name} still present", name)
    if not text.startswith(head):
        return RunResult("", rc, over, late, f"container never reported ready: {text[:300]!r}", name)
    body = text[len(head):]
    if over:
        body += f"\n[output truncated at {limit} bytes, container killed]\n"
    timed_out = late or rc in (124, 137) and not over
    return RunResult(body, rc, over, timed_out, None, name)


def _end_client(proc: subprocess.Popen[bytes], force: bool) -> int:
    """A clean EOF keeps the real exit code: killing it at once would turn 0 into -9."""
    if force:
        proc.kill()
    try:
        return proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.wait(timeout=30)


def run_sandboxed(
    scratch: Path, command: str, limits: Limits = Limits(),
    on_spawn: Callable[[subprocess.Popen[bytes]], None] | None = None,
) -> RunResult:
    """Attached run with capped output. on_spawn exists for the kill-the-client probe."""
    name = f"agentic-replay-{uuid.uuid4().hex[:16]}"
    marker = f"sandbox-ready-{uuid.uuid4().hex}"
    inner = inner_command(command, limits.seconds, marker)
    created = subprocess.run(docker_argv(name, scratch, inner, limits), capture_output=True,
                             timeout=CREATE_TIMEOUT_S)
    if created.returncode != 0:
        detail = created.stderr.decode("utf-8", "replace")[:300]
        return RunResult("", None, False, False, f"create failed: {detail}", name)
    proc = subprocess.Popen(["docker", "start", "-a", name], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if on_spawn:
        on_spawn(proc)
    deadline = time.monotonic() + limits.seconds + TERM_GRACE_S + HOST_GRACE_S
    raw, over, late = b"", False, False
    try:
        raw, over, late = _read_capped(proc, limits.cap_bytes, deadline)
    finally:
        # Client first: an unread attach stream blocks `docker kill` itself (proven).
        assert proc.stdout is not None
        proc.stdout.close()
        rc = _end_client(proc, force=over or late)
        gone = _stop_and_confirm(name)
    return _finish(raw, marker, rc, over, late, name, gone, limits.cap_bytes)


def hidden_command(module: str) -> str:
    assert HIDDEN_NAME.match(module), module
    return f"python -m unittest discover -s hidden -p {module} -t ."


def hidden_passed(result: RunResult, expected_tests: int) -> bool:
    """Needs the exact count and a bare OK: sys.exit at import gives rc 0 with nothing run."""
    if result.sandbox_error or result.truncated or result.timed_out or result.returncode != 0:
        return False
    ran = re.search(r"^Ran (\d+) tests? in ", result.output, re.M)
    lines = result.output.strip().splitlines()
    return bool(ran and int(ran.group(1)) == expected_tests and lines[-1] == "OK")


def copy_allowlisted(scratch: Path, dest: Path, patterns: list[str]) -> list[str]:
    """Regular files only, read through the same checks as the file tools."""
    copied: list[str] = []
    for pattern in patterns:
        for found in sorted(glob.glob(str(scratch / pattern), recursive=True)):
            relative = os.path.relpath(found, scratch)
            if os.path.islink(found) or not stat.S_ISREG(os.lstat(found).st_mode):
                continue
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            fd = fstools._open_regular(found, os.O_RDONLY)
            with os.fdopen(fd, "rb") as source:
                target.write_bytes(source.read())
            copied.append(relative)
    return copied


def run_hidden(
    scratch: Path, hidden_dir: Path, patterns: list[str], module: str, limits: Limits = Limits(),
) -> RunResult:
    """Fresh container, allowlisted sources only. Output goes to scoring, never to the model."""
    with tempfile.TemporaryDirectory(prefix="agentic-hidden-") as tmp:
        work = Path(tmp)
        copy_allowlisted(scratch, work, patterns)
        shutil.copytree(hidden_dir, work / "hidden")
        return run_sandboxed(work, hidden_command(module), limits)


def require_host() -> None:
    host = socket.gethostname()
    if host != ALLOWED_HOST:
        raise SandboxRefused(f"task runs on {ALLOWED_HOST} only, this is {host}")
    if shutil.which("docker") is None:
        raise SandboxRefused("docker is not on PATH")
    done = subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True)
    if done.returncode != 0:
        raise SandboxRefused(f"image not pulled: docker pull {IMAGE}")
    sweep_stale()


@dataclass(frozen=True)
class ProbeResult:
    name: str
    ok: bool
    detail: str


NETWORK_PROBE = """
import socket, unittest
class T(unittest.TestCase):
    def test(self):
        routes = open("/proc/net/route").read().splitlines()[1:]
        self.assertEqual(routes, [])
        with self.assertRaises(OSError):
            socket.create_connection(("1.1.1.1", 53), timeout=3)
"""
WRITE_PROBE = """
import os, unittest
class T(unittest.TestCase):
    def test(self):
        for path in ("/probe-file", "/scratch/probe-file"):
            with self.assertRaises(OSError):
                open(path, "w")
        os.symlink("/etc/passwd", "/work/escape")
"""
PASS_PROBE = "import unittest\nclass T(unittest.TestCase):\n    def test(self):\n        pass\n"
SLEEP_PROBE = "import time\ntime.sleep(600)\n"
SIGTERM_PROBE = ("import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                 "time.sleep(600)\n")
FLOOD_PROBE = "while True:\n    print('y' * 1024, flush=True)\n"
EXIT_PROBE = "import sys\nsys.exit(0)\n"


def _probe_dir(tests: dict[str, str]) -> tempfile.TemporaryDirectory[str]:
    tmp = tempfile.TemporaryDirectory(prefix="agentic-probe-")
    for name, text in tests.items():
        Path(tmp.name, name).write_text(text)
    return tmp


def _unit(name: str, source: str) -> ProbeResult:
    with _probe_dir({"test_probe.py": source}) as tmp:
        result = run_sandboxed(Path(tmp), "python -m unittest test_probe")
    return ProbeResult(name, hidden_passed(result, 1), result.output[-200:])


def _stopped(name: str, source: str) -> ProbeResult:
    with _probe_dir({"probe.py": source}) as tmp:
        started = time.monotonic()
        limits = Limits(seconds=2)
        result = run_sandboxed(Path(tmp), "python probe.py", limits)
    took = time.monotonic() - started
    # The bound the code guarantees: backstop at the deadline, then confirm it is gone.
    bound = limits.seconds + TERM_GRACE_S + HOST_GRACE_S + GONE_WAIT_S
    ok = result.timed_out and not result.sandbox_error and took < bound
    ok = ok and not _exists(result.container)
    return ProbeResult(name, ok, f"rc={result.returncode} {took:.1f}s")


def _flood() -> ProbeResult:
    with _probe_dir({"probe.py": FLOOD_PROBE}) as tmp:
        result = run_sandboxed(Path(tmp), "python probe.py")
    ok = result.truncated and "[output truncated" in result.output
    ok = ok and len(result.output) < OUTPUT_CAP + 200 and not _exists(result.container)
    return ProbeResult("output_cap", ok, f"{len(result.output)} chars rc={result.returncode}")


def _sys_exit() -> ProbeResult:
    source = {"bad.py": EXIT_PROBE, "test_probe.py": "import bad\n" + PASS_PROBE}
    with _probe_dir(source) as tmp:
        result = run_sandboxed(Path(tmp), "python -m unittest test_probe")
    ok = result.returncode == 0 and not hidden_passed(result, 1)
    return ProbeResult("sys_exit_at_import", ok, f"rc={result.returncode}")


def _symlink() -> ProbeResult:
    with _probe_dir({"plain.txt": "x"}) as tmp, tempfile.TemporaryDirectory() as outside:
        secret = Path(outside, "secret")
        secret.write_text("outside")
        os.symlink(secret, Path(tmp, "link"))
        try:
            text = fstools.read_file(Path(tmp), "link")
        except fstools.ToolError as exc:
            return ProbeResult("symlink_refused", True, str(exc))
    return ProbeResult("symlink_refused", False, f"read {text!r}")


def _kill_client_after(delay: float) -> ProbeResult:
    spawned: list[subprocess.Popen[bytes]] = []
    holder: list[RunResult] = []
    name = f"kill_client_after_{delay}s"
    with _probe_dir({"probe.py": SLEEP_PROBE}) as tmp:
        args = (Path(tmp), "python probe.py", Limits(seconds=30), spawned.append)
        worker = threading.Thread(target=lambda: holder.append(run_sandboxed(*args)))
        worker.start()
        while not spawned and worker.is_alive():
            time.sleep(0.01)
        time.sleep(delay)
        spawned[0].kill()
        worker.join(60)
    if not holder:
        return ProbeResult(name, False, "run did not return")
    time.sleep(LATE_START_WATCH_S)  # the daemon may still be starting it
    left = _exists(holder[0].container)
    return ProbeResult(name, not left, f"{holder[0].container} present={left}")


def containment_probes() -> list[ProbeResult]:
    """Real containers. `task` refuses to start unless every one holds."""
    return [
        _unit("normal_test_passes", PASS_PROBE),
        _unit("network_blocked", NETWORK_PROBE),
        _unit("root_and_scratch_read_only", WRITE_PROBE),
        _stopped("sleep_stopped", SLEEP_PROBE),
        _stopped("sigterm_ignored_stopped", SIGTERM_PROBE),
        _flood(),
        _sys_exit(),
        _symlink(),
        _kill_client_after(0.2),
        _kill_client_after(3.0),
    ]
