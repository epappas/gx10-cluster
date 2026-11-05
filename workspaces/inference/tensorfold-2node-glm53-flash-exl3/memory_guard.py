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
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import stat

SOFT_GIB = 2.5
SUSTAIN_S = 4.0
HARD_GIB = 1.0
SAMPLE_S = 0.2
MAX_SAMPLE_S = 0.25
WATCH_S = 1.0
DOCKER_TIMEOUT_S = 2.0
KILL_TIMEOUT_S = 2.0
RETRY_MAX_S = 5.0
STARTUP_MAX_S = 6 * 3600
KIB_PER_GIB = 1024**2
MEMINFO = Path("/proc/meminfo")
# Not just "no such": a dead daemon says "connect: no such file or directory".
NO_CONTAINER = "no such container"
SYSTEM_SIGNAL_HELPER = Path("/usr/local/libexec/gx10-container-signal")


@dataclass(frozen=True)
class ProcessBinding:
    helper: Path
    container_id: str
    pid: int
    start_ticks: int
    boot_id: str

    def arguments(self, action: str) -> list[str]:
        return [action, "--container-id", self.container_id, "--pid", str(self.pid),
                "--start-ticks", str(self.start_ticks), "--boot-id", self.boot_id]


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


def log_line(log: int, message: str) -> bool:
    """Unbuffered, and never fatal: a full disk must not stop a kill."""
    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    try:
        os.write(log, f"{stamp} {message}\n".encode())
        return True
    except OSError:
        return False


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


def trusted_system_helper(path: Path) -> bool:
    if path != SYSTEM_SIGNAL_HELPER:
        return False
    try:
        for item in (path, *path.parents):
            info = item.lstat()
            if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
                return False
        return stat.S_ISREG(path.stat().st_mode)
    except OSError:
        return False


def signal_helper(path: Path, arguments: list[str]) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, "-I", "-B", str(path), *arguments]
    result = subprocess.run(command, capture_output=True, text=True, timeout=KILL_TIMEOUT_S + 1)
    if result.returncode != 77 or not trusted_system_helper(path):
        return result
    command = ["/usr/bin/sudo", "-n", "--", "/usr/bin/python3", "-I", "-B", str(path), *arguments]
    return subprocess.run(command, capture_output=True, text=True, timeout=KILL_TIMEOUT_S + 1)


def bind_process(helper: Path, container_id: str, log: int) -> ProcessBinding | None:
    try:
        if not helper.is_file():
            raise ValueError("signal helper is not installed")
        result = docker("container", "inspect", "-f", "{{.State.Pid}} {{.HostConfig.RestartPolicy.Name}}", container_id)
        if result.returncode:
            raise ValueError(result.stderr.strip())
        fields = result.stdout.strip().split()
        if len(fields) != 2 or fields[1] != "no":
            raise ValueError("fallback requires an existing restart policy of no; no policy was changed")
        pid = int(fields[0])
        result = signal_helper(helper, ["inspect", "--container-id", container_id, "--pid", str(pid)])
        if result.returncode:
            raise ValueError(result.stdout.strip() or result.stderr.strip())
        value = json.loads(result.stdout)
        if value["container_id"] != container_id or value["pid"] != pid:
            raise ValueError("helper returned a different container/process binding")
        binding = ProcessBinding(helper, container_id, pid, int(value["start_ticks"]), str(value["boot_id"]))
        log_line(log, "process fallback armed: " + json.dumps({**asdict(binding), "helper": str(helper)}))
        return binding
    except (DockerUnavailable, OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError) as exc:
        log_line(log, f"process fallback unavailable; Docker-only protection: {exc}")
        return None


def process_alive(binding: ProcessBinding) -> bool | None:
    try:
        result = signal_helper(binding.helper, binding.arguments("check"))
        if result.returncode == 0 and json.loads(result.stdout).get("state") == "alive":
            return True
        if result.returncode == 3 and json.loads(result.stdout).get("state") == "exited":
            return False
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return None


