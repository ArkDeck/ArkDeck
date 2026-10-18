//! Exercises Runtime ownership with synthetic Provider/reader ports. The
//! private program cache is a fixture, not an imported proof or device result.
use super::*;
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ImportBinding, MaintenanceContext, OperationRequest};
use arkdeck_platform::HostDirectory;
use support::flash_lane::controlled_retry::{Plans, plans};

fn call_retry(owners: &Owners, fakes: &Fakes, method: &str, params: &Value) -> Value {
    owners.answer_with_clock(
        fakes,
        method,
        params.as_object().unwrap(),
        later,
        later_precise,
    )
}

fn failed_first(owners: &Owners, fakes: &Fakes, source: &str) -> String {
    fakes.begin(Script {
        perform: "outcomeUnknown".into(),
        ..Default::default()
    });
    let submit = call(
        owners,
        fakes,
        "job.submit",
        &request(source, "first-unknown"),
    );
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"))
        .to_owned();
    let run = call(owners, fakes, "job.run", &json!({"jobId": job}));
    assert_eq!(run["result"]["state"], "waitingForRecovery", "{run}");
    job
}

fn restoration(owners: &Owners, target: &str, identity: &str) -> (String, String) {
    let mut bytes =
        fs::read(support::fixture("flash-archive").join("archives/complete.tar.gz")).unwrap();
    // A distinct immutable artifact with the same valid synthetic archive body.
    bytes[4] = bytes[4].wrapping_add(17);
    let digest = sha256_hex(&bytes);
    let binding = |intent: &ImportIntent| -> Result<ImportBinding, WireError> {
        Ok(ImportBinding {
            target_id: intent.target_id.clone(),
            binding_revision: Some(1),
            stable_identity_sha256: Some(identity.into()),
        })
    };
    let begun = owners.imports.handle_resource("artifact.import.begin", json!({
        "schemaVersion":"arkdeck.import-intent/1", "importRequestId":"controlled-restoration",
        "kind":"flash-bundle", "targetId":target, "bindingRevision":"1", "deviceProfile":"dayu200",
        "name":"images.tar.gz", "byteCount":bytes.len().to_string(), "sha256":digest,
    }).as_object().unwrap(), &later().unwrap(), false, binding).unwrap();
    let id = begun["importId"].as_str().unwrap();
    if begun["state"] == "committed" {
        return (begun["receipt"]["lease"].as_str().unwrap().into(), digest);
    }
    owners
        .imports
        .handle_resource(
            "artifact.import.append",
            json!({
                "importId":id,"generation":"1","offset":"0","byteCount":bytes.len().to_string(),
                "sha256":digest,"base64":encode_import_chunk(&bytes).unwrap(),
            })
            .as_object()
            .unwrap(),
            &later().unwrap(),
            false,
            binding,
        )
        .unwrap();
    let committed = owners
        .imports
        .commit(
            json!({"importId":id,"generation":"1"}).as_object().unwrap(),
            &later().unwrap(),
            false,
            &owners.artifacts,
            1024 * 1024,
            binding,
        )
        .unwrap();
    (
        committed["receipt"]["lease"].as_str().unwrap().into(),
        digest,
    )
}

fn install(owners: &Owners, fakes: &Fakes, plans: &Plans) {
    fakes.controlled_retry(plans.clone());
    owners
        .flash
        .install_maintenance(Arc::new(MaintenanceContext::new(
            owners.jobs.clone(),
            owners.lane.clone(),
            Arc::new(fakes.clone()),
        )));
}

fn retry_request(owners: &Owners, fakes: &Fakes, source: &str, failed: &str, id: &str) -> Value {
    let mut raw: Value =
        serde_json::from_str(request(source, id)["requestJson"].as_str().unwrap()).unwrap();
    let target = raw["target"]["targetId"].as_str().unwrap().to_owned();
    let facts = fakes.recommission_facts(&target).unwrap();
    let (lease, restoration_sha) = restoration(owners, &target, &facts.identity_sha256);
    raw["inputs"]["failedRecommissionJobId"] = json!(failed);
    raw["inputs"]["restorationArtifactLease"] = json!(lease);
    let request = OperationRequest::decode(&serde_json::to_vec(&raw).unwrap()).unwrap();
    let key = request.fingerprint();
    // The primary fixture's import owns its payload digest independently of the
    // new program. Read that reviewed fixture input without altering it.
    let primary_sha: String = {
        let record: Value = serde_json::from_slice(&fs::read(fixture().join(
            "inputs/artifacts/.imports-v1/records/a395fa591aee0d71c83dfa0d5e8e101b9724a798df010c1176553e8723fc44de.json"
        )).unwrap()).unwrap();
        record["intent"]["sha256"].as_str().unwrap().into()
    };
    let plans = plans();
    install(owners, fakes, &plans);
    let identity: Value =
        serde_json::from_str(&facts.server_facts["dayu200RecommissionIdentityChain"]).unwrap();
    let program = json!({
        "schema":"arkdeck.recommission-retry-program/v1", "requestSha256":key,
        "identityChain":identity, "primarySha256":primary_sha, "restorationSha256":restoration_sha,
        "nonce":"0123456789abcdef0123456789abcdef",
        "primaryPlan":plans.primary.encode(), "restorationPlan":plans.restoration.encode(),
    });
    let directory = HostDirectory::open(&owners.state_root())
        .unwrap()
        .private_child("recommission-retry-plans")
        .unwrap();
    directory
        .create_document(
            &format!("{key}.json"),
            &serde_json::to_vec(&program).unwrap(),
        )
        .unwrap();
    json!({"requestJson":raw.to_string()})
}

