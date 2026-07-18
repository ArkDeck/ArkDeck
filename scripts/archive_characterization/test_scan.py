"""Branch-complete tests for the DAYU200 characterization scanner.

Covers: every ARC001..ARC009 hazard code, multi-hazard precedence, the
positive classification, every failed condition, zero-sized required members,
member-order invariance, archive-locator independence, classifier input shape,
bounded reads for a large synthetic member, closed-schema validation,
overwrite refusal, deterministic evidence bytes, and a static import/AST audit
proving no subprocess/network/extraction/execution code path exists.
"""

from __future__ import annotations

import ast
import io
import json
import os
import tempfile
import unittest

import fixtures
import scan


def _scan_case(case, audit=None):
    return scan.scan_archive(
        io.BytesIO(case.archive_bytes),
        case.expected_size,
        case.expected_sha256,
        audit,
    )


def _rows(*triples):
    return [scan.ClassificationRow(path, kind, size) for path, kind, size in triples]


class HazardRejectionTests(unittest.TestCase):
    def test_every_hazard_fixture_rejects_with_its_fixed_code(self):
        for case in fixtures.hazard_cases():
            with self.subTest(vector=case.name):
                audit = scan.ScanAudit()
                with self.assertRaises(scan.ScanFailure) as caught:
                    _scan_case(case, audit)
                self.assertEqual(caught.exception.code, case.expected_code)
                self.assertEqual(audit.classify_calls, 0)

    def test_all_nine_codes_are_covered_by_the_suite(self):
        covered = {c.expected_code for c in fixtures.hazard_cases()}
        self.assertEqual(covered, set(scan.HAZARD_CODES))

    def test_absolute_path_variants(self):
        for case in fixtures.absolute_variant_cases():
            with self.subTest(vector=case.name):
                with self.assertRaises(scan.ScanFailure) as caught:
                    _scan_case(case)
                self.assertEqual(caught.exception.code, scan.ARC003_PATH_ABSOLUTE)

    def test_invalid_path_variants(self):
        for case in fixtures.invalid_path_variant_cases():
            with self.subTest(vector=case.name):
                with self.assertRaises(scan.ScanFailure) as caught:
                    _scan_case(case)
                self.assertEqual(caught.exception.code, scan.ARC005_PATH_INVALID)

    def test_gnu_magic_is_accepted(self):
        identity, members, _ = _scan_case(fixtures.gnu_magic_case())
        self.assertTrue(identity["identityMatch"])
        self.assertEqual([m.path for m in members], ["parameter.txt"])

    def test_identity_gate_runs_before_member_hazards(self):
        # A traversal archive with a wrong expected identity must fail ARC001.
        bad = fixtures.hazard_cases()[7]  # arc004-traversal
        self.assertEqual(bad.name, "arc004-traversal")
        with self.assertRaises(scan.ScanFailure) as caught:
            scan.scan_archive(io.BytesIO(bad.archive_bytes), bad.expected_size, "0" * 64)
        self.assertEqual(caught.exception.code, scan.ARC001_IDENTITY_MISMATCH)

    def test_run_hazard_suite_measures_every_vector_as_passed(self):
        audit = scan.ScanAudit()
        results = scan.run_hazard_suite(audit)
        self.assertEqual(len(results), audit.hazard_vectors_executed)
        for row in results:
            with self.subTest(vector=row["vector"]):
                self.assertTrue(row["passed"])
                self.assertTrue(row["rejectedBeforeClassification"])
                self.assertEqual(row["classifierCalls"], 0)


