//! Replays every `job.plan` of the Swift native-library oracle
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC) through the
//! Rust planner, over the fixed root holding the library the oracle published
//! before any request, with the code-sign helper composed as the oracle
//! composed it:
//! - each of the five plans digests every step of the deployment, each
//!   provider step lowered to its exact process sequence with Swift's journal
//!   arguments, and the rollback a failure past the publish would apply. A
//!   plan digests the library's and the helper's host paths, which is why the
//!   fixed root is used;
//! - the four refusals are Swift's: a stale binding, an unknown lease, a
//!   library of another ABI and a logical name outside the catalog's pattern.
//!
//! Every answer must be Swift's, digest and message included, and nothing may
//! be admitted or dispatched. A composition without a verified helper cannot
//! plan a deployment at all. Fixture data is isolated host evidence, never a
//! device acceptance result.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::AdmissionRefusal;
use std::fs;
use support::debug_hap::{self, NoDispatch};
use support::hdc_oracle::{Owners, exchange};
use support::native_library::{self, FIXTURE, answer};

#[test]
fn rust_plans_the_swift_native_library_requests() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(FIXTURE);
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&NoDispatch);
    let (mut plans, mut materialized, mut differences) = (0, 0, Vec::new());
    for exchange in cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|exchange| exchange["method"] == "job.plan")
    {
        plans += 1;
        let actual = answer(
            owners
                .planner(&hdc)
                .handle(exchange["params"].as_object().unwrap())
                .map_err(AdmissionRefusal::from),
        );
        if actual["ok"] == true {
            materialized += 1;
        }
        if actual != exchange["answer"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                exchange["name"], exchange["answer"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!((plans, materialized), (9, 5), "five plans, four refusals");
    // A plan admits no Job and dispatches nothing.
    let jobs = owners.default_root.join("jobs");
    assert!(
        !jobs.exists() || fs::read_dir(&jobs).unwrap().next().is_none(),
        "planning admits nothing"
    );
    assert!(
        debug_hap::invocations(&owners.root).is_empty(),
        "planning dispatches nothing"
    );
}

/// A composition without a verified code-sign helper cannot deploy a native
/// library, as Swift's provider without one cannot: the operation is runtime
/// unavailable before any fact is read, with the zero-dispatch proof. The
/// reason is Swift's words, which are not pinned here.
#[test]
fn rust_refuses_a_native_deployment_without_a_verified_code_sign_helper() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(FIXTURE);
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let mut hdc = owners.hdc(&NoDispatch);
    hdc.code_sign_helper = None;
    let planned = exchange(&cases, "deployed.plan");
    let refusal = owners
        .planner(&hdc)
        .handle(planned["params"].as_object().unwrap())
        .unwrap_err();
    assert_eq!(refusal.code, "invalidInput");
    assert!(
        refusal
            .message
            .starts_with("deploy.native-library.app-owned@1 is runtime unavailable: "),
        "{}",
        refusal.message
    );
    // The same refusal answers a submission, before anything is admitted.
    let submitted = exchange(&cases, "deployed.submit");
    let denied = owners
        .admitter(&hdc, &owners.default_root)
        .handle(submitted["params"].as_object().unwrap())
        .unwrap_err();
    assert_eq!(
        native_library::answer(Err(denied))["error"]["details"],
        native_library::proof()
    );
    assert!(debug_hap::invocations(&owners.root).is_empty());
}
