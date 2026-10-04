//! GJ-1's device operations on Windows host code (TASK-XPA-005): the Swift
//! `observe.device@1` and `capture.diagnostics@1` oracles
//! (`rust/tests/fixtures/observe-device` and `capture-diagnostics`, produced
//! by `ObserveDeviceOracleContractTests` and
//! `CaptureDiagnosticsOracleContractTests`) replayed through the Rust
//! planner, admitter, runner, result reader and Artifact pager over the
//! shared fake HDC's answers ported in process (`oracle_fake.rs`), every
//! request in order, each run while the fake answers in the mode the oracle
//! names.
//!
//! Every answer's code, details and result must be Swift's (a refusal's
//! message is Swift's wording, T2, and is reported); the fake must receive
//! Swift's calls in order, `checkserver` among them, since a fake pinned to
//! no registered Windows tuple keeps Swift's lowering; and the Job index,
//! records, Journals, Artifacts and Sessions left must be Swift's byte for
//! byte, with the host paths spelled as the oracle recorded them, the
//! Session platform read as the oracle's and the values a manifest's length
//! derives relabelled one to one (`hdc_oracle::assert_read_only_replays`).
//! The macOS replays (`observe_device.rs`, `capture_diagnostics.rs`) run the
//! fake's driver as a subprocess and are unchanged.
#![cfg(windows)]

mod support;

use support::hdc_oracle;

#[test]
fn windows_observes_the_swift_fake_device() {
    hdc_oracle::assert_read_only_replays("observe-device", 28, 11);
}

#[test]
fn windows_captures_diagnostics_of_the_swift_fake_device() {
    hdc_oracle::assert_read_only_replays("capture-diagnostics", 28, 16);
}

/// The legs that only read the device (`capture-diagnostics-read-legs`):
/// the component detail, the Faultlogger index and one entry, the liveness
/// readback, succeeding, failing a leg, failing at publication, and parking
/// on an outcome nothing observes (a read past its budget, a read whose
/// process dies on a signal). Read-only: no mutation owner, a refusal's
/// wording T2.
#[test]
fn windows_captures_the_read_legs_of_the_swift_fake_device() {
    hdc_oracle::assert_read_only_replays("capture-diagnostics-read-legs", 66, 57);
}

/// The component tree and the screenshot (`capture-diagnostics-file-legs`),
/// each written to a provider-owned path, read back, received under the host
/// receive root and removed, under the durable mutation authority, with the
/// cleanup debts and the capability store; every answer Swift's, message
/// included.
#[test]
fn windows_captures_the_file_legs_of_the_swift_fake_device() {
    hdc_oracle::assert_authorized_replays("capture-diagnostics-file-legs", 77, 83);
}

/// The Trace legs (`capture-diagnostics-trace`), blocking and ring-buffered,
/// bracketed by the Trace Runtime probe's snapshots, under the mutation
/// authority; the probe's reads run concurrently, so each exchange's calls
/// are compared sorted.
#[test]
fn windows_captures_the_trace_legs_of_the_swift_fake_device() {
    hdc_oracle::assert_authorized_replays("capture-diagnostics-trace", 72, 300);
}
