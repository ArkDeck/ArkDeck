"""Headless contract tests for the collector's per-term receipt validation.

TASK-PD-001 r5. No broker launch, no GUI, no pinned archive, no device, no
network: every vector is a synthetic in-memory receipt evaluated directly
against `_validate_runtime_receipt`, plus source-literal pins on the explicit
BOOL boxing in `main.m` (README/runbook literal-sync test precedent).
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest

_BROKER_ROOT = os.path.dirname(os.path.abspath(__file__))
_COLLECTOR = os.path.join(_BROKER_ROOT, "collect_platform_evidence.py")
_MAIN_M = os.path.join(_BROKER_ROOT, "main.m")

_spec = importlib.util.spec_from_file_location("_pd001_r5_collector", _COLLECTOR)
collector = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = collector
_spec.loader.exec_module(collector)

DEVICE_PATHS = (
    "/dev/disk0",
    "/dev/rdisk0",
    "/dev/cu.usbserial-synthetic",
    "/dev/tty.usbserial-synthetic",
)
ARTIFACT = {
    "bundleIdentifier": "io.arkdeck.partition-decode-broker",
    "codeDirectoryHash": "0" * 40,
}
CORE_BYTES = {
    "partition-mapping.json": b'{"synthetic":"mapping"}\n',
    "member-reconciliation.json": b'{"synthetic":"reconciliation"}\n',
    "process-audit.json": b'{"synthetic":"audit"}\n',
}


def canonical_receipt() -> dict:
    checks = {
        path: {"readDenied": True, "writeDenied": True} for path in DEVICE_PATHS
    }
    checks["network-outbound"] = True
    checks["process-exec"] = True
    return {
        "schema": "arkdeck-dayu200-input-broker-runtime-1.0.0",
        "appSandboxPolicyVerified": True,
        "deviceNamespacePathRejectedBeforeOpen": True,
        "policyChecks": checks,
        "archiveAcquisition": "NSOpenPanel user selection",
        "archiveDescriptorOpenFlags": [
            "O_RDONLY", "O_NONBLOCK", "O_NOFOLLOW", "O_CLOEXEC",
        ],
        "descriptorTransfer": (
            "same-process CPython C API call with integer fd only"
        ),
        "archivePathPassedToDecoder": False,
        "subprocessUsed": False,
        "socketOrNetworkUsed": False,
        "realDeviceNodeOpenedForVerification": False,
        "existingArkDeckAppUsed": False,
        "runningCode": {
            "identifier": ARTIFACT["bundleIdentifier"],
            "codeDirectoryHash": ARTIFACT["codeDirectoryHash"],
        },
        "embeddedPythonVersion": collector.EXPECTED_PYTHON_VERSION,
        "coreOutputSha256": {
            name: hashlib.sha256(data).hexdigest()
            for name, data in CORE_BYTES.items()
        },
        "decoderOutputs": sorted(CORE_BYTES),
    }


class ReceiptVectorTests(unittest.TestCase):
    def _run(self, receipt, out_dir=None, payload=None):
        data = json.dumps(receipt, sort_keys=True).encode("utf-8")
        if payload is None:
            payload = data
        if out_dir is None:
            tmp = tempfile.TemporaryDirectory(prefix="pd001-r5-receipt-")
            self.addCleanup(tmp.cleanup)
            out_dir = tmp.name
            with open(
                os.path.join(out_dir, collector.RUNTIME_RECEIPT), "wb"
            ) as handle:
                handle.write(data)
            for name, content in CORE_BYTES.items():
                with open(os.path.join(out_dir, name), "wb") as handle:
                    handle.write(content)
        return collector._validate_runtime_receipt(
            receipt, payload, out_dir, ARTIFACT
        )

    def _assert_named_failure(self, receipt, term_fragment):
        with self.assertRaises(collector.CollectionError) as context:
            self._run(receipt)
        message = str(context.exception)
        self.assertIn("runtime receipt failed closed validation", message)
        self.assertIn(term_fragment, message)
        return message

    def test_canonical_true_receipt_passes_every_term(self):
        payloads = self._run(canonical_receipt())
        for name, content in CORE_BYTES.items():
            self.assertEqual(payloads[name], content)
        self.assertIn(collector.RUNTIME_RECEIPT, payloads)

    def test_integer_boxed_network_outbound_is_rejected_naming_the_field(self):
        receipt = canonical_receipt()
        receipt["policyChecks"]["network-outbound"] = 1
        message = self._assert_named_failure(
            receipt, "policyChecks[network-outbound]"
        )
        self.assertIn("observed 1", message)

    def test_integer_boxed_process_exec_is_rejected_naming_the_field(self):
        receipt = canonical_receipt()
        receipt["policyChecks"]["process-exec"] = 1
        self._assert_named_failure(receipt, "policyChecks[process-exec]")

    def test_integer_boxed_device_path_booleans_are_rejected(self):
        for path in DEVICE_PATHS:
            for field in ("readDenied", "writeDenied"):
                with self.subTest(path=path, field=field):
                    receipt = canonical_receipt()
                    receipt["policyChecks"][path] = {
                        "readDenied": True, "writeDenied": True, field: 1,
                    }
                    self._assert_named_failure(
                        receipt, f"policyChecks[{path}]"
                    )

    def test_full_integer_boxed_receipt_reports_first_boolean_field(self):
        # The exact defect shape observed on 2026-07-20: every
        # sandbox_check-derived field serialized as JSON 1.
        receipt = canonical_receipt()
        for path in DEVICE_PATHS:
            receipt["policyChecks"][path] = {"readDenied": 1, "writeDenied": 1}
        receipt["policyChecks"]["network-outbound"] = 1
        receipt["policyChecks"]["process-exec"] = 1
        self._assert_named_failure(receipt, "policyChecks[/dev/disk0]")

    def test_each_missing_top_level_field_produces_its_named_error(self):
        for key in (
            "schema",
            "appSandboxPolicyVerified",
            "deviceNamespacePathRejectedBeforeOpen",
            "policyChecks",
            "archiveAcquisition",
            "archiveDescriptorOpenFlags",
            "descriptorTransfer",
            "archivePathPassedToDecoder",
            "subprocessUsed",
            "socketOrNetworkUsed",
            "realDeviceNodeOpenedForVerification",
            "existingArkDeckAppUsed",
            "runningCode",
            "embeddedPythonVersion",
            "coreOutputSha256",
        ):
            with self.subTest(key=key):
                receipt = canonical_receipt()
                del receipt[key]
                message = self._assert_named_failure(receipt, key)
                self.assertIn("<missing>", message)

    def test_missing_device_path_entry_is_named(self):
        receipt = canonical_receipt()
        del receipt["policyChecks"]["/dev/rdisk0"]
        message = self._assert_named_failure(
            receipt, "policyChecks[/dev/rdisk0]"
        )
        self.assertIn("<missing>", message)

    def test_tampered_scalar_fields_each_produce_named_errors(self):
        vectors = (
            ("schema", "arkdeck-dayu200-input-broker-runtime-2.0.0", "schema"),
            ("archiveAcquisition", "argv path", "archiveAcquisition"),
            (
                "archiveDescriptorOpenFlags",
                ["O_RDONLY", "O_NOFOLLOW", "O_NONBLOCK", "O_CLOEXEC"],
                "archiveDescriptorOpenFlags",
            ),
            ("descriptorTransfer", "path handoff", "descriptorTransfer"),
            ("archivePathPassedToDecoder", True, "archivePathPassedToDecoder"),
            ("subprocessUsed", 0, "subprocessUsed"),
            ("embeddedPythonVersion", "3.14.7", "embeddedPythonVersion"),
            ("runningCode", "not-a-dict", "runningCode"),
            ("policyChecks", ["not-a-dict"], "policyChecks"),
        )
        for key, bad, fragment in vectors:
            with self.subTest(key=key):
                receipt = canonical_receipt()
                receipt[key] = bad
                self._assert_named_failure(receipt, fragment)

    def test_running_code_identity_mismatches_are_named(self):
        receipt = canonical_receipt()
        receipt["runningCode"]["identifier"] = "io.arkdeck.other"
        self._assert_named_failure(receipt, "runningCode.identifier")
        receipt = canonical_receipt()
        receipt["runningCode"]["codeDirectoryHash"] = "f" * 40
        self._assert_named_failure(receipt, "runningCode.codeDirectoryHash")

    def test_core_hash_key_set_and_format_are_enforced(self):
        receipt = canonical_receipt()
        del receipt["coreOutputSha256"]["process-audit.json"]
        self._assert_named_failure(receipt, "coreOutputSha256")
        receipt = canonical_receipt()
        receipt["coreOutputSha256"]["extra.json"] = "0" * 64
        self._assert_named_failure(receipt, "coreOutputSha256")
        receipt = canonical_receipt()
        receipt["coreOutputSha256"]["process-audit.json"] = "XYZ"
        self._assert_named_failure(
            receipt, "coreOutputSha256[process-audit.json]"
        )

    def test_receipt_file_and_core_hash_binding_still_fail_closed(self):
        receipt = canonical_receipt()
        data = json.dumps(receipt, sort_keys=True).encode("utf-8")
        tmp = tempfile.TemporaryDirectory(prefix="pd001-r5-binding-")
        self.addCleanup(tmp.cleanup)
        with open(
            os.path.join(tmp.name, collector.RUNTIME_RECEIPT), "wb"
        ) as handle:
            handle.write(data + b"tampered")
        for name, content in CORE_BYTES.items():
            with open(os.path.join(tmp.name, name), "wb") as handle:
                handle.write(content)
        with self.assertRaisesRegex(
            collector.CollectionError, "stdout receipt and broker receipt file"
        ):
            collector._validate_runtime_receipt(receipt, data, tmp.name, ARTIFACT)

        tmp2 = tempfile.TemporaryDirectory(prefix="pd001-r5-binding2-")
        self.addCleanup(tmp2.cleanup)
        with open(
            os.path.join(tmp2.name, collector.RUNTIME_RECEIPT), "wb"
        ) as handle:
            handle.write(data)
        for name, content in CORE_BYTES.items():
            with open(os.path.join(tmp2.name, name), "wb") as handle:
                handle.write(content + b"drift")
        with self.assertRaisesRegex(
            collector.CollectionError, "runtime-bound core hash mismatch"
        ):
            collector._validate_runtime_receipt(receipt, data, tmp2.name, ARTIFACT)


class MainSourceBooleanBoxingTests(unittest.TestCase):
    def setUp(self):
        with open(_MAIN_M, encoding="utf-8") as handle:
            self.source = handle.read()

    def test_every_sandbox_check_policy_field_uses_explicit_bool_boxing(self):
        for literal in (
            "NSNumber *readDenied = @NO;",
            "readDenied = @YES;",
            "NSNumber *writeDenied = @NO;",
            "writeDenied = @YES;",
            "NSNumber *networkOutboundDenied = @NO;",
            "networkOutboundDenied = @YES;",
            "NSNumber *processExecDenied = @NO;",
            "processExecDenied = @YES;",
            '@"readDenied": readDenied,',
            '@"writeDenied": writeDenied',
            'checks[@"network-outbound"] = networkOutboundDenied;',
            'checks[@"process-exec"] = processExecDenied;',
        ):
            self.assertIn(literal, self.source)

    def test_integer_boxing_is_absent_from_broker_source(self):
        # NSNumber int boxing of C comparison results was the 2026-07-20
        # platform-run root cause; the broker source must contain none at all.
        self.assertNotIn("@(", self.source)


class StaticSafetyTests(unittest.TestCase):
    def test_this_suite_never_launches_the_broker_or_collector_flow(self):
        # Each banned name must appear exactly once in this file: its
        # occurrence inside this tuple literal. Any second occurrence would
        # be a call site, which this headless suite must never contain.
        with open(os.path.abspath(__file__), encoding="utf-8") as handle:
            source = handle.read()
        for banned in (
            "collect_fresh", "_launch_verified_broker", "_build_fresh_artifact",
            "subprocess.Popen",
        ):
            self.assertEqual(source.count(banned), 1, banned)


if __name__ == "__main__":
    unittest.main()
