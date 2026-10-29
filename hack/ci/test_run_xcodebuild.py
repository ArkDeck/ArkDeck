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


def load_tests(loader, tests, pattern):
    # Keep host keyboard lifecycle regressions in the existing App CI entry.
    tests.addTests(loader.discover(str(SCRIPT.parent), "test_ui_test_input_source.py"))
    tests.addTests(loader.discover(str(SCRIPT.parent), "test_prepare_native_trace.py"))
    return tests


class RunUITestsTests(unittest.TestCase):
    def test_only_execution_modes_use_the_host_keyboard_guard(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "apple/ArkDeck.xcodeproj").mkdir(parents=True)
            scripts = root / "hack/ci"
            scripts.mkdir(parents=True)
            wrapper = scripts / "run-ui-tests.sh"
            shutil.copy2(SCRIPT.with_name("run-ui-tests.sh"), wrapper)
            (scripts / "prepare-native-trace.py").write_text(
                "import argparse,json,os,sys\n"
                "p=argparse.ArgumentParser()\n"
                "for key in ('repo','workspace','source-packages','sdk','signing-identity','inputs','xcodebuild'): p.add_argument('--'+key)\n"
                "for key in ('materialize','resolve'): p.add_argument('--'+key, action='store_true')\n"
                "a=p.parse_args()\n"
                "if os.environ.get('FAKE_TRACE_PREPARATION_EXIT'): sys.exit(41)\n"
                "print(json.dumps({'relativeSDK':'.arktrace-native/test/CArkTrace.xcframework',"
                "'source':a.source_packages+'/checkouts/ArkTrace'}))\n"
            )
            (scripts / "ui_test_input_source.py").write_text(
                "import os, subprocess, sys\n"
                "print('keyboard-guard', flush=True)\n"
                "if os.environ.get('GUARD_FAILURE'): sys.exit(42)\n"
                "os.environ['ARKDECK_UI_TEST_INPUT_SOURCE_GUARDED'] = '1'\n"
                "sys.exit(subprocess.call(sys.argv[1:]))\n"
            )
            binaries = root / "bin"
            binaries.mkdir()
            for name in ("pkill", "pgrep"):
                executable = binaries / name
                executable.write_text("#!/bin/sh\nprintf 'cleanup\\n' >&2\nexit 1\n")
                executable.chmod(0o700)
            xcodebuild = binaries / "xcodebuild"
            xcodebuild.write_text("#!/bin/sh\nprintf 'ARG:%s\\n' \"$@\"\nexit 7\n")
            xcodebuild.chmod(0o700)
            environment = os.environ | {
                "PATH": f"{binaries}:{os.environ['PATH']}",
                "ARKDECK_UI_TEST_DERIVED_DATA": str(root / "Derived Data"),
                "ARKDECK_XCODEBUILD_EXECUTABLE": str(xcodebuild),
            }
            for mode, action in (([], "test"), (["--no-build"], "test-without-building"),
                                 (["--build-once"], "build-for-testing")):
                with self.subTest(action=action):
                    result = subprocess.run(
                        ["sh", str(wrapper), *mode,
                         "-only-testing:ArkDeckHDCUITests/ViewerUITests"],
                        cwd=root, env=environment, text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertEqual("keyboard-guard" in result.stdout,
                                     action != "build-for-testing")
                    self.assertEqual(result.stdout.count("keyboard-guard"),
                                     int(action != "build-for-testing"))
                    self.assertEqual(result.stdout.splitlines()[-1], f"ARG:{action}")
                    self.assertIn("ARG:-only-testing:ArkDeckHDCUITests/ViewerUITests",
                                  result.stdout.splitlines())
                    self.assertNotIn("ARG:-only-testing:ArkDeckHDCUITests",
                                     result.stdout.splitlines())
                    self.assertIn("ARG:ARKDECK_TRACE_NATIVE_SOURCE=" + str(
                        (root / "Derived Data/SourcePackages/checkouts/ArkTrace").resolve()),
                        result.stdout.splitlines())
            failed_preparation = subprocess.run(
                ["sh", str(wrapper), "--build-once"], cwd=root,
                env=environment | {"FAKE_TRACE_PREPARATION_EXIT": "1"}, text=True, capture_output=True,
            )
            self.assertNotEqual(failed_preparation.returncode, 0)
            self.assertNotIn("ARG:", failed_preparation.stdout)
            refused = subprocess.run(
                ["sh", str(wrapper), "--no-build"], cwd=root,
                env=environment | {"GUARD_FAILURE": "1"}, text=True, capture_output=True,
            )
            self.assertEqual(refused.returncode, 42, refused.stderr)
            self.assertNotIn("cleanup", refused.stderr)
            self.assertNotIn("ARG:", refused.stdout)


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
        script = root / "hack/ci/run-xcodebuild.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, script)
        # Runner orchestration uses synthetic preparation; the actual pinned
        # checkout and bundle admission have separate failure regressions.
        (script.parent / "prepare-native-trace.py").write_text(
            "import argparse,json,os,sys\n"
            "p=argparse.ArgumentParser()\n"
            "for key in ('repo','workspace','source-packages','sdk','signing-identity','inputs'): p.add_argument('--'+key)\n"
            "a=p.parse_args()\n"
            "if os.environ.get('FAKE_TRACE_PREPARATION_EXIT'): sys.exit(int(os.environ['FAKE_TRACE_PREPARATION_EXIT']))\n"
            "print(json.dumps({'relativeSDK':'.arktrace-native/test/CArkTrace.xcframework',"
            "'source':a.source_packages+'/checkouts/ArkTrace'}))\n"
        )
        project = root / "apple/ArkDeck.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True)
        project.write_text("// project\n", encoding="utf-8")
        source = root / "apple/ArkDeckApp/App.swift"
        source.parent.mkdir(parents=True)
        source.write_text(source_contents, encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "add", "apple/ArkDeck.xcodeproj", "apple/ArkDeckApp", "hack"],
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
        stale_index = cache_root / "DerivedData/Index.noindex/DataStore"
        stale_index.mkdir(parents=True)
        (stale_index / "record").write_bytes(b"old index data")
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
            ["-project", str(canonical_cache / "workspace/apple/ArkDeck.xcodeproj")],
        )
        self.assertIn(str(canonical_cache / "DerivedData"), arguments)
        self.assertIn(str(canonical_cache / "SourcePackages"), arguments)
        self.assertIn(str(canonical_cache / "PackageCache"), arguments)
        self.assertIn("-showBuildTimingSummary", arguments)
        self.assertIn("ARCHS=arm64", arguments)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", arguments)
        self.assertIn("COMPILATION_CACHE_ENABLE_CACHING=YES", arguments)
        self.assertIn("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES", arguments)
        self.assertIn("COMPILER_INDEX_STORE_ENABLE=NO", arguments)
        self.assertIn("-resolvePackageDependencies", arguments)
        self.assertIn(f"ARKDECK_TRACE_NATIVE_SOURCE={canonical_cache / 'SourcePackages/checkouts/ArkTrace'}", arguments)
        self.assertFalse((cache_root / "DerivedData/Index.noindex").exists())
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
        self.assertIn("COMPILER_INDEX_STORE_ENABLE=NO", arguments)
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
        project = (repo_root / "apple/ArkDeck.xcodeproj/project.pbxproj").read_text()
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
        mirrored = cache_root / "workspace/apple/ArkDeckApp/App.swift"
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
            (cache_root / "workspace/apple/ArkDeckApp/App.swift").read_text(encoding="utf-8"),
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
    """Copy admitted native tools without changing their post-signing bytes."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = SCRIPT.parents[2]
        result = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-",
             str(cls.repo_root / "apple/ArkDeck.xcodeproj/project.pbxproj")],
            text=True, capture_output=True, check=True,
        )
        cls.objects = json.loads(result.stdout)["objects"]
        cls.phase = cls.objects["C20000000000000000000030"]

    def file_list(self, name: str) -> list[str]:
        return (self.repo_root / "apple/ArkDeckApp" / name).read_text().splitlines()

    def test_native_phase_owns_both_tools_and_preserves_script_sandbox(self) -> None:
        self.assertNotEqual(str(self.phase.get("alwaysOutOfDate", "0")), "1")
        self.assertNotIn("C20000000000000000000031", self.objects)
        self.assertNotIn("C20000000000000000000032", self.objects)
        self.assertCountEqual(self.phase["outputPaths"], [
            "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/arktrace-host-process",
            "$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/trace_streamer",
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ArkTraceRuntime/manifest.json",
        ])
        self.assertNotIn("codesign", self.phase["shellScript"])
        self.assertNotIn("plutil", self.phase["shellScript"])
        for configuration in ("A10000000000000000000072", "A10000000000000000000073"):
            self.assertEqual(self.objects[configuration]["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"], "YES")

    def test_sandbox_inputs_cover_all_admitted_files_and_enumerated_directories(self) -> None:
        for folder in ("", "/Helpers", "/TraceStreamer", "/ArkTraceRuntime"):
            self.assertIn("$(SRCROOT)/.arktrace-native/AppInputs" + folder, self.phase["inputPaths"])
        for name in ("receipt.json", "Helpers/arktrace-host-process", "Helpers/trace_streamer",
                     "TraceStreamer/manifest.json", "ArkTraceRuntime/manifest.json"):
            self.assertIn("$(SRCROOT)/.arktrace-native/AppInputs/" + name,
                          self.file_list("TraceRuntimeResources.xcfilelist"))
        source = "$(SRCROOT)/Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES/"
        destination = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ArkTrace/Licenses/"
        for path in (self.repo_root / "apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES").glob("*.txt"):
            self.assertIn(source + path.name, self.file_list("TraceRuntimeResources.xcfilelist"))
            self.assertIn(destination + path.name, self.file_list("TraceRuntimeOutputs.xcfilelist"))

    def test_packaging_preserves_admitted_bytes_and_stops_on_failed_validation(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        source_root = temporary / "source"
        native_inputs = source_root / ".arktrace-native/AppInputs"
        native_inputs.mkdir(parents=True)
        native_files = {
            "Helpers/trace_streamer": b"signed parser fixture",
            "Helpers/arktrace-host-process": b"signed host fixture",
            "TraceStreamer/manifest.json": b'{"binarySHA256":"admitted-parser"}',
            "ArkTraceRuntime/manifest.json": b'{"helperSHA256":"admitted-host"}',
        }
        for name, data in native_files.items():
            path = native_inputs / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for entry in self.file_list("TraceRuntimeResources.xcfilelist"):
            if "/.arktrace-native/" in entry:
                continue
            relative = entry.removeprefix("$(SRCROOT)/")
            target = source_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.repo_root / "apple" / relative, target)
        scripts = temporary / "native-source/hack"
        scripts.mkdir(parents=True)
        copier = scripts / "copy_native_app_resources.py"
        # Exact admission/signature checks are exercised by ArkTrace. This
        # seam verifies the downstream phase neither re-signs nor rewrites
        # tools/manifests after its shared copier has accepted them.
        copier.write_text(
            "from pathlib import Path\nimport sys,shutil\n"
            "assert sys.argv[1:3]==['--product','arkdeck']\n"
            "source,bundle=Path(sys.argv[4]),Path(sys.argv[6])\n"
            "for src,dst in {'Helpers/trace_streamer':'MacOS/trace_streamer',"
            "'Helpers/arktrace-host-process':'Helpers/arktrace-host-process',"
            "'TraceStreamer/manifest.json':'Resources/TraceStreamer/manifest.json',"
            "'ArkTraceRuntime/manifest.json':'Resources/ArkTraceRuntime/manifest.json'}.items():\n"
            " target=bundle/'Contents'/dst\n target.parent.mkdir(parents=True,exist_ok=True)\n"
            " shutil.copyfile(source/src,target)\n"
        )
        products = temporary / "products"
        bundle = products / "ArkDeck.app"
        licenses = bundle / "Contents/Resources/ArkTrace/Licenses"
        licenses.mkdir(parents=True)
        (licenses / "stale.txt").write_text("remove")
        environment = os.environ | {
            "SRCROOT": str(source_root), "TARGET_BUILD_DIR": str(products),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "ArkDeck.app/Contents/Resources",
            "ARKDECK_TRACE_NATIVE_SOURCE": str(scripts.parent), "WRAPPER_NAME": "ArkDeck.app",
        }
        subprocess.run(["/bin/sh", "-c", self.phase["shellScript"]], env=environment,
                       text=True, capture_output=True, check=True, timeout=10)
        for name, data in native_files.items():
            target = ("MacOS/trace_streamer" if name=="Helpers/trace_streamer" else
                      name if name.startswith("Helpers/") else "Resources/" + name)
            self.assertEqual((bundle / "Contents" / target).read_bytes(), data)
            self.assertEqual((native_inputs / name).read_bytes(), data)
        self.assertFalse((licenses / "stale.txt").exists())
        for source in (source_root / "Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES").iterdir():
            self.assertEqual((licenses / source.name).read_bytes(), source.read_bytes())
        copier.write_text("raise SystemExit(17)\n")
        refused = subprocess.run(["/bin/sh", "-c", self.phase["shellScript"]], env=environment,
                                 text=True, capture_output=True, timeout=10)
        self.assertEqual(refused.returncode, 17)


if __name__ == "__main__":
    unittest.main()
