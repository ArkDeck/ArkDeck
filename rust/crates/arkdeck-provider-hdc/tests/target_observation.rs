//! The target observation port over the shared fake HDC driver: the tool
//! version and the candidate list read through the real process dispatch,
//! bracketed by injected USB relations or by the Runtime's registry reader
//! over a census, the identity readback that the adoption path binds to, and
//! the argv the driver logged. The registry reader also reads this host's own
//! I/O Registry, which proves nothing about a device.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{
    DAYU200_NORMAL_PRODUCT_ID, Expected, HdcDispatch, NoUsbRelations, ROCKUSB_VENDOR_ID, Reading,
    UsbRegistryRelations, UsbRelation, UsbRelations, adoption_holds, observe_device_identity,
    observe_tool_version,
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

/// The DAYU200 in its HDC-normal personality as the host census lists it.
fn board(entry: u64) -> UsbHostDevice {
    UsbHostDevice {
        serial: CONNECT_KEY.into(),
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
        topology: "100".into(),
        product_name: Some("\"HDC Device\"".into()),
        registry_entry_id: Some(entry),
    }
}

#[test]
fn the_registry_reader_brackets_the_shared_fake_as_swift_s_census_does() {
    let fake = SharedFake::from_fixture(None);
    let dispatch = &fake.dispatch as &dyn HdcDispatch;

    // The census lists the board beside devices that are not it: the reading
    // proves the candidate, and the adoption's final check holds over the
    // same census and the readback.
    let census = || {
        Ok(vec![
            UsbHostDevice {
                serial: "keyboard".into(),
                vendor_id: 0x05ac,
                product_id: 0x0342,
                topology: "1048576".into(),
                product_name: Some("Keyboard".into()),
                registry_entry_id: Some(9),
            },
            UsbHostDevice {
                product_id: 0x350a,
                product_name: None,
                ..board(8)
            },
            board(17),
        ])
    };
    let reader = UsbRegistryRelations::new(census);
    let reading = Reading::take(dispatch, &reader).unwrap();
    assert_eq!(reading.rows()[0].relation, Some(relation(17)));
    assert_eq!(reading.rows()[0].continuity(), "relationProven");
    let identity = observe_device_identity(dispatch, CONNECT_KEY, Expected::default()).unwrap();
    assert!(adoption_holds(
        &relation(17),
        &reader.relations().unwrap(),
        &identity
    ));

    // A census that cannot be taken fails the reading in Swift's words before
    // any list is read: it is never a list of unproved candidates.
    let calls = |fake: &SharedFake| {
        String::from_utf8(fake.invocations())
            .unwrap()
            .lines()
            .count()
    };
    let before = calls(&fake);
    let unavailable = UsbRegistryRelations::new(|| Err(RegistryUnavailable::Services(-1)));
    assert_eq!(
        Reading::take(dispatch, &unavailable).unwrap_err().0,
        "admissionRejected(\"USB registry unavailable\")"
    );
    assert_eq!(
        calls(&fake),
        before,
        "no list is read after the first census fails"
    );
}

/// This host's registry through the production reader: it answers whether or
/// not a board is attached, and anything it lists is an HDC-normal DAYU200
/// relation with an attachment. A host-only read, never device evidence.
#[test]
fn the_system_registry_reader_answers_on_this_host() {
    let relations = UsbRegistryRelations::system()
        .relations()
        .expect("the host registry answers");
    if relations.is_empty() {
        eprintln!("skipped: no DAYU200 in its HDC-normal personality is attached");
    } else {
        eprintln!(
            "{} DAYU200 relation(s) on this host: a host-only read, not device evidence",
            relations.len()
        );
    }
    for relation in &relations {
        assert_eq!(relation.vendor_id, ROCKUSB_VENDOR_ID);
        assert_eq!(relation.product_id, DAYU200_NORMAL_PRODUCT_ID);
        assert_ne!(relation.attachment_id, 0);
    }
}
