#!/usr/bin/env python3
"""Real ARM-image state-unit gates. No model initialization or GPU fault injection."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Generator
import unittest

from tensorfold.cuda import health
from tensorfold.cuda.server import App
from tensorfold.families.glm5_next.cuda import multi
from tensorfold.families.glm5_next.cuda.engine import GlmEngine
from tensorfold.families.glm5_next.cuda.sliced_fill import PendingFill
from tensorfold.server import metrics


def decoder() -> multi.MultiDecoder:
    value = object.__new__(multi.MultiDecoder)
    value.broken = None
    value.exit_on_broken = False
    value.lanes = {}
    value.partial = None
    return value


def application(value: multi.MultiDecoder | None) -> App:
    scheduler = object.__new__(multi.GlmScheduler)
    scheduler.decoder = value
    scheduler.max_streams = 4
    engine = object.__new__(GlmEngine)
    engine.scheduler = scheduler
    app = object.__new__(App)
    app.engine = engine
    app.context_window = 1048576
    return app


class BrokenHealthChecks(unittest.TestCase):
    def test_first_error_identity(self) -> None:
        value = decoder()
        original = RuntimeError("first state-unit failure")
        value._break(original)
        value._break(ValueError("later failure"))
        self.assertIs(value.broken, original)

    def test_latch_precedes_real_pending_fill_cleanup_failure(self) -> None:
        value = decoder()

        def steps() -> Generator[None, None, None]:
            try:
                yield
            finally:
                self.assertIsNotNone(value.broken, "cleanup ran before the broken latch")
                raise RuntimeError("state-unit cleanup failure")

        pending = PendingFill([])
        pending.steps = steps()
        next(pending.steps)
        value.partial = pending
        with self.assertRaisesRegex(RuntimeError, "state-unit cleanup failure"):
            value.drop()
        self.assertIsInstance(value.broken, RuntimeError)
        self.assertEqual(str(value.broken), "an iteration failed")

    def test_exit_parser_positive_negative_and_actual_environment(self) -> None:
        for raw in ("", "0", " 0 "):
            self.assertFalse(multi.exit_on_broken(raw))
        self.assertTrue(multi.exit_on_broken(" 1 "))
        for raw in ("true", "-1", "2"):
            with self.assertRaises(ValueError):
                multi.exit_on_broken(raw)
        previous = os.environ.pop("TF_GLM_EXIT_ON_BROKEN", None)
        try:
            self.assertFalse(multi.exit_on_broken())
            os.environ["TF_GLM_EXIT_ON_BROKEN"] = "1"
            self.assertTrue(multi.exit_on_broken())
        finally:
            os.environ.pop("TF_GLM_EXIT_ON_BROKEN", None)
            if previous is not None:
                os.environ["TF_GLM_EXIT_ON_BROKEN"] = previous

    def test_healthy_snapshot_and_actual_metric(self) -> None:
        app = application(None)
        self.assertIs(health.of(app).snapshot(app)["ok"], True)
        lines: list[str] = []
        metrics._health(lines, app)
        self.assertIn(metrics.HEALTH + "ok 1", lines)

    def test_broken_snapshot_survives_actual_counter_failure(self) -> None:
        value = decoder()
        with self.assertRaises(AttributeError):
            value.health()
        value.broken = RuntimeError("x" * 400)
        app = application(value)
        body = health.of(app).snapshot(app)
        self.assertIs(body["ok"], False)
        self.assertEqual(body["broken"], "RuntimeError: " + "x" * 200)
        lines: list[str] = []
        metrics._health(lines, app)
        self.assertIn(metrics.HEALTH + "ok 0", lines)

    def test_real_process_exit_not_an_import_failure(self) -> None:
        code = "\n".join((
            "from tensorfold.families.glm5_next.cuda.multi import MultiDecoder",
            "value = object.__new__(MultiDecoder)",
            "value.broken = None",
            "value.exit_on_broken = True",
            "value._break(RuntimeError('state-unit subprocess failure'))",
            "raise AssertionError('os._exit did not terminate the process')",
        ))
        result = subprocess.run([sys.executable, "-I", "-B", "-c", code],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("TF_GLM_EXIT_ON_BROKEN=1: exiting with code 1", result.stderr)
        self.assertIn("state-unit subprocess failure", result.stderr)


if __name__ == "__main__":
    modules = (multi, health, metrics)
    print(json.dumps({"scope": "Complete real modules, constructor-bypassed state inputs; NOT GPU fault proof",
                      "modules": {str(module.__file__): hashlib.sha256(
                          Path(module.__file__).read_bytes()).hexdigest() for module in modules}}), flush=True)
    unittest.main(verbosity=2)
