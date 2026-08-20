#!/usr/bin/env python3
"""Every workspace manifest is well-formed, and every workspace is runnable.

The manifests are parsed by `ws` with awk, not a YAML library, so a structure
awk cannot read is a runtime failure with no error message - it silently yields
an empty field and the workspace looks nameless or requirement-free. This guard
turns that into an offline failure.

It also enforces the two claims `ws list` makes: that a name matches its
directory, and that provenance is one of the two values the colouring knows.
"""
import pathlib
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
WS = REPO / "workspaces"

# `bench` and `agent` are clients, not servers: they need a RUNNING endpoint
# rather than a free GPU, which is why they carry almost no `requires:`.
KINDS = {"inference", "cluster", "rl", "bench", "agent"}
PROVENANCE = {"verified", "unverified"}
REQUIRED = ("name", "kind", "engine", "provenance", "summary")
KNOWN_REQUIRES = {"gpu_arch", "min_unified_gb", "min_disk_gb", "docker", "rdma", "peers"}


def main() -> int:
    problems: list[str] = []
    manifests = sorted(WS.glob("*/*/workspace.yml"))
    if not manifests:
        print("workspaces: no manifests found", file=sys.stderr)
        return 1

    for m in manifests:
        rel = m.relative_to(REPO)
        try:
            doc = yaml.safe_load(m.read_text()) or {}
        except yaml.YAMLError as exc:
            problems.append(f"{rel}: not valid YAML: {exc}")
            continue

        for key in REQUIRED:
            if not doc.get(key):
                problems.append(f"{rel}: missing required key '{key}'")

        # `ws` resolves a workspace by DIRECTORY name, then prints the `name`
        # field. If they disagree, `ws up <what list showed>` fails to resolve.
        if doc.get("name") and doc["name"] != m.parent.name:
            problems.append(
                f"{rel}: name '{doc['name']}' != directory '{m.parent.name}'"
            )
        if doc.get("kind") and doc["kind"] not in KINDS:
            problems.append(f"{rel}: kind '{doc['kind']}' not in {sorted(KINDS)}")
        if doc.get("provenance") and doc["provenance"] not in PROVENANCE:
            problems.append(
                f"{rel}: provenance '{doc['provenance']}' not in {sorted(PROVENANCE)}"
            )

        # A typo'd requirement key is the dangerous case: ws_req finds nothing,
        # the check silently never runs, and preflight reports ready.
        for key in (doc.get("requires") or {}):
            if key not in KNOWN_REQUIRES:
                problems.append(
                    f"{rel}: unknown requires key '{key}' - ws would silently "
                    f"skip it. Known: {sorted(KNOWN_REQUIRES)}"
                )

        # Flags come from somewhere. Requiring a source is what keeps these
        # recipes from drifting into folklore.
        if not doc.get("sources"):
            problems.append(f"{rel}: no sources - where did these flags come from?")

        # Something has to actually run.
        d = m.parent
        if not any((d / f).exists() for f in ("compose.yml", "up.sh")):
            if doc.get("kind") != "cluster":
                problems.append(f"{rel}: no compose.yml and no up.sh - nothing to run")

        for script in d.glob("*.sh"):
            if not script.stat().st_mode & 0o111:
                problems.append(f"{rel.parent}/{script.name}: not executable")

    for p in problems:
        print(f"workspaces: {p}", file=sys.stderr)
    if problems:
        return 1

    kinds = sorted({(yaml.safe_load(m.read_text()) or {}).get("kind") for m in manifests})
    print(f"workspaces: {len(manifests)} manifests valid across {len(kinds)} kinds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
