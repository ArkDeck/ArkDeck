#!/usr/bin/env python3
"""Contract tests for the stable-path Xcode build runner."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
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
        *arguments: str,
        exit_code: str = "0",
        jobs: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.pop("ARKDECK_XCODE_JOBS", None)
        if jobs is not None:
            environment["ARKDECK_XCODE_JOBS"] = jobs
        environment.update(
            {
                "ARKDECK_XCODE_CACHE_ROOT": str(cache_root),
                "ARKDECK_XCODEBUILD_EXECUTABLE": str(xcodebuild),
                "FAKE_XCODEBUILD_EXIT": exit_code,
            }
        )
        return subprocess.run(
            ["/bin/sh", str(script), *arguments],
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
        self.assertIn("ARCHS=arm64", arguments)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", arguments)
        self.assertIn("COMPILATION_CACHE_ENABLE_CACHING=YES", arguments)
        self.assertIn("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES", arguments)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
        self.assertNotIn("-jobs", arguments)
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", arguments)
        self.assertIn("SWIFT_COMPILATION_MODE=singlefile", arguments)
        self.assertEqual(arguments[-1], "build-for-testing")
        self.assertIn(f"ArkDeck Xcode cache: {canonical_cache}", result.stderr)
        self.assertTrue((cache_root / "build.lock").is_file())

    def test_build_job_limit_survives_lock_reentry_for_both_configurations(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        executable = self.make_fake_xcodebuild(temporary)
        for mode in ((), ("--release",)):
            for jobs in ("2", "4", "8"):
                with self.subTest(mode=mode, jobs=jobs):
                    result = self.invoke(script, temporary / "cache", executable,
                                         *mode, jobs=jobs)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    arguments = [line.removeprefix("ARG:") for line in
                                 result.stdout.splitlines() if line.startswith("ARG:")]
                    self.assertEqual(arguments.count("-jobs"), 1)
                    self.assertEqual(arguments[arguments.index("-jobs") + 1], jobs)

    def test_invalid_build_job_limit_fails_before_touching_cache(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        executable = self.make_fake_xcodebuild(temporary)
        for jobs in ("0", "-1", "1.5", "4 8", "auto", "65", "01", "99999999999999999"):
            with self.subTest(jobs=jobs):
                cache = temporary / "cache"
                result = self.invoke(script, cache, executable, "--release", jobs=jobs)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("ARKDECK_XCODE_JOBS", result.stderr)
                self.assertFalse(cache.exists())

    def test_release_uses_arm64_for_packages_without_overriding_signing(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache"
        executable = self.make_fake_xcodebuild(temporary)
        debug = self.invoke(script, cache_root, executable)
        release = self.invoke(script, cache_root, executable, "--release")

        self.assertEqual(debug.returncode, 0, debug.stderr)
        self.assertEqual(release.returncode, 0, release.stderr)
        arguments = [
            line.removeprefix("ARG:")
            for line in release.stdout.splitlines()
            if line.startswith("ARG:")
        ]
        self.assertEqual(arguments[arguments.index("-configuration") + 1], "Release")
        self.assertIn("ARCHS=arm64", arguments)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", arguments)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", arguments)
        self.assertIn("COMPILATION_CACHE_ENABLE_CACHING=YES", arguments)
        self.assertIn("-showBuildTimingSummary", arguments)
        self.assertEqual(arguments[-1], "build")
        for prefix in ("CODE_SIGN", "DEVELOPMENT_TEAM=", "SWIFT_OPTIMIZATION_LEVEL=",
                       "SWIFT_COMPILATION_MODE="):
            self.assertFalse(any(value.startswith(prefix) for value in arguments))
        for option in ("-project", "-derivedDataPath", "-clonedSourcePackagesDirPath",
                       "-packageCachePath"):
            value = arguments[arguments.index(option) + 1]
            self.assertIn(f"ARG:{value}", debug.stdout.splitlines())

    def test_runner_rejects_extra_arguments_including_architecture_overrides(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_runner_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        for arguments in (("ARCHS=x86_64",), ("--release", "ARCHS=x86_64"),
                          ("--release", "--release")):
            with self.subTest(arguments=arguments):
                result = self.invoke(
                    script, temporary / "cache", self.make_fake_xcodebuild(temporary),
                    *arguments,
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("unexpected argument", result.stderr)

    def test_project_and_ui_runner_remain_arm64_only(self) -> None:
        repo_root = SCRIPT.parents[2]
        project = (repo_root / "ArkDeck.xcodeproj/project.pbxproj").read_text()
        for identifier in ("A10000000000000000000070", "A10000000000000000000071"):
            settings = re.search(
                rf"{identifier} /\* (?:Debug|Release) \*/ = \{{.*?buildSettings = \{{(.*?)\n\s*\}};",
                project, re.DOTALL,
            )
            self.assertIsNotNone(settings)
            self.assertIn("ARCHS = arm64;", settings[1])
            self.assertIn("ONLY_ACTIVE_ARCH = YES;", settings[1])
        ui_runner = SCRIPT.with_name("run-ui-tests.sh").read_text()
        self.assertIn("  ARCHS=arm64 \\\n", ui_runner)
        self.assertIn("  ONLY_ACTIVE_ARCH=YES \\\n", ui_runner)

    def test_ui_runner_rejects_architecture_overrides_before_cleanup(self) -> None:
        for arguments in (("ARCHS=x86_64",), ("ONLY_ACTIVE_ARCH=NO",),
                          ("-arch", "x86_64")):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["/bin/sh", str(SCRIPT.with_name("run-ui-tests.sh")),
                     "--build-once", *arguments],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("architecture is managed by this runner", result.stderr)

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


class TraceResourcePhaseTests(unittest.TestCase):
    """Keep packaging incremental without changing its signed-helper boundary."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = SCRIPT.parents[2]
        result = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-",
             str(cls.repo_root / "ArkDeck.xcodeproj/project.pbxproj")],
            text=True, capture_output=True, check=True,
        )
        cls.objects = json.loads(result.stdout)["objects"]
        cls.phase = cls.objects["C20000000000000000000030"]

    def file_list(self, name: str) -> list[str]:
        return (self.repo_root / "ArkDeckApp" / name).read_text().splitlines()

    def test_resource_phase_is_incremental_after_final_helper_signing(self) -> None:
        self.assertNotEqual(str(self.phase.get("alwaysOutOfDate", "0")), "1")
        self.assertEqual(
            self.phase["inputPaths"],
            [
                "$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/trace_streamer",
                # The script enumerates *.txt; track directory entry changes
                # as well as the exact files declared in the input file list.
                "$(SRCROOT)/Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES",
            ],
        )
        self.assertEqual(self.phase["inputFileListPaths"], [
            "$(SRCROOT)/ArkDeckApp/TraceRuntimeResources.xcfilelist",
        ])
        self.assertEqual(self.phase["outputFileListPaths"], [
            "$(SRCROOT)/ArkDeckApp/TraceRuntimeOutputs.xcfilelist",
        ])
        app = self.objects["A10000000000000000000050"]
        order = app["buildPhases"]
        prepare, embed, resources = (
            "C20000000000000000000032", "C20000000000000000000031",
            "C20000000000000000000030",
        )
        self.assertLess(order.index(prepare), order.index(embed))
        self.assertLess(order.index(embed), order.index(resources))
        embedded_file = self.objects[self.objects[embed]["files"][0]]
        self.assertIn("CodeSignOnCopy", embedded_file["settings"]["ATTRIBUTES"])
        preparation = self.objects[prepare]["shellScript"]
        self.assertIn("--options runtime --entitlements", preparation)
        self.assertNotIn("codesign", self.phase["shellScript"])
        for configuration in ("A10000000000000000000072", "A10000000000000000000073"):
            self.assertEqual(
                self.objects[configuration]["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"],
                "YES",
            )

    def test_declared_files_cover_exact_canonical_inputs_and_packaged_outputs(self) -> None:
        source = "$(SRCROOT)/Packages/ArkDeckKit"
        licenses = sorted(
            path.name for path in
            (self.repo_root / "Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES").glob("*.txt")
        )
        self.assertTrue(licenses)
        expected_inputs = [
            f"{source}/ThirdParty/TraceStreamer/macx/trace_streamer",
            f"{source}/ThirdParty/TraceStreamer/macx/manifest.json",
            f"{source}/Resources/ArkTraceCLIResources/LICENSE",
            f"{source}/THIRD_PARTY_NOTICES.md",
            *(f"{source}/ThirdParty/TraceStreamer/LICENSES/{name}" for name in licenses),
        ]
        self.assertCountEqual(self.file_list("TraceRuntimeResources.xcfilelist"), expected_inputs)
        destination = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
        expected_outputs = [
            f"{destination}/TraceStreamer/manifest.json",
            f"{destination}/ArkTrace/LICENSE",
            f"{destination}/ArkTrace/THIRD_PARTY_NOTICES.md",
            f"{destination}/ArkTrace/Licenses",
            *(f"{destination}/ArkTrace/Licenses/{name}" for name in licenses),
        ]
        self.assertCountEqual(self.file_list("TraceRuntimeOutputs.xcfilelist"), expected_outputs)

    def test_packaging_hashes_final_helper_without_mutating_canonical_manifest(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        source_root = temporary / "source"
        for entry in self.file_list("TraceRuntimeResources.xcfilelist"):
            relative = entry.removeprefix("$(SRCROOT)/")
            destination = source_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.name == "trace_streamer":
                destination.write_bytes(b"canonical unsigned helper fixture")
            else:
                shutil.copyfile(self.repo_root / relative, destination)
        canonical_manifest = source_root / "Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/manifest.json"
        canonical_bytes = canonical_manifest.read_bytes()
        canonical = json.loads(canonical_bytes)
        products = temporary / "products"
        helper = products / "ArkDeck.app/Contents/MacOS/trace_streamer"
        helper.parent.mkdir(parents=True)
        resources = products / "ArkDeck.app/Contents/Resources"
        license_root = resources / "ArkTrace/Licenses"
        license_root.mkdir(parents=True)
        stale_license = license_root / "stale-license.txt"
        stale_license.write_text("must not survive the next packaging pass")
        environment = os.environ | {
            "SRCROOT": str(source_root),
            "TARGET_BUILD_DIR": str(products),
            "EXECUTABLE_FOLDER_PATH": "ArkDeck.app/Contents/MacOS",
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "ArkDeck.app/Contents/Resources",
        }
        # Synthetic bytes model the already-signed Copy Files output. This
        # tests packaging data flow, not signature validity or device behavior.
        for final_bytes in (b"first signed helper fixture", b"updated signed helper fixture"):
            helper.write_bytes(final_bytes)
            helper.chmod(0o755)
            subprocess.run(
                ["/bin/sh", "-c", self.phase["shellScript"]],
                env=environment, text=True, capture_output=True, check=True, timeout=10,
            )
            packaged = json.loads((resources / "TraceStreamer/manifest.json").read_text())
            self.assertEqual(packaged, canonical | {"binarySHA256": hashlib.sha256(final_bytes).hexdigest()})
            self.assertEqual(canonical_manifest.read_bytes(), canonical_bytes)
            self.assertEqual(helper.read_bytes(), final_bytes)
            self.assertFalse(stale_license.exists())
            expected_licenses = source_root / "Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES"
            self.assertCountEqual(
                [path.name for path in license_root.iterdir()],
                [path.name for path in expected_licenses.iterdir()],
            )
            for path in expected_licenses.iterdir():
                self.assertEqual((license_root / path.name).read_bytes(), path.read_bytes())


if __name__ == "__main__":
    unittest.main()
