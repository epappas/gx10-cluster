#!/usr/bin/env python3
"""Real Docker/host-process checks; only disposable, test-owned containers are signalled."""
from __future__ import annotations

from contextlib import contextmanager
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from typing import Iterator
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / "workspaces/inference/tensorfold-2node-glm53-flash-exl3"
HELPER = WORKSPACE / "container_signal.py"
SPEC = importlib.util.spec_from_file_location("real_memory_guard", WORKSPACE / "memory_guard.py")
assert SPEC is not None and SPEC.loader is not None
GUARD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GUARD
SPEC.loader.exec_module(GUARD)
IMAGE = os.environ.get("MEMORY_GUARD_IMAGE", "python:3-alpine")


class GuardFallbackChecks(unittest.TestCase):
    def setUp(self) -> None:
        private = ROOT / ".private-publication"
        private.mkdir(mode=0o700, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=private, prefix="guard-fallback-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.log_path = self.folder / "guard.log"
        self.log = os.open(self.log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.addCleanup(os.close, self.log)
        self.name = "gx10-guard-test-fallback-" + uuid.uuid4().hex[:10]
        self.cid = subprocess.check_output([
            "docker", "run", "--pull=never", "-d", "--name", self.name,
            "--user", f"{os.getuid()}:{os.getgid()}", "--network", "none", "--memory", "64m",
            "--cpus", "0.1", "--pids-limit", "32", IMAGE, "sleep", "180",
        ], text=True, timeout=60).strip()
        self.addCleanup(subprocess.run, ["docker", "rm", "-f", self.cid],
                        check=True, stdout=subprocess.DEVNULL, timeout=45)
        self.binding = GUARD.bind_process(HELPER, self.cid, self.log)
        self.assertIsNotNone(self.binding, self.log_path.read_text())

    @contextmanager
    def unavailable_docker(self) -> Iterator[None]:
        previous = {key: os.environ.get(key) for key in ("DOCKER_HOST", "DOCKER_CONTEXT")}
        os.environ["DOCKER_HOST"] = "unix://" + str(self.folder / "not-listening.sock")
        os.environ.pop("DOCKER_CONTEXT", None)
        try:
            yield
        finally:
            for key, value in previous.items():
                os.environ.pop(key, None)
                if value is not None:
                    os.environ[key] = value

    def test_actual_unavailable_daemon_uses_confirmed_pidfd_exit(self) -> None:
        with self.unavailable_docker():
            result = GUARD.kill(self.name, self.cid, "isolated gate", False, self.log, self.binding)
        self.assertTrue(result, self.log_path.read_text())
        self.assertIs(GUARD.process_alive(self.binding), False)
        text = self.log_path.read_text()
        self.assertIn("pidfd exit confirmed", text)
        self.assertEqual(text.count("killed container " + self.name), 1)

    def test_bad_cached_binding_cannot_kill_the_live_target(self) -> None:
        wrong = GUARD.ProcessBinding(HELPER, "0" * 64, self.binding.pid,
                                     self.binding.start_ticks, self.binding.boot_id)
        with self.unavailable_docker():
            self.assertFalse(GUARD.kill(self.name, self.cid, "bad identity gate", False, self.log, wrong))
        self.assertIs(GUARD.process_alive(self.binding), True)
        self.assertNotIn("killed container " + self.name, self.log_path.read_text())

    def test_healthy_actual_memory_does_not_signal_workload(self) -> None:
        self.assertGreater(GUARD.mem_available_kib(), 5 * GUARD.KIB_PER_GIB,
                           "real healthy-memory gate requires at least five GiB available")
        args = GUARD.parse_args(["--container", self.name, "--log", str(self.log_path),
                                 "--signal-helper", str(HELPER)])
        done = threading.Event()
        thread = threading.Thread(target=GUARD.guard, args=(args, self.cid, done, self.log, self.binding))
        thread.start()
        try:
            done.wait(0.5)
            self.assertIs(GUARD.process_alive(self.binding), True)
            self.assertNotIn("killed container " + self.name, self.log_path.read_text())
        finally:
            done.set()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())

    def test_unavailable_docker_does_not_end_kernel_bound_supervision(self) -> None:
        done = threading.Event()
        with self.unavailable_docker():
            thread = threading.Thread(target=GUARD.watch, args=(self.name, self.cid, done, self.log, self.binding))
            thread.start()
            try:
                self.assertFalse(done.wait(1))
                self.assertIs(GUARD.process_alive(self.binding), True)
            finally:
                done.set()
                thread.join(timeout=7)
                self.assertFalse(thread.is_alive())

    def test_real_metadata_absence_does_not_hide_live_cached_process(self) -> None:
        subprocess.run(["docker", "rename", self.name, self.name + "-renamed"], check=True, timeout=30)
        done = threading.Event()
        thread = threading.Thread(target=GUARD.watch, args=(self.name, self.cid, done, self.log, self.binding))
        thread.start()
        try:
            self.assertFalse(done.wait(1))
            self.assertIs(GUARD.process_alive(self.binding), True)
            result = GUARD.signal_helper(HELPER, self.binding.arguments("kill"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(done.wait(7))
        finally:
            done.set()
            thread.join(timeout=7)
            self.assertFalse(thread.is_alive())

    def test_user_writable_helper_is_never_trusted_for_sudo(self) -> None:
        self.assertFalse(GUARD.trusted_system_helper(HELPER))
        self.assertFalse(GUARD.trusted_system_helper(self.folder / "pretend-system-helper"))
        self.assertIs(GUARD.process_alive(self.binding), True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
