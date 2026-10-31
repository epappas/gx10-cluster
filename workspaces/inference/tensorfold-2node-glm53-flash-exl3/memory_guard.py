#!/usr/bin/env python3
"""Kill a container before MemAvailable runs out and the node stops answering.

Under the soft floor for the sustain time, or under the hard floor at once, the
container is killed. Exits by itself when the container stops or is replaced.
No pid file and no lock: nothing it leaves behind can block a restart.

Stdlib only: it is copied to the worker and run by the system python3.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SOFT_GIB = 2.5
SUSTAIN_S = 4.0
HARD_GIB = 1.0
SAMPLE_S = 0.2
MAX_SAMPLE_S = 0.25
WATCH_S = 1.0
DOCKER_TIMEOUT_S = 10.0
# Measured: 12 s for `docker kill` on a loaded daemon, so 10 s would cut off real kills.
KILL_TIMEOUT_S = 30.0
KIB_PER_GIB = 1024**2
MEMINFO = Path("/proc/meminfo")
# Not just "no such": a dead daemon says "connect: no such file or directory".
NO_CONTAINER = "no such container"


class DockerUnavailable(Exception):
    """Docker gave no answer, which says nothing about the container."""


@dataclass
class Dip:
    started: float
    lowest_kib: int


def mem_available_kib() -> int:
    for line in MEMINFO.read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1])
    raise RuntimeError(f"no MemAvailable in {MEMINFO}")


def gib(kib: float) -> str:
    return f"{kib / KIB_PER_GIB:.2f} GiB"


def log_line(log: int, message: str) -> None:
    """Unbuffered, and never fatal: a full disk must not stop a kill."""
    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    try:
        os.write(log, f"{stamp} {message}\n".encode())
    except OSError:
        pass


def docker(*args: str, timeout: float = DOCKER_TIMEOUT_S) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(["docker", *args], capture_output=True, text=True,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DockerUnavailable(str(exc)) from exc


def running_id(name: str) -> str | None:
    """The running container's id, None if it is absent or stopped."""
    done = docker("container", "inspect", "-f", "{{.Id}} {{.State.Running}}", name)
    if done.returncode != 0:
        if NO_CONTAINER in done.stderr.lower():
            return None
        raise DockerUnavailable(done.stderr.strip())
    container_id, running = done.stdout.split()
    return container_id if running == "true" else None


def watch(name: str, container_id: str, gone: threading.Event, log: int) -> None:
    """A thread, so a slow docker never delays a memory sample."""
    unreachable = False
    while not gone.wait(WATCH_S):
        try:
            current = running_id(name)
        except DockerUnavailable as exc:
            if not unreachable:
                log_line(log, f"docker unreachable, still guarding: {exc}")
            unreachable = True
            continue
        unreachable = False
        if current != container_id:
            gone.set()


def kill(name: str, container_id: str, why: str, retry: bool, log: int) -> bool:
    """True when nothing is left to guard. By id: never a successor of that name."""
    # Written first: a node that freezes during the kill still leaves the decision.
    log_line(log, f"killing container {name}: {why}")
    began = time.monotonic()
    try:
        done = docker("kill", container_id, timeout=KILL_TIMEOUT_S)
    except DockerUnavailable as exc:
        log_line(log, f"kill failed, will retry: {exc}")
        return False
    took = time.monotonic() - began
    reason = done.stderr.strip()
    if done.returncode == 0:
        log_line(log, f"killed container {name}: {why}; docker took {took:.1f} s")
        return True
    if NO_CONTAINER not in reason.lower() and "not running" not in reason.lower():
        log_line(log, f"kill failed, will retry: {reason}")
        return False
    if retry:
        log_line(log, f"killed container {name}: {why}; an earlier kill got no reply in time")
    else:
        log_line(log, f"container {name} went by itself before the kill: {why}")
    return True


def kill_reason(args: argparse.Namespace, dip: Dip, available_kib: int, now: float) -> str | None:
    lowest = gib(dip.lowest_kib)
    if available_kib < args.hard_gib * KIB_PER_GIB:
        return (f"MemAvailable {gib(available_kib)} under hard floor {args.hard_gib:.2f} GiB; "
                f"lowest {lowest}")
    held = now - dip.started
    if held >= args.sustain_s:
        return (f"MemAvailable under soft floor {args.soft_gib:.2f} GiB for {held:.1f} s; "
                f"lowest {lowest}")
    return None


def guard(args: argparse.Namespace, container_id: str, gone: threading.Event, log: int) -> None:
    dip: Dip | None = None
    unconfirmed: str | None = None
    while not gone.is_set():
        available = mem_available_kib()
        now = time.monotonic()
        if available >= args.soft_gib * KIB_PER_GIB:
            if dip:
                log_line(log, f"recovered: no kill; lowest {gib(dip.lowest_kib)}, "
                              f"lasted {now - dip.started:.1f} s")
            dip = None
        else:
            if dip is None:
                dip = Dip(now, available)
                log_line(log, f"dip: MemAvailable {gib(available)} under soft floor "
                              f"{args.soft_gib:.2f} GiB")
            dip.lowest_kib = min(dip.lowest_kib, available)
            why = kill_reason(args, dip, available, now)
            if why:
                if kill(args.container, container_id, why, unconfirmed is not None, log):
                    return
                unconfirmed = why
        gone.wait(args.sample_s)
    if unconfirmed:
        log_line(log, f"killed container {args.container}: {unconfirmed}; "
                      "an earlier kill got no reply in time")
    log_line(log, f"container {args.container} gone, guard exiting"
                  + (f"; open dip lowest {gib(dip.lowest_kib)}" if dip else ""))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--soft-gib", type=float, default=SOFT_GIB)
    parser.add_argument("--sustain-s", type=float, default=SUSTAIN_S)
    parser.add_argument("--hard-gib", type=float, default=HARD_GIB)
    parser.add_argument("--sample-s", type=float, default=SAMPLE_S)
    args = parser.parse_args(argv)
    if not 0 < args.hard_gib <= args.soft_gib:
        parser.error("floors must satisfy 0 < hard <= soft")
    if args.sustain_s <= 0:
        parser.error("--sustain-s must be above zero")
    if not 0 < args.sample_s <= MAX_SAMPLE_S:
        parser.error(f"--sample-s must be above zero and at most {MAX_SAMPLE_S}")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        container_id = running_id(args.container)
    except DockerUnavailable as exc:
        print(f"memory_guard: docker unavailable: {exc}", file=sys.stderr)
        return 2
    if container_id is None:
        print(f"memory_guard: no running container named {args.container}", file=sys.stderr)
        return 2
    args.log.parent.mkdir(parents=True, exist_ok=True)
    log = os.open(args.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    log_line(log, f"started: container {args.container}, soft {args.soft_gib:.2f} GiB for "
                  f"{args.sustain_s:.1f} s, hard {args.hard_gib:.2f} GiB, "
                  f"sample {args.sample_s:.2f} s, now {gib(mem_available_kib())}")
    gone = threading.Event()
    threading.Thread(target=watch, args=(args.container, container_id, gone, log),
                     daemon=True).start()
    guard(args, container_id, gone, log)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
