#!/usr/bin/env python3
"""The GLM memory guard kills what it must, and only that.

Real guard, real /proc/meminfo, real docker, real throwaway containers. Floors
are set relative to the host's live MemAvailable, and the brief dip is a real
allocation. No test touches any container it did not create.

The wiring runs the real up.sh and down.sh. Only the kit is replaced: a fixture
start.sh records what it was told and starts a throwaway container, because the
kit's own code is never run here. "Rank 1" is a private sshd on loopback, so the
worker path crosses real ssh, with its own HOME, on this same machine.

Whatever could not run prints NOT PROVEN. That is never a pass.

    python3 tests/check_memory_guard.py
"""

from __future__ import annotations

import os
import signal
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parent.parent
WORKSPACE = REPO / "workspaces" / "inference" / "tensorfold-2node-glm53-flash-exl3"
GUARD = WORKSPACE / "memory_guard.py"
IMAGE = os.environ.get("MEMORY_GUARD_IMAGE", "python:3-alpine")
REAL_CONTAINER = "glm53-flash-tf"
KIB_PER_GIB = 1024**2
TINY_GIB = "0.002"
# The guard's own deadlines are asserted on its decision. How long docker then
# takes is the daemon's, and it is reported: 12 s at load 39, and once no reply
# inside the guard's 30 s timeout, which its retry then finished.
DECISION_SLACK_S = 1.5
KILLED_WITHIN_S = 45.0
DIP_BYTES = 5 * 1024**3 // 2
RECOVERY_MARGIN_GIB = 0.5
DIP_SUSTAIN_S = 10
# What PR #20's sampler counts as a kill line.
KILL_LINE = re.compile(r"\bkilled\b", re.I)

not_proven: list[str] = []
measured: list[str] = []

SSHD_CONFIG = """Port {port}
ListenAddress 127.0.0.1
HostKey {tmp}/host_key
PidFile {tmp}/sshd.pid
AuthorizedKeysFile {tmp}/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
SetEnv HOME={tmp}/worker-home
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
FIXTURE_START = """#!/usr/bin/env bash
set -eu
printf '%s\\n' "$@" > "$FIXTURE_OUT/argv"
env > "$FIXTURE_OUT/env"
[ "${DRY_RUN:-0}" != 1 ] || exit 0
if [ -z "${FIXTURE_NO_CONTAINER:-}" ]; then
    rounds=1
    [ -z "${FIXTURE_REPLACE:-}" ] || rounds=2
    for round in $(seq 1 "$rounds"); do
        [ "$round" = 1 ] || docker rm -f "$CONTAINER_NAME" >/dev/null
        id=$(docker run -d --name "$CONTAINER_NAME" --network none "$FIXTURE_IMAGE" sleep 300)
        printf '%s\\n' "$id" >> "$FIXTURE_OUT/ids"
        i=0
        until grep -qF "started: container $CONTAINER_NAME id=$id," "$HOME/.cache/tensorfold-glm53/logs/memguard.log" && \
              grep -qF "started: container $CONTAINER_NAME id=$id," "$FIXTURE_WORKER_HOME/.cache/tensorfold-glm53/logs/memguard.log"; do
            i=$((i + 1)); [ "$i" -lt 150 ] || exit 90
            sleep 0.1
        done
    done
    touch "$FIXTURE_OUT/guarded-before-return"
