#!/usr/bin/env python3
"""Closed Manifest schema regression; synthetic projections are not device evidence."""
import copy
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "openspec/contracts"


class PreconsumeManifestSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        documents = [json.loads(path.read_text(encoding="utf-8"))
                     for path in CONTRACTS.glob("*.schema.json")]
        registry = Registry().with_resources(
            (document["$id"], Resource.from_contents(document))
            for document in documents if "$id" in document
        )
        schema = json.loads((CONTRACTS / "manifest.schema.json").read_text(encoding="utf-8"))
        cls.validator = Draft202012Validator(schema, registry=registry,
                                            format_checker=FormatChecker())
        cls.original = json.loads((ROOT / "rust/tests/fixtures/debug-hap/sessions/2026/09/"
                                   "session-job-e79d1b4e261f4a13d0bfb58a97fbf163/manifest.json")
                                  .read_text(encoding="utf-8"))

    def fixture(self):
        value = copy.deepcopy(self.original)
        value["steps"] = [step for step in value["steps"] if step["id"] in {
            "confirm-evidence-target", "read-evidence-model", "read-evidence-firmware"}]
        self.assertEqual(len(value["steps"]), 3)
        value.update(runtimeAuthority=None, status="failed", compensations=[],
                     failure={"stage": "execution", "code": "executionFailed",
                              "summary": "synthetic pre-consume fixture"})
        return value

    def test_existing_consumed_manifest_and_explicit_null_failures(self):
        self.validator.validate(self.original)
        value = self.fixture()
        self.assertEqual(value["executionAuthority"], "standardAgent")
        self.assertEqual(value["toolchain"]["kind"], "runtimeProvider")
        self.validator.validate(value)
        value.update(status="cancelled", failure=None)
        self.validator.validate(value)

    def test_null_cannot_hide_authority_or_mutating_declarations(self):
        changes = [
            lambda v: v.update(status="succeeded", failure=None),
            lambda v: v.update(status="interrupted"),
            lambda v: v.update(executionMode="planOnly"),
            lambda v: v.update(outcomeCertainty="outcomeUnknown"),
            lambda v: v["steps"][0].update(effect="deviceMutation"),
            lambda v: v["steps"][0].update(effect="destructive"),
            lambda v: v["steps"][0].update(compensationDescriptors=[{}]),
            lambda v: v.update(compensations=[{}]),
            lambda v: v.pop("runtimeAuthority"),
            lambda v: v.update(runtimeAuthority={"kind": "defaultReadOnlyPolicy"}),
        ]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                value = self.fixture()
                change(value)
                self.assertFalse(self.validator.is_valid(value))

    def test_legacy_toolchains_never_gain_explicit_null_authority(self):
        for kind in ["none", "hostTool", "hdc"]:
            value = self.fixture()
            value["toolchain"]["kind"] = kind
            self.assertFalse(self.validator.is_valid(value), kind)


if __name__ == "__main__":
    unittest.main()
