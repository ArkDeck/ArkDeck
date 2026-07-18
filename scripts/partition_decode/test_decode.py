"""Branch-complete and r2 safety-boundary tests for TASK-PD-001."""

from __future__ import annotations

import ast
import contextlib
import fcntl
import gzip
import hashlib
import inspect
import io
import json
import os
import plistlib
import re
import stat
import tempfile
import types
import unittest
from unittest import mock

import decode
import evidence
import fixtures


@contextlib.contextmanager
def _read_only_descriptor(payload: bytes):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "fixture.bin")
        with open(path, "wb") as handle:
            handle.write(payload)
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        try:
            yield descriptor, path
        finally:
            os.close(descriptor)


def _decode_case(case, audit=None, parameter_sha256=None):
    """Test-only constant patching; production exposes no identity bypass."""
    audit = audit if audit is not None else decode.DecodeAudit()
    with _read_only_descriptor(case.archive_bytes) as (descriptor, _):
        with mock.patch.object(decode, "EXPECTED_RAW_SIZE", case.expected_size):
            with mock.patch.object(
                decode, "EXPECTED_RAW_SHA256", case.expected_sha256
            ):
                with mock.patch.object(
                    decode, "EXPECTED_PARAMETER_SIZE", case.parameter_size
                ):
                    with mock.patch.object(
                        decode,
                        "EXPECTED_PARAMETER_SHA256",
                        parameter_sha256 or case.parameter_sha256,
                    ):
                        return decode.decode_archive(descriptor, audit)


