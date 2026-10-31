#!/usr/bin/env python3
"""`ws status` sees workspaces that have no compose.yml.

Runs the real `ws` and the real docker, with no shim. The script and its library
are copied beside one throwaway manifest, whose container name is unique, so
this never touches a real workspace's container. Docker absent is real absence:
PATH holds links to every tool `ws` needs, and docker is not one of them.

    python3 tests/check_ws_status.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IMAGE_ENV = "WS_STATUS_IMAGE"
TOOLS = ("bash", "awk", "sed", "tr", "sort", "cat", "basename", "dirname", "readlink", "env", "tput")


def scaffold(root: Path, container: str) -> Path:
    shutil.copy(REPO / "workspaces" / "ws", root / "ws")
    shutil.copytree(REPO / "workspaces" / "lib", root / "lib")
    for name, line in (("probe-running", f"container: {container}\n"),
                       ("probe-prefix", f"container: {container}-longer\n"),
                       ("probe-unnamed", "")):
        folder = root / "inference" / name
        folder.mkdir(parents=True)
        (folder / "workspace.yml").write_text(f"name: {name}\nkind: inference\n{line}")
    return root / "ws"


def status(ws: Path, path: str | None = None) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "PATH": path or os.environ["PATH"]}
    bash = shutil.which("bash")
    return subprocess.run([str(bash), str(ws), "status"], capture_output=True, text=True, env=env, timeout=120)


def docker_free_path(root: Path) -> str:
    folder = root / "bin"
    folder.mkdir()
    for tool in TOOLS:
        found = shutil.which(tool)
        if found:
            os.symlink(found, folder / tool)
    assert shutil.which("docker", path=str(folder)) is None
    return str(folder)


def check_docker_absent(ws: Path, root: Path) -> None:
    done = status(ws, docker_free_path(root))
    assert done.returncode != 0, done.stdout
    assert "docker is not on PATH" in done.stderr, done.stderr
    assert "no workspace is running" not in done.stdout, "a lie: nothing could be checked"


def check_docker_unreachable(ws: Path) -> None:
    """Real docker, pointed at a socket nothing listens on."""
    env = {**os.environ, "DOCKER_HOST": "unix:///nonexistent/docker.sock"}
    done = subprocess.run([str(shutil.which("bash")), str(ws), "status"], capture_output=True,
                          text=True, env=env, timeout=60)
    assert done.returncode != 0, done.stdout
    assert "docker is not reachable" in done.stderr, done.stderr


def local_image() -> str | None:
    wanted = os.environ.get(IMAGE_ENV)
    if wanted:
        return wanted
    listed = subprocess.run(["docker", "images", "--format", "{{.ID}}"], capture_output=True, text=True)
    ids = listed.stdout.split()
    return ids[0] if ids else None


def check_live(ws: Path, container: str, image: str) -> None:
    subprocess.run(["docker", "create", "--name", container, image, "sleep", "60"],
                   check=True, capture_output=True)
    try:
        stopped = status(ws)
        assert stopped.returncode == 0, stopped.stderr
        assert "probe-running" not in stopped.stdout, stopped.stdout
        subprocess.run(["docker", "start", container], check=True, capture_output=True)
        running = status(ws)
        assert running.returncode == 0, running.stderr
        assert "probe-running" in running.stdout and container in running.stdout, running.stdout
        assert "Up " in running.stdout, running.stdout
        assert "probe-prefix" not in running.stdout, "name filter is not exact"
        assert "probe-unnamed" not in running.stdout
    finally:
        subprocess.run(["docker", "rm", "-f", container], capture_output=True)
    after = status(ws)
    assert "probe-running" not in after.stdout, after.stdout


def main() -> int:
    container = f"ws-status-test-{uuid.uuid4().hex[:12]}"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        ws = scaffold(root, container)
        check_docker_absent(ws, root)
        if shutil.which("docker"):
            check_docker_unreachable(ws)
        reachable = shutil.which("docker") and subprocess.run(
            ["docker", "info"], capture_output=True).returncode == 0
        image = local_image() if reachable else None
        if not image:
            print("ws-status: docker-absent case holds; NOT PROVEN - running and stopped "
                  "cases need docker and one local image")
            return 0
        check_live(ws, container, image)
    print("ws-status: running, stopped, exact-name and docker-absent cases hold on real docker")
    return 0


if __name__ == "__main__":
    sys.exit(main())
