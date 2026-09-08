use std::fmt::Write;
use std::fs;

use arkdeck_contract::{
    CATALOG_CANONICAL_JSON, CATALOG_DIGEST, CONTRACT_INPUTS, sha256_hex, strict_json,
};
use serde_json::Value;

#[path = "common/mod.rs"]
mod common;

#[test]
fn all_current_operations_reproduce_the_input_catalog_digest() {
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    assert_eq!(inputs["catalogDigest"], CATALOG_DIGEST);
    assert_eq!(
        sha256_hex(CATALOG_CANONICAL_JSON.as_bytes()),
        CATALOG_DIGEST
    );
    let mut operations = fs::read_dir(common::repo_root().join("Catalog/operations"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .map(|path| strict_json(&fs::read(path).unwrap()).unwrap())
        .collect::<Vec<_>>();
    operations.sort_by(|a, b| {
        (
            a["id"].as_str().unwrap(),
            a["version"].as_u64().unwrap_or(0),
        )
            .cmp(&(
                b["id"].as_str().unwrap(),
                b["version"].as_u64().unwrap_or(0),
            ))
    });
    let expected_count = inputs["files"]
        .as_object()
        .unwrap()
        .keys()
        .filter(|path| path.starts_with("Catalog/operations/") && path.ends_with(".json"))
        .count();
    assert!(expected_count > 0);
    assert_eq!(operations.len(), expected_count);
    let value = Value::Array(operations);
    assert_eq!(
        strict_json(CATALOG_CANONICAL_JSON.as_bytes()).unwrap(),
        value
    );
    // Catalog has its own frozen ensure_ascii=True/sorted-key serialization,
    // not the CLI canonical JSON's literal-Unicode encoding. Exercise its
    // existing non-ASCII descriptions rather than assuming those bytes agree.
    let json = serde_json::to_string(&value).unwrap();
    assert!(!json.is_ascii());
    let mut canonical = String::new();
    for character in json.chars() {
        if character < '\u{7f}' {
            canonical.push(character);
        } else {
            for unit in character.encode_utf16(&mut [0; 2]) {
                write!(canonical, "\\u{unit:04x}").unwrap();
            }
        }
    }
    assert_eq!(canonical, CATALOG_CANONICAL_JSON);
    assert_eq!(sha256_hex(canonical.as_bytes()), CATALOG_DIGEST);
    let matrix = fs::read_to_string(
        common::repo_root().join("Catalog/generated/effect-authorization-matrix.md"),
    )
    .unwrap();
    assert!(matrix.contains(&format!("Catalog digest: `{CATALOG_DIGEST}`")));
    let registry = common::load_json("Packages/ArkDeckKit/Contracts/control-protocol.json");
    assert_eq!(registry["currentVersion"], inputs["protocolVersion"]);
}
