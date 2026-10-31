"""One run directory: manifest, snapshots, raw JSONL, summary.

Lines are flushed as they happen, so a dead server or a killed client leaves
everything measured so far on disk.
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .client import Reply, fetch_json
from .sampler import Sampler, Window, low_in_window, summarise_memory

DEFAULT_ROOT = Path.home() / ".local/state/gx10-bench/agentic-replay"


def new_run_dir(root: Path, label: str) -> Path:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = root / f"{label}-{stamp}"
    path.mkdir(parents=True, exist_ok=False)
    return path


def reply_record(reply: Reply) -> dict[str, Any]:
    return {
        "status": reply.status, "error": reply.error, "dead": reply.dead,
        "started": reply.started, "ended": reply.ended,
        "ttft_s": reply.ttft_s, "decode_tps": reply.decode_tps,
        "content": reply.content, "reasoning": reply.reasoning,
        "tool_calls": reply.tool_calls, "prompt_tokens": reply.prompt_tokens,
        "cached_tokens": reply.cached_tokens, "completion_tokens": reply.completion_tokens,
        "finish_reason": reply.finish_reason, "budget": reply.budget_stop,
    }


@dataclass
class Run:
    path: Path
    base_url: str
    api_key: str
    nodes: list[str] = field(default_factory=list)
    guard_log: str | None = None
    records: list[dict[str, Any]] = field(default_factory=list)
    samples: list[dict[str, Any]] = field(default_factory=list)
    sampler: Sampler | None = None

    def __post_init__(self) -> None:
        self._lock = threading.Lock()
        self._requests = (self.path / "requests.jsonl").open("a", buffering=1)
        self._memory = (self.path / "memory.jsonl").open("a", buffering=1)

    def write_json(self, name: str, obj: Any) -> None:
        (self.path / name).write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")

    def add_request(self, record: dict[str, Any]) -> None:
        with self._lock:
            self.records.append(record)
            self._requests.write(json.dumps(record) + "\n")

    def add_sample(self, sample: dict[str, Any]) -> None:
        with self._lock:
            self.samples.append(sample)
            self._memory.write(json.dumps(sample) + "\n")

    def snapshot(self, phase: str) -> dict[str, Any]:
        """/v1/models and /health: window sizes differ, and a kit may restart smaller."""
        root = self.base_url.rstrip("/").removesuffix("/v1")
        snap = {"models": fetch_json(f"{self.base_url.rstrip('/')}/models", self.api_key),
                "health": fetch_json(f"{root}/health", self.api_key)}
        self.write_json(f"snapshot-{phase}.json", snap)
        return snap

    def start_sampler(self, ssh_config: str | None) -> None:
        if self.nodes:
            self.sampler = Sampler(self.nodes, self.guard_log, ssh_config, self.add_sample)

    def memory_summary(self) -> dict[str, Any]:
        if self.sampler:
            self.sampler.stop()
            self.sampler = None
        if not self.nodes:
            return {"sampler": "not run"}
        for record in self.records:
            window = Window(record["started"], record["ended"])
            record["memory_low_kib"] = low_in_window(self.samples, window)
        return summarise_memory(self.samples, self.nodes, self.guard_log)

    def close(self, summary: dict[str, Any]) -> None:
        self.write_json("summary.json", summary)
        self._requests.close()
        self._memory.close()


def request_rows(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    keys = ("seed", "conv", "step", "kind", "target_bytes", "ttft_s", "decode_tps",
            "prompt_tokens", "cached_tokens", "completion_tokens", "finish_reason",
            "budget", "error", "memory_low_kib", "not_cold")
    return [{k: r.get(k) for k in keys} for r in records]


def per_minute(records: list[dict[str, Any]]) -> list[dict[str, int]]:
    """Requests and errors by minute since the first request."""
    if not records:
        return []
    start = min(r["started"] for r in records)
    minutes: dict[int, dict[str, int]] = {}
    for record in records:
        minute = int((record["started"] - start) // 60)
        row = minutes.setdefault(minute, {"minute": minute, "requests": 0, "errors": 0})
        row["requests"] += 1
        row["errors"] += 1 if record.get("error") else 0
    return [minutes[m] for m in sorted(minutes)]
