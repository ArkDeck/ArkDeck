"""Offline GJ-4 proofs from committed producer bytes and current wire shapes.

Synthetic variants never execute a CLI, Runtime, image or device.
"""
from __future__ import annotations

import base64
import copy
import gzip
import hashlib
import io
import json
import tarfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gj_record import flash_image, record
from gj_record.criteria import DEFECT, INCOMPLETE, PASS
from gj_record.run import RefusedInput, Run, Step
from gj_record.test_gj_record import Case, D, HDC, TARGET

ROOT = Path(__file__).resolve().parents[2]
STORY = ROOT / "rust/tests/fixtures/flash-run/stories/canonical"


def fixture():
    exchanges = json.loads((STORY / "cases.json").read_text(encoding="utf-8"))["exchanges"]
    result = next(x["answer"]["result"] for x in exchanges
                  if x["method"] == "job.result" and x["answer"].get("ok") is True)
    _, import_id, artifact = result["evidence"]["parameters"]["artifactLease"].split(":")
    archive = (STORY / "files/artifacts" / import_id / artifact).read_bytes()
    frames = ROOT / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.inspection.jsonl"
    inspection = next(x["result"] for x in map(json.loads, frames.read_text(encoding="utf-8").splitlines())
                      if x.get("ok") is True and x["result"]["import"]["metadata"]["kind"] == "flash-bundle")
    imported = inspection["import"]
    imported["importId"] = import_id
    receipt = imported["receipt"]
    receipt.update(importId=import_id, artifactId=artifact, owner={"kind": "import", "id": import_id},
                   lease=result["evidence"]["parameters"]["artifactLease"])
    return result, inspection, archive


def image(version=b"OpenHarmony-7.0.0.43", *, payload=None, name="system.img", extra=()):
    # Preserve the committed archive's other DAYU200 products. Only the synthetic
    # system declaration (and explicitly named negative) changes.
    _, _, original = fixture()
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as writer:
        with tarfile.open(fileobj=io.BytesIO(original), mode="r:gz") as reader:
            for member in reader:
                content = reader.extractfile(member).read()
                if member.name == "system.img":
                    content = payload if payload is not None else b"const.ohos.fullname=" + version + b"\n"
                    member.name = name
                member.size = len(content)
                writer.addfile(member, io.BytesIO(content))
        for extra_name, content in extra:
            member = tarfile.TarInfo(extra_name)
            member.size = len(content)
            writer.addfile(member, io.BytesIO(content))
    return gzip.compress(output.getvalue(), mtime=0)


def step(command, result, arguments=(), sequence=1, *, ok=True, code=0):
    return Step({"sequence": sequence, "arguments": list(arguments), "exitCode": code,
                 "stdoutFile": f"{sequence:04d}-synthetic.json"},
                {"command": command, "ok": ok, "result": result})


def proof(archive=None, *, chunk=256):
    result, inspection, original = fixture()
    archive = original if archive is None else archive
    digest = hashlib.sha256(archive).hexdigest()
    imported = inspection["import"]
    for fields in (imported["metadata"], imported["receipt"]):
        fields["byteCount"] = str(len(archive))
    imported["metadata"]["sha256"] = imported["receipt"]["artifactDigest"] = digest
    result["evidence"]["authority"]["artifactDigest"] = digest
    import_id, artifact = imported["importId"], imported["receipt"]["artifactId"]
    inspect = step("artifact.import.inspect", inspection, ["--import", import_id])
    flash = step("job.result", result, sequence=2)
    reads = []
    for offset in range(0, len(archive), chunk):
        piece = archive[offset:offset + chunk]
        reads.append(step("artifact.read", {
            "artifactId": artifact, "artifactDigest": digest, "base64": base64.b64encode(piece).decode(),
            "byteCount": len(piece), "offset": offset, "nextOffset": offset + len(piece),
            "totalByteCount": len(archive), "eof": offset + len(piece) == len(archive)},
            ["--import", import_id, "--artifact", artifact, "--offset", str(offset)], sequence=3 + len(reads)))
    return Run([inspect, flash, *reads]), flash


