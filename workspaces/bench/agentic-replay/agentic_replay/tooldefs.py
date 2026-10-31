"""The tool schemas sent to the model, and the validator for what comes back."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

JSON_TYPES: dict[str, type] = {"string": str, "integer": int}


def _tool(name: str, description: str, props: dict[str, str], required: list[str]) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": {k: {"type": v} for k, v in props.items()},
                "required": required,
            },
        },
    }


TOOLS: list[dict[str, Any]] = [
    _tool("read_file", "Read a text file of the project, from a byte offset.",
          {"path": "string", "offset": "integer"}, ["path"]),
    _tool("write_file", "Create or replace a text file of the project.",
          {"path": "string", "content": "string"}, ["path", "content"]),
    _tool("list_dir", "List one directory of the project.", {"path": "string"}, ["path"]),
    _tool("grep", "Find a fixed string (not a regular expression) in project files.",
          {"pattern": "string", "path": "string"}, ["pattern"]),
    _tool("run_tests", "Run the project's visible unit tests.", {}, []),
]

# Tool syntax leaked into plain text. A list of shapes, not a per-model branch.
CONTENT_SYNTAX = re.compile(
    r"<\s*/?\s*tool_call|<\s*function\s*=|<\|\s*tool|<｜[^｜]*tool|<\s*\|?\s*DSML"
    r"|\[TOOL_CALLS\]|\"tool_calls\"\s*:|\"arguments\"\s*:\s*[\"{]",
)


@dataclass(frozen=True)
class CallVerdict:
    valid: bool
    reason: str
    name: str | None = None
    arguments: dict[str, Any] | None = None


def _schemas(tools: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {t["function"]["name"]: t["function"]["parameters"] for t in tools}


def _is_type(value: Any, json_type: str) -> bool:
    if json_type == "integer" and isinstance(value, bool):
        return False
    return isinstance(value, JSON_TYPES[json_type])


def check_call(call: dict[str, Any], tools: list[dict[str, Any]]) -> CallVerdict:
    function = call.get("function") or {}
    name = function.get("name")
    schemas = _schemas(tools)
    if name not in schemas:
        return CallVerdict(False, "unknown_tool", name)
    try:
        args = json.loads(function.get("arguments") or "")
    except json.JSONDecodeError:
        return CallVerdict(False, "truncated_json", name)
    if not isinstance(args, dict):
        return CallVerdict(False, "arguments_not_object", name)
    schema = schemas[name]
    for key in schema["required"]:
        if key not in args:
            return CallVerdict(False, "missing_argument", name)
    for key, value in args.items():
        spec = schema["properties"].get(key)
        if spec is not None and not _is_type(value, spec["type"]):
            return CallVerdict(False, "wrong_type", name)
    return CallVerdict(True, "ok", name, args)


def syntax_in_content(content: str | None) -> bool:
    return bool(content and CONTENT_SYNTAX.search(content))


def check_reply(
    tool_calls: list[dict[str, Any]], content: str | None, tools: list[dict[str, Any]]
) -> list[CallVerdict]:
    """One verdict per call, plus one for tool syntax found in plain content."""
    verdicts = [check_call(c, tools) for c in tool_calls]
    if syntax_in_content(content):
        verdicts.append(CallVerdict(False, "syntax_in_content"))
    return verdicts
