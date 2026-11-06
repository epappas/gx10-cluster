#!/usr/bin/env python3
"""Explicitly prepare public pinned fixtures, then run the real offline source gates."""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from types import ModuleType
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "workspaces/inference/tensorfold-2node-glm53-flash-exl3/backports"
OWNER_URL = "https://github.com/epappas/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git"
OWNER_PIN = "2ba40b5aea52114013f770f73c485483d65089a0"


def run(args: list[str], timeout: int = 180) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args!r}\n{result.stdout}{result.stderr}")
    return result


def load_builder() -> ModuleType:
    spec = importlib.util.spec_from_file_location("public_backport_builder", PACKAGE / "build.py")
    if spec is None or spec.loader is None:
        raise ImportError("cannot load actual backport builder")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fetch(directory: Path, url: str, pin: str, depth: int) -> None:
    run(["git", "init", "--quiet", "--template=", str(directory)])
    base = ["git", "-c", "core.hooksPath=/dev/null", "-C", str(directory)]
    run([*base, "remote", "add", "origin", url])
    run([*base, "fetch", "--quiet", "--depth", str(depth), "origin", pin])
    run([*base, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    if run([*base, "rev-parse", "HEAD"]).stdout.strip() != pin:
        raise ValueError("downloaded Git checkout is not the immutable requested pin")


def extract_baseline_patches(kit: Path, pin: str, destination: Path) -> None:
    raw = subprocess.check_output(["git", "--no-replace-objects", "-C", str(kit),
                                   "archive", pin, "--", "patches"], cwd=ROOT, timeout=60)
    destination.mkdir(mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for member in archive:
            if member.isdir() and member.name == "patches":
                continue
            parts = member.name.split("/")
            if not member.isfile() or len(parts) != 2 or parts[0] != "patches" or not parts[1].endswith(".patch"):
                raise ValueError("unexpected entry in the pinned patch archive")
            if member.size > 20 * 1024**2:
                raise ValueError("pinned patch exceeds the bounded extraction size")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("cannot read pinned patch bytes")
            (destination / parts[1]).write_bytes(stream.read())


def validate(cache: Path, builder: ModuleType) -> None:
    checks = builder.verifier()
    manifest = checks.load_manifest(PACKAGE / "manifest.json")
    builder.check_kit(cache / "kit-data", OWNER_PIN, manifest, checks)
    if builder.git(cache / "engine-data", "rev-parse", "HEAD") != manifest["engine_base"]:
        raise ValueError("fixture engine pin differs")
    checks.check_patch_set(cache / "baseline-patches", manifest, False)
    checks.check_modules(cache / "baseline", manifest, "before")
    checks.check_modules(cache / "candidate", manifest, "after")
    checks.check_patch_set(cache / "candidate-patches", manifest, True)
    run([sys.executable, "-I", "-B", str(PACKAGE / "apply.py"), "verify", "--offline-source-check",
         "--source-root", str(cache / "candidate"), "--installed-patches", str(cache / "candidate-patches"),
         "--provenance", str(cache / "source-proof.json")])


def prepare(cache: Path, builder: ModuleType) -> None:
    if cache.exists():
        validate(cache, builder)
        print("Existing public-source fixtures revalidated; no network acquisition needed.")
        return
    cache.mkdir(mode=0o700, parents=True)
    checks = builder.verifier()
    manifest = checks.load_manifest(PACKAGE / "manifest.json")
    fetch(cache / "kit-data", OWNER_URL, OWNER_PIN, 2)
    fetch(cache / "engine-data", manifest["engine_url"], manifest["engine_base"], 1)
    extract_baseline_patches(cache / "kit-data", manifest["kit_base"], cache / "baseline-patches")
    checks.check_patch_set(cache / "baseline-patches", manifest, False)
    shutil.copytree(cache / "engine-data/src", cache / "baseline")
    for patch in sorted((cache / "baseline-patches").glob("*.patch")):
        run(["patch", "--batch", "--forward", "--fuzz=0", "-p0", "--directory", str(cache / "baseline"),
             "--input", str(patch)])
    checks.check_modules(cache / "baseline", manifest, "before")
    shutil.copytree(cache / "baseline", cache / "candidate")
    shutil.copytree(cache / "baseline-patches", cache / "candidate-patches")
    run([sys.executable, "-I", "-B", str(PACKAGE / "apply.py"), "apply", "--offline-source-check",
         "--source-root", str(cache / "candidate"), "--installed-patches", str(cache / "candidate-patches"),
         "--provenance", str(cache / "source-proof.json")])
    validate(cache, builder)
    print("Prepared complete actual source packages from immutable public Git objects.")


def reasoning(cache: Path, phase: str) -> None:
    command = [sys.executable, "-I", "-B", str(ROOT / "tests/check_glm_backports.py"),
               "--source-root", str(cache / phase)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=60)
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    measurements = next(item["actual_work_measurements"] for item in records if "actual_work_measurements" in item)
    actual = [(item["steps"], item["actual_calls"]) for item in measurements]
    expected = [(64, 2080), (128, 8256)] if phase == "baseline" else [(64, 128), (128, 256)]
    if actual != expected or result.returncode != (1 if phase == "baseline" else 0):
        raise AssertionError(f"unexpected {phase} result: {result.returncode}\n{result.stdout}{result.stderr}")
    if phase == "baseline" and "FAILED (failures=2)" not in result.stderr:
        raise AssertionError("baseline did not fail solely on the two real traversal-work bounds")
    print(json.dumps({"phase": phase, "expected_exit_observed": result.returncode,
                      "actual_work_measurements": measurements}))


def check(cache: Path, builder: ModuleType) -> None:
    validate(cache, builder)
    reasoning(cache, "baseline")
    reasoning(cache, "candidate")
    artifacts = cache.parent / ("builder-gate-" + uuid.uuid4().hex)
    result = run([sys.executable, "-I", "-B", str(ROOT / "tests/check_glm_backport_build.py"),
                  "--baseline-root", str(cache / "baseline"), "--kit-git", str(cache / "kit-data"),
                  "--artifact-dir", str(artifacts)], timeout=300)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    print("Public-source and offline regression gates PASS; ARM dependency-image and live serving gates are separate.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "check"))
    parser.add_argument("--cache", type=Path, default=ROOT / ".private-publication/glm-backport-fixtures")
    args = parser.parse_args()
    os.umask(0o077)
    private = ROOT / ".private-publication"
    private.mkdir(mode=0o700, exist_ok=True)
    cache = args.cache.resolve()
    if not cache.is_relative_to(private.resolve()) or cache == private.resolve():
        parser.error("generated fixture cache must be inside this worktree's ignored private artifact directory")
    builder = load_builder()
    {"prepare": prepare, "check": check}[args.action](cache, builder)


if __name__ == "__main__":
    main()
