#!/usr/bin/env python3
"""Pinned-source admission failures; fixtures never act as native tools."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_native_trace", Path(__file__).with_name("prepare-native-trace.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeTraceSourceTests(unittest.TestCase):
    def test_materialization_preserves_source_and_omits_ignored_state(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        repo, workspace = root / "repo", root / "workspace"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / ".gitignore").write_text("ignored/\n")
        (repo / "source.swift").write_text("let value = 1\n")
        (repo / "ignored").mkdir()
        (repo / "ignored/cache").write_text("private cache")
        subprocess.run(["git", "add", ".gitignore", "source.swift"], cwd=repo, check=True)
        (repo / "source.swift").write_text("let value = 2\n")
        (repo / "new.swift").write_text("let newValue = 3\n")
        module.materialize(repo, workspace)
        self.assertEqual((workspace / "source.swift").read_bytes(), (repo / "source.swift").read_bytes())
        self.assertTrue((workspace / "new.swift").is_file())
        self.assertFalse((workspace / "ignored").exists())
        self.assertFalse((workspace / ".git").exists())
        self.assertTrue((repo / "ignored/cache").is_file())
        with self.assertRaisesRegex(ValueError, "external"):
            module.materialize(repo, repo / "build")

    def checkout(self):
        base = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        packages = base / "SourcePackages"
        source = packages / "checkouts/ArkTrace"
        (source / "sources/ArkTraceAppSupport").mkdir(parents=True)
        tracked = source / "probe.txt"
        tracked.write_text("owned fixture")
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "add", "probe.txt"], cwd=source, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "fixture"], cwd=source, check=True)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        return packages, source, tracked, revision

    def test_source_revision_and_tracked_bytes_cannot_drift(self):
        packages, source, tracked, revision = self.checkout()
        self.assertEqual(module.find_source(packages, revision), source)
        with self.assertRaisesRegex(ValueError, "revision mismatch"):
            module.find_source(packages, "0" * 40)
        tracked.write_text("changed")
        with self.assertRaisesRegex(ValueError, "source drift"):
            module.find_source(packages, revision)

    def test_duplicate_or_linked_source_checkout_is_rejected(self):
        packages, source, _, revision = self.checkout()
        duplicate = source.parent / "Other"
        (duplicate / "sources/ArkTraceAppSupport").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "one resolved"):
            module.find_source(packages, revision)
        (duplicate / "sources/ArkTraceAppSupport").rmdir()
        link = source.parent / "Linked"
        source.rename(duplicate / "Saved")
        link.symlink_to(duplicate / "Saved", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "physical"):
            module.find_source(packages, revision)

    def test_resolved_pin_requires_one_exact_revision(self):
        packages, _, _, revision = self.checkout()
        workspace = packages.parent / "workspace"
        path = workspace / "apple/Packages/ArkDeckKit/Package.resolved"
        path.parent.mkdir(parents=True)
        row = {"identity": "arktrace", "state": {"revision": revision}}
        path.write_text(json.dumps({"pins": [row]}))
        self.assertEqual(module.source_revision(workspace), revision)
        for pins in ([], [row, row], [{"identity": "arktrace", "state": {"revision": "main"}}]):
            with self.subTest(pins=pins):
                path.write_text(json.dumps({"pins": pins}))
                with self.assertRaises(ValueError):
                    module.source_revision(workspace)


if __name__ == "__main__":
    unittest.main()
