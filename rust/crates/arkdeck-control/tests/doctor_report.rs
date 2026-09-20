//! `doctor` is Swift's `doctorReport(deep:)` computed from the host's owners:
//! every recorded Swift report whose inputs a host can state is reproduced
//! byte for byte from those inputs. A report's inputs are read back from its
//! own `checks` (the Catalog's available count, the registered providers,
//! the Artifact quota, the Target store, discovery, the cleanup debt); the
//! host answers exactly that. What start-up recovery and the deep ledger scan
//! found (`runtime.jobRecordUnreadable`, `runtime.durableRecordsUnreadable`)
//! is in no `checks` entry, so the host states what those findings state, and
//! the replay proves their wording, severity, scope and order and what they
//! make of the report's readiness.
use arkdeck_contract::*;
use arkdeck_control::{
    ArtifactStoreFacts, Control, DoctorFacts, HdcStatus, HostServices, TargetStoreFacts,
};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const CORPUS: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/doctor.jsonl"
);

/// A host that states one recorded report's inputs.
struct Recorded {
    report: Arc<Mutex<Value>>,
    /// Operations answered so far in this report's Catalog pass.
    answered: Arc<AtomicUsize>,
}

impl Recorded {
    fn checks(&self) -> Value {
        self.report.lock().unwrap()["checks"].clone()
    }

    /// Every recorded finding of `code`, read by `of` into the fact it states.
    fn findings<T>(&self, code: &str, of: impl Fn(&str) -> Option<T>) -> Vec<T> {
        self.report.lock().unwrap()["findings"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|finding| finding["code"] == code)
            .map(|finding| {
                of(finding["summary"].as_str().expect("a recorded summary"))
                    .expect("a recorded summary this Runtime writes")
            })
            .collect()
    }
}

