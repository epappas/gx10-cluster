#!/usr/bin/env python3
"""Assert the directory indexes still describe what is actually there.

An index that has gone stale is worse than no index: it tells you a role or a
runbook does not exist, confidently. This is the cheapest possible guard - it
does not check that the prose is *good*, only that nothing is missing.

    python3 tests/check_docs.py
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r"\]\(([^)]+)\)")
NAME_RE = re.compile(r'<a name="([^"]+)"')


def missing(index: pathlib.Path, needles: list[str], label: str) -> list[str]:
    if not index.exists():
        return [f"{index.relative_to(REPO)} is missing entirely"]
    text = index.read_text()
    return [
        f"{index.relative_to(REPO)} does not mention {label} '{n}'"
        for n in sorted(needles)
        if n not in text
    ]


def slugify(heading: str) -> str:
    """GitHub's anchor rule: lowercase, drop punctuation, spaces to hyphens."""
    text = heading.lstrip("#").strip().lower()
    kept = [c for c in text if c.isalnum() or c in " -_"]
    return "".join(kept).replace(" ", "-")


def check_links(md: pathlib.Path) -> list[str]:
    """Relative links must resolve, and anchors must name a real heading.

    A dead anchor is silent - the page loads and quietly ignores the fragment -
    so nothing but a check like this catches it.
    """
    problems: list[str] = []
    here = md.parent
    for match in LINK_RE.finditer(md.read_text()):
        target = match.group(1).strip()
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path_part, _, anchor = target.partition("#")
        dest = (here / path_part).resolve() if path_part else md
        if not dest.exists():
            problems.append(f"{md.relative_to(REPO)} links to missing {target}")
            continue
        if anchor and dest.suffix == ".md":
            anchors = {slugify(ln) for ln in dest.read_text().splitlines() if ln.startswith("#")}
            # Explicit <a name="..."> targets count too.
            anchors |= set(NAME_RE.findall(dest.read_text()))
            if anchor not in anchors:
                problems.append(f"{md.relative_to(REPO)} links to {target} - no such anchor")
    return problems


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

    # Every markdown file's relative links and anchors resolve
    links = 0
    for md in sorted(REPO.rglob("*.md")):
        if ".git" in md.parts:
            continue
        links += sum(
            1 for m in LINK_RE.finditer(md.read_text())
            if not m.group(1).startswith(("http", "mailto"))
        )
        problems += check_links(md)

    for p in problems:
        print(f"docs: {p}", file=sys.stderr)
    if problems:
        print(
            "docs: fix the entries or links above - do not delete the check",
            file=sys.stderr,
        )
        return 1

    print(
        f"docs: {len(roles)} roles, {len(runbooks)} runbooks, {len(refs)} reference docs, "
        f"{len(varfiles)} vars files indexed; {links} links and anchors resolve"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
