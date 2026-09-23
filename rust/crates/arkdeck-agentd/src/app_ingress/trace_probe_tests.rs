//! The App asks `trace.probe` of one adopted Target, as ClientKit's Overview
//! capability and Trace facades do (`{"targetId": ...}`). A recording host
//! stands in for the probe: the boundary is under test here, the probe's
//! reads are replayed by `trace_probe_control`. No signed peer, device or
//! installed Runtime is represented.
use super::*;
use arkdeck_contract::{DeviceObservationsResult, WireError};
use std::sync::Mutex;

type Targets = Arc<Mutex<Vec<String>>>;
struct Probe {
    targets: Targets,
}
impl HostServices for Probe {
    fn observed_at(&self) -> String {
        "2026-09-24T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("trace.probe observes no candidates")
    }
    fn trace_probe(&self, target_id: &str) -> Result<Value, WireError> {
        self.targets.lock().unwrap().push(target_id.to_owned());
        let corpus = include_str!(
            "../../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/trace.probe.jsonl"
        );
        Ok(corpus
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|record| record["ok"] == true)
            .unwrap()["result"]
            .clone())
    }
}
fn probe(root: &Root) -> (AppIngress<Probe>, Arc<Control<Probe>>, Targets) {
    let targets = Targets::default();
    let control = Arc::new(
        Control::new(Probe {
            targets: Arc::clone(&targets),
        })
        .unwrap(),
    );
    (
        AppIngress::new(Arc::clone(&control), root.peer().euid),
        control,
        targets,
    )
}

#[test]
fn the_app_probes_its_target_once_through_the_shared_control() {
    let root = Root::new();
    let (ingress, control, targets) = probe(&root);
    let request = frame("trace.probe", json!({"targetId": "TGT-3ba3f5f43b92"}));
    let reply = ingress.handle(&request, root.peer());
    result(&reply, "trace.probe");
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 1);
    assert_eq!(targets.lock().unwrap().as_slice(), ["TGT-3ba3f5f43b92"]);
    // The local socket reaches the same Control and answers the same bytes.
    assert_eq!(control.handle_frame(&request), reply);
    assert_eq!(targets.lock().unwrap().len(), 2);
    // Without a probe, the App hears what Swift's daemon without one says.
    let unconfigured = root.ingress().handle(
        &frame("trace.probe", json!({"targetId": "TGT-1"})),
        root.peer(),
    );
    let refusal = decode_response(unconfigured.trim_ascii_end(), "request-1", "trace.probe")
        .unwrap()
        .outcome
        .unwrap_err();
    assert_eq!(
        (refusal.code.as_str(), refusal.message.as_str()),
        ("internalError", "Trace Runtime probing is not configured")
    );
}

#[test]
fn the_app_names_only_its_target_and_never_a_command_or_route() {
    let root = Root::new();
    let (ingress, _control, targets) = probe(&root);
    for params in [
        json!({}),
        json!({"targetId": 5}),
        json!({"targetId": null}),
        json!({"target": "TGT-1"}),
        json!({"targetId": "TGT-1", "rawCommand": "shell id"}),
        json!({"targetId": "TGT-1", "connectKey": "forged"}),
        json!({"targetId": "TGT-1", "peerEUID": root.peer().euid}),
    ] {
        let reply = ingress.handle(&frame("trace.probe", params.clone()), root.peer());
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    let valid = frame("trace.probe", json!({"targetId": "TGT-1"}));
    for peer in [
        PeerOrigin {
            euid: root.peer().euid.wrapping_add(1),
            ..root.peer()
        },
        PeerOrigin {
            pid: 1,
            ..root.peer()
        },
        PeerOrigin {
            foreground_console: true,
            ..root.peer()
        },
    ] {
        assert_eq!(code(&ingress.handle(&valid, peer)), "rejected");
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert!(targets.lock().unwrap().is_empty());
}
