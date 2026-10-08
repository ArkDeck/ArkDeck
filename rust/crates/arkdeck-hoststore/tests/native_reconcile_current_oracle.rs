//! Published-c6 safety response to all original Native reconcile requests.
//! Software fixtures only; no device, child process or hardware evidence.
#![cfg(any(target_os = "macos", windows))]
mod support;

#[test]
fn all_published_native_reconcile_answers_and_owner_trees_match() {
    support::native_reconcile_current::assert_replays();
}

#[test]
fn the_complete_native_reconcile_projection_refuses_drift() {
    support::native_reconcile_current::assert_rejects_drift();
}

#[test]
#[ignore = "explicit CREATE_NEW software recording"]
fn record_published_native_reconcile_oracle() {
    let output = std::env::var_os("ARKDECK_RECORD_NATIVE_RECONCILE_ORACLE")
        .expect("explicit fresh output directory");
    support::native_reconcile_current::record(std::path::Path::new(&output));
}