def append_journey(journal, *, version="OpenHarmony-7.0.0.36", readback=None, postflight=None,
                   capture_import=True):
    result, inspection, original = fixture()
    archive = original if version == "OpenHarmony-7.0.0.36" else image(version.encode())
    run, flash = proof(archive)
    result, inspection = flash.result, run.steps[0].result
    evidence, job = result["evidence"], result["job"]
    evidence.update(catalogDigest=journal.digest, targetId=TARGET)
    job["targetId"] = TARGET
    evidence["observation"].update(targetId=TARGET, firmware=readback or version)
    for fields in (inspection["import"]["metadata"], inspection["import"]["receipt"]):
        fields["targetId"] = TARGET
    if capture_import:
        journal.ok("artifact.import.inspect", ["artifact", "import", "inspect", "--import", inspection["import"]["importId"]], inspection)
        for read in run.steps[2:]:
            journal.ok("artifact.read", ["artifact", "read", *read.entry["arguments"]], read.result)
    journal.ok("agent.run", ["agent", "run", "--operation", "flash.full-restore@1", "--execution-id", f"gj4-{D}", "--target", TARGET], {
        "executionId": f"gj4-{D}", "operation": "flash.full-restore@1", "state": "completed",
        "jobId": job["jobId"], "jobState": "succeeded", "outcomeUnknown": False,
        "catalogDigest": journal.digest, "evidence": evidence, "humanAction": None, "nextAction": None, "job": job})
    payloads = []
    for row in result["artifacts"]:
        content = (STORY / "files/artifacts" / job["jobId"] / row["artifactId"]).read_bytes()
        if row["name"] == "post-flash-facts.json":
            facts = json.loads(content)
            facts["firmware"] = readback or version
            content = json.dumps(facts).encode()
            row.update(sha256=hashlib.sha256(content).hexdigest(), byteCount=str(len(content)))
        payloads.append((row, content))
    journal.ok("job.result", ["job", "result", "--job", job["jobId"]], result)
    for row, content in payloads:
        journal.ok("artifact.read", ["artifact", "read", "--job", job["jobId"], "--artifact", row["artifactId"]], {
            "artifactId": row["artifactId"], "artifactDigest": row["sha256"], "base64": base64.b64encode(content).decode(),
            "byteCount": len(content), "offset": 0, "eof": True, "nextOffset": len(content), "totalByteCount": len(content)})
    journal.job(f"gj4-{D}-postflight", "observe.device@1", {}, observation={"firmware": postflight or version})


