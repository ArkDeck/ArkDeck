"""Host-only tests for the one-run TASK-RKFUI-001A E1 harness."""

from __future__ import annotations

import ast
import datetime as dt
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("probe.py")
REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
DISCOVERY_FIXTURES = (
    REPOSITORY_ROOT
    / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/Discovery/1.0.0"
)
SPEC = importlib.util.spec_from_file_location("_rkfui001a_probe", MODULE_PATH)
probe = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = probe
SPEC.loader.exec_module(probe)

# Deliberately synthetic: real device connect keys never enter repository fixtures.
CONNECT_KEY = "0123456789abcdef0123456789abcdef"
SERIAL_SHA256 = probe.sha256_bytes(CONNECT_KEY.encode("ascii"))
PINNED_SERIAL_SHA256 = (
    "958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e"
)
FIRMWARE = "OpenHarmony 7.0.0.33"
HDC_VERSION = "Ver: 3.2.0f"
HDC_SHA256 = "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
OLD_HDC_VERSION = "Ver: 3.2.0d"
OLD_HDC_SHA256 = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260"
R5_AUTHORIZATION_REF = "PR#481@0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07"
LOADER_LINE = b"DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=2\tLoader\n"


class FakeRunner:
    def __init__(
        self,
        *,
        firmware: str = FIRMWARE,
        hdc_version: str = HDC_VERSION,
        targets: bytes | None = None,
        post_targets: bytes = b"",
        pre_ld: bytes = b"",
        post_ld: bytes = LOADER_LINE,
        e1_exit: int = 0,
        e1_stderr: bytes = b"",
    ):
        self.firmware = firmware
        self.hdc_version = hdc_version
        self.targets = targets or f"{CONNECT_KEY}\n".encode("ascii")
        self.post_targets = post_targets
        self.pre_ld = pre_ld
        self.post_ld = post_ld
        self.e1_exit = e1_exit
        self.e1_stderr = e1_stderr
        self.calls: list[list[str]] = []
        self.target_list_calls = 0
        self.ld_calls = 0

    def __call__(self, argv, timeout_ms, cwd):
        self.calls.append(list(argv))
        if argv[-1:] == ["-v"] and pathlib.Path(argv[0]).name == "hdc":
            return result((self.hdc_version + "\n").encode("utf-8"))
        if argv[-1:] == ["checkserver"]:
            return result(
                (
                    f"server version: {self.hdc_version} "
                    f"daemon version: {self.hdc_version}\n"
                ).encode("utf-8")
            )
        if argv[-2:] == ["list", "targets"]:
            self.target_list_calls += 1
            stdout = self.targets if self.target_list_calls <= 2 else self.post_targets
            return result(stdout)
        if argv[-3:] == ["param", "get", "const.product.software.version"]:
            return result((self.firmware + "\n").encode("utf-8"))
        if pathlib.Path(argv[0]).name == "rkdeveloptool" and argv[-1:] == ["-v"]:
            return result(b"rkdeveloptool ver 1.32\n")
        if argv[:2] == ["/usr/bin/git", "-C"]:
            return result(b"304f073752fd25c854e1bcf05d8e7f925b1f4e14\n")
        if argv[:3] == ["/usr/bin/codesign", "-dv", "--verbose=4"]:
            return result(stderr=b"Signature=adhoc\n")
        if argv[:3] == ["/usr/bin/xattr", "-p", "com.apple.quarantine"]:
            return result(stderr=b"No such xattr: com.apple.quarantine\n", exit_code=1)
        if pathlib.Path(argv[0]).name == "rkdeveloptool" and argv[-1:] == ["ld"]:
            self.ld_calls += 1
            return result(self.pre_ld if self.ld_calls == 1 else self.post_ld)
        if argv[-5:] == ["-t", CONNECT_KEY, "shell", "reboot", "loader"]:
            return result(exit_code=self.e1_exit, stderr=self.e1_stderr)
        raise AssertionError(f"unexpected argv: {argv}")


