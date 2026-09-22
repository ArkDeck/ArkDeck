//! Synthetic peer/source fixtures exercise the real App admission gate.
use super::*;
use arkdeck_contract::{Response, WireError};
use std::sync::{Barrier, Mutex};

fn document(client: &str, operation: &str) -> Value {
    json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0",
        "requestId":"app-request", "idempotencyKey":"app-request",
        "target":{"targetId":"TGT-fixture","expectedBindingRevision":1},
        "operation":{"id":operation,"version":1},"inputs":{},
        "requestedOutputs":["rawArtifacts","derivedArtifacts"],
        "clientContext":{"clientName":client,"provenance":{}}})
}
fn submit(document: &Value) -> Vec<u8> {
    frame("job.submit", json!({"requestJson":document.to_string()}))
}
fn capture() -> Value {
    document("ArkDeckApp.DebugWorkspace.Logs", "capture.diagnostics")
}
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
        assert_eq!(code(&ingress.handle(request, root.peer())), "rejected");
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
    assert_eq!(code(&ingress.handle(&run, root.peer())), "rejected");
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
        assert_eq!(code(&ingress.handle(request, root.peer())), "rejected");
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
    assert_eq!(code(&failed.handle(&run, root.peer())), "rejected");
    assert_eq!(*calls.lock().unwrap(), ["submit"]);
    let (accepted, _, _, _) = owner(&root, false);
    result(
        &accepted.handle(&submit(&capture()), root.peer()),
        "job.submit",
    );
    let reopened = AppIngress::new(accepted.control.clone(), root.peer().euid);
    assert_eq!(code(&reopened.handle(&run, root.peer())), "rejected");
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
            "rejected"
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
            "rejected"
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
                "rejected"
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
fn uidump_runs_through_production_host_and_publishes_its_file_artifacts() {
    production_uidump("success");
}
#[test]
fn uidump_missing_received_file_is_not_published_or_replayed() {
    production_uidump("missing");
}
#[test]
fn uidump_interrupted_capture_is_unknown_and_never_replayed() {
    production_uidump("interrupted");
}
fn production_uidump(mode: &str) {
    use arkdeck_contract::sha256_hex;
    use arkdeck_hoststore::{
        ArtifactReadStore, ArtifactUsage, CapabilityStore, JobStore, SessionStore, TargetStore,
    };
    use arkdeck_platform::VerifiedTool;
    use arkdeck_provider_hdc::ProcessDispatch;
    use std::os::unix::fs::PermissionsExt;
    let root = Root::new();
    for name in [
        "targets",
        "jobs",
        "artifacts",
        "session-owner",
        "Sessions",
        "device",
    ] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.0.join(name))
            .unwrap();
    }
    let target_file = root.0.join("targets/targets.json");
    fs::copy(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/capture-diagnostics/targets-state/targets.json"),
        &target_file,
    )
    .unwrap();
    fs::set_permissions(&target_file, fs::Permissions::from_mode(0o600)).unwrap();
    // A tiny PNG fixture; no hardware evidence is constructed or promoted.
    fs::write(
        root.0.join("image.png"),
        [
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
            8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207,
            192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
            130,
        ],
    )
    .unwrap();
    let mut script=r#"#!/bin/sh
