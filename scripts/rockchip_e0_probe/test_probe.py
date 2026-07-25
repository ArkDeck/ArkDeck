import importlib.util
import json
import pathlib
import plistlib
import re
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rockchip_e0_probe", ROOT / "probe.py")
assert SPEC and SPEC.loader
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
FIXTURES = (
    ROOT.parent.parent
    / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/Discovery/1.0.0"
)
COMMITTED_RECEIPT = (
    ROOT.parent.parent
    / "openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/"
    "TASK-RKFUI-001/sanitized-e0-receipt.json"
)
SWIFT_DISCOVERY = (
    ROOT.parent.parent
    / "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift"
)
CANONICAL_REGISTRY_ROOT = (
    ROOT.parent.parent / "openspec/integrations/rockchip/rockusb-discovery/1.0.0"
)


def dictionary_key_paths(value: object, prefix: str = "") -> set[str]:
    paths: set[str] = set()
    if not isinstance(value, dict):
        return paths
    for key, nested in value.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        paths.add(path)
        paths.update(dictionary_key_paths(nested, path))
    return paths


def swift_string_enum_raw_values(enum_name: str) -> set[str]:
    source = SWIFT_DISCOVERY.read_text(encoding="utf-8")
    match = re.search(
        rf"public enum {re.escape(enum_name)}: String,.*?\{{(?P<body>.*?)\n\}}",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing Swift enum {enum_name}")
    return set(re.findall(r"^\s*case\s+([A-Za-z][A-Za-z0-9]*)\s*$", match["body"], re.MULTILINE))


class RockchipE0ProbeTests(unittest.TestCase):
    def fixture(self, name: str) -> bytes:
        return (FIXTURES / name).read_bytes()

    def test_bundled_registry_copies_match_canonical_openspec(self) -> None:
        # The Swift contract suite reads only Bundle.module copies of these files;
        # this assertion is what keeps those copies byte-identical to the canonical
        # openspec registry, so a drifted copy fails here instead of passing silently.
        for name in ("registry.yaml", "resources.json"):
            with self.subTest(name=name):
                self.assertEqual(
                    (FIXTURES / name).read_bytes(),
                    (CANONICAL_REGISTRY_ROOT / name).read_bytes(),
                )

    def test_strict_success_and_multi(self) -> None:
        single = PROBE.parse_ld(
            self.fixture("success-single-loader.stdout.bin"), b"", "exited", 0
        )
        self.assertEqual(single["verdict"], "accessible")
        self.assertEqual(len(single["observations"]), 1)
        self.assertNotIn("locationID", single["observations"][0])
        self.assertEqual(len(single["observations"][0]["locationIDSummary"]), 12)
        multi = PROBE.parse_ld(
            self.fixture("success-multi-device.stdout.bin"), b"", "exited", 0
        )
        self.assertEqual(multi["verdict"], "accessible")
        self.assertEqual(len(multi["observations"]), 2)

    def test_fault_and_access_classification(self) -> None:
        cases = {
            "malformed-missing-tab.stdout.bin": "malformedOutput",
            "duplicate-device-number.stdout.bin": "malformedOutput",
            "duplicate-location.stdout.bin": "malformedOutput",
            "unknown-mode.stdout.bin": "malformedOutput",
            "maskrom.stdout.bin": "protocolBlocked",
            "similar-family.stdout.bin": "protocolBlocked",
        }
        for name, verdict in cases.items():
            with self.subTest(name=name):
                self.assertEqual(PROBE.parse_ld(self.fixture(name), b"", "exited", 0)["verdict"], verdict)
        self.assertEqual(PROBE.parse_ld(b"", b"", "exited", 0)["verdict"], "offlineOrUnauthorized")
        self.assertEqual(
            PROBE.parse_ld(b"", self.fixture("permission-denied.stderr.bin"), "exited", 1)["verdict"],
            "permissionDenied",
        )
        self.assertEqual(
            PROBE.parse_ld(b"", self.fixture("driver-unavailable.stderr.bin"), "exited", 1)["verdict"],
            "driverUnavailable",
        )
        carriage_return = self.fixture("success-single-loader.stdout.bin").replace(b"\n", b"\r\n")
        self.assertEqual(
            PROBE.parse_ld(carriage_return, b"", "exited", 0),
            {
                "verdict": "malformedOutput",
                "diagnostic": "unexpectedCarriageReturn",
                "observations": [],
            },
        )

    def test_combined_standard_output_and_error_must_fit_maximum_output_bytes(self) -> None:
        stdout = b"A" * (63 * 1_024)
        stderr = b"B" * (2 * 1_024)
        self.assertLess(len(stdout), 65_536)
        self.assertLess(len(stderr), 65_536)
        self.assertEqual(
            PROBE.parse_ld(stdout, stderr, "exited", 0),
            {"verdict": "malformedOutput", "diagnostic": "outputTooLarge", "observations": []},
        )

    def test_closed_command_and_entitlements(self) -> None:
        self.assertEqual(
            PROBE.PINNED_TOOL_SHA256,
            "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923",
        )
        self.assertNotEqual(
            PROBE.PINNED_TOOL_SHA256,
            "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611",
        )
        self.assertEqual(PROBE.EXACT_ARGUMENTS, ["ld"])
        self.assertNotIn("sudo", PROBE.EXACT_ARGUMENTS)
        self.assertNotIn("sh", PROBE.EXACT_ARGUMENTS)
        self.assertEqual(
            PROBE.EXPECTED_ENTITLEMENTS,
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.device.serial": True,
                "com.apple.security.device.usb": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.files.user-selected.read-only": True,
                "com.apple.security.network.client": True,
            },
        )
        self.assertTrue(
            PROBE.FORBIDDEN_ENTITLEMENTS.isdisjoint(PROBE.EXPECTED_ENTITLEMENTS)
        )
        entitlement_document = plistlib.loads((ROOT / "Probe.entitlements").read_bytes())
        self.assertEqual(entitlement_document, PROBE.EXPECTED_ENTITLEMENTS)
        self.assertTrue(
            PROBE.FORBIDDEN_ENTITLEMENTS.isdisjoint(entitlement_document)
        )
        self.assertEqual(
            PROBE.classify_preflight_failure("quarantinePresent"),
            {"verdict": "toolBlocked", "diagnostic": "quarantinePresent", "observations": []},
        )
        for failure in (
            "securityScopedBookmarkStale",
            "securityScopedBookmarkPathMismatch",
            "bookmarkCreationFailed",
            "bookmarkResolutionFailed",
            "executableInspectionFailed",
        ):
            with self.subTest(failure=failure):
                self.assertEqual(
                    PROBE.classify_preflight_failure(failure),
                    {"verdict": "toolBlocked", "diagnostic": failure, "observations": []},
                )

    def test_bookmark_options_and_sanitized_failure_contract_are_exact(self) -> None:
        self.assertEqual(
            PROBE.BOOKMARK_CREATION_OPTIONS,
            ["withSecurityScope", "securityScopeAllowOnlyReadAccess"],
        )
        self.assertEqual(
            PROBE.BOOKMARK_RESOLUTION_OPTIONS,
            ["withSecurityScope", "withoutUI"],
        )
        swift_source = (ROOT / "RockchipE0ProbeApp.swift").read_text(encoding="utf-8")
        self.assertRegex(
            swift_source,
            r"bookmarkCreationOptions: URL\.BookmarkCreationOptions = \[\s*"
            r"\.withSecurityScope, \.securityScopeAllowOnlyReadAccess,\s*\]",
        )
        self.assertRegex(
            swift_source,
            r"bookmarkResolutionOptions: URL\.BookmarkResolutionOptions = \[\s*"
            r"\.withSecurityScope, \.withoutUI,\s*\]",
        )
        self.assertNotIn("bookmarkCreationOrResolutionFailed", swift_source)
        self.assertNotIn("localizedDescription", swift_source)
        self.assertNotIn("bookmarkDataBase64", swift_source)
        self.assertNotIn(".withoutImplicitSecurityScope", swift_source)
        self.assertNotIn(".minimalBookmark", swift_source)
        self.assertNotIn(".suitableForBookmarkFile", swift_source)
        self.assertGreaterEqual(swift_source.count("relativeTo: nil"), 2)
        for stage in ("bookmarkCreationFailed", "bookmarkResolutionFailed"):
            observation = PROBE._sanitized_bookmark_observation(
                {
                    "bookmarkCreated": False,
                    "preflightFailure": stage,
                    "launchErrorDomain": "NSCocoaErrorDomain",
                    "launchErrorCode": 256,
                    "localizedDescription": "/private/tmp/forbidden",
                    "selectedPath": "/private/tmp/forbidden",
                    "bookmarkDataBase64": "forbidden",
                }
            )
            self.assertEqual(
                set(observation),
                {
                    "creationOptions",
                    "resolutionOptions",
                    "created",
                    "failureStage",
                    "errorDomain",
                    "errorCode",
                },
            )
            self.assertEqual(observation["failureStage"], stage)
            self.assertEqual(observation["errorDomain"], "NSCocoaErrorDomain")
            self.assertEqual(observation["errorCode"], 256)
            self.assertNotIn("forbidden", json.dumps(observation))
        non_bookmark = PROBE._sanitized_bookmark_observation(
            {
                "bookmarkCreated": True,
                "preflightFailure": "executableHashMismatch",
                "launchErrorDomain": "forbidden",
                "launchErrorCode": 999,
            }
        )
        self.assertIsNone(non_bookmark["failureStage"])
        self.assertIsNone(non_bookmark["errorDomain"])
        self.assertIsNone(non_bookmark["errorCode"])

    def test_info_plist_has_no_quarantine_override(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as root:
            path = pathlib.Path(root) / "Info.plist"
            PROBE._make_info_plist(path)
            document = plistlib.loads(path.read_bytes())
        self.assertTrue(PROBE.FORBIDDEN_INFO_PLIST_KEYS.isdisjoint(document))

    def test_selector_lexical_policy_only_gates_canonical_entry(self) -> None:
        self.assertTrue(
            PROBE._selector_entry_policy_satisfied("canonicalDirect", True)
        )
        self.assertFalse(
            PROBE._selector_entry_policy_satisfied("canonicalDirect", False)
        )
        self.assertTrue(
            PROBE._selector_entry_policy_satisfied("singleLayerSymlink", False)
        )

    def test_characterization_dispatch_surface_is_structurally_closed(self) -> None:
        self.assertEqual(
            set(PROBE.CHARACTERIZATION_DISPATCH_COUNTERS),
            {
                "selectedProcess",
                "ldReadOnly",
                "usb",
                "network",
                "hdc",
                "device",
                "deviceMutation",
                "destructive",
                "sudoOrPrivilegeElevation",
                "helper",
                "driverInstall",
                "systemRuleMutation",
                "groupMutation",
                "aclMutation",
                "xattrWrite",
            },
        )
        self.assertEqual(
            set(PROBE.CHARACTERIZATION_DISPATCH_COUNTERS.values()), {0}
        )
        source = (ROOT / "CharacterizationFixture.c").read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"\b(?:exec|fork|system)\s*\(", source))

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign toolchain")
    def test_characterization_fixture_build_is_deterministic_and_unpinned(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as parent:
            first = pathlib.Path(parent) / "first"
            second = pathlib.Path(parent) / "second"
            first_receipt = PROBE.build_characterization_fixture(first)
            second_receipt = PROBE.build_characterization_fixture(second)
        self.assertEqual(
            first_receipt["target"]["sha256"], second_receipt["target"]["sha256"]
        )
        self.assertNotEqual(
            first_receipt["target"]["sha256"], PROBE.PINNED_TOOL_SHA256
        )
        self.assertEqual(first_receipt["target"]["codeTrust"], "adHoc")
        self.assertFalse(first_receipt["target"]["quarantinePresent"])
        self.assertTrue(first_receipt["selector"]["isSymlink"])
        self.assertEqual(first_receipt["selector"]["symlinkDepth"], 1)
        self.assertFalse(first_receipt["fixtureExecuted"])

    def test_sanitized_receipt_schema_matches_committed_evidence(self) -> None:
        envelope = {
            "bookmarkCreated": True,
            "securityScopeStarted": True,
            "preflightFailure": "quarantinePresent",
            "childLaunchAttempted": False,
            "termination": None,
            "exitCode": None,
        }
        parsed = PROBE.classify_preflight_failure(envelope["preflightFailure"])
        receipt = PROBE.build_sanitized_receipt(
            envelope=envelope,
            captured_at="2026-07-22T06:20:49Z",
            executor="agent",
            app_executable_sha256="a" * 64,
            entitlements=PROBE.EXPECTED_ENTITLEMENTS,
            build_receipt={
                "signatureClass": "adHoc",
                "developerIDIdentityAvailableAtBuild": False,
                "hardenedRuntime": True,
            },
            selected_basename="rkdeveloptool",
            tool_hash=PROBE.PINNED_TOOL_SHA256,
            trust={
                "codeTrust": "adHoc",
                "signatureIntegrityCheckExit": 0,
                "quarantinePresent": True,
                "gatekeeperAssessmentExit": 3,
                "gatekeeperAssessmentSummary": "rejected",
            },
            stdout=b"",
            stderr=b"",
            parsed=parsed,
            execute_readiness_passed=False,
        )
        committed = json.loads(COMMITTED_RECEIPT.read_text(encoding="utf-8"))
        current_schema = {
            path
            for path in dictionary_key_paths(receipt)
            if not path.startswith("app.entitlements.")
        }
        historical_schema = {
            path
            for path in dictionary_key_paths(committed)
            if not path.startswith("app.entitlements.")
        }
        self.assertEqual(current_schema, historical_schema)
        self.assertIn(
            "com.apple.security.files.user-selected.read-write",
            committed["app"]["entitlements"],
        )
        self.assertNotIn(
            "com.apple.security.files.user-selected.read-only",
            committed["app"]["entitlements"],
        )
        self.assertIn(
            "com.apple.security.files.user-selected.read-only",
            receipt["app"]["entitlements"],
        )
        self.assertNotIn(
            "com.apple.security.files.user-selected.read-write",
            receipt["app"]["entitlements"],
        )
        self.assertNotIn("rawArtifacts", receipt)
        self.assertEqual(
            receipt["privacy"]["rawArtifacts"], "emptyBecauseChildLaunchWasBlocked"
        )
        responsibilities = swift_string_enum_raw_values("RockchipDeviceAccessResponsibility")
        remediations = swift_string_enum_raw_values("RockchipDeviceAccessRemediation")
        self.assertEqual(
            set(PROBE.SWIFT_DEVICE_ACCESS_RESPONSIBILITY_RAW_VALUES), responsibilities
        )
        self.assertEqual(set(PROBE.SWIFT_DEVICE_ACCESS_REMEDIATION_RAW_VALUES), remediations)
        self.assertIn(receipt["deviceAccessAdvisor"]["responsibility"], responsibilities)
        self.assertIn(receipt["deviceAccessAdvisor"]["remediation"], remediations)
        self.assertEqual(
            receipt["deviceAccessAdvisor"]["remediation"], "selectPinnedUserApprovedTool"
        )


if __name__ == "__main__":
    unittest.main()
