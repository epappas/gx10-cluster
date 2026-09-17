#!/usr/bin/env python3
"""Drop a checkpoint's own clean pages from the page cache, without root.

On GB10 the page cache and the "GPU" pool are the same LPDDR5x. Weights just
downloaded, rsynced to the peer, or read over NFS are still resident as clean
pages, and vLLM then loads the same bytes again into the unified pool - so a
cold boot can die with a CUDA OOM on a machine that looks idle.

`echo 3 > /proc/sys/vm/drop_caches` wants root and throws away every other
process's cache too. `posix_fadvise(POSIX_FADV_DONTNEED)` drops the clean
pages of files you can open, needs no privilege, and touches only these files.
Dirty pages are left alone, so this cannot lose data; the worst case is
re-reading from disk what was about to be re-read anyway.

    python3 evict-page-cache.py <dir> [<dir> ...]

Prints one line to stderr and always exits 0 - evicting the cache is an
optimisation, and refusing to launch over a failed one would be worse.

Mechanism documented in MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks
(AGPL-3.0-or-later); this is an independent implementation of it.
"""

from __future__ import annotations

import os
import socket
import sys

# Only the big files the engine is about to re-read. Configs and tokenizers
# are kilobytes and the loader wants them cached.
SUFFIXES = (".safetensors", ".bin", ".pt", ".gguf")


def evict(path: str, seen: set) -> int:
    """Drop path's clean pages. Returns bytes covered, 0 if it could not.

    Keyed on (device, inode), not on the path: the HF cache names every shard
    twice - snapshots/<sha>/x.safetensors is a symlink onto blobs/<hash> - and
    counting an inode twice would report 300 GiB for a 150 GiB checkpoint.
    """
    try:
        fd = os.open(path, os.O_RDONLY)  # follows the symlink to the blob
    except OSError:
        return 0
    try:
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino) in seen:
            return 0
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        seen.add((st.st_dev, st.st_ino))
        return st.st_size
    except (OSError, AttributeError):  # no posix_fadvise here: not an error
        return 0
    finally:
        os.close(fd)


def main(roots: list[str]) -> int:
    total = files = 0
    seen: set = set()
    for root in roots:
        # NOT followlinks=True: a shard reached through snapshots/ is a symlink
        # to a FILE, already listed here, and os.open follows it to the blob.
        for dirpath, _, names in os.walk(root):
            for name in names:
                if name.endswith(SUFFIXES):
                    got = evict(os.path.join(dirpath, name), seen)
                    total += got
                    files += got > 0
    print(f"page cache  {socket.gethostname()}  released "
          f"{total / 2**30:.1f} GiB over {files} files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