def result(
    stdout: bytes = b"",
    *,
    stderr: bytes = b"",
    exit_code: int = 0,
    timed_out: bool = False,
) -> probe.CommandResult:
    return probe.CommandResult(
        exit_code=None if timed_out else exit_code,
        timed_out=timed_out,
        stdout=stdout,
        stderr=stderr,
        duration_ms=1,
    )


def fake_server(_):
    return {
        "pid": 50752,
        "parentPID": 1,
        "sameUIDAsExecutor": True,
        "ownership": "preExistingExternalSameUIDPinnedExecutable",
        "executableMatchedClient": True,
        "serverLifecycleMutationCount": 0,
    }


def fake_usb_reader(timeout_ms, cwd):
    return result(b'{"SPUSBDataType":[]}\n')


class HarnessCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.hdc = self.root / "hdc"
        self.rk = self.root / "rkdeveloptool"
        self.hdc.write_bytes(b"fake pinned hdc")
        self.rk.write_bytes(b"fake pinned rkdeveloptool")
        self.hdc.chmod(0o755)
        self.rk.chmod(0o755)
        self.state = self.root / "controlled-state"

    def tearDown(self):
        self.temp.cleanup()

    def config(self, *, valid_until: dt.datetime | None = None):
        return probe.Config(
            repo_root=self.root,
            state_root=self.state,
            hdc_path=self.hdc,
            rkdeveloptool_path=self.rk,
            authorization_refs=(
                "PR#440@f4e901492e7d3b82f883424c756868fffa4946df",
                "PR#452@d22cdeeebc781b9c3a1b063dbee6631934c51ac0",
                R5_AUTHORIZATION_REF,
            ),
            valid_until=valid_until or dt.datetime(2030, 1, 1, tzinfo=dt.timezone.utc),
            max_runs=1,
            target_model="DAYU200",
            target_soc="RK3568",
            serial_sha256=SERIAL_SHA256,
            firmware=FIRMWARE,
            transport="usb",
            binding_revision=1,
            hdc_version=HDC_VERSION,
            hdc_sha256=probe.sha256_file(self.hdc),
            rkdeveloptool_version="rkdeveloptool ver 1.32",
            rkdeveloptool_sha256=probe.sha256_file(self.rk),
            rkdeveloptool_upstream_commit="304f073752fd25c854e1bcf05d8e7f925b1f4e14",
            e1_arguments_template=(
                "-t",
                "<durable-connect-key>",
                "shell",
                "reboot",
                "loader",
            ),
            firmware_arguments_template=(
                "-t",
                "<durable-connect-key>",
                "shell",
                "param",
                "get",
                "const.product.software.version",
            ),
            impact_confirmation_token="ENTER-LOADER-WILL-DISCONNECT-HDC",
            command_timeout_ms=10_000,
            disconnect_deadline_ms=1_000,
            loader_deadline_ms=1_000,
            poll_interval_ms=1,
            maximum_output_bytes=65_536,
        )

    def run_workflow(self, fake: FakeRunner, *, config=None, confirmation=None):
        fixed_now = lambda: dt.datetime(2026, 7, 24, 3, 30, tzinfo=dt.timezone.utc)
        clock = [0.0]

        def monotonic():
            clock[0] += 0.25
            return clock[0]

        return probe.characterize(
            config or self.config(),
            impact_confirmation=confirmation
            or "ENTER-LOADER-WILL-DISCONNECT-HDC",
            runner=fake,
            server_inspector=fake_server,
            usb_reader=fake_usb_reader,
            now=fixed_now,
            monotonic=monotonic,
            sleeper=lambda _: None,
        )


