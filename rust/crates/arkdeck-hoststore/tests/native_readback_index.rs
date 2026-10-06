//! Portable exact-byte proof for the macOS frozen native snapshot consumers.
//! Only public committed fixtures are read; no daemon or transport is opened.
#![cfg(any(target_os = "macos", windows))]

mod support;

use arkdeck_contract::{foundation_json, sha256_hex};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use support::hdc_oracle::native_readback;

fn extended(bytes: &[u8]) -> Vec<u8> {
    let mut record: Value = serde_json::from_slice(bytes).unwrap();
    let timeline = record["timeline"].as_array_mut().unwrap();
    let mut rows = Vec::new();
    for row in timeline.iter() {
        rows.push(row.clone());
        for (step, phase) in [
            ("backup-current-version", "backup"),
            ("rollback-native-library", "rollback"),
        ] {
            if row
                .as_str()
                .unwrap()
                .starts_with(&format!("verified {step} ["))
            {
                rows.push(json!(format!(
                    "native-readback {step} {}",
                    native_readback::expected(phase)
                )));
            }
        }
    }
    if *timeline == rows {
        bytes.to_vec()
    } else {
        *timeline = rows;
        foundation_json::pretty(&record, true).unwrap()
    }
}

fn snapshot(fixture: &str, prefix: &str) -> (Value, Value, BTreeMap<String, Vec<u8>>) {
    let root = support::fixture(fixture);
    let expected = support::document(&root, &format!("{prefix}/index.json"));
    let mut actual = expected.clone();
    let mut records = BTreeMap::new();
    for row in actual["rows"].as_array_mut().unwrap() {
        let job = row["jobId"].as_str().unwrap().to_owned();
        let original = fs::read(
            root.join(prefix)
                .join("jobs")
                .join(&job)
                .join("job-record.json"),
        )
        .unwrap();
        assert_eq!(
            row["recordSHA256"],
            sha256_hex(&support::machine_independent(&original)),
            "the frozen digest itself still proves its whole historical bytes"
        );
        let current = extended(&original);
        assert_eq!(
            native_readback::historical_bytes(&current),
            original,
            "all historical serialized record bytes remain exact"
        );
        row["recordSHA256"] = json!(sha256_hex(&support::machine_independent(&current)));
        records.insert(job, current);
    }
    (expected, actual, records)
}

#[test]
fn native_final_and_every_published_or_parked_recovery_index_keep_the_frozen_digest() {
    let fixture = "device-mutation-reconcile/nativeLibrary";
    let cases = support::document(&support::fixture(fixture), "cases.json");
    let mut snapshots = vec![
        ("deploy-native-library", "store".to_owned()),
        (fixture, "store".to_owned()),
    ];
    snapshots.extend(
        cases["steps"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|step| {
                let step = step.as_str().unwrap();
                (step != "crash").then(|| (fixture, format!("steps/{step}")))
            }),
    );
    let mut changed = 0;
    let mut unchanged = 0;
    for (fixture, prefix) in snapshots {
        let (expected, actual, records) = snapshot(fixture, &prefix);
        for (old, current) in expected["rows"]
            .as_array()
            .unwrap()
            .iter()
            .zip(actual["rows"].as_array().unwrap())
        {
            if old["recordSHA256"] == current["recordSHA256"] {
                unchanged += 1;
            } else {
                changed += 1;
            }
        }
        assert_eq!(
            native_readback::historical_index(&actual, |job| records[job].clone()),
            expected,
            "every row/hash/column of {fixture}/{prefix}"
        );
    }
    assert!(
        changed > 0,
        "the actual new serialized bytes must change some current digests"
    );
    assert!(
        unchanged > 0,
        "rows without readback additions are not replaced"
    );
}

#[test]
fn native_index_requires_the_complete_original_record_digest_and_identity() {
    let (_, actual, records) = snapshot("deploy-native-library", "store");
    let first = actual["rows"][0]["jobId"].as_str().unwrap().to_owned();
    for field in ["recordSHA256", "jobId"] {
        let mut bad = actual.clone();
        bad["rows"][0][field] = json!(if field == "recordSHA256" {
            "0".repeat(64)
        } else {
            "another-job".into()
        });
        assert!(
            std::panic::catch_unwind(|| native_readback::historical_index(&bad, |job| {
                records.get(job).unwrap_or(&records[&first]).clone()
            }))
            .is_err(),
            "unprojected {field} mismatch must refuse"
        );
    }
    let mut changed_records = records.clone();
    let mut value: Value = serde_json::from_slice(&changed_records[&first]).unwrap();
    value["state"] = json!("failed");
    changed_records.insert(first, foundation_json::pretty(&value, true).unwrap());
    assert!(
        std::panic::catch_unwind(|| native_readback::historical_index(&actual, |job| {
            changed_records[job].clone()
        }))
        .is_err(),
        "record drift cannot be normalized before original index correlation"
    );
}

#[test]
fn native_index_refuses_missing_extra_changed_proofs_and_preserves_other_drift() {
    let (expected, actual, records) = snapshot("deploy-native-library", "store");
    let job = actual["rows"][0]["jobId"].as_str().unwrap().to_owned();
    for corruption in ["missing", "extra", "changed"] {
        let mut value: Value = serde_json::from_slice(&records[&job]).unwrap();
        let timeline = value["timeline"].as_array_mut().unwrap();
        let at = timeline
            .iter()
            .position(|row| row.as_str().unwrap().starts_with("native-readback "))
            .unwrap();
        if corruption == "missing" {
            timeline.remove(at);
        } else {
            let mut proof = native_readback::expected("backup");
            if corruption == "extra" {
                proof["unknown"] = json!(true);
            } else {
                proof["backupSha256"] = json!("f".repeat(64));
            }
            timeline[at] = json!(format!("native-readback backup-current-version {proof}"));
        }
        let bytes = foundation_json::pretty(&value, true).unwrap();
        let mut bad = actual.clone();
        bad["rows"][0]["recordSHA256"] = json!(sha256_hex(&support::machine_independent(&bytes)));
        assert!(
            std::panic::catch_unwind(|| native_readback::historical_index(&bad, |id| {
                if id == job {
                    bytes.clone()
                } else {
                    records[id].clone()
                }
            }))
            .is_err(),
            "an integrity-matching but invalid {corruption} proof must refuse"
        );
    }
    let mut value: Value = serde_json::from_slice(&records[&job]).unwrap();
    value["state"] = json!("failed");
    let bytes = foundation_json::pretty(&value, true).unwrap();
    let mut bad = actual;
    bad["rows"][0]["recordSHA256"] = json!(sha256_hex(&support::machine_independent(&bytes)));
    assert_ne!(
        native_readback::historical_index(&bad, |id| {
            if id == job {
                bytes.clone()
            } else {
                records[id].clone()
            }
        }),
        expected,
        "non-additive record drift remains a historical digest mismatch"
    );
}
