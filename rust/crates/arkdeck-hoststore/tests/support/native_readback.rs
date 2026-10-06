//! The additive native readback proof, checked before the frozen Swift oracle
//! compares its historical fields. No fixture bytes or pins are rewritten.
use arkdeck_contract::{foundation_json, sha256_hex};
use serde_json::{Value, json};

const INPUT: &str = "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53";
const PREVIOUS: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const LOADER: &str = "/data/storage/el1/bundle/libs/arm/libexample.so";

pub fn expected(phase: &str) -> Value {
    let mut value = json!({
        "schemaVersion":"arkdeck.native-library.readback/1",
        "inputABI":"arm64-v8a",
        "inputBuildId":"00112233445566778899aabbccddeeff10213243",
        "inputSha256":INPUT,
        "phase":phase,
        "backupSha256":PREVIOUS,
    });
    match phase {
        "backup" => value["currentSha256"] = json!(PREVIOUS),
        "rollback" => {
            let maps = format!("/proc/4321/maps:7f000 {LOADER}\n");
            value["restoredSha256"] = json!(PREVIOUS);
            value["processIds"] = json!([4321]);
            value["mappedProcessIds"] = json!([4321]);
            value["mapsVerified"] = json!(true);
            value["mapsSha256"] = json!(sha256_hex(maps.as_bytes()));
            value["mapsByteCount"] = json!(maps.len());
            value["matchingMapLineCount"] = json!(1);
            value["loaderPathSha256"] = json!(sha256_hex(LOADER.as_bytes()));
        }
        _ => panic!("unknown native proof phase {phase}"),
    }
    value
}

fn phase(step: &str) -> &'static str {
    match step {
        "backup-current-version" => "backup",
        "rollback-native-library" => "rollback",
        _ => panic!("unknown native readback step {step}"),
    }
}

/// Exactly the two possible additional rows, their complete field sets and
/// every value, correlated to the unchanged successful fact-name rows.
pub fn timeline_proofs(timeline: &[Value]) -> Vec<(&'static str, Value)> {
    let mut proofs = Vec::new();
    for row in timeline {
        let text = row.as_str().expect("timeline text");
        if let Some(rest) = text.strip_prefix("native-readback ") {
            let (step, encoded) = rest.split_once(' ').expect("native proof row");
            let kind = phase(step);
            let value: Value = serde_json::from_str(encoded).expect("native proof JSON");
            assert_eq!(value, expected(kind), "every native readback field/value");
            assert!(
                !proofs.iter().any(|(seen, _)| *seen == kind),
                "duplicate proof"
            );
            proofs.push((kind, value));
        }
    }
    for (step, kind) in [
        ("backup-current-version", "backup"),
        ("rollback-native-library", "rollback"),
    ] {
        let verified = timeline
            .iter()
            .filter(|row| {
                row.as_str()
                    .unwrap()
                    .starts_with(&format!("verified {step} ["))
            })
            .count();
        assert_eq!(
            verified,
            proofs.iter().filter(|(seen, _)| *seen == kind).count()
        );
    }
    proofs
}

fn project(value: &mut Value) -> bool {
    let mut changed = false;
    if let Some(timeline) = value.get_mut("timeline") {
        let timeline = if timeline["kind"] == "inline" {
            timeline.get_mut("entries").and_then(Value::as_array_mut)
        } else {
            timeline.as_array_mut()
        };
        if let Some(timeline) = timeline {
            let proofs = timeline_proofs(timeline);
            if !proofs.is_empty() {
                timeline.retain(|row| !row.as_str().unwrap().starts_with("native-readback "));
                changed = true;
            }
        }
    }
    if value["kind"] == "stepOutcome"
        && matches!(
            value["stepId"].as_str(),
            Some("backup-current-version" | "rollback-native-library")
        )
        && value["payload"]["result"] == "succeeded"
    {
        let step = value["stepId"].as_str().unwrap();
        assert_eq!(value["eventId"], format!("outcome-{step}"));
        assert_eq!(
            value["payload"]["correlatesToIntentEventId"],
            format!("intent-{step}")
        );
        assert_eq!(value["payload"]["outcomeCertainty"], "confirmed");
        let encoded = value["payload"]["summary"]
            .as_str()
            .expect("durable native proof");
        let evidence: Value = serde_json::from_str(encoded).expect("durable native proof JSON");
        assert_eq!(evidence, expected(phase(step)), "whole durable proof");
        value["payload"].as_object_mut().unwrap().remove("summary");
        changed = true;
    }
    match value {
        Value::Array(values) => {
            for child in values {
                changed |= project(child);
            }
        }
        Value::Object(values) => {
            for child in values.values_mut() {
                changed |= project(child);
            }
        }
        _ => (),
    }
    changed
}

/// Projection is used only by deploy-native-library's historical replay,
/// after the exact above assertions. Every other field still compares byte
/// for byte, including original timeline rows, intents and failed outcomes.
pub fn historical_bytes(bytes: &[u8]) -> Vec<u8> {
    if let Ok(mut value) = serde_json::from_slice::<Value>(bytes) {
        if !project(&mut value) {
            return bytes.to_vec();
        }
        return if bytes.contains(&b'\n') {
            foundation_json::pretty(&value, true).unwrap()
        } else {
            serde_json::to_vec(&value).unwrap()
        };
    }
    let mut result = Vec::new();
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        let (content, newline) = if let Some(content) = line.strip_suffix(b"\n") {
            (content, true)
        } else {
            (line, false)
        };
        result.extend(historical_bytes_single_line(content));
        if newline {
            result.push(b'\n');
        }
    }
    result
}

/// Verify the complete current record against its actual SQLite digest before
/// hashing the strictly validated historical projection. No expected digest
/// is copied, and every other index field (including unchanged rows) survives.
pub fn historical_index(index: &Value, record: impl Fn(&str) -> Vec<u8>) -> Value {
    let mut result = index.clone();
    for row in result["rows"].as_array_mut().expect("complete index rows") {
        let job = row["jobId"].as_str().expect("index Job ID");
        let bytes = super::super::machine_independent(&record(job));
        let value: Value = serde_json::from_slice(&bytes).expect("complete current Job record");
        assert_eq!(value["jobID"], job, "index/record Job identity");
        assert_eq!(
            row["recordSHA256"],
            sha256_hex(&bytes),
            "actual index digest must prove the complete unprojected record"
        );
        let projected = historical_bytes(&bytes);
        if projected != bytes {
            assert_eq!(
                value["operationReference"], "deploy.native-library.app-owned@1",
                "only the native operation has this additive proof"
            );
            row["recordSHA256"] = json!(sha256_hex(&projected));
        }
    }
    result
}

fn historical_bytes_single_line(bytes: &[u8]) -> Vec<u8> {
    let Ok(mut value) = serde_json::from_slice::<Value>(bytes) else {
        return bytes.to_vec();
    };
    if project(&mut value) {
        serde_json::to_vec(&value).unwrap()
    } else {
        bytes.to_vec()
    }
}