class InventoryTests(unittest.TestCase):
    def test_positive_inventory_is_physical_order_with_member_hashes(self):
        import hashlib

        identity, members, _ = _scan_case(fixtures.positive_case())
        expected_names = [name.decode() for name, _ in fixtures.POSITIVE_MEMBERS]
        self.assertEqual([m.path for m in members], expected_names)
        for member, (_, data) in zip(members, fixtures.POSITIVE_MEMBERS):
            self.assertEqual(member.kind, "regular")
            self.assertEqual(member.size, len(data))
            self.assertEqual(member.sha256, hashlib.sha256(data).hexdigest())
        self.assertEqual([m.index for m in members], list(range(len(members))))

    def test_source_path_and_bytesio_produce_identical_inventory(self):
        case = fixtures.positive_case()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "fixture.tar.gz")
            with open(path, "wb") as handle:
                handle.write(case.archive_bytes)
            from_path = scan.scan_archive(path, case.expected_size, case.expected_sha256)
            from_memory = _scan_case(case)
        self.assertEqual(from_path[0], from_memory[0])
        self.assertEqual(from_path[1], from_memory[1])

    def test_bounded_reads_for_large_member(self):
        case = fixtures.large_member_archive()
        audit = scan.ScanAudit()
        _, members, _ = _scan_case(case, audit)
        self.assertEqual(members[0].size, 3 * 1048576 + 123)
        self.assertGreater(audit.max_observed_read_chunk, 0)
        self.assertLessEqual(audit.max_observed_read_chunk, scan.MAX_READ_CHUNK)
        self.assertGreaterEqual(audit.uncompressed_bytes_read, members[0].size)


class ClassificationTests(unittest.TestCase):
    def _classify_archive(self, archive_bytes):
        case = fixtures.case("adhoc", archive_bytes, None)
        _, members, _ = _scan_case(case)
        return scan.classify(
            scan.ClassificationRow(m.path, m.kind, m.size) for m in members
        )

    def test_positive_archive_matches_rockchip_raw_image_set(self):
        result = self._classify_archive(fixtures.positive_archive())
        self.assertEqual(result["imagePackageFamily"], "rockchipRawImageSet")
        self.assertEqual(result["failedConditionIds"], [])
        self.assertEqual(
            [c["id"] for c in result["conditions"]], list(scan.CONDITION_IDS)
        )
        self.assertTrue(all(c["passed"] for c in result["conditions"]))

    def test_fixed_axes_are_always_present(self):
        for archive in (fixtures.positive_archive(), fixtures.positive_archive(omit=("uboot.img",))):
            result = self._classify_archive(archive)
            self.assertEqual(result["classificationScope"], "fixedArchiveOnly")
            self.assertFalse(result["authoritative"])
            self.assertEqual(result["deviceFlashProvider"], "unknown")
            self.assertEqual(result["targetCompatibility"], "unknown")
            self.assertEqual(result["imageProfileReadiness"], "candidateNonExecutable")
            self.assertFalse(result["executableProfile"])
            self.assertFalse(result["hardwareSupportClaim"])

    def test_missing_parameter_txt_fails_only_that_condition(self):
        result = self._classify_archive(fixtures.positive_archive(omit=("parameter.txt",)))
        self.assertEqual(result["imagePackageFamily"], "unknown")
        self.assertEqual(result["failedConditionIds"], ["PKG-RK-PARAMETER"])

    def test_missing_miniloader_fails_only_that_condition(self):
        result = self._classify_archive(
            fixtures.positive_archive(omit=("MiniLoaderAll.bin",))
        )
        self.assertEqual(result["failedConditionIds"], ["PKG-RK-MINILOADER"])

    def test_missing_uboot_fails_only_that_condition(self):
        result = self._classify_archive(fixtures.positive_archive(omit=("uboot.img",)))
        self.assertEqual(result["failedConditionIds"], ["PKG-RK-UBOOT"])

    def test_single_extra_image_fails_extra_images_condition(self):
        result = self._classify_archive(fixtures.positive_archive(omit=("system.img",)))
        self.assertEqual(result["failedConditionIds"], ["PKG-RK-EXTRA-IMAGES"])

    def test_unlisted_member_fails_allowlist_condition(self):
        result = self._classify_archive(
            fixtures.positive_archive(extra=((b"README.txt", b"R" * 8),))
        )
        self.assertEqual(result["failedConditionIds"], ["PKG-RK-ALLOWLIST"])

    def test_zero_sized_required_member_fails_root_regular_nonempty(self):
        result = self._classify_archive(
            fixtures.positive_archive(zero_size=("parameter.txt",))
        )
        self.assertEqual(result["imagePackageFamily"], "unknown")
        self.assertEqual(
            result["failedConditionIds"], ["PKG-RK-ROOT-REGULAR-NONEMPTY"]
        )
        # The anchor is still present exactly once.
        self.assertTrue(result["conditions"][1]["passed"])

    def test_nested_member_fails_root_level_condition(self):
        rows = _rows(
            ("parameter.txt", "regular", 1),
            ("MiniLoaderAll.bin", "regular", 1),
            ("uboot.img", "regular", 1),
            ("sub/boot.img", "regular", 1),
            ("system.img", "regular", 1),
        )
        result = scan.classify(rows)
        self.assertIn("PKG-RK-ROOT-REGULAR-NONEMPTY", result["failedConditionIds"])

    def test_empty_inventory_fails_the_three_anchors_and_extra_images(self):
        result = scan.classify([])
        self.assertEqual(result["imagePackageFamily"], "unknown")
        self.assertEqual(
            result["failedConditionIds"],
            ["PKG-RK-PARAMETER", "PKG-RK-MINILOADER", "PKG-RK-UBOOT", "PKG-RK-EXTRA-IMAGES"],
        )

    def test_failed_ids_report_every_failure_in_fixed_order(self):
        rows = _rows(("nested/readme.doc", "regular", 0))
        result = scan.classify(rows)
        self.assertEqual(
            result["failedConditionIds"],
            [
                "PKG-RK-ROOT-REGULAR-NONEMPTY",
                "PKG-RK-PARAMETER",
                "PKG-RK-MINILOADER",
                "PKG-RK-UBOOT",
                "PKG-RK-EXTRA-IMAGES",
                "PKG-RK-ALLOWLIST",
            ],
        )

    def test_member_order_invariance(self):
        rows = _rows(
            ("parameter.txt", "regular", 1),
            ("MiniLoaderAll.bin", "regular", 1),
            ("uboot.img", "regular", 1),
            ("boot_linux.img", "regular", 1),
            ("system.img", "regular", 1),
        )
        self.assertEqual(scan.classify(rows), scan.classify(list(reversed(rows))))

    def test_classifier_rejects_non_projection_rows(self):
        with self.assertRaises(TypeError):
            scan.classify([("parameter.txt", "regular", 1)])
        with self.assertRaises(TypeError):
            scan.classify([{"path": "parameter.txt", "kind": "regular", "size": 1}])

    def test_projection_shape_is_exactly_path_kind_size(self):
        self.assertEqual(scan.ClassificationRow._fields, ("path", "kind", "size"))


