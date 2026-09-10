"""Receipt completeness checks: a partial/incorrect run must not become evidence."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hoststore_shadow", Path(__file__).with_name("hoststore-shadow.py"))
shadow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shadow)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, outcome in shadow.EXPECTED.items():
            store = {"history": "history-filter", "bundle": "bundle-registry",
                     "tool": "tool-registry", "names": "display-names", "session": "session-configuration", "trace": "trace-cache"}[name.split("-", 1)[0]]
            value = {"case": name, "store": store, "outcome": outcome,
                     "inputSHA256": "a" * 64, "projectionSHA256": "b" * 64}
            (self.root / f"{name}.json").write_text(json.dumps(value))

    def test_requires_every_expected_case_exactly_once(self):
        self.assertEqual(len(shadow.validate_cases(self.root)), len(shadow.EXPECTED))
        (self.root / "history-maximum-generation.json").unlink()
        with self.assertRaises(ValueError):
            shadow.validate_cases(self.root)

    def test_unknown_case_cannot_substitute_for_missing_coverage(self):
        (self.root / "unexpected.json").write_text("{}")
        with self.assertRaises(ValueError):
            shadow.validate_cases(self.root)

    def test_refusal_cannot_be_reported_as_byte_equality_or_wrong_store(self):
        path = self.root / "history-extra-query-field.json"
        original = json.loads(path.read_text())
        for key, value in (("outcome", "equal"), ("store", "tool-registry"),
                           ("inputSHA256", "not-a-digest"), ("case", "different-case")):
            with self.subTest(key=key):
                path.write_text(json.dumps(dict(original, **{key: value})))
                with self.assertRaises(ValueError):
                    shadow.validate_cases(self.root)


if __name__ == "__main__":
    unittest.main()
