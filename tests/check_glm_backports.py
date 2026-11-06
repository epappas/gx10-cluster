#!/usr/bin/env python3
"""Exercise the complete real GLM kept-reasoning module, without a model backend."""
from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from types import FrameType, ModuleType
from typing import Any
import unittest

MODULE_PATH = Path("tensorfold/families/glm5_next/cuda/kept_reasoning.py")


def load_module(source_root: Path) -> ModuleType:
    path = (source_root / MODULE_PATH).resolve(strict=True)
    spec = importlib.util.spec_from_file_location("verified_kept_reasoning", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if Path(module.__file__).resolve() != path:
        raise ImportError("loaded a different kept-reasoning module")
    return module


def tool_calls(cid: str | None = None, a: int = 19) -> list[dict[str, Any]]:
    call: dict[str, Any] = {
        "type": "function",
        "function": {"name": "add", "arguments": json.dumps({"a": a, "b": 23})},
    }
    if cid is not None:
        call["id"] = cid
    return [call]


def assistant(calls: list[dict[str, Any]]) -> dict[str, Any]:
    return {"role": "assistant", "content": "", "tool_calls": calls}


def actual_work(module: ModuleType, steps: int) -> int:
    store = module.KeptReasoning()
    store.remember([], tool_calls("unrelated", -1), "Unrelated reasoning.")
    messages: list[dict[str, Any]] = [{"role": "user", "content": "Start."}]
    for index in range(steps):
        cid = f"client-{index}"
        messages.extend([assistant(tool_calls(cid, index)), {
            "role": "tool", "tool_call_id": cid, "content": "result"}])
    count = 0
    target = module._calls.__code__

    def profile(frame: FrameType, event: str, argument: Any) -> None:
        nonlocal count
        if event == "call" and frame.f_code is target:
            count += 1

    previous = sys.getprofile()
    try:
        sys.setprofile(profile)
        restored = store.restore(messages)
    finally:
        sys.setprofile(previous)
    if restored is not messages:
        raise AssertionError("unrelated reasoning matched the measured history")
    return count


class KeptReasoningChecks(unittest.TestCase):
    module: ModuleType
    source_root: Path

    def setUp(self) -> None:
        self.history: list[dict[str, Any]] = [{"role": "user", "content": "Add."}]
        self.calls = tool_calls("call_" + "a" * 24)
        self.store = self.module.KeptReasoning()
        self.store.remember(self.history, self.calls, "Use the actual add result.")

    def request(self, with_id: bool = False) -> list[dict[str, Any]]:
        calls = deepcopy(self.calls)
        if not with_id:
            del calls[0]["id"]
        return deepcopy(self.history) + [assistant(calls)]

    def test_server_id_precedence_and_copy_semantics(self) -> None:
        messages = self.request(True)
        before = deepcopy(messages)
        restored = self.store.restore(messages)
        self.assertEqual(restored[-1]["reasoning_content"], "Use the actual add result.")
        self.assertIsNot(restored, messages)
        self.assertIsNot(restored[-1], messages[-1])
        self.assertIs(restored[0], messages[0])
        self.assertEqual(messages, before)
        messages[0]["content"] = "Changed but the trusted server ID still matches."
        self.assertIn("reasoning_content", self.store.restore(messages)[-1])

    def test_stripped_id_and_equivalent_serialization(self) -> None:
        messages = self.request()
        messages[0]["content"] = "  Add.\n"
        messages[-1]["tool_calls"][0]["function"]["arguments"] = '{"b":23,"a":19}'
        self.assertIn("reasoning_content", self.store.restore(messages)[-1])
        messages[-1]["tool_calls"][0]["id"] = "client-renumbered"
        self.assertIn("reasoning_content", self.store.restore(messages)[-1])

    def test_changed_history_or_call_does_not_restore_without_server_id(self) -> None:
        for change in ("history", "name", "arguments"):
            with self.subTest(change=change):
                messages = self.request()
                function = messages[-1]["tool_calls"][0]["function"]
                if change == "history":
                    messages[0]["content"] = "Another conversation."
                elif change == "name":
                    function["name"] = "subtract"
                else:
                    function["arguments"] = '{"a":20,"b":23}'
                self.assertIs(self.store.restore(messages), messages)

    def test_changed_prior_tool_result_or_arguments_do_not_restore(self) -> None:
        history = self.history + [assistant(tool_calls("prior", 1)), {
            "role": "tool", "tool_call_id": "prior", "content": "24"}]
        self.store.remember(history, self.calls, "Reasoning for this chain.")
        for changed in ("prior_result", "prior_arguments"):
            messages = deepcopy(history) + [assistant(tool_calls())]
            if changed == "prior_result":
                messages[-2]["content"] = "25"
            else:
                messages[-3]["tool_calls"][0]["function"]["arguments"] = '{"a":2,"b":23}'
            self.assertIs(self.store.restore(messages), messages)

    def test_existing_reasoning_is_not_overwritten(self) -> None:
        for field in ("reasoning_content", "reasoning", "content"):
            messages = self.request()
            value = "<think>Already present.</think>" if field == "content" else "Already present."
            messages[-1][field] = value
            self.assertIs(self.store.restore(messages), messages)
        messages = self.request()
        messages[-1]["reasoning_content"] = " \n"
        self.assertIn("Use the actual", self.store.restore(messages)[-1]["reasoning_content"])

    def test_empty_and_non_list_inputs_are_unchanged(self) -> None:
        for value in (None, "text", {}, []):
            self.assertIs(self.store.restore(value), value)
        empty = self.module.KeptReasoning()
        messages = self.request()
        self.assertIs(empty.restore(messages), messages)

    def test_invalid_or_oversize_reasoning_is_not_remembered(self) -> None:
        store = self.module.KeptReasoning(chars=4)
        for value in (None, "", "  ", "12345", 42):
            store.remember(self.history, self.calls, value)
        self.assertEqual(len(store), 0)
        store.remember(self.history, self.calls, "éé")
        self.assertEqual(len(store), 1)

    def test_zero_entries_and_character_budget(self) -> None:
        store = self.module.KeptReasoning(entries=0)
        store.remember(self.history, self.calls, "reasoning")
        self.assertEqual(len(store), 0)
        store = self.module.KeptReasoning(entries=10, chars=5)
        store.remember(self.history, tool_calls("first"), "123")
        other = [{"role": "user", "content": "Other."}]
        store.remember(other, tool_calls("second"), "456")
        self.assertEqual(len(store), 1)
        messages = self.request()
        self.assertIs(store.restore(messages), messages)

    def test_lru_touch_and_repeated_key_eviction(self) -> None:
        store = self.module.KeptReasoning(entries=2)
        histories = [[{"role": "user", "content": name}] for name in ("a", "b", "c")]
        calls = [tool_calls("call_" + name * 24) for name in ("a", "b", "c")]
        store.remember(histories[0], calls[0], "first")
        store.remember(histories[1], calls[1], "second")
        store.restore(histories[0] + [assistant(calls[0])])
        store.remember(histories[2], calls[2], "third")
        rejected = histories[1] + [assistant(calls[1])]
        self.assertIs(store.restore(rejected), rejected)
        store = self.module.KeptReasoning(entries=2)
        store.remember(self.history, self.calls, "old")
        store.remember(self.history, self.calls, "new")
        store.remember(histories[2], calls[2], "third")
        self.assertEqual(store.restore(self.request(True))[-1]["reasoning_content"], "new")

    def env_result(self, settings: dict[str, str]) -> subprocess.CompletedProcess[str]:
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("TF_GLM_KEEP_REASONING", "TF_GLM_KEEP_REASONING_MB")}
        environment.update(settings)
        code = ('import importlib.util,json,sys; p=sys.argv[1]; '
                's=importlib.util.spec_from_file_location("actual_kept",p); '
                'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                'v=m.KeptReasoning.from_env(); '
                'print(json.dumps(None if v is None else {"entries":v.entries,"chars":v.chars}))')
        return subprocess.run([sys.executable, "-I", "-B", "-c", code,
                               str(self.source_root / MODULE_PATH)],
                              env=environment, text=True, capture_output=True, timeout=15)

    def test_actual_environment_parser(self) -> None:
        for settings, expected in (({}, {"entries": 1024, "chars": 32 << 20}),
                                   ({"TF_GLM_KEEP_REASONING": "0", "TF_GLM_KEEP_REASONING_MB": "bad"}, None),
                                   ({"TF_GLM_KEEP_REASONING": "2", "TF_GLM_KEEP_REASONING_MB": "1"},
                                    {"entries": 2, "chars": 1 << 20})):
            result = self.env_result(settings)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)
        for key in ("TF_GLM_KEEP_REASONING", "TF_GLM_KEEP_REASONING_MB"):
            for value in ("bad", "-1"):
                result = self.env_result({key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ValueError", result.stderr)

    def test_actual_restore_work_is_linear(self) -> None:
        measurements = []
        for steps in (64, 128):
            with self.subTest(steps=steps):
                count = actual_work(self.module, steps)
                measurements.append({"steps": steps, "actual_calls": count, "linear_bound": 2 * steps})
                self.assertLessEqual(count, 2 * steps)
        print(json.dumps({"actual_work_measurements": measurements}, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    args = parser.parse_args()
    source_root = args.source_root.resolve(strict=True)
    module = load_module(source_root)
    KeptReasoningChecks.module = module
    KeptReasoningChecks.source_root = source_root
    path = source_root / MODULE_PATH
    print(json.dumps({"source": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                      "scope": "Complete actual stdlib module; no GPU, backend replacements, or HTTP."}))
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(KeptReasoningChecks)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
