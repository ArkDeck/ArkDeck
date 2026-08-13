#!/usr/bin/env python3
"""Offline contracts for the local Rockchip App build entry point."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import build  # noqa: E402
import local_app  # noqa: E402


class LocalRockchipAppBuildTests(unittest.TestCase):
    def test_pinned_source_set_is_cpp_and_uses_latest_published_standard(self) -> None:
        recipe = build.load_recipe()
        self.assertTrue(recipe["inputs"]["rkdeveloptool"]["sourceFiles"])
        self.assertTrue(
            all(
                Path(name).suffix == ".cpp"
                for name in recipe["inputs"]["rkdeveloptool"]["sourceFiles"]
            )
        )
        self.assertEqual(local_app.LOCAL_C_STANDARD, "c23")
        self.assertEqual(local_app.LOCAL_CXX_STANDARD, "c++23")
        self.assertEqual(
            local_app.LOCAL_CXX_STANDARD,
            recipe["component"]["cxxLanguageStandard"],
        )

    def test_compile_arguments_are_typed_cpp23_and_source_pinned(self) -> None:
        recipe = build.load_recipe()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source/main.cpp"
            output = root / "objects/main.o"
            arguments = local_app._compile_arguments(
                compiler="/toolchain/clang++",
                source=source,
                output=output,
                work_root=root,
                rk_source=root / "source",
                libusb_source=root / "libusb-source",
                libusb_build=root / "libusb-build",
                generated_config=root / "generated/config.h",
                toolchain={"sdkPath": "/SDK"},
                recipe=recipe,
            )
        self.assertEqual(arguments[0], "/toolchain/clang++")
        self.assertIn("-std=c++23", arguments)
        self.assertEqual(arguments[-4:], ["-c", str(source), "-o", str(output)])
        self.assertNotIn("-std=c++11", arguments)

    def test_xcode_arguments_enable_binary_and_matching_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            component = root / "stage/rkdeveloptool"
            metadata = root / "component-output"
            arguments = local_app._xcodebuild_arguments(
                work_root=root,
                component=component,
                metadata_root=metadata,
            )
        self.assertEqual(arguments[0], "/usr/bin/xcodebuild")
        self.assertIn("ROCKCHIP_COMPONENT_INPUT={}".format(component), arguments)
        self.assertIn("ROCKCHIP_COMPONENT_METADATA_ROOT={}".format(metadata), arguments)
        self.assertIn("EXCLUDED_SOURCE_FILE_NAMES=", arguments)
        self.assertNotIn("/bin/sh", arguments)
        self.assertNotIn("/bin/bash", arguments)

    def test_local_source_manifest_covers_local_builder_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "source-distribution-manifest.json"
            build.write_canonical_json(manifest, {"buildFiles": []})
            local_app._augment_local_source_manifest(manifest)
            document = json.loads(manifest.read_text(encoding="utf-8"))
        self.assertTrue(document["developmentOnly"])
        self.assertEqual(
            [item["path"] for item in document["buildFiles"]],
            [
                "scripts/rockchip_component/LOCAL.md",
                "scripts/rockchip_component/local_app.py",
                "scripts/rockchip_component/test_local_app.py",
            ],
        )

    def test_project_keeps_release_metadata_default_and_local_override(self) -> None:
        project = (local_app.PROJECT_PATH / "project.pbxproj").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'path = "$(ROCKCHIP_COMPONENT_METADATA_ROOT)/registry.yaml";',
            project,
        )
        self.assertGreaterEqual(
            project.count(
                'ROCKCHIP_COMPONENT_METADATA_ROOT = "$(SOURCE_ROOT)/openspec/integrations/rockchip/bundled-component/1.0.0";'
            ),
            2,
        )

    def test_local_entry_point_does_not_launch_devices_or_component(self) -> None:
        source = (SCRIPT_DIR / "local_app.py").read_text(encoding="utf-8")
        for forbidden in ("hdc shell", "rkdeveloptool ld", "rkdeveloptool wl", "open -a"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