fi
[ -z "${FIXTURE_HOLD:-}" ] || exec sleep 60
exit "${FIXTURE_EXIT:-0}"
"""

REAL_HF: Path | None = None
HELPER_ONLY = False


def mem_available_gib() -> float:
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) / KIB_PER_GIB
    raise AssertionError("no MemAvailable in /proc/meminfo")


def run(*argv: str, timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def wait_for(condition: Callable[[], bool], seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()


def container_name() -> str:
    return f"gx10-guard-test-{uuid.uuid4().hex[:12]}"


def start_container(name: str) -> None:
    done = run("docker", "run", "-d", "--name", name, "--network", "none", IMAGE, "sleep", "300",
               timeout=240)
    assert done.returncode == 0, done.stderr


def remove_container(name: str) -> None:
    run("docker", "rm", "-f", name)


def is_running(name: str) -> bool:
    done = run("docker", "container", "inspect", "-f", "{{.State.Running}}", name)
    return done.stdout.strip() == "true"


def start_guard(name: str, log: Path, *floors: str,
                env: dict[str, str] | None = None) -> subprocess.Popen[str]:
    guard = subprocess.Popen([sys.executable, str(GUARD), "--container", name, "--log", str(log),
                              *floors], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    assert wait_for(lambda: "started:" in text(log), 30), "guard never started"
    return guard


def stop_guard(guard: subprocess.Popen[str]) -> None:
    if guard.poll() is None:
        guard.kill()
    guard.communicate()


def text(log: Path) -> str:
    return log.read_text() if log.exists() else ""


def decided_after(log: Path) -> float:
    """Seconds from the guard's start to its first decision: a retry repeats the line."""
    stamps: dict[str, str] = {}
    for line in text(log).splitlines():
        stamps.setdefault(line.split()[1], line.split()[0])
    began, decided = stamps["started:"], stamps["killing"]
    return (datetime.fromisoformat(decided) - datetime.fromisoformat(began)).total_seconds()


def docker_took(log: Path) -> str:
    found = re.search(r"docker took [0-9.]+ s", text(log))
    return found.group(0) if found else "kill was not confirmed"


def check_refuses_bad_arguments() -> None:
    for extra in (["--sample-s", "0.5"], ["--soft-gib", "1", "--hard-gib", "2"],
                  ["--hard-gib", "0"], ["--sustain-s", "0"]):
        done = run(sys.executable, str(GUARD), "--container", "x", "--log", "/dev/null", *extra)
        assert done.returncode != 0, f"accepted {extra}"


def check_defaults_and_wiring() -> None:
    source = GUARD.read_text()
    for line in ("SOFT_GIB = 2.5", "SUSTAIN_S = 4.0", "HARD_GIB = 1.0", "SAMPLE_S = 0.2"):
        assert line in source, f"default changed: {line}"
    up = (WORKSPACE / "up.sh").read_text()
    assert "exec ./start.sh" not in up, "exec leaves nothing able to start the guards"
    helper = (WORKSPACE / "memory_guard.sh").read_text()
    assert 'memory_guard_launch "$@"' in up and './start.sh "$@"' in helper
    assert "exec " not in (WORKSPACE / "down.sh").read_text(), "exec skips stopping the guards"
    manifest = (WORKSPACE / "workspace.yml").read_text()
    assert "provenance: unverified" in manifest, "nothing here booted GLM"


def check_soft_floor_kills(tmp: Path) -> None:
    """Default sustain and hard floor, soft floor above what the host has."""
    name, log = container_name(), tmp / "soft.log"
    start_container(name)
    try:
        guard = start_guard(name, log, "--soft-gib", f"{mem_available_gib() * 2 + 1:.2f}")
        assert wait_for(lambda: not is_running(name), KILLED_WITHIN_S), "not killed"
        assert guard.wait(15) == 0
        decided = decided_after(log)
        assert 4.0 <= decided <= 4.0 + DECISION_SLACK_S, f"decided after {decided:.1f} s"
        lines = [ln for ln in text(log).splitlines() if KILL_LINE.search(ln)]
        assert len(lines) == 1 and f"killed container {name}" in lines[0], text(log)
        assert "lowest" in lines[0] and "soft floor" in lines[0], lines[0]
        assert re.match(r"\d{4}-\d\d-\d\dT", lines[0]), lines[0]
        measured.append(f"soft kill decided at {decided:.1f} s, {docker_took(log)}")
    finally:
        remove_container(name)


def check_hard_floor_kills_at_once(tmp: Path) -> None:
    name, log = container_name(), tmp / "hard.log"
    start_container(name)
    try:
        floor = f"{mem_available_gib() * 2 + 1:.2f}"
        guard = start_guard(name, log, "--soft-gib", floor, "--hard-gib", floor,
                            "--sustain-s", "60")
        assert wait_for(lambda: not is_running(name), KILLED_WITHIN_S), "not killed"
        assert guard.wait(15) == 0
        decided = decided_after(log)
        assert decided <= DECISION_SLACK_S, f"hard floor waited {decided:.1f} s"
        assert f"killed container {name}" in text(log) and "hard floor" in text(log), text(log)
        measured.append(f"hard kill decided at {decided:.1f} s, {docker_took(log)}")
    finally:
        remove_container(name)


