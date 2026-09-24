//! The App asks `flash.device-access` with no parameters at all, as
//! ClientKit's `RockchipDeviceAccessApplicationFacade` does, and the answer
//! is the shared Control's. A recording host stands in for the observer: the
//! boundary is under test here, the observer's socket session is tested in
//! `arkdeck-provider-arkforge`. No signed peer, board or ArkForge daemon is
//! represented.
use super::*;
use arkdeck_contract::{DeviceObservationsResult, WireError};
use std::sync::atomic::AtomicUsize;

struct Access {
    reads: Arc<AtomicUsize>,
}
impl HostServices for Access {
    fn observed_at(&self) -> String {
        "2026-09-25T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("device access observes no candidates")
    }
    fn flash_device_access(&self) -> Result<Value, WireError> {
        self.reads.fetch_add(1, Ordering::Relaxed);
        Ok(json!({"observationCount": 2, "observedModes": ["Loader", "Maskrom"]}))
    }
}

#[test]
fn the_app_reads_device_access_with_no_parameters_through_the_shared_control() {
    let root = Root::new();
    let reads = Arc::new(AtomicUsize::new(0));
    let control = Arc::new(
        Control::new(Access {
            reads: Arc::clone(&reads),
        })
        .unwrap(),
    );
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    // ClientKit leaves `params` out of the frame; an empty object is the
    // same request.
    let bare = frame("flash.device-access", Value::Null);
    let reply = ingress.handle(&bare, root.peer());
    assert_eq!(
        result(&reply, "flash.device-access"),
        json!({"observationCount": 2, "observedModes": ["Loader", "Maskrom"]})
    );
    assert_eq!(
        ingress.handle(&frame("flash.device-access", json!({})), root.peer()),
        reply
    );
    assert_eq!(control.handle_frame(&bare), reply);
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 2);
    assert_eq!(reads.load(Ordering::Relaxed), 3);
    // The App never names a socket, a runtime directory or a device.
    for params in [
        json!({"socketPath": "/caller/path"}),
        json!({"runtimeDirectory": "/private/tmp/arkforge"}),
        json!({"serial": "loader-serial-0451"}),
    ] {
        let reply = ingress.handle(&frame("flash.device-access", params.clone()), root.peer());
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    for peer in [
        PeerOrigin {
            euid: root.peer().euid.wrapping_add(1),
            ..root.peer()
        },
        PeerOrigin {
            foreground_console: true,
            ..root.peer()
        },
    ] {
        assert_eq!(code(&ingress.handle(&bare, peer)), "rejected");
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 2);
    assert_eq!(reads.load(Ordering::Relaxed), 3);
    // Without the observer, the App hears what Swift's daemon without it
    // says.
    let refusal = decode_response(
        root.ingress().handle(&bare, root.peer()).trim_ascii_end(),
        "request-1",
        "flash.device-access",
    )
    .unwrap()
    .outcome
    .unwrap_err();
    assert_eq!(
        (refusal.code.as_str(), refusal.message.as_str()),
        (
            "internalError",
            "Rockchip device access observation is not configured"
        )
    );
}
