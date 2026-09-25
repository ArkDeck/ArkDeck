//! The machine-contract products this CLI owns (Swift `CLIMachineContracts`),
//! held byte for byte to the committed bundle.
//!
//! The committed bundle lives outside `rust/` (`openspec/contracts/` and the
//! contract tests' `Fixtures/CLI/`), where the contract views do not reach,
//! so each owned product's SHA-256 is kept in
//! `rust/tests/fixtures/contracts-bundle/owned.json`, and
//! `rust/scripts/check-contracts.py` holds that table to the committed files.
use arkdeck_cli::machine_contracts::{contract_products, fixture_products, json_document};
use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn owned() -> BTreeMap<String, String> {
    serde_json::from_str(include_str!(
        "../../../tests/fixtures/contracts-bundle/owned.json"
    ))
    .unwrap()
}

#[test]
fn every_owned_product_is_the_published_bytes() {
    let mut produced = BTreeMap::new();
    for product in contract_products() {
        produced.insert(
            format!("contracts/{}", product.relative_path),
            product.bytes,
        );
    }
    for product in fixture_products() {
        produced.insert(format!("fixtures/{}", product.relative_path), product.bytes);
    }
    let owned = owned();
    assert_eq!(
        produced.keys().collect::<Vec<_>>(),
        owned.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in &produced {
        assert_eq!(
            &sha256_hex(bytes),
            &owned[path],
            "{path} as rendered:\n{}",
            String::from_utf8_lossy(bytes)
        );
    }
    // The page and next-action schemas and their eight samples: 10 of the
    // bundle's 235 products.
    assert_eq!(produced.len(), 10);
}

#[test]
fn fixtures_are_listed_in_path_order() {
    let paths: Vec<String> = fixture_products()
        .into_iter()
        .map(|product| product.relative_path)
        .collect();
    let mut sorted = paths.clone();
    sorted.sort();
    assert_eq!(paths, sorted);
}

/// Swift `ContractJSON`: keys in UTF-16 code-unit order, two-space
/// indentation, canonical scalars, empty containers inline, one LF.
#[test]
fn the_renderer_writes_swifts_contract_json() {
    assert_eq!(json_document(&json!({})), b"{}\n");
    assert_eq!(json_document(&json!([])), b"[]\n");
    assert_eq!(json_document(&Value::Null), b"null\n");
    // "\u{1F600}" is a surrogate pair (0xD83D …), so it sorts before
    // "\u{FF21}" in UTF-16, though its UTF-8 bytes sort after.
    let value = json!({
        "b": [1, {"a": []}, 0.5, false],
        "a": {"z": "é/\"\u{1}", "\u{FF21}": 1, "\u{1F600}": {}},
    });
    assert_eq!(
        String::from_utf8(json_document(&value)).unwrap(),
        "{\n  \"a\": {\n    \"z\": \"é/\\\"\\u0001\",\n    \"\u{1F600}\": {},\n    \"\u{FF21}\": 1\n  },\n  \"b\": [\n    1,\n    {\n      \"a\": []\n    },\n    0.5,\n    false\n  ]\n}\n"
    );
}
