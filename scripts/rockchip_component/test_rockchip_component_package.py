#!/usr/bin/env python3
"""Offline contract and mutation tests for the release packager."""

from __future__ import annotations

import copy
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

import rockchip_component_package as package


class ContractFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.spec = package.load_json(package.PACKAGE_SPEC_PATH)
        cls.registry = package.load_json(package.REGISTRY_PATH)

    def valid_unsigned(self) -> dict:
        component = self.spec["component"]
        artifact = self.registry["artifact"]
        return {
            "exists": True,
            "regular": True,
            "symlink": False,
            "size": component["size"],
            "sha256": component["sha256"],
            "fileType": "Mach-O 64-bit executable arm64",
            "architectures": list(component["architectures"]),
            "machoUUID": component["machoUUID"],
            "minimumMacOS": component["minimumMacOS"],
            "loadCommandsSHA256": artifact["loadCommandsSHA256"],
            "dependencies": sorted(component["dependencies"]),
            "signature": "absent",
            "versionFormatPresent": True,
            "versionLiteralPresent": True,
        }

    def signature(self, identifier: str, entitlements: dict) -> dict:
        signing = self.spec["signing"]
        return {
            "identifier": identifier,
            "teamIdentifier": signing["teamIdentifier"],
            "authority": signing["identityKind"] + ": Test",
            "certificateSHA1": signing["certificateSHA1"],
            "certificateValid": True,
            "chainTrusted": True,
            "hardenedRuntime": True,
            "timestampPresent": True,
            "designatedRequirement": (
                f'designated => identifier "{identifier}" and anchor apple generic'
            ),
            "entitlements": copy.deepcopy(entitlements),
            "strictVerification": True,
        }

    def valid_archive(self) -> dict:
        app = {
            **self.signature(
                self.spec["app"]["bundleIdentifier"],
                self.spec["app"]["entitlements"],
            ),
            "bundleIdentifier": self.spec["app"]["bundleIdentifier"],
            "version": self.spec["app"]["version"],
            "buildVersion": self.spec["app"]["buildVersion"],
            "architectures": list(self.spec["app"]["architectures"]),
            "minimumMacOS": self.spec["app"]["minimumMacOS"],
        }
        component = {
            **self.signature(
                self.spec["component"]["identifier"],
                self.spec["component"]["entitlements"],
            ),
            "bundlePath": self.spec["component"]["bundlePath"],
            "architectures": list(self.spec["component"]["architectures"]),
            "machoUUID": self.spec["component"]["machoUUID"],
            "minimumMacOS": self.spec["component"]["minimumMacOS"],
        }
        metadata = {
            item["name"]: item["sha256"] for item in self.spec["metadata"]["files"]
        }
        return {
            "app": app,
            "component": component,
            "metadata": metadata,
            "nestedCodePaths": sorted(
                [
                    "Contents/MacOS/ArkDeck",
                    self.spec["component"]["bundlePath"],
                ]
            ),
            "appTreeSHA256": "a" * 64,
        }

    def valid_dmg(self) -> dict:
        signing = self.spec["signing"]
        return {
            "valid": True,
            "signed": True,
            "rootEntries": sorted(self.spec["distribution"]["rootEntries"]),
            "identifier": None,
            "teamIdentifier": signing["teamIdentifier"],
            "authority": signing["identityKind"] + ": Test",
            "certificateSHA1": signing["certificateSHA1"],
            "hardenedRuntime": False,
            "timestampPresent": True,
            "designatedRequirement": "anchor apple generic",
            "entitlements": None,
            "strictVerification": True,
        }

    def valid_notary(self) -> dict:
        return {
            "submissionId": "11111111-2222-3333-4444-555555555555",
            "logPresent": True,
            "status": "Accepted",
            "logStatus": "Accepted",
            "issueCount": 0,
        }

    def valid_final(self) -> dict:
        return {
            "stapleValid": True,
            "dmgGatekeeper": True,
            "appGatekeeper": True,
            "archiveAppTreeSHA256": "a" * 64,
            "mountedAppTreeSHA256": "a" * 64,
        }

    def valid_receipt(self) -> dict:
        metadata = {
            item["name"]: item["sha256"] for item in self.spec["metadata"]["files"]
        }
        tuple_value = {
            "app": {
                "bundleIdentifier": self.spec["app"]["bundleIdentifier"],
                "version": self.spec["app"]["version"],
                "buildVersion": self.spec["app"]["buildVersion"],
                "treeSHA256": "a" * 64,
            },
            "component": {
                "identifier": self.spec["component"]["identifier"],
                "machoUUID": self.spec["component"]["machoUUID"],
                "unsignedSHA256": self.spec["component"]["sha256"],
                "signedSHA256": "b" * 64,
            },
            "dmg": {
                "name": self.spec["distribution"]["dmgName"],
                "sha256": "c" * 64,
                "size": 123456,
            },
            "metadata": metadata,
            "notarySubmissionId": "11111111-2222-3333-4444-555555555555",
        }
        return {
            "effectCounters": {
                "appLaunch": 0,
                "componentLaunch": 0,
                "deviceMutation": 0,
                "dmgInstall": 0,
                "e1Dispatch": 0,
                "e2Dispatch": 0,
                "hdcAccess": 0,
                "releaseUpload": 0,
                "usbAccess": 0,
            },
            "generatedAt": "2026-07-29T00:00:00Z",
            "packageId": self.spec["packageId"],
            "schemaVersion": "1.0.0",
            "signing": {
                "certificateSHA1": self.spec["signing"]["certificateSHA1"],
                "hardenedRuntime": True,
                "identityKind": self.spec["signing"]["identityKind"],
                "secureTimestamp": True,
                "teamIdentifier": self.spec["signing"]["teamIdentifier"],
            },
            "sourceArtifact": {
                **self.spec["sourceArtifact"],
                "componentSHA256": self.spec["component"]["sha256"],
                "componentSize": self.spec["component"]["size"],
            },
            "tuple": tuple_value,
            "tupleSHA256": package.sha256_bytes(
                package.canonical_json_bytes(tuple_value)
            ),
            "validation": {
                "archive": "PASS",
                "componentInput": "PASS",
                "dmg": "PASS",
                "gatekeeperApp": "PASS",
                "gatekeeperDMG": "PASS",
                "notary": "Accepted",
                "staple": "PASS",
            },
            "verdict": "PASS",
        }

    def assert_mutation_fails(self, validator, valid: dict, path: tuple, value) -> None:
        mutated = copy.deepcopy(valid)
        cursor = mutated
        for key in path[:-1]:
            cursor = cursor[key]
        if value is _DELETE:
            del cursor[path[-1]]
        else:
            cursor[path[-1]] = value
        with self.assertRaises(package.PackageError):
            validator(mutated)


