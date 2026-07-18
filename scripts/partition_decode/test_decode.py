"""Branch-complete and safety-boundary tests for TASK-PD-001."""

from __future__ import annotations

import ast
import gzip
import hashlib
import inspect
import io
import json
import os
import stat
import tempfile
import types
import unittest
from unittest import mock

import decode
import fixtures


def _decode_case(case, audit=None, src=None, parameter_sha256=None):
    """Test-only composition for synthetic identities; production has no bypass."""
    audit = audit if audit is not None else decode.DecodeAudit()
    src = src if src is not None else io.BytesIO(case.archive_bytes)
    source_stream = decode._open_source(src, audit)
    close_stream = not isinstance(src, io.BytesIO)
    original_size = decode.EXPECTED_PARAMETER_SIZE
    original_sha = decode.EXPECTED_PARAMETER_SHA256
    try:
        identity_stream = decode._AuditedRawStream(source_stream, audit, "identity")
        observed_size, observed_sha256 = decode._hash_raw(identity_stream, audit)
        if (observed_size, observed_sha256) != (
            case.expected_size,
            case.expected_sha256,
        ):
            raise AssertionError("synthetic fixture identity drift")
        decode._assert_source_stable(identity_stream, audit)
        identity_stream.seek(0)
        decode.EXPECTED_PARAMETER_SIZE = case.parameter_size
        decode.EXPECTED_PARAMETER_SHA256 = parameter_sha256 or case.parameter_sha256
        gzip_stream = decode._AuditedRawStream(source_stream, audit, "gzip")
        with gzip.GzipFile(fileobj=gzip_stream, mode="rb") as gz:
            payload = decode._read_parameter_member(gz, audit)
        decode._assert_source_stable(gzip_stream, audit)
    finally:
        decode.EXPECTED_PARAMETER_SIZE = original_size
        decode.EXPECTED_PARAMETER_SHA256 = original_sha
        if close_stream:
            source_stream.close()
    device, partitions = decode.parse_parameter(payload)
    identity = {
        "sizeBytes": observed_size,
        "sha256": observed_sha256,
        "identityMatch": True,
    }
    return identity, device, partitions, audit


