"""Scripted workloads. Bodies are built here, before anything is sent.

The generators take no reply as input, so in replay and soak no model output
can reach a later request.
"""

from __future__ import annotations

import itertools
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

from .core import Sampling, derive_hex, derive_int, render_body
from .corpus import Corpus, iter_pieces
from .recall import Fact, Probe, make_facts, probes_at
from .tooldefs import TOOLS

SYSTEM_PROMPT = (
    "You are a coding agent working in a repository. Use the tools to inspect "
    "and change files. Keep working until the task is done, then reply in plain "
    "text with a short summary."
)
OPENING = "Survey this repository before we start on the work."
PIECE_BYTES = 16 * 1024
SHORT_PROMPT = "Summarise what the file above is for, in one sentence."
JSON_PROMPT = 'Reply with a JSON object of the form {"ok": true}.'
SAMPLING_PROMPT = "Name twenty unrelated words."
SAMPLING_MAX_TOKENS = 32
HOT_TEMPERATURE = 1.9
TINY_TOP_P = 0.0001


def salt_for(seed: int, *labels: object) -> str:
    return derive_hex(seed, "salt", *labels)[:32]


def system_message(salt: str) -> dict[str, str]:
    # The salt comes first: everything behind it misses the prompt cache.
    return {"role": "system", "content": f"session {salt}\n{SYSTEM_PROMPT}"}


@dataclass(frozen=True)
class Planned:
    kind: str
    conv: int
    step: int
    target_bytes: int
    salt: str
    body: bytes
    probe: Probe | None = None
    variant: str | None = None


@dataclass
class ScriptedHistory:
    """Grows one conversation by tool rounds, planting facts at their depths."""

    corpus: Corpus
    seed: int
    label: str
    facts: tuple[Fact, ...] = ()
    messages: list[dict[str, Any]] = field(default_factory=list)
    grown: int = 0
    rounds: int = 0
    reused: bool = False

    def __post_init__(self) -> None:
        self._pieces = iter_pieces(self.corpus, derive_int(self.seed, self.label), PIECE_BYTES)
        self._pending = sorted(self.facts, key=lambda f: f.depth_bytes)

    def _notes_due(self, after: int) -> str:
        due = [f for f in self._pending if f.depth_bytes < after]
        self._pending = self._pending[len(due):]
        return "".join(f"{f.sentence()}\n" for f in due)

    def add_round(self) -> None:
        piece = next(self._pieces)
        self.rounds += 1
        call_id = f"call_{self.rounds:06d}"
        size = len(piece.text.encode())
        content = self._notes_due(self.grown + size) + piece.text
        self.messages.append({
            "role": "assistant",
            "content": f"Reading {piece.path}.",
            "tool_calls": [{
                "id": call_id,
                "type": "function",
                "function": {
                    "name": "read_file",
                    "arguments": f'{{"path":"{piece.path}","offset":{piece.offset}}}',
                },
            }],
        })
        self.messages.append({"role": "tool", "tool_call_id": call_id, "content": content})
        self.grown += size
        self.reused = self.reused or piece.reused

    def grow_to(self, target_bytes: int) -> None:
        while self.grown < target_bytes:
            self.add_round()


@dataclass(frozen=True)
class ReplaySpec:
    target_bytes: int
    step_bytes: int
    probe_bytes: tuple[int, ...]
    fact_count: int
    sampling: Sampling
    interleave: bool = False
    response_format: bool = False
    sampling_check: bool = False

    def stops(self) -> list[int]:
        steps = range(self.step_bytes, self.target_bytes + 1, self.step_bytes)
        return sorted({*steps, *self.probe_bytes})


def opening(salt: str) -> list[dict[str, Any]]:
    return [system_message(salt), {"role": "user", "content": OPENING}]


def _short_call(
    model: str, spec: ReplaySpec, corpus: Corpus, seed: int, wire_seed: int | None,
    tag: tuple[object, ...], prompt: str, extra: dict[str, Any] | None = None,
) -> tuple[str, bytes]:
    salt = salt_for(seed, *tag)
    history = ScriptedHistory(corpus, seed, f"short:{tag}", messages=opening(salt))
    history.add_round()
    messages = [*history.messages, {"role": "user", "content": prompt}]
    return salt, render_body(model, messages, spec.sampling, wire_seed, TOOLS, extra)


