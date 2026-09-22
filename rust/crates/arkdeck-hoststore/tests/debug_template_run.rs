//! The real planner/admitter/runner/Artifact path over an isolated synthetic Target.
#![cfg(target_os = "macos")]
mod support;
use arkdeck_hoststore::{JobAdmitter, JobResultReader};
use arkdeck_provider_hdc::{DebugReadTemplate, DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::{sync::Mutex, time::Duration};
use support::{debug_hap, fixed_now, hdc_oracle::Owners};

struct TemplateDispatch<'a> {
    base: &'a (dyn HdcDispatch + Sync),
    template: DebugReadTemplate,
    mode: &'a str,
    calls: Mutex<usize>,
}
impl HdcDispatch for TemplateDispatch<'_> {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        if plan.arguments.len() >= 2 && plan.arguments[2..] == self.template.plan("").arguments[2..]
        {
            *self.calls.lock().unwrap() += 1;
            assert_eq!(plan.capture_bytes, self.template.plan("").capture_bytes);
            assert_eq!(plan.timeout, Duration::from_secs(30));
            if self.mode == "interrupted" {
                return Err(DispatchFailure::Unobservable(
                    "synthetic template process lost".into(),
                ));
            }
            return Ok(Receipt {
                exit_status: if self.mode == "exit" { 7 } else { 0 },
                stdout: if self.mode == "offline" {
                    b"[Fail] target offline".to_vec()
                } else {
                    vec![0xff, b'\n', b'x']
                },
                stderr: vec![],
                truncated: self.mode == "truncated",
                duration: Duration::from_micros(1500),
            });
        }
        self.base.dispatch(plan)
    }
}

