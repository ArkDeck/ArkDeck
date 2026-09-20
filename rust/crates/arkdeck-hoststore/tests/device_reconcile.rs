//! Replays the Swift device reconcile oracle
//! (`rust/tests/fixtures/device-reconcile`, recorded by
//! `DeviceReconcileOracleContractTests.testSwiftRecoversAndReconcilesTheParkedDeviceJobs`)
//! through the Rust admitter, runner, recovery, reconciler and readers over
//! the shared fake HDC, composed as the standalone daemon composes them:
//! - three Jobs run: an `observe.device@1` that succeeds, one whose version
//!   probe answers nothing (parked, its host-only intent outstanding), and an
//!   `input.tap@1` the injector acknowledges as another gesture (parked, its
//!   mutation intent outstanding, its capability use `outcomeUnknown`);
//! - the daemon starts twice over the same root;
//! - `job.reconcile` five times: the parked observation is confirmed not
//!   executed from the Target's fresh facts and published, the tap stays
//!   unknown twice ("mutation has no dedicated readback"), and the finished
//!   Job and the failed one are answered as they are;
//! - a new tap is refused by the lineage its unknown use blocks;
//! - every Job read and the capability reads.
//!
//! Every answer, the store before the first start, after each start and
//! after each reconcile (Job index, Job files, capability store), and
//! everything the replay leaves must be Swift's byte for byte, once each Job
//! record's volume, device, inode and claim generation are read as labels.
//! No start and no reconcile dispatches: the fake's log does not grow. The
//! runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use support::debug_hap;
use support::reconcile::Daemon;

#[test]
fn rust_recovers_and_reconciles_the_swift_device_jobs() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open("device-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    let exchanges = cases["exchanges"].as_array().unwrap();
    let (runs, rest) = exchanges.split_at(
        exchanges
            .iter()
            .position(|exchange| exchange["method"] == "job.reconcile")
            .unwrap(),
    );
    let mut differences = Vec::new();
    let mut compare = |exchange: &serde_json::Value, actual: serde_json::Value| {
        if actual != exchange["answer"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                exchange["name"], exchange["answer"]
            ));
        }
    };

    // The three Jobs are admitted and run; then the store Swift recorded.
    assert_eq!(runs.len(), 6);
    for exchange in runs {
        compare(exchange, daemon.answer(&daemon.dispatch, exchange));
    }
    let before = daemon.calls();
    assert_eq!(
        before.len() as u64,
        cases["invocationsBeforeRestart"].as_u64().unwrap()
    );
    daemon.assert_snapshot("before");

    // The daemon starts again over the same root, and then once more.
    for start in cases["starts"].as_array().unwrap() {
        let recovered = daemon.restart();
        assert!(recovered.quarantined.is_empty() && recovered.refused.is_empty());
        assert_eq!(
            serde_json::json!(recovered.statuses),
            start["recovered"],
            "{}",
            start["name"]
        );
        daemon.assert_snapshot(start["name"].as_str().unwrap());
    }
    assert_eq!(daemon.calls(), before, "a start dispatched");

    // Every reconcile, each followed by the store it leaves; none dispatches.
    let reconciles: Vec<_> = rest
        .iter()
        .take_while(|exchange| exchange["method"] == "job.reconcile")
        .collect();
    assert_eq!(reconciles.len(), 5);
    for exchange in &reconciles {
        compare(exchange, daemon.answer(&daemon.dispatch, exchange));
        daemon.assert_snapshot(&format!("steps/{}", exchange["name"].as_str().unwrap()));
    }
    assert_eq!(daemon.calls(), before, "a reconcile dispatched");

    // The new tap, every read and the capability reads.
    for exchange in &rest[reconciles.len()..] {
        compare(exchange, daemon.answer(&daemon.dispatch, exchange));
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(daemon.calls(), before, "a read dispatched");
    daemon.assert_leftovers();
}
