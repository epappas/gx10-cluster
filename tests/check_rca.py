#!/usr/bin/env python3
"""Real-host checks for bounded, private gx10-rca evidence collection."""
from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "roles/monitoring/files/gx10-rca"
LOADER = SourceFileLoader("gx10_rca", str(TOOL))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None:
    raise ImportError(f"cannot load {TOOL}")
RCA = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = RCA
LOADER.exec_module(RCA)


def keys(value: object) -> set[str]:
    if isinstance(value, dict):
        return {str(key) for key in value} | set().union(*(keys(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(keys(item) for item in value))
    return set()


class RcaChecks(unittest.TestCase):
    def test_real_local_capture_schema_privacy_and_private_output(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", str(TOOL), "--local", "--json", "--command-timeout", "2",
             "--max-output-bytes", "1024"], capture_output=True, text=True, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertEqual(evidence["schema_version"], 1)
        self.assertEqual(evidence["kit"], "tensorfold-glm53")
        self.assertEqual(evidence["container"], "glm53-flash-tf")
        self.assertRegex(evidence["files"]["host_boot_id"]["output"], r"^[0-9a-f-]{36}$")
        memory = evidence["files"]["memory"]
        self.assertEqual(memory["status"], "ok", memory)
        self.assertIn("MemTotal:", memory["output"])
        self.assertIn("MemAvailable:", memory["output"])
        pressure = evidence["files"]["memory_pressure"]
        self.assertEqual(pressure["status"], "ok", pressure)
        self.assertRegex(pressure["output"], r"(?m)^some\s")
        for name in ("kernel_current", "kernel_previous", "docker_current", "docker_previous",
                     "journal_boot_list", "journal_disk_usage", "docker_inspect", "gpu_telemetry"):
            self.assertIn(name, evidence["commands"])
        self.assertIn("memory_pressure", evidence["files"])
        self.assertIn("guard_tail", evidence["files"])
        self.assertIn("journal_persistence", evidence)
        self.assertFalse(evidence["engine_logs_sensitive_opt_in"])
        self.assertNotIn("engine_logs_sensitive_opt_in", evidence["commands"])
        private_keys = {"container_env", "environment", "full_env", "tmux", "engine_logs", "customer_logs", "core_dumps"}
        self.assertTrue(private_keys.isdisjoint(keys(evidence)))
        command_text = " ".join(part for command in evidence["commands"].values()
                                 for part in command["command"])
        self.assertNotIn("docker logs", command_text)
        for command in evidence["commands"].values():
            self.assertIn("exit_code", command)
            self.assertIn("process_reaped", command)
            self.assertIn("output_truncated", command)

        self.assert_private_output(evidence)
        if shutil.which("docker"):
            self.assertEqual(evidence["commands"]["docker_inspect"]["command"][0], "docker")
            self.assertIsInstance(evidence["commands"]["docker_inspect"]["exit_code"], int)
        if shutil.which("journalctl"):
            self.assertTrue(evidence["commands"]["journal_boot_list"]["command"][0].endswith("journalctl"))

    def assert_private_output(self, evidence: RCA.Evidence) -> None:
        with tempfile.TemporaryDirectory(prefix="gx10-rca-gate-") as temporary:
            parent = Path(temporary)
            output = RCA.create_output_dir(parent / "capture")
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            saved = RCA.write_evidence(output, evidence)
            self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o600)
            self.assertEqual(json.loads(saved.read_text()), evidence)
            with self.assertRaises(FileExistsError):
                RCA.create_output_dir(output)
            existing = parent / "existing"
            existing.mkdir(mode=0o700)
            with self.assertRaises(FileExistsError):
                RCA.create_output_dir(existing)
            link = parent / "linked"
            link.symlink_to(parent / "existing", target_is_directory=True)
            with self.assertRaises(FileExistsError):
                RCA.create_output_dir(link)

    def test_actual_missing_command_and_unsupported_journal_are_findings(self) -> None:
        with tempfile.TemporaryDirectory(prefix="gx10-rca-missing-") as temporary:
            absent = str(Path(temporary) / "not-installed")
            missing: dict[str, RCA.CommandResult] = {}
            findings: list[RCA.Finding] = []
            RCA.record_command(missing, findings, "absent", [absent], 1.0, 1024)
            self.assertIsNone(missing["absent"]["exit_code"])
            self.assertIn("unavailable", {item["kind"] for item in findings})

        commands: dict[str, RCA.CommandResult] = {}
        findings = []
        RCA.record_command(commands, findings, "unsupported_journal",
                           ["journalctl", "--gx10-rca-not-a-real-option"], 2.0, 1024)
        self.assertTrue(commands["unsupported_journal"]["exit_code"] is None
                        or commands["unsupported_journal"]["exit_code"] != 0)
        self.assertTrue(findings, "unsupported or unavailable journalctl must be a finding")

    def test_real_child_timeout_and_bounded_output(self) -> None:
        slow = RCA.run_command([sys.executable, "-I", "-c", "import time; time.sleep(3)"], 0.1, 1024)
        self.assertTrue(slow["timed_out"])
        self.assertTrue(slow["process_reaped"])
        self.assertIsNotNone(slow["exit_code"])

        started = time.monotonic()
        blocked_input = RCA.run_command(
            [sys.executable, "-I", "-c", "import time; time.sleep(2)"], 0.1, 1024,
            b"x" * (1024 * 1024),
        )
        self.assertTrue(blocked_input["timed_out"])
        self.assertTrue(blocked_input["process_reaped"])
        self.assertLess(time.monotonic() - started, 0.75)

        noisy = RCA.run_command([sys.executable, "-I", "-c", "print('x' * 5000)"], 5.0, 1024)
        self.assertEqual(noisy["exit_code"], 0)
        self.assertTrue(noisy["output_truncated"])
        self.assertEqual(len(noisy["output"].encode()), 1024)
        self.assertGreater(noisy["output_bytes"], 1024)

    def test_fifo_is_rejected_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory(prefix="gx10-rca-fifo-") as temporary:
            fifo = Path(temporary) / "log.fifo"
            os.mkfifo(fifo)
            started = time.monotonic()
            result = RCA.read_bounded(fifo, 1024)
            self.assertLess(time.monotonic() - started, 0.5)
            self.assertEqual(result["status"], "not_regular_file")

    def test_selection_rejects_path_and_ssh_injection(self) -> None:
        for kit, container, peer in (("../logs", "glm53-flash-tf", None),
                                     ("tensorfold-glm53", "name;id", None),
                                     ("tensorfold-glm53", "glm53-flash-tf", "-oProxyCommand=bad"),
                                     ("tensorfold-glm53", "glm53-flash-tf", "-F@poseidon")):
            with self.subTest(kit=kit, container=container, peer=peer):
                with self.assertRaises(ValueError):
                    RCA.validate_selection(kit, container, peer)
        host = "operator@poseidon"
        RCA.validate_selection("dsv41-tensorfold", "dsv41-1017-exl3-tf", host)
        ssh = RCA.ssh_argv(host, ["python3", "-I", "-", "--local", "--json"])
        self.assertEqual(ssh[-3], "--")
        self.assertEqual(ssh[-2], host)


    def test_report_is_read_only_readable_and_rejects_unsafe_inputs(self) -> None:
        evidence = RCA.collect_local("tensorfold-glm53", "glm53-flash-tf", 1.0, 1024, False, False)
        evidence["commands"]["docker_inspect"]["output"] += "\n\x1b[2J\u009bcontrol-test"
        with tempfile.TemporaryDirectory(prefix="gx10-rca-report-") as temporary:
            folder = Path(temporary)
            saved = RCA.write_evidence(folder, evidence)
            result = subprocess.run([sys.executable, "-I", "-B", str(TOOL), "--report", str(saved)],
                                    capture_output=True, text=True, timeout=5,
                                    env={**os.environ, "PATH": str(folder / "no-commands")})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("HOST:", result.stdout)
            self.assertIn("kernel_previous", result.stdout)
            self.assertIn("observations, not a root-cause verdict", result.stdout)
            self.assertNotIn("\x1b", result.stdout)
            self.assertNotIn("\u009b", result.stdout)
            for extra in (["--sudo"], ["--peer", "poseidon"], ["--output", str(folder / "new")]):
                conflict = subprocess.run([sys.executable, "-I", "-B", str(TOOL), "--report", str(saved), *extra],
                                          capture_output=True, text=True, timeout=5)
                self.assertNotEqual(conflict.returncode, 0)
            invalid = folder / "invalid.json"
            invalid.write_text("not JSON")
            fifo = folder / "fifo"
            os.mkfifo(fifo)
            for path in (invalid, fifo):
                rejected = subprocess.run([sys.executable, "-I", "-B", str(TOOL), "--report", str(path)],
                                          capture_output=True, text=True, timeout=2)
                self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
