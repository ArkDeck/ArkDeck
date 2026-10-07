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

#[test]
fn publication_aggregates_require_the_original_manifest_and_complete_file_counts() {
    use std::fs;
    let fixture = support::fixture(native_current::fixture_name());
    native_current::assert_source(&fixture);
    let proofs = support::document(&fixture, "publication-proofs.json");
    let root = support::fixture_fs::temporary_root().join(format!(
        "arkdeck-native-aggregate-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    support::fixture_fs::private_dir(&root);
    for expected in proofs.as_array().unwrap() {
        let job = expected["jobId"].as_str().unwrap();
        let mut record = support::document(&fixture, &format!("store/jobs/{job}/job-record.json"));
        let relative = record["sessionPublicationRecord"]["relativeSessionPath"]
            .as_str()
            .unwrap()
            .to_owned();
        let destination = root.join("Sessions").join(&relative);
        for (path, bytes) in
            support::debug_hap::tree_bytes(&fixture.join("sessions").join(&relative))
        {
            let path = destination.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, bytes).unwrap();
        }
        let path = destination.join("manifest.json");
        let original = fs::read(&path).unwrap();
        let mut host_manifest = String::from_utf8(original.clone()).unwrap();
        assert_eq!(host_manifest.matches("\"PLATFORM-MACOS@0.2.0\"").count(), 1);
        if cfg!(windows) {
            host_manifest =
                host_manifest.replacen("\"PLATFORM-MACOS@0.2.0\"", "\"PLATFORM-WINDOWS@0.2.0\"", 1);
        }
        fs::write(&path, host_manifest.as_bytes()).unwrap();
        let mut actual = expected.clone();
        actual["manifestSHA256"] = json!(arkdeck_contract::sha256_hex(host_manifest.as_bytes()));
        actual["manifestByteCount"] = json!(host_manifest.len().to_string());
        actual["sessionShow"]["sizeBytes"] = json!(
            support::debug_hap::tree_bytes(&destination)
                .values()
                .map(Vec::len)
                .sum::<usize>()
                .to_string()
        );
        record["sessionPublicationRecord"]["receipt"]["manifestSHA256"] =
            actual["manifestSHA256"].clone();
        let record_path = root.join("store/jobs").join(job).join("job-record.json");
        fs::create_dir_all(record_path.parent().unwrap()).unwrap();
        fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
        assert_eq!(
            native_current::publication_size(&fixture, &root, &actual, expected).to_string(),
            actual["sessionShow"]["sizeBytes"]
        );
        let mut wrong = actual.clone();
        wrong["sessionShow"]["sizeBytes"] = json!("1");
        assert!(
            std::panic::catch_unwind(|| native_current::publication_size(
                &fixture, &root, &wrong, expected
            ))
            .is_err()
        );
        let mut wrong_manifest = expected.clone();
        wrong_manifest["manifestSHA256"] = json!("0".repeat(64));
        assert!(
            std::panic::catch_unwind(|| native_current::publication_size(
                &fixture,
                &root,
                &actual,
                &wrong_manifest
            ))
            .is_err()
        );
        let audit = destination.join("audit/session.jsonl");
        let original_audit = fs::read(&audit).unwrap();
        let mut changed = original_audit.clone();
        changed.extend_from_slice(b"changed non-manifest entry");
        fs::write(&audit, changed).unwrap();
        assert!(
            std::panic::catch_unwind(|| native_current::publication_size(
                &fixture, &root, &actual, expected
            ))
            .is_err()
        );
        fs::write(audit, original_audit).unwrap();
    }
    assert!(root.starts_with(support::fixture_fs::temporary_root()));
    fs::remove_dir_all(root).unwrap();
}
