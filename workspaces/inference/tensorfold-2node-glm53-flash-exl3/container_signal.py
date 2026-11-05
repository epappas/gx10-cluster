#!/usr/bin/python3 -I
"""Inspect or terminate one identity-verified local Docker init process without Docker."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import asdict, dataclass
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import select
import signal
from typing import Any, Iterator
from uuid import UUID

BOOT_ID = Path("/proc/sys/kernel/random/boot_id")


@dataclass(frozen=True)
class Identity:
    container_id: str
    pid: int
    start_ticks: int
    boot_id: str


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_target(container_id: str, pid: int) -> None:
    require(re.fullmatch(r"[0-9a-f]{64}", container_id) is not None,
            "container ID must be the full 64-character hexadecimal ID")
    require(pid > 1, "refusing PID 1 or a nonpositive PID")


def identity(container_id: str, pid: int) -> Identity:
    validate_target(container_id, pid)
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
        cgroups = Path(f"/proc/{pid}/cgroup").read_text().splitlines()
    except FileNotFoundError as exc:
        raise ProcessLookupError(f"process {pid} exited") from exc
    components = {part for line in cgroups
                  for part in PurePosixPath(line.split(":", 2)[-1]).parts}
    require(container_id in components or f"docker-{container_id}.scope" in components,
            "process cgroup does not identify the requested Docker container")
    fields = stat.rsplit(")", 1)[1].split()
    require(len(fields) > 19, "incomplete kernel process identity")
    start_ticks = int(fields[19])
    require(start_ticks > 0, "invalid kernel process start time")
    boot_id = str(UUID(BOOT_ID.read_text().strip()))
    return Identity(container_id, pid, start_ticks, boot_id)


def exited(descriptor: int, timeout_s: float = 0) -> bool:
    poller = select.poll()
    poller.register(descriptor, select.POLLIN)
    events = poller.poll(math.ceil(timeout_s * 1000))
    return any(event & select.POLLIN for _, event in events)


@contextmanager
def pinned(container_id: str, pid: int) -> Iterator[tuple[int, Identity]]:
    validate_target(container_id, pid)
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise OSError("Linux pidfd support is required; no numeric-PID fallback")
    descriptor = os.pidfd_open(pid)
    try:
        if exited(descriptor):
            raise ProcessLookupError(f"process {pid} already exited")
        measured = identity(container_id, pid)
        yield descriptor, measured
    finally:
        os.close(descriptor)


def expected_identity(args: argparse.Namespace) -> Identity:
    require(args.start_ticks is not None and args.start_ticks > 0,
            "cached positive start-ticks are required")
    require(args.boot_id is not None, "cached boot-id is required")
    return Identity(args.container_id, args.pid, args.start_ticks, str(UUID(args.boot_id)))


def operate(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    expected = expected_identity(args) if args.action != "inspect" else None
    with pinned(args.container_id, args.pid) as (descriptor, measured):
        if args.action == "inspect":
            return 0, asdict(measured)
        require(measured == expected, "cached process identity differs; refusing to signal")
        if args.action == "check":
            return 0, {"state": "alive", **asdict(measured)}
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        if not exited(descriptor, args.timeout_s):
            return 1, {"state": "unconfirmed", "reason": "SIGKILL requested but exit not observed",
                       **asdict(measured)}
        return 0, {"state": "killed", **asdict(measured)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "check", "kill"))
    parser.add_argument("--container-id", required=True)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--start-ticks", type=int)
    parser.add_argument("--boot-id")
    parser.add_argument("--timeout-s", type=float, default=2.0)
    args = parser.parse_args()
    try:
        require(math.isfinite(args.timeout_s) and 0 < args.timeout_s <= 5,
                "timeout must be finite, above zero and at most five seconds")
        code, value = operate(args)
    except ProcessLookupError as exc:
        code, value = 3, {"state": "exited", "reason": str(exc)}
    except PermissionError as exc:
        code, value = 77, {"state": "permission-denied", "reason": str(exc)}
    except (ValueError, IndexError) as exc:
        code, value = 2, {"state": "refused", "reason": str(exc)}
    except OSError as exc:
        code, value = 1, {"state": "unconfirmed", "reason": str(exc)}
    print(json.dumps(value, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
