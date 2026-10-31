"""Shared constants and the deterministic helpers every mode derives from."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from typing import Any

# A stdlib tool cannot count tokens and tokenizers differ, so sizes are bytes.
# 3 is measured on this corpus: 80,000 bytes were 27,473 DeepSeek prompt tokens.
BYTES_PER_TOKEN_WORTH = 3


def token_worth(tokens: int) -> int:
    return tokens * BYTES_PER_TOKEN_WORTH


def derive_hex(seed: int, *labels: object) -> str:
    text = ":".join(str(x) for x in (seed, *labels))
    return hashlib.sha256(text.encode()).hexdigest()


def derive_int(seed: int, *labels: object) -> int:
    return int(derive_hex(seed, *labels)[:16], 16)


def canonical_bytes(obj: Any) -> bytes:
    # ASCII escapes: a model reply can hold a lone surrogate, which UTF-8 cannot encode.
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def sha256_of(obj: Any) -> str:
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


@dataclass(frozen=True)
class Sampling:
    """Set on every body: kit defaults differ and may silently differ per model."""

    temperature: float
    top_p: float
    top_k: int
    max_tokens: int

    def as_body(self) -> dict[str, float | int]:
        return asdict(self)


def render_body(
    model: str,
    messages: list[dict[str, Any]],
    sampling: Sampling,
    seed: int | None,
    tools: list[dict[str, Any]] | None = None,
    extra: dict[str, Any] | None = None,
) -> bytes:
    """One request body. Sends no thinking or reasoning parameter, by invariant."""
    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
        **sampling.as_body(),
    }
    if tools is not None:
        body["tools"] = tools
    if seed is not None:
        body["seed"] = seed
    return canonical_bytes({**body, **(extra or {})})