class DescriptorAndStreamingTests(unittest.TestCase):
    def test_identity_gate_precedes_archive_and_parameter_processing(self):
        case = fixtures.archive()
        audit = decode.DecodeAudit()
        with _read_only_descriptor(case.archive_bytes) as (descriptor, _):
            with self.assertRaises(decode.DecodeFailure) as caught:
                decode.decode_archive(descriptor, audit)
        self.assertEqual(caught.exception.code, decode.PD001_IDENTITY_MISMATCH)
        self.assertEqual(audit.tar_headers_inspected, 0)
        self.assertEqual(audit.parameter_bytes_returned_to_decoder, 0)

    def test_bounded_stream_discard_returns_only_parameter_body(self):
        case = fixtures.archive()
        identity, device, rows, audit = _decode_case(case)
        self.assertTrue(identity["identityMatch"])
        self.assertEqual(device, "rk29xxnand")
        self.assertEqual(len(rows), 3)
        self.assertEqual(audit.tar_headers_inspected, 2)
        self.assertEqual(audit.non_parameter_member_spans_stream_discarded, 1)
        self.assertEqual(audit.non_parameter_member_contents_read, 1)
        self.assertEqual(
            audit.parameter_bytes_returned_to_decoder, case.parameter_size
        )
        self.assertEqual(audit.identity_pass_raw_bytes_read, case.expected_size)
        self.assertEqual(audit.gzip_pass_raw_bytes_read, case.expected_size)
        self.assertEqual(audit.raw_bytes_read, 2 * case.expected_size)
        self.assertLessEqual(audit.max_observed_read_chunk, decode.MAX_READ_CHUNK)
        self.assertTrue(audit.first_read_after_descriptor_gates)
        before_span = len(
            fixtures.tar_member(b"before.img", b"NON_PARAMETER_MEMBER_SECRET" * 8)
        )
        self.assertEqual(
            audit.decompressed_bytes_streamed,
            before_span + decode.TAR_BLOCK + case.parameter_size,
        )
        self.assertGreater(audit.gzip_compressed_bytes_buffered_at_stop, 0)

    def test_discard_releases_application_chunk_before_next_read(self):
        events = []

        class TrackedChunk:
            def __init__(self, index):
                self.index = index

            def __del__(self):
                events.append(f"del{self.index}")

        calls = 0

        def tracked_read(gz, amount, audit):
            nonlocal calls
            del gz, amount, audit
            calls += 1
            events.append(f"call{calls}")
            return TrackedChunk(calls)

        with mock.patch.object(decode, "_read_gzip_exact", side_effect=tracked_read):
            decode._discard_gzip_exact(
                object(), decode.MAX_READ_CHUNK + 1, decode.DecodeAudit()
            )
        self.assertEqual(events, ["call1", "del1", "call2", "del2"])

    def test_raw_stream_wrapper_counts_read_and_readinto_by_pass(self):
        audit = decode.DecodeAudit(
            pre_read_fstat_passed=True,
            pre_read_read_only_gate_passed=True,
        )
        identity_stream = decode._AuditedRawStream(
            io.BytesIO(b"identity"), audit, "identity"
        )
        self.assertEqual(identity_stream.read(3), b"ide")
        gzip_stream = decode._AuditedRawStream(
            io.BytesIO(b"gzip-pass"), audit, "gzip"
        )
        buffer = bytearray(4)
        self.assertEqual(gzip_stream.readinto(buffer), 4)
        self.assertEqual(bytes(buffer), b"gzip")
        self.assertEqual(audit.identity_pass_raw_bytes_read, 3)
        self.assertEqual(audit.gzip_pass_raw_bytes_read, 4)
        self.assertEqual(audit.raw_bytes_read, 7)

    def test_raw_wrapper_refuses_read_before_descriptor_gates(self):
        audit = decode.DecodeAudit()
        stream = decode._AuditedRawStream(io.BytesIO(b"x"), audit, "identity")
        with self.assertRaises(decode.DecodeFailure) as caught:
            stream.read(1)
        self.assertEqual(
            caught.exception.code, decode.PD012_SOURCE_NOT_STABLE_REGULAR_FILE
        )
        self.assertEqual(audit.raw_bytes_read, 0)

    def test_missing_parameter_fails_explicitly(self):
        case = fixtures.archive(include_parameter=False)
        with self.assertRaises(decode.DecodeFailure) as caught:
            _decode_case(case)
        self.assertEqual(caught.exception.code, decode.PD003_PARAMETER_MISSING)

    def test_invalid_tar_header_fails_closed(self):
        parameter = fixtures.parameter_text()
        raw = gzip.compress(
            fixtures.tar_header(b"parameter.txt", len(parameter), corrupt=True)
            + parameter
            + b"\x00" * (decode.TAR_BLOCK - len(parameter) % decode.TAR_BLOCK),
            mtime=0,
        )
        case = fixtures.FixtureCase(
            raw,
            len(raw),
            hashlib.sha256(raw).hexdigest(),
            len(parameter),
            hashlib.sha256(parameter).hexdigest(),
        )
        with self.assertRaises(decode.DecodeFailure) as caught:
            _decode_case(case)
        self.assertEqual(caught.exception.code, decode.PD002_ARCHIVE_INVALID)

    def test_parameter_member_hash_is_a_second_fixed_gate(self):
        case = fixtures.archive()
        with self.assertRaises(decode.DecodeFailure) as caught:
            _decode_case(case, parameter_sha256="0" * 64)
        self.assertEqual(caught.exception.code, decode.PD004_PARAMETER_MEMBER_INVALID)

    def test_non_regular_synthetic_modes_fail_before_dup_or_read(self):
        for mode in (
            stat.S_IFBLK,
            stat.S_IFCHR,
            stat.S_IFIFO,
            stat.S_IFLNK,
            stat.S_IFDIR,
        ):
            with self.subTest(mode=mode):
                audit = decode.DecodeAudit()
                fake_stat = types.SimpleNamespace(st_mode=mode | 0o600)
                with mock.patch.object(decode.os, "fstat", return_value=fake_stat):
                    with mock.patch.object(
                        decode.os,
                        "dup",
                        side_effect=AssertionError("non-regular fd must not be duplicated"),
                    ):
                        with self.assertRaises(decode.DecodeFailure) as caught:
                            decode.decode_archive(123, audit)
                self.assertEqual(
                    caught.exception.code,
                    decode.PD012_SOURCE_NOT_STABLE_REGULAR_FILE,
                )
                self.assertEqual(audit.raw_bytes_read, 0)
                self.assertFalse(audit.pre_read_fstat_passed)

    def test_non_read_only_descriptor_fails_before_dup_or_read(self):
        audit = decode.DecodeAudit()
        fake_stat = types.SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600,
            st_dev=1,
            st_ino=2,
            st_size=3,
            st_mtime_ns=4,
            st_ctime_ns=5,
        )
        with mock.patch.object(decode.os, "fstat", return_value=fake_stat):
            with mock.patch.object(decode.fcntl, "fcntl", return_value=os.O_RDWR):
                with mock.patch.object(
                    decode.os,
                    "dup",
                    side_effect=AssertionError("writable fd must not be duplicated"),
                ):
                    with self.assertRaises(decode.DecodeFailure) as caught:
                        decode.decode_archive(123, audit)
        self.assertEqual(caught.exception.code, decode.PD013_DESCRIPTOR_NOT_READ_ONLY)
        self.assertEqual(audit.raw_bytes_read, 0)
        self.assertTrue(audit.pre_read_fstat_passed)
        self.assertFalse(audit.pre_read_read_only_gate_passed)

    def test_actual_read_write_regular_fd_is_rejected_with_zero_reads(self):
        with tempfile.TemporaryFile(mode="w+b") as handle:
            audit = decode.DecodeAudit()
            with self.assertRaises(decode.DecodeFailure) as caught:
                decode.decode_archive(handle.fileno(), audit)
        self.assertEqual(caught.exception.code, decode.PD013_DESCRIPTOR_NOT_READ_ONLY)
        self.assertEqual(audit.raw_bytes_read, 0)

    def test_invalid_descriptor_shapes_fail_before_fstat(self):
        for value in (True, -1, "3", None):
            with self.subTest(value=value):
                with mock.patch.object(
                    decode.os,
                    "fstat",
                    side_effect=AssertionError("invalid descriptor must fail first"),
                ):
                    with self.assertRaises(decode.DecodeFailure):
                        decode.decode_archive(value)

    def test_caller_descriptor_remains_owned_by_broker(self):
        case = fixtures.archive()
        with _read_only_descriptor(case.archive_bytes) as (descriptor, _):
            with self.assertRaises(decode.DecodeFailure):
                decode.decode_archive(descriptor)
            self.assertTrue(stat.S_ISREG(os.fstat(descriptor).st_mode))

    def test_regular_file_metadata_change_fails_stability_recheck(self):
        with _read_only_descriptor(b"before") as (descriptor, path):
            audit = decode.DecodeAudit()
            stream = decode._open_descriptor_stream(descriptor, audit)
            try:
                with open(path, "ab") as handle:
                    handle.write(b"after")
                with self.assertRaises(decode.DecodeFailure) as caught:
                    decode._assert_source_stable(stream, audit)
            finally:
                stream.close()
        self.assertEqual(
            caught.exception.code, decode.PD012_SOURCE_NOT_STABLE_REGULAR_FILE
        )


