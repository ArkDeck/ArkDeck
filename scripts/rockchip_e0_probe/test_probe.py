import importlib.util
import json
import pathlib
import re
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
        self.assertEqual(PROBE.EXACT_ARGUMENTS, ["ld"])
        self.assertNotIn("sudo", PROBE.EXACT_ARGUMENTS)
        self.assertNotIn("sh", PROBE.EXACT_ARGUMENTS)
        self.assertEqual(len(PROBE.EXPECTED_ENTITLEMENTS), 6)
        self.assertTrue(PROBE.EXPECTED_ENTITLEMENTS["com.apple.security.app-sandbox"])
        self.assertTrue(PROBE.EXPECTED_ENTITLEMENTS["com.apple.security.device.usb"])
        self.assertEqual(
            PROBE.classify_preflight_failure("quarantinePresent"),
            {"verdict": "toolBlocked", "diagnostic": "quarantinePresent", "observations": []},
        )
        for failure in (
            "securityScopedBookmarkStale",
            "securityScopedBookmarkPathMismatch",
            "bookmarkCreationOrResolutionFailed",
        ):
            with self.subTest(failure=failure):
                self.assertEqual(
                    PROBE.classify_preflight_failure(failure),
                    {"verdict": "toolBlocked", "diagnostic": failure, "observations": []},
                )

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
        self.assertEqual(dictionary_key_paths(receipt), dictionary_key_paths(committed))
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