class ConsumedImageTests(unittest.TestCase):
    def test_committed_producer_archive_and_wire_supply_version(self):
        run, flash = proof()
        value, sources = flash_image.consumed_image_version(run, flash)
        self.assertEqual(value["runtimeBuildVersion"], "OpenHarmony-7.0.0.36")
        self.assertEqual(value["byteCount"], 903)
        self.assertEqual(len(sources), 5)

    def test_another_declared_version_is_not_a_pin(self):
        run, flash = proof(image())
        self.assertEqual(flash_image.consumed_image_version(run, flash)[0]["runtimeBuildVersion"], "OpenHarmony-7.0.0.43")

    def test_large_mirror_fits_published_import_cap_without_document_limit(self):
        self.assertEqual(flash_image.MAX_ARCHIVE_BYTES, 8 * 1024**3)
        self.assertGreater(flash_image.MAX_ARCHIVE_BYTES, 725737667)
        run, flash = proof()
        for fields in (run.steps[0].result["import"]["metadata"], run.steps[0].result["import"]["receipt"]):
            fields["byteCount"] = str(flash_image.MAX_ARCHIVE_BYTES + 1)
        with self.assertRaisesRegex(flash_image.ImageProofError, "content"):
            flash_image.consumed_image_version(run, flash)

    def test_missing_inspection_or_reads_stays_missing(self):
        for remove in ("artifact.import.inspect", "artifact.read"):
            run, flash = proof()
            run.steps = [s for s in run.steps if s.command != remove]
            with self.subTest(remove=remove), self.assertRaises(flash_image.MissingImageProof):
                flash_image.consumed_image_version(run, flash)

    def test_latest_inspection_refusal_cannot_hide_behind_a_valid_receipt(self):
        run, flash = proof()
        run.steps.append(step("artifact.import.inspect", {}, run.steps[0].entry["arguments"], 20, ok=False, code=2))
        with self.assertRaisesRegex(flash_image.ImageProofError, "refused"):
            flash_image.consumed_image_version(run, flash)

    def test_inspection_arguments_must_name_its_actual_owner(self):
        run, flash = proof()
        inspect = run.steps[0]
        inspect.entry["arguments"][-1] = "imp-foreign"
        with self.assertRaisesRegex(flash_image.ImageProofError, "request owner"):
            flash_image.consumed_image_version(run, flash)
        inspect.entry["arguments"] = ["--import-request-id", inspect.result["import"]["importRequestId"]]
        self.assertEqual(flash_image.consumed_image_version(run, flash)[0]["byteCount"], 903)

    def test_receipt_scope_content_and_owner_are_exact(self):
        changes = {"artifactDigest": "0" * 64, "byteCount": "1", "targetId": "TGT-other", "bindingRevision": "2",
                   "lease": "other", "artifactId": "ART-other", "owner": {"kind": "job", "id": "job-other"},
                   "importRequestId": "different", "name": "other.tar.gz", "validation": {"kind": "flash-bundle"}}
        for name, value in changes.items():
            run, flash = proof()
            run.steps[0].result["import"]["receipt"][name] = value
            with self.subTest(name=name), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_original_consumption_proof_cannot_be_missing_or_changed(self):
        for name, value in (("artifactDigest", None), ("artifactDigest", "0" * 64), ("kind", "defaultReadOnlyPolicy"),
                            ("planDigest", None), ("consumptionFingerprintSha256", ""), ("useOrdinal", 0)):
            run, flash = proof()
            flash.result["evidence"]["authority"][name] = value
            with self.subTest(name=name, value=value), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_flash_operation_provider_and_profile_cannot_be_substituted(self):
        for key, replacement in (("operationReference", "observe.device@1"), ("actualEffect", "readOnly"),
                                 ("providerId", "hdc"), ("deviceProfileRef", "foreign")):
            run, flash = proof()
            fields = flash.result["evidence"] if key != "deviceProfileRef" else flash.result["evidence"]["parameters"]
            fields[key] = replacement
            with self.subTest(key=key), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_malformed_objects_fail_closed_with_bounded_reasons(self):
        for container, name in (("evidence", "parameters"), ("evidence", "authority"), ("import", "metadata"), ("import", "receipt")):
            run, flash = proof()
            owner = flash.result[container] if container == "evidence" else run.steps[0].result[container]
            owner[name] = ["invalid"]
            with self.subTest(name=name), self.assertRaisesRegex(flash_image.ImageProofError, "malformed"):
                flash_image.consumed_image_version(run, flash)

    def test_every_chunk_field_and_actual_bytes_must_agree(self):
        for name, value in (("artifactId", "ART-other"), ("artifactDigest", "0" * 64), ("offset", 1),
                            ("byteCount", 1), ("nextOffset", 999), ("totalByteCount", 1), ("eof", True),
                            ("base64", "!!!!"), ("base64", base64.b64encode(bytes(256)).decode())):
            run, flash = proof()
            run.steps[2].result[name] = value
            with self.subTest(name=name, value=value), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_whole_digest_is_not_only_a_chunk_claim(self):
        run, flash = proof()
        for s in run.steps[2:]:
            s.result["artifactDigest"] = "0" * 64
        imported = run.steps[0].result["import"]
        imported["metadata"]["sha256"] = imported["receipt"]["artifactDigest"] = "0" * 64
        flash.result["evidence"]["authority"]["artifactDigest"] = "0" * 64
        with self.assertRaisesRegex(flash_image.ImageProofError, "whole SHA"):
            flash_image.consumed_image_version(run, flash)

    def test_missing_chunk_eof_or_later_read_refusal_cannot_pass(self):
        for change in ("gap", "partial", "refusal"):
            run, flash = proof()
            if change == "gap":
                del run.steps[3]
            elif change == "partial":
                run.steps.pop()
            else:
                run.steps.append(step("artifact.read", {}, run.steps[2].entry["arguments"], 20, ok=False, code=2))
            with self.subTest(change=change), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_identical_refresh_is_allowed_but_changed_duplicate_is_not(self):
        run, flash = proof()
        run.steps += copy.deepcopy(run.steps[2:])
        self.assertEqual(flash_image.consumed_image_version(run, flash)[0]["byteCount"], 903)
        run.steps[-1].result["eof"] = False
        with self.assertRaisesRegex(flash_image.ImageProofError, "repeated"):
            flash_image.consumed_image_version(run, flash)

    def test_a_refresh_cannot_hide_an_earlier_wrong_owner_argument(self):
        for arguments in (["--job", "job-foreign"], ["--job=job-foreign"]):
            run, flash = proof()
            run.steps += copy.deepcopy(run.steps[2:])
            run.steps[2].entry["arguments"] += arguments
            with self.subTest(arguments=arguments), self.assertRaisesRegex(flash_image.ImageProofError, "owner"):
                flash_image.consumed_image_version(run, flash)

    def test_wrong_argv_owner_or_offset_cannot_supply_a_chunk(self):
        for token in ("--job", "--offset"):
            run, flash = proof()
            if token == "--job":
                run.steps[2].entry["arguments"] += ["--job", "job-other"]
            else:
                run.steps[2].entry["arguments"][-1] = "1"
            with self.subTest(token=token), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_system_declaration_missing_empty_conflicting_or_unbounded_refuses(self):
        for payload in (b"nothing", b"const.ohos.fullname=\n", b"const.ohos.fullname=OpenHarmony-7\nconst.ohos.fullname=OpenHarmony-8\n",
                        b"const.ohos.fullname=" + b"a" * 257 + b"\n", b"const.ohos.fullname=OpenHarmony-7"):
            run, flash = proof(image(payload=payload))
            with self.subTest(payload=payload[:40]), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_streamed_version_marker_and_value_cross_piece_boundaries(self):
        scanner = flash_image._VersionScanner()
        for part in (b"noiseconst.ohos.", b"fullname=OpenHarmony-7.0.", b"0.43", b"\n"):
            scanner.consume(part)
        self.assertEqual(scanner.finish(), "OpenHarmony-7.0.0.43")

    def test_tar_truncation_corruption_missing_and_duplicate_system_refuse(self):
        raw = gzip.decompress(image())
        corrupt = bytearray(raw)
        corrupt[0] ^= 1
        archives = (b"not gzip", image(name="other.img"), image(extra=(("system.img", b"x"),)),
                    gzip.compress(raw[:600]), gzip.compress(corrupt), gzip.compress(raw + b"not padding"))
        for archive in archives:
            run, flash = proof(archive)
            with self.subTest(size=len(archive)), self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_stream_expansion_is_bounded(self):
        run, flash = proof()
        with patch.object(flash_image, "MAX_EXPANDED_BYTES", 1024):
            with self.assertRaises(flash_image.ImageProofError):
                flash_image.consumed_image_version(run, flash)

    def test_committed_arkforge_tool_is_not_mistaken_for_hdc(self):
        run, flash = proof()
        self.assertNotEqual(flash.result["evidence"]["observation"]["toolSha256"], HDC)
        record._refuse_foreign_hdc(run, HDC)

    def test_arkforge_provider_provenance_is_closed_to_exact_flash(self):
        for location, key, value in (("evidence", "operationReference", "observe.device@1"),
                                      ("evidence", "providerId", "hdc"),
                                      ("observation", "providerId", "hdc"),
                                      ("observation", "toolSha256", ""),
                                      ("observation", "toolVersion", ""),
                                      ("observation", "targetId", "TGT-other"),
                                      ("observation", "bindingRevision", 2)):
            run, flash = proof()
            evidence = flash.result["evidence"]
            fields = evidence if location == "evidence" else evidence["observation"]
            fields[key] = value
            with self.subTest(location=location, key=key), self.assertRaises(RefusedInput):
                record._refuse_foreign_hdc(run, HDC)

    def test_hdc_observations_still_require_exact_registered_tool(self):
        run, flash = proof()
        evidence = flash.result["evidence"]
        evidence.update(providerId="hdc", operationReference="observe.device@1", actualEffect="readOnly")
        evidence["observation"]["providerId"] = "hdc"
        with self.assertRaises(RefusedInput):
            record._refuse_foreign_hdc(run, HDC)
        evidence["observation"]["toolSha256"] = HDC
        record._refuse_foreign_hdc(run, HDC)