class RegistryAndArgvTests(HarnessCase):
    def test_registry_closure_pins_exact_authority_target_and_commands(self):
        registry = json.loads(
            (
                pathlib.Path(__file__).resolve().parents[2]
                / probe.REGISTRY_RELATIVE_PATH
            ).read_text()
        )
        self.assertEqual(registry["characterizationStatus"], "pending")
        self.assertEqual(registry["authorization"]["maxRuns"], 1)
        self.assertEqual(registry["target"]["firmware"], FIRMWARE)
        self.assertEqual(registry["target"]["serialSHA256"], PINNED_SERIAL_SHA256)
        self.assertEqual(
            registry["authorization"]["refs"],
            [
                "PR#440@f4e901492e7d3b82f883424c756868fffa4946df",
                "PR#452@d22cdeeebc781b9c3a1b063dbee6631934c51ac0",
                R5_AUTHORIZATION_REF,
            ],
        )
        self.assertEqual(registry["hdc"], probe.EXPECTED_HDC)
        self.assertEqual(registry["hdc"]["reportedVersion"], HDC_VERSION)
        self.assertEqual(registry["hdc"]["sha256"], HDC_SHA256)
        self.assertEqual(
            registry["operation"]["exactArgvTemplate"],
            ["-t", "<durable-connect-key>", "shell", "reboot", "loader"],
        )
        self.assertEqual(registry["rockUSBObservation"]["exactArgv"], ["ld"])
        self.assertIn("destructive", registry["operation"]["forbiddenEffects"])
        self.assertIn("retry", registry["operation"]["forbiddenEffects"])

    def test_registry_rejects_each_old_hdc_pin_without_dual_pin_fallback(self):
        registry = json.loads(
            (
                pathlib.Path(__file__).resolve().parents[2]
                / probe.REGISTRY_RELATIVE_PATH
            ).read_text()
        )
        for field, old_value in (
            ("reportedVersion", OLD_HDC_VERSION),
            ("sha256", OLD_HDC_SHA256),
        ):
            with self.subTest(field=field):
                drifted = json.loads(json.dumps(registry))
                drifted["hdc"][field] = old_value
                repo_root = self.root / field
                registry_path = repo_root / probe.REGISTRY_RELATIVE_PATH
                registry_path.parent.mkdir(parents=True)
                registry_path.write_text(json.dumps(drifted), encoding="utf-8")
                with self.assertRaisesRegex(
                    probe.ProbeError,
                    "loader-transition HDC exact pin or server policy drifted",
                ):
                    probe.load_config(
                        self.rk,
                        repo_root=repo_root,
                        state_root=self.root / f"{field}-state",
                    )

    def test_materializers_are_closed_and_targeted(self):
        config = self.config()
        self.assertEqual(
            config.materialize_e1(CONNECT_KEY),
            [str(self.hdc), "-t", CONNECT_KEY, "shell", "reboot", "loader"],
        )
        self.assertEqual(
            config.materialize_firmware_readback(CONNECT_KEY),
            [
                str(self.hdc),
                "-t",
                CONNECT_KEY,
                "shell",
                "param",
                "get",
                "const.product.software.version",
            ],
        )

    def test_cli_exposes_no_target_hdc_command_or_retry_argument(self):
        parser = probe.build_parser()
        option_strings = {
            option
            for action in parser._subparsers._group_actions[0].choices[
                "characterize"
            ]._actions
            for option in action.option_strings
        }
        self.assertEqual(
            option_strings,
            {"-h", "--help", "--rkdeveloptool", "--impact-confirmation"},
        )

    def test_source_never_enables_host_shell(self):
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                for keyword in node.keywords:
                    if keyword.arg == "shell":
                        self.assertFalse(
                            isinstance(keyword.value, ast.Constant)
                            and keyword.value.value is True
                        )

    def test_subprocess_capture_applies_one_combined_output_limit(self):
        command = [
            sys.executable,
            "-c",
            "import sys;sys.stdout.buffer.write(b'a'*65536);sys.stderr.buffer.write(b'b'*65536)",
        ]
        observed = probe.subprocess_runner(command, 5_000, self.root)
        self.assertTrue(observed.output_truncated)
        self.assertEqual(len(observed.stdout) + len(observed.stderr), probe.MAX_RAW_BYTES)