impl HostServices for Recorded {
    fn observed_at(&self) -> String {
        self.report.lock().unwrap()["observedAt"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        let hdc = &self.checks()["hdc"];
        assert_eq!(hdc["configured"], false, "the corpus has no HDC observer");
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("doctor observes no device")
    }
    /// A registered provider's operations are answered; the first of them,
    /// as many as the report counted available, with no reason.
    fn operation_availability(
        &self,
        _reference: &str,
        provider: &str,
    ) -> Option<Vec<(&'static str, String)>> {
        let checks = self.checks();
        let registered = checks["providers"]["registered"].as_array().unwrap();
        if !registered.iter().any(|name| name == provider) {
            return None;
        }
        let available = checks["catalog"]["availableOperationCount"]
            .as_u64()
            .unwrap() as usize;
        Some(
            if self.answered.fetch_add(1, Ordering::SeqCst) < available {
                Vec::new()
            } else {
                vec![("provider_tool_unavailable", "recorded".into())]
            },
        )
    }
    fn doctor_facts(&self, deep: bool) -> DoctorFacts {
        let checks = self.checks();
        let artifacts = &checks["storage"]["runtimeArtifacts"];
        let target = &checks["target"];
        DoctorFacts {
            artifacts: match (artifacts["configured"].as_bool().unwrap(), deep) {
                (false, _) => ArtifactStoreFacts::NotConfigured,
                (true, false) => ArtifactStoreFacts::NotChecked,
                (true, true) => match (
                    artifacts["totalBytes"].as_u64(),
                    artifacts["usedBytes"].as_u64(),
                ) {
                    (Some(total), Some(used)) => ArtifactStoreFacts::Quota { total, used },
                    _ => ArtifactStoreFacts::Unreadable,
                },
            },
            targets: match (
                target["configured"].as_bool().unwrap(),
                target["adoptedTargetCount"].as_u64(),
            ) {
                (false, _) => TargetStoreFacts::NotConfigured,
                (true, Some(count)) => TargetStoreFacts::Adopted(count),
                (true, None) => TargetStoreFacts::Unreadable,
            },
            discovery: target["bootstrapConfigured"].as_bool().unwrap(),
            cleanup_debt: checks["recovery"]["outstandingCleanupCount"].as_u64(),
            // What start-up recovery and the deep ledger scan found is in no
            // `checks` entry of Swift's report: the findings themselves are
            // where it is stated. So this host states exactly what the
            // recorded findings state, and the replay proves the wording,
            // severity, scope and order this Runtime gives them, and what
            // they make of the report's readiness and blocker count.
            quarantined: self.findings("runtime.jobRecordUnreadable", |summary| {
                let rest = summary.split_once("cannot read: ")?.1;
                let (job, rest) = rest.split_once(" — ")?;
                Some((
                    job.to_owned(),
                    rest.split_once(". The Job is not live")?.0.to_owned(),
                ))
            }),
            unreadable_records: deep
                .then(|| {
                    let mut found = self.findings("runtime.durableRecordsUnreadable", |summary| {
                        let (total, rest) = summary.split_once(" durable Job records")?;
                        let sample = rest
                            .split_once("among them ")
                            .and_then(|(_, named)| named.split_once(". No byte"))
                            .map(|(named, _)| {
                                named.split(", ").map(str::to_owned).collect::<Vec<_>>()
                            })
                            .unwrap_or_default();
                        Some((total.parse::<u64>().ok()?, sample))
                    });
                    found.pop().unwrap_or((0, Vec::new()))
                })
                .filter(|(total, _)| *total > 0),
        }
    }
}

fn call<H: HostServices>(control: &Control<H>, params: Option<Value>) -> Response {
    let request = Request::new(
        "doctor",
        "doctor",
        params.and_then(|p| p.as_object().cloned()),
    );
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let response = control.handle_frame(&frame[..frame.len() - 1]);
    decode_response(&response[..response.len() - 1], "doctor", "doctor").unwrap()
}

#[test]
fn every_recorded_report_is_reproduced_from_the_inputs_it_states() {
    let (report, answered) = (
        Arc::new(Mutex::new(Value::Null)),
        Arc::new(AtomicUsize::new(0)),
    );
    let control = Control::new(Recorded {
        report: Arc::clone(&report),
        answered: Arc::clone(&answered),
    })
    .unwrap();
    let mut reproduced = 0;
    for (line, text) in CORPUS.lines().enumerate() {
        let recorded: Value = serde_json::from_str(text).unwrap();
        let Some(result) = recorded.get("result") else {
            continue;
        };
        let findings: Vec<&str> = result["findings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|finding| finding["code"].as_str().unwrap())
            .collect();
        *report.lock().unwrap() = result.clone();
        answered.store(0, Ordering::SeqCst);
        let answer = call(&control, recorded.get("params").cloned());
        assert_eq!(
            answer.outcome.unwrap(),
            *result,
            "doctor.jsonl line {}",
            line + 1
        );
        reproduced += 1;
    }
    // The corpus holds eight reports, the one naming undecodable durable Job
    // records among them.
    assert!(reproduced >= 8, "{reproduced}");
    assert_eq!(
        CORPUS
            .lines()
            .filter(|text| text.contains("runtime.durableRecordsUnreadable"))
            .count(),
        1
    );
}

struct Managed(
    &'static str,
    &'static str,
    &'static str,
    Vec<(String, String)>,
);
impl HostServices for Managed {
    fn observed_at(&self) -> String {
        "2026-09-19T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus {
            configured: true,
            checked: deep,
            availability: self.0.into(),
            ownership: self.1.into(),
            server_health: "unknown".into(),
            reason_code: self.2.into(),
        }
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!()
    }
    fn operation_availability(
        &self,
        reference: &str,
        provider: &str,
    ) -> Option<Vec<(&'static str, String)>> {
        (provider == "hdc").then(|| {
            if reference == "observe.device@1" {
                Vec::new()
            } else {
                vec![("operation_not_supported", "not here".into())]
            }
        })
    }
    fn doctor_facts(&self, _deep: bool) -> DoctorFacts {
        DoctorFacts {
            artifacts: ArtifactStoreFacts::Quota { total: 8, used: 3 },
            targets: TargetStoreFacts::Adopted(1),
            discovery: true,
            cleanup_debt: Some(0),
            quarantined: self.3.clone(),
            ..DoctorFacts::default()
        }
    }
}

/// A Runtime-managed, live HDC identity and a readable, empty Runtime make a
/// deep report healthy but for the Session output owner Swift does not
/// publish: ready, degraded. Any other identity is a blocker naming why.
#[test]
fn a_deep_report_is_ready_only_with_a_live_runtime_managed_identity() {
    let ready = Control::new(Managed(
        "available",
        "arkDeckManaged",
        "hdc.identityObserved",
        Vec::new(),
    ))
    .unwrap();
    let report = call(&ready, Some(json!({"deep": true}))).outcome.unwrap();
    assert_eq!(report["ready"], true, "{report}");
    assert_eq!(report["overall"], "degraded");
    assert_eq!(
        report["findingCounts"],
        json!({"blocker": 0, "warning": 2, "info": 7})
    );
    assert_eq!(
        report["checks"]["storage"]["runtimeArtifacts"],
        json!({"checked": true, "configured": true, "totalBytes": 8, "usedBytes": 3, "remainingBytes": 5})
    );
    assert_eq!(report["checks"]["providers"]["registered"], json!(["hdc"]));
    let codes: Vec<_> = report["findings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| finding["code"].clone())
        .collect();
    assert!(codes.contains(&json!("hdc.identityReady")), "{codes:?}");

    let unproven = Control::new(Managed(
        "unavailable",
        "unknown",
        "hdc.identityFamilyUnavailable",
        Vec::new(),
    ))
    .unwrap();
    let report = call(&unproven, Some(json!({"deep": true})))
        .outcome
        .unwrap();
    assert_eq!(report["ready"], false);
    let finding = report["findings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|finding| finding["code"] == "hdc.identityUnavailable")
        .unwrap()
        .clone();
    assert_eq!(
        finding["summary"],
        "the selected HDC server identity is unavailable or not Runtime-managed: \
         hdc.identityFamilyUnavailable"
    );
    assert_eq!(
        report["checks"]["hdc"],
        json!({"checked": true, "configured": true, "availability": "unavailable",
               "ownership": "unknown", "serverHealth": "unknown",
               "reasonCode": "hdc.identityFamilyUnavailable"})
    );
    // Standard mode does not observe the identity at all.
    let report = call(&unproven, None).outcome.unwrap();
    assert_eq!(report["ready"], true, "{report}");
    assert_eq!(
        report["checks"]["hdc"]["reasonCode"],
        "doctor.deepNotRequested"
    );
}

/// A Job start-up recovery set aside is a blocker naming it, before the
/// Catalog's findings, as Swift's report names `quarantinedJobRecords`; no
/// deep read is needed to say so, and a healthy store says nothing.
#[test]
fn a_quarantined_job_record_is_a_blocker_before_the_catalog_findings() {
    let control = Control::new(Managed(
        "available",
        "arkDeckManaged",
        "hdc.identityObserved",
        vec![(
            "job-9f".into(),
            "job record was written in a shape this build cannot read".into(),
        )],
    ))
    .unwrap();
    for deep in [false, true] {
        let report = call(&control, Some(json!({"deep": deep}))).outcome.unwrap();
        let findings = report["findings"].as_array().unwrap().clone();
        let codes: Vec<&str> = findings
            .iter()
            .map(|finding| finding["code"].as_str().unwrap())
            .collect();
        assert_eq!(
            codes
                .iter()
                .position(|code| *code == "runtime.jobRecordUnreadable"),
            Some(1),
            "{codes:?}"
        );
        assert!(
            codes.iter().position(|code| code.starts_with("catalog.")) > Some(1),
            "{codes:?}"
        );
        assert_eq!(
            findings[1],
            json!({"code": "runtime.jobRecordUnreadable", "severity": "blocker",
                   "scope": "runtime",
                   "summary": "a Job record in this store was written in a shape this build cannot read: job-9f — job record was written in a shape this build cannot read. The Job is not live, its record was not modified, and it still counts as active"})
        );
        assert_eq!(report["ready"], false, "{report}");
        assert_eq!(report["findingCounts"]["blocker"], 1);
    }
}
