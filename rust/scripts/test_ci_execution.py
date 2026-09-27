#!/usr/bin/env python3
"""Exercise source/cache isolation and complete native Cargo test scheduling."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cache = load("ci-workspace")
tests = load("run-workspace-tests")


class WorkspaceCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arkdeck-ci-cache-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.source = self.directory / "checkout"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("rust/src/lib.rs", "// first\n")
        self.write("rust/Cargo.toml", '[workspace]\n')
        self.write("rust/Cargo.lock", "# lock\n")
        self.write("rust/rust-toolchain.toml", '[toolchain]\nchannel = "stable"\n')
        self.write(".gitignore", "rust/target/\nignored\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.root = cache.cache_root(str(self.directory / "cache"), self.source)

    def git(self, *args):
        return cache.git(self.source, *args)

    def write(self, path, text):
        file = self.source / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def test_restore_preserves_identical_mtimes_and_updates_changed_deleted_and_untracked_sources(self):
        mirror = cache.prepare(self.source, self.root)
        file = mirror / "rust/src/lib.rs"
        os.utime(file, ns=(1_000_000_000, 1_000_000_000))
        (mirror / "stray").write_text("cached source must not survive")
        (mirror / "rust/target").mkdir()
        (mirror / "rust/target/product").write_text("retained build")
        self.write("ignored", "must not be copied")
        self.write("new-input", "current untracked source")
        cache.prepare(self.source, self.root)
        self.assertEqual(file.stat().st_mtime_ns, 1_000_000_000)
        self.assertFalse((mirror / "stray").exists())
        self.assertFalse((mirror / "ignored").exists())
        self.assertEqual((mirror / "new-input").read_text(), "current untracked source")
        self.assertEqual((mirror / "rust/target/product").read_text(), "retained build")
        self.write("rust/src/lib.rs", "// changed\n")
        (self.source / "new-input").unlink()
        cache.prepare(self.source, self.root)
        self.assertEqual(file.read_text(), "// changed\n")
        self.assertGreater(file.stat().st_mtime_ns, 1_000_000_000)
        self.assertFalse((mirror / "new-input").exists())

    def test_restored_git_authority_is_replaced_without_inheriting_credentials_or_environment(self):
        mirror = cache.prepare(self.source, self.root)
        cache.git(mirror, "config", "http.extraheader", "fixture-secret")
        old = self.git("rev-parse", "HEAD")
        self.write("next", "next revision")
        self.git("add", ".")
        self.git("commit", "-qm", "next")
        current = self.git("rev-parse", "HEAD")
        cache.prepare(self.source, self.root)
        self.assertEqual(cache.git(mirror, "rev-parse", "HEAD"), current)
        self.assertEqual(cache.git(mirror, "rev-parse", "origin/main"), old)
        self.assertNotIn("fixture-secret", (mirror / ".git/config").read_text())
        self.assertEqual(cache.git(mirror, "show", "origin/main:rust/src/lib.rs"), "// first")
        self.assertEqual(cache.git(mirror, "diff", "--name-only"), "")
        child = mirror / "fixture-git"
        child.mkdir()
        cache.git(child, "init", "-q")
        self.assertTrue((child / ".git").is_dir())
        self.assertEqual(self.git("rev-parse", "HEAD"), current)

    def test_rejects_shared_or_unowned_roots_and_simultaneous_use(self):
        for root in (self.source, self.source / "target", self.directory):
            with self.subTest(root=root), self.assertRaises(ValueError):
                cache.cache_root(str(root), self.source)
        unowned = self.directory / "unowned"
        unowned.mkdir()
        (unowned / "file").write_text("keep")
        with self.assertRaises(ValueError):
            cache.cache_root(str(unowned), self.source)
        with cache.locked(self.root):
            with self.assertRaises(ValueError):
                with cache.locked(self.root):
                    self.fail("two writers")
        self.assertFalse((self.root / "in-use").exists())

    @unittest.skipIf(sys.platform == "win32", "creating symlinks requires a Windows privilege")
    def test_restored_parent_symlink_never_writes_outside_owned_workspace(self):
        mirror = cache.prepare(self.source, self.root)
        outside = self.directory / "outside"
        outside.mkdir()
        sentinel = outside / "lib.rs"
        sentinel.write_text("untouched")
        shutil.rmtree(mirror / "rust/src")
        (mirror / "rust/src").symlink_to(outside, target_is_directory=True)
        cache.prepare(self.source, self.root)
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertFalse((mirror / "rust/src").is_symlink())

    def test_view_sync_retains_only_its_own_target_and_identical_source_mtimes(self):
        stage = self.directory / "stage"
        (stage / "rust/src").mkdir(parents=True)
        (stage / "rust/src/lib.rs").write_text("source")
        for name in ("published", "candidate"):
            destination = self.root / name
            cache.sync_tree(stage, destination, preserve=(("rust", "target"),))
            (destination / "rust/target").mkdir()
            (destination / "rust/target/product").write_text(name)
            file = destination / "rust/src/lib.rs"
            os.utime(file, ns=(1_000_000_000, 1_000_000_000))
            (destination / "stale-input").write_text("obsolete")
            cache.sync_tree(stage, destination, preserve=(("rust", "target"),))
            self.assertEqual(file.stat().st_mtime_ns, 1_000_000_000)
            self.assertEqual((destination / "rust/target/product").read_text(), name)
            self.assertFalse((destination / "stale-input").exists())

    def test_cache_key_separates_compiler_image_flags_manifests_and_stable_path(self):
        with patch.object(cache.subprocess, "check_output", return_value="compiler-v1"), patch.dict(os.environ, {"ImageVersion": "image-v1"}):
            original = cache.key(self.source, str(self.root))
            self.write("rust/src/lib.rs", "// source-only edit\n")
            self.assertEqual(cache.key(self.source, str(self.root)), original)
            self.assertNotEqual(cache.key(self.source, str(self.root / "other")), original)
            for variable, value in (("ImageVersion", "image-v2"), ("RUSTFLAGS", "-C debuginfo=0")):
                with patch.dict(os.environ, {variable: value}):
                    self.assertNotEqual(cache.key(self.source, str(self.root)), original)
            with patch.object(cache.subprocess, "check_output", return_value="compiler-v2"):
                self.assertNotEqual(cache.key(self.source, str(self.root)), original)
            self.write("rust/Cargo.lock", "# different dependency\n")
            self.assertNotEqual(cache.key(self.source, str(self.root)), original)


class CargoSchedulingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arkdeck-ci-cargo-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "Cargo.toml"
        self.manifest.write_text('[package]\nname="arkdeck-agentd"\nversion="0.1.0"\nedition="2021"\n')
        self.metadata = {"workspace_members": ["agent"], "packages": [
            {"id": "agent", "name": "arkdeck-agentd", "manifest_path": str(self.manifest), "targets": []}]}

    def artifact(self, name, kind="test", package="agent", harness=True):
        return {"reason": "compiler-artifact", "package_id": package, "target": {"name": name, "kind": [kind]},
                "profile": {"test": harness}, "executable": "/never-executed-directly"}

    def messages(self, *artifacts):
        return [*artifacts, {"reason": "build-finished", "success": True}]

    def test_new_and_sensitive_targets_are_exhaustive_and_conservative(self):
        planned = dict(tests.queues(self.messages(
            self.artifact("workspace_tests_process"), self.artifact("spawning"),
            self.artifact("capture_diagnostics"), self.artifact("brand_new"),
            self.artifact("arkforged_owner_stop", harness=False), self.artifact("agent", "lib"),
            self.artifact("agent", "bin"), self.artifact("checked_example", "example"),
        ), self.metadata))
        self.assertEqual(planned["isolated"], tests.BASE + ["--test", "workspace_tests_process"])
        conservative = planned["shared-resources"]
        for target in ("spawning", "capture_diagnostics", "brand_new", "arkforged_owner_stop", "checked_example"):
            self.assertIn(target, conservative)
        self.assertIn("--lib", conservative)
        self.assertIn("--bin", conservative)
        self.assertNotIn("workspace_tests_process", conservative)
        self.assertEqual(conservative[:len(tests.BASE)], tests.BASE)

    def test_duplicate_names_do_not_inherit_another_packages_overlap_permission(self):
        self.metadata["workspace_members"].append("other")
        self.metadata["packages"].append(dict(self.metadata["packages"][0], id="other", name="other"))
        planned = dict(tests.queues(self.messages(self.artifact("workspace_tests_process"),
            self.artifact("workspace_tests_process", package="other")), self.metadata))
        self.assertNotIn("isolated", planned)
        self.assertIn("workspace_tests_process", planned["shared-resources"])

    def test_ambiguous_shapes_fall_back_to_all_tests_and_incomplete_inventory_fails(self):
        with self.assertRaisesRegex(ValueError, "complete test build"):
            tests.queues([self.artifact("test")], self.metadata)
        self.manifest.write_text(self.manifest.read_text() + '\n[[example]]\nname="custom"\nharness=false\n')
        self.assertEqual(tests.queues(self.messages(self.artifact("test")), self.metadata), [("workspace", tests.BASE)])
        self.assertEqual(tests.queues(self.messages(), self.metadata), [("workspace", tests.BASE)])

    @unittest.skipUnless(shutil.which("cargo"), "native fixture needs Cargo")
    def test_native_cargo_keeps_harnesses_docs_environment_overlap_and_failures(self):
        # A tiny dependency-free workspace, not the product's full CI gate.
        # The two tests handshake: serialized Cargo executions cannot pass.
        self.manifest.write_text(self.manifest.read_text() + '\n[[test]]\nname="custom"\nharness=false\n')
        (self.root / "src").mkdir()
        (self.root / "tests").mkdir()
        (self.root / "receipts").mkdir()
        helper = '''fn mark(name: &str) {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    assert_eq!(std::env::current_dir().unwrap(), root);
    std::fs::write(root.join("receipts").join(name), "ran").unwrap();
}
fn overlap(mine: &str, peer: &str) {
    mark(mine);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("receipts").join(peer).exists() {
        assert!(std::time::Instant::now() < deadline, "Cargo queues did not overlap");
        std::thread::yield_now();
    }
}
'''
        (self.root / "src/lib.rs").write_text('''/// ```
/// std::fs::write("receipts/doc", "ran").unwrap();
/// assert!(std::env::var("ARKDECK_CI_FIXTURE_FAIL_DOC").is_err());
/// ```
pub fn documented() {}
#[test] fn unit() { std::fs::write("receipts/unit", "ran").unwrap(); }
''')
        (self.root / "tests/shared.rs").write_text(helper + '#[test] fn shared() { overlap("shared", "isolated"); }\n')
        (self.root / "tests/workspace_tests_process.rs").write_text(helper + '#[test] fn isolated() { overlap("isolated", "shared"); }\n')
        (self.root / "tests/custom.rs").write_text('fn main() { std::fs::write("receipts/custom", "ran").unwrap(); }\n')
        environment = {"CARGO_TARGET_DIR": str(self.root / "target"), "CARGO_BUILD_JOBS": "2"}
        with patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
            subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=self.root, check=True, capture_output=True)
            directory = self.root / "reports"
            code = tests.execute(self.root, workers=2, directory=directory)
            if code:
                self.fail("native fixture failed: " + "\n".join(p.read_text() for p in directory.glob("*.log")))
            self.assertEqual({p.name for p in (self.root / "receipts").iterdir()}, {"unit", "doc", "shared", "isolated", "custom"})
            # A failing queue must not suppress the other queue or doctests.
            (self.root / "tests/shared.rs").write_text(helper + '#[test] fn shared() { mark("shared"); panic!("fixture failure"); }\n')
            with patch.dict(os.environ, {"ARKDECK_CI_FIXTURE_FAIL_DOC": "1"}):
                self.assertNotEqual(tests.execute(self.root, workers=2, directory=directory), 0)
            report = json.loads((directory / "timings.json").read_text())
            stages = {stage["name"]: stage for stage in report["stages"]}
            self.assertTrue(report["completed"])
            self.assertNotEqual(stages["shared-resources"]["exitCode"], 0)
            self.assertNotEqual(stages["doctests"]["exitCode"], 0)
            self.assertEqual(stages["isolated"]["exitCode"], 0)


if __name__ == "__main__":
    unittest.main()