class ParserTests(HarnessCase):
    def test_hdc_target_requires_exact_single_digest(self):
        command = result(f"{CONNECT_KEY}\n".encode())
        targets = probe.parse_hdc_targets(command.stdout, command.stderr, command)
        self.assertEqual(probe.require_exact_target(targets, SERIAL_SHA256), CONNECT_KEY.encode())
        with self.assertRaises(probe.ProbeError):
            probe.require_exact_target(targets + [b"deadbeefdeadbeef"], SERIAL_SHA256)

    def test_hdc_target_rejects_unknown_line_and_duplicate(self):
        unknown = result(b"status words are not a connect key\n")
        with self.assertRaises(probe.ProbeError):
            probe.parse_hdc_targets(unknown.stdout, unknown.stderr, unknown)
        duplicate = result(f"{CONNECT_KEY}\n{CONNECT_KEY}\n".encode())
        with self.assertRaises(probe.ProbeError):
            probe.parse_hdc_targets(duplicate.stdout, duplicate.stderr, duplicate)

    def test_firmware_is_exact_not_substring(self):
        self.assertEqual(probe.parse_firmware(result((FIRMWARE + "\n").encode()), FIRMWARE), FIRMWARE)
        with self.assertRaises(probe.ProbeError):
            probe.parse_firmware(result(b"OpenHarmony 7.0.0.34\n"), FIRMWARE)

    def test_ld_accepts_only_exact_loader_semantics(self):
        loader_lf = probe.parse_ld(
            result((DISCOVERY_FIXTURES / "success-single-loader.stdout.bin").read_bytes())
        )
        loader_crlf = probe.parse_ld(
            result((DISCOVERY_FIXTURES / "success-single-loader-crlf.stdout.bin").read_bytes())
        )
        self.assertEqual(loader_lf["status"], "observations")
        self.assertEqual(loader_crlf, loader_lf)
        self.assertEqual(len(loader_lf["observations"]), 1)
        self.assertTrue(loader_lf["observations"][0]["isExpectedLoader"])

        self.assertEqual(
            probe.parse_ld(
                result((DISCOVERY_FIXTURES / "success-multi-device-crlf.stdout.bin").read_bytes())
            ),
            probe.parse_ld(
                result((DISCOVERY_FIXTURES / "success-multi-device.stdout.bin").read_bytes())
            ),
        )

        maskrom_crlf = probe.parse_ld(
            result((DISCOVERY_FIXTURES / "maskrom-crlf.stdout.bin").read_bytes())
        )
        self.assertEqual(maskrom_crlf["status"], "observations")
        self.assertEqual(len(maskrom_crlf["observations"]), 1)
        self.assertFalse(maskrom_crlf["observations"][0]["isExpectedLoader"])

    def test_ld_line_termination_faults_fail_closed(self):
        cases = {
            "bare-carriage-return.stdout.bin": "unexpectedCarriageReturn",
            "mixed-line-terminators.stdout.bin": "mixedLineTerminators",
            "missing-final-terminator.stdout.bin": "missingFinalLineTerminator",
            "empty-record.stdout.bin": "emptyLine:2",
        }
        for fixture_name, expected_reason in cases.items():
            with self.subTest(reason=expected_reason):
                parsed = probe.parse_ld(
                    result((DISCOVERY_FIXTURES / fixture_name).read_bytes())
                )
                self.assertEqual(parsed["status"], "blocked")
                self.assertEqual(parsed["reason"], expected_reason)
                self.assertEqual(parsed["observations"], [])
        crlf_then_missing_final = (
            (DISCOVERY_FIXTURES / "success-single-loader-crlf.stdout.bin").read_bytes()
            + b"DevNo=2\tVid=0x2207,Pid=0x350a,LocationID=5\tLoader"
        )
        self.assertEqual(
            probe.parse_ld(result(crlf_then_missing_final))["reason"],
            "missingFinalLineTerminator",
        )

    def test_ld_malformed_multi_and_stderr_fail_closed(self):
        self.assertEqual(probe.parse_ld(result(b"garbage\n"))["status"], "blocked")
        multi = probe.parse_ld(result(LOADER_LINE + LOADER_LINE.replace(b"DevNo=1", b"DevNo=2")))
        self.assertEqual(multi["status"], "blocked")
        self.assertEqual(
            probe.parse_ld(result(stderr=b"permission denied"))["reason"],
            "permissionDenied",
        )


