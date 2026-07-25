#!/usr/bin/env python3
"""Contract and mutation tests for TASK-BRC-002's build recipe."""

from __future__ import annotations

import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import build  # noqa: E402


class RockchipComponentBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self.recipe = build.load_recipe()

    def _write_tar(
        self,
        path: Path,
        entries: Sequence[Tuple[str, str, bytes, int, Optional[str]]],
    ) -> None:
        mode = "w:gz" if path.suffix == ".gz" else "w:bz2"
        with tarfile.open(path, mode) as archive:
            for name, kind, data, permissions, linkname in entries:
                info = tarfile.TarInfo(name)
                info.mode = permissions
                if kind == "directory":
                    info.type = tarfile.DIRTYPE
                    info.size = 0
                    archive.addfile(info)
                elif kind == "file":
                    info.type = tarfile.REGTYPE
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
                elif kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = linkname or "target"
                    archive.addfile(info)
                elif kind == "hardlink":
                    info.type = tarfile.LNKTYPE
                    info.linkname = linkname or "root/target"
                    archive.addfile(info)
                elif kind == "fifo":
                    info.type = tarfile.FIFOTYPE
                    archive.addfile(info)
                else:
                    raise AssertionError("unsupported test entry kind")

    def _valid_entries(self) -> List[Tuple[str, str, bytes, int, Optional[str]]]:
        return [
            ("root/", "directory", b"", 0o755, None),
            ("root/source.cpp", "file", b"int main() { return 0; }\n", 0o644, None),
        ]

    def test_recipe_is_exact_and_normalization_is_forbidden(self) -> None:
        self.assertEqual(self.recipe["recipeId"], "rockchip-component-build@1.0.0")
        self.assertEqual(self.recipe["component"]["targetTriple"], "arm64-apple-macos14.0")
        self.assertEqual(self.recipe["component"]["architecture"], "arm64")
        self.assertEqual(
            self.recipe["builder"]["hostedImage"],
            {
                "imageOS": "macos26",
                "label": "macos-26-arm64",
                "version": "20260720.0258.1",
            },
        )
        self.assertEqual(self.recipe["builder"]["osBuild"], "25E246")
        self.assertEqual(self.recipe["builder"]["osVersion"], "26.4")
        self.assertEqual(
            self.recipe["builder"]["developerDirectoryAllowlist"],
            ["/Applications/Xcode_26.6.app/Contents/Developer"],
        )
        self.assertRegex(self.recipe["builder"]["gnupgBottle"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(
            self.recipe["builder"]["gnupgBottle"]["formulaCommit"],
            r"^[0-9a-f]{40}$",
        )
        for tool_name in ("gpg", "gpgv"):
            tool = self.recipe["builder"][tool_name]
            self.assertEqual(tool["version"], "2.5.21")
            self.assertTrue(tool["absolutePath"].startswith("/opt/homebrew/bin/"))
            self.assertTrue(
                tool["realPath"].startswith("/opt/homebrew/Cellar/gnupg/2.5.21/bin/")
            )
            self.assertNotIn("sha256", tool)
        self.assertEqual(self.recipe["reproducibility"]["cleanBuilders"], 2)
        self.assertEqual(self.recipe["reproducibility"]["normalization"], "forbidden")
        self.assertEqual(self.recipe["environment"]["callerPATH"], "ignored")
        self.assertEqual(self.recipe["environment"]["homebrewBuildPaths"], "denied")

    def test_pinned_input_digests_are_not_placeholders(self) -> None:
        assets = [
            self.recipe["inputs"]["rkdeveloptool"]["archive"],
            self.recipe["inputs"]["libusb"]["archive"],
            self.recipe["inputs"]["libusb"]["signature"],
            self.recipe["inputs"]["libusb"]["keys"],
        ]
        for asset in assets:
            with self.subTest(asset=asset["filename"]):
                self.assertRegex(asset["sha256"], r"^[0-9a-f]{64}$")
                self.assertGreater(asset["size"], 0)
                self.assertTrue(asset["url"].startswith("https://"))

    def test_hosted_image_mutations_fail_closed(self) -> None:
        expected = self.recipe["builder"]["hostedImage"]
        build._require_exact_fact("hosted image", dict(expected), expected)
        mutations = (
            {**expected, "imageOS": "macos27"},
            {**expected, "label": "macos-26"},
            {**expected, "version": "20260721.0000.1"},
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(build.BuildError):
                build._require_exact_fact("hosted image", mutation, expected)

    def test_archive_accepts_one_root_and_extracts_regular_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "fixture.tar.gz"
            entries = self._valid_entries() + [
                ("root/configure", "file", b"#!/bin/sh\n", 0o755, None)
            ]
            self._write_tar(archive, entries)
            members = build.validate_archive(archive, "root")
            self.assertEqual([item.kind for item in members], ["directory", "file", "file"])
            destination = root / "out"
            inventory = build.extract_archive(archive, "root", destination)
            self.assertEqual(
                [item["path"] for item in inventory],
                ["configure", "source.cpp"],
            )
            self.assertEqual(
                (destination / "root/source.cpp").read_bytes(),
                b"int main() { return 0; }\n",
            )
            self.assertEqual(
                (destination / "root/configure").stat().st_mode & 0o777,
                0o755,
            )

    def test_archive_mutations_fail_closed(self) -> None:
        cases = {
            "absolute": [("/root/source", "file", b"x", 0o644, None)],
            "traversal": [("root/../escape", "file", b"x", 0o644, None)],
            "second-root": [
                ("root/a", "file", b"x", 0o644, None),
                ("other/b", "file", b"x", 0o644, None),
            ],
            "casefold-duplicate": [
                ("root/A", "file", b"x", 0o644, None),
                ("root/a", "file", b"y", 0o644, None),
            ],
            "symlink": [("root/link", "symlink", b"", 0o777, "root/source")],
            "hardlink": [("root/link", "hardlink", b"", 0o644, "root/source")],
            "fifo": [("root/pipe", "fifo", b"", 0o644, None)],
            "privilege-mode": [("root/tool", "file", b"x", 0o4755, None)],
            "backslash": [("root\\escape", "file", b"x", 0o644, None)],
            "noncanonical": [("root//source", "file", b"x", 0o644, None)],
        }
        for name, entries in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "fixture.tar.gz"
                self._write_tar(archive, entries)
                with self.assertRaises(build.BuildError):
                    build.validate_archive(archive, "root")

    def test_file_pin_mutations_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "asset"
            path.write_bytes(b"accepted")
            pin = {
                "filename": "asset",
                "size": len(b"accepted"),
                "sha256": build.sha256_bytes(b"accepted"),
            }
            build.verify_file_pin(path, pin)
            for mutation in (
                {**pin, "size": pin["size"] + 1},
                {**pin, "sha256": "0" * 64},
            ):
                with self.subTest(mutation=mutation), self.assertRaises(build.BuildError):
                    build.verify_file_pin(path, mutation)

    def test_closed_environment_ignores_caller_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            toolchain = {
                "developerDirectory": "/Applications/Xcode.app/Contents/Developer",
                "sdkPath": "/Applications/Xcode.app/SDK",
                "tools": {
                    "ar": "/Applications/Xcode.app/ar",
                    "clang": "/Applications/Xcode.app/clang",
                    "clang++": "/Applications/Xcode.app/clang++",
                    "nm": "/Applications/Xcode.app/nm",
                    "ranlib": "/Applications/Xcode.app/ranlib",
                    "strip": "/Applications/Xcode.app/strip",
                },
            }
            old_path = os.environ.get("PATH")
            os.environ["PATH"] = "/opt/homebrew/bin:/attacker"
            try:
                env = build._closed_build_environment(root, toolchain, self.recipe)
            finally:
                if old_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = old_path
            self.assertEqual(env["PATH"], "/usr/bin:/bin")
            self.assertNotIn("/opt/homebrew", json.dumps(env))
            self.assertEqual(env["CONFIG_SITE"], "/dev/null")
            self.assertEqual(env["PKG_CONFIG"], "/usr/bin/false")
            self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "14.0")

    def test_otool_dependency_parser_is_order_independent(self) -> None:
        output = """binary:
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)
\t/usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 1.0.0)
"""
        self.assertEqual(
            build._parse_otool_dependencies(output),
            ["/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib"],
        )

    def test_receipt_path_sanitization_is_deterministic(self) -> None:
        recorder = build.CommandRecorder(
            {
                "/private/tmp/builder-a": "$WORK_ROOT",
                "/Applications/Xcode.app/Contents/Developer": "$DEVELOPER_DIR",
            }
        )
        observed = recorder.sanitize(
            "/private/tmp/builder-a/out\n"
            "/Applications/Xcode.app/Contents/Developer/usr/bin/clang\n"
        )
        self.assertEqual(
            observed,
            "$WORK_ROOT/out\n$DEVELOPER_DIR/usr/bin/clang\n",
        )

    def test_minimum_os_parser_requires_build_version_command(self) -> None:
        valid = """Load command 8
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.0
"""
        self.assertEqual(build._parse_minos(valid), "14.0")
        with self.assertRaises(build.BuildError):
            build._parse_minos("cmd LC_VERSION_MIN_MACOSX\nversion 14.0\n")

    def test_sensitive_values_are_rejected(self) -> None:
        build.assert_no_sensitive_values({"safe": "/Applications/Xcode.app"})
        for value in (
            "/Users/alice/image.img",
            "/private/tmp/build",
            "-----BEGIN PRIVATE KEY-----",
            "github_pat_example",
        ):
            with self.subTest(value=value), self.assertRaises(build.BuildError):
                build.assert_no_sensitive_values({"unsafe": value})

    def _minimal_spdx_source(self, root: Path) -> Tuple[List[Dict[str, Any]], Path]:
        source = root / "rk"
        source.mkdir()
        property_text = (
            "/* Redistribution is permitted when this header is retained. */\n"
            "#ifndef PROPERTY_HPP\n"
        )
        (source / "Property.hpp").write_text(property_text, encoding="utf-8")
        inventory = [
            {
                "path": "Property.hpp",
                "sha1": build.sha1_file(source / "Property.hpp"),
                "sha256": build.sha256_file(source / "Property.hpp"),
                "size": (source / "Property.hpp").stat().st_size,
            }
        ]
        return inventory, source

    def test_spdx_has_required_relationships_and_custom_license(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory, source = self._minimal_spdx_source(root)
            path = root / "sbom.json"
            artifact = {"sha256": "a" * 64}
            build.generate_spdx(path, inventory, source, artifact, self.recipe)
            build.validate_spdx(path)
            document = json.loads(path.read_text(encoding="utf-8"))
            relationships = {item["relationshipType"] for item in document["relationships"]}
            self.assertTrue(
                {"BUILD_TOOL_OF", "DEPENDS_ON", "DESCRIBES", "GENERATED_FROM", "STATIC_LINK"}
                <= relationships
            )

    def test_spdx_relationship_mutation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory, source = self._minimal_spdx_source(root)
            path = root / "sbom.json"
            build.generate_spdx(path, inventory, source, {"sha256": "a" * 64}, self.recipe)
            document = json.loads(path.read_text(encoding="utf-8"))
            document["relationships"] = [
                item
                for item in document["relationships"]
                if item["relationshipType"] != "STATIC_LINK"
            ]
            build.write_canonical_json(path, document)
            with self.assertRaises(build.BuildError):
                build.validate_spdx(path)

    def _receipt(self, builder_id: str) -> Dict[str, Any]:
        return {
            "artifact": {"sha256": "a" * 64},
            "builderId": builder_id,
            "commandDigest": "b" * 64,
            "metadata": {"registry.yaml": {"sha256": "c" * 64}},
            "recipe": {"sha256": "d" * 64},
            "signature": {"verdict": "GOODSIG+VALIDSIG"},
            "toolchain": {
                "signatureVerifier": {
                    "tools": {
                        "gpg": {"sha256": "e" * 64},
                        "gpgv": {"sha256": "f" * 64},
                    }
                },
                "xcodeVersion": "26.6",
            },
        }

    def _write_compare_fixture(self, root: Path, builder_id: str) -> None:
        names = [
            self.recipe["component"]["outputName"],
            *build.OUTPUT_METADATA,
        ]
        for name in names:
            (root / name).write_bytes(("same:" + name).encode("utf-8"))
        build.write_canonical_json(root / "builder-receipt.json", self._receipt(builder_id))

    def test_compare_requires_two_distinct_byte_identical_builders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            a = root / "a"
            b = root / "b"
            a.mkdir()
            b.mkdir()
            self._write_compare_fixture(a, "builder-a")
            self._write_compare_fixture(b, "builder-b")
            output = root / "comparison.json"
            result = build.compare_outputs(a, b, output)
            self.assertEqual(result["verdict"], "PASS-byte-identical")
            self.assertFalse(result["sharedBuildRoot"])

            (b / "rkdeveloptool").write_bytes(b"mutated")
            with self.assertRaises(build.BuildError):
                build.compare_outputs(a, b, output)

    def test_compare_rejects_same_builder_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            a = root / "a"
            b = root / "b"
            a.mkdir()
            b.mkdir()
            self._write_compare_fixture(a, "builder-a")
            self._write_compare_fixture(b, "builder-a")
            with self.assertRaises(build.BuildError):
                build.compare_outputs(a, b, root / "comparison.json")

    def test_compare_rejects_verifier_hash_disagreement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            a = root / "a"
            b = root / "b"
            a.mkdir()
            b.mkdir()
            self._write_compare_fixture(a, "builder-a")
            self._write_compare_fixture(b, "builder-b")
            receipt = json.loads((b / "builder-receipt.json").read_text(encoding="utf-8"))
            receipt["toolchain"]["signatureVerifier"]["tools"]["gpg"]["sha256"] = "0" * 64
            build.write_canonical_json(b / "builder-receipt.json", receipt)
            with self.assertRaises(build.BuildError):
                build.compare_outputs(a, b, root / "comparison.json")

    def test_registry_rejects_dependency_and_normalization_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "registry.json"
            base = {
                "artifact": {
                    "dependencies": sorted(
                        self.recipe["inspection"]["directDependencyAllowlist"]
                    )
                },
                "build": {
                    "normalization": "forbidden",
                    "recipeSHA256": build.sha256_file(build.RECIPE_PATH),
                },
                "dependencies": {"nonSystemBundledDylibCount": 0},
                "registryVersion": "1.0.0",
            }
            build.write_canonical_json(path, base)
            build.validate_registry(path, self.recipe)
            mutations = [
                {**base, "artifact": {"dependencies": ["/tmp/ambient.dylib"]}},
                {**base, "build": {**base["build"], "normalization": "strip-after-compare"}},
                {
                    **base,
                    "dependencies": {"nonSystemBundledDylibCount": 1},
                },
            ]
            for mutation in mutations:
                with self.subTest(mutation=mutation):
                    build.write_canonical_json(path, mutation)
                    with self.assertRaises(build.BuildError):
                        build.validate_registry(path, self.recipe)

    def test_source_never_uses_shell_expansion_apis(self) -> None:
        source = (SCRIPT_DIR / "build.py").read_text(encoding="utf-8")
        forbidden = ("shell=True", "os.system(", "os.popen(", "subprocess.Popen(")
        for marker in forbidden:
            with self.subTest(marker=marker):
                self.assertNotIn(marker, source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
