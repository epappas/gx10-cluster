"""Recall probes: facts planted at known depths, and the scorer.

Design follows quant-quality-ab: a needle alone proves little, so there are
three kinds. `single` finds one fact, `combo` combines two planted far apart,
and `absent` guards the suite: a model that confabulates would pass needles too.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .core import derive_hex, derive_int

LABELS = ("kestrel", "heron", "osprey", "plover", "avocet", "lapwing", "dunlin", "curlew")
ABSENT_LABEL = "bittern"
WORDS = ("CORAL", "INDIGO", "SAFFRON", "UMBER", "COBALT", "OCHRE", "SIENNA", "VIRIDIAN")
DEPTHS = (0.02, 0.10, 0.25, 0.45, 0.70, 0.95)

CODE = re.compile(r"\b\d{4}-[A-Za-z]+\b")
NUMBER = re.compile(r"(?<![\w-])\d+(?![\w-])")
ABSENT_PHRASES = (
    "not present", "not mentioned", "not recorded", "not found", "no record",
    "does not appear", "is not listed", "no such depot", "no information",
)


@dataclass(frozen=True)
class Fact:
    label: str
    code: str
    crates: int
    depth_bytes: int

    def sentence(self) -> str:
        return (f"Audit note: the {self.label} depot has access code {self.code} "
                f"and holds exactly {self.crates} sealed crates.")


@dataclass(frozen=True)
class Probe:
    kind: str
    question: str
    expected: str
    allowed: tuple[str, ...]
    depth_bytes: int


def make_facts(seed: int, target_bytes: int, count: int) -> tuple[Fact, ...]:
    assert 0 < count <= len(DEPTHS)
    labels = sorted(LABELS, key=lambda x: derive_hex(seed, "label", x))
    words = sorted(WORDS, key=lambda x: derive_hex(seed, "word", x))
    indexes = [round(i * (len(DEPTHS) - 1) / max(count - 1, 1)) for i in range(count)]
    facts = []
    for n, at in enumerate(indexes):
        code = f"{1000 + derive_int(seed, 'code', n) % 9000}-{words[n]}"
        crates = 11 + derive_int(seed, "crates", n) % 89
        facts.append(Fact(labels[n], code, crates, int(target_bytes * DEPTHS[at])))
    return tuple(facts)


def probes_at(size_bytes: int, facts: tuple[Fact, ...]) -> list[Probe]:
    """Every fact already planted at this size, one combination, one absent."""
    planted = [f for f in facts if f.depth_bytes < size_bytes]
    out = [
        Probe("single",
              f"From the audit notes in the files above, what is the access code of the "
              f"{f.label} depot? Answer with just the code, without calling a tool.",
              f.code, (), f.depth_bytes)
        for f in planted
    ]
    if len(planted) >= 2:
        a, b = planted[0], planted[-1]
        out.append(Probe(
            "combo",
            f"From the audit notes in the files above, how many sealed crates do the "
            f"{a.label} and {b.label} depots hold in total? Answer with just the number, without calling a tool.",
            str(a.crates + b.crates), (str(a.crates), str(b.crates)), a.depth_bytes))
    out.append(Probe(
        "absent",
        f"From the audit notes in the files above, what is the access code of the "
        f"{ABSENT_LABEL} depot? If it is not recorded there, say exactly: NOT PRESENT. Answer from the text above, "
        f"without calling a tool.",
        "", (), 0))
    return out


def score(probe: Probe, reply: str) -> int:
    """1 or 0 on the visible reply. An empty reply at a length stop is decided by the caller."""
    text = reply.strip()
    if probe.kind == "absent":
        return _score_absent(text)
    if probe.kind == "combo":
        return _score_combo(probe, text)
    found = {c.upper() for c in CODE.findall(text)}
    return int(found == {probe.expected.upper()})


def _score_absent(text: str) -> int:
    lower = text.lower()
    if CODE.search(text):
        return 0
    return int(any(p in lower for p in ABSENT_PHRASES))


def _score_combo(probe: Probe, text: str) -> int:
    found = set(NUMBER.findall(text))
    if probe.expected not in found:
        return 0
    return int(found <= {probe.expected, *probe.allowed})