#[test]
fn closed_templates_run_as_jobs_and_unknown_results_never_replay() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let owners = Owners::open(&fixture);
    let cases = support::document(&fixture, "cases.json");
    let source = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["method"] == "job.plan" && v["answer"]["ok"] == true)
        .unwrap();
    let original: Value =
        serde_json::from_str(source["params"]["requestJson"].as_str().unwrap()).unwrap();
    for (index, (id, mode)) in [
        ("device.packageInventory", "success"),
        ("device.debugParameterRead", "success"),
        ("device.windowInventory", "success"),
        ("device.uptime", "success"),
        ("device.uptime", "offline"),
        ("device.uptime", "exit"),
        ("device.uptime", "truncated"),
        ("device.uptime", "interrupted"),
    ]
    .into_iter()
    .enumerate()
    {
        let dispatch = TemplateDispatch {
            base: &owners.dispatch,
            template: DebugReadTemplate::parse(id).unwrap(),
            mode,
            calls: Mutex::new(0),
        };
        let hdc = owners.hdc(&dispatch);
        let mut request = original.clone();
        request["requestId"] = json!(format!("req-template-{index}"));
        request["idempotencyKey"] = json!(format!("idem-template-{index}"));
        request["operation"] = json!({"id":"debug.template","version":1});
        request["inputs"] = json!({"templateId":id});
        let params = json!({"requestJson":request.to_string()});
        if index == 0 {
            let before = owners.calls();
            for (key, value) in [
                ("templateId", json!("shell uptime")),
                ("rawCommand", json!("shell uptime")),
            ] {
                let mut invalid = request.clone();
                invalid["inputs"][key] = value;
                assert!(
                    owners
                        .planner(&hdc)
                        .handle(
                            json!({"requestJson":invalid.to_string()})
                                .as_object()
                                .unwrap()
                        )
                        .is_err()
                );
            }
            let mut stale = request.clone();
            stale["target"]["expectedBindingRevision"] = json!(9999);
            assert!(
                owners
                    .planner(&hdc)
                    .handle(
                        json!({"requestJson":stale.to_string()})
                            .as_object()
                            .unwrap()
                    )
                    .is_err()
            );
            assert_eq!(owners.calls(), before);
            assert_eq!(*dispatch.calls.lock().unwrap(), 0);
        }
        let plan = owners
            .planner(&hdc)
            .handle(params.as_object().unwrap())
            .unwrap();
        assert_eq!(plan["effectiveEffect"], "readOnly");
        assert_eq!(plan["steps"].as_array().unwrap().len(), 3);
        assert_eq!(*dispatch.calls.lock().unwrap(), 0);
        let admitter = JobAdmitter {
            planner: owners.planner(&hdc),
            jobs: &owners.jobs,
            now: fixed_now,
            authority: None,
        };
        let admitted = admitter.handle(params.as_object().unwrap()).unwrap();
        let job = admitted["jobId"].as_str().unwrap();
        let publisher = owners.publisher();
        let runner = owners.runner(&hdc, &publisher, false);
        let result = runner
            .handle(&serde_json::from_value(json!({"jobId":job})).unwrap())
            .unwrap();
        assert_eq!(*dispatch.calls.lock().unwrap(), 1, "{mode}");
        let record = owners.record(job);
        assert_eq!(record["outcomeUnknown"], mode == "interrupted", "{result}");
        let state = record["state"].as_str().unwrap();
        assert_eq!(
            state,
            if mode == "success" {
                "succeeded"
            } else if mode == "interrupted" {
                "waitingForRecovery"
            } else {
                "failed"
            },
            "{record}"
        );
        let reader = JobResultReader {
            jobs: &owners.jobs,
            artifacts: &owners.artifacts,
        };
        let evidence = reader
            .handle(
                "job.evidence",
                &serde_json::from_value(json!({"jobId":job})).unwrap(),
            )
            .unwrap();
        assert!(
            evidence["observation"].is_null(),
            "templates do not manufacture evidence facts: {evidence}"
        );
        if mode == "success" {
            let index: Value = serde_json::from_slice(
                &std::fs::read(owners.root.join("artifacts").join(job).join("index.json")).unwrap(),
            )
            .unwrap();
            let rows = index["artifacts"].as_array().unwrap();
            for name in ["template-output.txt", "template-report.json"] {
                let artifact = rows.iter().find(|row| row["name"] == name).unwrap();
                let id = artifact["artifactID"].as_str().unwrap();
                let bytes = owners
                    .artifacts
                    .read(job, id, 0, 65536, true)
                    .unwrap()
                    .bytes;
                if name == "template-output.txt" {
                    assert_eq!(bytes, vec![0xff, b'\n', b'x']);
                    assert!(owners.artifacts.read(job, id, 0, 65536, false).is_err());
                } else {
                    let report: Value = serde_json::from_slice(&bytes).unwrap();
                    assert_eq!(report["templateId"], dispatch.template.raw());
                    assert_eq!(report["durationMilliseconds"], "2");
                    assert_eq!(report["stdoutByteCount"], "3");
                }
            }
        }
        if mode == "interrupted" {
            arkdeck_hoststore::recover_active_jobs(&owners.jobs, None, fixed_now).unwrap();
            assert_eq!(
                *dispatch.calls.lock().unwrap(),
                1,
                "recovery cannot dispatch"
            );
            let reconcile = arkdeck_hoststore::JobReconciler {
                jobs: &owners.jobs,
                artifacts: &owners.artifacts,
                imports: None,
                now: fixed_now,
                sessions: Some(&publisher),
                hdc: Some(&hdc),
                capabilities: None,
            };
            let _ = reconcile.handle(&serde_json::from_value(json!({"jobId":job})).unwrap());
            assert_eq!(
                *dispatch.calls.lock().unwrap(),
                1,
                "reconciliation cannot replay an unknown template"
            );
            let _ = runner.handle(&serde_json::from_value(json!({"jobId":job})).unwrap());
            assert_eq!(
                *dispatch.calls.lock().unwrap(),
                1,
                "unknown intent must not replay"
            );
            assert!(owners.record(job)["outcomeUnknown"].as_bool().unwrap());
        }
    }
}
