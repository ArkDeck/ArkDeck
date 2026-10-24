#!/usr/bin/env python3
"""Host-only regression tests; no App, Runtime, signing or device commands."""
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installed_rust_ui", Path(__file__).with_name("installed_rust_ui.py"))
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)

QUERY = {"search": "test-marker", "status": "all", "mode": "all", "sessionId": None,
         "targetId": None, "timeRange": "anyTime", "activity": "all"}


class InstalledRustUITests(unittest.TestCase):
    def test_launchd_requires_one_live_pid(self):
        self.assertEqual(subject.live_pid("service = {\n\tpid = 123\n}"), 123)
        for text in ("pid = 0", "pid = 12\npid = 13", "state = waiting"):
            with self.assertRaises(RuntimeError):
                subject.live_pid(text)

    def test_live_label_alone_is_not_mach_ownership(self):
        subject.verify_live_endpoint('endpoints = {\n"com.arkdeck.agentd" = {\nactive = 1\n}\n}')
        for text in ('gui/501/com.arkdeck.agentd = {\npid = 123\n}',
                     '"com.arkdeck.agentd" = {\nactive = 0\n}',
                     '"other.service" = {\nactive = 1\n}'):
            with self.assertRaises(RuntimeError):
                subject.verify_live_endpoint(text)

    def test_preserve_absent_or_existing_query(self):
        for original_query, action in ((None, "delete"), ({**QUERY, "search": "original"}, "save")):
            original = {"generation": "7", "query": original_query}
            self.assertEqual(subject.restoration(original, original, QUERY), "unchanged")
            self.assertEqual(subject.restoration(original, {"generation": "8", "query": QUERY}, QUERY), action)

    def test_never_overwrite_external_or_ambiguous_changes(self):
        original = {"generation": "7", "query": None}
        for current in (
            {"generation": "9", "query": QUERY},
            {"generation": "8", "query": {**QUERY, "mode": "live"}},
            {"generation": "8", "query": None},
            {"generation": "7", "query": QUERY},
        ):
            with self.assertRaises(RuntimeError):
                subject.restoration(original, current, QUERY)

    def test_restore_passes_original_fields_and_exact_generation(self):
        original_query = {**QUERY, "search": "original spaces --not-an-option", "targetId": "target-original"}
        snapshot = {"original": {"generation": "7", "query": original_query}, "testQuery": QUERY}
        before = {"schemaVersion": "arkdeck.history-filter-list/1", "generation": "8",
                  "filters": [{"generation": "8", "query": QUERY}]}
        after = {"schemaVersion": "arkdeck.history-filter-list/1", "generation": "9",
                 "filters": [{"generation": "9", "query": original_query}]}
        with patch.object(subject, "cli_filter", side_effect=[before, {}, after]) as call:
            self.assertTrue(subject.restore({}, snapshot)["restored"])
        arguments = call.call_args_list[1].args
        self.assertEqual(arguments[:4], ({}, "save", "--expected-generation", "8"))
        self.assertIn(original_query["search"], arguments)
        self.assertIn("target-original", arguments)
        self.assertIn("--target", arguments)
        self.assertIn("--time", arguments)
        self.assertNotIn("--session", arguments)

    def test_unrestorable_original_is_rejected_before_ui_save(self):
        with self.assertRaises(RuntimeError):
            subject.restore_arguments({**QUERY, "search": "--option-looking-search"})

    def test_live_code_validation_binds_pid_to_pinned_disk_cdhash(self):
        code_hash = "a" * 40
        with patch.object(subject, "run", side_effect=[b"arm64\n", f"CDHash={code_hash}\n".encode(), b""]) as call:
            self.assertEqual(subject.verify_live_code(321, Path("/signed/daemon")), code_hash)
        self.assertEqual(call.call_args.args, ("/usr/bin/codesign", "--verify", "-R", '=cdhash H"' + code_hash + '"', "321"))
        with patch.object(subject, "run", side_effect=[b"arm64\n", f"CDHash={code_hash}\n".encode(), RuntimeError("different live code")]):
            with self.assertRaises(RuntimeError):
                subject.verify_live_code(321, Path("/signed/daemon"))

    def test_universal_binary_cannot_use_the_wrong_slice_hash(self):
        with patch.object(subject, "run", return_value=b"x86_64 arm64e\n") as call:
            with self.assertRaises(RuntimeError):
                subject.verify_live_code(321, Path("/signed/daemon"))
        self.assertEqual(call.call_count, 1)

    @unittest.skipUnless(sys.platform == "darwin", "macOS requirement parser")
    def test_cdhash_requirement_parses_with_system_csreq(self):
        result = subprocess.run(["/usr/bin/csreq", "-r", '=cdhash H"' + "a" * 40 + '"', "-t"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_restore_conflict_dispatches_no_mutation(self):
        current = {"schemaVersion": "arkdeck.history-filter-list/1", "generation": "9",
                   "filters": [{"generation": "9", "query": QUERY}]}
        with patch.object(subject, "cli_filter", return_value=current) as call:
            with self.assertRaises(RuntimeError):
                subject.restore({}, {"original": {"generation": "7", "query": None}, "testQuery": QUERY})
        self.assertEqual(call.call_count, 1)
        self.assertEqual(call.call_args.args[1], "list")

    def test_snapshot_is_private_and_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.json"
            subject.write_private(path, {"original": QUERY})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                subject.write_private(path, {})
            self.assertEqual(subject.read_json(path), {"original": QUERY})

    def test_bad_or_inconsistent_filter_projection_is_refused(self):
        for document in (
            {"schemaVersion": "other", "generation": "1", "filters": []},
            {"schemaVersion": "arkdeck.history-filter-list/1", "generation": "01", "filters": []},
            {"schemaVersion": "arkdeck.history-filter-list/1", "generation": "8",
             "filters": [{"generation": "7", "query": QUERY}]},
        ):
            with self.assertRaises(RuntimeError):
                subject.resource(document)


if __name__ == "__main__":
    unittest.main()