class ClosedGrammarTests(unittest.TestCase):
    def test_all_three_positive_grammar_branches(self):
        _, rows = decode.parse_parameter(fixtures.parameter_text())
        self.assertEqual(
            [row.grammar_branch for row in rows],
            ["fixed", "fixedBootable", "remainderGrow"],
        )
        self.assertEqual(rows[0].size_value, 0x10)
        self.assertEqual(rows[0].offset_value, 0x20)
        self.assertIsNone(rows[2].size_value)
        self.assertEqual(rows[2].attribute, "grow")

    def test_parameter_document_failures_are_explicit(self):
        cases = (
            (b"\xff", decode.PD005_PARAMETER_TEXT_INVALID),
            (b"BAD LINE\n", decode.PD005_PARAMETER_TEXT_INVALID),
            (b"FIELD:value\n", decode.PD006_CMDLINE_MISSING),
            (
                b"CMDLINE:mtdparts=x:0x1@0x2(a)\n"
                b"CMDLINE:mtdparts=x:0x1@0x2(b)\n",
                decode.PD007_CMDLINE_DUPLICATE,
            ),
            (b"CMDLINE:not-mtdparts\n", decode.PD008_CMDLINE_INVALID),
        )
        for payload, code in cases:
            with self.subTest(code=code, payload=payload):
                with self.assertRaises(decode.DecodeFailure) as caught:
                    decode.parse_parameter(payload)
                self.assertEqual(caught.exception.code, code)

    def test_unknown_partition_shapes_fail_instead_of_guessing(self):
        invalid_entries = (
            "10@0x20(a)",
            "0x10(a)",
            "0x10@20(a)",
            "0x10@0x20()",
            "0x10@0x20(a):bootable",
            "0x10@0x20(a:unknown)",
            "-@0x20(a)",
            "-@0x20(a:bootable)",
            "0x10@0x20(a:grow)",
            "0x0@0x20(a)",
            "0x10@0x20(a),",
            "-@0x0(rest:grow),0x10@0x20(later)",
        )
        for entry in invalid_entries:
            with self.subTest(entry=entry):
                payload = f"CMDLINE:mtdparts=rk29xxnand:{entry}\n".encode()
                with self.assertRaises(decode.DecodeFailure) as caught:
                    decode.parse_parameter(payload)
                self.assertEqual(caught.exception.code, decode.PD009_PARTITION_INVALID)

    def test_duplicate_partition_name_fails(self):
        payload = b"CMDLINE:mtdparts=x:0x1@0x2(same),0x3@0x4(same)\n"
        with self.assertRaises(decode.DecodeFailure) as caught:
            decode.parse_parameter(payload)
        self.assertEqual(caught.exception.code, decode.PD010_PARTITION_DUPLICATE)


