#!/usr/bin/env python3
"""Real elevated fallback on one test-owned root container; never signals inference."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import ModuleType
import uuid


def load_guard(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("real_guard_root_gate", path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def prove_fallback(guard: ModuleType, cid: str, folder: Path) -> None:
    log_path = folder / "root-fallback.log"
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    previous = {key: os.environ.get(key) for key in ("DOCKER_HOST", "DOCKER_CONTEXT")}
    try:
        binding = guard.bind_process(guard.SYSTEM_SIGNAL_HELPER, cid, descriptor)
        assert binding is not None, log_path.read_text()
        fd = os.pidfd_open(binding.pid)
        try:
            try:
                signal.pidfd_send_signal(fd, 0)
            except PermissionError:
                pass
            else:
                raise AssertionError("caller already has signal permission; sudo path is not proven")
        finally:
            os.close(fd)
        os.environ["DOCKER_HOST"] = "unix://" + str(folder / "not-listening.sock")
        os.environ.pop("DOCKER_CONTEXT", None)
        assert guard.kill("test-owned-root-container", cid, "isolated sudo gate", False, descriptor, binding)
        assert guard.process_alive(binding) is False
        assert "pidfd exit confirmed" in log_path.read_text(), log_path.read_text()
        print(json.dumps({"result": "PASS", "container_id": cid, "pid": binding.pid,
                          "docker_socket_unavailable": True, "unprivileged_signal_denied": True,
                          "fixed_root_helper_exit_confirmed": True}))
    finally:
        for key, value in previous.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value
        os.close(descriptor)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guard", required=True, type=Path)
    parser.add_argument("--image", required=True, help="Already cached, authorized local image; never pulled")
    args = parser.parse_args()
    assert os.geteuid() != 0, "Run as the normal operator, not with sudo"
    guard = load_guard(args.guard.resolve(strict=True))
    assert guard.trusted_system_helper(guard.SYSTEM_SIGNAL_HELPER), "fixed root-owned helper is not installed safely"
    name = "gx10-guard-test-root-" + uuid.uuid4().hex[:10]
    cid = subprocess.check_output([
        "docker", "run", "--pull=never", "-d", "--name", name, "--user", "0:0", "--network", "none",
        "--memory", "64m", "--cpus", "0.1", "--pids-limit", "32", "-e", "NVIDIA_VISIBLE_DEVICES=void",
        "-e", "CUDA_VISIBLE_DEVICES=", "--entrypoint", "python3", args.image,
        "-I", "-B", "-c", "import time; time.sleep(120)",
    ], text=True, timeout=60).strip()
    try:
        with tempfile.TemporaryDirectory(dir=args.guard.resolve().parent, prefix="root-gate-") as folder:
            prove_fallback(guard, cid, Path(folder))
    finally:
        subprocess.run(["docker", "rm", "-f", cid], check=True, timeout=45, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
