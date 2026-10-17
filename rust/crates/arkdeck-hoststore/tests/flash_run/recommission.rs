//! Synthetic Runtime ownership tests, never hardware acceptance evidence.
use super::*;
use arkdeck_hoststore::JobArchiver;

fn expired() -> Option<String> {
    Some("2026-09-25T05:00:00Z".into())
}
fn expired_precise() -> Option<String> {
    Some("2026-09-25T05:00:00.000Z".into())
}
fn later() -> Option<String> {
    Some("2026-09-25T05:30:00Z".into())
}
fn later_precise() -> Option<String> {
    Some("2026-09-25T05:30:00.000Z".into())
}

fn archived(owners: &Owners, fakes: &Fakes) -> String {
    fakes.begin(Script {
        perform: "outcomeUnknown".into(),
        ..Default::default()
    });
    // Materialize against this build's Catalog; historical golden requests retain
    // their original reviewed plan digest and are never rewritten.
    let params = recorded("failures", "prewarmRefused.submit")["params"].clone();
    let submit = owners.answer(fakes, "job.submit", params.as_object().unwrap());
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"))
        .to_owned();
    let run = owners.answer(fakes, "job.run", json!({"jobId": job}).as_object().unwrap());
    assert_eq!(run["result"]["state"], "waitingForRecovery", "{run}");
    let publisher = SessionPublisher {
        sessions: &owners.sessions,
        claims: &owners.claims,
        probe: &owners.probe,
    };
    let archive = JobArchiver {
        jobs: &owners.jobs,
        now: expired,
        sessions: Some(&publisher),
    };
    let preview = archive
        .preview(json!({"jobId": job}).as_object().unwrap())
        .unwrap();
    assert_eq!(preview["canArchive"], true, "{preview}");
    let archived = archive
        .archive(
            json!({"jobId": job, "expectedReviewSha256": preview["reviewSha256"],
        "userConfirmationId": "fixture-retain-unknown"})
            .as_object()
            .unwrap(),
        )
        .unwrap();
    assert_eq!(archived["sessionPublished"], true, "{archived}");
    assert_eq!(archived["outcomeUnknown"], true);
    job
}

