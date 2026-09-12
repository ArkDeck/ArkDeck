use arkdeck_contract::{
    ImportIntent, ImportProjection, decode_import_chunk, encode_import_chunk, import_timestamp,
};
use serde_json::{Value, json};
fn corpus(method: &str) -> Vec<Value> {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames");
    std::fs::read_to_string(root.join(format!("artifact.import.{method}.jsonl")))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
#[test]
fn actual_swift_upload_and_terminal_projections_keep_exact_metadata_identity() {
    let mut count = 0;
    for method in ["begin", "append", "inspect", "commit", "abort", "release"] {
        for row in corpus(method) {
            if row["ok"] != true || row["result"]["schemaVersion"] != "arkdeck.import/1" {
                continue;
            }
            let value = &row["result"];
            let projection = ImportProjection::parse(value).unwrap();
            count += 1;
            assert_eq!(projection.intent.projection(), value["metadata"]);
            let durable = serde_json::to_vec(&projection.intent).unwrap();
            let decoded: ImportIntent = serde_json::from_slice(&durable).unwrap();
            assert_eq!(decoded, projection.intent);
            for (key, changed) in [
                ("importId", json!("imp-NOT-AN-ID")),
                ("importRequestId", json!("foreign-request")),
                ("metadataFingerprint", json!("a".repeat(64))),
                ("generation", json!("01")),
                ("generation", json!("9223372036854775808")),
                ("nextOffset", json!("8589934593")),
                ("maximumChunkBytes", json!("2097153")),
                ("state", json!("ready")),
                ("createdAtUtc", json!("2026-02-30T00:00:00Z")),
                ("extra", json!(false)),
            ] {
                let mut bad = value.clone();
                bad[key] = changed;
                assert!(ImportProjection::parse(&bad).is_err(), "{method} {key}");
            }
            let mut bad = value.clone();
            bad["metadata"]["targetId"] = json!("foreign-target");
            assert!(ImportProjection::parse(&bad).is_err());
        }
    }
    assert!(count >= 5, "missing actual Swift producer coverage");
}
#[test]
fn closed_intent_counts_and_registered_kind_bounds_are_preserved() {
    let seed = corpus("begin")
        .into_iter()
        .find(|v| v["ok"] == true)
        .unwrap()["result"]["metadata"]
        .clone();
    for (key, changed) in [
        ("byteCount", json!(1)),
        ("byteCount", json!("01")),
        ("byteCount", json!("0")),
        ("bindingRevision", json!("0")),
        ("bindingRevision", json!("9223372036854775808")),
        ("kind", json!("arbitrary")),
        ("importRequestId", json!("../escape")),
        ("name", json!("../file.hap")),
        ("sha256", json!("A".repeat(64))),
        ("extra", json!(false)),
    ] {
        let mut bad = seed.clone();
        bad[key] = changed;
        assert!(
            ImportIntent::from_wire(bad.as_object().unwrap()).is_err(),
            "{key}"
        );
    }
    let mut flash = seed;
    flash["kind"] = json!("flash-bundle");
    flash["name"] = json!("images.tar.gz");
    flash["deviceProfile"] = json!("dayu200");
    flash["byteCount"] = json!("8589934592");
    assert!(ImportIntent::from_wire(flash.as_object().unwrap()).is_ok());
    flash["byteCount"] = json!("8589934593");
    assert!(ImportIntent::from_wire(flash.as_object().unwrap()).is_err());
}
#[test]
fn canonical_bounded_chunk_encoding_rejects_padding_and_length_ambiguity() {
    for bytes in [
        b"f".as_slice(),
        b"fo",
        b"foo",
        b"a\0b",
        &[255u8; 65539],
        &[0u8; 2 * 1024 * 1024],
    ] {
        let encoded = encode_import_chunk(bytes).unwrap();
        assert_eq!(
            decode_import_chunk(&encoded, bytes.len() as u64).unwrap(),
            bytes
        );
    }
    for (encoded, count) in [
        ("Zh==", 1),
        ("Zm9=", 2),
        ("Zg==Zg==", 2),
        ("Zg=", 1),
        ("Zg==\n", 1),
        ("", 0),
        ("Zg==", 2_097_153),
    ] {
        assert!(decode_import_chunk(encoded, count).is_err());
    }
    assert!(encode_import_chunk(&[]).is_err());
}
#[test]
fn import_timestamps_compare_instants_and_refuse_ambiguous_timezones() {
    assert_eq!(
        import_timestamp("2026-09-12T08:00:00+08:00"),
        import_timestamp("2026-09-12T00:00:00Z")
    );
    assert!(import_timestamp("2024-02-29T00:00:00.1Z").is_some());
    for invalid in [
        "2023-02-29T00:00:00Z",
        "2026-01-01T00:00:00--1:00",
        "2026-01-01T00:00:00+-0:00",
        "2026-01-01T00:00:00+00:-1",
        "2026-01-01T00:00:00.Z",
    ] {
        assert!(import_timestamp(invalid).is_none(), "{invalid}");
    }
}

#[test]
fn actual_swift_reference_inspections_preserve_unknown_outcome_blockers() {
    let mut count = 0;
    for row in corpus("inspection") {
        if row["ok"] != true { continue; }
        let value = row["result"].clone();
        let imported = arkdeck_contract::validate_import_inspection(&value).unwrap();
        assert_eq!(imported.value, value["import"]);
        count += 1;
        for replacement in [
            json!({"state":"clear","activeJobIds":[],"outcomeUnknownJobIds":["job-unknown"],"activeMaterializationCount":"0"}),
            json!({"state":"referenced","activeJobIds":["job-z","job-a"],"outcomeUnknownJobIds":[],"activeMaterializationCount":"0"}),
            json!({"state":"referenced","activeJobIds":["job-a","job-a"],"outcomeUnknownJobIds":[],"activeMaterializationCount":"0"}),
            json!({"state":"clear","activeJobIds":[],"outcomeUnknownJobIds":[],"activeMaterializationCount":"1"}),
            json!({"state":"referenced","activeJobIds":[],"outcomeUnknownJobIds":[],"activeMaterializationCount":"1025"}),
        ] {
            let mut bad = value.clone(); bad["references"] = replacement;
            assert!(arkdeck_contract::validate_import_inspection(&bad).is_err());
        }
    }
    assert!(count > 0);
}