class IdentityAndStreamingTests(unittest.TestCase):
    def _assert_special_source_rejected_before_read(self, path):
        audit = decode.DecodeAudit()
        with self.assertRaises(decode.DecodeFailure) as caught:
            decode.decode_archive(path, audit)
        self.assertEqual(
            caught.exception.code, decode.PD012_SOURCE_NOT_STABLE_REGULAR_FILE
        )
        self.assertEqual(audit.raw_bytes_read, 0)
        self.assertEqual(audit.tar_headers_inspected, 0)

    def test_identity_gate_precedes_archive_and_parameter_processing(self):
        case = fixtures.archive()
        audit = decode.DecodeAudit()
        with self.assertRaises(decode.DecodeFailure) as caught:
            decode.decode_archive(io.BytesIO(case.archive_bytes), audit)
        self.assertEqual(caught.exception.code, decode.PD001_IDENTITY_MISMATCH)
        self.assertEqual(audit.tar_headers_inspected, 0)
        self.assertEqual(audit.parameter_bytes_returned_to_decoder, 0)

    def test_streams_only_to_parameter_and_returns_only_parameter_body(self):
        case = fixtures.archive()
        identity, device, rows, audit = _decode_case(case)
        self.assertTrue(identity["identityMatch"])
        self.assertEqual(device, "rk29xxnand")
        self.assertEqual(len(rows), 3)
        self.assertEqual(audit.tar_headers_inspected, 2)
        self.assertEqual(audit.non_parameter_member_spans_stream_discarded, 1)
        self.assertEqual(audit.parameter_bytes_returned_to_decoder, case.parameter_size)
        self.assertEqual(audit.identity_pass_raw_bytes_read, case.expected_size)
        self.assertEqual(audit.gzip_pass_raw_bytes_read, case.expected_size)
        self.assertEqual(audit.raw_bytes_read, 2 * case.expected_size)
        self.assertLessEqual(audit.max_observed_read_chunk, decode.MAX_READ_CHUNK)

    def test_raw_stream_wrapper_counts_read_and_readinto_by_pass(self):
        audit = decode.DecodeAudit()
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

    def test_path_and_memory_sources_decode_identically(self):
        case = fixtures.archive()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "different-locator-name.tar.gz")
            with open(path, "wb") as handle:
                handle.write(case.archive_bytes)
            from_path = _decode_case(case, src=path)
            from_memory = _decode_case(case)
        self.assertEqual(from_path[:3], from_memory[:3])

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

    def test_special_files_and_symlinks_fail_before_any_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            fifo = os.path.join(tmp, "archive.fifo")
            regular = os.path.join(tmp, "archive.bin")
            symlink = os.path.join(tmp, "archive.link")
            os.mkfifo(fifo)
            with open(regular, "wb") as handle:
                handle.write(b"regular")
            os.symlink(regular, symlink)
            for path in (tmp, fifo, symlink):
                with self.subTest(path_kind=path):
                    with mock.patch.object(
                        decode.os,
                        "open",
                        side_effect=AssertionError("special path must not be opened"),
                    ):
                        self._assert_special_source_rejected_before_read(path)

    def test_character_and_block_modes_are_rejected_without_opening_a_device(self):
        for mode in (stat.S_IFCHR, stat.S_IFBLK):
            with self.subTest(mode=mode):
                fake_stat = types.SimpleNamespace(st_mode=mode | 0o600)
                with mock.patch.object(decode.os, "lstat", return_value=fake_stat):
                    with mock.patch.object(
                        decode.os,
                        "open",
                        side_effect=AssertionError("device node must not be opened"),
                    ):
                        self._assert_special_source_rejected_before_read(
                            "synthetic-device-node"
                        )

    def test_replacement_race_is_rejected_after_nonblocking_nofollow_open(self):
        regular_stat = types.SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600,
            st_dev=1,
            st_ino=2,
            st_size=3,
            st_mtime_ns=4,
            st_ctime_ns=5,
        )
        fifo_stat = types.SimpleNamespace(st_mode=stat.S_IFIFO | 0o600)
        audit = decode.DecodeAudit()
        with mock.patch.object(decode.os, "lstat", return_value=regular_stat):
            with mock.patch.object(decode.os, "open", return_value=123) as open_call:
                with mock.patch.object(decode.os, "fstat", return_value=fifo_stat):
                    with mock.patch.object(decode.os, "close") as close_call:
                        with self.assertRaises(decode.DecodeFailure):
                            decode._open_source("race-target", audit)
        self.assertEqual(open_call.call_args.args[1], decode.SOURCE_OPEN_FLAGS)
        close_call.assert_called_once_with(123)

    def test_mode_gate_rejects_block_character_fifo_and_symlink_types(self):
        self.assertTrue(decode.SOURCE_OPEN_FLAGS & os.O_NOFOLLOW)
        self.assertTrue(decode.SOURCE_OPEN_FLAGS & os.O_NONBLOCK)
        self.assertTrue(decode.SOURCE_OPEN_FLAGS & os.O_CLOEXEC)
        self.assertTrue(decode._is_regular_file_mode(stat.S_IFREG | 0o600))
        for mode in (stat.S_IFBLK, stat.S_IFCHR, stat.S_IFIFO, stat.S_IFLNK):
            with self.subTest(mode=mode):
                self.assertFalse(decode._is_regular_file_mode(mode | 0o600))

    def test_regular_file_metadata_change_fails_stability_recheck(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "archive.bin")
            with open(path, "wb") as handle:
                handle.write(b"before")
            audit = decode.DecodeAudit()
            stream = decode._open_source(path, audit)
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
        payload = (
            b"CMDLINE:mtdparts=x:0x1@0x2(same),0x3@0x4(same)\n"
        )
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
        by_path = {row["path"]: row for row in result["members"]}
        self.assertEqual(by_path["boot.img"]["partition"], "boot")
        self.assertEqual(by_path["parameter.txt"]["status"], "notApplicable")
        self.assertIn("alias inference is forbidden", by_path["user-data.img"]["reason"])

    def test_invalid_inventory_is_rejected(self):
        inventory = fixtures.inventory()
        inventory["archiveSha256"] = "0" * 64
        with self.assertRaises(decode.DecodeFailure) as caught:
            decode.reconcile_members([], inventory)
        self.assertEqual(caught.exception.code, decode.PD011_INVENTORY_INVALID)