class ReconciliationTests(unittest.TestCase):
    def test_every_inventory_member_and_partition_is_accounted_for(self):
        _, rows = decode.parse_parameter(fixtures.parameter_text())
        result = decode.reconcile_members(rows, fixtures.inventory())
        self.assertEqual(result["inventoryMemberCount"], 6)
        self.assertEqual(len(result["members"]), 6)
        self.assertEqual(len(result["partitions"]), 3)
        self.assertEqual(result["mappedImageCount"], 2)
        self.assertEqual(result["orphanImageMembers"], ["user-data.img"])
        self.assertEqual(result["orphanPartitions"], ["userdata"])

    def test_invalid_inventory_is_rejected(self):
        inventory = fixtures.inventory()
        inventory["archiveSha256"] = "0" * 64
        with self.assertRaises(decode.DecodeFailure) as caught:
            decode.reconcile_members([], inventory)
        self.assertEqual(caught.exception.code, decode.PD011_INVENTORY_INVALID)


class EvidencePipelineTests(unittest.TestCase):
    def _valid_bundle(self):
        inventory, inventory_sha256 = evidence.load_archived_inventory()
        identity = {
            "sizeBytes": decode.EXPECTED_RAW_SIZE,
            "sha256": decode.EXPECTED_RAW_SHA256,
            "identityMatch": True,
        }
        rows = decode._expected_partition_rows()
        reconciliation = decode.reconcile_members(rows, inventory)
        documents = {
            "partition-mapping.json": decode._partition_document(
                identity, "rk29xxnand", rows
            ),
            "member-reconciliation.json": decode._reconciliation_document(
                reconciliation, inventory_sha256
            ),
            "process-audit.json": decode._expected_audit_document(),
        }
        decode.validate_evidence_bundle(documents, inventory, inventory_sha256)
        payloads = {
            name: evidence._serialize(document) for name, document in documents.items()
        }
        return documents, payloads, inventory, inventory_sha256

    def test_core_outputs_are_create_only_and_deterministic(self):
        _, payloads, _, _ = self._valid_bundle()
        with tempfile.TemporaryDirectory() as directory:
            first = os.path.join(directory, "first")
            second = os.path.join(directory, "second")
            evidence._write_set(first, payloads, evidence.CORE_OUTPUTS)
            evidence._write_set(second, payloads, evidence.CORE_OUTPUTS)
            for name in evidence.CORE_OUTPUTS:
                with open(os.path.join(first, name), "rb") as handle:
                    left = handle.read()
                with open(os.path.join(second, name), "rb") as handle:
                    right = handle.read()
                self.assertEqual(left, right)
            with self.assertRaises(decode.DecodeToolError):
                evidence._write_set(first, payloads, evidence.CORE_OUTPUTS)

    def test_closed_validation_rejects_tampered_scope_and_audit(self):
        documents, _, inventory, inventory_sha256 = self._valid_bundle()
        mapping = json.loads(evidence._serialize(documents["partition-mapping.json"]))
        mapping["scope"]["authoritative"] = True
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence(
                "partition-mapping.json", mapping, inventory, inventory_sha256
            )
        audit = json.loads(evidence._serialize(documents["process-audit.json"]))
        audit["archivePathOpenCallCount"] = 1
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence(
                "process-audit.json", audit, inventory, inventory_sha256
            )

    def test_production_signatures_accept_fd_not_archive_path(self):
        self.assertEqual(
            tuple(inspect.signature(decode.decode_archive).parameters),
            ("descriptor", "audit"),
        )
        self.assertEqual(
            tuple(inspect.signature(evidence.build_core_evidence_from_fd).parameters),
            ("descriptor", "out_dir", "inventory_path"),
        )

    def test_no_raw_parameter_or_locator_in_expected_core_bundle(self):
        _, payloads, _, _ = self._valid_bundle()
        combined = b"".join(payloads.values())
        self.assertNotIn(b"TOP_SECRET_PARAMETER_RAW_VALUE", combined)
        self.assertNotIn(b"/Users/", combined)
        self.assertNotIn(b"Downloads", combined)

    @staticmethod
    def _caller_assertion_platform_document():
        return {
            "schema": "arkdeck-dayu200-input-broker-platform-1.0.0",
            "evidenceClass": "platform",
            "scope": decode._scope(),
            "environment": {
                "osProductVersion": "26.5.2",
                "osBuildVersion": "25F84",
                "architecture": "arm64",
                "xcodeVersion": "Xcode 26.6",
                "swiftVersion": "Apple Swift version 6.3.3",
                "pythonVersion": "3.14.6",
            },
            "sandboxBroker": {
                "artifact": {
                    "signatureVerifiedStrict": True,
                    "signatureIdentity": "adhoc",
                    "sha256": "a" * 64,
                },
                "signedEntitlements": {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.files.user-selected.read-only": True,
                    "com.apple.security.temporary-exception.files.absolute-path.read-only": [
                        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/"
                    ],
                },
                "policy": {
                    "sha256": "b" * 64,
                    "appSandboxPolicyVerified": True,
                    "deviceNamespace": "/dev",
                    "deviceNamespacePathRejectedBeforeOpen": True,
                    "deviceNamespaceReadDenied": True,
                    "deviceNamespaceWriteDenied": True,
                    "networkDenied": True,
                    "processExecDenied": True,
                },
                "descriptorTransfer": {
                    "archiveAcquisition": "NSOpenPanel user selection",
                    "archiveDescriptorOpenFlags": [
                        "O_RDONLY",
                        "O_NONBLOCK",
                        "O_NOFOLLOW",
                        "O_CLOEXEC",
                    ],
                    "decoderInvocation": (
                        "same-process CPython C API call with integer fd only"
                    ),
                    "archivePathPassedToDecoder": False,
                    "subprocessUsed": False,
                    "socketOrNetworkUsed": False,
                    "existingArkDeckAppUsed": False,
                },
            },
        }

    def test_caller_assertion_platform_document_is_rejected(self):
        _, payloads, _, _ = self._valid_bundle()
        platform = self._caller_assertion_platform_document()
        with self.assertRaises(decode.EvidenceValidationError):
            evidence.validate_platform_evidence(platform, {}, b"{}", payloads)

    def test_runtime_receipt_requires_device_detail_and_artifact_identity(self):
        receipt = {
            "schema": "arkdeck-dayu200-input-broker-runtime-1.0.0",
            "appSandboxPolicyVerified": True,
            "coreOutputSha256": {name: "a" * 64 for name in evidence.CORE_OUTPUTS},
        }
        with self.assertRaises(decode.EvidenceValidationError):
            evidence.validate_runtime_receipt(receipt)

    def test_publisher_has_no_staging_or_standalone_caller_json_cli(self):
        parameters = tuple(
            inspect.signature(
                evidence.publish_collector_validated_evidence
            ).parameters
        )
        self.assertEqual(
            parameters,
            (
                "core_payloads",
                "runtime_document",
                "runtime_payload",
                "platform_document",
                "platform_payload",
                "out_dir",
                "inventory_path",
            ),
        )
        source = inspect.getsource(evidence)
        self.assertNotIn("--staging-dir", source)
        self.assertNotIn('if __name__ == "__main__"', source)

    def test_blocked_audit_does_not_claim_literal_zero_retention_pass(self):
        audit = decode._expected_audit_document()
        self.assertEqual(
            audit["applicationChunkReferenceRetainedAcrossNextReadBytes"], 0
        )
        self.assertIn("DEFLATE", audit["deflateInternalHistoryRetention"])
        self.assertFalse(audit["crossChunkRetentionAcceptanceSatisfied"])
        self.assertFalse(audit["partitionAcceptanceSatisfied"])


