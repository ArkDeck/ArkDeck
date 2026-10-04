//! Recovery is an explicit continuation of a durable App request. These
//! synthetic records and peers grant no device authority or hardware evidence.
use super::*;
use arkdeck_hoststore::{JobRecord, JobStore};

fn parked(root: &Root, state: &str, unknown: bool, client: &str) -> crate::host::Host {
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let request = document(client, "capture.diagnostics");
    let value = json!({"jobID":"job-recover","request":request,
        "operationReference":"capture.diagnostics@1","catalogDigest":arkdeck_contract::CATALOG_DIGEST,
        "providerID":"hdc","createdAtUTC":"2026-10-04T00:00:00Z","actualEffect":"readOnly",
        "materializedPlanDigest":"a".repeat(64),"materializedBindingRevision":1,
        "state":state,"outcomeUnknown":unknown,"timeline":[],"actualStepKinds":[],"skipReasons":{}});
    let record = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.admit(&record, &arkdeck_contract::sha256_hex(b"fixture-recovery"))
        .unwrap();
    crate::host::Host::from_environment().with_jobs(jobs)
}

#[test]
fn recovery_gate_reopens_only_durable_app_jobs_in_the_exact_safe_state() {
    for (state, unknown, client, reconcile, resume) in [
        (
            "waitingForRecovery",
            true,
            "ArkDeckApp.TraceWorkspace",
            true,
            false,
        ),
        (
            "waitingForRecovery",
            false,
            "ArkDeckApp.TraceWorkspace",
            true,
            false,
        ),
        (
            "resumeAtConfirmedSafeBoundary",
            false,
            "ArkDeckApp.TraceWorkspace",
            false,
            true,
        ),
        (
            "resumeAtConfirmedSafeBoundary",
            true,
            "ArkDeckApp.TraceWorkspace",
            false,
            false,
        ),
        ("running", false, "ArkDeckApp.TraceWorkspace", false, false),
        ("queued", false, "ArkDeckApp.TraceWorkspace", false, false),
        (
            "succeeded",
            false,
            "ArkDeckApp.TraceWorkspace",
            false,
            false,
        ),
        ("waitingForRecovery", true, "untrusted-caller", false, false),
        (
            "resumeAtConfirmedSafeBoundary",
            false,
            "untrusted-caller",
            false,
            false,
        ),
    ] {
        let root = Root::new();
        let host = parked(&root, state, unknown, client);
        assert_eq!(
            host.app_job_recovery_allowed("job-recover", false),
            reconcile,
            "{state}/{client}"
        );
        assert_eq!(
            host.app_job_recovery_allowed("job-recover", true),
            resume,
            "{state}/{client}"
        );
        assert!(!host.app_job_recovery_allowed("foreign", true));
        assert!(!host.app_job_recovery_allowed("foreign", false));
        let ingress = AppIngress::new(Arc::new(Control::new(host).unwrap()), root.peer().euid);
        for (method, allowed) in [("job.run", resume), ("job.reconcile", reconcile)] {
            let reply = ingress.handle(&frame(method, json!({"jobId":"job-recover"})), root.peer());
            assert_eq!(
                code(&reply) == "methodNotAllowlisted",
                !allowed,
                "{method}/{state}"
            );
        }
        assert_eq!(
            ingress.dispatches.load(Ordering::Relaxed),
            usize::from(reconcile) + usize::from(resume)
        );
    }
}

#[test]
fn recovery_gate_refuses_extra_identity_and_authority_fields_before_control() {
    let root = Root::new();
    let ingress = AppIngress::new(
        Arc::new(
            Control::new(parked(
                &root,
                "waitingForRecovery",
                true,
                "ArkDeckApp.TraceWorkspace",
            ))
            .unwrap(),
        ),
        root.peer().euid,
    );
    for params in [
        json!({}),
        json!({"jobId":5}),
        json!({"jobId":"job-recover", "targetId":"replacement"}),
        json!({"jobId":"job-recover", "authorization":{}}),
    ] {
        assert_eq!(
            code(&ingress.handle(&frame("job.reconcile", params), root.peer())),
            "invalidParams"
        );
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
}

#[test]
fn recovery_continuation_is_exclusive_and_does_not_create_a_new_runnable_claim() {
    use arkdeck_contract::WireError;
    use std::sync::{Barrier, atomic::AtomicBool};
    struct Owner {
        eligible: AtomicBool,
        entered: Arc<Barrier>,
        release: Arc<Barrier>,
    }
    impl HostServices for Owner {
        fn observations(&self) -> Result<arkdeck_contract::DeviceObservationsResult, WireError> {
            unreachable!("recovery never enumerates another device")
        }
        fn observed_at(&self) -> String {
            "2026-10-04T00:00:00Z".into()
        }
        fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
            arkdeck_control::HdcStatus::unavailable(deep, "fixture")
        }
        fn app_job_recovery_allowed(&self, job: &str, resume: bool) -> bool {
            job == "job-recover" && resume && self.eligible.load(Ordering::SeqCst)
        }
        fn job_run(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
            self.entered.wait();
            self.release.wait();
            self.eligible.store(false, Ordering::SeqCst);
            Err(WireError {
                code: "recordUnreadable".into(),
                message: "fixture lost result".into(),
                details: None,
            })
        }
    }
    let root = Root::new();
    let entered = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let ingress = Arc::new(AppIngress::new(
        Arc::new(
            Control::new(Owner {
                eligible: AtomicBool::new(true),
                entered: entered.clone(),
                release: release.clone(),
            })
            .unwrap(),
        ),
        root.peer().euid,
    ));
    let request = frame("job.run", json!({"jobId":"job-recover"}));
    let running = {
        let ingress = ingress.clone();
        let request = request.clone();
        let peer = root.peer();
        std::thread::spawn(move || ingress.handle(&request, peer))
    };
    entered.wait();
    assert_eq!(
        code(&ingress.handle(&request, root.peer())),
        "methodNotAllowlisted"
    );
    release.wait();
    assert_eq!(code(&running.join().unwrap()), "recordUnreadable");
    for method in ["job.run", "job.cancel"] {
        assert_eq!(
            code(&ingress.handle(&frame(method, json!({"jobId":"job-recover"})), root.peer())),
            "methodNotAllowlisted"
        );
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 1);
}
