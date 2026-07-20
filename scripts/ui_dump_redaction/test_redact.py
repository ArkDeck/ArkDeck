"""Contract tests for uidump-derived-redaction-v1.

All vectors are synthetic. The suite performs no HDC, device, network, GUI, or
real-capture operation and writes only to per-test temporary directories.
"""

from __future__ import annotations

import ast
import dataclasses
import hashlib
import importlib.util
import json
import os
import pathlib
import random
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SCRIPT = SCRIPT_DIR / "redact.py"
MANIFEST = SCRIPT_DIR / "algorithm-v1.json"
SAFE_LITERALS = SCRIPT_DIR / "safe-literals-v1.txt"
SCHEMA = SCRIPT_DIR / "redaction-receipt.schema.json"

spec = importlib.util.spec_from_file_location("ui_dump_redact", SCRIPT)
assert spec is not None and spec.loader is not None
redact = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = redact
spec.loader.exec_module(redact)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class RedactorContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest, cls.manifest_bytes = redact.load_manifest(MANIFEST)
        cls.safe_literals, cls.safe_literal_bytes = redact.load_safe_literals(
            SAFE_LITERALS, cls.manifest
        )
        cls.schema, cls.schema_bytes = redact.load_receipt_schema(cls.manifest)

    def transform(self, raw: bytes):
        return redact.transform(raw, self.safe_literals, self.manifest)

    def invoke(
        self,
        directory: pathlib.Path,
        raw: bytes,
        *,
        expected_hash: str | None = None,
        input_flag: str = "--input",
        input_path: pathlib.Path | None = None,
        output_path: pathlib.Path | None = None,
        receipt_path: pathlib.Path | None = None,
        manifest_path: pathlib.Path = MANIFEST,
        safe_literals_path: pathlib.Path = SAFE_LITERALS,
    ):
        source = input_path or directory / "controlled-raw.bin"
        if input_path is None:
            source.write_bytes(raw)
        output = output_path or directory / "derived.txt"
        receipt = receipt_path or directory / "receipt.json"
        argv = [
            sys.executable,
            str(SCRIPT),
            "--algorithm-manifest",
            str(manifest_path),
            "--safe-literals",
            str(safe_literals_path),
            input_flag,
            str(source),
            "--expected-input-sha256",
            expected_hash or sha256(raw),
            "--output",
            str(output),
            "--receipt",
            str(receipt),
        ]
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return completed, source, output, receipt

    def test_cli_rejects_abbreviated_option_names_without_outputs(self):
        raw = b"text=secret\n"
        with tempfile.TemporaryDirectory(prefix="ud-redactor-argv-") as temporary:
            completed, source, output, receipt = self.invoke(
                pathlib.Path(temporary), raw, input_flag="--inp"
            )
            self.assert_failure_without_artifacts(completed, output, receipt, 2)
            self.assertEqual(source.read_bytes(), raw)

    def assert_failure_without_artifacts(
        self, completed, output: pathlib.Path, receipt: pathlib.Path, code: int
    ):
        self.assertEqual(completed.returncode, code, completed.stderr.decode("ascii"))
        self.assertFalse(output.exists())
        self.assertFalse(receipt.exists())
        self.assertEqual(completed.stdout, b"")

    def test_success_normalizes_lines_redacts_all_content_and_writes_closed_receipt(self):
        raw = (
            b'Root: com.example.waterflowdemo windowId=123456 '
            b'path=/Users/alice/demo text="Account Balance" true\r\n'
            b'Root: com.example.waterflowdemo serial=ABC123 false null\r'
        )
        with tempfile.TemporaryDirectory(prefix="ud-redactor-success-") as temporary:
            completed, source, output, receipt_path = self.invoke(
                pathlib.Path(temporary), raw
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode("ascii"))
            derived = output.read_bytes()
            receipt = json.loads(receipt_path.read_text(encoding="ascii"))

            for sensitive in (
                b"Root",
                b"com.example.waterflowdemo",
                b"123456",
                b"/Users/alice/demo",
                b"Account",
                b"Balance",
                b"ABC123",
                b"true",
                b"false",
                b"null",
            ):
                self.assertNotIn(sensitive, derived)
            self.assertTrue(derived.endswith(b"\n"))
            self.assertNotIn(b"\r", derived)
            derived.decode("ascii")

            self.assertEqual(receipt["raw"], {"sha256": sha256(raw), "size": len(raw)})
            self.assertEqual(
                receipt["derived"],
                {"sha256": sha256(derived), "size": len(derived)},
            )
            self.assertEqual(
                receipt["normalization"]["lineEndings"],
                {"lf": 0, "crlf": 1, "cr": 1},
            )
            self.assertGreater(receipt["replacements"]["total"], 0)
            self.assertTrue(receipt["outputSideCheck"]["passed"])
            self.assertEqual(len(receipt["replay"]["argv"]), 14)
            self.assertEqual(receipt["replay"]["argv"][9], sha256(raw))
            self.assertNotIn(str(pathlib.Path(temporary)), json.dumps(receipt))
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(receipt_path.stat().st_mode), 0o600)
            redact.validate_receipt(
                receipt,
                self.schema,
                raw=raw,
                result=self.transform(raw),
                manifest=self.manifest,
                manifest_bytes=self.manifest_bytes,
                safe_literal_bytes=self.safe_literal_bytes,
                schema_bytes=self.schema_bytes,
            )

    def test_duplicate_tokens_reuse_first_typed_ordinal_and_order_is_preserved(self):
        result = self.transform(b"alpha 7 alpha\nbeta alpha 7\n")
        self.assertEqual(
            result.derived,
            b"@R-ID-000001@ @R-NU-000001@ @R-ID-000001@\n"
            b"@R-ID-000002@ @R-ID-000001@ @R-NU-000001@\n",
        )
        self.assertEqual(result.replacement_total, 6)
        self.assertEqual(result.replacement_unique, 3)
        self.assertEqual(result.unique_by_type["ID"], 2)
        self.assertEqual(result.unique_by_type["NU"], 1)

    def test_context_free_boolean_and_null_atoms_are_always_redacted(self):
        self.assertEqual(self.safe_literals, frozenset())
        result = self.transform(b"text=true text=false text=null\n")
        self.assertEqual(
            result.derived,
            b"@R-ID-000001@ = @R-ID-000002@ "
            b"@R-ID-000001@ = @R-ID-000003@ "
            b"@R-ID-000001@ = @R-ID-000004@\n",
        )
        for literal in (b"text", b"true", b"false", b"null"):
            self.assertNotIn(literal, result.derived)

    def test_all_sensitive_classes_and_unicode_page_text_become_typed_placeholders(self):
        raw = (
            "com.example.application EntryAbility HomePage Window42 Component77 "
            "/data/app/private SERIAL-00001234567890 98765432101234567890 "
            "账户余额 \"quoted page text\"\n"
        ).encode("utf-8")
        result = self.transform(raw)
        self.assertEqual(result.derived.decode("ascii").count("@R-"), 10)
        for code in ("PK", "ID", "PA", "NU", "TX", "QU"):
            self.assertGreater(result.replacements_by_type[code], 0)
        for token in raw.decode("utf-8").replace("\n", " ").split():
            self.assertNotIn(token.encode("utf-8"), result.derived)

    def test_json_quoted_escaping_is_validated_and_decoded_value_is_never_retained(self):
        result = self.transform(b'key="line \\"quoted\\" and \\u4e2d\\u6587"\n')
        self.assertIn(b'"@R-QU-000001@"', result.derived)
        self.assertNotIn(b"quoted", result.derived)
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_TOKEN"):
            self.transform(b'key="bad \\q escape"\n')
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_UNICODE"):
            self.transform(b'key="bidi \\u202e"\n')
        for escaped_control in (b"\\n", b"\\r", b"\\t", b"\\b", b"\\f", b"\\u000a"):
            with self.subTest(escaped_control=escaped_control):
                raw = b'key="line' + escaped_control + b'secret"\n'
                with self.assertRaisesRegex(redact.RedactionError, "INVALID_UNICODE"):
                    self.transform(raw)

    def test_invalid_utf8_control_bidi_confusable_and_non_nfc_fail_closed(self):
        vectors = {
            "invalid-utf8": b"name=\xff\n",
            "nul": b"name=bad\x00value\n",
            "tab": b"name\tvalue\n",
            "other-control": b"name=bad\x1fvalue\n",
            "bidi": "name=ab\u202ecd\n".encode("utf-8"),
            "confusable": "name=p\u0430ge\n".encode("utf-8"),
            "non-nfc": "name=Cafe\u0301\n".encode("utf-8"),
            "unassigned": "name=\u0378\n".encode("utf-8"),
        }
        for name, raw in vectors.items():
            with self.subTest(name=name):
                with self.assertRaises(redact.RedactionError):
                    self.transform(raw)

    def test_unknown_reserved_placeholder_and_malformed_line_fail_closed(self):
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_TOKEN"):
            self.transform(b"@R-ID-000001@\n")
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_LINE"):
            self.transform(b'name="unterminated\n')
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_LINE"):
            self.transform(b"   \n")
        oversized_line = b"secret " + (b"[" * (self.manifest["limits"]["tokensPerLine"] + 1))
        with self.assertRaisesRegex(redact.RedactionError, "INVALID_LINE"):
            self.transform(oversized_line)

    def test_resource_limits_reject_overlong_token_and_input(self):
        token = b"a" * (self.manifest["limits"]["tokenBytes"] + 1)
        with self.assertRaisesRegex(redact.RedactionError, "RESOURCE_LIMIT"):
            self.transform(token + b"\n")
        with tempfile.TemporaryDirectory(prefix="ud-redactor-large-") as temporary:
            directory = pathlib.Path(temporary)
            raw = b"a" * (self.manifest["limits"]["inputBytes"] + 1)
            completed, _source, output, receipt = self.invoke(directory, raw)
            self.assert_failure_without_artifacts(
                completed,
                output,
                receipt,
                redact.ERROR_CODES["INPUT_TOO_LARGE"],
            )

    def test_expected_input_hash_drift_fails_without_outputs_and_raw_is_unchanged(self):
        raw = b"serial ABC123\n"
        with tempfile.TemporaryDirectory(prefix="ud-redactor-hash-") as temporary:
            directory = pathlib.Path(temporary)
            completed, source, output, receipt = self.invoke(
                directory, raw, expected_hash="0" * 64
            )
            self.assert_failure_without_artifacts(
                completed,
                output,
                receipt,
                redact.ERROR_CODES["INPUT_HASH_MISMATCH"],
            )
            self.assertEqual(source.read_bytes(), raw)
            self.assertEqual(sha256(source.read_bytes()), sha256(raw))

    def test_path_conflicts_stdin_and_preexisting_outputs_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ud-redactor-path-") as temporary:
            directory = pathlib.Path(temporary)
            raw_path = directory / "raw"
            raw_path.write_bytes(b"secret\n")
            for output, receipt in (
                (raw_path, directory / "receipt"),
                (directory / "derived", raw_path),
                (directory / "same", directory / "same"),
            ):
                with self.subTest(output=output.name, receipt=receipt.name):
                    with self.assertRaisesRegex(redact.RedactionError, "PATH_CONFLICT"):
                        redact.validate_paths(str(raw_path), str(output), str(receipt))
            with self.assertRaisesRegex(redact.RedactionError, "PATH_CONFLICT"):
                redact.validate_paths("-", str(directory / "derived"), str(directory / "receipt"))

            existing_output = directory / "existing"
            existing_output.write_bytes(b"sentinel")
            completed, _source, output, receipt = self.invoke(
                directory,
                b"secret\n",
                output_path=existing_output,
                receipt_path=directory / "new-receipt",
            )
            self.assertEqual(completed.returncode, redact.ERROR_CODES["OUTPUT_EXISTS"])
            self.assertEqual(output.read_bytes(), b"sentinel")
            self.assertFalse(receipt.exists())

    def test_every_resolved_data_path_must_be_outside_repository_root(self):
        self.assertEqual(redact._REPOSITORY_ROOT, SCRIPT_DIR.parent.parent)
        with tempfile.TemporaryDirectory(prefix="ud-redactor-repo-boundary-") as temporary:
            directory = pathlib.Path(temporary)
            outside_input = directory / "raw"
            outside_input.write_bytes(b"secret\n")
            outside_output = directory / "derived"
            outside_receipt = directory / "receipt"
            repository_paths = (
                redact._REPOSITORY_ROOT / "AGENTS.md",
                SCRIPT_DIR / "forbidden-derived.tmp",
                SCRIPT_DIR / "forbidden-receipt.tmp",
            )
            vectors = (
                (repository_paths[0], outside_output, outside_receipt),
                (outside_input, repository_paths[1], outside_receipt),
                (outside_input, outside_output, repository_paths[2]),
            )
            for name, paths in zip(("input", "output", "receipt"), vectors, strict=True):
                with self.subTest(name=name):
                    with self.assertRaisesRegex(redact.RedactionError, "PATH_CONFLICT"):
                        redact.validate_paths(*(str(path) for path in paths))

            repository_link = directory / "repository-link"
            repository_link.symlink_to(redact._REPOSITORY_ROOT, target_is_directory=True)
            with self.assertRaisesRegex(redact.RedactionError, "PATH_CONFLICT"):
                redact.validate_paths(
                    str(outside_input),
                    str(repository_link / "symlinked-derived.tmp"),
                    str(outside_receipt),
                )

            raw = MANIFEST.read_bytes()
            completed, _source, output, receipt = self.invoke(
                directory,
                raw,
                input_path=MANIFEST,
                expected_hash=sha256(raw),
                output_path=outside_output,
                receipt_path=outside_receipt,
            )
            self.assert_failure_without_artifacts(
                completed,
                output,
                receipt,
                redact.ERROR_CODES["PATH_CONFLICT"],
            )

    def test_receipt_write_failure_rolls_back_new_derived_file(self):
        with tempfile.TemporaryDirectory(prefix="ud-redactor-rollback-") as temporary:
            directory = pathlib.Path(temporary)
            output = directory / "derived"
            receipt = directory / "missing-parent" / "receipt"
            completed, _source, _output, _receipt = self.invoke(
                directory,
                b"secret\n",
                output_path=output,
                receipt_path=receipt,
            )
            self.assertEqual(completed.returncode, redact.ERROR_CODES["IO_ERROR"])
            self.assertFalse(output.exists())
            self.assertFalse(receipt.exists())

    def test_manifest_allowlist_and_receipt_schema_drift_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ud-redactor-drift-") as temporary:
            directory = pathlib.Path(temporary)
            altered_manifest = directory / "algorithm.json"
            document = json.loads(MANIFEST.read_text(encoding="utf-8"))
            document["limits"]["tokens"] += 1
            altered_manifest.write_text(json.dumps(document), encoding="utf-8")
            completed, _source, output, receipt = self.invoke(
                directory, b"secret\n", manifest_path=altered_manifest
            )
            self.assert_failure_without_artifacts(
                completed,
                output,
                receipt,
                redact.ERROR_CODES["MANIFEST_INVALID"],
            )

            altered_literals = directory / "safe.txt"
            altered_literals.write_bytes(SAFE_LITERALS.read_bytes() + b"Window\n")
            second = directory / "second"
            second.mkdir()
            completed, _source, output, receipt = self.invoke(
                second, b"secret\n", safe_literals_path=altered_literals
            )
            self.assert_failure_without_artifacts(
                completed,
                output,
                receipt,
                redact.ERROR_CODES["ALLOWLIST_INVALID"],
            )

            altered_schema = directory / "receipt.schema.json"
            altered_schema.write_bytes(SCHEMA.read_bytes() + b" ")
            with mock.patch.object(redact, "_RECEIPT_SCHEMA_PATH", altered_schema):
                with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
                    redact.load_receipt_schema(self.manifest)

    def test_duplicate_json_keys_and_noncanonical_safe_literal_order_are_rejected(self):
        duplicate = b'{"schema":"one","schema":"two"}'
        with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
            redact._load_json(duplicate, "MANIFEST_INVALID")
        with tempfile.TemporaryDirectory(prefix="ud-redactor-literals-") as temporary:
            path = pathlib.Path(temporary) / "safe.txt"
            data = b"true\nnull\nfalse\n"
            path.write_bytes(data)
            manifest = json.loads(json.dumps(self.manifest))
            manifest["hashPins"]["safeLiteralsSha256"] = sha256(data)
            with self.assertRaisesRegex(redact.RedactionError, "ALLOWLIST_INVALID"):
                redact.load_safe_literals(path, manifest)

    def test_independent_output_gate_detects_literal_path_key_and_shape_survivors(self):
        vectors = (
            b"secret\n",
            b"/Users/alice/private\n",
            b"-----BEGIN PRIVATE KEY-----\n",
            b'"secret"\n',
        )
        for derived in vectors:
            with self.subTest(derived=derived):
                with self.assertRaisesRegex(redact.RedactionError, "SENSITIVE_OUTPUT"):
                    redact.assert_output_clean(derived, self.safe_literals, {"secret"})

    def test_receipt_validator_rejects_tampering_and_extra_fields(self):
        raw = b"alpha 42\n"
        result = self.transform(raw)
        receipt = redact.build_receipt(
            raw=raw,
            result=result,
            manifest=self.manifest,
            manifest_bytes=self.manifest_bytes,
            safe_literal_bytes=self.safe_literal_bytes,
            schema_bytes=self.schema_bytes,
            completed_at="2026-07-20T12:00:00Z",
        )
        redact.validate_receipt(
            receipt,
            self.schema,
            raw=raw,
            result=result,
            manifest=self.manifest,
            manifest_bytes=self.manifest_bytes,
            safe_literal_bytes=self.safe_literal_bytes,
            schema_bytes=self.schema_bytes,
        )
        pristine_receipt = json.loads(json.dumps(receipt))
        tampered = json.loads(json.dumps(receipt))
        tampered["unexpected"] = True
        with self.assertRaises(redact.SchemaValidationError):
            redact.validate_schema(tampered, self.schema, self.schema)
        tampered = json.loads(json.dumps(receipt))
        tampered["derived"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
            redact.validate_receipt(
                tampered,
                self.schema,
                raw=raw,
                result=result,
                manifest=self.manifest,
                manifest_bytes=self.manifest_bytes,
                safe_literal_bytes=self.safe_literal_bytes,
                schema_bytes=self.schema_bytes,
            )
        original_lf_count = result.line_endings["lf"]
        receipt["normalization"]["lineEndings"]["lf"] += 100
        self.assertEqual(
            result.line_endings["lf"],
            original_lf_count,
            "receipt dictionaries must not alias TransformResult dictionaries",
        )
        with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
            redact.validate_receipt(
                receipt,
                self.schema,
                raw=raw,
                result=result,
                manifest=self.manifest,
                manifest_bytes=self.manifest_bytes,
                safe_literal_bytes=self.safe_literal_bytes,
                schema_bytes=self.schema_bytes,
            )
        receipt = pristine_receipt
        statistic_paths = (
            ("replacements", "total"),
            ("replacements", "unique"),
            ("replacements", "byType", "ID"),
            ("replacements", "uniqueByType", "ID"),
            ("normalization", "lineEndings", "lf"),
            ("normalization", "lineCount"),
            ("normalization", "tokenCount"),
            ("outputSideCheck", "checkedSensitiveLiterals"),
        )
        for path in statistic_paths:
            with self.subTest(path=path):
                tampered = json.loads(json.dumps(receipt))
                target = tampered
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] += 100
                with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
                    redact.validate_receipt(
                        tampered,
                        self.schema,
                        raw=raw,
                        result=result,
                        manifest=self.manifest,
                        manifest_bytes=self.manifest_bytes,
                        safe_literal_bytes=self.safe_literal_bytes,
                        schema_bytes=self.schema_bytes,
                    )
        inconsistent_result = dataclasses.replace(
            result, replacement_total=result.replacement_total + 1
        )
        with self.assertRaisesRegex(redact.RedactionError, "MANIFEST_INVALID"):
            redact.validate_receipt(
                receipt,
                self.schema,
                raw=raw,
                result=inconsistent_result,
                manifest=self.manifest,
                manifest_bytes=self.manifest_bytes,
                safe_literal_bytes=self.safe_literal_bytes,
                schema_bytes=self.schema_bytes,
            )

    def test_repeated_cli_runs_are_byte_deterministic_without_real_paths_in_receipts(self):
        raw = b"Node id=77 text=synthetic Node id=77\n"
        derived_payloads = []
        for index in range(2):
            with tempfile.TemporaryDirectory(
                prefix=f"ud-redactor-determinism-{index}-"
            ) as temporary:
                completed, _source, output, receipt = self.invoke(
                    pathlib.Path(temporary), raw
                )
                self.assertEqual(completed.returncode, 0, completed.stderr.decode("ascii"))
                derived_payloads.append(output.read_bytes())
                receipt_text = receipt.read_text(encoding="ascii")
                self.assertNotIn(temporary, receipt_text)
        self.assertEqual(derived_payloads[0], derived_payloads[1])
        self.assertEqual(sha256(derived_payloads[0]), sha256(derived_payloads[1]))

    def test_seeded_property_vectors_are_deterministic_and_literal_free(self):
        generator = random.Random(0xA7D3C)
        packages = ["com.example.alpha", "org.synthetic.beta", "io.fixture.gamma"]
        identifiers = ["Window77", "EntryAbility", "Component991", "SERIALABC123"]
        paths = ["/data/app/private", "/Users/tester/page", "~/fixture/path"]
        texts = ["hello!", "sample@example", "页面文本", "synthetic-value"]
        lines = []
        sensitive = set()
        for _ in range(250):
            values = [
                generator.choice(packages),
                generator.choice(identifiers),
                generator.choice(paths),
                str(generator.randrange(10**12, 10**15)),
                generator.choice(texts),
            ]
            if generator.randrange(2):
                values.append(json.dumps(generator.choice(texts), ensure_ascii=False))
            if generator.randrange(3) == 0:
                values.extend(["true", "false", "null"])
            lines.append(" [ " + " , ".join(values) + " ] ")
            sensitive.update(value.strip('"') for value in values)
        raw = ("\n".join(lines) + "\n").encode("utf-8")
        first = self.transform(raw)
        second = self.transform(raw)
        self.assertEqual(first.derived, second.derived)
        self.assertEqual(first.replacements_by_type, second.replacements_by_type)
        self.assertEqual(first.derived.decode("ascii").count("@R-"), first.replacement_total)
        derived_atoms = set(
            redact._derived_atoms(first.derived.decode("ascii"), self.safe_literals)
        )
        self.assertTrue(sensitive.isdisjoint(derived_atoms))

    def test_raw_descriptor_is_read_only_and_symlink_input_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="ud-redactor-readonly-") as temporary:
            directory = pathlib.Path(temporary)
            raw = directory / "raw"
            raw.write_bytes(b"secret\n")
            before = raw.read_bytes()
            observed = redact.read_raw_input(str(raw), self.manifest["limits"]["inputBytes"])
            self.assertEqual(observed, before)
            self.assertEqual(raw.read_bytes(), before)
            symlink = directory / "raw-link"
            symlink.symlink_to(raw)
            with self.assertRaisesRegex(redact.RedactionError, "IO_ERROR"):
                redact.read_raw_input(
                    str(symlink), self.manifest["limits"]["inputBytes"]
                )
            fifo = directory / "raw-fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(redact.RedactionError, "IO_ERROR"):
                redact.read_raw_input(
                    str(fifo), self.manifest["limits"]["inputBytes"]
                )

    def test_source_is_stdlib_only_and_has_no_process_network_or_shell_dispatch(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module.split(".")[0])
        self.assertEqual(
            imports,
            {
                "__future__",
                "argparse",
                "dataclasses",
                "datetime",
                "hashlib",
                "json",
                "os",
                "pathlib",
                "re",
                "stat",
                "sys",
                "typing",
                "unicodedata",
            },
        )
        source = SCRIPT.read_text(encoding="utf-8")
        for forbidden in (
            "os.system",
            "os.popen",
            "subprocess",
            "socket",
            "urllib",
            "requests",
            "Process(",
        ):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
