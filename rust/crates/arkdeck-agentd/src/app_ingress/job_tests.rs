//! Synthetic peer/source fixtures exercise the real App admission gate.
use super::*;
use arkdeck_contract::{Response, WireError};
use std::sync::{Barrier, Mutex};

/// Swift's App transport refuses every Job request outside its typed gate,
/// and every Job the App did not submit, with this code.
const NOT_ALLOWLISTED: &str = "methodNotAllowlisted";

struct Owner {
    calls: Arc<Mutex<Vec<String>>>,
    entered: Arc<Barrier>,
    release: Arc<Barrier>,
    refuse_submit: bool,
}
impl HostServices for Owner {
    fn observations(&self) -> Result<arkdeck_contract::DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "unused fixture observation".into(),
            details: None,
        })
    }
    fn observed_at(&self) -> String {
        "2026-09-22T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "fixture")
    }
    fn job_submit(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push("submit".into());
        if self.refuse_submit {
            return Err(WireError {
                code: "internalError".into(),
                message: "lost admission receipt".into(),
                details: None,
            });
        }
        Ok(
            json!({"schemaVersion":"arkdeck.job-acceptance/1","jobId":"job-owned","deduplicated":false,"newDispatchCount":0}),
        )
    }
    fn job_run(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push("run".into());
        self.entered.wait();
        self.release.wait();
        Err(WireError {
            code: "recordUnreadable".into(),
            message: "execution outcome cannot be observed".into(),
            details: None,
        })
    }
    fn job_cancel(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push("cancel".into());
        Ok(json!({"cancelRequested":true}))
    }
}
type OwnerFixture = (
    Arc<AppIngress<Owner>>,
    Arc<Mutex<Vec<String>>>,
    Arc<Barrier>,
    Arc<Barrier>,
);
fn owner(root: &Root, refuse_submit: bool) -> OwnerFixture {
    let calls = Arc::new(Mutex::new(vec![]));
    let entered = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let control = Arc::new(
        Control::new(Owner {
            calls: calls.clone(),
            entered: entered.clone(),
            release: release.clone(),
            refuse_submit,
        })
        .unwrap(),
    );
    (
        Arc::new(AppIngress::new(control, root.peer().euid)),
        calls,
        entered,
        release,
    )
}
#[test]
fn app_run_is_owned_once_parallel_cancel_enters_and_unknown_never_replays() {
    let root = Root::new();
    let (ingress, calls, entered, release) = owner(&root, false);
    let run = frame("job.run", json!({"jobId":"job-owned"}));
    let cancel = frame("job.cancel", json!({"jobId":"job-owned"}));
    for request in [&run, &cancel] {
        assert_eq!(code(&ingress.handle(request, root.peer())), NOT_ALLOWLISTED);
    }
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(
        result(
            &ingress.handle(&submit(&capture()), root.peer()),
            "job.submit"
        )["jobId"],
        "job-owned"
    );
    let running = {
        let ingress = ingress.clone();
        let run = run.clone();
        let peer = root.peer();
        std::thread::spawn(move || ingress.handle(&run, peer))
    };
    entered.wait();
    // A deduplicated submit while the first run is in flight cannot start a second.
    result(
        &ingress.handle(&submit(&capture()), root.peer()),
        "job.submit",
    );
    assert_eq!(code(&ingress.handle(&run, root.peer())), NOT_ALLOWLISTED);
    assert_eq!(
        result(&ingress.handle(&cancel, root.peer()), "job.cancel")["cancelRequested"],
        true
    );
    release.wait();
    let reply = running.join().unwrap();
    let error = decode_response(reply.trim_ascii_end(), "request-1", "job.run")
        .unwrap()
        .outcome
        .unwrap_err();
    assert_eq!(error.code, "recordUnreadable");
    assert_eq!(error.message, "execution outcome cannot be observed");
    assert!(error.details.is_none()); // Never add a zero-dispatch claim after execution.
    for request in [&run, &cancel] {
        assert_eq!(code(&ingress.handle(request, root.peer())), NOT_ALLOWLISTED);
    }
    assert_eq!(
        *calls.lock().unwrap(),
        ["submit", "run", "submit", "cancel"]
    );
}
#[test]
fn failed_submission_and_a_new_ingress_never_adopt_a_job() {
    let root = Root::new();
    let (failed, calls, _, _) = owner(&root, true);
    assert_eq!(
        code(&failed.handle(&submit(&capture()), root.peer())),
        "internalError"
    );
    let run = frame("job.run", json!({"jobId":"job-owned"}));
    assert_eq!(code(&failed.handle(&run, root.peer())), NOT_ALLOWLISTED);
    assert_eq!(*calls.lock().unwrap(), ["submit"]);
    let (accepted, _, _, _) = owner(&root, false);
    result(
        &accepted.handle(&submit(&capture()), root.peer()),
        "job.submit",
    );
    let reopened = AppIngress::new(accepted.control.clone(), root.peer().euid);
    assert_eq!(code(&reopened.handle(&run, root.peer())), NOT_ALLOWLISTED);
    // A plan result, malformed receipt or mismatched response id grants nothing.
    let gate = jobs::Gate::default();
    let reply=encode_frame(&Response::success("other",json!({"schemaVersion":"arkdeck.job-acceptance/1","jobId":"job-owned","deduplicated":false,"newDispatchCount":0})).value(),MAX_RESPONSE_BYTES).unwrap();
    assert!(!gate.record_reply(&reply, "request-1", jobs::Kind::Logs));
    assert!(!gate.record_reply(b"{}", "request-1", jobs::Kind::Logs));
    assert!(!gate.owns("job-owned"));
}
#[test]
fn typed_app_pairs_are_closed_and_bad_authority_never_reaches_control() {
    for (client, operations) in [
        ("ArkDeckApp.TraceWorkspace", vec!["capture.diagnostics"]),
        (
            "ArkDeckApp.DebugWorkspace.Logs",
            vec!["capture.diagnostics"],
        ),
        (
            "ArkDeckApp.DebugWorkspace.Artifacts",
            vec!["deploy.native-library.app-owned"],
        ),
        ("ArkDeckApp.DebugWorkspace.Apps", vec!["debug.hap"]),
        (
            "ArkDeckApp.DebugWorkspace.Network",
            vec!["port-forward.create", "port-forward.remove"],
        ),
        ("ArkDeckApp.DebugWorkspace.Commands", vec!["debug.template"]),
        (
            "ArkDeckApp.Toolkit.DeviceControl",
            vec![
                "capture.diagnostics",
                "capture.screen-sequence",
                "input.tap",
                "input.long-press",
                "input.swipe",
            ],
        ),
        ("ArkDeckApp.FlashWorkspace", vec!["flash.full-restore"]),
    ] {
        for operation in operations {
            let doc = document(client, operation);
            for method in ["job.plan", "job.submit"] {
                let request = Request::new(
                    "request-1",
                    method,
                    Some(serde_json::Map::from_iter([(
                        "requestJson".into(),
                        json!(doc.to_string()),
                    )])),
                );
                assert!(
                    matches!(jobs::Action::parse(&request), Ok(Some(_))),
                    "{client}/{operation}"
                );
            }
        }
    }
    let root = Root::new();
    let (ingress, calls, _, _) = owner(&root, false);
    let mut invalid = vec![
        document("CLI", "capture.diagnostics"),
        document("ArkDeckApp.TraceWorkspace", "input.tap"),
        document("ArkDeckApp.DebugWorkspace.Logs", "observe.device"),
    ];
    for (key, value) in [
        ("authorization", json!(null)),
        ("authorization", json!({"capabilityId":"CAP-forged"})),
        ("campaignReservation", json!(null)),
        ("trustedFacts", json!({})),
    ] {
        let mut doc = capture();
        doc[key] = value;
        invalid.push(doc);
    }
    let mut wrong_version = capture();
    wrong_version["operation"]["version"] = json!(2);
    invalid.push(wrong_version);
    for doc in invalid {
        assert_eq!(
            code(&ingress.handle(&submit(&doc), root.peer())),
            NOT_ALLOWLISTED
        );
    }
    let duplicate =
        capture()
            .to_string()
            .replacen("\"inputs\":{}", "\"inputs\":{},\"inputs\":{}", 1);
    for params in [
        json!({}),
        json!({"requestJson":duplicate}),
        json!({"requestJson":capture().to_string(),"authorization":{}}),
    ] {
        assert_eq!(
            code(&ingress.handle(&frame("job.submit", params), root.peer())),
            NOT_ALLOWLISTED
        );
    }
    for method in ["job.run", "job.cancel"] {
        for params in [
            json!({"jobId":""}),
            json!({"jobId":"job-foreign"}),
            json!({"jobId":"job-owned","authorization":{}}),
        ] {
            assert_eq!(
                code(&ingress.handle(&frame(method, params), root.peer())),
                NOT_ALLOWLISTED
            );
        }
    }
    for peer in [
        PeerOrigin {
            foreground_console: true,
            ..root.peer()
        },
        PeerOrigin {
            euid: root.peer().euid.wrapping_add(1),
            ..root.peer()
        },
    ] {
        assert_eq!(code(&ingress.handle(&submit(&capture()), peer)), "rejected");
    }
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
}

