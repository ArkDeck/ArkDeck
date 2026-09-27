//! Opt-in real-daemon CAS-miss subset. The Python carrier owns the unpaired
//! daemon, absolute deadline and private directory; no installed Runtime is used.
#![cfg(target_os = "macos")]
use arkdeck_provider_arkforge::{
    AssessmentSource, LaneArtifact, LanePlanPreview, LanePreview, LanePreviewHost, PlanConnections,
    PlanSource, authority_support::Configuration,
};
use arkforge_client::{ControllerClient, DeviceObservationView, MaterializeInput};
use arkforge_ipc::messages::MaterializePlanResponse;
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

const ARCHIVE: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const PROFILE: &str = "org.openharmony.dayu200@1.0.0";

struct InspectOnly {
    client: ControllerClient,
    inspections: Arc<AtomicUsize>,
}
impl PlanSource for InspectOnly {
    fn inspect(&mut self, digest: &str) -> Result<(), String> {
        assert_eq!(digest, ARCHIVE);
        assert_eq!(self.inspections.fetch_add(1, Ordering::SeqCst), 0);
        let error = self
            .client
            .artifact_show(digest)
            .expect_err("fresh CAS must be empty");
        // A disconnect or decoder error must not masquerade as a proven store miss.
        assert_eq!(error.code, "ARTIFACT_NOT_FOUND");
        Err(error.code)
    }
    fn import(&mut self, _: &LaneArtifact) -> Result<(), String> {
        panic!("CAS-miss preview must not import")
    }
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String> {
        panic!("CAS-miss preview must not discover devices")
    }
    fn materialize(&mut self, _: &MaterializeInput<'_>) -> Result<MaterializePlanResponse, String> {
        panic!("CAS-miss preview must not materialize")
    }
}
struct Connections {
    runtime: PathBuf,
    inspections: Arc<AtomicUsize>,
}
impl PlanConnections for Connections {
    fn controller(&self) -> Result<Box<dyn PlanSource>, String> {
        let client =
            ControllerClient::connect_with_read_timeout(&self.runtime, Duration::from_secs(5))
                .expect("connect to the harness-owned daemon");
        Ok(Box::new(InspectOnly {
            client,
            inspections: self.inspections.clone(),
        }))
    }
    fn public(&self) -> Result<Box<dyn AssessmentSource>, String> {
        panic!("CAS-miss preview must stop before public assessment")
    }
}

#[test]
#[ignore = "run only through scripts/ci/run-spk9-preview-missing.py"]
fn real_daemon_missing_archive_preview() {
    let runtime = PathBuf::from(std::env::var("ARKDECK_SPK9_RUNTIME").expect("isolated carrier"));
    let report = PathBuf::from(std::env::var("ARKDECK_SPK9_RUST_REPORT").expect("result path"));
    let inspections = Arc::new(AtomicUsize::new(0));
    let preview = LanePreviewHost::new(
        Box::new(Connections {
            runtime,
            inspections: inspections.clone(),
        }),
        Configuration::new(&"00".repeat(32), &"00".repeat(32), ""),
        PROFILE.into(),
    );
    assert_eq!(preview.profile_reference(), PROFILE);
    assert_eq!(
        preview.preview(ARCHIVE, "SPK9-fixture-no-device"),
        LanePreview::BundleNotInLaneStore
    );
    assert_eq!(inspections.load(Ordering::SeqCst), 1);
    std::fs::write(
        report,
        serde_json::to_vec_pretty(&serde_json::json!({
            "owner": "rust", "outcome": "bundleNotInLaneStore", "archiveSHA256": ARCHIVE,
            "profileReference": PROFILE, "calls": ["controller.inspectArtifact"],
            "refusalCode": "ARTIFACT_NOT_FOUND"
        }))
        .unwrap(),
    )
    .unwrap();
}