class ServerInspectionTests(HarnessCase):
    def test_server_inspection_requires_same_uid_and_pinned_executable(self):
        def runner(argv, timeout_ms, cwd):
            if argv[0] == "/usr/sbin/lsof" and "-iTCP:8710" in argv:
                return result(f"p50752\nu{os.getuid()}\n".encode())
            if argv[0] == "/bin/ps" and argv[1:3] == ["-p", "50752"]:
                return result(
                    f"50752 1 {os.getuid()} hdc -m -s ::ffff:127.0.0.1:8710\n".encode()
                )
            if argv[0] == "/usr/sbin/lsof" and "-d" in argv:
                return result(f"p50752\nn{self.hdc}\n".encode())
            raise AssertionError(argv)

        inspected = probe.inspect_hdc_server(self.hdc, command_runner=runner)
        self.assertEqual(
            inspected["ownership"], "preExistingExternalSameUIDPinnedExecutable"
        )
        self.assertEqual(inspected["serverLifecycleMutationCount"], 0)

    def test_server_inspection_blocks_zero_or_multiple_servers(self):
        def runner(argv, timeout_ms, cwd):
            return result(b"")

        with self.assertRaises(probe.ProbeError):
            probe.inspect_hdc_server(self.hdc, command_runner=runner)

        def multiple(argv, timeout_ms, cwd):
            if argv[0] == "/usr/sbin/lsof" and "-iTCP:8710" in argv:
                return result(
                    f"p50752\nu{os.getuid()}\np50753\nu{os.getuid()}\n".encode()
                )
            raise AssertionError(argv)

        with self.assertRaises(probe.ProbeError):
            probe.inspect_hdc_server(self.hdc, command_runner=multiple)