def seed_probe_body(model: str, sampling: Sampling, seed: int) -> bytes:
    """Asks once whether this server accepts `seed`. The answer goes in the results."""
    messages = [system_message(salt_for(seed, "seed-probe")),
                {"role": "user", "content": "Reply with the word ready."}]
    return render_body(model, messages, sampling, seed)


def _sampling_checks(
    model: str, messages: list[dict[str, Any]], spec: ReplaySpec, seed: int | None,
) -> Iterator[tuple[str, bytes]]:
    """Three variants of one prompt, compared with its greedy reply to show values win.

    top_k stays set on the hot variants: top_k=0 came back as a server error on TensorFold.
    """
    base = spec.sampling
    variants = {
        "greedy": Sampling(0.0, 1.0, base.top_k, SAMPLING_MAX_TOKENS),
        "hot": Sampling(HOT_TEMPERATURE, 1.0, base.top_k, SAMPLING_MAX_TOKENS),
        "hot_top_k_1": Sampling(HOT_TEMPERATURE, 1.0, 1, SAMPLING_MAX_TOKENS),
        "hot_top_p_tiny": Sampling(HOT_TEMPERATURE, TINY_TOP_P, base.top_k, SAMPLING_MAX_TOKENS),
    }
    question = [*messages, {"role": "user", "content": SAMPLING_PROMPT}]
    for name, sampling in variants.items():
        yield name, render_body(model, question, sampling, seed, TOOLS)


def replay_requests(
    spec: ReplaySpec, corpus: Corpus, model: str, seed: int, conv: int, send_seed: bool,
) -> Iterator[Planned]:
    """Every request of one conversation, in order, from seed and corpus alone."""
    salt = salt_for(seed, "replay", conv)
    facts = make_facts(seed, spec.target_bytes, spec.fact_count)
    history = ScriptedHistory(corpus, seed, f"replay:{conv}", facts, opening(salt))
    wire_seed = seed if send_seed else None
    sampling_due = spec.sampling_check
    for step, target in enumerate(spec.stops(), 1):
        history.grow_to(target)
        body = render_body(model, history.messages, spec.sampling, wire_seed, TOOLS)
        yield Planned("step", conv, step, target, salt, body)
        if sampling_due:
            sampling_due = False
            for name, checked in _sampling_checks(model, history.messages, spec, wire_seed):
                yield Planned("sampling", conv, step, target, salt, checked, variant=name)
        if target in spec.probe_bytes:
            yield from _probes(spec, model, history, facts, wire_seed, conv, step, target, salt)
        if spec.interleave:
            tag = ("short", conv, step)
            s, b = _short_call(model, spec, corpus, seed, wire_seed, tag, SHORT_PROMPT)
            yield Planned("short", conv, step, target, s, b)
        if spec.response_format and conv == 0 and step == 1:
            extra = {"response_format": {"type": "json_object"}}
            tag = ("json", conv)
            s, b = _short_call(model, spec, corpus, seed, wire_seed, tag, JSON_PROMPT, extra)
            yield Planned("response_format", conv, step, target, s, b)


def _probes(
    spec: ReplaySpec, model: str, history: ScriptedHistory, facts: tuple[Fact, ...],
    seed: int | None, conv: int, step: int, target: int, salt: str,
) -> Iterator[Planned]:
    """Each probe is a branch: the question is never appended to the shared history."""
    for probe in probes_at(target, facts):
        branch = [*history.messages, {"role": "user", "content": probe.question}]
        body = render_body(model, branch, spec.sampling, seed, TOOLS)
        yield Planned("probe", conv, step, target, salt, body, probe=probe)


@dataclass(frozen=True)
class SoakSpec:
    short_bytes: int
    long_bytes: int
    long_every: int
    sampling: Sampling


def soak_requests(
    spec: SoakSpec, corpus: Corpus, model: str, seed: int, send_seed: bool,
) -> Iterator[Planned]:
    """Endless distinct conversations, each with a new salt, so kept states pile up."""
    for index in itertools.count():
        is_long = spec.long_every > 0 and (index + 1) % spec.long_every == 0
        size = spec.long_bytes if is_long else spec.short_bytes
        salt = salt_for(seed, "soak", index)
        history = ScriptedHistory(corpus, seed, f"soak:{index}", messages=opening(salt))
        history.grow_to(size)
        body = render_body(model, history.messages, spec.sampling, seed if send_seed else None, TOOLS)
        yield Planned("long" if is_long else "short", index, 1, size, salt, body)
