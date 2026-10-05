//! Synthetic source-proof tests, never acceptance evidence or a dispatch.
use super::*;
use crate::test_private::{create_private_directory, temporary_root};
use crate::{
    ArtifactReadStore, ProfilePresets, WorkspaceCommandPreset, WorkspaceComposition,
    WorkspaceProfile,
};
use std::path::PathBuf;

const AT: &str = "2026-10-06T00:00:00Z";

// A synthetic PE resource image, never launched. Its exact pinned bytes have
// the same fixed FileVersion structure exercised by platform parser tests.
fn versioned_image() -> Vec<u8> {
    let mut image = vec![0; 0x300];
    let word =
        |image: &mut [u8], at, value: u16| image[at..at + 2].copy_from_slice(&value.to_le_bytes());
    let dword =
        |image: &mut [u8], at, value: u32| image[at..at + 4].copy_from_slice(&value.to_le_bytes());
    image[..2].copy_from_slice(b"MZ");
    dword(&mut image, 60, 0x80);
    image[0x80..0x84].copy_from_slice(b"PE\0\0");
    word(&mut image, 0x86, 1);
    word(&mut image, 0x94, 240);
    word(&mut image, 0x98, 0x20b);
    dword(&mut image, 0x98 + 108, 16);
    dword(&mut image, 0x98 + 128, 0x1000);
    dword(&mut image, 0x98 + 132, 256);
    image[0x188..0x18d].copy_from_slice(b".rsrc");
    for (at, value) in [(0x190, 256), (0x194, 0x1000), (0x198, 256), (0x19c, 0x200)] {
        dword(&mut image, at, value);
    }
    let resource = &mut image[0x200..];
    for at in [14, 46, 78] {
        word(resource, at, 1);
    }
    for (at, value) in [
        (16, 16),
        (20, 0x8000_0020),
        (48, 1),
        (52, 0x8000_0040),
        (80, 1033),
        (84, 96),
        (96, 0x1080),
        (100, 92),
    ] {
        dword(resource, at, value);
    }
    let fixed = &mut resource[128..220];
    word(fixed, 0, 92);
    word(fixed, 2, 52);
    for (index, character) in "VS_VERSION_INFO\0".encode_utf16().enumerate() {
        word(fixed, 6 + index * 2, character);
    }
    for (at, value) in [
        (40, 0xfeef_04bd),
        (44, 0x0001_0000),
        (48, (24 << 16) | 14),
        (52, 1 << 16),
    ] {
        dword(fixed, at, value);
    }
    image
}

fn set_arguments(manifest: &mut Value, arguments: Value) {
    let hash = sha256_hex(&crate::session_json::encode(&arguments).unwrap());
    manifest["steps"][0]["arguments"] = arguments;
    manifest["steps"][0]["argumentsHash"] = json!(hash);
}

struct Fixture {
    root: PathBuf,
    workspace: WorkspaceComposition,
    artifacts: ArtifactReadStore,
    record: JobRecord,
    materialization: crate::job_plan::WorkspaceMaterialization,
    events: Vec<Value>,
    replay: ReplayFacts,
}