class EvidencePipelineTests(unittest.TestCase):
    def _build(self, out_dir, case=None):
        case = case or fixtures.positive_case()
        return scan.build_evidence(
            io.BytesIO(case.archive_bytes),
            out_dir,
            case.expected_size,
            case.expected_sha256,
        )

    def test_pipeline_writes_exactly_the_five_allowed_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            audit = self._build(out)
            self.assertEqual(sorted(os.listdir(out)), sorted(scan.EVIDENCE_OUTPUTS))
            self.assertEqual(audit.evidence_files_written, list(scan.EVIDENCE_OUTPUTS))
            self.assertEqual(audit.writes_outside_allowed_outputs, 0)

    def test_every_json_output_validates_against_its_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            for name in scan._SCHEMA_FILES:
                with open(os.path.join(out, name), "rb") as handle:
                    document = json.loads(handle.read().decode("utf-8"))
                scan.validate_schema(document, scan._load_schema(name))

    def test_evidence_bytes_are_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            first, second = os.path.join(tmp, "a"), os.path.join(tmp, "b")
            self._build(first)
            self._build(second)
            for name in scan.EVIDENCE_OUTPUTS:
                with open(os.path.join(first, name), "rb") as handle:
                    left = handle.read()
                with open(os.path.join(second, name), "rb") as handle:
                    right = handle.read()
                self.assertEqual(left, right, name)

    def test_evidence_is_locator_independent(self):
        case = fixtures.positive_case()
        with tempfile.TemporaryDirectory() as tmp:
            locations = []
            for label in ("first-name.tar.gz", "second-name.tar.gz"):
                directory = os.path.join(tmp, label + ".dir")
                os.makedirs(directory)
                path = os.path.join(directory, label)
                with open(path, "wb") as handle:
                    handle.write(case.archive_bytes)
                out = os.path.join(tmp, label + ".evidence")
                scan.build_evidence(path, out, case.expected_size, case.expected_sha256)
                locations.append(out)
            for name in scan.EVIDENCE_OUTPUTS:
                with open(os.path.join(locations[0], name), "rb") as handle:
                    left = handle.read()
                with open(os.path.join(locations[1], name), "rb") as handle:
                    right = handle.read()
                self.assertEqual(left, right, name)
                if name != "summary.md":
                    self.assertNotIn(b"first-name", left)
                    self.assertNotIn(b"tar.gz", left)

    def test_existing_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            with open(os.path.join(out, "archive-identity.json"), "rb") as handle:
                original = handle.read()
            with self.assertRaises(scan.ScanToolError):
                self._build(out)
            with open(os.path.join(out, "archive-identity.json"), "rb") as handle:
                self.assertEqual(handle.read(), original)

    def test_hazard_input_writes_no_evidence(self):
        case = [c for c in fixtures.hazard_cases() if c.name == "arc003-absolute-path"][0]
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            with self.assertRaises(scan.ScanFailure):
                self._build(out, case=case)
            self.assertFalse(os.path.exists(out))

    def test_summary_records_hashes_of_the_four_json_results(self):
        import hashlib

        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            with open(os.path.join(out, "summary.md"), "r", encoding="utf-8") as handle:
                summary = handle.read()
            for name in scan._SCHEMA_FILES:
                with open(os.path.join(out, name), "rb") as handle:
                    digest = hashlib.sha256(handle.read()).hexdigest()
                self.assertIn(digest, summary)

    def test_schema_validator_rejects_tampered_documents(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "evidence")
            self._build(out)
            with open(os.path.join(out, "package-classification.json"), "rb") as handle:
                document = json.loads(handle.read().decode("utf-8"))
        schema = scan._load_schema("package-classification.json")
        tampered = dict(document, authoritative=True)
        with self.assertRaises(scan.SchemaValidationError):
            scan.validate_schema(tampered, schema)
        extra_key = dict(document, hardwareClaim="yes")
        with self.assertRaises(scan.SchemaValidationError):
            scan.validate_schema(extra_key, schema)


