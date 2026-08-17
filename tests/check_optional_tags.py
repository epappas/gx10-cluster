#!/usr/bin/env python3
"""Assert every tagged `include_role` in optional.yml applies its tag downward.

Tags on a dynamic include select the INCLUDE, not the tasks inside it. The
role's own tasks carry no tag, so under `--tags ray` the include matches, runs,
and then every task it pulled in is filtered out. The result is
`make optional TAGS=ray` reporting `ok=1 changed=0` having installed nothing -
a silent no-op that is indistinguishable from success, and which affected every
entry in optional.yml at once.

`apply: tags:` is the documented mechanism that pushes the tag onto the
included tasks. This check exists because nothing else catches its absence:

  - ansible-lint does not know the include is meant to do anything.
  - `--syntax-check` passes; the YAML is valid either way.
  - `--list-tasks --tags <t>` does NOT expand dynamic includes, so it prints
    the include and stops, looking identical whether the role runs or not.
    That is precisely the check that let the bug survive in the first place.

Only a real run against real hardware would otherwise notice, which is the one
place this repo cannot test.

    python3 tests/check_optional_tags.py     # exit 1 on any include missing it
"""

from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - environment problem, not a finding
    sys.exit(
        "optional-tags: PyYAML is required (pip install pyyaml).\n"
        "  A bare interpreter cannot import it, and pipx venvs are isolated,\n"
        "  so install it into the interpreter that runs the test suite."
    )

REPO = pathlib.Path(__file__).resolve().parent.parent
PLAYBOOK = REPO / "optional.yml"

# The tag every optional entry carries to keep a bare run a no-op. It is never
# the tag that selects the entry, so it is excluded when working out what the
# apply block should contain.
NEVER = "never"


def main() -> int:
    if not PLAYBOOK.exists():
        print(f"optional-tags: {PLAYBOOK.name} is missing entirely", file=sys.stderr)
        return 1

    problems: list[str] = []
    checked = 0

    for play in yaml.safe_load(PLAYBOOK.read_text()) or []:
        for task in play.get("tasks") or []:
            include = task.get("ansible.builtin.include_role") or task.get("include_role")
            if not include:
                continue

            name = task.get("name", "(unnamed task)")
            # Tags that actually select this entry - everything but `never`.
            selectors = [t for t in (task.get("tags") or []) if t != NEVER]
            if not selectors:
                # An untagged include always runs; there is nothing to push down.
                continue

            checked += 1
            applied = ((include.get("apply") or {}).get("tags")) or []

            missing = [t for t in selectors if t not in applied]
            if missing:
                problems.append(
                    f"'{name}' is selected by {selectors} but does not apply "
                    f"{missing} to the included tasks - `make optional "
                    f"TAGS={selectors[0]}` would run zero tasks and report success. "
                    f"Add:\n"
                    f"        apply:\n"
                    f"          tags: [{selectors[0]}]"
                )
                continue

            # The other direction: applying a tag the entry is NOT selected by
            # re-creates the exporters-pulls-in-dashboards bug the `roles:` list
            # had, just one level down.
            extra = [t for t in applied if t not in selectors]
            if extra:
                problems.append(
                    f"'{name}' applies {extra} to its included tasks but is not "
                    f"selected by {extra} - that widens the tag and lets one "
                    f"component drag in another."
                )

    for p in problems:
        print(f"optional-tags: {p}", file=sys.stderr)
    if problems:
        print(
            "optional-tags: fix the entries above - an opt-in component that "
            "installs nothing is worse than one that fails.",
            file=sys.stderr,
        )
        return 1

    print(f"optional-tags: {checked} tagged include_role(s) apply their tag to included tasks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