impl Fixture {
    fn new(reference: &str, own_image: bool) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let root = temporary_root().join(format!("workspace-session-{nonce:016x}"));
        create_private_directory(&root);
        let root = arkdeck_platform::host_resolved_path(&root).unwrap();
        for child in ["source", "artifacts", "job"] {
            create_private_directory(&root.join(child));
        }
        let executable = if own_image {
            arkdeck_platform::host_resolved_path(&std::env::current_exe().unwrap()).unwrap()
        } else {
            let destination = root.join("versioned.exe");
            std::fs::write(&destination, versioned_image()).unwrap();
            arkdeck_platform::host_resolved_path(&destination).unwrap()
        };
        let preset = |id| {
            WorkspaceCommandPreset::hashing(
                id,
                executable.to_str().unwrap(),
                None,
                &["/c", "exit", "0"],
                10,
            )
            .unwrap()
        };
        let profile = WorkspaceProfile::primary(
            "source-proof@1",
            "fixture-project",
            root.join("source").to_str().unwrap(),
            &["**"],
            preset("inspect"),
            preset("patch"),
            ProfilePresets {
                build: vec![preset("build")],
                test: vec![preset("tests")],
                ..Default::default()
            },
        )
        .unwrap();
        let workspace =
            WorkspaceComposition::with_profiles(vec![profile], &root.join("copies"), || {
                Some(AT.into())
            })
            .unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let (id, kind, cancellation) = workspace_mutation(reference).unwrap();
        let input = if kind == "buildWorkspaceOpenHarmony" {
            "buildPresetRef"
        } else {
            "testPresetRef"
        };
        let preset_id = if kind == "buildWorkspaceOpenHarmony" {
            "build"
        } else {
            "tests"
        };
        let request = json!({"schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
            "requestId": "source-proof-request", "idempotencyKey": "source-proof-idempotency",
            "target": {"targetId": "workspace-host"}, "operation": {"id": reference.strip_suffix("@1").unwrap(), "version": 1},
            "inputs": {"projectRef": "fixture-project", input: preset_id}, "requestedOutputs": ["derivedArtifacts"],
            "authorization": {"capabilityId": "CAP-RT-SOURCE-PROOF"}});
        let request_decoded =
            OperationRequest::decode(&crate::session_json::encode(&request).unwrap()).unwrap();
        let descriptor = CatalogOperation::lookup(&request_decoded.operation_id, Some(1)).unwrap();
        let planner = crate::JobPlanner {
            artifacts: Some(&artifacts),
            imports: None,
            analyzer: None,
            state_root: &root,
            hdc: None,
            workspace: Some(&workspace),
        };
        let materialization = planner
            .workspace_materialization(&request_decoded, descriptor)
            .unwrap();
        let digest = materialization.digest().unwrap();
        let mut original = request.clone();
        original.as_object_mut().unwrap().remove("authorization");
        let mut record = JobRecord::admitted(
            "job-source-proof",
            request,
            original,
            reference,
            arkdeck_contract::CATALOG_DIGEST,
            "workspace",
            AT,
            "deviceMutation",
            None,
            &digest,
        );
        record.set_admission_evidence(json!({"kind": "runtimeCapability", "reference": "CAP-RT-SOURCE-PROOF",
            "admittedAtUTC": AT, "validUntilUTC": "2026-10-06T01:00:00Z", "consumptionFingerprintSHA256": "a".repeat(64),
            "runtimeCapabilityCorrelation": {"reservationID": "source-proof-idempotency", "useOrdinal": 1,
                "planDigestSHA256": digest, "stepSetDigestSHA256": crate::job_step_digest::step_set_digest(descriptor, &request_decoded.inputs).unwrap(),
                "targetBindingDigestSHA256": sha256_hex(b"-\n-")}}));
        record.state = "succeeded".into();
        record.start(AT);
        record.finish(AT);
        record.add_step_kind(kind);
        let envelope = |event_id: &str, sequence| Envelope {
            event_id: event_id.into(),
            sequence,
            session_id: "session-job-source-proof".into(),
            job_id: "job-source-proof".into(),
            timestamp: AT.into(),
        };
        let step = json!({"id": id, "kind": kind, "effect": "deviceMutation", "cancellation": cancellation,
            "bindingRequirement": "none", "compensationDescriptors": [], "arguments": materialization.document["steps"][0]["journalArguments"]});
        let target = events::Target {
            scope: "host".into(),
            target_id: "workspace-host".into(),
            connect_key: None,
            identity_snapshot_hash: None,
        };
        let events = vec![
            events::job_created(
                &envelope("created", 0),
                "execute",
                "standardAgent",
                "CORE-2.0.0",
            ),
            events::state_transition(
                &envelope("preflight", 1),
                "queued",
                "preflight",
                "admitted",
                None,
            ),
            events::state_transition(
                &envelope("running", 2),
                "preflight",
                "running",
                "steps-start",
                None,
            ),
            events::step_intent(&envelope("intent", 3), &step, &target, 1, None).unwrap(),
            events::step_outcome(
                &envelope("outcome", 4),
                id,
                1,
                "intent",
                "succeeded",
                "confirmed",
                None,
                None,
            ),
            events::state_transition(
                &envelope("finalizing", 5),
                "running",
                "finalizing",
                "steps-done",
                None,
            ),
            events::state_transition(
                &envelope("succeeded", 6),
                "finalizing",
                "succeeded",
                "complete",
                None,
            ),
        ];
        let mut journal = JournalWriter::open(&root.join("job"), true).unwrap();
        for event in &events {
            journal.append(event).unwrap();
        }
        let replay = journal.facts();
        drop(journal);
        Self {
            root,
            workspace,
            artifacts,
            record,
            materialization,
            events,
            replay,
        }
    }

    fn context(&self, cached: bool) -> WorkspaceSessionContext<'_> {
        WorkspaceSessionContext {
            planner: crate::JobPlanner {
                artifacts: Some(&self.artifacts),
                imports: None,
                analyzer: None,
                state_root: &self.root,
                hdc: None,
                workspace: Some(&self.workspace),
            },
            materialization: cached.then_some(&self.materialization),
        }
    }

    fn manifest(&self, cached: bool) -> Result<Value, Stop> {
        compose_with_workspace(
            &self.record,
            &self.events,
            &self.replay,
            AT,
            Some(self.context(cached)),
        )
        .map(|bytes| serde_json::from_slice(&bytes).unwrap())
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn successful_build_and_tests_keep_the_original_consumption_and_actual_same_sha_version() {
    for operation in ["workspace.build-openharmony@1", "workspace.run-tests@1"] {
        let fixture = Fixture::new(operation, false);
        let digest = fixture.materialization.document["steps"][0]["executableSHA256"]
            .as_str()
            .unwrap();
        let tool = arkdeck_platform::VerifiedTool::open(
            fixture.materialization.executable_path.as_ref().unwrap(),
            digest,
        )
        .unwrap();
        assert_eq!(tool.file_version().unwrap(), "24.14.1.0");
        let manifest = fixture
            .manifest(false)
            .unwrap_or_else(|stop| panic!("{}: {}", stop.reason, stop.detail));
        assert_eq!(manifest["toolchain"]["reportedVersion"], "24.14.1.0");
        assert_eq!(
            manifest["runtimeAuthority"]["planDigest"],
            fixture.record.materialized_plan().unwrap()
        );
        assert_eq!(
            manifest["runtimeAuthority"]["consumptionFingerprintSha256"],
            "a".repeat(64)
        );
        assert_eq!(manifest["originalTarget"]["kind"], "host");
        assert_eq!(manifest["bindingHistory"], json!([]));
        assert_eq!(manifest["steps"][0]["effect"], "deviceMutation");
    }
}

#[test]
fn original_materialized_document_bytes_still_match_the_preexisting_plan_layout() {
    let fixture = Fixture::new("workspace.build-openharmony@1", true);
    let action = fixture
        .workspace
        .build_action(
            fixture.record.operation(),
            fixture.record.request["inputs"].as_object().unwrap(),
        )
        .unwrap();
    let invocation = &action.invocation;
    let expected = json!({"operationReference": "workspace.build-openharmony@1", "catalogDigest": arkdeck_contract::CATALOG_DIGEST,
        "inputs": fixture.record.request["inputs"], "targetID": "workspace-host", "providerID": "workspace",
        "steps": [{"stepID": "build-project", "kind": "buildWorkspaceOpenHarmony", "effect": "deviceMutation",
            "cancellation": "immediate", "binding": "none", "isOptional": false, "processKind": "process",
            "journalArguments": {"projectRef": "fixture-project", "buildPresetRef": "build"},
            "executableSHA256": invocation.executable_sha256, "workingDirectory": invocation.project_root,
            "argumentSummary": ["/c", "exit", "0"], "timeoutSeconds": 10}]});
    assert_eq!(
        crate::session_json::encode(&fixture.materialization.document).unwrap(),
        crate::session_json::encode(&expected).unwrap()
    );
    assert_eq!(
        fixture.manifest(true).unwrap()["toolchain"]["reportedVersion"],
        env!("CARGO_PKG_VERSION")
    );
}

#[test]
fn drifted_plan_step_set_authority_tool_and_host_declarations_are_refused() {
    type Edit = fn(&mut Fixture);
    let changes: &[Edit] = &[
        |f| f.materialization.document["steps"][0]["argumentSummary"] = json!(["foreign"]),
        |f| {
            let mut a = f.record.admission().unwrap().clone();
            a["runtimeCapabilityCorrelation"]["stepSetDigestSHA256"] = json!("b".repeat(64));
            f.record.set_admission_evidence(a);
        },
        |f| {
            let mut a = f.record.admission().unwrap().clone();
            a["kind"] = json!("defaultReadOnlyPolicy");
            f.record.set_admission_evidence(a);
        },
        |f| f.events[3]["payload"]["step"]["effect"] = json!("destructive"),
        |f| f.events[3]["payload"]["target"]["scope"] = json!("device"),
        |f| f.events[3]["bindingRevision"] = json!(1),
        |f| f.events[3]["payload"]["step"]["kind"] = json!("installPackage"),
        |f| f.events[4]["payload"]["outcomeCertainty"] = json!("outcomeUnknown"),
        |f| f.events[3]["payload"]["step"]["compensationDescriptors"] = json!([{}]),
        |f| f.events.push(f.events[3].clone()),
        |f| f.replay.has_torn_tail = true,
        |f| {
            f.materialization.executable_path =
                Some(f.root.join("missing.exe").to_string_lossy().into_owned())
        },
    ];
    for (index, change) in changes.iter().enumerate() {
        let mut fixture = Fixture::new("workspace.build-openharmony@1", true);
        change(&mut fixture);
        assert!(fixture.manifest(true).is_err(), "change {index}");
    }
}

#[test]
fn copied_runtime_bytes_cannot_borrow_the_current_image_version() {
    let fixture = Fixture::new("workspace.build-openharmony@1", true);
    let path = fixture.root.join("copy.exe");
    std::fs::copy(std::env::current_exe().unwrap(), &path).unwrap();
    let tool = arkdeck_platform::VerifiedTool::open(
        &path,
        fixture.materialization.document["steps"][0]["executableSHA256"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert!(
        tool_version(&tool).is_err(),
        "a different native file has no Runtime-owned version provenance"
    );
}

#[test]
fn host_manifest_arguments_remain_closed_and_typed_with_valid_argument_hashes() {
    for operation in ["workspace.build-openharmony@1", "workspace.run-tests@1"] {
        let fixture = Fixture::new(operation, true);
        let original = fixture.manifest(true).unwrap();
        let preset = if operation == "workspace.build-openharmony@1" {
            "buildPresetRef"
        } else {
            "testPresetRef"
        };
        for change in 0..4 {
            let mut manifest = original.clone();
            let mut arguments = manifest["steps"][0]["arguments"].clone();
            match change {
                0 => arguments[preset] = Value::Null,
                1 => arguments[preset] = json!(""),
                2 => {
                    arguments.as_object_mut().unwrap().remove("projectRef");
                }
                _ => arguments["foreign"] = json!("argument"),
            }
            set_arguments(&mut manifest, arguments);
            assert!(
                crate::session_manifest::decode_manifest(
                    &crate::session_json::encode(&manifest).unwrap()
                )
                .is_err(),
                "{operation} change {change}"
            );
        }
    }
}

#[test]
fn a_physical_associated_patch_uses_its_original_pre_write_plan_and_keeps_all_artifact_proof() {
    use crate::artifact_publication::{ArtifactPublisher, Product};
    let mut fixture = Fixture::new("workspace.build-openharmony@1", true);
    let patch = b"--- a/App.txt\n+++ b/App.txt\n@@ -1 +1 @@\n-old\n+new\n";
    std::fs::write(fixture.root.join("source/App.txt"), b"old\n").unwrap();
    let publisher = ArtifactPublisher {
        store: &fixture.artifacts,
        quota: 1024 * 1024,
        home: "",
        now: || Some(AT.into()),
    };
    let row = publisher.publish(&Product {job_id: "job-patch-input", session_id: "session-job-patch-input",
        step_id: "create-checkpoint", name: "fix.patch", media_type: "text/x-diff", privacy: "standard",
        retention_class: "default", source_operation: "workspace.create-checkpoint@1", provider_id: "workspace",
        binding: json!({"targetID": "TGT-PHYSICAL-ASSOCIATION", "bindingRevision": 7, "stableIdentitySHA256": "c".repeat(64)}),
        observation_window: None}, patch).unwrap();
    let reference = "workspace.apply-patch@1";
    let descriptor = CatalogOperation::lookup("workspace.apply-patch", Some(1)).unwrap();
    let mut request = fixture.record.request.clone();
    request["operation"]["id"] = json!("workspace.apply-patch");
    request["target"]["targetId"] = json!("TGT-PHYSICAL-ASSOCIATION");
    request["inputs"] = json!({"projectRef": "fixture-project", "patchArtifactRef": format!("lease-v1:job-patch-input:{}", row["artifactID"].as_str().unwrap()),
        "allowedFileGlobs": ["App.txt"]});
    // The exact revision is taken after the input source file exists.
    let profile = fixture
        .workspace
        .registry
        .profile("fixture-project")
        .unwrap();
    request["inputs"]["expectedWorkspaceRevision"] = json!(
        crate::workspace_support::workspace_revision(
            &profile.project_root,
            &profile.profile_id,
            &profile.allowed_file_globs
        )
        .unwrap()
    );
    let decoded =
        OperationRequest::decode(&crate::session_json::encode(&request).unwrap()).unwrap();
    fixture.materialization = fixture
        .context(false)
        .planner
        .workspace_materialization(&decoded, descriptor)
        .unwrap();
    let plan = fixture.materialization.digest().unwrap();
    let mut original = request.clone();
    original.as_object_mut().unwrap().remove("authorization");
    fixture.record = JobRecord::admitted(
        "job-source-proof",
        request,
        original,
        reference,
        arkdeck_contract::CATALOG_DIGEST,
        "workspace",
        AT,
        "deviceMutation",
        None,
        &plan,
    );
    fixture.record.state = "succeeded".into();
    fixture.record.start(AT);
    fixture.record.finish(AT);
    fixture.record.add_step_kind("applyWorkspacePatch");
    let artifact = sha256_hex(patch);
    fixture.record.set_admission_evidence(json!({"kind": "runtimeCapability", "reference": "CAP-RT-SOURCE-PROOF", "admittedAtUTC": AT,
        "validUntilUTC": "2026-10-06T01:00:00Z", "consumptionFingerprintSHA256": "a".repeat(64),
        "runtimeCapabilityCorrelation": {"reservationID": "source-proof-idempotency", "useOrdinal": 1, "planDigestSHA256": plan,
            "stepSetDigestSHA256": crate::job_step_digest::step_set_digest(descriptor, &decoded.inputs).unwrap(),
            "targetBindingDigestSHA256": sha256_hex(b"-\n-"), "artifactSHA256": artifact}}));
    let mut args = fixture.materialization.document["steps"][0]["journalArguments"].clone();
    let attempt = sha256_hex(format!("job-source-proof\n{artifact}\nfixture-project").as_bytes());
    args["patchAttemptRef"] = json!(format!("patch-{}", &attempt[..32]));
    let envelope = Envelope {
        event_id: "intent".into(),
        sequence: 3,
        session_id: "session-job-source-proof".into(),
        job_id: "job-source-proof".into(),
        timestamp: AT.into(),
    };
    fixture.events[3] = events::step_intent(&envelope, &json!({"id": "apply-patch", "kind": "applyWorkspacePatch", "effect": "deviceMutation",
        "cancellation": "atSafeBoundary", "bindingRequirement": "none", "compensationDescriptors": [], "arguments": args}),
        &events::Target {scope: "host".into(), target_id: "TGT-PHYSICAL-ASSOCIATION".into(), connect_key: None, identity_snapshot_hash: None}, 1, None).unwrap();
    fixture.events[4]["stepId"] = json!("apply-patch");
    // Model the completed effect without launching the patch tool. The normal
    // provider revision guard now refuses to rematerialize the original request.
    std::fs::write(fixture.root.join("source/App.txt"), b"new\n").unwrap();
    assert!(
        fixture
            .context(false)
            .planner
            .workspace_materialization(&decoded, descriptor)
            .is_err()
    );
    let manifest = fixture.manifest(true).unwrap();
    assert_eq!(
        manifest["originalTarget"]["identitySnapshot"]["workspaceScope"],
        "TGT-PHYSICAL-ASSOCIATION"
    );
    assert_eq!(manifest["originalTarget"]["connectKey"], Value::Null);
    assert_eq!(manifest["bindingHistory"], json!([]));
    assert_eq!(manifest["runtimeAuthority"]["artifactDigest"], artifact);
    assert_eq!(manifest["runtimeAuthority"]["planDigest"], plan);
    for (pointer, value) in [
        ("/runtimeAuthority/artifactDigest", json!("b".repeat(64))),
        ("/runtimeAuthority/stepSetDigest", json!("b".repeat(64))),
        (
            "/originalTarget/identitySnapshot/projectRef",
            json!("foreign-project"),
        ),
        ("/steps/0/kind", json!("installPackage")),
        ("/runtimeAuthority", Value::Null),
    ] {
        let mut bad = manifest.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        assert!(
            crate::session_manifest::decode_manifest(&crate::session_json::encode(&bad).unwrap())
                .is_err(),
            "{pointer}"
        );
    }
    for change in 0..4 {
        let mut bad = manifest.clone();
        let mut arguments = bad["steps"][0]["arguments"].clone();
        match change {
            0 => {
                arguments.as_object_mut().unwrap().remove("patchSha256");
                bad["runtimeAuthority"]["artifactDigest"] = Value::Null;
            }
            1 => arguments["allowedFileGlobs"] = json!([]),
            2 => arguments["allowedFileGlobs"] = json!([null]),
            _ => arguments["patchArtifactId"] = Value::Null,
        }
        set_arguments(&mut bad, arguments);
        assert!(
            crate::session_manifest::decode_manifest(&crate::session_json::encode(&bad).unwrap())
                .is_err(),
            "apply change {change}"
        );
    }
}