class WorkflowTests(HarnessCase):
    def test_supported_run_is_one_e1_and_zero_destructive(self):
        fake = FakeRunner()
        exit_code, receipt, receipt_path = self.run_workflow(fake)
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt["capabilityVerdict"], "supported")
        self.assertEqual(receipt["autoRebindVerdict"], "manualConfirmationRequired")
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 1)
        self.assertEqual(receipt["counters"]["rebootLoader"], 1)
        self.assertEqual(receipt["counters"]["e2Destructive"], 0)
        e1_calls = [
            argv
            for argv in fake.calls
            if argv[-5:] == ["-t", CONNECT_KEY, "shell", "reboot", "loader"]
        ]
        self.assertEqual(len(e1_calls), 1)
        self.assertTrue(receipt_path.exists())

    def test_binding_intent_and_usage_are_durable_and_receipt_is_redacted(self):
        fake = FakeRunner()
        _, receipt, receipt_path = self.run_workflow(fake)
        run_dir = receipt_path.parent
        self.assertTrue((run_dir / "original-target.json").exists())
        binding = json.loads((run_dir / "current-binding-r1.json").read_text())
        self.assertEqual(binding["revision"], 1)
        intent = json.loads((run_dir / "enter-updater-intent.json").read_text())
        self.assertEqual(intent["bindingRevision"], 1)
        self.assertEqual(intent["attempt"], 1)
        usage = json.loads((self.state / "usage.json").read_text())
        self.assertEqual(usage["state"], "consumedNoRetry")
        sanitized = receipt_path.read_text()
        self.assertNotIn(CONNECT_KEY, sanitized)
        self.assertIn(SERIAL_SHA256, sanitized)
        self.assertTrue(receipt["durability"]["intentPrecededDispatch"])

    def test_firmware_mismatch_blocks_before_usage_and_e1(self):
        fake = FakeRunner(firmware="OpenHarmony 7.0.0.34")
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 0)
        self.assertFalse((self.state / "usage.json").exists())
        self.assertFalse(
            any(argv[-2:] == ["reboot", "loader"] for argv in fake.calls)
        )

    def test_old_hdc_version_blocks_before_usage_and_e1(self):
        fake = FakeRunner(hdc_version=OLD_HDC_VERSION)
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 0)
        self.assertFalse((self.state / "usage.json").exists())
        self.assertFalse(
            any(argv[-2:] == ["reboot", "loader"] for argv in fake.calls)
        )

    def test_multiple_target_blocks_before_usage_and_e1(self):
        fake = FakeRunner(
            targets=f"{CONNECT_KEY}\ndeadbeefdeadbeefdeadbeefdeadbeef\n".encode()
        )
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 0)
        self.assertFalse((self.state / "usage.json").exists())

    def test_existing_rockusb_candidate_blocks_before_e1(self):
        fake = FakeRunner(pre_ld=LOADER_LINE)
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 0)
        self.assertFalse((self.state / "usage.json").exists())

    def test_existing_usage_blocks_second_run(self):
        self.state.mkdir(parents=True)
        (self.state / "usage.json").write_text('{"state":"consumedNoRetry"}\n')
        fake = FakeRunner()
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 0)
        self.assertEqual(fake.calls, [])

    def test_bad_confirmation_and_expired_window_block_before_state(self):
        with self.assertRaises(probe.ProbeError):
            self.run_workflow(FakeRunner(), confirmation="YES")
        expired = self.config(
            valid_until=dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)
        )
        with self.assertRaises(probe.ProbeError):
            self.run_workflow(FakeRunner(), config=expired)
        self.assertFalse(self.state.exists())

    def test_nonzero_hdc_receipt_never_claims_supported(self):
        fake = FakeRunner(e1_exit=1)
        exit_code, receipt, _ = self.run_workflow(fake)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["capabilityVerdict"], "unknown")
        self.assertEqual(receipt["counters"]["e1DeviceMutation"], 1)
        self.assertEqual(json.loads((self.state / "usage.json").read_text())["state"], "consumedNoRetry")

    def test_exit_zero_with_stderr_or_no_disconnect_remains_unknown(self):
        with_stderr = FakeRunner(e1_stderr=b"unregistered warning\n")
        exit_code, receipt, _ = self.run_workflow(with_stderr)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["capabilityVerdict"], "unknown")

        self.state = self.root / "controlled-state-no-disconnect"
        no_disconnect = FakeRunner(
            post_targets=f"{CONNECT_KEY}\n".encode("ascii")
        )
        exit_code, receipt, _ = self.run_workflow(no_disconnect)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["capabilityVerdict"], "unknown")

    def test_wrong_mode_is_unsupported_and_missing_loader_is_unknown(self):
        maskrom = FakeRunner(
            post_ld=b"DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=2\tMaskrom\n"
        )
        exit_code, receipt, _ = self.run_workflow(maskrom)
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt["capabilityVerdict"], "unsupported")
        self.assertEqual(receipt["autoRebindVerdict"], "unknown")

        self.state = self.root / "controlled-state-missing-loader"
        missing = FakeRunner(post_ld=b"")
        exit_code, receipt, _ = self.run_workflow(missing)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["capabilityVerdict"], "unknown")
        self.assertEqual(receipt["autoRebindVerdict"], "unknown")


if __name__ == "__main__":
    unittest.main()