fn ledger(root: &Path) -> Value {
    serde_json::from_slice(
        &fs::read(root.join("store/flash-recommission-allocations.json")).unwrap(),
    )
    .unwrap()
}

#[test]
fn controlled_retry_plan_uses_the_job_owner_when_runtime_state_is_separate() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let failed = failed_first(&owners, &fakes, &source);
    let originals = [history(&owners, &source), history(&owners, &failed)];
    let first_budget = ledger(&root);
    fakes.begin(Script::default());
    let params = retry_request(&owners, &fakes, &source, &failed, "separate-state-plan");
    // Windows production has a Runtime parent and a separate private Job store.
    // The planner's other owners may use that parent; retry programs belong to
    // the Job owner that also reads the proof during completion/reconciliation.
    let runtime_state = root.join("runtime-parent");
    HostDirectory::open_or_create_private(&runtime_state).unwrap();
    let facts = |target: &str, recommission: bool| {
        assert!(recommission);
        fakes.recommission_facts(target)
    };
    let planner = FlashPlanner {
        planner: owners.planner(&runtime_state),
        flash: Some(&owners.flash),
        facts: Some(&facts),
    };
    let plan = planner
        .handle(params.as_object().unwrap())
        .unwrap_or_else(|error| panic!("{}: {}", error.code, error.message));
    assert_eq!(plan["jobAdmitted"], false);
    assert_eq!(plan["dispatchDisposition"], "notDispatched");
    assert!(plan["providerAdmissionBlocker"].is_null());
    assert!(!runtime_state.join("recommission-retry-plans").exists());
    assert_eq!(ledger(&root), first_budget);
    assert_eq!(
        [history(&owners, &source), history(&owners, &failed)],
        originals
    );
}

#[test]
fn explicit_retry_covers_both_unknowns_and_restores_original_ramdisk_before_success() {
    successful_retry(false);
}

#[test]
fn controlled_retry_keeps_the_same_connector_across_new_usb_attachments() {
    successful_retry(true);
}

