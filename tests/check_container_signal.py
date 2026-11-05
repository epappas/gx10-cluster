#!/usr/bin/env python3
"""Exercise actual pidfds and only test-owned local Docker containers; no GPU use."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "workspaces/inference/tensorfold-2node-glm53-flash-exl3/container_signal.py"
IMAGE = os.environ.get("MEMORY_GUARD_IMAGE", "python:3-alpine")


class ContainerSignalChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.containers: list[str] = []

    def tearDown(self) -> None:
        for cid in self.containers:
            subprocess.run(["docker", "rm", "-f", cid], check=True,
                           stdout=subprocess.DEVNULL, timeout=45)

    def container(self, root: bool = False) -> dict[str, Any]:
        name = "gx10-guard-test-pidfd-" + uuid.uuid4().hex[:10]
        uid = "0:0" if root else f"{os.getuid()}:{os.getgid()}"
        cid = subprocess.check_output([
            "docker", "run", "--pull=never", "-d", "--name", name, "--user", uid, "--network", "none",
            "--memory", "64m", "--cpus", "0.1", "--pids-limit", "32", IMAGE, "sleep", "180",
        ], text=True, timeout=60).strip()
        self.containers.append(cid)
        value = json.loads(subprocess.check_output(["docker", "inspect", cid], text=True, timeout=30))[0]
        result = self.call("inspect", {"container_id": cid, "pid": value["State"]["Pid"]})
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def call(self, action: str, value: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, "-I", "-B", str(HELPER), action]
        for name, item in value.items():
            command.extend(["--" + name.replace("_", "-"), str(item)])
        return subprocess.run(command, text=True, capture_output=True, timeout=10)

    def assert_alive(self, identity: dict[str, Any]) -> None:
        result = self.call("check", identity)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "alive")

    def test_inspect_and_healthy_check_do_not_kill(self) -> None:
        self.assert_alive(self.container())

    def test_real_pidfd_kill_is_confirmed_and_repeat_is_not_killed(self) -> None:
        identity = self.container()
        result = self.call("kill", identity)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "killed")
        repeated = self.call("kill", identity)
        self.assertEqual(repeated.returncode, 3, repeated.stdout + repeated.stderr)
        self.assertEqual(json.loads(repeated.stdout)["state"], "exited")

    def test_wrong_identity_cannot_signal_live_target(self) -> None:
        identity = self.container()
        changes = {"container_id": "0" * 64, "start_ticks": identity["start_ticks"] + 1,
                   "boot_id": str(uuid.uuid4())}
        for key, value in changes.items():
            with self.subTest(field=key):
                wrong = {**identity, key: value}
                result = self.call("kill", wrong)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["state"], "refused")
                self.assert_alive(identity)

    def test_unrelated_host_process_is_never_a_container_target(self) -> None:
        identity = self.container()
        child = subprocess.Popen([sys.executable, "-I", "-B", "-c", "import time; time.sleep(120)"])
        try:
            result = self.call("inspect", {"container_id": identity["container_id"], "pid": child.pid})
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("cgroup", result.stdout)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait(timeout=10)
        self.assert_alive(identity)

    def test_pid_one_and_malformed_ids_are_refused(self) -> None:
        for value in ({"container_id": "0" * 64, "pid": 1},
                      {"container_id": "not-a-container", "pid": os.getpid()}):
            with self.subTest(value=value):
                result = self.call("inspect", value)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["state"], "refused")

    def test_real_permission_denial_does_not_become_success(self) -> None:
        self.assertNotEqual(os.geteuid(), 0, "Run as a normal user to prove permission denial")
        identity = self.container(root=True)
        result = self.call("kill", identity)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "permission-denied")
        self.assert_alive(identity)

    def test_target_exiting_without_signal_is_reported_as_exited(self) -> None:
        identity = self.container()
        subprocess.run(["docker", "stop", "--time", "1", identity["container_id"]], check=True,
                       stdout=subprocess.DEVNULL, timeout=30)
        result = self.call("check", identity)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "exited")


if __name__ == "__main__":
    unittest.main(verbosity=2)
