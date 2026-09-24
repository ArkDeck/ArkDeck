//! The App ingress (`src/app_ingress.rs`) over a production Host whose HDC is
//! a fake script: captures, Overview continuations and Debug templates run as
//! typed Jobs, and the reads, Trace maintenance and Debug probe answered from
//! the production owners, as the App ingress's unit tests drove them until
//! they moved to this binary of spawning tests (see `main.rs`). Synthetic
//! kernel-origin peers: no signed XPC peer, device or installed Runtime.
use crate::app_ingress::AppIngress;
use arkdeck_contract::{decode_response, sha256_hex};
use arkdeck_control::Control;
use arkdeck_hoststore::{
    ArtifactReadStore, ArtifactUsage, JobStore, SessionStore, TargetStore, TraceCacheStore,
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
    sync::{Arc, atomic::Ordering},
};

#[allow(dead_code)]
#[path = "../../src/app_ingress/fixtures.rs"]
mod fixtures;
use fixtures::*;

/// The published contract view runs these tests against the merge base's
/// inputs, which name their commit; the checkout and candidate views do not.
fn published_view() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}
/// A plan as the control layer answers it under this build's `job.plan`
/// schema. The checkout and candidate views publish the additive step-set
/// review digest every Rust plan carries. The published view compiles the
/// merge base's closed result schema, which predates it, so the control layer
/// answers `internalError` in place of a result that schema cannot publish.
fn plan_answer(reply: &[u8]) -> Option<Value> {
    let schema: Value = serde_json::from_str(
        arkdeck_contract::METHOD_SCHEMAS
            .iter()
            .find(|(method, _)| *method == "job.plan")
            .unwrap()
            .1,
    )
    .unwrap();
    let publishes_digest = schema["$defs"]["result"]["properties"]
        .get("stepSetDigestSHA256")
        .is_some();
    assert!(
        publishes_digest || published_view(),
        "only the merge base's schema may predate the step-set review digest"
    );
    let outcome = decode_response(reply.trim_ascii_end(), "request-1", "job.plan")
        .unwrap()
        .outcome;
    if !publishes_digest {
        let error = outcome.expect_err("a plan field the schema does not publish");
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (
                "internalError",
                "the result does not conform to the current contract"
            )
        );
        return None;
    }
    let plan = outcome.unwrap_or_else(|error| panic!("job.plan: {error:?}"));
    let digest = plan["stepSetDigestSHA256"].as_str().unwrap_or_default();
    assert!(
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "{plan}"
    );
    Some(plan)
}

