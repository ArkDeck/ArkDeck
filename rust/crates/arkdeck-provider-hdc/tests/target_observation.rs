//! The target observation port over the shared fake HDC driver: the tool
//! version and the candidate list read through the real process dispatch,
//! bracketed by injected USB relations, the identity readback that the
//! adoption path binds to, and the argv the driver logged.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    DAYU200_NORMAL_PRODUCT_ID, Expected, HdcDispatch, NoUsbRelations, ROCKUSB_VENDOR_ID, Reading,
    UsbRelation, adoption_holds, observe_device_identity, observe_tool_version,
};
use common::{CONNECT_KEY, SharedFake};

fn relation(attachment_id: u64) -> UsbRelation {
    UsbRelation {
        serial: CONNECT_KEY.into(),
        location: "100".into(),
        attachment_id,
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
    }
}

#[test]
fn the_observation_port_reads_the_shared_fake_bracketed_by_relations() {
    let fake = SharedFake::from_fixture(None);
    let dispatch = &fake.dispatch as &dyn HdcDispatch;
    assert_eq!(observe_tool_version(dispatch).unwrap(), "3.2.0d");

    // Without a relation reader every candidate is listed but unproved.
    let reading = Reading::take(dispatch, &NoUsbRelations).unwrap();
    reading.validate().unwrap();
    assert_eq!(reading.candidates.len(), 1);
    assert_eq!(reading.candidates[0].connect_key, CONNECT_KEY);
    assert_eq!(reading.candidates[0].state, "Connected");
    assert_eq!(reading.rows()[0].continuity(), "generationScoped");

    // One usable relation in both reads proves the candidate, and the
    // adoption's final check holds over the live relations and the readback.
    let live = || Ok(vec![relation(17)]);
    let reading = Reading::take(dispatch, &live).unwrap();
    let row = &reading.rows()[0];
    assert_eq!(row.relation, Some(relation(17)));
    assert_eq!(row.continuity(), "relationProven");
    let identity = observe_device_identity(
        dispatch,
        CONNECT_KEY,
        Expected {
            tool_version: Some("3.2.0d"),
            ..Expected::default()
        },
    )
    .unwrap();
    assert_eq!(identity["serial"], CONNECT_KEY);
    assert!(adoption_holds(&relation(17), &live().unwrap(), &identity));
    assert!(
        !adoption_holds(&relation(17), &[relation(18)], &identity),
        "a reconnect under the readback"
    );

    // What the driver ran: `-v`, then `list targets -v` for each list and
    // for the identity readback — nothing else, and never with `-t`.
    let log = String::from_utf8(fake.invocations()).unwrap();
    let lines: Vec<&str> = log.lines().collect();
    assert_eq!(
        lines,
        vec![
            "-v\u{1f}",
            "list\u{1f}targets\u{1f}-v\u{1f}",
            "list\u{1f}targets\u{1f}-v\u{1f}",
            "list\u{1f}targets\u{1f}-v\u{1f}",
        ]
    );

    // The fixture's other device: the key is not the one the row carries,
    // so the identity readback refuses and the relation proves no row.
    fake.set_mode("otherDevice");
    assert_eq!(
        observe_device_identity(dispatch, CONNECT_KEY, Expected::default())
            .unwrap_err()
            .0,
        "targetConfirmationMismatch: expected exactly one matching target row, saw 0"
    );
    let reading = Reading::take(dispatch, &live).unwrap();
    assert_eq!(reading.rows()[0].relation, None);
    fake.set_mode("emptyVersion");
    assert_eq!(
        observe_tool_version(dispatch).unwrap_err().0,
        "tool version could not be verified"
    );
}
