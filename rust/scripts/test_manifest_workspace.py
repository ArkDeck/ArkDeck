#!/usr/bin/env python3
"""Approved host workspace Manifest shape; these fixtures are not hardware evidence."""
import copy
import hashlib
import json
import unittest

from test_manifest_preconsume import PreconsumeManifestSchemaTests, ROOT


class WorkspaceManifestSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        PreconsumeManifestSchemaTests.setUpClass.__func__(cls)
    def fixture_for(self, operation):
        catalog = json.loads((ROOT / f"Catalog/operations/{operation}.v1.json").read_text(encoding="utf-8"))
        self.assertEqual(catalog["provider"], "workspace")
        self.assertEqual(catalog["binding"], "none")
        self.assertEqual(len(catalog["steps"]), 1)
        declaration = catalog["steps"][0]
        reference = f"{operation}@1"
        value = copy.deepcopy(self.original)
        step = copy.deepcopy(value["steps"][0])
        step.update(id=declaration["stepID"], kind=declaration["kind"], effect="deviceMutation",
                    cancellation=declaration["cancellation"], bindingRequirement="none", bindingRevision=None,
                    compensationDescriptors=[], sourceStepId=None, compensationTrigger=None,
                    disposition="executed", outcomeCertainty="confirmed", semanticResult="succeeded")
        arguments = {
            "workspace.apply-patch": {"projectRef": "fixture-project", "patchArtifactId": "ART-fixture",
                                      "patchSha256": "a" * 64, "allowedFileGlobs": ["App.txt"],
                                      "patchAttemptRef": "patch-fixture"},
            "workspace.revert-patch": {"projectRef": "fixture-project", "patchAttemptRef": "patch-fixture"},
            "workspace.build-openharmony": {"projectRef": "fixture-project", "buildPresetRef": "fixture-build"},
            "workspace.create-checkpoint": {"projectRef": "fixture-project", "artifactId": "artifact-fixture"},
            "workspace.run-tests": {"projectRef": "fixture-project", "testPresetRef": "fixture-tests"},
        }
        step["arguments"] = arguments[operation]
        step["argumentsHash"] = hashlib.sha256(json.dumps(step["arguments"], ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()).hexdigest()
        audit = value["runtimeAuthority"]
        audit.update(kind="runtimeCapability", targetBindingDigest=hashlib.sha256(b"-\n-").hexdigest(),
                     stepSetDigest=hashlib.sha256(f'{step["id"]}|{step["kind"]}|deviceMutation|{step["cancellation"]}|none'.encode()).hexdigest(),
                     artifactDigest="a" * 64 if operation == "workspace.apply-patch" else None)
        value.update(status="succeeded", failure=None, recovery=None, steps=[step], compensations=[], bindingHistory=[],
                     originalTarget={"kind": "host", "connectKey": None, "transport": "host", "identitySnapshot": {
                         "workspaceScope": "TGT-PHYSICAL-ASSOCIATION", "projectRef": "fixture-project",
                         "providerId": "workspace", "catalogDigest": "c" * 64}},
                     toolchain={"kind": "hostTool", "providerIdentity": "workspace", "profileIdentifier": reference,
                                "reportedVersion": "24.14.1.0", "sha256": "d" * 64},
                     workflow={"kind": reference, "providerIdentity": "workspace", "profileVersion": "c" * 64})
        return value

    def test_current_catalog_host_mutations_keep_consumption_and_have_no_device_binding(self):
        for operation in ["workspace.apply-patch", "workspace.revert-patch", "workspace.build-openharmony",
                          "workspace.create-checkpoint", "workspace.run-tests"]:
            with self.subTest(operation=operation):
                self.validator.validate(self.fixture_for(operation))

    def test_consumed_host_branch_is_closed_to_foreign_or_unaudited_steps(self):
        changes = [
            lambda v: v.update(runtimeAuthority=None),
            lambda v: v.pop("runtimeAuthority"),
            lambda v: v["runtimeAuthority"].update(kind="defaultReadOnlyPolicy"),
            lambda v: v["runtimeAuthority"].update(stepSetDigest="e" * 64),
            lambda v: v["runtimeAuthority"].update(targetBindingDigest="e" * 64),
            lambda v: v["runtimeAuthority"].pop("consumptionFingerprintSha256"),
            lambda v: v["toolchain"].update(kind="none"),
            lambda v: v["toolchain"].update(providerIdentity="hdc"),
            lambda v: v["toolchain"].update(profileIdentifier="workspace.run-tests@1"),
            lambda v: v["toolchain"].update(reportedVersion=""),
            lambda v: v["workflow"].update(kind="debug.hap@1"),
            lambda v: v["steps"][0].update(kind="installPackage"),
            lambda v: v["steps"][0].update(effect="destructive"),
            lambda v: v["steps"][0].update(bindingRequirement="confirmedDevice", bindingRevision=7),
            lambda v: v["steps"][0].update(compensationDescriptors=[{}]),
            lambda v: v["steps"][0]["arguments"].update(buildPresetRef=None),
            lambda v: v["steps"][0]["arguments"].update(foreign="argument"),
            lambda v: v["steps"][0]["arguments"].pop("projectRef"),
            lambda v: v["steps"].append(copy.deepcopy(v["steps"][0])),
            lambda v: v["originalTarget"].update(connectKey="foreign-device"),
            lambda v: v["originalTarget"]["identitySnapshot"].update(extra="unknown"),
            lambda v: v["bindingHistory"].append({}),
            lambda v: v.update(executionMode="planOnly"),
            lambda v: v.update(status="interrupted"),
        ]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                value = self.fixture_for("workspace.build-openharmony")
                change(value)
                self.assertFalse(self.validator.is_valid(value))

    def test_apply_requires_both_original_non_null_lowercase_artifact_digests(self):
        value = self.fixture_for("workspace.apply-patch")
        value["runtimeAuthority"]["artifactDigest"] = None
        value["steps"][0]["arguments"].pop("patchSha256")
        self.assertFalse(self.validator.is_valid(value))
        for key in ["artifactDigest", "patchSha256"]:
            value = self.fixture_for("workspace.apply-patch")
            target = value["runtimeAuthority"] if key == "artifactDigest" else value["steps"][0]["arguments"]
            target[key] = "A" * 64
            self.assertFalse(self.validator.is_valid(value))


if __name__ == "__main__":
    unittest.main()
