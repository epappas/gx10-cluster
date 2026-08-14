#!/usr/bin/env python3
"""Assert the directory indexes still describe what is actually there.

An index that has gone stale is worse than no index: it tells you a role or a
runbook does not exist, confidently. This is the cheapest possible guard - it
does not check that the prose is *good*, only that nothing is missing.

    python3 tests/check_docs.py
"""

from __future__ import annotations

import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent


def missing(index: pathlib.Path, needles: list[str], label: str) -> list[str]:
    if not index.exists():
        return [f"{index.relative_to(REPO)} is missing entirely"]
    text = index.read_text()
    return [
        f"{index.relative_to(REPO)} does not mention {label} '{n}'"
        for n in sorted(needles)
        if n not in text
    ]


def main() -> int:
    problems: list[str] = []

    # Every role appears in roles/README.md
    roles = [p.name for p in (REPO / "roles").iterdir() if p.is_dir()]
    problems += missing(REPO / "roles" / "README.md", roles, "role")

    # Every runbook is linked from its index and from the top-level README
    runbooks = [
        p.name for p in (REPO / "docs" / "runbooks").glob("*.md") if p.name != "README.md"
    ]
    problems += missing(REPO / "docs" / "runbooks" / "README.md", runbooks, "runbook")
    problems += missing(REPO / "README.md", runbooks, "runbook")

    # Every reference doc is linked from the docs index
    refs = [p.name for p in (REPO / "docs").glob("*.md") if p.name != "README.md"]
    problems += missing(REPO / "docs" / "README.md", refs, "doc")

    # Every vars file is described
    varfiles = [p.name for p in (REPO / "vars").glob("*.yml")]
    problems += missing(REPO / "vars" / "README.md", varfiles, "vars file")

    for p in problems:
        print(f"docs: {p}", file=sys.stderr)
    if problems:
        print(
            "docs: indexes are stale - add the missing entries, do not delete the check",
            file=sys.stderr,
        )
        return 1

    print(
        f"docs: indexes cover {len(roles)} roles, {len(runbooks)} runbooks, "
        f"{len(refs)} reference docs, {len(varfiles)} vars files"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