class StaticAuditTests(unittest.TestCase):
    ALLOWED_IMPORTS = {
        "scan.py": {
            "__future__",
            "argparse",
            "dataclasses",
            "fixtures",
            "gzip",
            "hashlib",
            "io",
            "json",
            "os",
            "posixpath",
            "re",
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
        "shutil",
        "tarfile",
        "tempfile",
        "zipfile",
    }
    BANNED_ATTRIBUTES = {"system", "popen", "exec", "execv", "execve", "spawn", "fork"}

    def _module_tree(self, filename):
        directory = os.path.dirname(os.path.abspath(scan.__file__))
        with open(os.path.join(directory, filename), "rb") as handle:
            return ast.parse(handle.read().decode("utf-8"))

    def test_imports_are_stdlib_allowlisted(self):
        for filename, allowed in self.ALLOWED_IMPORTS.items():
            tree = self._module_tree(filename)
            imported = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported.update(alias.name.split(".")[0] for alias in node.names)
                elif isinstance(node, ast.ImportFrom):
                    imported.add((node.module or "").split(".")[0])
            self.assertLessEqual(imported, allowed, filename)
            self.assertFalse(imported & self.BANNED_NAMES, filename)

    def test_no_process_or_execution_attributes(self):
        for filename in self.ALLOWED_IMPORTS:
            tree = self._module_tree(filename)
            for node in ast.walk(tree):
                if isinstance(node, ast.Attribute):
                    self.assertNotIn(node.attr, self.BANNED_ATTRIBUTES, filename)
                if isinstance(node, ast.Name):
                    self.assertNotIn(node.id, self.BANNED_NAMES, filename)

    def test_cli_exposes_no_identity_bypass(self):
        parser = scan.build_arg_parser()
        option_strings = set()
        for action in parser._actions:
            option_strings.update(action.option_strings)
        self.assertEqual(option_strings, {"-h", "--help", "--archive", "--out-dir"})

    def test_production_identity_constants_are_pinned(self):
        self.assertEqual(scan.EXPECTED_RAW_SIZE, 732948803)
        self.assertEqual(
            scan.EXPECTED_RAW_SHA256,
            "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280",
        )
        self.assertEqual(scan.MAX_READ_CHUNK, 1048576)


if __name__ == "__main__":
    unittest.main()