#[test]
fn continuation_refuses_mutation_stale_markers_and_missing_context_before_control() {
    let root = Root::new();
    let (ingress, calls, _, _) = owner(&root, false);
    let mut base = document("arkdeck-overview-continuation", "capture.diagnostics");
    base["inputs"] =
        json!({"durationSeconds":1,"captureHilog":false,"uiDump":false,"crashLogs":false});
    base["clientContext"]["provenance"] = json!({"arkdeck.continuedFromJob":"job-historical"});
    for change in [
        "screenshot",
        "tree",
        "trace",
        "markers",
        "missingSource",
        "missingBinding",
        "wrongOperation",
        "invalidInput",
        "wrongVersion",
    ] {
        let mut doc = base.clone();
        match change {
            "screenshot" => doc["inputs"]["uiScreenshot"] = json!(true),
            "tree" => doc["inputs"]["uiComponentTree"] = json!(true),
            "trace" => doc["inputs"]["traceCategories"] = json!(["sched"]),
            "markers" => doc["inputs"]["markers"] = json!(["old capture instant"]),
            "missingSource" => doc["clientContext"]["provenance"] = json!({}),
            "missingBinding" => {
                doc["target"]
                    .as_object_mut()
                    .unwrap()
                    .remove("expectedBindingRevision");
            }
            "wrongOperation" => doc["operation"]["id"] = json!("input.tap"),
            "invalidInput" => doc["inputs"]["durationSeconds"] = json!(-1),
            "wrongVersion" => doc["operation"]["version"] = json!(2),
            _ => unreachable!(),
        }
        for method in ["job.plan", "job.submit"] {
            assert_eq!(
                code(&ingress.handle(
                    &frame(method, json!({"requestJson":doc.to_string()})),
                    root.peer()
                )),
                NOT_ALLOWLISTED,
                "{change}/{method}"
            );
        }
    }
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
}
