import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-swiftpm.sh")
REPO_ROOT = SCRIPT.parents[3]


class RunSwiftPMTests(unittest.TestCase):
    def make_fake_swift(self, directory: Path) -> Path:
        executable = directory / "swift"
        executable.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\"\n"
            "exit \"${FAKE_SWIFT_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable

    def make_runner_repo(
        self, root: Path, source_contents: str, modified_time: int
    ) -> tuple[Path, Path]:
        script = root / "Packages/ArkDeckKit/Scripts/run-swiftpm.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, script)
        source = root / "Packages/ArkDeckKit/Sources/Example/Example.swift"
        source.parent.mkdir(parents=True)
        source.write_text(source_contents, encoding="utf-8")
        (root / "Packages/ArkDeckKit/Package.swift").write_text(
            "// swift-tools-version: 6.0\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "add", "Packages/ArkDeckKit"], check=True
        )
        os.utime(source, (modified_time, modified_time))
        return script, source

    def invoke(
        self, *arguments: str, exit_code: str = "0"
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        script, _ = self.make_runner_repo(
            temporary_path / "repo", "public let value = 1\n", 1_700_000_000
        )
        cache_root = temporary_path / "cache root"
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(self.make_fake_swift(temporary_path)),
                "FAKE_SWIFT_EXIT": exit_code,
            }
        )
        result = subprocess.run(
            ["/bin/sh", str(script), *arguments],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        return result, cache_root

    def test_build_uses_stable_paths_outside_the_worktree(self) -> None:
        result, cache_root = self.invoke("build", "--target", "ArkDeckCore")
        canonical_cache_root = cache_root.resolve()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "build",
                "--package-path",
                str(canonical_cache_root / "workspace/Packages/ArkDeckKit"),
                "--scratch-path",
                str(canonical_cache_root / "build"),
                "--cache-path",
                str(canonical_cache_root / "dependencies"),
                "--target",
                "ArkDeckCore",
            ],
        )
        self.assertTrue((cache_root / "workspace").is_dir())
        self.assertFalse((cache_root / "workspace").is_symlink())
        self.assertEqual(
            (
                cache_root / "workspace/Packages/ArkDeckKit/.build"
            ).resolve(),
            (cache_root / "build").resolve(),
        )
        self.assertEqual(
            (cache_root / "workspace/Packages/ArkDeckKit/Package.swift").read_text(
                encoding="utf-8"
            ),
            "// swift-tools-version: 6.0\n",
        )
        self.assertTrue((cache_root / "build.lock").is_file())
        self.assertIn(f"ArkDeck SwiftPM cache: {canonical_cache_root}", result.stderr)

    def test_test_arguments_and_swift_exit_status_are_preserved(self) -> None:
        result, _ = self.invoke(
            "test", "--parallel", "--filter", "ArkDeckCoreTests", exit_code="23"
        )

        self.assertEqual(result.returncode, 23)
        self.assertEqual(
            result.stdout.splitlines()[-3:],
            ["--parallel", "--filter", "ArkDeckCoreTests"],
        )

    def test_runner_owned_paths_cannot_be_overridden(self) -> None:
        for option in ("--package-path", "--scratch-path=/tmp/build", "--cache-path"):
            with self.subTest(option=option):
                result, _ = self.invoke("test", option)
                self.assertEqual(result.returncode, 64)
                self.assertIn("is managed by this runner", result.stderr)

    def test_cache_root_must_be_absolute(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": "relative-cache",
                "ARKDECK_SWIFT_EXECUTABLE": str(self.make_fake_swift(temporary_path)),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(SCRIPT), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("cache root must be absolute", result.stderr)

    def test_cache_root_must_be_outside_the_worktree(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        script, _ = self.make_runner_repo(
            temporary_path / "repo", "public let value = 1\n", 1_700_000_000
        )
        cache_root = temporary_path / "repo/local-cache"
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(
                    self.make_fake_swift(temporary_path)
                ),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("cache root must be outside the worktree", result.stderr)
        self.assertFalse(cache_root.exists())

    def test_existing_non_directory_workspace_is_rejected(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        cache_root = temporary_path / "cache"
        cache_root.mkdir(parents=True)
        (cache_root / "workspace").write_text("not a mirror", encoding="utf-8")
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(self.make_fake_swift(temporary_path)),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(SCRIPT), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 73)
        self.assertIn("exists and is not a directory", result.stderr)

    def test_shared_build_invocations_are_serialized(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        cache_root = temporary_path / "cache"
        script, _ = self.make_runner_repo(
            temporary_path / "repo", "public let value = 1\n", 1_700_000_000
        )
        active_directory = temporary_path / "active"
        executable = temporary_path / "serialized-swift"
        executable.write_text(
            "#!/bin/sh\n"
            "mkdir \"$FAKE_SWIFT_ACTIVE\" || exit 91\n"
            "sleep 0.2\n"
            "rmdir \"$FAKE_SWIFT_ACTIVE\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(executable),
                "FAKE_SWIFT_ACTIVE": str(active_directory),
            }
        )
        command = ["/bin/sh", str(script), "build"]

        first = subprocess.Popen(
            command,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        second = subprocess.Popen(
            command,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        first.communicate(timeout=5)
        second.communicate(timeout=5)
        self.assertEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0)

    def test_worktree_switch_updates_only_changed_mirror_files(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        first_script, _ = self.make_runner_repo(
            temporary_path / "first", "public let value = 1\n", 1_700_000_000
        )
        second_script, second_source = self.make_runner_repo(
            temporary_path / "second", "public let value = 1\n", 1_800_000_000
        )
        cache_root = temporary_path / "cache"
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(
                    self.make_fake_swift(temporary_path)
                ),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(first_script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        mirror_source = (
            cache_root / "workspace/Packages/ArkDeckKit/Sources/Example/Example.swift"
        )
        first_mirror_stat = mirror_source.stat()

        result = subprocess.run(
            ["/bin/sh", str(second_script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        second_mirror_stat = mirror_source.stat()
        self.assertEqual(second_mirror_stat.st_ino, first_mirror_stat.st_ino)
        self.assertEqual(second_mirror_stat.st_mtime, first_mirror_stat.st_mtime)
        self.assertEqual(second_source.stat().st_mtime, 1_800_000_000)

        subprocess.run(
            ["/bin/sh", str(first_script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=True,
        )
        second_source.write_text("public let value = 2\n", encoding="utf-8")
        os.utime(second_source, (1_900_000_000, 1_900_000_000))
        result = subprocess.run(
            ["/bin/sh", str(second_script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(mirror_source.read_text(encoding="utf-8"), "public let value = 2\n")
        self.assertEqual(second_source.stat().st_mtime, 1_900_000_000)

    def test_root_level_ignored_name_keeps_nested_tracked_twin(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        root = temporary_path / "repo"
        script, _ = self.make_runner_repo(
            root, "public let value = 1\n", 1_700_000_000
        )
        # Git anchors `/cache-dir/` to the repo root, so only the root-level
        # directory is ignored; the identically named tracked directory under
        # Sources/ must survive in the mirror. An unanchored rsync exclude
        # pattern would match both and delete the tracked twin.
        (root / ".gitignore").write_text("/cache-dir/\n", encoding="utf-8")
        (root / "cache-dir").mkdir()
        (root / "cache-dir/junk.txt").write_text("local only\n", encoding="utf-8")
        nested = root / "Packages/ArkDeckKit/Sources/cache-dir/Nested.swift"
        nested.parent.mkdir(parents=True)
        nested.write_text("public let nested = 1\n", encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(root), "add", ".gitignore", "Packages"], check=True
        )
        cache_root = temporary_path / "cache"
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(self.make_fake_swift(temporary_path)),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((cache_root / "workspace/cache-dir").exists())
        self.assertTrue(
            (
                cache_root
                / "workspace/Packages/ArkDeckKit/Sources/cache-dir/Nested.swift"
            ).is_file()
        )

    def test_symlink_cache_layout_is_migrated_to_a_source_mirror(self) -> None:
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        temporary_path = Path(temporary)
        cache_root = temporary_path / "cache"
        script, _ = self.make_runner_repo(
            temporary_path / "repo", "public let value = 1\n", 1_700_000_000
        )
        cache_root.mkdir()
        (cache_root / "workspace").symlink_to(temporary_path / "repo")
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKDECK_SWIFT_EXECUTABLE": str(
                    self.make_fake_swift(temporary_path)
                ),
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(script), "build"],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((cache_root / "workspace").is_dir())
        self.assertFalse((cache_root / "workspace").is_symlink())


if __name__ == "__main__":
    unittest.main()