#[test]
fn uidump_runs_through_production_host_and_publishes_its_file_artifacts() {
    let _turn = crate::turn();
    production_uidump("success");
}
#[test]
fn uidump_missing_received_file_is_not_published_or_replayed() {
    let _turn = crate::turn();
    production_uidump("missing");
}
#[test]
fn uidump_interrupted_capture_is_unknown_and_never_replayed() {
    let _turn = crate::turn();
    production_uidump("interrupted");
}
#[test]
fn overview_continuation_runs_fresh_observation_through_the_runtime() {
    let _turn = crate::turn();
    production_uidump("continuation-observe");
    production_uidump("continuation-capture");
    production_uidump("continuation-interrupted");
}
#[test]
fn debug_template_jobs_execute_and_publish_through_the_app_ingress() {
    let _turn = crate::turn();
    production_uidump("template");
    production_uidump("template-interrupted");
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
'checkserver') printf 'Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n';;
'list targets -v') printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key";;
"-t $key shell param get const.product.name") printf 'Fixture Device\n';;
"-t $key shell param get const.ohos.fullname") printf 'Fixture OS\n';;
"-t $key shell uptime") printf 'up 1 day\n';;
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
    if mode == "template-interrupted" {
        script = script.replace(
            "shell uptime\") printf",
            "shell uptime\") kill -KILL $$; printf",
        );
    }
    if mode == "continuation-interrupted" {
        script = script.replace(
            "'checkserver') printf",
            "'checkserver') kill -KILL $$; printf",
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
    let template = mode.starts_with("template");
    if template {
        doc["clientContext"] =
            json!({"clientName":"ArkDeckApp.DebugWorkspace.Commands", "provenance":{}});
        doc["operation"]["id"] = json!("debug.template");
        doc["inputs"] = json!({"templateId":"device.uptime"});
    }
    let continuation = mode.starts_with("continuation-");
    if continuation {
        doc["clientContext"] = json!({"clientName":"arkdeck-overview-continuation", "provenance":{"arkdeck.continuedFromJob":"job-historical", "arkdeck.threadId":"thread-continuation"}});
        doc["operation"]["id"] = json!(if mode != "continuation-capture" {
            "observe.device"
        } else {
            "capture.diagnostics"
        });
        doc["inputs"] = if mode != "continuation-capture" {
            json!({})
        } else {
            json!({"durationSeconds":1,"captureHilog":false,"uiDump":false,"crashLogs":false})
        };
        let mut stale = doc.clone();
        stale["target"]["expectedBindingRevision"] = json!(2);
        let refused = ingress.handle(&submit(&stale), root.peer());
        assert!(
            decode_response(refused.trim_ascii_end(), "request-1", "job.submit")
                .unwrap()
                .outcome
                .is_err()
        );
        assert!(!root.0.join("calls").exists());
    }
    let planned = ingress.handle(
        &frame("job.plan", json!({"requestJson":doc.to_string()})),
        root.peer(),
    );
    if let Some(plan) = plan_answer(&planned) {
        assert_eq!(plan["dispatchDisposition"], "notDispatched");
    }
    assert!(!root.0.join("calls").exists());
    let accepted = result(&ingress.handle(&submit(&doc), root.peer()), "job.submit");
    let id = accepted["jobId"].as_str().unwrap();
    assert_eq!(accepted["newDispatchCount"], 0);
    let request = frame("job.run", json!({"jobId":id}));
    let status = result(&ingress.handle(&request, root.peer()), "job.run");
    if matches!(
        mode,
        "missing" | "interrupted" | "continuation-interrupted" | "template-interrupted"
    ) {
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
        if continuation || template {
            // Even a caller explicitly resubmitting the identical request
            // cannot use a renewed App claim to replay an unknown Runtime intent.
            let duplicate = ingress.handle(&submit(&doc), root.peer());
            if decode_response(duplicate.trim_ascii_end(), "request-1", "job.submit")
                .unwrap()
                .outcome
                .is_ok()
            {
                let reply = ingress.handle(&request, root.peer());
                if let Ok(status) = decode_response(reply.trim_ascii_end(), "request-1", "job.run")
                    .unwrap()
                    .outcome
                {
                    assert_eq!(status["outcomeUnknown"], true, "{status}");
                }
            }
            assert_eq!(fs::read(root.0.join("calls")).unwrap(), calls);
        }
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
    if template {
        assert_eq!(names.len(), 2, "{artifacts}");
        assert!(names.contains(&"template-output.txt") && names.contains(&"template-report.json"));
        assert_eq!(status["actualEffect"], "readOnly");
    } else if !continuation {
        assert!(names.contains(&"screenshot.png"), "{artifacts}");
        assert!(names.contains(&"ui-tree.json"), "{artifacts}");
    } else {
        assert!(!names.is_empty(), "{artifacts}");
        assert_eq!(status["actualEffect"], "readOnly");
        assert_eq!(status["threadId"], "thread-continuation");
    }
    let mut reads = 0;
    for item in artifacts["items"].as_array().unwrap() {
        if continuation && item["status"] != "published" {
            continue;
        }
        if !continuation
            && !template
            && !matches!(
                item["name"].as_str(),
                Some("screenshot.png" | "ui-tree.json")
            )
        {
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
        reads += 1;
        assert!(!read["base64"].as_str().unwrap().is_empty());
        if !continuation {
            assert_eq!(read["eof"], true, "{read}");
        }
        if item["name"] == "template-output.txt" {
            assert_eq!(read["base64"], "dXAgMSBkYXkK");
        }
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
    assert!(reads > 0, "{artifacts}");
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

#[test]
fn app_reads_and_trace_maintenance_answer_from_the_production_owners() {
    let _turn = crate::turn();
    let root = uploads();
    for name in ["state", "sessions", "trace-cache"] {
        directory(&root.0.join(name));
    }
    directory(&root.0.join("trace-cache/traces"));
    // An inert local HDC that logs what it runs and answers only the probe's
    // three fixed reads of the fixture Target's route.
    let script = r#"#!/bin/sh
printf '%s\n' "$*" >> 'ROOT/hdc-calls'
case "$*" in
'-t display-name-device shell bm dump -a') printf 'com.example.z\ncom.example.a\n';;
'-t display-name-device fport ls') printf 'tcp:9000 tcp:8000\n';;
'-t display-name-device rport ls') printf '[Fail] offline\n' >&2;;
*) exit 93;;
esac
"#
    .replace("ROOT", root.0.to_str().unwrap());
    fs::write(root.0.join("hdc"), &script).unwrap();
    fs::set_permissions(root.0.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
    let artifacts = root.0.join("artifacts");
    let control = Arc::new(
        Control::new(
            crate::host::Host::from_environment()
                .with_targets(TargetStore::open(&root.0.join("targets")).unwrap())
                .with_artifacts(ArtifactReadStore::open(&artifacts).unwrap())
                .with_jobs(JobStore::open_owner(&root.0.join("jobs")).unwrap())
                .with_trace_cache(
                    TraceCacheStore::open(&root.0.join("trace-cache/traces")).unwrap(),
                )
                .with_storage(
                    SessionStore::open(&root.0.join("state"), &root.0.join("sessions")).unwrap(),
                    ArtifactUsage::open(&artifacts, 1024 * 1024).unwrap(),
                )
                .with_development_hdc(Some(arkdeck_provider_hdc::ProcessDispatch::new(
                    arkdeck_platform::VerifiedTool::open(
                        root.0.join("hdc"),
                        &sha256_hex(script.as_bytes()),
                    )
                    .unwrap(),
                    None,
                ))),
        )
        .unwrap(),
    );
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    // Reads answer exactly as the local socket's Control answers them.
    for method in ["artifact.quota", "trace.cache.status"] {
        let request = frame(method, json!({}));
        let reply = ingress.handle(&request, root.peer());
        assert_eq!(reply, control.handle_frame(&request), "{method}");
        result(&reply, method);
    }
    let quota = result(
        &ingress.handle(&frame("artifact.quota", json!({})), root.peer()),
        "artifact.quota",
    );
    assert_eq!(quota["totalBytes"], 1024 * 1024);
    let purged = result(
        &ingress.handle(&frame("trace.cache.purge", json!({})), root.peer()),
        "trace.cache.purge",
    );
    assert_eq!(purged["removedEntryCount"], 0);
    // The owner's root replaced under it: its purge outcome is unknown, and
    // that answer crosses once, unchanged, without touching the replacement.
    fs::rename(
        root.0.join("trace-cache/traces"),
        root.0.join("trace-cache/moved"),
    )
    .unwrap();
    directory(&root.0.join("trace-cache/traces"));
    let error = refusal(
        &ingress.handle(&frame("trace.cache.purge", json!({})), root.peer()),
        "trace.cache.purge",
    );
    assert_eq!(error.code, "outcomeUnknown");
    assert_eq!(error.details.unwrap()["phase"], "traceCacheOwner");
    assert_eq!(
        fs::read_dir(root.0.join("trace-cache/traces"))
            .unwrap()
            .count(),
        0
    );
    let probe = result(
        &ingress.handle(
            &frame("debug.probe", json!({"targetId":TARGET})),
            root.peer(),
        ),
        "debug.probe",
    );
    assert_eq!(
        (&probe["targetId"], &probe["bindingRevision"]),
        (&json!(TARGET), &json!(1))
    );
    assert_eq!(probe["packages"], json!(["com.example.a", "com.example.z"]));
    assert_eq!(
        probe["portRules"],
        json!([{"direction":"forward","localPort":9000,"remotePort":8000}])
    );
    let mut calls: Vec<_> = fs::read_to_string(root.0.join("hdc-calls"))
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    calls.sort();
    assert_eq!(
        calls,
        [
            "-t display-name-device fport ls",
            "-t display-name-device rport ls",
            "-t display-name-device shell bm dump -a",
        ]
    );
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 6);
}
