"""Recorder checks against committed Swift capture products; no Runtime/device.

Only in-memory copies of the recorded answer are varied for refusal cases.
These tests never create hardware evidence or run a producer/CLI image.
"""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import unittest

from gj_record.criteria import DEFECT, INCOMPLETE, PASS, Judge
from gj_record.journeys import Context
from gj_record.run import Run, Step


class ArtifactInventoryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Path(__file__).resolve().parents[2] / "rust/tests/fixtures/capture-diagnostics"
        exchanges = json.loads((self.fixture / "cases.json").read_text(encoding="utf-8"))["exchanges"]
        result = next(e["answer"]["result"] for e in exchanges if e["method"] == "job.result"
                      and e["answer"].get("ok") is True
                      and e["answer"]["result"]["evidence"]["status"] == "verified")
        self.job = result["job"]["jobId"]
        self.result = result
        self.steps = [self.step("job.result", result)]
        for row in result["artifacts"]:
            if row["status"] != "published":
                continue
            data = (self.fixture / "artifacts" / self.job / row["artifactId"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), row["sha256"])
            self.assertEqual(str(len(data)), row["byteCount"])
            self.steps.append(self.step("artifact.read", {
                "artifactId": row["artifactId"], "artifactDigest": row["sha256"],
                "base64": base64.b64encode(data).decode(), "byteCount": len(data),
                "offset": 0, "eof": True, "nextOffset": len(data), "totalByteCount": len(data),
            }))

    def step(self, command, result):
        sequence = len(getattr(self, "steps", [])) + 1
        return Step({"sequence": sequence, "stdoutFile": f"{sequence:04d}-synthetic.json",
                     "arguments": [*command.split("."), "--job", self.job, "--output", "json"]},
                    {"schemaVersion": "arkdeck.cli.result/1", "command": command,
                     "ok": True, "result": result})

    def row(self, name):
        return next(a for a in self.result["artifacts"] if a["name"] == name)

    def check(self, *, required=("hilog.txt", "ui-dump.json", "capture-summary.json")):
        run = Run(self.steps)
        judge = Judge(run)
        context = Context(run, judge, "2026-10-05")
        _, contents = context.job(self.job, "capture", required=required,
                                  non_empty=("hilog.txt", "ui-dump.json"))
        context.capture_complete(contents, "capture")
        return judge, contents

    def drop_read(self, artifact):
        self.steps = [s for s in self.steps if s.command != "artifact.read"
                      or s.result["artifactId"] != artifact]

    def test_default_capture_keeps_fourteen_declarations_and_reads_six_published_products(self):
        judge, contents = self.check()
        self.assertEqual(judge.state(), (PASS, None))
        self.assertEqual(len(self.result["artifacts"]), 14)
        self.assertEqual(len(contents), 6)
        self.assertEqual(sum(a["status"] == "missing" for a in self.result["artifacts"]), 8)
        self.assertNotIn("crash-index.txt", contents)
        self.assertEqual(self.result["evidence"]["missingRequiredArtifacts"], [])
        self.assertFalse(any(c.missing for c in judge.checks))

    def test_a_required_name_must_be_published(self):
        row = self.row("hilog.txt")
        self.drop_read(row["artifactId"])
        row.update(status="missing", byteCount="0", sha256="", bytesVerified=False)
        judge, contents = self.check()
        self.assertEqual(judge.state()[0], DEFECT)
        self.assertEqual(judge.state()[1]["criterion"], "capture: Artifact hilog.txt published")
        self.assertNotIn("hilog.txt", contents)

    def test_verified_status_cannot_hide_an_unavailable_inventory(self):
        self.result["evidence"]["inventoryAvailable"] = False
        judge, _ = self.check()
        self.assertEqual(judge.state()[0], DEFECT)
        self.assertEqual(judge.state()[1]["criterion"], "capture: inventory available")

    def test_a_missing_requested_product_retains_the_producers_integrity_blocker(self):
        exchanges = json.loads((self.fixture / "cases.json").read_text(encoding="utf-8"))["exchanges"]
        failed = next(e["answer"]["result"] for e in exchanges if e["method"] == "job.result"
                      and e["answer"].get("ok") is True
                      and "artifactIntegrityFailed" in e["answer"]["result"]["evidence"]["blockers"])
        # A selected optional product is missing, while the summary's required
        # products can still be complete. Copy the producer's actual refusal
        # status/blockers into this in-memory corrupt-publication variant.
        self.result["evidence"]["parameters"]["crashLogs"] = True
        self.assertEqual(self.row("crash-index.txt")["status"], "missing")
        self.result["evidence"]["status"] = failed["evidence"]["status"]
        self.result["evidence"]["blockers"] = failed["evidence"]["blockers"]
        judge, contents = self.check()
        self.assertEqual(len(contents), 6)
        self.assertEqual(json.loads(contents["capture-summary.json"])["completeness"], "complete")
        self.assertEqual(judge.state()[0], DEFECT)
        self.assertTrue(any(not c.holds and c.criterion == "capture: blockers" for c in judge.checks))

    def test_truncated_and_unknown_declarations_fail(self):
        row = self.row("crash-index.txt")
        for state in ("truncated", "future", None):
            with self.subTest(status=state):
                row["status"] = state
                judge, _ = self.check()
                self.assertEqual(judge.state()[0], DEFECT)
                self.assertEqual(judge.state()[1]["criterion"], "capture: crash-index.txt publication status")

    def test_missing_declarations_must_have_the_exact_empty_shape(self):
        row = self.row("crash-index.txt")
        original = dict(row)
        for field, value in (("byteCount", "1"), ("byteCount", "00"), ("byteCount", 0),
                             ("sha256", "f" * 64), ("sha256", None),
                             ("bytesVerified", True), ("bytesVerified", 0), ("bytesVerified", None)):
            with self.subTest(field=field, value=value):
                row.clear()
                row.update(original)
                row[field] = value
                judge, _ = self.check()
                self.assertEqual(judge.state()[0], DEFECT)
                self.assertEqual(judge.state()[1]["criterion"], "capture: crash-index.txt missing declaration has no bytes")

    def test_a_missing_declaration_cannot_contradict_a_successful_read(self):
        row = self.row("crash-index.txt")
        self.steps.append(self.step("artifact.read", {
            "artifactId": row["artifactId"], "artifactDigest": hashlib.sha256(b"").hexdigest(),
            "base64": "", "byteCount": 0, "offset": 0, "eof": True,
            "nextOffset": 0, "totalByteCount": 0,
        }))
        judge, _ = self.check()
        self.assertEqual(judge.state()[0], DEFECT)

    def test_a_self_consistent_read_must_match_its_inventory_digest_and_length(self):
        row = self.row("hilog.txt")
        original = dict(row)
        for field, value in (("sha256", "f" * 64), ("byteCount", str(int(row["byteCount"]) + 1))):
            with self.subTest(field=field):
                row.clear()
                row.update(original)
                row[field] = value
                judge, contents = self.check()
                self.assertEqual(judge.state()[0], DEFECT)
                self.assertEqual(judge.state()[1]["criterion"], "capture: hilog.txt read whole and digest-checked")
                self.assertNotIn("hilog.txt", contents)

    def test_published_bytes_require_the_producers_verification(self):
        self.row("hilog.txt")["bytesVerified"] = False
        judge, _ = self.check()
        self.assertEqual(judge.state()[0], DEFECT)
        self.assertEqual(judge.state()[1]["criterion"], "capture: hilog.txt bytesVerified")

    def test_a_partial_read_is_a_failed_whole_read(self):
        artifact = self.row("hilog.txt")["artifactId"]
        next(s for s in self.steps if s.command == "artifact.read" and s.result["artifactId"] == artifact).result["eof"] = False
        judge, contents = self.check()
        self.assertEqual(judge.state()[0], DEFECT)
        self.assertNotIn("hilog.txt", contents)

    def test_a_published_product_without_a_read_remains_incomplete(self):
        self.drop_read(self.row("hilog.txt")["artifactId"])
        judge, _ = self.check()
        self.assertEqual(judge.state()[0], INCOMPLETE)
        self.assertEqual(judge.state()[1]["criterion"], "capture: hilog.txt read")


if __name__ == "__main__":
    unittest.main()
