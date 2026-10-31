"""Host-side file tools. Their arguments are model output, so they are untrusted.

Each path goes through realpath containment. Every open uses O_NOFOLLOW and
O_NONBLOCK and then fstat, so a symlink is refused and a FIFO cannot hang us.
Grep takes a fixed string, so a model regex cannot hang it either.
"""

from __future__ import annotations

import errno
import os
import stat
from pathlib import Path

MAX_READ_BYTES = 64 * 1024
MAX_WRITE_BYTES = 256 * 1024
MAX_LIST_ENTRIES = 1000
MAX_GREP_LINES = 200
MAX_GREP_FILE_BYTES = 1024 * 1024
MAX_PATH_DEPTH = 32  # deeper trees reach RecursionError in glob and makedirs


class ToolError(Exception):
    """Goes back to the model as a tool result."""


def cap_text(text: str, limit: int) -> str:
    """One bound on what any tool returns, with a marker when it cut."""
    data = text.encode("utf-8", "replace")
    if len(data) <= limit:
        return text
    return data[:limit].decode("utf-8", "ignore") + f"\n[truncated at {limit} bytes]\n"


def _resolve(root: Path, path: str) -> str:
    if not isinstance(path, str) or not path or "\0" in path:
        raise ToolError("invalid path")
    base = os.path.realpath(root)
    resolved = os.path.realpath(os.path.join(base, path))
    if resolved != base and not resolved.startswith(base + os.sep):
        raise ToolError(f"path is outside the project: {path}")
    return resolved


def _refuse_links(root: Path, path: str) -> None:
    """The last component may not be a link, even one that stays inside."""
    base = os.path.realpath(root)
    joined = os.path.normpath(os.path.join(base, path))
    if joined != base and not joined.startswith(base + os.sep):
        raise ToolError(f"path is outside the project: {path}")
    if os.path.islink(joined):
        raise ToolError(f"path is a symbolic link: {path}")


def _open_regular(path: str, flags: int) -> int:
    try:
        fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o644)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENXIO):
            raise ToolError("not a regular file") from exc
        raise ToolError(exc.strerror or "cannot open file") from exc
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ToolError("not a regular file")
    return fd


def read_file(root: Path, path: str, offset: int = 0) -> str:
    _refuse_links(root, path)
    resolved = _resolve(root, path)
    if offset < 0:
        raise ToolError("offset must not be negative")
    fd = _open_regular(resolved, os.O_RDONLY)
    try:
        size = os.fstat(fd).st_size
        data = os.pread(fd, MAX_READ_BYTES, offset) if offset < size else b""
    finally:
        os.close(fd)
    text = data.decode("utf-8", "replace")
    if offset + len(data) < size:
        text += f"\n[truncated: file has {size} bytes, read again from offset {offset + len(data)}]"
    return text


def write_file(root: Path, path: str, content: str) -> str:
    _refuse_links(root, path)
    resolved = _resolve(root, path)
    if len(Path(path).parts) > MAX_PATH_DEPTH:
        raise ToolError(f"path deeper than {MAX_PATH_DEPTH} components")
    data = content.encode()
    if len(data) > MAX_WRITE_BYTES:
        raise ToolError(f"content over the {MAX_WRITE_BYTES} byte limit")
    if os.path.lexists(resolved) and not stat.S_ISREG(os.lstat(resolved).st_mode):
        raise ToolError("not a regular file")
    os.makedirs(os.path.dirname(resolved), exist_ok=True)
    fd = _open_regular(resolved, os.O_WRONLY | os.O_CREAT)
    try:
        os.ftruncate(fd, 0)
        os.write(fd, data)
    finally:
        os.close(fd)
    return f"wrote {len(data)} bytes to {path}"


def list_dir(root: Path, path: str) -> str:
    _refuse_links(root, path)
    resolved = _resolve(root, path)
    if not stat.S_ISDIR(_lstat(resolved).st_mode):
        raise ToolError("not a directory")
    with os.scandir(resolved) as entries:
        names = sorted(e.name + ("/" if e.is_dir(follow_symlinks=False) else "") for e in entries)
    extra = len(names) - MAX_LIST_ENTRIES
    marker = [f"[truncated: {extra} more entries]"] if extra > 0 else []
    return "\n".join(names[:MAX_LIST_ENTRIES] + marker)


def _lstat(path: str) -> os.stat_result:
    try:
        return os.lstat(path)
    except OSError as exc:
        raise ToolError(exc.strerror or "cannot stat path") from exc


def _walk_files(start: str) -> list[str]:
    if stat.S_ISREG(_lstat(start).st_mode):
        return [start]
    if not stat.S_ISDIR(_lstat(start).st_mode):
        raise ToolError("not a file or directory")
    found: list[str] = []
    for folder, dirs, files in os.walk(start, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(folder, d)))
        found.extend(os.path.join(folder, f) for f in sorted(files))
    return found


def _grep_file(path: str, needle: str) -> list[tuple[int, str]]:
    try:
        fd = _open_regular(path, os.O_RDONLY)
    except ToolError:
        return []
    try:
        data = os.read(fd, MAX_GREP_FILE_BYTES)
    finally:
        os.close(fd)
    lines = data.decode("utf-8", "replace").splitlines()
    return [(n, line) for n, line in enumerate(lines, 1) if needle in line]


def grep(root: Path, pattern: str, path: str = ".") -> str:
    if not pattern:
        raise ToolError("empty pattern")
    _refuse_links(root, path)
    start = _resolve(root, path)
    base = os.path.realpath(root)
    hits: list[str] = []
    for file_path in _walk_files(start):
        for number, line in _grep_file(file_path, pattern):
            hits.append(f"{os.path.relpath(file_path, base)}:{number}:{line[:400]}")
            if len(hits) >= MAX_GREP_LINES:
                return "\n".join(hits) + "\n[truncated]"
    return "\n".join(hits)