fn successful_retry(attachment_changes: bool) {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let failed = failed_first(&owners, &fakes, &source);
    let originals = [history(&owners, &source), history(&owners, &failed)];
    let first_budget = ledger(&root)["allocations"][0].clone();
    fakes.begin(if attachment_changes {
        Script {
            alias_topology: Some("84".into()),
            perform: "retryAttachmentChanges".into(),
            ..Default::default()
        }
    } else {
        Script::default()
    });
    let params = retry_request(&owners, &fakes, &source, &failed, "controlled-success");
    let submit = call_retry(&owners, &fakes, "job.submit", &params);
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"))
        .to_owned();
    let run = call_retry(&owners, &fakes, "job.run", &json!({"jobId":job}));
    let record = owners.jobs.read_snapshot(&job).unwrap();
    assert_eq!(
        run["result"]["state"], "recovered",
        "{run}: {:?}",
        record.timeline
    );
    assert_eq!(ledger(&root)["allocations"].as_array().unwrap().len(), 2);
    assert_eq!(ledger(&root)["allocations"][0], first_budget);
    assert_eq!(
        [history(&owners, &source), history(&owners, &failed)],
        originals
    );
    let epochs: Value = serde_json::from_slice(
        &fs::read(root.join("store/superseding-recovery-epochs.json")).unwrap(),
    )
    .unwrap();
    let epoch_text = epochs.to_string();
    assert!(
        epoch_text.contains(&source) && epoch_text.contains(&failed),
        "{epochs}"
    );
    let proof: Value = serde_json::from_slice(
        &fs::read(
            owners
                .state_root()
                .join("jobs")
                .join(&job)
                .join("recommission-full-readback.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(proof["primaryReads"].as_array().unwrap().len(), 9);
    assert_eq!(
        proof["restorationRead"]["sha256"],
        support::flash_lane::controlled_retry::ORIGINAL_RAMDISK
    );
    let calls = fakes.calls().0;
    assert_eq!(
        calls
            .iter()
            .filter(|call| call.starts_with("prepare "))
            .count(),
        2,
        "{calls:?}"
    );
    assert_eq!(
        calls
            .iter()
            .filter(|call| call.starts_with("perform "))
            .count(),
        2,
        "{calls:?}"
    );
    assert_eq!(
        calls
            .iter()
            .filter(|call| call.starts_with("readback "))
            .count(),
        10,
        "{calls:?}"
    );
    if attachment_changes {
        let preparations: Vec<_> = calls
            .iter()
            .filter(|call| call.starts_with("prepare "))
            .collect();
        assert!(preparations[0].contains(" topology=84 "), "{calls:?}");
        assert!(preparations[1].contains(" topology=126 "), "{calls:?}");
        assert_eq!(fakes.current().alias_topology.as_deref(), Some("168"));
        assert_eq!(
            first_budget["allocation"]["identityChain"]["usbTopology"],
            "42"
        );
        assert_eq!(
            ledger(&root)["allocations"][1]["allocation"]["identityChain"]["usbTopology"],
            "84"
        );
    }
    let target_id = record.request["target"]["targetId"].as_str().unwrap();
    let targets = owners.targets.records().unwrap();
    assert_eq!(
        targets
            .iter()
            .find(|target| target["targetID"] == target_id)
            .unwrap()["bindingRevision"],
        2
    );
    drop(owners);
    let restarted = Owners::open(&root, &fakes);
    fakes.begin(Script::default());
    let duplicate = call_retry(&restarted, &fakes, "job.submit", &params);
    assert_eq!(duplicate["result"]["jobId"], job, "{duplicate}");
    assert_eq!(fakes.calls(), (vec![], vec![]));
    assert_eq!(
        [history(&restarted, &source), history(&restarted, &failed)],
        originals
    );
    assert_eq!(ledger(&root)["allocations"][0], first_budget);
}

#[test]
fn controlled_retry_failures_preserve_both_histories_and_never_allocate_a_third_budget() {
    let _lock = exclusive();
    for fault in [
        "retryMissingPreboot",
        "retryWrongHash",
        "retryIdentityDrift",
        "retryAttachmentDuringRead",
        "retrySourceWrite",
        "retryRestoreUnknown",
        "retryRestoreRead",
    ] {
        let root = lay_down();
        let fakes = Fakes::default();
        let owners = Owners::open(&root, &fakes);
        let source = archived(&owners, &fakes);
        let failed = failed_first(&owners, &fakes, &source);
        let originals = [history(&owners, &source), history(&owners, &failed)];
        let first_budget = ledger(&root)["allocations"][0].clone();
        fakes.begin(Script {
            perform: fault.into(),
            ..Default::default()
        });
        let params = retry_request(&owners, &fakes, &source, &failed, fault);
        let submit = call_retry(&owners, &fakes, "job.submit", &params);
        let job = submit["result"]["jobId"]
            .as_str()
            .unwrap_or_else(|| panic!("{fault}: {submit}"));
        let run = call_retry(&owners, &fakes, "job.run", &json!({"jobId":job}));
        assert_eq!(
            run["result"]["state"], "waitingForRecovery",
            "{fault}: {run}"
        );
        assert_eq!(run["result"]["outcomeUnknown"], true, "{fault}: {run}");
        assert_eq!(ledger(&root)["allocations"][0], first_budget, "{fault}");
        assert_eq!(ledger(&root)["allocations"][1]["consumed"], true, "{fault}");
        assert!(
            ledger(&root)["allocations"][1]["postflight"].is_null(),
            "{fault}"
        );
        assert_eq!(
            [history(&owners, &source), history(&owners, &failed)],
            originals,
            "{fault}"
        );
        assert!(
            !root.join("store/superseding-recovery-epochs.json").exists(),
            "{fault}"
        );
        assert!(
            owners
                .targets
                .records()
                .unwrap()
                .iter()
                .all(|target| target["bindingRevision"] == 1)
        );
        let allocated = ledger(&root);
        drop(owners);
        let restarted = Owners::open(&root, &fakes);
        fakes.begin(Script {
            terminal: "completed".into(),
            ..Default::default()
        });
        install(&restarted, &fakes, &plans());
        let reconciled = call_retry(&restarted, &fakes, "job.reconcile", &json!({"jobId":job}));
        assert_eq!(
            restarted.jobs.read_snapshot(job).unwrap().state,
            "waitingForRecovery",
            "{fault}: {reconciled}"
        );
        assert!(
            !root.join("store/superseding-recovery-epochs.json").exists(),
            "{fault}"
        );
        assert_eq!(ledger(&root), allocated, "{fault}");
        assert!(
            fakes
                .calls()
                .0
                .iter()
                .all(|call| call.starts_with("observe ")),
            "{fault}: {:?}",
            fakes.calls()
        );
        assert!(fakes.calls().1.is_empty(), "{fault}");
        fakes.begin(Script::default());
        let third = retry_request(&restarted, &fakes, &source, &failed, "third-is-forbidden");
        let refused = call_retry(&restarted, &fakes, "job.submit", &third);
        assert_eq!(refused["ok"], false, "{fault}: {refused}");
        assert_eq!(ledger(&root), allocated, "{fault}");
        assert_eq!(fakes.calls(), (vec![], vec![]));
    }
}