def fallback_kill(binding: ProcessBinding, name: str, why: str, log: int) -> bool:
    try:
        result = signal_helper(binding.helper, binding.arguments("kill"))
        value = json.loads(result.stdout)
        if result.returncode == 0 and value.get("state") == "killed":
            log_line(log, f"killed container {name} id={binding.container_id}: {why}; pidfd exit confirmed")
            return True
        if result.returncode == 3 and value.get("state") == "exited":
            log_line(log, f"cached process exited for container {name}; termination cause unconfirmed")
            return True
        log_line(log, f"process fallback unconfirmed for {name}: exit={result.returncode} {result.stdout.strip()}")
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        log_line(log, f"process fallback unconfirmed for {name}: {exc}")
    return False


def save_binding(args: argparse.Namespace, binding: ProcessBinding | None, log: int) -> None:
    if binding is None or args.status_file is None:
        return
    path = args.status_file.with_name("process.json")
    value = {**asdict(binding), "helper": str(binding.helper), "guard_pid": os.getpid()}
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream)
            stream.write("\n")
    except OSError as exc:
        log_line(log, f"process binding snapshot not written: {exc}")


def watch(name: str, container_id: str, gone: threading.Event, log: int,
          binding: ProcessBinding | None = None) -> None:
    """Slow inspections cannot block the memory sampler."""
    delay = SAMPLE_S
    retained = False
    while not gone.wait(delay):
        try:
            current = running_id(name)
        except DockerUnavailable as exc:
            if binding is not None and process_alive(binding) is False:
                gone.set()
                return
            if delay == SAMPLE_S:
                protection = "cached process fallback retained" if binding else "protection unconfirmed"
                log_line(log, f"docker unavailable: {protection}: {exc}")
            delay = min(RETRY_MAX_S, max(1.0, delay * 2))
            continue
        delay = SAMPLE_S
        if current == container_id:
            retained = False
            continue
        if binding is None or process_alive(binding) is False:
            gone.set()
            return
        if not retained:
            log_line(log, f"Docker metadata changed for {name}; cached process protection retained")
            retained = True
        delay = 1.0


def kill(name: str, container_id: str, why: str, retry: bool, log: int,
         binding: ProcessBinding | None = None) -> bool:
    """Return terminal only after Docker confirmation or identity-verified process exit."""
    if not retry:
        log_line(log, f"killing container {name} id={container_id}: {why}")
    began = time.monotonic()
    try:
        done = docker("kill", container_id, timeout=KILL_TIMEOUT_S)
        if done.returncode == 0:
            took = time.monotonic() - began
            log_line(log, f"killed container {name} id={container_id}: {why}; docker took {took:.1f} s")
            return True
        reason = done.stderr.strip()
    except DockerUnavailable as exc:
        reason = str(exc)
    if binding is not None and fallback_kill(binding, name, why, log):
        return True
    if not retry:
        log_line(log, f"kill unconfirmed, retrying with backoff: {reason}")
    return False


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


def guard(args: argparse.Namespace, container_id: str, gone: threading.Event, log: int,
          binding: ProcessBinding | None = None) -> None:
    dip: Dip | None = None
    unconfirmed = False
    retry_at = 0.0
    retry_delay = 1.0
    while not gone.is_set():
        available = mem_available_kib()
        now = time.monotonic()
        if available >= args.soft_gib * KIB_PER_GIB:
            if dip:
                suffix = "; earlier kill unconfirmed" if unconfirmed else ""
                log_line(log, f"recovered: no kill confirmed; lowest {gib(dip.lowest_kib)}, "
                              f"lasted {now - dip.started:.1f} s{suffix}")
            dip, unconfirmed, retry_at, retry_delay = None, False, 0.0, 1.0
        else:
            if dip is None:
                dip = Dip(now, available)
                log_line(log, f"dip: MemAvailable {gib(available)} under soft floor "
                              f"{args.soft_gib:.2f} GiB; lowest {gib(available)}")
            dip.lowest_kib = min(dip.lowest_kib, available)
            why = kill_reason(args, dip, available, now)
            if why and now >= retry_at:
                if kill(args.container, container_id, why, unconfirmed, log, binding):
                    return
                unconfirmed = True
                retry_at = time.monotonic() + retry_delay
                retry_delay = min(RETRY_MAX_S, retry_delay * 2)
        gone.wait(args.sample_s)
    if unconfirmed:
        log_line(log, f"container {args.container} gone; kill unconfirmed")
    log_line(log, f"container {args.container} gone, guard exiting"
                  + (f"; open dip lowest {gib(dip.lowest_kib)}" if dip else ""))


