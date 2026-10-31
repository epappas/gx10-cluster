"""Streaming chat client, and the parser that turns a stream into one Reply.

Fields are recorded under the name that arrived. Nothing here knows a model.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from http.client import HTTPException
from typing import Any

ERROR_BODY_LIMIT = 2048
MIN_DECODE_SPAN_S = 0.05
KNOWN_DELTA_FIELDS = {"role", "content", "tool_calls", "function_call"}


@dataclass
class Reply:
    status: int | None = None
    error: str | None = None
    dead: bool = False
    started: float = 0.0
    ended: float = 0.0
    first: float | None = None
    last: float | None = None
    content: str | None = None
    reasoning: dict[str, str] = field(default_factory=dict)
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    prompt_tokens: int | None = None
    cached_tokens: int | None = None
    completion_tokens: int | None = None
    finish_reason: str | None = None

    @property
    def ttft_s(self) -> float | None:
        return None if self.first is None else self.first - self.started

    @property
    def decode_tps(self) -> float | None:
        """usage.completion_tokens over first-to-last delta. Missing, never 0.

        A reply delivered as one burst has no measurable span: live tool-call
        replies gave 2,199,452 tok/s. Their decode time sits inside ttft_s.
        """
        if self.completion_tokens is None or self.first is None or self.last is None:
            return None
        span = self.last - self.first
        return self.completion_tokens / span if span >= MIN_DECODE_SPAN_S else None

    @property
    def ok(self) -> bool:
        """TensorFold reports some refusals as an error chunk inside a status 200 stream."""
        return self.status == 200 and not self.error

    @property
    def budget_stop(self) -> bool:
        """A length stop with empty content ran out of budget. It is not a wrong answer."""
        return self.finish_reason == "length" and not self.content

    def assistant_message(self) -> dict[str, Any]:
        """The reply exactly as received, under the fields that arrived."""
        message: dict[str, Any] = {"role": "assistant", "content": self.content}
        message.update(self.reasoning)
        if self.tool_calls:
            message["tool_calls"] = self.tool_calls
        return message


def _merge_tool_calls(reply: Reply, deltas: list[dict[str, Any]]) -> None:
    for delta in deltas:
        index = delta.get("index", len(reply.tool_calls))
        while len(reply.tool_calls) <= index:
            reply.tool_calls.append(
                {"id": None, "type": "function", "function": {"name": "", "arguments": ""}})
        call = reply.tool_calls[index]
        call["id"] = delta.get("id") or call["id"]
        function = delta.get("function") or {}
        call["function"]["name"] += function.get("name") or ""
        call["function"]["arguments"] += function.get("arguments") or ""


def _apply_delta(reply: Reply, delta: dict[str, Any], now: float) -> None:
    text = delta.get("content")
    if isinstance(text, str):
        reply.content = (reply.content or "") + text
    fragments = [v for k, v in delta.items()
                 if k not in KNOWN_DELTA_FIELDS and isinstance(v, str) and v]
    for key, value in delta.items():
        if key not in KNOWN_DELTA_FIELDS and isinstance(value, str) and value:
            reply.reasoning[key] = reply.reasoning.get(key, "") + value
    if delta.get("tool_calls"):
        _merge_tool_calls(reply, delta["tool_calls"])
    # A role chunk can precede prefill, so only real output ends it.
    if text or fragments or delta.get("tool_calls"):
        reply.first = now if reply.first is None else reply.first
        reply.last = now


def _apply_usage(reply: Reply, usage: dict[str, Any]) -> None:
    details = usage.get("prompt_tokens_details") or {}
    reply.prompt_tokens = usage.get("prompt_tokens", reply.prompt_tokens)
    reply.completion_tokens = usage.get("completion_tokens", reply.completion_tokens)
    cached = details.get("cached_tokens", usage.get("cached_tokens"))
    reply.cached_tokens = cached if cached is not None else reply.cached_tokens


def _apply_chunk(reply: Reply, chunk: dict[str, Any], now: float) -> None:
    if chunk.get("error"):
        reply.error = json.dumps(chunk["error"])[:ERROR_BODY_LIMIT]
    if chunk.get("usage"):
        _apply_usage(reply, chunk["usage"])
    for choice in chunk.get("choices") or []:
        _apply_delta(reply, choice.get("delta") or {}, now)
        reply.finish_reason = choice.get("finish_reason") or reply.finish_reason


def parse_stream(lines: Iterable[bytes], reply: Reply, clock: Callable[[], float]) -> bool:
    """Feed SSE lines into reply. True when the stream ended with [DONE]."""
    for raw in lines:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            return True
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError:
            reply.error = f"unparseable chunk: {data[:200]}"
            continue
        try:
            _apply_chunk(reply, chunk, clock())
        except (AttributeError, TypeError, KeyError) as exc:
            reply.error = f"malformed chunk: {type(exc).__name__}: {data[:200]}"
    return False


def _headers(api_key: str) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return headers


def post_chat(base_url: str, api_key: str, body: bytes, timeout: float) -> Reply:
    """One streamed request. Never raises: a failure is a recorded Reply."""
    reply = Reply(started=time.time())
    url = base_url.rstrip("/") + "/chat/completions"
    request = urllib.request.Request(url, data=body, headers=_headers(api_key))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            reply.status = response.status
            if not parse_stream(response, reply, time.time):
                reply.error = reply.error or "stream ended without [DONE]"
                reply.dead = True
    except urllib.error.HTTPError as exc:
        reply.status = exc.code
        reply.error = exc.read(ERROR_BODY_LIMIT).decode("utf-8", "replace")
    except (urllib.error.URLError, HTTPException, OSError) as exc:
        reply.error = f"{type(exc).__name__}: {exc}"
        reply.dead = True
    reply.ended = time.time()
    return reply


def fetch_json(url: str, api_key: str, timeout: float = 10.0) -> dict[str, Any]:
    """A snapshot. A failure is returned as data, so the run keeps it."""
    request = urllib.request.Request(url, headers=_headers(api_key))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return {"status": response.status, "body": json.loads(response.read())}
    except urllib.error.HTTPError as exc:
        return {"status": exc.code, "error": exc.read(ERROR_BODY_LIMIT).decode("utf-8", "replace")}
    except (urllib.error.URLError, HTTPException, OSError, ValueError) as exc:
        return {"status": None, "error": f"{type(exc).__name__}: {exc}"}
