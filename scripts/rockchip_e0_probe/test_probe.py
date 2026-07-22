import importlib.util
import pathlib
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
        self.assertEqual(
            PROBE.classify_preflight_failure("securityScopedBookmarkStale")["verdict"],
            "permissionDenied",
        )


if __name__ == "__main__":
    unittest.main()
