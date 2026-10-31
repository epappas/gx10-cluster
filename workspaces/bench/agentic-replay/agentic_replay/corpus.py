"""Corpus: tracked text files at a pinned revision, read from git objects only.

A directory walk reaches .env and harness credentials, so nothing here touches
the working tree.
"""

from __future__ import annotations

import hashlib
import itertools
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from .core import derive_hex

EXCLUDED_PREFIX = "workspaces/bench/agentic-replay/"
BLOB_MODES = {"100644", "100755"}


class CorpusError(Exception):
    pass


@dataclass(frozen=True)
class CorpusFile:
    path: str
    text: str


@dataclass(frozen=True)
class Corpus:
    rev: str
    digest: str
    files: tuple[CorpusFile, ...]

    @property
    def size_bytes(self) -> int:
        return sum(len(f.text.encode()) for f in self.files)


@dataclass(frozen=True)
class Piece:
    path: str
    offset: int
    text: str
    reused: bool


def _git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    done = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True)
    if done.returncode != 0:
        raise CorpusError(f"git {args[0]} failed: {done.stderr.decode(errors='replace').strip()}")
    return done.stdout


def _tracked_blobs(repo: Path, rev: str) -> list[tuple[str, str]]:
    blobs: list[tuple[str, str]] = []
    for entry in _git(repo, "ls-tree", "-r", "-z", rev).split(b"\0"):
        if not entry:
            continue
        meta, path = entry.decode().split("\t", 1)
        mode, kind, oid = meta.split()
        if kind == "blob" and mode in BLOB_MODES and not path.startswith(EXCLUDED_PREFIX):
            blobs.append((path, oid))
    return sorted(blobs)


def _read_batch(repo: Path, oids: list[str]) -> list[bytes]:
    raw = _git(repo, "cat-file", "--batch", stdin="".join(f"{o}\n" for o in oids).encode())
    blobs: list[bytes] = []
    at = 0
    for _ in oids:
        eol = raw.index(b"\n", at)
        size = int(raw[at:eol].split()[2])
        blobs.append(raw[eol + 1 : eol + 1 + size])
        at = eol + 1 + size + 1
    return blobs


def _as_text(blob: bytes) -> str | None:
    if not blob or b"\0" in blob:
        return None
    try:
        return blob.decode("utf-8")
    except UnicodeDecodeError:
        return None


def load_corpus(repo: Path, rev: str) -> Corpus:
    full = _git(repo, "rev-parse", "--verify", f"{rev}^{{commit}}").decode().strip()
    blobs = _tracked_blobs(repo, full)
    contents = _read_batch(repo, [oid for _, oid in blobs])
    digest = hashlib.sha256()
    files: list[CorpusFile] = []
    for (path, oid), blob in zip(blobs, contents):
        text = _as_text(blob)
        if text is None:
            continue
        digest.update(f"{path}\0{oid}\n".encode())
        files.append(CorpusFile(path, text))
    if not files:
        raise CorpusError(f"no text files at {full}")
    return Corpus(full, digest.hexdigest(), tuple(files))


def iter_pieces(corpus: Corpus, seed: int, piece_bytes: int) -> Iterator[Piece]:
    """Endless stream. Past the corpus size it reshuffles with the seed and sets reused."""
    assert piece_bytes > 0
    for round_no in itertools.count():
        order = sorted(corpus.files, key=lambda f: derive_hex(seed, round_no, f.path))
        for f in order:
            data = f.text.encode()
            for offset in range(0, len(data), piece_bytes):
                text = data[offset : offset + piece_bytes].decode("utf-8", "ignore")
                yield Piece(f.path, offset, text, round_no > 0)
