#!/usr/bin/env python3
"""Build or inspect a private two-backport image without replacing dependencies."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
from types import ModuleType
from typing import Any

HERE = Path(__file__).resolve().parent
MODULE_ROOT = "/usr/local/lib/python3.12/dist-packages/tensorfold"
IMAGE_IDENT = "{{.RootFS.Layers}}{{.Config.Env}}{{.Config.Entrypoint}}{{.Config.Cmd}}{{.Config.WorkingDir}}"
RUNTIME_FIELDS = ("Env", "Entrypoint", "Cmd", "WorkingDir", "User", "ExposedPorts", "Volumes",
                  "Healthcheck", "StopSignal", "Shell")


def verifier() -> ModuleType:
    spec = importlib.util.spec_from_file_location("glm_backport_apply", HERE / "apply.py")
    if spec is None or spec.loader is None:
        raise ImportError("cannot load the repository backport verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args!r}\n{result.stdout}{result.stderr}")
    return result


def git(directory: Path, *args: str) -> str:
    return run(["git", "--no-replace-objects", "-C", str(directory), *args]).stdout.strip()


def checkout_tree(directory: Path, sha: str) -> dict[str, tuple[str, str]]:
    entries = git(directory, "ls-tree", "-r", "-z", "--full-tree", sha).split("\0")
    result: dict[str, tuple[str, str]] = {}
    for entry in filter(None, entries):
        header, name = entry.split("\t", 1)
        mode, kind, object_id = header.split()
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ValueError(f"unsupported checkout source entry: {name}")
        result[name] = (mode, object_id)
    return result


def runtime_cache(name: str, tracked: dict[str, tuple[str, str]]) -> bool:
    path = Path(name)
    if path.parent.name != "__pycache__":
        return False
    match = re.fullmatch(r"(.+)\.cpython-[0-9]+(?:\.opt-[012])?\.pyc", path.name)
    return match is not None and str(path.parent.parent / (match[1] + ".py")) in tracked


def check_checkout(directory: Path, sha: str, checks: ModuleType) -> None:
    checks.require(checks.full_sha(sha, 40), "checkout source requires a full commit SHA")
    checks.require(git(directory, "rev-parse", "HEAD") == sha,
                   "kit checkout is not the requested commit")
    tracked = checkout_tree(directory, sha)
    for name, (mode, object_id) in tracked.items():
        path = checks.regular_file(directory, name)
        actual = git(directory, "hash-object", "--no-filters", "--", str(path.resolve()))
        checks.require(actual == object_id, f"checkout source checksum mismatch: {name}")
        checks.require(bool(path.stat().st_mode & 0o111) == (mode == "100755"),
                       f"checkout source executable mode mismatch: {name}")
    checks.require(not git(directory, "diff", "--cached", "--name-only", sha, "--"),
                   "checkout source index differs from the requested commit")
    for folder, directories, files in os.walk(directory, followlinks=False):
        if Path(folder) == directory:
            directories[:] = [name for name in directories if name != ".git"]
            files = [name for name in files if name != ".git"]
        for name in directories:
            checks.require(not (Path(folder) / name).is_symlink(), "symlink checkout directory")
        for name in files:
            path = Path(folder) / name
            relative = str(path.relative_to(directory))
            checks.require(path.is_file() and not path.is_symlink(),
                           f"not a regular checkout file: {relative}")
            checks.require(relative in tracked or runtime_cache(relative, tracked),
                           f"unexpected checkout file: {relative}")


def check_kit(directory: Path, sha: str, manifest: dict[str, Any], checks: ModuleType) -> None:
    checks.require(checks.full_sha(sha, 40) and sha != manifest["kit_base"],
                   "derived kit must be a full commit SHA distinct from the baseline")
    check_checkout(directory, sha, checks)
    git(directory, "merge-base", "--is-ancestor", manifest["kit_base"], sha)
    expected = {"A\tpatches/" + item["file"] for item in manifest["patches"]}
    changed = set(git(directory, "diff", "--name-status", manifest["kit_base"], sha).splitlines())
    checks.require(changed == expected, "derived source must add only the two approved payloads")
    checks.check_patch_set(directory / "patches", manifest, True)
    for patch in manifest["patches"]:
        path = checks.regular_file(directory / "patches", patch["file"])
        checks.require(checks.sha256(path) == patch["sha256"], "fork payload checksum mismatch")


def inspect_image(reference: str) -> dict[str, Any]:
    values = json.loads(run(["docker", "image", "inspect", reference]).stdout)
    if not isinstance(values, list) or len(values) != 1:
        raise ValueError("expected exactly one inspected image")
    return values[0]


def parent_image(manifest: dict[str, Any], checks: ModuleType) -> dict[str, Any]:
    parent = inspect_image(manifest["parent"])
    checks.require(manifest["parent"] in parent.get("RepoDigests", []),
                   "cached parent does not attest the pinned registry digest; no pull was performed")
    checks.require(parent.get("Architecture") == "arm64" and parent.get("Os") == "linux",
                   "parent must be the Linux ARM64 image")
    checks.require(parent["Config"].get("Labels", {}).get("tf.patches")
                   == manifest["baseline_source_sha256"][:12], "wrong parent patch identity")
    checks.require(bool(parent["RootFS"]["Layers"]), "parent has no recorded filesystem layers")
    return parent


def content_identity(reference: str) -> str:
    text = run(["docker", "image", "inspect", "--format", IMAGE_IDENT, reference]).stdout
    return hashlib.sha256((text.rstrip("\n") + "\n").encode()).hexdigest()


def container_file(container: str, path: str, maximum: int = 2 * 1024 * 1024) -> bytes:
    process = subprocess.Popen(["docker", "cp", f"{container}:{path}", "-"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        if process.stdout is None:
            raise RuntimeError("docker cp has no output stream")
        with tarfile.open(fileobj=process.stdout, mode="r|*") as archive:
            entries = []
            for member in archive:
                if not member.isfile():
                    continue
                if member.size > maximum:
                    raise ValueError(f"image verification file exceeds bound: {path}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f"cannot read image file: {path}")
                entries.append(stream.read(maximum + 1))
        error = process.communicate(timeout=30)[1]
        if process.returncode:
            raise RuntimeError(f"docker cp failed: {error.decode(errors='replace')}")
        if len(entries) != 1 or len(entries[0]) > maximum:
            raise ValueError(f"expected exactly one bounded regular image file: {path}")
        return entries[0]
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def verify_files(reference: str, sha: str, manifest: dict[str, Any], checks: ModuleType) -> None:
    container = run(["docker", "create", "--network", "none", "--entrypoint", "/bin/true", reference]).stdout.strip()
    checks.require(bool(container), "docker did not return a verification container ID")
    try:
        for path, hashes in manifest["modules"].items():
            data = container_file(container, MODULE_ROOT + "/" + path)
            checks.require(hashlib.sha256(data).hexdigest() == hashes["after"],
                           f"candidate source checksum mismatch: {path}")
        data = container_file(container, "/opt/tf-backports/provenance.json")
        checks.require(json.loads(data) == checks.expected_provenance(manifest, sha),
                       "candidate source provenance mismatch")
        for patch in manifest["patches"]:
            data = container_file(container, "/opt/tf-patches/" + patch["file"])
            checks.require(hashlib.sha256(data).hexdigest() == patch["sha256"],
                           "candidate does not contain the selected patch payload")
    finally:
        run(["docker", "rm", "--volumes", container])


def verify_image(reference: str, sha: str, manifest: dict[str, Any], checks: ModuleType) -> dict[str, Any]:
    parent = parent_image(manifest, checks)
    candidate = inspect_image(reference)
    checks.require(candidate.get("Architecture") == "arm64" and candidate.get("Os") == "linux",
                   "candidate must be Linux ARM64")
    layers = parent["RootFS"]["Layers"]
    checks.require(candidate["RootFS"]["Layers"][:len(layers)] == layers
                   and len(candidate["RootFS"]["Layers"]) > len(layers),
                   "candidate does not preserve the complete parent layer prefix")
    for field in RUNTIME_FIELDS:
        checks.require(candidate["Config"].get(field) == parent["Config"].get(field),
                       f"candidate changed image runtime configuration: {field}")
    labels = candidate["Config"].get("Labels", {})
    expected = {"tf.patches": manifest["source_sha256"][:12], "gx10.glm.parent": manifest["parent"],
                "gx10.glm.kit": sha, "gx10.glm.fix.0118": manifest["patches"][0]["commit"],
                "gx10.glm.fix.0121": manifest["patches"][1]["commit"]}
    checks.require(all(labels.get(key) == value for key, value in expected.items()),
                   "candidate image labels do not match source provenance")
    verify_files(reference, sha, manifest, checks)
    return {"image_id": candidate["Id"], "content_identity": content_identity(reference),
            "parent_image_id": parent["Id"], "parent_registry_reference": manifest["parent"],
            "kit_sha": sha, "source_sha256": manifest["source_sha256"],
            "parent_layer_count": len(layers), "layer_count": len(candidate["RootFS"]["Layers"])}


def build_image(args: argparse.Namespace, manifest: dict[str, Any], checks: ModuleType) -> dict[str, Any]:
    architecture = run(["docker", "info", "--format", "{{.Architecture}}"]).stdout.strip()
    checks.require(architecture in ("aarch64", "arm64"), "build requires an approved native ARM64 Docker host")
    parent_image(manifest, checks)
    checks.check_payloads(HERE / "patches", manifest)
    command = ["docker", "build", "--pull=false", "--network=none", "--platform=linux/arm64",
               "--build-arg", "BASE_IMAGE=" + manifest["parent"],
               "--build-arg", "KIT_SHA=" + args.kit_sha, "--tag", args.image,
               "--file", str(HERE / "Dockerfile"), str(HERE)]
    result = run(command, timeout=args.timeout)
    print(result.stdout, end="")
    result_value = verify_image(args.image, args.kit_sha, manifest, checks)
    result_value["build_command"] = command
    return result_value


def save_receipt(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify"))
    parser.add_argument("--kit-dir", required=True, type=Path)
    parser.add_argument("--kit-sha", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    checks = verifier()
    manifest = checks.load_manifest(HERE / "manifest.json")
    checks.require(not args.receipt.exists(), "receipt path already exists")
    checks.require(0 < args.timeout <= 1800, "build timeout must be within 1..1800 seconds")
    check_kit(args.kit_dir.resolve(strict=True), args.kit_sha, manifest, checks)
    result = (build_image(args, manifest, checks) if args.action == "build"
              else verify_image(args.image, args.kit_sha, manifest, checks))
    result.update({"result": "PASS", "verified_utc": datetime.now(timezone.utc).isoformat(),
                   "scope": "Source/image identity only; no model, GPU-error, or serving validation."})
    save_receipt(args.receipt, result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
