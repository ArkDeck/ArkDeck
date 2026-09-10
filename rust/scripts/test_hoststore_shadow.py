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
                     "tool": "tool-registry", "names": "display-names", "session": "session-configuration", "trace": "trace-cache", "timestamp": "session-timestamp", "inventory": "session-storage", "graphemes": "session-graphemes", "identity": "tool-identity", "json": "session-json"}[name.split("-", 1)[0]]
            value = {"case": name, "store": store, "outcome": outcome,
                     "inputSHA256": "a" * 64, "projectionSHA256": "b" * 64, "oracleBinarySHA256": "c" * 64}
            (self.root / f"{name}.json").write_text(json.dumps(value))

    def test_requires_every_expected_case_exactly_once(self):
        self.assertEqual(len(shadow.validate_cases(self.root)), len(shadow.EXPECTED))
        (self.root / "history-maximum-generation.json").unlink()
        with self.assertRaises(ValueError):
            shadow.validate_cases(self.root)

    def test_mixed_oracle_binaries_cannot_form_one_run(self):
        path = self.root / "history-maximum-generation.json"
        value = json.loads(path.read_text())
        value["oracleBinarySHA256"] = "d" * 64
        path.write_text(json.dumps(value))
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



class DependencyProvenanceTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import patch
        import hashlib
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scratch = self.root / "build"
        self.checkout = self.scratch / "checkouts/ArkTrace"
        self.checkout.mkdir(parents=True)
        self.source = self.checkout / "fixture.txt"
        self.source.write_bytes(b"pinned\n")
        self.revision = "a" * 40
        package = self.root / "Packages/ArkDeckKit"
        package.mkdir(parents=True)
        location = "https://github.com/ArkDeck/ArkTrace.git"
        (package / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "arktrace", "location": location,
            "state": {"revision": self.revision}}]}))
        self.state = {"object": {"dependencies": [{"packageRef": {"identity": "arktrace", "location": location},
            "subpath": "ArkTrace", "state": {"name": "sourceControlCheckout", "checkoutState": {"revision": self.revision}}}]}}
        (self.scratch / "workspace-state.json").write_text(json.dumps(self.state))
        oid = hashlib.sha1(b"blob 7\0pinned\n").hexdigest()
        self.tree = f"100644 blob {oid}\tfixture.txt\0".encode()
        self.status = b""
        self.allow_crlf = False
        root_patch = patch.object(shadow, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        git_patch = patch.object(shadow.subprocess, "check_output", side_effect=self.git)
        git_patch.start()
        self.addCleanup(git_patch.stop)

    def git(self, command, **kwargs):
        args = command[3:]
        if args[0] == "rev-parse":
            return self.revision.encode() + b"\n"
        if args[0] == "status":
            return self.status
        if args[0] == "ls-tree":
            return self.tree
        if args[0] == "check-attr":
            values = {"text": "set", "eol": "crlf" if self.allow_crlf else "lf",
                      "filter": "unspecified", "working-tree-encoding": "unspecified"}
            return b"".join(f"fixture.txt\0{key}\0{value}\0".encode() for key, value in values.items())
        raise AssertionError(command)

    def test_checks_bytes_even_when_git_status_reports_clean(self):
        self.assertEqual(shadow.dependency_provenance(self.scratch)["revision"], self.revision)
        self.source.write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "checkout bytes differ"):
            shadow.dependency_provenance(self.scratch)

    def test_only_pinned_crlf_attribute_allows_git_line_ending_conversion(self):
        self.source.write_bytes(b"pinned\r\n")
        with self.assertRaisesRegex(ValueError, "checkout bytes differ"):
            shadow.dependency_provenance(self.scratch)
        self.allow_crlf = True
        receipt = shadow.dependency_provenance(self.scratch)
        self.assertEqual(receipt["sourceFiles"]["fixture.txt"], shadow.digest(b"pinned\r\n"))
        self.source.write_bytes(b"changed\r\n")
        with self.assertRaisesRegex(ValueError, "normalized checkout bytes differ"):
            shadow.dependency_provenance(self.scratch)

    def test_refuses_dirty_checkout_and_mismatched_resolution(self):
        self.status = b"?? extra.swift\n"
        with self.assertRaisesRegex(ValueError, "contains changes"):
            shadow.dependency_provenance(self.scratch)
        self.status = b""
        self.state["object"]["dependencies"][0]["state"]["checkoutState"]["revision"] = "b" * 40
        (self.scratch / "workspace-state.json").write_text(json.dumps(self.state))
        with self.assertRaisesRegex(ValueError, "does not match"):
            shadow.dependency_provenance(self.scratch)


if __name__ == "__main__":
    unittest.main()
