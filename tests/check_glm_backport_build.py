#!/usr/bin/env python3
"""Offline gates using real parent modules and the pinned public kit's Git objects.

This does not build an image, select a derived source pin, or prove GPU behavior.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
from types import ModuleType
from typing import Any
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "workspaces/inference/tensorfold-2node-glm53-flash-exl3/backports"


def load(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location("backport_" + name, PACKAGE / (name + ".py"))
    if spec is None or spec.loader is None:
        raise ImportError(name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuildChecks(unittest.TestCase):
    apply: ModuleType
    build: ModuleType
    manifest: dict[str, Any]
    baseline: Path
    kit: Path
    artifacts: Path

    def setUp(self) -> None:
        self.folder = self.artifacts / self.id().rsplit(".", 1)[-1]
        self.folder.mkdir(mode=0o700)

    def inputs(self) -> tuple[Path, Path]:
        source = self.folder / "source"
        for name in self.manifest["modules"]:
            origin = self.apply.regular_file(self.baseline, "tensorfold/" + name)
            target = source / "tensorfold" / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(origin, target)
        patches = self.folder / "installed-patches"
        shutil.copytree(self.kit / "patches", patches)
        return source, patches

    def invoke(self, action: str, source: Path, patches: Path,
               *extra: str) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, "-I", "-B", str(PACKAGE / "apply.py"), action,
                   "--source-root", str(source), "--installed-patches", str(patches),
                   "--provenance", str(self.folder / "provenance.json"), *extra]
        if "--kit-sha" not in extra:
            command.append("--offline-source-check")
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        receipt = {"command": command, "exit": result.returncode,
                   "stdout": result.stdout, "stderr": result.stderr}
        path = self.folder / (action + "-" + str(len(list(self.folder.glob("*.json")))) + ".json")
        path.write_text(json.dumps(receipt, indent=2) + "\n")
        return result

    def test_exact_payloads_and_real_overlay(self) -> None:
        self.apply.check_payloads(PACKAGE / "patches", self.manifest)
        source, patches = self.inputs()
        self.apply.check_modules(source, self.manifest, "before")
        self.apply.check_patch_set(patches, self.manifest, False)
        before = {p.name: self.apply.sha256(p) for p in patches.iterdir()}
        applied = self.invoke("apply", source, patches)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        verified = self.invoke("verify", source, patches)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        count, digest = self.apply.patch_fingerprint(patches, self.manifest["image_extras"])
        self.assertEqual((count, digest), (109, self.manifest["source_sha256"]))
        for name, digest_before in before.items():
            self.assertEqual(self.apply.sha256(patches / name), digest_before)
        provenance = json.loads((self.folder / "provenance.json").read_bytes())
        self.assertIsNone(provenance["kit_sha"], "offline proof must not invent a derived source pin")
        self.assertEqual(provenance["scope"], "offline-source-only")
        with self.assertRaisesRegex(ValueError, "derived kit"):
            self.apply.expected_provenance(self.manifest, provenance["kit_sha"])
        repeated = self.invoke("apply", source, patches)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertIn("provenance already exists", repeated.stderr)
        print(json.dumps({"patch_count": count, "fingerprint": self.manifest["source_sha256"],
                          "modules": self.apply.check_modules(source, self.manifest, "after"),
                          "kit_sha": None}, sort_keys=True))

    def test_reject_changed_manifest_identities(self) -> None:
        for key, value in (("parent", "other@sha256:" + "0" * 64),
                           ("parent_image_id", "sha256:" + "0" * 64),
                           ("kit_base", "0" * 40), ("engine_base", "0" * 40),
                           ("source_sha256", "0" * 64), ("image_extras", "")):
            with self.subTest(key=key):
                changed = deepcopy(self.manifest)
                changed[key] = value
                path = self.folder / (key + ".json")
                path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, "manifest identity"):
                    self.apply.load_manifest(path)

    def test_reject_baseline_as_derived_pin_before_mutation(self) -> None:
        source, patches = self.inputs()
        for pin in (self.manifest["kit_base"], "main", ""):
            result = self.invoke("apply", source, patches, "--kit-sha", pin)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("derived kit", result.stderr)
            self.apply.check_modules(source, self.manifest, "before")
            self.assertFalse((self.folder / "provenance.json").exists())

    def test_reject_wrong_preimage_before_mutation(self) -> None:
        source, patches = self.inputs()
        path = source / "tensorfold/cuda/health.py"
        path.write_bytes(path.read_bytes() + b"\n")
        result = self.invoke("apply", source, patches)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("before source checksum mismatch", result.stderr)
        self.apply.check_patch_set(patches, self.manifest, False)
        self.assertFalse((self.folder / "provenance.json").exists())

    def test_reject_tampered_baseline_patch_set(self) -> None:
        source, patches = self.inputs()
        path = next(patches.glob("*.patch"))
        original = path.read_bytes()
        for mutation in ("change", "remove", "add"):
            with self.subTest(mutation=mutation):
                path.write_bytes(original)
                if mutation == "change":
                    path.write_bytes(original + b"\n")
                elif mutation == "remove":
                    path.unlink()
                else:
                    (patches / "9999-unapproved.patch").write_bytes(original)
                result = self.invoke("apply", source, patches)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("installed patch", result.stderr)
                self.apply.check_modules(source, self.manifest, "before")
                self.assertFalse((self.folder / "provenance.json").exists())

    def test_reject_payload_mutation_and_extra_file(self) -> None:
        folder = self.folder / "payloads"
        shutil.copytree(PACKAGE / "patches", folder)
        path = folder / self.manifest["patches"][0]["file"]
        original = path.read_bytes()
        path.write_bytes(original + b"\n")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.apply.check_payloads(folder, self.manifest)
        path.write_bytes(original)
        (folder / "extra").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "unexpected files"):
            self.apply.check_payloads(folder, self.manifest)

    def test_reject_partial_or_changed_candidate_and_provenance(self) -> None:
        source, patches = self.inputs()
        result = self.invoke("apply", source, patches)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = source / "tensorfold/cuda/health.py"
        original = path.read_bytes()
        path.unlink()
        self.assertNotEqual(self.invoke("verify", source, patches).returncode, 0)
        path.write_bytes(original + b"\n")
        self.assertNotEqual(self.invoke("verify", source, patches).returncode, 0)
        path.write_bytes(original)
        provenance = self.folder / "provenance.json"
        value = json.loads(provenance.read_bytes())
        value["parent"] = "other"
        provenance.write_text(json.dumps(value))
        rejected = self.invoke("verify", source, patches)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("provenance does not match", rejected.stderr)

    def test_reject_symlink_even_inside_source_root(self) -> None:
        folder = self.folder / "root"
        folder.mkdir()
        real = folder / "real"
        real.mkdir()
        (real / "module.py").write_text("pass\n")
        (folder / "alias").symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.apply.regular_file(folder, "alias/module.py")
        with self.assertRaisesRegex(ValueError, "unsafe source path"):
            self.apply.regular_file(folder, "../module.py")

    def test_actual_baseline_checkout_and_runtime_cache(self) -> None:
        self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        cache = self.kit / "tools/__pycache__"
        cache.mkdir()
        state = cache / "client.cpython-312.pyc"
        py_compile.compile(str(self.kit / "tools/client.py"), cfile=str(state), doraise=True)
        try:
            self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            state.unlink()
            cache.rmdir()

    def test_reject_actual_checkout_tampering_including_index_flags(self) -> None:
        readme = self.kit / "README.md"
        original = readme.read_bytes()
        self.build.git(self.kit, "update-index", "--assume-unchanged", "README.md")
        try:
            readme.write_bytes(original + b"\n")
            with self.assertRaisesRegex(ValueError, "checkout source"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            readme.write_bytes(original)
            self.build.git(self.kit, "update-index", "--no-assume-unchanged", "README.md")
        extra = self.kit / "tools/unapproved.py"
        extra.write_text("pass\n")
        try:
            with self.assertRaisesRegex(ValueError, "unexpected checkout file"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            extra.unlink()

    def test_reject_skip_worktree_and_executable_mode_changes(self) -> None:
        readme = self.kit / "README.md"
        original, mode = readme.read_bytes(), readme.stat().st_mode
        self.build.git(self.kit, "update-index", "--skip-worktree", "README.md")
        try:
            readme.write_bytes(original + b"\n")
            with self.assertRaisesRegex(ValueError, "checkout source"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            readme.write_bytes(original)
            self.build.git(self.kit, "update-index", "--no-skip-worktree", "README.md")
        try:
            readme.chmod(mode | 0o111)
            with self.assertRaisesRegex(ValueError, "executable mode"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            readme.chmod(mode)

    def test_reject_git_ignored_source_and_unrelated_bytecode(self) -> None:
        exclude = self.kit / ".git/info/exclude"
        original = exclude.read_bytes()
        extra = self.kit / "tools/unapproved.py"
        try:
            exclude.write_bytes(original + b"\ntools/unapproved.py\n")
            extra.write_text("pass\n")
            with self.assertRaisesRegex(ValueError, "unexpected checkout file"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            extra.unlink(missing_ok=True)
            exclude.write_bytes(original)
        cache = self.kit / "tools/__pycache__"
        cache.mkdir()
        bytecode = cache / "unapproved.cpython-312.pyc"
        try:
            py_compile.compile(str(self.kit / "tools/client.py"), cfile=str(bytecode), doraise=True)
            with self.assertRaisesRegex(ValueError, "unexpected checkout file"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            bytecode.unlink()
            cache.rmdir()

    def test_reject_nonregular_runtime_cache(self) -> None:
        cache = self.kit / "tools/__pycache__"
        cache.mkdir()
        pipe = cache / "client.cpython-312.pyc"
        try:
            os.mkfifo(pipe, 0o600)
            with self.assertRaisesRegex(ValueError, "not a regular checkout file"):
                self.build.check_checkout(self.kit, self.manifest["kit_base"], self.apply)
        finally:
            pipe.unlink()
            cache.rmdir()

    def test_reject_real_nonselective_or_missing_kit_pin(self) -> None:
        for pin in (self.manifest["kit_base"], self.manifest["patches"][0]["commit"], "0" * 40, "main"):
            with self.subTest(pin=pin), self.assertRaises((ValueError, RuntimeError)):
                self.build.check_kit(self.kit, pin, self.manifest, self.apply)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", required=True, type=Path)
    parser.add_argument("--kit-git", required=True, type=Path,
                        help="Local Git repository containing the immutable public kit base")
    parser.add_argument("--artifact-dir", required=True, type=Path,
                        help="New empty directory under this worktree's .private-publication")
    args = parser.parse_args()
    os.umask(0o077)
    private = (ROOT / ".private-publication").resolve(strict=True)
    artifacts = args.artifact_dir.resolve()
    if not artifacts.is_relative_to(private) or artifacts.exists():
        parser.error("artifact directory must be new and inside worktree .private-publication")
    artifacts.mkdir(mode=0o700, parents=True)
    apply = load("apply")
    build = load("build")
    manifest = apply.load_manifest(PACKAGE / "manifest.json")
    baseline = args.baseline_root.resolve(strict=True)
    apply.check_modules(baseline, manifest, "before")
    kit = artifacts / "public-kit-data"
    build.run(["git", "clone", "--no-checkout", "--shared", str(args.kit_git.resolve(strict=True)), str(kit)])
    build.git(kit, "checkout", "--detach", manifest["kit_base"])
    BuildChecks.apply, BuildChecks.build, BuildChecks.manifest = apply, build, manifest
    BuildChecks.baseline, BuildChecks.kit, BuildChecks.artifacts = baseline, kit, artifacts
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BuildChecks)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print("Scope: real source application/verification and Git checkout validation only; "
          "derived fork pin, Docker identity/dependencies and ARM runtime NOT PROVEN.")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