class StaticProductionAuditTests(unittest.TestCase):
    ALLOWED_IMPORTS = {
        "decode.py": {
            "__future__",
            "dataclasses",
            "fcntl",
            "hashlib",
            "io",
            "os",
            "re",
            "stat",
            "sys",
            "typing",
            "zlib",
        },
        "broker_entry.py": {
            "__future__",
            "evidence",
            "hashlib",
            "json",
            "os",
            "sys",
        },
        "evidence.py": {
            "__future__",
            "hashlib",
            "json",
            "os",
            "re",
            "decode",
        },
        "macos_input_broker/collect_platform_evidence.py": {
            "__future__",
            "argparse",
            "base64",
            "binascii",
            "evidence",
            "hashlib",
            "json",
            "os",
            "plistlib",
            "re",
            "stat",
            "subprocess",
            "sys",
            "tempfile",
            "typing",
        },
    }
    ALLOWED_MODULE_CALLS = {
        "decode.py": {
            "dataclasses.field",
            "fcntl.fcntl",
            "hashlib.sha256",
            "os.close",
            "os.dup",
            "os.fdopen",
            "os.fstat",
            "re.compile",
            "stat.S_ISREG",
            "zlib.decompressobj",
        },
        "broker_entry.py": {
            "evidence.build_core_evidence_from_fd",
            "hashlib.sha256",
            "json.dumps",
            "os.path.dirname",
            "os.path.join",
        },
        "evidence.py": {
            "decode.DecodeFailure",
            "decode.DecodeToolError",
            "decode.EvidenceValidationError",
            "decode._audit_document",
            "decode._partition_document",
            "decode._reconciliation_document",
            "decode._scope",
            "decode._validate_inventory",
            "decode.decode_archive",
            "decode.reconcile_members",
            "decode.validate_evidence_bundle",
            "hashlib.sha256",
            "json.dumps",
            "json.loads",
            "os.makedirs",
            "os.path.abspath",
            "os.path.dirname",
            "os.path.join",
            "os.path.lexists",
            "re.fullmatch",
        },
        "macos_input_broker/collect_platform_evidence.py": {
            "argparse.ArgumentParser",
            "base64.b64decode",
            "evidence.publish_collector_validated_evidence",
            "hashlib.sha256",
            "json.dumps",
            "json.loads",
            "os.path.abspath",
            "os.path.basename",
            "os.path.dirname",
            "os.path.isdir",
            "os.path.join",
            "os.path.lexists",
            "os.path.relpath",
            "os.stat",
            "os.walk",
            "plistlib.load",
            "plistlib.loads",
            "re.fullmatch",
            "stat.S_ISREG",
            "subprocess.Popen",
            "subprocess.run",
            "sys.path.insert",
            "tempfile.TemporaryDirectory",
        },
    }
    BANNED_NAMES = {
        "subprocess",
        "socket",
        "ssl",
        "http",
        "urllib",
        "ftplib",
        "asyncio",
        "ctypes",
        "multiprocessing",
        "tarfile",
        "zipfile",
        "posix_spawn",
        "posix_spawnp",
        "execvp",
        "execvpe",
        "forkpty",
        "eval",
        "compile",
        "__import__",
    }
    BANNED_CALL_SUFFIXES = {
        "system",
        "popen",
        "fork",
        "forkpty",
        "posix_spawn",
        "posix_spawnp",
        "execv",
        "execve",
        "execvp",
        "execvpe",
        "spawnl",
        "spawnle",
        "spawnlp",
        "spawnlpe",
        "spawnv",
        "spawnve",
        "spawnvp",
        "spawnvpe",
        "socket",
        "connect",
        "send",
        "sendall",
        "request",
        "urlopen",
        "dlopen",
    }

    def _tree(self, filename):
        directory = os.path.dirname(os.path.abspath(decode.__file__))
        with open(os.path.join(directory, filename), "rb") as handle:
            return ast.parse(handle.read().decode("utf-8"))

    @staticmethod
    def _call_target(node):
        parts = []
        current = node
        while isinstance(current, ast.Attribute):
            parts.append(current.attr)
            current = current.value
        if not isinstance(current, ast.Name):
            return None
        parts.append(current.id)
        return ".".join(reversed(parts))

    def test_python_imports_and_module_call_targets_are_closed(self):
        for filename, allowed in self.ALLOWED_IMPORTS.items():
            tree = self._tree(filename)
            imports = set()
            imported_symbols = {}
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        self.assertIsNone(alias.asname, filename)
                        imports.add(alias.name.split(".")[0])
                elif isinstance(node, ast.ImportFrom):
                    module = (node.module or "").split(".")[0]
                    imports.add(module)
                    for alias in node.names:
                        self.assertIsNone(alias.asname, filename)
                        imported_symbols[alias.name] = module
            self.assertEqual(imports, allowed, filename)
            forbidden_names = self.BANNED_NAMES
            if filename == "macos_input_broker/collect_platform_evidence.py":
                forbidden_names = forbidden_names - {"subprocess"}
            self.assertFalse(imports & forbidden_names, filename)
            observed_module_calls = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Name):
                    self.assertNotIn(node.id, forbidden_names, filename)
                elif isinstance(node, ast.Call):
                    target = self._call_target(node.func)
                    if target is None:
                        continue
                    suffix = target.rsplit(".", 1)[-1]
                    self.assertNotIn(suffix, self.BANNED_CALL_SUFFIXES, filename)
                    root = target.split(".", 1)[0]
                    if root in imports:
                        observed_module_calls.add(target)
                    elif root in imported_symbols:
                        observed_module_calls.add(
                            target.replace(root, imported_symbols[root], 1)
                        )
            self.assertEqual(
                observed_module_calls, self.ALLOWED_MODULE_CALLS[filename], filename
            )

    def test_collector_subprocess_targets_are_fixed_argv_and_never_shell(self):
        tree = self._tree("macos_input_broker/collect_platform_evidence.py")
        subprocess_calls = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            target = self._call_target(node.func)
            if target not in {"subprocess.run", "subprocess.Popen"}:
                continue
            subprocess_calls.append(target)
            shell_values = [
                keyword.value
                for keyword in node.keywords
                if keyword.arg == "shell"
            ]
            self.assertEqual(len(shell_values), 1)
            self.assertIsInstance(shell_values[0], ast.Constant)
            self.assertIs(shell_values[0].value, False)
            self.assertFalse(any(keyword.arg is None for keyword in node.keywords))
        self.assertEqual(
            subprocess_calls.count("subprocess.run"), 2
        )
        self.assertEqual(subprocess_calls.count("subprocess.Popen"), 1)

    def test_decoder_has_no_archive_path_resolution_target(self):
        tree = self._tree("decode.py")
        observed_os_calls = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                target = self._call_target(node.func)
                if target in {"open", "os.open", "os.openat", "os.lstat", "os.stat"}:
                    self.fail(f"path-resolution target in production decoder: {target}")
                if target is not None and target.startswith("os."):
                    observed_os_calls.add(target)
            elif isinstance(node, ast.Name):
                self.assertNotIn(node.id, self.BANNED_NAMES)
        self.assertEqual(
            observed_os_calls,
            {"os.close", "os.dup", "os.fdopen", "os.fstat"},
        )

    def test_broker_entry_has_no_archive_path_argument_or_archive_open(self):
        tree = self._tree("broker_entry.py")
        source = inspect.getsource(__import__("broker_entry"))
        self.assertNotIn("archive_path", source)
        self.assertNotIn("os.open", source)
        self.assertNotIn("os.openat", source)
        self.assertNotIn("os.lstat", source)
        open_calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and self._call_target(node.func) == "open"
        ]
        self.assertEqual(len(open_calls), 1)
        self.assertIn("out_dir", ast.unparse(open_calls[0].args[0]))
        import broker_entry

        self.assertEqual(
            tuple(inspect.signature(broker_entry.run_from_broker_fd).parameters),
            ("descriptor", "out_dir"),
        )

    def test_macos_broker_source_and_entitlements_are_closed(self):
        root = os.path.join(
            os.path.dirname(os.path.abspath(decode.__file__)), "macos_input_broker"
        )
        with open(os.path.join(root, "main.m"), encoding="utf-8") as handle:
            source = handle.read()
        observed_headers = set(re.findall(r"^#import <([^>]+)>$", source, re.MULTILINE))
        self.assertEqual(
            observed_headers,
            {
                "AppKit/AppKit.h",
                "Foundation/Foundation.h",
                "Python.h",
                "Security/Security.h",
                "fcntl.h",
                "string.h",
                "sys/stat.h",
                "unistd.h",
            },
        )
        observed_c_targets = set(
            re.findall(r"(?<![.@])\b([A-Za-z_]\w*)\s*\(", source)
        )
        self.assertEqual(
            observed_c_targets,
            {
                "CFBridgingRelease",
                "CFRelease",
                "CopyRunningCodeIdentity",
                "CreateOutputDirectory",
                "HexData",
                "IsDeviceNamespaceURL",
                "PrintPythonError",
                "PyCallable_Check",
                "PyConfig_Clear",
                "PyConfig_InitIsolatedConfig",
                "PyErr_Occurred",
                "PyErr_Print",
                "PyImport_ImportModule",
                "PyList_Insert",
                "PyObject_CallObject",
                "PyObject_GetAttrString",
                "PyRun_SimpleString",
                "PyStatus_Exception",
                "PySys_GetObject",
                "PyUnicode_AsUTF8",
                "PyUnicode_Check",
                "PyUnicode_FromString",
                "Py_BuildValue",
                "Py_DECREF",
                "Py_FinalizeEx",
                "Py_InitializeFromConfig",
                "Py_XDECREF",
                "RunDecoderInProcess",
                "SecCodeCopySelf",
                "SecCodeCopySigningInformation",
                "VerifyClosedAppSandboxPolicy",
                "WriteRuntimeReceipt",
                "close",
                "fflush",
                "for",
                "fprintf",
                "getpid",
                "if",
                "main",
                "open",
                "printf",
                "sandbox_check",
                "strlen",
            },
        )
        observed_receivers = set(
            re.findall(r"\[\s*([A-Za-z_]\w*)\s+", source)
        )
        self.assertEqual(
            observed_receivers,
            {
                "NSApp",
                "NSApplication",
                "NSBundle",
                "NSData",
                "NSDictionary",
                "NSFileManager",
                "NSJSONSerialization",
                "NSMutableDictionary",
                "NSMutableString",
                "NSOpenPanel",
                "NSString",
                "applicationSupport",
                "brokerRoot",
                "data",
                "identifier",
                "manager",
                "object",
                "outDirectory",
                "panel",
                "result",
                "standardized",
                "terminated",
                "unique",
            },
        )
        observed_selector_tokens = set(
            re.findall(r"\b([A-Za-z_]\w*)\s*:", source)
        )
        self.assertEqual(
            observed_selector_tokens,
            {
                "JSONObjectWithData",
                "NULL",
                "URLByAppendingPathComponent",
                "URLForDirectory",
                "activateIgnoringOtherApps",
                "appendBytes",
                "appendFormat",
                "appropriateForURL",
                "attributes",
                "base64EncodedStringWithOptions",
                "create",
                "createDirectoryAtURL",
                "dataWithBytes",
                "dataWithJSONObject",
                "error",
                "failed",
                "hasPrefix",
                "inDomain",
                "isDirectory",
                "isEqualToString",
                "isKindOfClass",
                "length",
                "options",
                "setActivationPolicy",
                "stringByAppendingPathComponent",
                "stringByAppendingString",
                "stringWithCapacity",
                "withIntermediateDirectories",
                "writeToFile",
            },
        )
        observed_dot_targets = set(re.findall(r"\.([A-Za-z_]\w*)", source))
        self.assertEqual(
            observed_dot_targets,
            {
                "URL",
                "UTF8String",
                "UUID",
                "UUIDString",
                "allowsMultipleSelection",
                "bytes",
                "canChooseDirectories",
                "canChooseFiles",
                "err_msg",
                "fileSystemRepresentation",
                "h",
                "json",
                "length",
                "modules",
                "parse_argv",
                "path",
                "prompt",
                "resolvesAliases",
                "resourcePath",
                "site_import",
                "stringByStandardizingPath",
                "title",
                "usbserial",
                "write_bytecode",
            },
        )
        self.assertIn("[NSOpenPanel openPanel]", source)
        self.assertIn("IsDeviceNamespaceURL(selectedURL)", source)
        self.assertIn("open(selectedURL.fileSystemRepresentation", source)
        self.assertEqual(source.count(" open("), 1)
        self.assertIn("PyObject_CallObject(function, arguments)", source)
        self.assertIn('Py_BuildValue("(is)", descriptor', source)
        with open(os.path.join(root, "Broker.entitlements"), "rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(
            entitlements,
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-only": True,
                "com.apple.security.temporary-exception.files.absolute-path.read-only": [
                    "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/"
                ],
            },
        )
        forbidden = {
            "com.apple.security.device.usb",
            "com.apple.security.device.serial",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
        }
        self.assertTrue(forbidden.isdisjoint(entitlements))

    def test_declared_policy_denies_device_network_and_exec_namespaces(self):
        root = os.path.join(
            os.path.dirname(os.path.abspath(decode.__file__)), "macos_input_broker"
        )
        with open(os.path.join(root, "policy.json"), encoding="utf-8") as handle:
            policy = json.load(handle)
        self.assertEqual(
            policy["deviceNamespacePathPolicy"],
            "reject standardized /dev and /dev/** before archive open",
        )
        self.assertIn("network", policy["deniedCapabilities"])
        self.assertIn("process execution", policy["deniedCapabilities"])

    def test_production_constants_match_archived_evidence(self):
        self.assertEqual(decode.EXPECTED_RAW_SIZE, 732948803)
        self.assertEqual(
            decode.EXPECTED_RAW_SHA256,
            "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280",
        )
        self.assertEqual(decode.EXPECTED_PARAMETER_SIZE, 788)
        self.assertEqual(
            decode.EXPECTED_PARAMETER_SHA256,
            "35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048",
        )


if __name__ == "__main__":
    unittest.main()