fn request(source: &str, id: &str) -> Value {
    let mut request: Value = serde_json::from_str(
        recorded("failures", "prewarmRefused.submit")["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    request["requestId"] = json!(format!("req-recommission-{id}"));
    request["idempotencyKey"] = json!(format!("idem-recommission-{id}"));
    request["operation"] = json!({"id": "flash.recommission", "version": 1});
    request["inputs"]["retainedJobId"] = json!(source);
    request["inputs"]["verification"] = json!("full");
    json!({"requestJson": request.to_string()})
}

fn call(owners: &Owners, fakes: &Fakes, method: &str, params: &Value) -> Value {
    owners.answer_with_clock(
        fakes,
        method,
        params.as_object().unwrap(),
        expired,
        expired_precise,
    )
}

fn history(owners: &Owners, source: &str) -> Vec<Vec<u8>> {
    [
        "job-record.json",
        "journal.jsonl",
        "arkforge-runtime-state.json",
    ]
    .iter()
    .map(|name| fs::read(owners.state_root().join("jobs").join(source).join(name)).unwrap())
    .collect()
}

#[test]
fn independent_recommission_preserves_history_and_publishes_one_verified_binding() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    let state = owners.state_root();
    let authority = MutationAuthority {
        default_root: &state,
        sessions: Some(&owners.sessions),
        capabilities: &owners.capabilities,
        holds: &owners.holds,
    };
    assert!(
        authority.require_state(&owners.jobs).is_err(),
        "ordinary mutations retain the old unknown blocker"
    );
    let source_record = owners.jobs.read_snapshot(&source).unwrap();
    let cap_params =
        json!({"capabilityId": source_record.request["authorization"]["capabilityId"]});
    let old_budget = owners
        .capabilities
        .handle("capability.inspect", cap_params.as_object().unwrap())
        .unwrap();
    let target = source_record.request["target"]["targetId"]
        .as_str()
        .unwrap();
    fakes.begin(Script::default());
    let params = request(&source, "success");
    let submit = call(&owners, &fakes, "job.submit", &params);
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"))
        .to_owned();
    assert_eq!(
        call(&owners, &fakes, "job.submit", &params)["result"]["jobId"],
        job
    );
    assert_eq!(fakes.calls(), (vec![], vec![]));
    let allocated = fs::read(root.join("store/flash-recommission-allocations.json")).unwrap();
    let again = call(&owners, &fakes, "job.submit", &request(&source, "new-id"));
    assert_eq!(again["ok"], false, "{again}");
    assert_eq!(
        fs::read(root.join("store/flash-recommission-allocations.json")).unwrap(),
        allocated
    );
    let run = call(&owners, &fakes, "job.run", &json!({"jobId": job}));
    assert_eq!(run["result"]["state"], "recovered", "{run}");
    assert!(
        authority.require_state(&owners.jobs).is_ok(),
        "only durable supersession accounts for the retained Session"
    );
    assert_eq!(
        call(&owners, &fakes, "job.evidence", &json!({"jobId":job}))["ok"],
        true
    );
    assert_eq!(history(&owners, &source), original);
    assert_eq!(
        owners
            .capabilities
            .handle("capability.inspect", cap_params.as_object().unwrap())
            .unwrap(),
        old_budget
    );
    let records = owners.targets.records().unwrap();
    let advanced = records
        .iter()
        .find(|record| record["targetID"] == target)
        .unwrap();
    assert_eq!(advanced["bindingRevision"], 2);
    assert_eq!(
        advanced["stablePhysicalIdentitySHA256"],
        arkdeck_contract::sha256_hex(b"factory-loader-serial")
    );
    assert_eq!(
        call(&owners, &fakes, "job.status", &json!({"jobId":source}))["result"]["outcomeUnknown"],
        true
    );
    let epochs = fs::read(root.join("store/superseding-recovery-epochs.json")).unwrap();
    drop(owners);
    let restarted = Owners::open(&root, &fakes);
    fakes.begin(Script::default());
    let duplicate = call(&restarted, &fakes, "job.submit", &params);
    assert_eq!(duplicate["result"]["jobId"], job);
    assert_eq!(fakes.calls(), (vec![], vec![]));
    assert_eq!(history(&restarted, &source), original);
    assert_eq!(
        fs::read(root.join("store/superseding-recovery-epochs.json")).unwrap(),
        epochs
    );
}

#[test]
fn expired_allocation_and_unclosed_provider_dispatch_nothing_and_never_renew() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    fakes.begin(Script {
        prepare: "sourceBusy".into(),
        ..Default::default()
    });
    let params = request(&source, "expired");
    let blocked = call(&owners, &fakes, "job.submit", &params);
    assert_eq!(blocked["ok"], false, "{blocked}");
    assert!(
        blocked.to_string().contains("providerHasUnclosedJob"),
        "{blocked}"
    );
    assert!(
        !root
            .join("store/flash-recommission-allocations.json")
            .exists()
    );
    assert_eq!(fakes.calls(), (vec![], vec![]));
    fakes.begin(Script::default());
    let submit = call(&owners, &fakes, "job.submit", &params);
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"));
    let allocated = fs::read(root.join("store/flash-recommission-allocations.json")).unwrap();
    let run = owners.answer_with_clock(
        &fakes,
        "job.run",
        json!({"jobId":job}).as_object().unwrap(),
        later,
        later_precise,
    );
    assert_ne!(run["result"]["state"], "recovered", "{run}");
    assert!(
        fakes
            .calls()
            .0
            .iter()
            .all(|call| call.starts_with("prewarm ") || call.starts_with("finishPrewarm "))
    );
    let before: Value = serde_json::from_slice(&allocated).unwrap();
    let after: Value = serde_json::from_slice(
        &fs::read(root.join("store/flash-recommission-allocations.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        after["allocations"][0]["allocation"],
        before["allocations"][0]["allocation"]
    );
    assert_eq!(after["allocations"][0]["budgetClosed"], true);
    assert_eq!(after["allocations"][0]["consumed"], false);
    assert_eq!(history(&owners, &source), original);
    assert!(!root.join("store/superseding-recovery-epochs.json").exists());
}

#[test]
fn postflight_identity_drift_retains_unknown_and_burns_the_independent_epoch() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    fakes.begin(Script {
        perform: "postflightIdentityDrift".into(),
        ..Default::default()
    });
    let params = request(&source, "drift");
    let submit = call(&owners, &fakes, "job.submit", &params);
    let job = submit["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submit}"));
    let run = call(&owners, &fakes, "job.run", &json!({"jobId": job}));
    assert_ne!(run["result"]["state"], "recovered", "{run}");
    let record = owners.jobs.read_snapshot(job).unwrap();
    assert!(
        record
            .timeline
            .iter()
            .any(|line| line.contains("postflightOrHistoryDrifted")),
        "{:?}",
        record.timeline
    );
    assert!(!root.join("store/superseding-recovery-epochs.json").exists());
    let ledger: Value = serde_json::from_slice(
        &fs::read(root.join("store/flash-recommission-allocations.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(ledger["allocations"][0]["consumed"], true);
    assert!(ledger["allocations"][0]["postflight"].is_null());
    assert_eq!(history(&owners, &source), original);
    fakes.begin(Script::default());
    let retry = call(
        &owners,
        &fakes,
        "job.submit",
        &request(&source, "after-drift"),
    );
    assert_eq!(retry["ok"], false, "{retry}");
    assert_eq!(fakes.calls(), (vec![], vec![]));
    assert!(
        owners
            .targets
            .records()
            .unwrap()
            .iter()
            .all(|record| record["bindingRevision"] == 1)
    );
}

#[test]
fn an_unknown_recommission_cannot_allocate_another_epoch_after_restart() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    fakes.begin(Script {
        perform: "outcomeUnknown".into(),
        ..Default::default()
    });
    let submitted = call(
        &owners,
        &fakes,
        "job.submit",
        &request(&source, "new-unknown"),
    );
    let job = submitted["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submitted}"));
    let run = call(&owners, &fakes, "job.run", &json!({"jobId":job}));
    assert_eq!(run["result"]["state"], "waitingForRecovery", "{run}");
    assert_eq!(run["result"]["outcomeUnknown"], true);
    let ledger = fs::read(root.join("store/flash-recommission-allocations.json")).unwrap();
    drop(owners);
    let owners = Owners::open(&root, &fakes);
    recover_active_jobs(&owners.jobs, Some(&owners.capabilities), expired).unwrap();
    fakes.begin(Script::default());
    let again = call(
        &owners,
        &fakes,
        "job.submit",
        &request(&source, "after-new-unknown"),
    );
    assert_eq!(again["ok"], false, "{again}");
    assert_eq!(
        fs::read(root.join("store/flash-recommission-allocations.json")).unwrap(),
        ledger
    );
    assert_eq!(history(&owners, &source), original);
    assert_eq!(fakes.calls(), (vec![], vec![]));
    assert!(!root.join("store/superseding-recovery-epochs.json").exists());
}

#[test]
fn durable_epoch_repairs_a_crash_before_binding_and_terminal_publication_without_dispatch() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    let target_path = root.join("targets-state/targets.json");
    let previous_target = fs::read(&target_path).unwrap();
    fakes.begin(Script::default());
    let submitted = call(&owners, &fakes, "job.submit", &request(&source, "crash"));
    let job = submitted["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submitted}"))
        .to_owned();
    assert_eq!(
        call(&owners, &fakes, "job.run", &json!({"jobId":job}))["result"]["state"],
        "recovered"
    );
    let epochs = fs::read(root.join("store/superseding-recovery-epochs.json")).unwrap();
    drop(owners);
    // Synthetic loss of the projections after the durable epoch; these are
    // task-owned fixture files, never production state or hardware evidence.
    fs::write(&target_path, previous_target).unwrap();
    let job_dir = root.join("store/jobs").join(&job);
    let journal = fs::read_to_string(job_dir.join("journal.jsonl")).unwrap();
    let mut lines: Vec<_> = journal.lines().collect();
    assert!(lines.pop().unwrap().contains("\"to\":\"recovered\""));
    fs::write(
        job_dir.join("journal.jsonl"),
        format!("{}\n", lines.join("\n")),
    )
    .unwrap();
    let mut record = support::document(&job_dir, "job-record.json");
    record["state"] = json!("finalizing");
    record.as_object_mut().unwrap().remove("finishedAtUTC");
    fs::write(
        job_dir.join("job-record.json"),
        serde_json::to_vec(&record).unwrap(),
    )
    .unwrap();
    let owners = Owners::open(&root, &fakes);
    fakes.begin(Script::default());
    arkdeck_hoststore::reconcile_rockchip_startup(&owners.targets, &owners.state_root()).unwrap();
    let recovered = recover_jobs(
        &owners.jobs,
        std::slice::from_ref(&job),
        Some(&owners.capabilities),
        expired,
    )
    .unwrap();
    assert_eq!(recovered.statuses[0]["state"], "recovered");
    assert!(
        owners
            .targets
            .records()
            .unwrap()
            .iter()
            .any(|target| target["bindingRevision"] == 2)
    );
    assert_eq!(
        fs::read(root.join("store/superseding-recovery-epochs.json")).unwrap(),
        epochs
    );
    assert_eq!(history(&owners, &source), original);
    assert_eq!(fakes.calls(), (vec![], vec![]));
}

#[test]
fn changed_published_archive_blocks_without_allocating_or_dispatching() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = archived(&owners, &fakes);
    let original = history(&owners, &source);
    let record = owners.jobs.read_snapshot(&source).unwrap();
    let encoded = serde_json::to_value(record).unwrap();
    let relative = encoded["sessionPublicationRecord"]["relativeSessionPath"]
        .as_str()
        .unwrap();
    let manifest = root.join("Sessions").join(relative).join("manifest.json");
    let mut changed = fs::read(&manifest).unwrap();
    changed.push(b'\n');
    fs::write(&manifest, &changed).unwrap();
    fakes.begin(Script::default());
    let blocked = call(&owners, &fakes, "job.submit", &request(&source, "tampered"));
    assert_eq!(blocked["ok"], false, "{blocked}");
    assert!(
        !root
            .join("store/flash-recommission-allocations.json")
            .exists()
    );
    assert_eq!(history(&owners, &source), original);
    assert_eq!(fs::read(manifest).unwrap(), changed);
    assert_eq!(fakes.calls(), (vec![], vec![]));
}
