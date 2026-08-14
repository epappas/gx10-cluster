#!/usr/bin/env python3
"""Assert every `notify:` names a handler that exists in the same role.

Ansible only errors on an unknown handler when the notifying task actually
reports changed. So a typo'd notify stays invisible on an already-provisioned
box and detonates on a first-time provision - the run you least want to fail.
Nothing else in the offline suite can see it.

Deliberately parses YAML rather than grepping: a notify value can be a string
or a list, and handler names contain spaces, which shell word-splitting eats.

    python3 tests/check_handlers.py     # exit 1 on any unresolved notify
"""

from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - environment problem, not a finding
    sys.exit(
        "handlers: PyYAML is required (pip install pyyaml).\n"
        "  A bare interpreter cannot import it, and pipx venvs are isolated,\n"
        "  so ansible-core's own copy is not visible from here."
    )


def collect_notifies(node) -> list[str]:
    """Every notify value anywhere in a parsed task file."""
    found: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "notify":
                found.extend([value] if isinstance(value, str) else value)
            else:
                found.extend(collect_notifies(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(collect_notifies(item))
    return found


def handler_names(role: pathlib.Path) -> set[str]:
    names: set[str] = set()
    for handler_file in (role / "handlers").glob("*.yml"):
        for task in yaml.safe_load(handler_file.read_text()) or []:
            if isinstance(task, dict) and "name" in task:
                names.add(task["name"])
                names.update(task.get("listen", []) if isinstance(task.get("listen"), list) else [])
    return names


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    problems: list[str] = []
    checked = 0

    for role in sorted((repo / "roles").iterdir()):
        if not role.is_dir():
            continue
        defined = handler_names(role)
        for task_file in sorted((role / "tasks").glob("*.yml")):
            for notify in collect_notifies(yaml.safe_load(task_file.read_text())):
                checked += 1
                if notify not in defined:
                    problems.append(
                        f"{task_file.relative_to(repo)} notifies {notify!r}, "
                        f"but role '{role.name}' defines {sorted(defined) or 'no handlers'}"
                    )

    for problem in problems:
        print(f"handlers: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"handlers: {checked} notify reference(s) all resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
