//! The machine-contract products this CLI owns (Swift `CLIMachineContracts`),
//! held byte for byte to the committed bundle.
//!
//! The committed bundle lives outside `rust/` (`openspec/contracts/` and the
//! contract tests' `Fixtures/CLI/`), where the contract views do not reach,
//! so each owned product's SHA-256 is kept in
//! `rust/tests/fixtures/contracts-bundle/owned.json`, and
//! `rust/scripts/check-contracts.py` holds that table to the committed files.
use arkdeck_cli::CliError;
use arkdeck_cli::error_registry::{self, CODES, ExitCategory};
use arkdeck_cli::machine_contracts::{
    CANONICAL_REJECTIONS, contract_products, fixture_products, json_document, yaml_document,
};
use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The products built from the compiled contract: the command registry
/// carries the Catalog's digest, the result schema the protocol version, and
/// the control-plane schema the contract identity and the method set. A contract-input change regenerates them, so a fixed
/// digest cannot hold them. Instead they are compared with the committed
/// files, wherever a checkout has them. The contract views carry only `rust/`
/// and the contract inputs, never `openspec/contracts`, so there the
/// comparison is skipped by design.
const FROM_THE_CONTRACT: [&str; 3] = [
    "contracts/cli-command-registry.yaml",
    "contracts/cli-result.schema.json",
    "contracts/runtime-control-plane.schema.json",
];

/// The committed bundle's `openspec/contracts`, in a checkout.
fn committed_contracts() -> Option<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../openspec/contracts");
    root.is_dir().then_some(root)
}

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
    let mut accounted: Vec<&str> = owned
        .keys()
        .map(String::as_str)
        .chain(FROM_THE_CONTRACT)
        .collect();
    accounted.sort_unstable();
    assert_eq!(
        produced.keys().map(String::as_str).collect::<Vec<_>>(),
        accounted
    );
    let committed = committed_contracts();
    for (path, bytes) in &produced {
        if let Some(digest) = owned.get(path) {
            assert_eq!(
                &sha256_hex(bytes),
                digest,
                "{path} as rendered:\n{}",
                String::from_utf8_lossy(bytes)
            );
        } else if let Some(root) = &committed {
            let file = root.join(path.trim_start_matches("contracts/"));
            let published =
                std::fs::read(&file).unwrap_or_else(|error| panic!("{}: {error}", file.display()));
            assert!(
                published == *bytes,
                "{path} as rendered:\n{}",
                String::from_utf8_lossy(bytes)
            );
        }
    }
    // The command and error registries, the canonical vectors, the result,
    // page, event, next-action and control-plane schemas, the eight samples
    // and the seven envelopes: 23 of the bundle's 235 products.
    assert_eq!(produced.len(), 23);
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

/// Swift `ContractYAML`: the generated notice, then block mappings and
/// sequences of JSON scalars, empty containers inline, a nested mapping's
/// first key on its dash's line.
#[test]
fn the_yaml_renderer_writes_swifts_contract_yaml() {
    let value = json!({
        "b": [1, {"y": [], "x": "é/\""}, [true]],
        "a": {},
        "\u{FF21}": null,
    });
    assert_eq!(
        String::from_utf8(yaml_document(&value)).unwrap(),
        "# Generated by `arkdeck maintainer contracts export`; do not edit by hand.\n\
         \"a\": {}\n\
         \"b\":\n\
         \x20 - 1\n\
         \x20 - \"x\": \"é/\\\"\"\n\
         \x20   \"y\": []\n\
         \x20 - - true\n\
         \"\u{FF21}\": null\n"
    );
}

/// The published refusals are this build's too: its encoder refuses the two
/// integers beyond the exact range, and a non-finite number cannot even be
/// held in a JSON value.
#[test]
fn canonical_rejections_are_this_builds() {
    let names: Vec<&str> = CANONICAL_REJECTIONS.iter().map(|(name, _)| *name).collect();
    assert_eq!(
        names,
        [
            "positiveInfinity",
            "negativeInfinity",
            "nan",
            "integerBeyondExactRange",
            "unsignedIntegerBeyondExactRange",
        ]
    );
    for value in [json!(i64::MAX), json!(u64::MAX)] {
        assert!(arkdeck_contract::canonical_json(&value).is_err(), "{value}");
    }
    for number in [f64::INFINITY, f64::NEG_INFINITY, f64::NAN] {
        assert!(serde_json::Number::from_f64(number).is_none());
    }
}

/// Swift `CLIErrorCode`: 45 distinct codes in 11 of the 12 categories (none
/// is `ok`), each exiting as its category does, as `CliError` exits and as
/// the failure envelope reports it.
#[test]
fn every_code_exits_and_reports_as_its_registry_entry_says() {
    let mut names: Vec<&str> = CODES.iter().map(|(code, _)| *code).collect();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), 45);
    let exits: Vec<u8> = ExitCategory::ALL
        .iter()
        .map(|category| category.exit_code())
        .collect();
    assert_eq!(exits, [0, 1, 2, 4, 64, 65, 69, 70, 74, 75, 77, 130]);
    for (code, category) in CODES {
        let error = CliError::new(code, "registry");
        assert_eq!(error.exit_code(), category.exit_code(), "{code}");
        let envelope = arkdeck_cli::failure_envelope("job.status", &error, "ctl-registry", true);
        assert_eq!(
            envelope["error"]["controlRequestRetryable"],
            error_registry::control_request_retryable(code),
            "{code}"
        );
        assert_eq!(
            envelope["error"]["attentionRequired"],
            matches!(category.exit_code(), 2 | 75 | 77),
            "{code}"
        );
    }
    // Swift puts it in `unavailable` (69); this CLI exited 70 before.
    assert_eq!(
        CliError::new("blockedByProductDefect", "blocked").exit_code(),
        69
    );
    let retryable: Vec<&str> = CODES
        .iter()
        .map(|(code, _)| *code)
        .filter(|code| error_registry::control_request_retryable(code))
        .collect();
    assert_eq!(
        retryable,
        ["runtimeUnavailable", "resultNotReady", "clientTimeout"]
    );
    // A code the registry does not have is an internal failure.
    assert_eq!(CliError::new("notARegistryCode", "unknown").exit_code(), 70);
}
