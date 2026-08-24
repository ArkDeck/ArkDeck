#!/usr/bin/env python3
"""Contract tests for the stable-path Xcode build runner."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-xcodebuild.sh")


class RunXcodebuildTests(unittest.TestCase):
    def make_fake_xcodebuild(self, directory: Path) -> Path:
        executable = directory / "xcodebuild"
        executable.write_text(
            "#!/bin/sh\n"
            "printf 'CLANG_MODULE_CACHE_PATH=%s\\n' \"$CLANG_MODULE_CACHE_PATH\"\n"
            "printf 'SWIFTPM_MODULECACHE_OVERRIDE=%s\\n' \"$SWIFTPM_MODULECACHE_OVERRIDE\"\n"
            "printf 'ARG:%s\\n' \"$@\"\n"
            "exit \"${FAKE_XCODEBUILD_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable

    def make_runner_repo(
        self, root: Path, source_contents: str, modified_time: int
    ) -> tuple[Path, Path]:
        script = root / "scripts/ci/run-xcodebuild.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, script)
        project = root / "ArkDeck.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True)
        project.write_text("// project\n", encoding="utf-8")
        source = root / "ArkDeckApp/App.swift"
        source.parent.mkdir(parents=True)
        source.write_text(source_contents, encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "add", "ArkDeck.xcodeproj", "ArkDeckApp", "scripts"],
            check=True,
        )
        os.utime(source, (modified_time, modified_time))
        return script, source

    def invoke(
        self,
        script: Path,
        cache_root: Path,
        xcodebuild: Path,
        *,
        exit_code: str = "0",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_XCODE_CACHE_ROOT": str(cache_root),
                "ARKDECK_XCODEBUILD_EXECUTABLE": str(xcodebuild),
                "FAKE_XCODEBUILD_EXIT": exit_code,
            }
        )
        return subprocess.run(
            ["/bin/sh", str(script)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def test_build_uses_stable_owned_paths_and_module_cache(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache root"
        result = self.invoke(
            script, cache_root, self.make_fake_xcodebuild(temporary)
        )
        canonical_cache = cache_root.resolve()

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn(
            f"CLANG_MODULE_CACHE_PATH={canonical_cache / 'ModuleCache'}", lines
        )
        self.assertIn(
            f"SWIFTPM_MODULECACHE_OVERRIDE={canonical_cache / 'ModuleCache'}", lines
        )
        arguments = [
            line.removeprefix("ARG:")
            for line in lines
            if line.startswith("ARG:")
        ]
        self.assertEqual(
            arguments[0:2],
            ["-project", str(canonical_cache / "workspace/ArkDeck.xcodeproj")],
        )
        self.assertIn(str(canonical_cache / "DerivedData"), arguments)
        self.assertIn(str(canonical_cache / "SourcePackages"), arguments)
        self.assertIn(str(canonical_cache / "PackageCache"), arguments)
        self.assertIn("-showBuildTimingSummary", arguments)
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", arguments)
        self.assertIn("SWIFT_COMPILATION_MODE=singlefile", arguments)
        self.assertEqual(arguments[-1], "build-for-testing")
        self.assertIn(f"ArkDeck Xcode cache: {canonical_cache}", result.stderr)
        self.assertTrue((cache_root / "build.lock").is_file())

    def test_identical_content_from_another_worktree_preserves_mirror_identity(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        first_script, _ = self.make_runner_repo(
            temporary / "first", "let value = 1\n", 1_700_000_000
        )
        second_script, _ = self.make_runner_repo(
            temporary / "second", "let value = 1\n", 1_800_000_000
        )
        cache_root = temporary / "cache"
        xcodebuild = self.make_fake_xcodebuild(temporary)

        first = self.invoke(first_script, cache_root, xcodebuild)
        mirrored = cache_root / "workspace/ArkDeckApp/App.swift"
        first_stat = mirrored.stat()
        second = self.invoke(second_script, cache_root, xcodebuild)
        second_stat = mirrored.stat()

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first_stat.st_ino, second_stat.st_ino)
        self.assertEqual(first_stat.st_mtime_ns, second_stat.st_mtime_ns)

    def test_real_content_change_updates_the_mirror(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        first_script, _ = self.make_runner_repo(
            temporary / "first", "let value = 1\n", 1_700_000_000
        )
        second_script, _ = self.make_runner_repo(
            temporary / "second", "let value = 2\n", 1_800_000_000
        )
        cache_root = temporary / "cache"
        xcodebuild = self.make_fake_xcodebuild(temporary)

        self.assertEqual(
            self.invoke(first_script, cache_root, xcodebuild).returncode, 0
        )
        self.assertEqual(
            self.invoke(second_script, cache_root, xcodebuild).returncode, 0
        )

        self.assertEqual(
            (cache_root / "workspace/ArkDeckApp/App.swift").read_text(encoding="utf-8"),
            "let value = 2\n",
        )

    def test_ignored_files_are_not_mirrored(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        (temporary / "repo/.gitignore").write_text("local-build/\n", encoding="utf-8")
        ignored = temporary / "repo/local-build/result"
        ignored.parent.mkdir()
        ignored.write_text("private\n", encoding="utf-8")
        cache_root = temporary / "cache"

        result = self.invoke(script, cache_root, self.make_fake_xcodebuild(temporary))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((cache_root / "workspace/local-build").exists())

    def test_cache_root_must_be_absolute_and_outside_worktree(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        xcodebuild = self.make_fake_xcodebuild(temporary)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_XCODE_CACHE_ROOT": "relative-cache",
                "ARKDECK_XCODEBUILD_EXECUTABLE": str(xcodebuild),
            }
        )
        relative = subprocess.run(
            ["/bin/sh", str(script)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        inside = self.invoke(script, temporary / "repo/cache", xcodebuild)

        self.assertEqual(relative.returncode, 64)
        self.assertIn("cache root must be absolute", relative.stderr)
        self.assertEqual(inside.returncode, 64)
        self.assertIn("cache root must be outside the worktree", inside.stderr)

    def test_shared_build_invocations_are_serialized(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache"
        active_directory = temporary / "active"
        executable = temporary / "serialized-xcodebuild"
        executable.write_text(
            "#!/bin/sh\n"
            "mkdir \"$FAKE_XCODEBUILD_ACTIVE\" || exit 91\n"
            "sleep 0.2\n"
            "rmdir \"$FAKE_XCODEBUILD_ACTIVE\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKDECK_XCODE_CACHE_ROOT": str(cache_root),
                "ARKDECK_XCODEBUILD_EXECUTABLE": str(executable),
                "FAKE_XCODEBUILD_ACTIVE": str(active_directory),
            }
        )
        command = ["/bin/sh", str(script)]

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

    def test_xcodebuild_exit_status_is_preserved(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        result = self.invoke(
            script,
            temporary / "cache",
            self.make_fake_xcodebuild(temporary),
            exit_code="23",
        )
        self.assertEqual(result.returncode, 23)


if __name__ == "__main__":
    unittest.main()
