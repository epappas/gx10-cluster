"""compare: two result directories, one plain-text table. No winner logic.

Missing prints as missing, never 0. Runs of different workloads are refused.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

MISSING = "missing"
WINDOW_KEY = re.compile(r"context|window|max_model_len|max_seq|n_ctx|max_position", re.I)

Row = tuple[str, Any, Any]


class CompareRefused(Exception):
    pass


@dataclass(frozen=True)
class Result:
    path: Path
    manifest: dict[str, Any]
    summary: dict[str, Any]
    snapshot: dict[str, Any]
    snapshot_end: dict[str, Any]


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text()) if path.exists() else {}


def load_result(path: Path) -> Result:
    manifest = _load_json(path / "manifest.json")
    if not manifest.get("workload"):
        raise CompareRefused(f"{path}: no manifest, the run never started its workload")
    return Result(path, manifest, _load_json(path / "summary.json"),
                  _load_json(path / "snapshot-start.json"),
                  _load_json(path / "snapshot-end.json"))


def refuse_mismatch(a: Result, b: Result) -> None:
    left, right = a.manifest["workload"], b.manifest["workload"]
    differ = sorted(k for k in {*left, *right} if left.get(k) != right.get(k))
    if differ:
        details = "; ".join(f"{k}: {left.get(k)!r} != {right.get(k)!r}" for k in differ)
        raise CompareRefused(f"different workloads, refusing to compare: {details}")


def show(value: Any) -> str:
    if value is None:
        return MISSING
    return f"{value:.2f}" if isinstance(value, float) else str(value)


def window_sizes(snapshot: Any) -> str | None:
    """Any window-like key in the snapshots. Names are not assumed per server."""
    found: list[str] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                numeric = isinstance(value, (int, float)) and not isinstance(value, bool)
                if WINDOW_KEY.search(key) and numeric:
                    found.append(f"{key}={value}")
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(snapshot)
    return ", ".join(sorted(set(found))) or None


def _by_key(summary: dict[str, Any]) -> dict[tuple[Any, ...], dict[str, Any]]:
    rows = summary.get("requests") or []
    return {(r.get("seed"), r.get("conv"), r.get("step")): r for r in rows
            if r.get("kind") in ("step", "turn")}


def _decode(row: dict[str, Any]) -> Any:
    """Smoothed streaming and bursts bias this number, so it never prints unmarked."""
    rate, note = row.get("decode_tps"), row.get("decode_note")
    return f"{show(rate)} not meaningful: {note}" if note else rate


def _step_rows(a: Result, b: Result) -> Iterator[Row]:
    left, right = _by_key(a.summary), _by_key(b.summary)
    for key in sorted(set(left) | set(right), key=lambda k: tuple(x or 0 for x in k)):
        name = "seed {} conv {} step {}".format(*key)
        one, two = left.get(key, {}), right.get(key, {})
        for field in ("prompt_tokens", "cached_tokens", "completion_tokens", "total_s", "ttft_s",
                      "burst", "finish_reason", "error"):
            yield f"{name} {field}", one.get(field), two.get(field)
        yield f"{name} decode_tps", _decode(one), _decode(two)


def _recall_cells(summary: dict[str, Any]) -> dict[tuple[Any, ...], str]:
    groups: dict[tuple[Any, ...], list[Any]] = {}
    for row in summary.get("recall") or []:
        key = (row["size_bytes"], row["depth_bytes"], row["kind"])
        groups.setdefault(key, []).append(row["score"])
    return {k: _recall_cell(v) for k, v in groups.items()}


def _recall_cell(scores: list[Any]) -> str:
    """Budget stays in the first denominator, or a run of them reads as a survivor fraction.

    The answered reading is printed beside it. Errors and tool calls are counted apart.
    """
    answered = [s for s in scores if isinstance(s, int)]
    budget = scores.count("budget")
    unanswered = sorted({s for s in scores if not isinstance(s, int)})
    notes = "".join(f" {name} {scores.count(name)}" for name in unanswered)
    right = sum(answered)
    return f"{right}/{len(answered) + budget}; answered {right}/{len(answered)};{notes}".rstrip(" ;")


def _recall_rows(a: Result, b: Result) -> Iterator[Row]:
    left, right = _recall_cells(a.summary), _recall_cells(b.summary)
    for key in sorted(set(left) | set(right)):
        yield f"recall size {key[0]} depth {key[1]} {key[2]}", left.get(key), right.get(key)


def _task_cells(summary: dict[str, Any]) -> dict[tuple[Any, ...], dict[str, Any]]:
    return {(rep["seed"], row["id"]): row for rep in summary.get("repeats") or []
            for row in rep["tasks"]}


def _task_rows(a: Result, b: Result) -> Iterator[Row]:
    left, right = _task_cells(a.summary), _task_cells(b.summary)
    for key in sorted(set(left) | set(right)):
        one, two = left.get(key, {}), right.get(key, {})
        for field in ("status", "status_at_end", "turns", "wall_s", "invalid", "budget",
                      "refused", "repeated", "prompt_tokens_end"):
            yield f"seed {key[0]} task {key[1]} {field}", one.get(field), two.get(field)


def _memory_rows(a: Result, b: Result) -> Iterator[Row]:
    left, right = a.summary.get("memory") or {}, b.summary.get("memory") or {}
    for node in sorted(k for k in {*left, *right} if k != "sampler"):
        one, two = left.get(node) or {}, right.get(node) or {}
        yield f"memory {node} low_kib", one.get("low_kib"), two.get("low_kib")
        yield f"memory {node} guard", one.get("guard"), two.get("guard")
        yield f"memory {node} sampler errors", _errors(one), _errors(two)


def _minute_rows(a: Result, b: Result) -> Iterator[Row]:
    left = {r["minute"]: r for r in a.summary.get("per_minute") or []}
    right = {r["minute"]: r for r in b.summary.get("per_minute") or []}
    for minute in sorted({*left, *right}):
        one, two = left.get(minute, {}), right.get(minute, {})
        for field in ("requests", "errors", "ttft_p50_s", "total_p50_s"):
            yield f"soak minute {minute} {field}", one.get(field), two.get(field)


def _not_cold(result: Result) -> str | None:
    """Unknown when no server reported cached tokens, not zero."""
    rows_ = [r["not_cold"] for r in result.summary.get("requests") or []
             if r.get("not_cold") is not None]
    return f"{sum(rows_)}/{len(rows_)}" if rows_ else None


def _sampling(result: Result) -> str | None:
    check = result.summary.get("sampling_check")
    if not check:
        return None
    return ", ".join(f"{k} {check[k]}" for k in ("temperature", "top_k", "top_p"))


def _errors(row: dict[str, Any]) -> str | None:
    """An empty list prints `none`, so it cannot be mistaken for a run with no sampler."""
    if "errors" not in row:
        return None
    return "; ".join(row["errors"]) or "none"


def _metrics(result: Result) -> int | None:
    return (result.summary.get("metrics") or {}).get("saved")


def _stopped(result: Result) -> str | None:
    """No summary at all is missing. A summary with no stop reason finished."""
    if "stopped" not in result.summary:
        return None
    return result.summary["stopped"] or "no"


def _count(result: Result) -> int | None:
    requests = result.summary.get("requests")
    return None if requests is None else len(requests)


def rows(a: Result, b: Result) -> list[Row]:
    head: list[Row] = [
        ("model", a.manifest.get("model"), b.manifest.get("model")),
        ("window", window_sizes(a.snapshot), window_sizes(b.snapshot)),
        ("window at end", window_sizes(a.snapshot_end), window_sizes(b.snapshot_end)),
        ("request errors", a.summary.get("request_errors"), b.summary.get("request_errors")),
        ("stopped", _stopped(a), _stopped(b)),
        ("corpus_reused", a.summary.get("corpus_reused"), b.summary.get("corpus_reused")),
        ("soak verdict", a.summary.get("verdict"), b.summary.get("verdict")),
        ("metrics saved", _metrics(a), _metrics(b)),
        ("not_cold first steps", _not_cold(a), _not_cold(b)),
        ("sampling_check", _sampling(a), _sampling(b)),
        ("requests", _count(a), _count(b)),
        ("response_format", a.summary.get("response_format"), b.summary.get("response_format")),
    ]
    return [*head, *_step_rows(a, b), *_recall_rows(a, b), *_task_rows(a, b),
            *_minute_rows(a, b), *_memory_rows(a, b)]


def render(a: Result, b: Result) -> str:
    table = [(name, show(x), show(y)) for name, x, y in rows(a, b)]
    table.insert(0, ("metric", a.path.name, b.path.name))
    widths = [max(len(row[i]) for row in table) for i in range(3)]
    return "\n".join(
        "  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip() for row in table)


def run_compare(left: str, right: str) -> int:
    try:
        a, b = load_result(Path(left)), load_result(Path(right))
        refuse_mismatch(a, b)
    except CompareRefused as exc:
        print(f"refused: {exc}")
        return 2
    print(render(a, b))
    return 0