def check_full_disk_does_not_stop_a_kill() -> None:
    """/dev/full fails every write with ENOSPC, as a full odysseus would."""
    name = container_name()
    start_container(name)
    floor = f"{mem_available_gib() * 2 + 1:.2f}"
    guard = subprocess.Popen([sys.executable, str(GUARD), "--container", name, "--log", "/dev/full",
                              "--soft-gib", floor, "--hard-gib", floor],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert wait_for(lambda: not is_running(name), KILLED_WITHIN_S), "a full disk stopped the kill"
        assert guard.wait(15) == 0, "guard crashed on a failed log write"
    finally:
        stop_guard(guard)
        remove_container(name)


def check_survives_near_zero_floors(tmp: Path) -> None:
    name, log = container_name(), tmp / "survive.log"
    start_container(name)
    guard = start_guard(name, log, "--soft-gib", TINY_GIB, "--hard-gib", TINY_GIB)
    try:
        time.sleep(6)
        assert guard.poll() is None, "guard exited with its container alive"
        assert is_running(name), "killed with near-zero floors"
        assert not KILL_LINE.search(text(log)) and "dip:" not in text(log), text(log)
    finally:
        stop_guard(guard)
        remove_container(name)


def dip_once(tmp: Path, attempt: int) -> bool:
    """One real dip on its own container. False: the host moved, so it is no evidence.

    Above the floor by a margin, or a host hovering at the floor reads as recovered
    while the guard, rightly, is still in the dip. And timed from before the
    allocation: on a loaded host it is slow, and a dip it stretches past the
    sustain time is a correct kill, not a failure.
    """
    name, log = container_name(), tmp / f"dip{attempt}.log"
    start_container(name)
    floor = mem_available_gib() - 1.0
    guard = start_guard(name, log, "--soft-gib", f"{floor:.3f}", "--hard-gib", TINY_GIB,
                        "--sustain-s", str(DIP_SUSTAIN_S))
    try:
        began = time.monotonic()
        blob = b"\x01" * DIP_BYTES
        time.sleep(1.0)
        dipped = mem_available_gib() < floor
        time.sleep(0.5)
        del blob
        down_s = time.monotonic() - began
        time.sleep(0.6)
        if down_s > DIP_SUSTAIN_S - 2:
            return False
        if not dipped or mem_available_gib() < floor + RECOVERY_MARGIN_GIB:
            return False
        seen = wait_for(lambda: "recovered: no kill" in text(log), 3)
        if mem_available_gib() < floor + RECOVERY_MARGIN_GIB:
            return False
        assert seen, text(log)
        assert is_running(name), "a dip shorter than the sustain time killed the container"
        assert not KILL_LINE.search(text(log)), text(log)
        recovered = next(ln for ln in text(log).splitlines() if "recovered: no kill" in ln)
        measured.append(f"brief dip under a {floor:.1f} GiB floor: {recovered.split(' ', 1)[1]}")
        return True
    finally:
        stop_guard(guard)
        remove_container(name)


def check_brief_dip_recovers(tmp: Path) -> None:
    if mem_available_gib() < 8:
        not_proven.append("brief dip: under 8 GiB available, too little to dip safely")
        return
    if not any(dip_once(tmp, attempt) for attempt in range(3)):
        not_proven.append("brief dip: host memory moved too much in 3 tries")


def check_exits_when_container_goes(tmp: Path) -> None:
    for how, verb in (("removed", ("rm", "-f")), ("stopped", ("stop", "-t", "0"))):
        name, log = container_name(), tmp / f"{how}.log"
        start_container(name)
        guard = start_guard(name, log, "--soft-gib", TINY_GIB, "--hard-gib", TINY_GIB)
        try:
            assert run("docker", *verb, name).returncode == 0
            assert guard.wait(15) == 0, f"guard outlived a {how} container"
            assert "guard exiting" in text(log) and not KILL_LINE.search(text(log)), text(log)
        finally:
            stop_guard(guard)
            remove_container(name)


def check_restart_is_not_blocked(tmp: Path) -> None:
    """The kit's restart: same name, new container. Old guard leaves, a new one starts."""
    name, log = container_name(), tmp / "restart.log"
    start_container(name)
    old = start_guard(name, log, "--soft-gib", TINY_GIB, "--hard-gib", TINY_GIB)
    retired, successor = container_name(), container_name()
    try:
        # Successor first and a swap by rename: docker run takes seconds here, and
        # an absent name would exit the guard without reaching the id comparison.
        start_container(successor)
        assert run("docker", "rename", name, retired).returncode == 0
        assert run("docker", "rename", successor, name).returncode == 0
        assert old.wait(15) == 0, "old guard stayed on a replaced container"
        fresh = start_guard(name, tmp / "restart2.log", "--soft-gib", TINY_GIB,
                            "--hard-gib", TINY_GIB)
        assert fresh.poll() is None and is_running(name)
        stop_guard(fresh)
    finally:
        stop_guard(old)
        for leftover in (name, retired, successor):
            remove_container(leftover)


def check_missing_container_fails_fast(tmp: Path) -> None:
    log = tmp / "missing.log"
    began = time.monotonic()
    done = run(sys.executable, str(GUARD), "--container", container_name(), "--log", str(log),
               timeout=15)
    assert done.returncode == 2, done
    assert time.monotonic() - began < 10 and "no running container" in done.stderr, done
    assert not log.exists(), "a guard that never ran wrote a log"


def check_dead_docker_is_not_a_gone_container() -> None:
    """Real docker CLI against a socket nothing serves: unknown, not gone."""
    code = (f"import sys; sys.path.insert(0, {str(WORKSPACE)!r}); import memory_guard as g\n"
            "try:\n    print('answer', g.running_id('x'))\n"
            "except g.DockerUnavailable:\n    print('unavailable')\n")
    env = {**os.environ, "DOCKER_HOST": "unix:///nonexistent/docker.sock"}
    done = subprocess.run([sys.executable, "-B", "-c", code], capture_output=True, text=True,
                          env=env, timeout=30, check=False)
    assert done.stdout.strip() == "unavailable", done


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def start_sshd(tmp: Path) -> subprocess.Popen[bytes] | None:
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    if not Path(sshd).exists() or not shutil.which("ssh"):
        return None
    for key in ("host_key", "client_key"):
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(tmp / key))
    shutil.copy(tmp / "client_key.pub", tmp / "authorized_keys")
    (tmp / "worker-home").mkdir()
    port = free_port()
    (tmp / "sshd_config").write_text(SSHD_CONFIG.format(port=port, tmp=tmp))
    user = run("id", "-un").stdout.strip()
    (tmp / "ssh_config").write_text(SSH_CONFIG.format(port=port, tmp=tmp, user=user))
    process = subprocess.Popen([sshd, "-D", "-e", "-f", str(tmp / "sshd_config")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    probe = ("ssh", "-F", str(tmp / "ssh_config"), "-o", "BatchMode=yes", "loopback-node", "true")
    if wait_for(lambda: run(*probe).returncode == 0, 5):
        return process
    process.kill()
    process.wait()
    return None


def make_fixture_kit(tmp: Path) -> tuple[Path, Path]:
    kit = tmp / "kit"
    kit.mkdir()
    start = kit / "start.sh"
    start.write_text(FIXTURE_START)
    start.chmod(0o755)
    git = ("git", "-C", str(kit), "-c", "user.name=t", "-c", "user.email=t@t")
    run("git", "init", "-q", str(kit))
    run(*git, "remote", "add", "origin", str(kit))
    run(*git, "add", "start.sh")
    assert run(*git, "commit", "-q", "-m", "fixture").returncode == 0
    sha_file = tmp / "kit.sha"
    sha_file.write_text(run(*git, "rev-parse", "HEAD").stdout.strip())
    return kit, sha_file


def script_env(tmp: Path, name: str, ssh_args: str, worker: str) -> dict[str, str]:
    kit, sha_file = tmp / "kit", tmp / "kit.sha"
    real_hf = {"ML_VENV": str(REAL_HF.parent.parent)} if REAL_HF else {}
    return {**os.environ, **real_hf, "HOME": str(tmp / "head-home"), "CONTAINER_NAME": name,
            "KIT_DIR": str(kit), "KIT_URL": str(kit), "KIT_SHA_FILE_OVERRIDE": str(sha_file),
            "WORKER": worker, "PEER": "loopback-node", "FABRIC_PEER": "127.0.0.1",
            "WORKER_WEIGHTS": "copy", "GUARD_SSH_ARGS": ssh_args, "FIXTURE_OUT": str(tmp),
            "FIXTURE_IMAGE": IMAGE, "FIXTURE_WORKER_HOME": str(tmp / "worker-home")}


def script(path: str, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    argv = script_argv(path, args)
    return subprocess.run(argv, capture_output=True, text=True, env=env, timeout=120, check=False)


def script_argv(path: str, args: tuple[str, ...]) -> list[str]:
    if path == "up.sh" and HELPER_ONLY:
        code = 'source "$1"; cd "$KIT_DIR"; shift; memory_guard_launch "$@"'
        return ["bash", "-c", code, "helper-test", str(WORKSPACE / "memory_guard.sh"), *args]
    return [str(WORKSPACE / path), *args]


def find_real_hf() -> Path | None:
    located = shutil.which("hf")
    candidates = [Path(located)] if located else []
    candidates += [Path(os.environ.get("ML_VENV", str(Path.home() / "venvs/ml"))) / "bin/hf"]
    candidates += list((Path.home() / ".local/share/uv/tools").glob("*/bin/hf"))
    for cli in candidates:
        if cli.is_file() and run(str(cli), "--version").returncode == 0:
            return cli.resolve()
    return None


def guards_of(name: str) -> int:
    return len(run("pgrep", "-f", f"[m]emory_guard.py --container {name}( |$)").stdout.split())


def clean_up_rank(name: str) -> None:
    run("pkill", "-f", f"[m]emory_guard.py --container {name}( |$)")
    remove_container(name)


def check_up_reports_unreachable_worker(tmp: Path) -> None:
    """Works with no sshd at all: nothing listens on port 1."""
    name = container_name()
    env = script_env(tmp, name, "-p 1", "127.0.0.1")
    try:
        done = script("up.sh", env)
        assert done.returncode == 1 and "UNGUARDED" in done.stderr, done
        assert not (tmp / "argv").exists(), "start.sh ran before both supervisors were ready"
    finally:
        clean_up_rank(name)


def check_up_passthrough_and_cases(tmp: Path) -> None:
    name = container_name()
    env = script_env(tmp, name, f"-F {tmp / 'ssh_config'}", "loopback-node")
    try:
        script("up.sh", {**env, "DRY_RUN": "1"}, "restart", "--parallel", "2")
        assert (tmp / "argv").read_text().split() == ["restart", "--parallel", "2"]
        names = {ln.split("=")[0] for ln in (tmp / "env").read_text().splitlines() if "=" in ln}
        assert {n for n in names if "GUARD" in n} == {"GUARD_SSH_ARGS"}, "guard leaked into start.sh"
        remove_container(name)
        assert guards_of(name) == 0, "DRY_RUN must start no guard"

        done = script("up.sh", {**env, "FIXTURE_NO_CONTAINER": "1"}, "help")
        assert done.returncode == 0 and "no container" in done.stdout, done

        done = script("up.sh", {**env, "FIXTURE_EXIT": "7"})
        assert done.returncode == 7, done
        assert guards_of(name) == 2, "a failed start can leave ranks up: they need guards"
    finally:
        clean_up_rank(name)


def check_up_and_down_over_ssh(tmp: Path) -> None:
    """Both node paths use real ssh/real Docker, sharing a host, with separate HOME."""
    name = container_name()
    env = script_env(tmp, name, f"-F {tmp / 'ssh_config'}", "loopback-node")
    head = tmp / "head-home/.cache/tensorfold-glm53/logs/memguard.log"
    worker = tmp / "worker-home/.cache/tensorfold-glm53/logs/memguard.log"
    try:
        done = script("up.sh", {**env, "FIXTURE_REPLACE": "1"})
        assert done.returncode == 0, done
        assert f"started: container {name}" in text(head), done
        assert f"started: container {name}" in text(worker), done
        assert (tmp / "worker-home/.cache/tensorfold-glm53/memory_guard.py").read_bytes() \
            == GUARD.read_bytes(), "the worker must run the same guard"
        ids = (tmp / "ids").read_text().splitlines()
        assert len(ids) == 2 and ids[0] != ids[1], ids
        for container_id in ids:
            assert f"id={container_id}," in text(head), text(head)
            assert f"id={container_id}," in text(worker), text(worker)
        assert (tmp / "guarded-before-return").exists()
        assert guards_of(name) == 2, f"expected two guards: {done}"
        done = script("down.sh", env)
        assert done.returncode == 0 and guards_of(name) == 0, done
        assert done.stdout.count("stopped") >= 2, done
        measured.append("startup/load fixture: both container IDs armed before return on both node paths; down stops both")
    finally:
        clean_up_rank(name)


def check_startup_interrupted(tmp: Path) -> None:
    name = container_name()
    marker = tmp / "guarded-before-return"
    marker.unlink(missing_ok=True)
    env = script_env(tmp, name, f"-F {tmp / 'ssh_config'}", "loopback-node")
    process = subprocess.Popen(script_argv("up.sh", ()), env={**env, "FIXTURE_HOLD": "1"},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert wait_for(marker.exists, 45), "start fixture did not reach guarded load"
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=30)
        assert process.returncode == 143, (stdout, stderr)
        assert "startup interrupted" in stderr and "guarding container id=" in stdout, (stdout, stderr)
        assert guards_of(name) == 2 and is_running(name)
        measured.append("startup interruption: exit 143, current IDs still guarded and reported")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
        clean_up_rank(name)


def check_failed_startup_handshake(tmp: Path) -> None:
    name = container_name()
    (tmp / "argv").unlink(missing_ok=True)
    env = script_env(tmp, name, f"-F {tmp / 'ssh_config'}", "loopback-node")
    try:
        done = script("up.sh", {**env, "DOCKER_HOST": "unix:///nonexistent/guard-test.sock"})
        assert done.returncode != 0 and "startup handshake failed" in done.stderr, done
        assert "memory guard on rank 0: supervisor ready" not in done.stdout, done
        assert not (tmp / "argv").exists(), "start.sh ran despite a failed startup inspection"
        assert guards_of(name) == 0
        measured.append("failed startup inspection: no ready acknowledgement, start fixture not executed")
    finally:
        clean_up_rank(name)


def docker_socket() -> Path | None:
    endpoint = os.environ.get("DOCKER_HOST")
    if not endpoint:
        endpoint = run("docker", "context", "inspect", "--format",
                       "{{.Endpoints.docker.Host}}").stdout.strip()
    return Path(endpoint.removeprefix("unix://")) if endpoint.startswith("unix://") else None


def check_daemon_failure_backoff(tmp: Path) -> None:
    target = docker_socket()
    if target is None:
        not_proven.append("Docker transport fault: this Docker context is not a Unix socket")
        return
    name, log = container_name(), tmp / "daemon-failure.log"
    link = tmp / "daemon.sock"
    link.symlink_to(target)
    env = {**os.environ, "DOCKER_HOST": f"unix://{link}"}
    start_container(name)
    guard = start_guard(name, log, "--soft-gib", TINY_GIB, "--hard-gib", TINY_GIB, env=env)
    try:
        link.unlink()  # Real Docker endpoint becomes unreachable, not a fake daemon.
        assert wait_for(lambda: "docker unavailable" in text(log), 8), text(log)
        time.sleep(3)
        assert text(log).count("docker unavailable") == 1, text(log)
        assert guard.poll() is None and is_running(name)
        link.symlink_to(target)
        assert run("docker", "stop", "-t", "0", name).returncode == 0
        assert guard.wait(12) == 0
        assert not KILL_LINE.search(text(log)), text(log)
        measured.append("real Docker endpoint removed/restored: monitor survives; unavailable logged once; ordinary stop not a kill")
    finally:
        stop_guard(guard)
        remove_container(name)
        link.unlink(missing_ok=True)


def failed_kill_recovery(tmp: Path, attempt: int) -> bool:
    target = docker_socket()
    assert target is not None
    name, log = container_name(), tmp / f"unconfirmed-{attempt}.log"
    link = tmp / f"unconfirmed-{attempt}.sock"
    link.symlink_to(target)
    start_container(name)
    floor = mem_available_gib() - 1
    env = {**os.environ, "DOCKER_HOST": f"unix://{link}"}
    guard = start_guard(name, log, "--soft-gib", str(floor), "--hard-gib", TINY_GIB,
                        "--sustain-s", "0.2", env=env)
    try:
        link.unlink()
        blob = b"\x01" * DIP_BYTES
        attempted = wait_for(lambda: "kill unconfirmed" in text(log), 4)
        time.sleep(2)
        del blob
        if not attempted or not wait_for(lambda: mem_available_gib() > floor + 0.5, 5):
            return False
        assert wait_for(lambda: "recovered: no kill" in text(log), 4), text(log)
        assert text(log).count("retrying with backoff") == 1, text(log)
        link.symlink_to(target)
        assert run("docker", "stop", "-t", "0", name).returncode == 0
        assert guard.wait(12) == 0
        assert not KILL_LINE.search(text(log)), text(log)
        measured.append("failed kill -> live-memory recovery -> ordinary stop: no false kill line")
        return True
    finally:
        stop_guard(guard)
        remove_container(name)
        link.unlink(missing_ok=True)


def check_failed_kill_recovery(tmp: Path) -> None:
    if docker_socket() is None or mem_available_gib() < 8:
        not_proven.append("failed kill/recovery: needs a Unix Docker socket and 8 GiB available")
        return
    if not any(failed_kill_recovery(tmp, attempt) for attempt in range(3)):
        not_proven.append("failed kill/recovery: live host memory did not allow a valid dip")


def check_wiring(tmp: Path) -> None:
    global REAL_HF, HELPER_ONLY
    REAL_HF = find_real_hf()
    needs_hf = "command -v hf" in (WORKSPACE / "up.sh").read_text()
    HELPER_ONLY = needs_hf and REAL_HF is None
    if HELPER_ONLY:
        not_proven.append("integrated up.sh wrapper: actual hf CLI absent; real lifecycle helper tested directly")
    if run("docker", "container", "inspect", REAL_CONTAINER).returncode == 0:
        not_proven.append(f"wiring: a real {REAL_CONTAINER} exists; fallback would remove it")
        return
    make_fixture_kit(tmp)
    check_up_reports_unreachable_worker(tmp)
    sshd = start_sshd(tmp)
    if sshd is None:
        not_proven.append("worker/startup wiring over ssh: no usable sshd here")
        return
    try:
        (tmp / "argv").unlink(missing_ok=True)
        check_up_passthrough_and_cases(tmp)
        (tmp / "ids").unlink(missing_ok=True)
        check_up_and_down_over_ssh(tmp)
        check_startup_interrupted(tmp)
        check_failed_startup_handshake(tmp)
    finally:
        sshd.kill()
        sshd.wait()


def docker_problem() -> str | None:
    if not shutil.which("docker"):
        return "docker is not installed"
    if run("docker", "info").returncode != 0:
        return "docker is not reachable"
    if run("docker", "image", "inspect", IMAGE).returncode == 0:
        return None
    return None if run("docker", "pull", "-q", IMAGE, timeout=240).returncode == 0 \
        else f"image {IMAGE} is absent and cannot be pulled"


def main() -> int:
    check_refuses_bad_arguments()
    check_defaults_and_wiring()
    check_dead_docker_is_not_a_gone_container()
    problem = docker_problem()
    if problem:
        print(f"memory-guard: NOT PROVEN - every kill, dip and exit check: {problem}")
        return 0
    with tempfile.TemporaryDirectory(prefix="memory-guard-") as folder:
        tmp = Path(folder)
        check_missing_container_fails_fast(tmp)
        check_soft_floor_kills(tmp)
        check_hard_floor_kills_at_once(tmp)
        check_full_disk_does_not_stop_a_kill()
        check_survives_near_zero_floors(tmp)
        check_brief_dip_recovers(tmp)
        check_exits_when_container_goes(tmp)
        check_restart_is_not_blocked(tmp)
        check_daemon_failure_backoff(tmp)
        check_failed_kill_recovery(tmp)
        check_wiring(tmp)
    print("memory-guard: real-container kill/survival/exit checks completed; "
          "transport, startup and wrapper evidence follows; exclusions are NOT PROVEN")
    for line in measured:
        print(f"memory-guard: measured - {line}")
    for line in not_proven:
        print(f"memory-guard: NOT PROVEN - {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
