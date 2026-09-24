//! The App binds the Loader of the one attached board to a Target it
//! selected, as ClientKit's `FlashApplicationFacade.bindCurrentLoader` does:
//! it names that Target and the revision it saw, and nothing else. A
//! recording host stands in for the coordinator: the boundary is under test
//! here, the binding itself is replayed by `loader_binding_control`. No
//! signed peer, board or installed Runtime is represented.
use super::*;
use arkdeck_contract::{DeviceObservationsResult, WireError};
use std::sync::Mutex;

type Calls = Arc<Mutex<Vec<String>>>;
struct Binding {
    calls: Calls,
}
impl HostServices for Binding {
    fn observed_at(&self) -> String {
        "2026-09-25T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("the Loader binding observes no candidates")
    }
    fn flash_bind_current_loader(
        &self,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<Value, WireError> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("{target_id}@{expected_binding_revision}"));
        Ok(json!({
            "targetId": target_id,
            "previousBindingRevision": expected_binding_revision,
            "bindingRevision": expected_binding_revision + 1,
            "updated": true,
            "selectionEvidenceSha256": "e".repeat(64),
            "settledJobId": null,
        }))
    }
}
fn binding(root: &Root) -> (AppIngress<Binding>, Arc<Control<Binding>>, Calls) {
    let calls = Calls::default();
    let control = Arc::new(
        Control::new(Binding {
            calls: Arc::clone(&calls),
        })
        .unwrap(),
    );
    (
        AppIngress::new(Arc::clone(&control), root.peer().euid),
        control,
        calls,
    )
}

#[test]
fn the_app_binds_the_attached_loader_to_the_target_it_selected() {
    let root = Root::new();
    let (ingress, control, calls) = binding(&root);
    let request = frame(
        "flash.bind-current-loader",
        json!({"targetId": "TGT-3ba3f5f43b92", "expectedBindingRevision": 1}),
    );
    let reply = ingress.handle(&request, root.peer());
    let receipt = result(&reply, "flash.bind-current-loader");
    assert_eq!(receipt["bindingRevision"], 2);
    assert_eq!(receipt["settledJobId"], Value::Null);
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 1);
    assert_eq!(calls.lock().unwrap().as_slice(), ["TGT-3ba3f5f43b92@1"]);
    // The local socket reaches the same Control and answers the same bytes.
    assert_eq!(control.handle_frame(&request), reply);
    // Without the coordinator, the App hears what Swift's daemon without it
    // says.
    let refusal = decode_response(
        root.ingress()
            .handle(&request, root.peer())
            .trim_ascii_end(),
        "request-1",
        "flash.bind-current-loader",
    )
    .unwrap()
    .outcome
    .unwrap_err();
    assert_eq!(
        (refusal.code.as_str(), refusal.message.as_str()),
        ("internalError", "Rockchip Loader binding is not configured")
    );
}

#[test]
fn the_app_names_only_a_target_and_its_revision_and_never_a_board_or_a_binding() {
    let root = Root::new();
    let (ingress, _control, calls) = binding(&root);
    for params in [
        json!({}),
        json!({"targetId": "TGT-1"}),
        json!({"expectedBindingRevision": 1}),
        json!({"targetId": 5, "expectedBindingRevision": 1}),
        json!({"targetId": "TGT-1", "expectedBindingRevision": "1"}),
        json!({"targetId": "TGT-1", "expectedBindingRevision": 1, "serial": "loader-serial-0451"}),
        json!({"targetId": "TGT-1", "expectedBindingRevision": 1, "usbTopology": "17956864"}),
        json!({"targetId": "TGT-1", "expectedBindingRevision": 1, "selectionEvidenceSha256": "e"}),
        json!({"targetId": "TGT-1", "expectedBindingRevision": 1, "peerEUID": root.peer().euid}),
    ] {
        let reply = ingress.handle(
            &frame("flash.bind-current-loader", params.clone()),
            root.peer(),
        );
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    let valid = frame(
        "flash.bind-current-loader",
        json!({"targetId": "TGT-1", "expectedBindingRevision": 1}),
    );
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
    assert!(calls.lock().unwrap().is_empty());
    // A revision that is no positive integer passes the closed shape and is
    // refused by the shared Control as Swift refuses it, before the owner.
    let zero = ingress.handle(
        &frame(
            "flash.bind-current-loader",
            json!({"targetId": "TGT-1", "expectedBindingRevision": 0}),
        ),
        root.peer(),
    );
    assert_eq!(code(&zero), "invalidParams");
    assert!(calls.lock().unwrap().is_empty());
}