def status(args: argparse.Namespace, value: str) -> None:
    if args.status_file:
        try:
            args.status_file.write_text(value + "\n")
        except OSError:
            pass  # Missing/stale evidence fails the shell's status check, not monitoring.



def run_rank(args: argparse.Namespace, container_id: str, log: int) -> None:
    # The id and kernel identity are captured before sampling, never rediscovered by name during a kill.
    binding = bind_process(args.signal_helper, container_id, log)
    save_binding(args, binding, log)
    log_line(log, f"started: container {args.container} id={container_id}, "
                  f"soft {args.soft_gib:.2f} GiB for {args.sustain_s:.1f} s, "
                  f"hard {args.hard_gib:.2f} GiB, sample {args.sample_s:.2f} s")
    status(args, f"guarding {container_id}")
    gone = threading.Event()
    watcher = threading.Thread(target=watch, args=(args.container, container_id, gone, log, binding),
                               daemon=True)
    watcher.start()
    try:
        guard(args, container_id, gone, log, binding)
    finally:
        gone.set()
        watcher.join(DOCKER_TIMEOUT_S + 1)


def supervising(args: argparse.Namespace, deadline: float) -> bool:
    return bool(args.startup_file and args.startup_file.exists() and time.monotonic() < deadline)


def supervise(args: argparse.Namespace, log: int, current: str | None) -> None:
    deadline = time.monotonic() + STARTUP_MAX_S
    delay = SAMPLE_S
    final_checked = False
    while True:
        if current:
            run_rank(args, current, log)
        status(args, "waiting")
        if not supervising(args, deadline):
            if final_checked or args.startup_file is None:
                log_line(log, "startup supervision finished; no active guarded container")
                return
            # A replacement may have appeared between the shell's ack and disarm.
            try:
                current = running_id(args.container)
            except DockerUnavailable as exc:
                log_line(log, f"final handoff unconfirmed; discovery retained: {exc}")
                if args.startup_file:
                    args.startup_file.touch()
                time.sleep(RETRY_MAX_S)
                continue
            final_checked = True
            if current:
                continue
            log_line(log, "startup supervision finished after final inspection")
            return
        time.sleep(delay)
        try:
            current = running_id(args.container)
        except DockerUnavailable as exc:
            if delay == SAMPLE_S:
                log_line(log, f"docker unavailable: startup protection unconfirmed: {exc}")
            status(args, "unavailable")
            current = None
            delay = min(RETRY_MAX_S, max(1.0, delay * 2))
            continue
        delay = SAMPLE_S


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--soft-gib", type=float, default=SOFT_GIB)
    parser.add_argument("--sustain-s", type=float, default=SUSTAIN_S)
    parser.add_argument("--hard-gib", type=float, default=HARD_GIB)
    parser.add_argument("--sample-s", type=float, default=SAMPLE_S)
    parser.add_argument("--signal-helper", type=Path, default=SYSTEM_SIGNAL_HELPER)
    parser.add_argument("--startup-file", type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--status-file", type=Path)
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
    if container_id is None and args.startup_file is None:
        print(f"memory_guard: no running container named {args.container}", file=sys.stderr)
        return 2
    args.log.parent.mkdir(parents=True, exist_ok=True)
    log = os.open(args.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    ready = log_line(log, f"supervisor started: container {args.container}, pid={os.getpid()}")
    if args.ready_file:
        if not ready:
            return 2
        args.ready_file.write_text(str(os.getpid()))
    try:
        supervise(args, log, container_id)
    finally:
        if args.ready_file:
            args.ready_file.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
