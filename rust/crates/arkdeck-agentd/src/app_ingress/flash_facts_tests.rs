//! The App's Flash workspace asks `flash.bootloader-status` with no
//! parameters, `flash.prerequisites` of one Target for the profile it
//! prepared and `flash.lanePlanPreview` of one imported archive for them, as
//! ClientKit's `FlashApplicationFacade` does. A recording host
//! stands in for the observers: the boundary is under test here, the reads
//! themselves are replayed by `flash_host_facts_control`. No signed peer,
//! board or installed Runtime is represented.
use super::*;
use arkdeck_contract::{DeviceObservationsResult, WireError};
use std::sync::Mutex;

type Calls = Arc<Mutex<Vec<String>>>;
struct Facts {
    calls: Calls,
}
impl HostServices for Facts {
    fn observed_at(&self) -> String {
        "2026-09-25T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("the Flash reads observe no candidates")
    }
    fn flash_bootloader_status(&self) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push("bootloader".into());
        // A shape the merge base's contract publishes too, so that the
        // published view's replay of this boundary reads the same answer.
        Ok(json!({
            "disposition": "unbound",
            "mode": "loader",
            "observationCount": 1,
            "targetId": null,
            "bindingRevision": null,
        }))
    }
    fn flash_prerequisites(
        &self,
        target_id: &str,
        profile_reference: &str,
    ) -> Result<Value, WireError> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("{target_id}/{profile_reference}"));
        Ok(json!({
            "targetId": target_id,
            "profileReference": profile_reference,
            "bindingRevision": 2,
            "observations": [{"identifier": "loader-mode", "status": "unknown"}],
        }))
    }
    fn flash_lane_plan_preview(&self, target_id: &str) -> Result<Value, WireError> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("preview:{target_id}"));
        Ok(json!({"targetId": target_id, "bindingRevision": 2, "state": "laneNotComposed"}))
    }
}
fn facts(root: &Root) -> (AppIngress<Facts>, Arc<Control<Facts>>, Calls) {
    let calls = Calls::default();
    let control = Arc::new(
        Control::new(Facts {
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
fn the_app_reads_the_board_and_one_targets_prerequisites_through_the_shared_control() {
    let root = Root::new();
    let (ingress, control, calls) = facts(&root);
    let bootloader = frame("flash.bootloader-status", json!({}));
    let reply = ingress.handle(&bootloader, root.peer());
    assert_eq!(
        result(&reply, "flash.bootloader-status")["disposition"],
        "unbound"
    );
    let prerequisites = frame(
        "flash.prerequisites",
        json!({"targetId": "TGT-3ba3f5f43b92", "profileReference": "dayu200"}),
    );
    let answer = ingress.handle(&prerequisites, root.peer());
    assert_eq!(result(&answer, "flash.prerequisites")["bindingRevision"], 2);
    // ClientKit sends the status request without any parameters at all.
    let bare = ingress.handle(&frame("flash.bootloader-status", Value::Null), root.peer());
    assert_eq!(bare, reply);
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 3);
    assert_eq!(
        calls.lock().unwrap().as_slice(),
        ["bootloader", "TGT-3ba3f5f43b92/dayu200", "bootloader"]
    );
    // The local socket reaches the same Control and answers the same bytes.
    assert_eq!(control.handle_frame(&bootloader), reply);
    assert_eq!(control.handle_frame(&prerequisites), answer);
    // Without the observers, the App hears what Swift's daemon without them
    // says.
    let unconfigured = root.ingress();
    for (request, message) in [
        (
            frame("flash.bootloader-status", json!({})),
            "Rockchip bootloader status observation is not configured",
        ),
        (
            frame(
                "flash.prerequisites",
                json!({"targetId": "TGT-1", "profileReference": "dayu200"}),
            ),
            "Flash prerequisite observation is not configured",
        ),
    ] {
        let reply = unconfigured.handle(&request, root.peer());
        let method = if message.starts_with("Rockchip") {
            "flash.bootloader-status"
        } else {
            "flash.prerequisites"
        };
        let refusal = decode_response(reply.trim_ascii_end(), "request-1", method)
            .unwrap()
            .outcome
            .unwrap_err();
        assert_eq!(
            (refusal.code.as_str(), refusal.message.as_str()),
            ("internalError", message)
        );
    }
}

#[test]
fn the_app_names_only_a_target_and_a_profile_and_never_a_board_path_or_command() {
    let root = Root::new();
    let (ingress, _control, calls) = facts(&root);
    for params in [
        json!({"targetId": "TGT-1"}),
        json!({"serial": "loader-serial-0451"}),
        json!({"rockusbPath": "/usr/local/bin/rockusb"}),
        json!({"daemon": "/private/tmp/arkforged"}),
    ] {
        let reply = ingress.handle(
            &frame("flash.bootloader-status", params.clone()),
            root.peer(),
        );
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    for params in [
        json!({}),
        json!({"targetId": "TGT-1"}),
        json!({"profileReference": "dayu200"}),
        json!({"targetId": 5, "profileReference": "dayu200"}),
        json!({"targetId": "TGT-1", "profileReference": null}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "connectKey": "forged"}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "rawCommand": "shell id"}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "bundle": "/tmp/x.zip"}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "peerEUID": root.peer().euid}),
    ] {
        let reply = ingress.handle(&frame("flash.prerequisites", params.clone()), root.peer());
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    let valid = [
        frame("flash.bootloader-status", json!({})),
        frame(
            "flash.prerequisites",
            json!({"targetId": "TGT-1", "profileReference": "dayu200"}),
        ),
    ];
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
        for request in &valid {
            assert_eq!(code(&ingress.handle(request, peer)), "rejected");
        }
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert!(calls.lock().unwrap().is_empty());
    // An unsupported profile passes the closed shape and is refused by the
    // shared Control as Swift refuses it, without reaching the observer.
    let unsupported = ingress.handle(
        &frame(
            "flash.prerequisites",
            json!({"targetId": "TGT-1", "profileReference": "rk3568-generic"}),
        ),
        root.peer(),
    );
    assert_eq!(code(&unsupported), "invalidParams");
    assert!(calls.lock().unwrap().is_empty());
}

/// The App previews the lane plan of one imported archive for one Target and
/// profile, as ClientKit sends it: exactly those three strings, and never a
/// path, a topology or a plan of its own.
#[test]
fn the_app_previews_one_archive_for_one_target_and_names_nothing_else() {
    let root = Root::new();
    let (ingress, control, calls) = facts(&root);
    let digest = "e".repeat(64);
    let preview = frame(
        "flash.lanePlanPreview",
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "archiveSha256": digest}),
    );
    let reply = ingress.handle(&preview, root.peer());
    assert_eq!(
        result(&reply, "flash.lanePlanPreview")["state"],
        "laneNotComposed"
    );
    // The local socket reaches the same Control and answers the same bytes.
    assert_eq!(control.handle_frame(&preview), reply);
    for params in [
        json!({}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200"}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "archiveSha256": 7}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "archiveSha256": digest,
            "usbTopology": "17956864"}),
        json!({"targetId": "TGT-1", "profileReference": "dayu200", "archiveSha256": digest,
            "bundle": "/tmp/x.zip"}),
    ] {
        let reply = ingress.handle(&frame("flash.lanePlanPreview", params.clone()), root.peer());
        assert_eq!(code(&reply), "invalidParams", "{params}");
    }
    // A digest the closed shape carries but Swift's handler refuses is the
    // shared Control's refusal, before any preview.
    let short = ingress.handle(
        &frame(
            "flash.lanePlanPreview",
            json!({"targetId": "TGT-1", "profileReference": "dayu200",
                "archiveSha256": "e".repeat(63)}),
        ),
        root.peer(),
    );
    assert_eq!(code(&short), "invalidParams");
    // Another user, another process or the foreground console is refused.
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
        assert_eq!(code(&ingress.handle(&preview, peer)), "rejected");
    }
    assert_eq!(
        calls.lock().unwrap().as_slice(),
        ["preview:TGT-1", "preview:TGT-1"]
    );
}
