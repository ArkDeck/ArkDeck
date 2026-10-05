#!/usr/bin/env python3
"""Check chat isolation, snapshot refresh, retained products and Cargo routing."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("arkdeck_cargo_runner", Path(__file__).with_name("run-cargo.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
REAL_RUN = subprocess.run


class CargoRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arkdeck-cargo-test-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.source = self.base / "checkout"
        self.source.mkdir()
        self.git("init", "-qb", "main")
        self.git("config", "user.name", "Cache fixture")
        self.git("config", "user.email", "cache@example.invalid")
        self.write(".gitignore", "rust/target/\nignored\n")
        self.write("rust/Cargo.toml", '[package]\nname = "cache-fixture"\nversion = "0.1.0"\nedition = "2021"\n')
        self.write("rust/Cargo.lock", "# fixture lock\n")
        self.write("rust/src/main.rs", 'fn main() { println!("first"); }\n')
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.root = self.base / "cache"
        self.calls = []
        self.exit_code = 0
        self.concurrent_edit = False

    def git(self, *args):
        return runner.cache.git(self.source, *args)

    def write(self, name, value):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def fake_run(self, argv, **kwargs):
        if argv[0] != "cargo" and argv[0] != "host-check":
            return REAL_RUN(argv, **kwargs)
        self.calls.append((argv, kwargs))
        target = Path(kwargs["env"]["CARGO_TARGET_DIR"])
        target.mkdir(parents=True, exist_ok=True)
        (target / "product").write_bytes(b"retained compiler product")
        if argv[:2] == ["cargo", "fmt"] and "--check" not in argv:
            (kwargs["cwd"] / "src/main.rs").write_text("fn main() {}\n")
            if self.concurrent_edit:
                self.write("rust/src/main.rs", "// user edit during formatting\n")
        if argv[:2] == ["cargo", "generate-lockfile"]:
            (kwargs["cwd"] / "Cargo.lock").write_text("# regenerated lock\n")
        return subprocess.CompletedProcess(argv, self.exit_code)

    def invoke(self, *args, environment=None):
        env = {"ARKDECK_CARGO_CACHE_ROOT": str(self.root), "CODEX_THREAD_ID": "chat-1",
               "CARGO_HOME": str(self.base / "cargo-home")}
        for name, value in (environment or {}).items():
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
        with patch.dict(os.environ, env, clear=True), patch.object(runner, "ROOT", self.source), \
                patch.object(runner.subprocess, "run", side_effect=self.fake_run):
            return runner.main(list(args))

    def test_same_chat_reuses_products_and_file_identity_across_tasks_and_snapshots(self):
        self.invoke("check", "-p", "cache-fixture")
        mirror_file = self.root / "workspace/rust/src/main.rs"
        target = self.root / "workspace/rust/target"
        mirror_identity = (mirror_file.stat().st_ino, mirror_file.stat().st_mtime_ns)
        target_identity = target.stat().st_ino
        (target / "warm-dependency").write_bytes(b"keep this cache")
        other = self.base / "next-task-snapshot"
        REAL_RUN(["git", "clone", "-q", str(self.source), str(other)], check=True)
        self.invoke("test", environment={"ARKDECK_CARGO_SOURCE_ROOT": str(other), "TASK_ID": "new-task"})
        self.assertEqual((mirror_file.stat().st_ino, mirror_file.stat().st_mtime_ns), mirror_identity)
        changed = other / "rust/src/main.rs"
        changed.write_text('fn main() { println!("changed"); }\n')
        (other / "rust/new.rs").write_text("// untracked source\n")
        self.invoke("clippy", environment={"ARKDECK_CARGO_SOURCE_ROOT": str(other)})
        self.assertEqual(mirror_file.read_text(), changed.read_text())
        self.assertEqual(target.stat().st_ino, target_identity)
        self.assertEqual((target / "warm-dependency").read_bytes(), b"keep this cache")
        self.assertTrue((self.root / "workspace/rust/new.rs").exists())
        changed.unlink()
        self.invoke("check", environment={"ARKDECK_CARGO_SOURCE_ROOT": str(other)})
        self.assertFalse(mirror_file.exists())
        for _, kwargs in self.calls:
            self.assertEqual(kwargs["cwd"], self.root / "workspace/rust")
            self.assertEqual(kwargs["env"]["CARGO_TARGET_DIR"], str(target))
            self.assertEqual(kwargs["env"]["CARGO_BUILD_JOBS"], "2")
        self.assertFalse((other / "rust/target").exists())

    def test_three_chats_keep_separate_targets_and_cannot_claim_each_others_cache(self):
        roots = []
        for owner in ("chat-1", "chat-2", "chat-3"):
            self.root = self.base / owner
            self.invoke("build", environment={"CODEX_THREAD_ID": owner})
            roots.append(self.calls[-1][1]["env"]["CARGO_TARGET_DIR"])
            self.invoke("test", environment={"CODEX_THREAD_ID": owner})
            self.assertEqual(self.calls[-1][1]["env"]["CARGO_TARGET_DIR"], roots[-1])
        self.assertEqual(len(set(roots)), 3)
        with self.assertRaisesRegex(ValueError, "another chat"):
            self.invoke("build", environment={"CODEX_THREAD_ID": "chat-1"})

    def test_owner_selection_never_uses_task_revision_or_worktree(self):
        self.assertEqual(runner.owner_id({}), "local")
        self.assertEqual(runner.owner_id({"CODEX_THREAD_ID": "chat-1", "TASK_ID": "other"}), "chat-1")
        self.assertEqual(runner.owner_id({"ARKDECK_CARGO_OWNER": "fixed", "CODEX_THREAD_ID": "chat-1"}), "fixed")
        for value in ("../other", "", "a/b"):
            with self.assertRaises(ValueError):
                runner.owner_id({"ARKDECK_CARGO_OWNER": value})
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=self.base):
            self.assertEqual(runner.default_cache("chat-1").name, "chat-1")
            self.assertNotEqual(runner.default_cache("chat-1"), runner.default_cache("chat-2"))

    def test_default_root_is_reused_for_the_chat(self):
        with patch.object(runner, "default_cache", return_value=self.root):
            self.invoke("build", environment={"ARKDECK_CARGO_CACHE_ROOT": None})
            self.invoke("test", environment={"ARKDECK_CARGO_CACHE_ROOT": None})
        self.assertEqual(self.calls[0][1]["env"]["CARGO_TARGET_DIR"], self.calls[1][1]["env"]["CARGO_TARGET_DIR"])

    def test_source_and_child_git_environment_cannot_select_another_checkout(self):
        self.invoke("check", environment={"GIT_DIR": "/missing/git", "GIT_INDEX_FILE": "/missing/index"})
        self.assertFalse(any(name.startswith("GIT_") for name in self.calls[-1][1]["env"]))
        with self.assertRaisesRegex(ValueError, "independent Git top-level"):
            self.invoke("check", environment={"ARKDECK_CARGO_SOURCE_ROOT": str(self.source / "rust")})

    def test_same_chat_lock_prevents_source_sync_until_previous_command_finishes(self):
        self.invoke("check")
        with runner.runner_lock(self.root):
            with self.assertRaisesRegex(ValueError, "already in use"):
                self.invoke("test")
        self.assertEqual(len(self.calls), 1)
        self.invoke("test")
        self.assertEqual(len(self.calls), 2)

    def test_managed_paths_and_native_target_cannot_be_overridden(self):
        for flag in ("--manifest-path", "--target-dir", "--lockfile-path", "--config", "--target"):
            with self.subTest(flag=flag), self.assertRaises(ValueError):
                self.invoke("build", flag + "=elsewhere")
        with self.assertRaises(ValueError):
            self.invoke("fmt", "--", "--manifest-path=elsewhere")
        with self.assertRaisesRegex(ValueError, "CARGO_BUILD_TARGET"):
            self.invoke("build", environment={"CARGO_BUILD_TARGET": "other-host"})
        self.assertFalse(self.calls)
        self.invoke("run", "--", "--target", "app-argument")
        self.assertEqual(self.calls[-1][0], ["cargo", "run", "--locked", "--", "--target", "app-argument"])

    def test_cache_root_must_be_disjoint_from_source(self):
        for root in ("relative", str(self.source / "cache"), str(self.base)):
            with self.subTest(root=root), self.assertRaises(ValueError):
                self.invoke("check", environment={"ARKDECK_CARGO_CACHE_ROOT": root})

    @unittest.skipIf(sys.platform == "win32", "creating symlinks requires a Windows privilege")
    def test_preserved_target_must_be_an_owned_directory(self):
        self.invoke("check")
        target = self.root / "workspace/rust/target"
        shutil.rmtree(target)
        target.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "owned directory"):
            self.invoke("check")

    def test_cargo_config_cannot_select_a_second_host_target(self):
        self.write(".cargo/config.toml", '[build]\ntarget = "another-host"\n')
        with self.assertRaisesRegex(ValueError, "build.target"):
            self.invoke("build")
        self.assertFalse(self.calls)

    def test_formatter_and_lockfile_changes_return_to_source_only_on_success(self):
        self.invoke("fmt", "--all")
        self.assertEqual((self.source / "rust/src/main.rs").read_text(), "fn main() {}\n")
        self.assertNotIn("--locked", self.calls[-1][0])
        self.invoke("generate-lockfile")
        self.assertEqual((self.source / "rust/Cargo.lock").read_text(), "# regenerated lock\n")
        self.write("rust/src/main.rs", "// keep source on failed fmt\n")
        self.exit_code = 23
        self.assertEqual(self.invoke("fmt", "--all"), 23)
        self.assertEqual((self.source / "rust/src/main.rs").read_text(), "// keep source on failed fmt\n")

    def test_formatter_does_not_overwrite_concurrent_checkout_edits(self):
        self.concurrent_edit = True
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.invoke("fmt", "--all")
        self.assertEqual((self.source / "rust/src/main.rs").read_text(), "// user edit during formatting\n")

    def test_exec_checks_share_the_mirror_target_and_propagate_failure(self):
        self.exit_code = 7
        self.assertEqual(self.invoke("exec", "--", "host-check", "rust/scripts/check-contracts.py"), 7)
        argv, kwargs = self.calls[-1]
        self.assertEqual(argv, ["host-check", "rust/scripts/check-contracts.py"])
        self.assertEqual(kwargs["cwd"], self.root / "workspace")
        self.assertEqual(kwargs["env"]["ARKDECK_RUST_STABLE_VIEWS"], "1")

    @unittest.skipUnless(os.environ.get("ARKDECK_TEST_REAL_CARGO") == "1", "opt-in native Cargo cache check")
    def test_real_cargo_reuses_unchanged_snapshot_and_rebuilds_changed_snapshot(self):
        (self.source / "rust/Cargo.lock").unlink()
        environment = dict(os.environ, ARKDECK_CARGO_SOURCE_ROOT=str(self.source),
                           ARKDECK_CARGO_CACHE_ROOT=str(self.root), ARKDECK_CARGO_OWNER="native-fixture")
        script = str(Path(__file__).with_name("run-cargo.py"))

        def invoke(*args):
            result = REAL_RUN([sys.executable, script, *args], env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

        invoke("generate-lockfile", "--offline")
        first = invoke("run", "--offline", "--verbose")
        self.assertTrue(first.stdout.rstrip().endswith("first"))
        target = self.root / "workspace/rust/target"
        target_inode = target.stat().st_ino
        second = self.base / "second-snapshot"
        REAL_RUN(["git", "clone", "-q", str(self.source), str(second)], check=True)
        shutil.copyfile(self.source / "rust/Cargo.lock", second / "rust/Cargo.lock")
        environment["ARKDECK_CARGO_SOURCE_ROOT"] = str(second)
        warm = invoke("run", "--offline", "--verbose")
        self.assertIn("Fresh cache-fixture", warm.stderr)
        self.assertTrue(warm.stdout.rstrip().endswith("first"))
        (second / "rust/src/main.rs").write_text('fn main() { println!("second"); }\n')
        changed = invoke("run", "--offline", "--verbose")
        self.assertTrue(changed.stdout.rstrip().endswith("second"))
        self.assertEqual(target.stat().st_ino, target_inode)
        self.assertFalse((self.source / "rust/target").exists())
        self.assertFalse((second / "rust/target").exists())


if __name__ == "__main__":
    unittest.main()
