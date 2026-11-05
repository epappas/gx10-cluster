#!/usr/bin/env python3
"""Apply and verify the two approved source backports inside a derived image."""
from __future__ import annotations

import argparse
import hashlib
from importlib.metadata import distribution
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
from typing import Any

MODULES = frozenset({
    "families/glm5_next/cuda/kept_reasoning.py",
    "families/glm5_next/cuda/multi.py", "cuda/health.py", "server/metrics.py",
})
PATCH_NAMES = ("0118-glm-broken-health-exit.patch", "0121-glm-kept-reasoning-linear.patch")
MANIFEST_SHA256 = "f2b062db888c86b800d53a4972c5178e2c804aef27847ac748cc3a6a350af1e6"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def full_sha(value: object, length: int = 64) -> bool:
    return isinstance(value, str) and re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is not None


def load_manifest(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    require(hashlib.sha256(data).hexdigest() == MANIFEST_SHA256,
            "manifest identity differs from the approved two-backport contract")
    value = json.loads(data)
    require(isinstance(value, dict) and type(value.get("schema")) is int and value["schema"] == 1,
            "unsupported backport manifest")
    require(full_sha(value.get("kit_base"), 40) and full_sha(value.get("engine_base"), 40),
            "source references must be full Git SHAs")
    parent = value.get("parent", "")
    require(isinstance(parent, str) and "@sha256:" in parent and full_sha(parent.rsplit(":", 1)[-1]),
            "parent image must use a full registry digest")
    require(value.get("parent_image_id", "").startswith("sha256:")
            and full_sha(value["parent_image_id"][7:]), "invalid parent image ID")
    require(value.get("baseline_patch_count") == 107 and value.get("patch_count") == 109,
            "expected exactly 107 baseline and 109 candidate patches")
    require(full_sha(value.get("baseline_source_sha256")) and full_sha(value.get("source_sha256")),
            "invalid patch-set SHA-256")
    patches = value.get("patches")
    require(isinstance(patches, list) and len(patches) == 2, "expected exactly two backports")
    require(tuple(item.get("file") for item in patches) == PATCH_NAMES, "unexpected backport order")
    for patch in patches:
        require(full_sha(patch.get("sha256")) and full_sha(patch.get("commit"), 40),
                "invalid backport identity")
    require(isinstance(value.get("image_extras"), str) and "\n" not in value["image_extras"],
            "invalid image extras")
    require(set(value.get("modules", {})) == MODULES, "unexpected changed-module set")
    for hashes in value["modules"].values():
        require(set(hashes) == {"before", "after"} and all(full_sha(v) for v in hashes.values()),
                "invalid module hashes")
    return value


def regular_file(root: Path, name: str) -> Path:
    relative = PurePosixPath(name)
    require(bool(relative.parts) and not relative.is_absolute() and ".." not in relative.parts,
            "unsafe source path")
    path = root
    require(not root.is_symlink(), f"symlink source root: {root}")
    for part in relative.parts:
        path = path / part
        require(not path.is_symlink(), f"symlink in source path: {path}")
    require(path.is_file(), f"not a regular source file: {path}")
    require(path.resolve().is_relative_to(root.resolve()), f"source escapes root: {path}")
    return path


def check_payloads(folder: Path, manifest: dict[str, Any]) -> None:
    require({path.name for path in folder.iterdir()} == set(PATCH_NAMES),
            "backport directory contains unexpected files")
    for patch in manifest["patches"]:
        path = regular_file(folder, patch["file"])
        require(sha256(path) == patch["sha256"], f"backport checksum mismatch: {path.name}")


def patch_fingerprint(folder: Path, extras: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    paths = sorted(folder.glob("*.patch"))
    for path in paths:
        regular_file(folder, path.name)
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    digest.update((extras + "\n").encode())
    return len(paths), digest.hexdigest()


def check_patch_set(folder: Path, manifest: dict[str, Any], patched: bool) -> None:
    prefix = "" if patched else "baseline_"
    count, digest = patch_fingerprint(folder, manifest["image_extras"])
    require(count == manifest[prefix + "patch_count"], "unexpected installed patch count")
    require(digest == manifest[prefix + "source_sha256"], "installed patch fingerprint mismatch")


def check_modules(root: Path, manifest: dict[str, Any], phase: str) -> dict[str, str]:
    measured = {}
    for name, hashes in manifest["modules"].items():
        path = regular_file(root / "tensorfold", name)
        measured[name] = sha256(path)
        require(measured[name] == hashes[phase], f"{phase} source checksum mismatch: {name}")
    return measured


def run_patch(root: Path, path: Path, dry_run: bool) -> None:
    args = ["patch", "--batch", "--forward", "--fuzz=0", "--directory", str(root), "-p0", "-i", str(path)]
    if dry_run:
        args.append("--dry-run")
    result = subprocess.run(args, text=True, capture_output=True,
                            env={**os.environ, "LC_ALL": "C"}, timeout=60)
    if result.returncode:
        raise RuntimeError(f"patch failed ({result.returncode}): {result.stdout}{result.stderr}")
    require(not re.search(r"\b(offset|fuzz)\b", result.stdout + result.stderr, re.I),
            "patch application requires an offset or fuzz")
    print(result.stdout, end="")


def expected_provenance(manifest: dict[str, Any], kit_sha: str | None,
                        *, offline: bool = False) -> dict[str, Any]:
    if offline:
        require(kit_sha is None, "offline source checks cannot select a derived kit")
    else:
        require(full_sha(kit_sha, 40) and kit_sha != manifest["kit_base"],
                "derived kit reference must be a full Git SHA distinct from the baseline")
    return {"schema": 1, "scope": "offline-source-only" if offline else "derived-kit",
            "parent": manifest["parent"], "parent_image_id": manifest["parent_image_id"],
            "kit_base": manifest["kit_base"], "kit_sha": kit_sha,
            "source_sha256": manifest["source_sha256"], "patch_count": manifest["patch_count"],
            "fixes": manifest["patches"],
            "modules": {name: hashes["after"] for name, hashes in manifest["modules"].items()}}


def apply_backports(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    require(not args.provenance.exists(), "backport provenance already exists")
    check_payloads(args.manifest.parent / "patches", manifest)
    check_modules(args.source_root, manifest, "before")
    check_patch_set(args.installed_patches, manifest, False)
    provenance = expected_provenance(manifest, args.kit_sha, offline=args.offline_source_check)
    for patch in manifest["patches"]:
        source = args.manifest.parent / "patches" / patch["file"]
        require(not (args.installed_patches / patch["file"]).exists(), "backport already installed")
        run_patch(args.source_root, source, True)
    for patch in manifest["patches"]:
        source = args.manifest.parent / "patches" / patch["file"]
        run_patch(args.source_root, source, False)
        shutil.copyfile(source, args.installed_patches / patch["file"])
    check_modules(args.source_root, manifest, "after")
    check_patch_set(args.installed_patches, manifest, True)
    args.provenance.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(args.provenance, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(provenance, stream, indent=2)
        stream.write("\n")


def verify_backports(args: argparse.Namespace, manifest: dict[str, Any]) -> None:
    check_payloads(args.manifest.parent / "patches", manifest)
    measured = check_modules(args.source_root, manifest, "after")
    check_patch_set(args.installed_patches, manifest, True)
    require(json.loads(args.provenance.read_bytes()) == expected_provenance(
                manifest, args.kit_sha, offline=args.offline_source_check),
            "installed provenance does not match the requested source")
    print(json.dumps({"result": "PASS", "kit_sha": args.kit_sha,
                      "source_sha256": manifest["source_sha256"], "modules": measured}, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "verify"))
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("manifest.json"))
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--installed-patches", type=Path, default=Path("/opt/tf-patches"))
    parser.add_argument("--provenance", type=Path, default=Path("/opt/tf-backports/provenance.json"))
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument("--kit-sha", help="Verified immutable derived-kit commit; required for images")
    identity.add_argument("--offline-source-check", action="store_true",
                          help="Unbound source-only test; records no derived-kit claim")
    args = parser.parse_args()
    args.manifest = args.manifest.resolve(strict=True)
    if args.source_root is None:
        args.source_root = Path(distribution("tensorfold").locate_file(""))
    args.source_root = args.source_root.resolve(strict=True)
    manifest = load_manifest(args.manifest)
    {"apply": apply_backports, "verify": verify_backports}[args.action](args, manifest)


if __name__ == "__main__":
    main()
