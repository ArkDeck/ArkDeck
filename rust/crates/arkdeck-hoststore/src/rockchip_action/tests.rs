//! The typed Rockchip action against Swift: the digests Swift's records pin,
//! the catalog, the descriptor match and `materialize()`'s decoding and
//! refusals.
use super::*;
use std::path::Path;

const KEY: &str = "1501ffff00000000000000000000cafe";

fn fixture(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/loader-binding/inputs")
        .join(name);
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn expectation() -> Expectation {
    Expectation {
        previous_connect_key: KEY.into(),
        previous_identity_sha256: sha256_hex(KEY.as_bytes()),
        usb_topology: "18874368".into(),
    }
}

fn every_action() -> Vec<RockchipAction> {
    let identity = "a".repeat(64);
    vec![
        RockchipAction::EnterLoader(KEY.into()),
        RockchipAction::ObserveHdcNormalUsb(KEY.into()),
        RockchipAction::WaitForHdcDisconnect(KEY.into()),
        RockchipAction::WaitForLoader(identity.clone()),
        RockchipAction::RebindLoader(identity.clone()),
        RockchipAction::RebootToNormal(identity),
        RockchipAction::WaitForHdcReconnect(KEY.into()),
        RockchipAction::WaitForBoundHdcReconnect(expectation()),
        RockchipAction::VerifyBoundBuild {
            expectation: expectation(),
            product_model: "ohos".into(),
            build_version: "OpenHarmony-7.0.0.37".into(),
        },
        RockchipAction::CapturePostFlashDiagnostics {
            connect_key: KEY.into(),
            request: CaptureRequest::new(30, vec!["arkdeck:*".into()], 16 * 1024 * 1024).unwrap(),
        },
    ]
}

/// The two actions Swift's records under `rockchip-runtime` hold in the
/// Loader binding oracle: their persisted form and digest are the ones Swift
/// wrote.
#[test]
fn the_persisted_form_and_digest_are_the_ones_swifts_records_hold() {
    for (name, action) in [
        (
            "record-reconcile-intent.json",
            RockchipAction::ObserveHdcNormalUsb(KEY.into()),
        ),
        (
            "record-wait-for-hdc-intent.json",
            RockchipAction::WaitForHdcReconnect(KEY.into()),
        ),
    ] {
        let intent = fixture(name);
        assert_eq!(action.persisted(), intent["action"], "{name}");
        assert_eq!(action.sha256(), intent["actionSHA256"], "{name}");
        assert_eq!(
            RockchipAction::from_persisted(&intent["action"]).unwrap(),
            action,
            "{name}"
        );
    }
}

#[test]
fn every_action_round_trips_through_its_persisted_form() {
    for action in every_action() {
        assert_eq!(
            RockchipAction::from_persisted(&action.persisted()).unwrap(),
            action
        );
    }
}

#[test]
fn the_catalog_and_the_effects_are_swifts() {
    let identifiers: Vec<(&str, &str)> = every_action()
        .iter()
        .map(|action| (action.identifier(), action.effect()))
        .collect();
    assert_eq!(
        identifiers,
        [
            ("rockchip.hdc.enter-loader.v1", "deviceMutation"),
            ("rockchip.iokit.observe-hdc-normal.v1", "readOnly"),
            ("rockchip.hdc.wait-disconnect.v1", "readOnly"),
            ("rockchip.rockusb.wait-loader.v1", "readOnly"),
            ("rockchip.rockusb.rebind-loader.v1", "readOnly"),
            ("rockchip.rockusb.reboot-normal.v1", "deviceMutation"),
            ("rockchip.hdc.wait-reconnect.v1", "readOnly"),
            ("rockchip.hdc.wait-bound-reconnect.v1", "readOnly"),
            ("rockchip.hdc.verify-bound-build.v1", "readOnly"),
            ("rockchip.hdc.capture-post-flash-hilog.v1", "readOnly"),
        ]
    );
}

/// A catalog descriptor is one the durable host accepts: its identifier and
/// digest are the action's, and the action matches it. The connect key or
/// identity the action names must be the descriptor's.
#[test]
fn a_catalog_descriptor_matches_its_action_and_no_other() {
    let identity = "a".repeat(64);
    for action in every_action() {
        let descriptor = action.descriptor(
            "job-1",
            "step-1",
            "TGT-1",
            2,
            KEY,
            &identity,
            &"7".repeat(64),
        );
        assert_eq!(descriptor.identifier, action.identifier());
        assert_eq!(descriptor.action_sha256, action.sha256());
        assert_eq!(
            serde_json::from_str::<Value>(&descriptor.action).unwrap(),
            action.persisted()
        );
        assert!(action.matches(&descriptor), "{action:?}");
        let mut elsewhere = descriptor.clone();
        elsewhere.connect_key = "another-key".into();
        elsewhere.expected_identity_sha256 = "b".repeat(64);
        assert!(!action.matches(&elsewhere), "{action:?}");
        let mut renamed = descriptor;
        renamed.identifier = "rockchip.hdc.other.v1".into();
        assert!(!action.matches(&renamed), "{action:?}");
    }
}

#[test]
fn a_persisted_action_is_refused_in_swifts_words() {
    let cases: [(Value, &str); 9] = [
        (
            json!({"kind": "rockchip.flashPartitions", "arguments": {}}),
            "rockchip.flashPartitions is a legacy in-process Rockchip write intent, removed in \
             CHG-2026-059. The record is intact; the intent is not replayable and cannot be \
             re-derived, so this job's outcome is unknown until a person reconciles the device.",
        ),
        (
            json!({"kind": "rockchip.verifyBuild", "arguments": {}}),
            "rockchip.verifyBuild is the retired unbound post-flash verification; it does not \
             prove device identity and is superseded by rockchip.verifyBoundBuild",
        ),
        (
            json!({"kind": "rockchip.teleport", "arguments": {}}),
            "persisted typed provider action kind rockchip.teleport is unknown",
        ),
        (
            json!({"kind": "rockchip.enterLoader", "arguments": {}}),
            "persisted rockchip.enterLoader is missing string connectKey",
        ),
        (
            json!({"kind": "rockchip.waitForBoundHDCReconnect", "arguments": {
                "previousConnectKey": KEY, "previousIdentitySha256": "b".repeat(64),
                "usbTopology": "18874368"}}),
            "persisted rockchip.waitForBoundHDCReconnect carries an invalid HDC binding \
             expectation",
        ),
        (
            json!({"kind": "rockchip.capturePostFlashDiagnostics", "arguments": {
                "connectKey": KEY, "durationSeconds": 0, "filters": [], "byteBudget": 4096}}),
            "outOfBounds(field: \"durationSeconds\", detail: \"1...600\")",
        ),
        (
            json!({"kind": "rockchip.capturePostFlashDiagnostics", "arguments": {
                "connectKey": KEY, "durationSeconds": 5, "filters": ["a;b"],
                "byteBudget": 4096}}),
            "malformed(field: \"filters\", detail: \"filter tokens are bounded ASCII, no shell \
             fragments\")",
        ),
        (
            json!({"kind": "rockchip.capturePostFlashDiagnostics", "arguments": {
                "connectKey": KEY, "durationSeconds": 5, "filters": [], "byteBudget": 1}}),
            "outOfBounds(field: \"byteBudget\", detail: \"1024...134217728\")",
        ),
        (
            json!({"kind": "rockchip.capturePostFlashDiagnostics", "arguments": {
                "connectKey": KEY, "durationSeconds": 5, "filters": [7], "byteBudget": 4096}}),
            "persisted rockchip.capturePostFlashDiagnostics.filters contains a non-string",
        ),
    ];
    for (persisted, error) in cases {
        assert_eq!(
            RockchipAction::from_persisted(&persisted),
            Err(error.to_owned()),
            "{persisted}"
        );
    }
}

/// Swift's floor for the capture command: the duration and 15 s of grace,
/// never under 45 s.
#[test]
fn the_capture_command_timeout_is_swifts() {
    for (duration, timeout) in [(5, 45), (30, 45), (31, 46), (600, 615)] {
        assert_eq!(
            CaptureRequest::new(duration, Vec::new(), 4096)
                .unwrap()
                .command_timeout_seconds(),
            timeout
        );
    }
    assert_eq!(
        CaptureRequest::new(5, vec!["x".into(); 17], 4096),
        Err("outOfBounds(field: \"filters\", detail: \"at most 16\")".into())
    );
}