_DELETE = object()


class PackageSourceContractTests(ContractFixture):
    def test_package_registry_and_metadata_pins_are_exact(self) -> None:
        self.assertEqual(
            self.spec["component"]["sha256"],
            self.registry["artifact"]["sha256"],
        )
        self.assertEqual(
            self.spec["component"]["machoUUID"],
            self.registry["artifact"]["machoUUID"],
        )
        self.assertEqual(
            self.spec["component"]["dependencies"],
            self.registry["artifact"]["dependencies"],
        )
        for item in self.spec["metadata"]["files"]:
            path = package.INTEGRATION_ROOT / item["name"]
            self.assertEqual(package.sha256_file(path), item["sha256"])

    def test_source_entitlements_are_exact(self) -> None:
        self.assertEqual(
            package.load_plist(package.APP_ENTITLEMENTS_PATH),
            self.spec["app"]["entitlements"],
        )
        self.assertEqual(
            package.load_plist(package.COMPONENT_ENTITLEMENTS_PATH),
            self.spec["component"]["entitlements"],
        )

    def test_xcode_project_has_fixed_copy_and_release_signing_contract(self) -> None:
        project = (package.REPO_ROOT / "ArkDeck.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        required_literals = [
            "Embed Rockchip Component",
            "Embed Rockchip Component Metadata",
            "CodeSignOnCopy",
            "dstSubfolderSpec = 6;",
            "dstPath = RockchipComponent/1.0.0;",
            'path = "$(ROCKCHIP_COMPONENT_INPUT)";',
            "EXCLUDED_SOURCE_FILE_NAMES = false;",
            "ARCHS = arm64;",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;",
            "ENABLE_HARDENED_RUNTIME = YES;",
            'OTHER_CODE_SIGN_FLAGS = "--timestamp";',
            "DEVELOPMENT_TEAM = 8AQTYW5FKR;",
        ]
        for literal in required_literals:
            with self.subTest(literal=literal):
                self.assertIn(literal, project)

    def test_runner_rejects_relative_commands_and_shell_launchers(self) -> None:
        runner = package.Runner({})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {"PATH": "/usr/bin:/bin"}
            with self.assertRaises(package.PackageError):
                runner.run(["codesign"], cwd=root, env=env)
            with self.assertRaises(package.PackageError):
                runner.run(["/bin/sh", "-c", "true"], cwd=root, env=env)

    def test_sanitizer_removes_profile_and_user_paths(self) -> None:
        runner = package.Runner(
            {
                "secret-profile": "<NOTARY_PROFILE>",
                "/Users/example/private/login.keychain-db": "<NOTARY_KEYCHAIN>",
            }
        )
        observed = runner.sanitize(
            "secret-profile /Users/example/private/login.keychain-db "
            "/Users/example/private/release/output"
        )
        self.assertNotIn("secret-profile", observed)
        self.assertNotIn("/Users/example", observed)
        self.assertIn("<NOTARY_KEYCHAIN>", observed)

    def test_notary_preflight_binds_the_explicit_keychain(self) -> None:
        class CapturingRunner:
            def __init__(self) -> None:
                self.arguments = []

            def run(self, arguments, **_kwargs):
                self.arguments = [str(argument) for argument in arguments]
                return package.CommandResult(
                    argv0="xcrun",
                    exit_code=0,
                    stdout="{}",
                    stderr="",
                )

        runner = CapturingRunner()
        package.preflight_notary_auth(
            profile="opaque-profile",
            keychain=Path("/Users/example/private/login.keychain-db"),
            runner=runner,
            env={},
            cwd=Path("/private/tmp"),
        )
        self.assertEqual(
            runner.arguments,
            [
                "/usr/bin/xcrun",
                "notarytool",
                "history",
                "--keychain-profile",
                "opaque-profile",
                "--keychain",
                "/Users/example/private/login.keychain-db",
                "--output-format",
                "json",
            ],
        )

    def test_regular_file_gate_rejects_symlink_and_nonregular_input(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            regular = root / "component"
            regular.write_bytes(b"fixture")
            package.ensure_regular_no_symlink(regular, "fixture")
            alias = root / "alias"
            alias.symlink_to(regular)
            with self.assertRaises(package.PackageError):
                package.ensure_regular_no_symlink(alias, "fixture")
            with self.assertRaises(package.PackageError):
                package.ensure_regular_no_symlink(root, "fixture")

    def test_repository_output_and_input_are_forbidden(self) -> None:
        with self.assertRaises(package.PackageError):
            package.ensure_outside_repository(
                package.REPO_ROOT / "rkdeveloptool", "component input"
            )
        with self.assertRaises(package.PackageError):
            package.ensure_outside_repository(
                package.REPO_ROOT / "release", "release output"
            )

    def test_load_command_and_dependency_parsers(self) -> None:
        load = (
            "/tmp/rkdeveloptool:\n"
            "Load command 9\n"
            "      cmd LC_BUILD_VERSION\n"
            "  cmdsize 32\n"
            " platform 1\n"
            "    minos 14.0\n"
            "Load command 10\n"
            "       cmd LC_UUID\n"
            "   cmdsize 24\n"
            "      uuid 8AB1A64A-F879-3FC1-A6DE-63D3529C79C6\n"
        )
        self.assertEqual(package.parse_minos(load), "14.0")
        self.assertEqual(
            package.parse_macho_uuid(load),
            "8ab1a64a-f879-3fc1-a6de-63d3529c79c6",
        )
        with self.assertRaises(package.PackageError):
            package.parse_macho_uuid(load.replace("LC_UUID", "LC_LOAD_DYLIB"))
        with self.assertRaises(package.PackageError):
            package.parse_macho_uuid(
                load.replace(
                    "8AB1A64A-F879-3FC1-A6DE-63D3529C79C6", "not-a-uuid"
                )
            )
        self.assertTrue(
            package.normalize_load_commands(load).startswith(
                "$OUTPUT_DIR/rkdeveloptool:"
            )
        )
        dependencies = (
            "/tmp/rkdeveloptool:\n"
            "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
            "\t/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit "
            "(compatibility version 1.0.0)\n"
        )
        self.assertEqual(
            package.parse_dependencies(dependencies),
            [
                "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
                "/usr/lib/libSystem.B.dylib",
            ],
        )

    def test_codesign_entitlement_parser_ignores_trailing_diagnostics(self) -> None:
        plist = plistlib.dumps(
            {"com.apple.security.app-sandbox": True},
            fmt=plistlib.FMT_XML,
        )
        observed = package.plist_from_codesign_output(
            b"prefix diagnostic\n" + plist + b"\nExecutable=<COMPONENT>\n"
        )
        self.assertEqual(
            observed,
            {"com.apple.security.app-sandbox": True},
        )

    def test_certificate_extraction_uses_single_equals_option(self) -> None:
        source = (
            package.REPO_ROOT
            / "scripts/rockchip_component/rockchip_component_package.py"
        ).read_text(encoding="utf-8")
        self.assertIn('f"--extract-certificates={prefix}"', source)
        self.assertNotIn('"--extract-certificates",\n            str(prefix)', source)


class UnsignedInputMutationTests(ContractFixture):
    def test_valid_unsigned_facts_pass(self) -> None:
        package.validate_unsigned_facts(
            self.valid_unsigned(), self.spec, self.registry
        )

    def test_every_unsigned_input_drift_fails_closed(self) -> None:
        mutations = [
            (("exists",), False, "missing"),
            (("regular",), False, "nonregular"),
            (("symlink",), True, "symlink"),
            (("size",), 1, "size"),
            (("sha256",), "0" * 64, "hash"),
            (("fileType",), "data", "Mach-O"),
            (("architectures",), ["x86_64"], "architecture"),
            (("machoUUID",), "0" * 36, "Mach-O UUID"),
            (("minimumMacOS",), "13.0", "minimum OS"),
            (("loadCommandsSHA256",), "0" * 64, "load commands"),
            (
                ("dependencies",),
                ["/usr/local/lib/libusb.dylib"],
                "dependencies",
            ),
            (("signature",), "present", "signed input"),
            (("versionFormatPresent",), False, "version format"),
            (("versionLiteralPresent",), False, "version literal"),
        ]
        for path, value, label in mutations:
            with self.subTest(label=label):
                self.assert_mutation_fails(
                    lambda facts: package.validate_unsigned_facts(
                        facts, self.spec, self.registry
                    ),
                    self.valid_unsigned(),
                    path,
                    value,
                )


class ArchiveMutationTests(ContractFixture):
    def test_device_elf_resource_is_host_data_not_nested_macos_code(self) -> None:
        helper = (
            package.REPO_ROOT
            / "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Resources"
            / "OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable"
        )
        self.assertEqual(helper.stat().st_mode & 0o111, 0)

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "ArkDeck.app"
            app_binary = app / "Contents/MacOS/ArkDeck"
            component = app / self.spec["component"]["bundlePath"]
            bundled_helper = (
                app
                / "Contents/Resources/ArkDeckKit_ArkDeckWorkflows.bundle"
                / "Contents/Resources/OpenHarmonyNativeCodeSign"
                / "arkdeck-code-sign-enable"
            )
            for path in (app_binary, component, bundled_helper):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
            app_binary.chmod(0o755)
            component.chmod(0o755)
            bundled_helper.chmod(0o644)

            self.assertEqual(
                package.nested_code_paths(app),
                sorted(
                    [
                        "Contents/MacOS/ArkDeck",
                        self.spec["component"]["bundlePath"],
                    ]
                ),
            )

            bundled_helper.chmod(0o755)
            self.assertIn(
                bundled_helper.relative_to(app).as_posix(),
                package.nested_code_paths(app),
            )

    def test_valid_archive_facts_pass(self) -> None:
        package.validate_archive_facts(self.valid_archive(), self.spec)

    def test_component_location_identity_and_binary_mutations_fail(self) -> None:
        mutations = [
            (("component", "bundlePath"), "Contents/Resources/rkdeveloptool"),
            (("component", "identifier"), "com.example.rkdeveloptool"),
            (("component", "architectures"), ["x86_64"]),
            (("component", "machoUUID"), "0" * 36),
            (("component", "minimumMacOS"), "13.0"),
            (("nestedCodePaths",), ["Contents/MacOS/ArkDeck"]),
            (
                ("nestedCodePaths",),
                [
                    "Contents/MacOS/ArkDeck",
                    "Contents/MacOS/rkdeveloptool",
                    "Contents/Frameworks/extra.dylib",
                ],
            ),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                self.assert_mutation_fails(
                    lambda facts: package.validate_archive_facts(facts, self.spec),
                    self.valid_archive(),
                    path,
                    value,
                )

    def test_component_entitlement_and_runtime_mutations_fail(self) -> None:
        missing = copy.deepcopy(self.spec["component"]["entitlements"])
        del missing["com.apple.security.inherit"]
        extra = copy.deepcopy(self.spec["component"]["entitlements"])
        extra["com.apple.security.cs.disable-library-validation"] = True
        mutations = [
            (("component", "entitlements"), missing),
            (("component", "entitlements"), extra),
            (("component", "hardenedRuntime"), False),
            (("component", "strictVerification"), False),
            (("component", "designatedRequirement"), "identifier only"),
        ]
        for path, value in mutations:
            with self.subTest(path=path):
                self.assert_mutation_fails(
                    lambda facts: package.validate_archive_facts(facts, self.spec),
                    self.valid_archive(),
                    path,
                    value,
                )

    def test_component_signature_mutations_fail(self) -> None:
        mutations = [
            (("component", "authority"), "adhoc"),
            (("component", "authority"), "Apple Development: Test"),
            (("component", "teamIdentifier"), "WRONGTEAM1"),
            (("component", "certificateSHA1"), "0" * 40),
            (("component", "certificateValid"), False),
            (("component", "chainTrusted"), False),
            (("component", "timestampPresent"), False),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                self.assert_mutation_fails(
                    lambda facts: package.validate_archive_facts(facts, self.spec),
                    self.valid_archive(),
                    path,
                    value,
                )

    def test_app_shape_entitlement_and_signature_mutations_fail(self) -> None:
        missing = copy.deepcopy(self.spec["app"]["entitlements"])
        del missing["com.apple.security.app-sandbox"]
        extra = copy.deepcopy(self.spec["app"]["entitlements"])
        extra["com.apple.security.get-task-allow"] = True
        mutations = [
            (("app", "bundleIdentifier"), "com.example.desktop"),
            (("app", "identifier"), "com.example.desktop"),
            (("app", "version"), "0.2.0"),
            (("app", "buildVersion"), "2"),
            (("app", "architectures"), ["arm64", "x86_64"]),
            (("app", "minimumMacOS"), "13.0"),
            (("app", "entitlements"), missing),
            (("app", "entitlements"), extra),
            (("app", "authority"), "adhoc"),
            (("app", "teamIdentifier"), "WRONGTEAM1"),
            (("app", "certificateSHA1"), "0" * 40),
            (("app", "certificateValid"), False),
            (("app", "chainTrusted"), False),
            (("app", "timestampPresent"), False),
            (("app", "hardenedRuntime"), False),
            (("app", "strictVerification"), False),
            (("app", "designatedRequirement"), "identifier only"),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                self.assert_mutation_fails(
                    lambda facts: package.validate_archive_facts(facts, self.spec),
                    self.valid_archive(),
                    path,
                    value,
                )

    def test_metadata_missing_extra_and_drift_mutations_fail(self) -> None:
        valid = self.valid_archive()
        missing = copy.deepcopy(valid["metadata"])
        missing.pop("sbom.spdx.json")
        extra = copy.deepcopy(valid["metadata"])
        extra["unexpected"] = "0" * 64
        drift = copy.deepcopy(valid["metadata"])
        drift["THIRD-PARTY-NOTICES.txt"] = "0" * 64
        for value, label in (
            (missing, "missing"),
            (extra, "extra"),
            (drift, "drift"),
        ):
            with self.subTest(label=label):
                self.assert_mutation_fails(
                    lambda facts: package.validate_archive_facts(facts, self.spec),
                    valid,
                    ("metadata",),
                    value,
                )


class DmgNotaryAndReceiptMutationTests(ContractFixture):
    def test_valid_dmg_notary_final_and_receipt_pass(self) -> None:
        package.validate_dmg_facts(self.valid_dmg(), self.spec)
        package.validate_notary_facts(self.valid_notary())
        package.validate_final_facts(self.valid_final())
        package.validate_receipt(self.valid_receipt(), self.spec)

    def test_unsigned_malformed_or_wrongly_signed_dmg_fails(self) -> None:
        mutations = [
            (("valid",), False),
            (("signed",), False),
            (("rootEntries",), ["ArkDeck.app"]),
            (("authority",), "adhoc"),
            (("teamIdentifier",), "WRONGTEAM1"),
            (("certificateSHA1",), "0" * 40),
            (("timestampPresent",), False),
            (("strictVerification",), False),
        ]
        for path, value in mutations:
            with self.subTest(path=path):
                self.assert_mutation_fails(
                    lambda facts: package.validate_dmg_facts(facts, self.spec),
                    self.valid_dmg(),
                    path,
                    value,
                )

    def test_notary_rejected_invalid_unknown_or_missing_log_fails(self) -> None:
        mutations = [
            (("submissionId",), ""),
            (("logPresent",), False),
            (("status",), "Rejected"),
            (("status",), "Invalid"),
            (("status",), "Unknown"),
            (("logStatus",), "Rejected"),
            (("issueCount",), 1),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                self.assert_mutation_fails(
                    package.validate_notary_facts,
                    self.valid_notary(),
                    path,
                    value,
                )

    def test_staple_gatekeeper_and_contained_app_drift_fail(self) -> None:
        mutations = [
            (("stapleValid",), False),
            (("dmgGatekeeper",), False),
            (("appGatekeeper",), False),
            (("mountedAppTreeSHA256",), "0" * 64),
        ]
        for path, value in mutations:
            with self.subTest(path=path):
                self.assert_mutation_fails(
                    package.validate_final_facts,
                    self.valid_final(),
                    path,
                    value,
                )

    def test_mixed_atomic_tuple_and_self_report_mutations_fail(self) -> None:
        mutations = [
            (("verdict",), "PASS-SELF-REPORTED"),
            (("validation", "notary"), "Unknown"),
            (("signing", "teamIdentifier"), "WRONGTEAM1"),
            (("sourceArtifact", "artifactId"), "different"),
            (("sourceArtifact", "componentSHA256"), "0" * 64),
            (("tuple", "app", "version"), "0.2.0"),
            (("tuple", "component", "identifier"), "com.example.tool"),
            (("tuple", "component", "machoUUID"), "0" * 36),
            (("tuple", "component", "unsignedSHA256"), "0" * 64),
            (("tuple", "metadata", "sbom.spdx.json"), "0" * 64),
            (("tuple", "metadata", "THIRD-PARTY-NOTICES.txt"), "0" * 64),
            (("tuple", "metadata", "source-distribution-manifest.json"), "0" * 64),
            (("tuple", "dmg", "name"), "other.dmg"),
            (("tuple", "notarySubmissionId"), ""),
            (("tupleSHA256",), "0" * 64),
            (("effectCounters", "componentLaunch"), 1),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                self.assert_mutation_fails(
                    lambda facts: package.validate_receipt(facts, self.spec),
                    self.valid_receipt(),
                    path,
                    value,
                )


class NotaryLogSanitizationTests(ContractFixture):
    def test_notary_log_projection_omits_ticket_and_sanitizes_paths(self) -> None:
        raw = {
            "logFormatVersion": 1,
            "jobId": "11111111-2222-3333-4444-555555555555",
            "status": "Accepted",
            "statusSummary": "Ready for distribution",
            "statusCode": 0,
            "archiveFilename": "/Users/example/private/ArkDeck.dmg",
            "uploadDate": "2026-07-29T00:00:00Z",
            "sha256": "a" * 64,
            "ticketContents": ["secret-ticket-body"],
            "issues": [],
        }
        sanitized = package.sanitize_notary_log(
            raw,
            "11111111-2222-3333-4444-555555555555",
            package.Runner({}),
        )
        serialized = json.dumps(sanitized, sort_keys=True)
        self.assertNotIn("ticketContents", serialized)
        self.assertNotIn("secret-ticket-body", serialized)
        self.assertNotIn("/Users/", serialized)
        self.assertEqual(sanitized["status"], "Accepted")
        self.assertEqual(sanitized["issueCount"], 0)


if __name__ == "__main__":
    unittest.main()
