//! Versioned prospective CHG-2026-081 software oracle; no hardware evidence.
#![cfg(any(target_os = "macos", windows))]
mod support;
use serde_json::json;
use support::hdc_oracle::{self, native_current};

#[test]
fn every_current_native_exchange_and_complete_store_matches_its_versioned_oracle() {
    let name = native_current::fixture_name();
    native_current::assert_source(&support::fixture(name));
    hdc_oracle::assert_replays(name, 40, native_current::call_count());
}

#[test]
#[ignore = "explicit CREATE_NEW oracle recording, never a normal test update"]
fn record_current_native_oracle() {
    let output =
        std::env::var_os("ARKDECK_RECORD_NATIVE_CURRENT_ORACLE").expect("explicit new destination");
    hdc_oracle::record_native_current(std::path::Path::new(&output));
}

#[test]
fn native_oracle_refuses_a_missing_reordered_or_foreign_preflight_call() {
    let expected = native_current::expected_calls();
    let root = std::path::Path::new("/private/tmp/arkdeck-hdc-oracle");
    native_current::assert_original_calls(&expected, root);
    if expected.is_empty() {
        assert!(
            std::panic::catch_unwind(|| native_current::assert_original_calls(
                "unpublished-device-call\n",
                root
            ))
            .is_err()
        );
    } else {
        let mut lines: Vec<_> = expected.lines().map(str::to_owned).collect();
        lines.swap(0, 1);
        assert!(
            std::panic::catch_unwind(|| native_current::assert_original_calls(
                &(lines.join("\n") + "\n"),
                root
            ))
            .is_err()
        );
        let missing = expected.lines().skip(1).collect::<Vec<_>>().join("\n") + "\n";
        assert!(
            std::panic::catch_unwind(|| native_current::assert_original_calls(&missing, root))
                .is_err()
        );
        let foreign = expected.replacen("shell", "unpublished-command", 1);
        assert!(
            std::panic::catch_unwind(|| native_current::assert_original_calls(&foreign, root))
                .is_err()
        );
        let misplaced = expected.lines().skip(3).collect::<Vec<_>>().join("\n")
            + "\n"
            + &expected.lines().take(3).collect::<Vec<_>>().join("\n")
            + "\n";
        assert!(
            std::panic::catch_unwind(|| native_current::assert_original_calls(&misplaced, root))
                .is_err()
        );
    }
}

#[test]
fn current_import_labels_preserve_all_metadata_and_are_bijective() {
    let proofs = support::document(
        &support::fixture(native_current::fixture_name()),
        "publication-proofs.json",
    );
    let expected = &proofs[0]["importReceipt"];
    let id = "imp-11111111-1111-4111-a111-111111111111";
    let artifact = "ART-11111111111111111111111111111111";
    let mut actual = expected.clone();
    actual["importId"] = json!(id);
    actual["receipt"]["importId"] = json!(id);
    actual["receipt"]["owner"]["id"] = json!(id);
    actual["receipt"]["artifactId"] = json!(artifact);
    actual["receipt"]["lease"] = json!(format!("lease-v1:{id}:{artifact}"));
    let mut labels = support::debug_hap::HostLabels::portable();
    native_current::learn_receipt_labels(&actual, expected, &mut labels);
    assert_eq!(labels.swift(&actual), *expected);
    for pointer in [
        "/metadata/sha256",
        "/receipt/bindingRevision",
        "/receipt/owner/kind",
        "/receipt/lease",
        "/state",
    ] {
        let mut drift = actual.clone();
        *drift.pointer_mut(pointer).unwrap() = json!("foreign");
        assert!(
            std::panic::catch_unwind(|| native_current::learn_receipt_labels(
                &drift,
                expected,
                &mut support::debug_hap::HostLabels::portable()
            ))
            .is_err(),
            "{pointer}"
        );
    }
    let mut other = actual.clone();
    let other_id = "imp-22222222-2222-4222-a222-222222222222";
    other["importId"] = json!(other_id);
    other["receipt"]["importId"] = json!(other_id);
    other["receipt"]["owner"]["id"] = json!(other_id);
    other["receipt"]["lease"] = json!(format!("lease-v1:{other_id}:{artifact}"));
    assert!(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            native_current::learn_receipt_labels(&other, expected, &mut labels)
        }))
        .is_err()
    );
}
