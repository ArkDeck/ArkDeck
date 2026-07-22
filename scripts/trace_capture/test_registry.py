"""Host-only negative and closure tests for the registered trace probe pack."""

from __future__ import annotations

import json
import pathlib
import shutil
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from validate_registry import DEFAULT_PACK, RegistryValidationError, validate_pack


class TraceRegistryTestCase(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="trace-registry-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)

    def copied_pack(self) -> pathlib.Path:
        target = self.root / "pack"
        shutil.copytree(DEFAULT_PACK, target)
        return target

    def test_registered_pack_has_exact_hash_and_privacy_closure(self):
        result = validate_pack()
        self.assertEqual(result["entryCount"], 7)
        self.assertEqual(result["resourceCount"], 7)
        self.assertGreater(result["fixtureBytes"], 10_000)

    def test_tampered_fixture_fails_closed(self):
        pack = self.copied_pack()
        fixture = pack / "fixtures/hitrace-help.stdout.bin"
        fixture.write_bytes(fixture.read_bytes() + b"tamper")
        with self.assertRaisesRegex(RegistryValidationError, "size mismatch"):
            validate_pack(pack)

    def test_unlisted_fixture_fails_closed(self):
        pack = self.copied_pack()
        (pack / "fixtures/unlisted.bin").write_bytes(b"unregistered")
        with self.assertRaisesRegex(RegistryValidationError, "closure mismatch"):
            validate_pack(pack)

    def test_duplicate_json_member_fails_closed(self):
        pack = self.copied_pack()
        path = pack / "resources.json"
        document = json.loads(path.read_text(encoding="utf-8"))
        serialized = json.dumps(document, indent=2)
        path.write_text(
            serialized.replace(
                '"schemaVersion": "1.0.0"',
                '"schemaVersion": "1.0.0",\n  "schemaVersion": "1.0.0"',
                1),
            encoding="utf-8")
        with self.assertRaisesRegex(RegistryValidationError, "duplicate JSON member"):
            validate_pack(pack)


if __name__ == "__main__":
    unittest.main()