root='FIXTURE_ROOT'
printf '%s\n' "$*" >> "$root/calls"
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
'-v') printf 'Ver: 3.2.0d\n';;
'list targets -v') printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key";;
"-t $key shell param get const.product.name") printf 'Fixture Device\n';;
"-t $key shell param get const.ohos.fullname") printf 'Fixture OS\n';;
"-t $key shell df -k /data/local/tmp") printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/block/data 1048576 1024 1047552 1%% /data\n';;
"-t $key shell hidumper -s WindowManagerService -a -a") printf '{"windows":[]}\n';;
"-t $key shell snapshot_display -t png -f /data/local/tmp/arkdeck-"*) cp "$root/image.png" "$root/device/${8##*/}"; printf 'success\n';;
"-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*) printf '{"attributes":{"id":"root","password":"fixture-secret"},"children":[]}\n' > "$root/device/${7##*/}"; printf 'success\n';;
"-t $key shell ls -l /data/local/tmp/arkdeck-"*) printf '%s 1 shell shell %s 2026-09-22 00:00 %s\n' -rw-rw-rw- "$(wc -c < "$root/device/${6##*/}")" "$6";;
"-t $key file recv /data/local/tmp/arkdeck-"*) cp "$root/device/${5##*/}" "$6"; printf 'FileTransfer finish\n';;
"-t $key shell rm -f /data/local/tmp/arkdeck-"*) rm -f "$root/device/${6##*/}";;
*) printf 'unexpected fixture command\n' >&2; exit 93;;
esac
"#.replace("FIXTURE_ROOT",root.0.to_str().unwrap());
    if mode == "missing" {
        script = script.replace("cp \"$root/device/${5##*/}\" \"$6\"", ":");
    } else if mode == "interrupted" {
        script = script.replace(
            "cp \"$root/image.png\"",
            "kill -KILL $$; cp \"$root/image.png\"",
        );
    }
    let tool = root.0.join("hdc");
    fs::write(&tool, &script).unwrap();
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o700)).unwrap();
    let host = crate::host::Host::from_environment()
        .with_targets(TargetStore::open(&root.0.join("targets")).unwrap())
        .with_jobs(JobStore::open_owner(&root.0.join("jobs")).unwrap())
        .with_capabilities(CapabilityStore::open(&root.0.join("jobs/capabilities")).unwrap())
        .with_development_mutation_root(root.0.join("jobs"))
        .with_artifacts(ArtifactReadStore::open(&root.0.join("artifacts")).unwrap())
        .with_storage(
            SessionStore::open(&root.0.join("session-owner"), &root.0.join("Sessions")).unwrap(),
            ArtifactUsage::open(&root.0.join("artifacts"), 128 * 1024 * 1024).unwrap(),
        )
        .with_planning(&root.0, None)
        .with_development_hdc(Some(ProcessDispatch::new(
            VerifiedTool::open(tool, &sha256_hex(script.as_bytes())).unwrap(),
            None,
        )));
    let control = Arc::new(Control::new(host).unwrap());
    let ingress = AppIngress::new(control.clone(), root.peer().euid);
    let mut doc = capture();
    // Each independent Runtime fixture owns distinct Job/landing identities.
    doc["requestId"] = json!(format!(
        "uidump-{mode}-{}",
        root.0.file_name().unwrap().to_str().unwrap()
    ));
    doc["idempotencyKey"] = doc["requestId"].clone();
    doc["target"]["targetId"] = json!("TGT-3ba3f5f43b92");
    doc["inputs"] = json!({"durationSeconds":1,"captureHilog":false,"hilogFilters":[],"uiDump":true,"crashLogs":false,"uiScreenshot":true,"uiComponentTree":true,"redactionProfile":"standard"});
    let plan = result(
        &ingress.handle(
            &frame("job.plan", json!({"requestJson":doc.to_string()})),
            root.peer(),
        ),
        "job.plan",
    );
    assert_eq!(plan["dispatchDisposition"], "notDispatched");
    assert!(!root.0.join("calls").exists());
    let accepted = result(&ingress.handle(&submit(&doc), root.peer()), "job.submit");
    let id = accepted["jobId"].as_str().unwrap();
    assert_eq!(accepted["newDispatchCount"], 0);
    let request = frame("job.run", json!({"jobId":id}));
    let status = result(&ingress.handle(&request, root.peer()), "job.run");
    if mode != "success" {
        assert_ne!(status["state"], "succeeded", "{status}");
        assert_eq!(status["outcomeUnknown"], true, "{status}");
        let artifacts = result(
            &ingress.handle(
                &frame("artifact.list", json!({"owner":{"kind":"job","id":id}})),
                root.peer(),
            ),
            "artifact.list",
        );
        assert!(
            artifacts["items"]
                .as_array()
                .unwrap()
                .iter()
                .all(|item| item["name"] != "screenshot.png"),
            "{artifacts}"
        );
        if mode == "missing" {
            assert!(
                artifacts["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|item| item["name"] != "ui-tree.json"),
                "{artifacts}"
            );
        }
        let calls = fs::read(root.0.join("calls")).unwrap();
        assert_eq!(code(&ingress.handle(&request, root.peer())), "rejected");
        assert_eq!(fs::read(root.0.join("calls")).unwrap(), calls);
        drop(ingress);
        drop(control);
        let reopened = JobStore::open(&root.0.join("jobs")).unwrap();
        let durable = reopened
            .handle_resource("job.show", json!({"jobId":id}).as_object().unwrap())
            .unwrap();
        assert_eq!(durable["job"]["outcomeUnknown"], true);
        return;
    }
    assert_eq!(status["state"], "succeeded", "{status}");
    assert_eq!(status["outcomeUnknown"], false);
    let artifacts = result(
        &ingress.handle(
            &frame("artifact.list", json!({"owner":{"kind":"job","id":id}})),
            root.peer(),
        ),
        "artifact.list",
    );
    let names: Vec<_> = artifacts["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"screenshot.png"), "{artifacts}");
    assert!(names.contains(&"ui-tree.json"), "{artifacts}");
    for item in artifacts["items"].as_array().unwrap() {
        if !matches!(
            item["name"].as_str(),
            Some("screenshot.png" | "ui-tree.json")
        ) {
            continue;
        }
        let read = result(
            &ingress.handle(
                &frame(
                    "artifact.read",
                    json!({
                        "owner":{"kind":"job","id":id}, "artifactId":item["artifactId"],
                        "offset":0,"maxBytes":4096,"allowSensitive":true
                    }),
                ),
                root.peer(),
            ),
            "artifact.read",
        );
        assert_eq!(read["eof"], true, "{read}");
        if item["name"] == "screenshot.png" {
            assert_eq!(
                read["base64"],
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
            );
        }
        if item["name"] == "ui-tree.json" {
            assert_eq!(
                read["base64"],
                "eyJhdHRyaWJ1dGVzIjp7ImlkIjoicm9vdCIsInBhc3N3b3JkIjoiPFJFREFDVEVEPiJ9LCJjaGlsZHJlbiI6W119Cg==",
                "{read}"
            );
        }
    }
    let shown = result(
        &ingress.handle(&frame("job.show", json!({"jobId":id})), root.peer()),
        "job.show",
    );
    assert_eq!(shown["job"]["state"], "succeeded", "{shown}");
    let calls = fs::read(root.0.join("calls")).unwrap();
    assert_eq!(code(&ingress.handle(&request, root.peer())), "rejected");
    assert_eq!(fs::read(root.0.join("calls")).unwrap(), calls);
    // A valid Job submitted over UDS is still foreign to the App gate.
    doc["requestId"] = json!(format!("foreign-{id}"));
    doc["idempotencyKey"] = doc["requestId"].clone();
    let foreign = result(&control.handle_frame(&submit(&doc)), "job.submit");
    for method in ["job.run", "job.cancel"] {
        assert_eq!(
            code(&ingress.handle(
                &frame(method, json!({"jobId":foreign["jobId"]})),
                root.peer()
            )),
            "rejected"
        );
    }
    assert_eq!(fs::read(root.0.join("calls")).unwrap(), calls);
}
