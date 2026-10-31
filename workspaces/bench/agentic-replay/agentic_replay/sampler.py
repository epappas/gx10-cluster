"""Memory sampler over read-only ssh. Nothing is written on a node.

One remote loop reads MemAvailable and, if a guard log was given, any new
lines. It holds no process that idles: every pass writes to stdout, so when the
client goes the next write fails and the loop exits.
"""

from __future__ import annotations

import re
import shlex
import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

PERIOD_S = "0.2"
KILL_LINE = re.compile(r"\bkilled\b", re.I)
GUARD_NOT_READ = "guard not read"
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=10")

Sink = Callable[[dict[str, Any]], None]


def remote_script(guard_log: str | None) -> str:
    memory = "awk '/^MemAvailable:/{print \"M\", $2}' /proc/meminfo || exit 1"
    if guard_log is None:
        return f"while :; do {memory}; sleep {PERIOD_S}; done"
    log = shlex.quote(guard_log)
    return (
        f"[ -r {log} ] || {{ echo 'E guard log unreadable'; exit 3; }}; "
        f"seen=$(wc -c < {log}); "
        f"while :; do {memory}; "
        f"size=$(wc -c < {log}) || {{ echo 'E guard log unreadable'; exit 3; }}; "
        f"[ \"$size\" -lt \"$seen\" ] && seen=0; "
        f"if [ \"$size\" -gt \"$seen\" ]; then "
        f"tail -c +$((seen + 1)) {log} | head -c $((size - seen)) | sed 's/^/G /' || exit 1; "
        f"seen=$size; fi; "
        f"sleep {PERIOD_S}; done"
    )


def ssh_argv(node: str, guard_log: str | None, ssh_config: str | None) -> list[str]:
    config = ("-F", ssh_config) if ssh_config else ()
    command = "exec sh -c " + shlex.quote(remote_script(guard_log))
    return ["ssh", *config, *SSH_OPTIONS, node, command]


def parse_line(node: str, line: str, now: float) -> dict[str, Any] | None:
    tag, _, rest = line.rstrip("\n").partition(" ")
    if tag == "M" and rest.isdigit():
        return {"node": node, "t": now, "available_kib": int(rest)}
    if tag == "G":
        return {"node": node, "t": now, "guard_line": rest, "kill": bool(KILL_LINE.search(rest))}
    if tag == "E":
        return {"node": node, "t": now, "error": rest}
    return None


class Sampler:
    def __init__(self, nodes: list[str], guard_log: str | None, ssh_config: str | None, sink: Sink):
        self.guard_log = guard_log
        self._sink = sink
        self._stopping = threading.Event()
        self._procs = {n: subprocess.Popen(ssh_argv(n, guard_log, ssh_config),
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, text=True)
                       for n in nodes}
        self._threads = [threading.Thread(target=self._read, args=(n, p), daemon=True)
                         for n, p in self._procs.items()]
        for thread in self._threads:
            thread.start()

    def _read(self, node: str, proc: subprocess.Popen[str]) -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            parsed = parse_line(node, line, time.time())
            if parsed:
                self._sink(parsed)
        if not self._stopping.is_set():
            self._sink({"node": node, "t": time.time(), "error": f"ssh ended rc={proc.wait()}"})

    def stop(self) -> None:
        self._stopping.set()
        for proc in self._procs.values():
            proc.terminate()
        for thread in self._threads:
            thread.join(5)


@dataclass(frozen=True)
class Window:
    started: float
    ended: float


def guard_reading(guard_log: str | None, values: list[int], errors: list[str],
                  kills: list[str]) -> Any:
    """An unread log is `guard not read`. An empty kill list would claim there were none."""
    if guard_log is None:
        return "no guard log"
    return GUARD_NOT_READ if errors or not values else {"kill_lines": kills}


def guard_unread(memory: dict[str, Any]) -> list[str]:
    return [node for node, row in memory.items()
            if isinstance(row, dict) and row.get("guard") == GUARD_NOT_READ]


def summarise_memory(
    samples: list[dict[str, Any]], nodes: list[str], guard_log: str | None,
) -> dict[str, Any]:
    """Without a log the answer is `no guard log`, never `no kills`."""
    out: dict[str, Any] = {}
    for node in nodes:
        mine = [s for s in samples if s.get("node") == node]
        values = [s["available_kib"] for s in mine if "available_kib" in s]
        kills = [s["guard_line"] for s in mine if s.get("kill")]
        errors = [s["error"] for s in mine if "error" in s]
        out[node] = {
            "samples": len(values),
            "low_kib": min(values) if values else None,
            "median_interval_s": _median_interval(mine),
            "errors": errors,
            "kill_lines": kills,
            "guard": guard_reading(guard_log, values, errors, kills),
        }
    return out


def _median_interval(samples: list[dict[str, Any]]) -> float | None:
    times = [s["t"] for s in samples if "available_kib" in s]
    gaps = sorted(b - a for a, b in zip(times, times[1:]))
    return gaps[len(gaps) // 2] if gaps else None


def low_in_window(samples: list[dict[str, Any]], window: Window) -> dict[str, int]:
    """Lowest MemAvailable per node while one request was in flight."""
    lows: dict[str, int] = {}
    for s in samples:
        if "available_kib" in s and window.started <= s["t"] <= window.ended:
            node = s["node"]
            lows[node] = min(lows.get(node, s["available_kib"]), s["available_kib"])
    return lows