class GoldenJourneyFourImageTests(Case):
    def test_profile_supported_version_and_derived_public_metadata(self):
        self.journal.facts()
        append_journey(self.journal, version="OpenHarmony-7.0.0.43")
        journey = self.journey(self.assemble(names=("GJ-4",)), "GJ-4")
        self.assertEqual(journey["state"], PASS, journey.get("firstFailingCriterion"))
        self.assertEqual(journey["flashImage"]["runtimeBuildVersion"], "OpenHarmony-7.0.0.43")
        self.assertEqual(set(journey["flashImage"]), {"deviceProfileRef", "archiveSha256", "byteCount", "runtimeBuildVersion"})

    def test_machine_readback_must_equal_consumed_image_not_old_pin(self):
        self.journal.facts()
        append_journey(self.journal, version="OpenHarmony-7.0.0.43", readback="OpenHarmony-7.0.0.37")
        journey = self.journey(self.assemble(names=("GJ-4",)), "GJ-4")
        self.assertEqual(journey["state"], DEFECT)
        self.assertIn("machine readback firmware", journey["firstFailingCriterion"]["criterion"])

    def test_postflight_must_also_equal_consumed_image(self):
        self.journal.facts()
        append_journey(self.journal, postflight="OpenHarmony-7.0.0.37")
        journey = self.journey(self.assemble(names=("GJ-4",)), "GJ-4")
        self.assertEqual(journey["state"], DEFECT)
        self.assertIn("restored image firmware", journey["firstFailingCriterion"]["criterion"])

    def test_no_caller_or_filename_fallback_when_import_not_captured(self):
        self.journal.facts()
        append_journey(self.journal, capture_import=False)
        journey = self.journey(self.assemble(names=("GJ-4",)), "GJ-4")
        self.assertEqual(journey["state"], INCOMPLETE)
        self.assertNotIn("flashImage", journey)


if __name__ == "__main__":
    unittest.main()
