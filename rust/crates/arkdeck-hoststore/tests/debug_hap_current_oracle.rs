//! Current-Catalog full software HAP oracle; no hardware acceptance.
#![cfg(any(target_os = "macos", windows))]
mod support;
use support::hdc_oracle::{self, hap_current};

#[test]
fn current_hap_preserves_every_exchange_call_and_complete_store() {
    hap_current::assert_source(&support::fixture(hap_current::NAME));
    hdc_oracle::assert_replays(hap_current::NAME, 63, 108);
}

#[test]
#[ignore = "explicit CREATE_NEW current-Catalog software recording"]
fn record_current_hap_oracle() {
    let output = std::env::var_os("ARKDECK_RECORD_HAP_CURRENT_ORACLE")
        .expect("explicit CREATE_NEW destination");
    hdc_oracle::record_hap_current(std::path::Path::new(&output));
}

#[test]
fn current_recipe_refuses_changed_request_order_or_dispatch() {
    let original = support::document(&support::fixture("debug-hap"), "cases.json");
    hap_current::validate_exchanges(&original, &original);
    for (a, b) in [(0, 1), (1, 2), (60, 61)] {
        let mut changed = original.clone();
        changed["exchanges"].as_array_mut().unwrap().swap(a, b);
        assert!(
            std::panic::catch_unwind(|| hap_current::validate_exchanges(&original, &changed))
                .is_err()
        );
    }
    let mut changed = original.clone();
    changed["exchanges"][0]["params"]["requestJson"] = serde_json::json!("{}");
    assert!(
        std::panic::catch_unwind(|| hap_current::validate_exchanges(&original, &changed)).is_err()
    );
    let calls =
        std::fs::read_to_string(support::fixture("debug-hap").join("hdc-invocations.log")).unwrap();
    let root = std::path::Path::new("/private/tmp/arkdeck-hdc-oracle");
    hap_current::assert_original_calls(&calls, root);
    assert!(
        std::panic::catch_unwind(|| hap_current::assert_original_calls(
            &calls.replacen("targets", "devices", 1),
            root
        ))
        .is_err()
    );
    let missing = calls.lines().skip(1).collect::<Vec<_>>().join("\n") + "\n";
    assert!(
        std::panic::catch_unwind(|| hap_current::assert_original_calls(&missing, root)).is_err()
    );
}