class EvidencePipelineTests(unittest.TestCase):
    def _valid_bundle(self):
        identity = {
            "sizeBytes": decode.EXPECTED_RAW_SIZE,
            "sha256": decode.EXPECTED_RAW_SHA256,
            "identityMatch": True,
        }
        rows = decode._expected_partition_rows()
        inventory, inventory_sha256 = decode.load_archived_inventory()
        reconciliation = decode.reconcile_members(rows, inventory)
        audit = decode.DecodeAudit(
            raw_bytes_read=(
                decode.EXPECTED_RAW_SIZE + decode.EXPECTED_GZIP_PASS_RAW_BYTES_READ
            ),
            identity_pass_raw_bytes_read=decode.EXPECTED_RAW_SIZE,
            gzip_pass_raw_bytes_read=decode.EXPECTED_GZIP_PASS_RAW_BYTES_READ,
            decompressed_bytes_streamed=(
                decode.EXPECTED_DECOMPRESSED_BYTES_TO_PARAMETER
            ),
            parameter_bytes_returned_to_decoder=decode.EXPECTED_PARAMETER_SIZE,
            max_observed_read_chunk=decode.MAX_READ_CHUNK,
            tar_headers_inspected=decode.EXPECTED_TAR_HEADERS_INSPECTED,
            non_parameter_member_spans_stream_discarded=(
                decode.EXPECTED_NON_PARAMETER_SPANS_DISCARDED
            ),
            non_parameter_member_contents_read=(
                decode.EXPECTED_NON_PARAMETER_SPANS_DISCARDED
            ),
            non_parameter_member_content_bytes_read=(
                decode.EXPECTED_NON_PARAMETER_CONTENT_BYTES_READ
            ),
            archive_open_modes=["rb"],
            archive_source_kind="regularFile",
            regular_file_gate_checks=decode.EXPECTED_REGULAR_FILE_GATE_CHECKS,
        )
        documents = {
            "partition-mapping.json": decode._partition_document(
                identity, "rk29xxnand", rows
            ),
            "member-reconciliation.json": decode._reconciliation_document(
                reconciliation, inventory_sha256
            ),
            "process-audit.json": decode._audit_document(audit),
        }
        decode.validate_evidence_bundle(documents)
        payloads = {
            name: decode._serialize(document) for name, document in documents.items()
        }
        payloads["summary.md"] = decode._summary(
            documents["partition-mapping.json"], reconciliation, payloads
        )
        return documents, payloads, audit

    def _build(self, out_dir):
        _, payloads, audit = self._valid_bundle()
        decode._write_evidence_set(out_dir, payloads, audit)
        return audit

    def test_writes_exact_allowlist_and_no_raw_text_or_other_member_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            audit = self._build(out)
            self.assertEqual(sorted(os.listdir(out)), sorted(decode.EVIDENCE_OUTPUTS))
            self.assertEqual(audit.writes_outside_allowed_outputs, 0)
            payloads = []
            for name in decode.EVIDENCE_OUTPUTS:
                with open(os.path.join(out, name), "rb") as handle:
                    payloads.append(handle.read())
            combined = b"".join(payloads)
        self.assertNotIn(b"TOP_SECRET_PARAMETER_RAW_VALUE", combined)
        self.assertNotIn(b"NON_PARAMETER_MEMBER_SECRET", combined)
        self.assertNotIn(b"AFTER_PARAMETER_SECRET", combined)

    def test_evidence_bytes_are_deterministic_and_output_dir_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = os.path.join(tmp, "locator-a-should-not-appear")
            second = os.path.join(tmp, "second")
            self._build(first)
            self._build(second)
            for name in decode.EVIDENCE_OUTPUTS:
                with open(os.path.join(first, name), "rb") as handle:
                    left = handle.read()
                with open(os.path.join(second, name), "rb") as handle:
                    right = handle.read()
                self.assertEqual(left, right, name)
                self.assertNotIn(b"locator-a-should-not-appear", left)

    def test_existing_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            with self.assertRaises(decode.DecodeToolError):
                self._build(out)

    def test_preflight_prevents_mixed_directory_when_only_summary_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            os.makedirs(out)
            summary = os.path.join(out, "summary.md")
            with open(summary, "wb") as handle:
                handle.write(b"old-summary\n")
            _, payloads, audit = self._valid_bundle()
            with self.assertRaises(decode.DecodeToolError):
                decode._write_evidence_set(out, payloads, audit)
            self.assertEqual(os.listdir(out), ["summary.md"])
            with open(summary, "rb") as handle:
                self.assertEqual(handle.read(), b"old-summary\n")
            self.assertEqual(audit.evidence_files_written, [])

    def test_summary_hashes_every_json_and_carries_scope_boundary(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            with open(os.path.join(out, "summary.md"), encoding="utf-8") as handle:
                summary = handle.read()
            for name in decode.EVIDENCE_OUTPUTS[:3]:
                with open(os.path.join(out, name), "rb") as handle:
                    self.assertIn(hashlib.sha256(handle.read()).hexdigest(), summary)
            self.assertIn("Non-authoritative", summary)
            self.assertIn("BLOCKED", summary)
            self.assertIn("no flash", summary)

    def test_closed_validation_rejects_tampered_scope(self):
        documents, _, _ = self._valid_bundle()
        document = json.loads(
            decode._serialize(documents["partition-mapping.json"]).decode("utf-8")
        )
        document["scope"]["authoritative"] = True
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence("partition-mapping.json", document)

    def test_mapping_validation_requires_exact_pinned_identity(self):
        documents, _, _ = self._valid_bundle()
        document = json.loads(
            decode._serialize(documents["partition-mapping.json"]).decode("utf-8")
        )
        document["archiveIdentity"] = {
            "identityMatch": True,
            "sizeBytes": 1,
            "sha256": "0" * 64,
        }
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence("partition-mapping.json", document)

    def test_reconciliation_validation_rejects_empty_zero_count_claim(self):
        documents, _, _ = self._valid_bundle()
        document = json.loads(
            decode._serialize(documents["member-reconciliation.json"]).decode("utf-8")
        )
        for key in (
            "inventoryMemberCount",
            "imageMemberCount",
            "mappedImageCount",
            "orphanImageCount",
            "orphanPartitionCount",
        ):
            document[key] = 0
        for key in ("members", "partitions", "orphanImageMembers", "orphanPartitions"):
            document[key] = []
        document["inventoryReference"]["memberCount"] = 0
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence("member-reconciliation.json", document)

    def test_process_audit_validation_pins_all_bounded_read_metrics(self):
        documents, _, _ = self._valid_bundle()
        mutations = {
            "pythonVersion": "99.0.0-fake",
            "configuredMaxReadChunkBytes": 1 << 40,
            "maxObservedReadChunkBytes": 1 << 40,
            "rawBytesRead": 0,
            "identityPassRawBytesRead": 0,
            "gzipPassRawBytesRead": decode.EXPECTED_GZIP_PASS_RAW_BYTES_READ + 1,
            "decompressedBytesStreamedThroughLocator": 0,
            "tarHeadersInspected": 0,
            "nonParameterMemberSpansStreamDiscarded": 0,
            "counterProvenance": {"readMetrics": "fabricated"},
            "potentialDeviceOpenPathCount": 0,
            "pathReplacementDeviceOpenRaceExcluded": True,
            "zeroDeviceAccessStaticProofSatisfied": True,
            "partitionAcceptanceBlockingReasons": [],
            "archiveLocator": "/secret/archive.tar.gz",
        }
        for field, value in mutations.items():
            with self.subTest(field=field):
                document = json.loads(
                    decode._serialize(documents["process-audit.json"]).decode("utf-8")
                )
                document[field] = value
                with self.assertRaises(decode.EvidenceValidationError):
                    decode.validate_evidence("process-audit.json", document)

    def test_bundle_validation_rejects_cross_document_partition_drift(self):
        documents, _, _ = self._valid_bundle()
        tampered = json.loads(decode._serialize(documents).decode("utf-8"))
        tampered["member-reconciliation.json"]["partitions"][0]["partition"] = "other"
        with self.assertRaises(decode.EvidenceValidationError):
            decode.validate_evidence_bundle(tampered)

    def test_production_build_evidence_has_no_test_identity_or_inventory_overrides(self):
        self.assertEqual(
            tuple(inspect.signature(decode.build_evidence).parameters),
            ("src", "out_dir"),
        )
        self.assertEqual(
            tuple(inspect.signature(decode.decode_archive).parameters),
            ("src", "audit"),
        )

    def test_cli_reports_blocked_after_writing_failure_evidence(self):
        audit = decode.DecodeAudit(
            evidence_files_written=list(decode.EVIDENCE_OUTPUTS)
        )
        stderr = io.StringIO()
        with mock.patch.object(decode, "build_evidence", return_value=audit):
            with mock.patch.object(decode.sys, "stderr", stderr):
                result = decode.main(["--archive", "ignored", "--out-dir", "ignored"])
        self.assertEqual(result, 3)
        self.assertIn("decode blocked", stderr.getvalue())


class StaticAuditTests(unittest.TestCase):
    ALLOWED_IMPORTS = {
        "decode.py": {
            "__future__",
            "argparse",
            "dataclasses",
            "gzip",
            "hashlib",
            "io",
            "json",
            "os",
            "re",
            "stat",
            "sys",
            "typing",
        },
        "fixtures.py": {"__future__", "gzip", "hashlib", "typing"},
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
        "getattr",
        "eval",
        "compile",
        "__import__",
    }
    BANNED_ATTRIBUTES = {
        "system",
        "popen",
        "exec",
        "execv",
        "execve",
        "execvp",
        "execvpe",
        "spawn",
        "posix_spawn",
        "posix_spawnp",
        "fork",
        "forkpty",
        "extract",
        "extractall",
    }
    ALLOWED_OS_CALLS = {
        "os.close",
        "os.fdopen",
        "os.fspath",
        "os.fstat",
        "os.lstat",
        "os.makedirs",
        "os.open",
        "os.path.abspath",
        "os.path.dirname",
        "os.path.join",
        "os.path.lexists",
    }
    PROCESS_CAPABLE_OS_CALLS = {
        "os.posix_spawn",
        "os.posix_spawnp",
        "os.execv",
        "os.execve",
        "os.execvp",
        "os.execvpe",
        "os.fork",
        "os.forkpty",
        "os.popen",
        "os.system",
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

    def test_imports_are_stdlib_allowlisted_and_external_stacks_absent(self):
        for filename, allowed in self.ALLOWED_IMPORTS.items():
            tree = self._tree(filename)
            imports = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imports.update(alias.name.split(".")[0] for alias in node.names)
                elif isinstance(node, ast.ImportFrom):
                    imports.add((node.module or "").split(".")[0])
            self.assertLessEqual(imports, allowed, filename)
            self.assertFalse(imports & self.BANNED_NAMES, filename)

    def test_no_process_network_transport_or_extraction_attributes(self):
        for filename in self.ALLOWED_IMPORTS:
            tree = self._tree(filename)
            for node in ast.walk(tree):
                if isinstance(node, ast.Attribute):
                    self.assertNotIn(node.attr, self.BANNED_ATTRIBUTES, filename)
                elif isinstance(node, ast.Name):
                    self.assertNotIn(node.id, self.BANNED_NAMES, filename)

    def test_os_import_and_actual_call_targets_are_strictly_allowlisted(self):
        tree = self._tree("decode.py")
        observed_os_calls = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name == "os":
                        self.assertIsNone(alias.asname)
            elif isinstance(node, ast.ImportFrom):
                self.assertNotEqual(node.module, "os")
            elif isinstance(node, ast.Call):
                target = self._call_target(node.func)
                if target is not None and target.startswith("os."):
                    self.assertIn(target, self.ALLOWED_OS_CALLS)
                    observed_os_calls.add(target)
        self.assertEqual(observed_os_calls, self.ALLOWED_OS_CALLS)

    def test_process_capable_os_regression_vectors_are_never_allowlisted(self):
        self.assertTrue(self.PROCESS_CAPABLE_OS_CALLS.isdisjoint(self.ALLOWED_OS_CALLS))
        for target in ("os.posix_spawnp", "os.execvp", "os.forkpty"):
            with self.subTest(target=target):
                tree = ast.parse(f"{target}('tool', ['tool'])")
                call = next(node for node in ast.walk(tree) if isinstance(node, ast.Call))
                self.assertNotIn(self._call_target(call.func), self.ALLOWED_OS_CALLS)

    def test_cli_exposes_no_identity_or_inventory_bypass(self):
        options = set()
        for action in decode.build_arg_parser()._actions:
            options.update(action.option_strings)
        self.assertEqual(options, {"-h", "--help", "--archive", "--out-dir"})

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
