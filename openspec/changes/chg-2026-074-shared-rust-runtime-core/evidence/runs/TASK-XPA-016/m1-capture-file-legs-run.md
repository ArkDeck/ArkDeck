# TASK-XPA-016 — M1 run record: the capture file legs

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M1 (GJ-1), lane B's platform
executor: the legs of `capture.diagnostics@1` the Rust provider did not have — every file product
with its receive and cleanup, and the three stdout legs the default request leaves unselected —
ported from Swift's HDC provider as one additive module with T1 argv parity proved over the
shared fake HDC driver. Host measurement only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device, no HDC server, no daemon.

Base: protected main `847eefdb` (#1941). Branch `agent/xpa-016-capture-file-legs-20260914`; no
stacking. Files: `arkdeck-provider-hdc/src/capture_files.rs` (new), its export block in
`lib.rs`, `tests/capture_files.rs` (new), `serde_json` as a dependency of the crate (the same
line the status slice adds), this record, one README section. No `arkdeck-hoststore`,
`arkdeck-agentd`, `arkdeck-control`, Swift or contract change.

## Why this slice

r11's M1 row asks for `capture.diagnostics@1`'s "22 steps, all of them"; the delivered Rust
operation (#1938) materializes the storage preflight, `hilog -x` and the window inventory and
refuses the other legs at planning as not materialized. The M1 map (lane B, 2026-09-14) found
no `uitest`, `snapshot_display`, `hitrace`, `hidumper -s 1201`, `file recv` or `pidof` literal
anywhere under `rust/crates/`, and found the legs' Swift semantics pinned by
`ArtifactReceiveLegContractTests`, `ScreenshotEncodingContractTests`,
`DiagnosticsAndHAPContractTests` (liveness) and the lowering and verdicts in
`DeviceProviderAdapters.swift` (`:972-1240`, `:1886-2340`). Whether the fourteen unmaterialized
legs are M1 or M2 is ambiguous between `tasks.md` ("`capture.diagnostics@1`" in the M1 list) and
the runbook (§2 needs only HiLog and the UI dump) — a maintainer question recorded here; the
provider half is lane B's either way and blocks nothing.

## What Rust now has

`arkdeck_provider_hdc::FileAction` (`capture_files.rs`, 11 actions) with:

| Action | Swift argv (after `-t <key>`) | Budget | Verdict |
| --- | --- | --- | --- |
| `CaptureTrace` (blocking) | `shell hitrace -t <s> -b <kb> <categories…> -o <path>`; `shell ls -l <path>` | s+30 (continues past non-zero); 15 | the listing's size: `emptyTrace` at 0, unknown when not a regular file |
| `CaptureTrace` (ring) | `--trace_begin -b <kb> <categories…>`; [`echo <anchor> > /sys/kernel/tracing/trace_marker`; `grep -c <anchor> /sys/kernel/tracing/trace`]; `sleep <s>`; `--trace_dump -o <path>`; `--trace_finish_nodump`; `ls -l` | 30; 15; 15; s+30; 120 (continues); 30 (continues); 15 | 5 or 7 processes exactly; `ringHeldCoverageAnchor` from the count; `coverageAnchor` |
| `CaptureComponentTree` | `shell uitest dumpLayout -p <path>`; `ls -l` | 60 (continues); 15 | `emptyComponentTree` |
| `CaptureScreenshot` | `shell snapshot_display -t <png\|jpeg> -f <path>`; `ls -l` | 60 (continues); 15 | `emptyScreenshot` |
| `CaptureScreenSequence` | `mkdir -p <frames>`; per frame `snapshot_display -t <type> [-w W -h H] [-i id] -f <frames>/NNNN.<type>`; `tar -c -f <archive> -C <frames> .`; `ls -l <archive>` | 30; 60 each (continue); 120 (continues); 15 | `emptyScreenSequence`; captured frame count, per-frame durations (`%.3f`), frames per second (`%.2f`) |
| `CleanupScreenSequence` | `rm -f <frames…>`; `rm -f <archive>`; `rmdir <frames>`; `ls -ld <frames>` | 60; 30; 30; 15 (all continue) | `sequenceCleanupResidue` when listed; unknown unless exactly one listing line or the not-found grammar |
| `ReceiveOwnedArtifact` | `file recv <remote> <root>/<basename>` | 60 | the landed bytes: unknown when nothing landed, `emptyArtifact`, `oversizedArtifact` (never digested), `hashMismatch`, `unexpectedFormat`; `localArtifact`/`byteCount`/`sha256` |
| `CleanupOwnedRemotePath` | `shell rm -f <path>` | 15 | `cleanupDebt` on a non-zero exit |
| `CaptureCrashIndex` | `shell hidumper -s 1201 -a "-p Faultlogger -l"` | 30 | `entryCount` between the first and last `******`, `byteCount` |
| `CaptureCrashLog` | `shell hidumper -s 1201 -a "-p Faultlogger -f <name>"` | 30 | `faultLogNotFound` on `invalid parameters.`, unknown without the HiviewDFX header |
| `CaptureComponentDetail` | `shell hidumper -s WindowManagerService -a "-w <w> -element -lastpage <c>"` | 30 | as the window inventory |
| `ObserveApplicationLiveness` | `shell pidof <process>` | 30 | always verified: HEALTHY/RUNNING, UNHEALTHY/STOPPED, UNKNOWN (unavailable, truncated, ambiguous), bound to `applicationRef` and the deployed digest |

The request types carry Swift's bounds (`OwnedRemotePath`/`OwnedRemoteDirectory` components and
255-byte paths, `TraceRequest` 1–120 s / 1–24 identifier categories / 1024–65536 KiB / a
ring-only 14–64 character anchor derived as `ARKDECKANCHOR` + the last 40 alphanumerics of
job and step, `ScreenSequenceRequest` 2–300 frames / both or neither dimension / display 0–64,
`FaultLogName`, `LivenessRequest` with the bundle, ability and process identifier rules).
`for_step` is Swift's mapping from a catalog step and the request's inputs: the stdout actions
by their catalog action id, the file legs by step id, receive and cleanup re-minting the
producer's path (`file_producer_step_id`), the screenshot type reaching the path, the receive's
magic and the cleanup alike; `persisted` the journal forms (`hdc.captureTrace`,
`hdc.receiveOwnedArtifact` with `expectedLeadingBytes` as hex, …). `run` is Swift's dispatcher
rule for these plans over any `HdcDispatch`: a sequence stops at the first non-zero exit an
invocation does not continue past; a receive prepares its landing (owner-only directory, a
leftover from an earlier attempt removed) and inspects it afterwards whatever the exit.

## Measurement

`tests/capture_files.rs` runs the legs through `ProcessDispatch` over the shared fake HDC driver
(`/private/tmp/arkdeck-hdc-oracle`, under its lock) with this slice's own answers fragment: the
tree's two invocations read back from the driver's log argument for argument; the still, then
its receive landing a PNG-headed 22-byte payload the driver wrote to the host path from
`file recv`'s argv, verified with the digest of those bytes and the remote basename as
`localArtifact`, a JFIF pin on the same bytes `unexpectedFormat`, and in mode `nothing` the
stale landing cleared before the transfer and the outcome unknown; mode `missing` (the
not-found listing) unknown; mode `traceFails` (hitrace exits 1) still verified from the listing
with both invocations logged; a two-frame sequence verified with `capturedFrameCount` 2 and its
cleanup `cleaned`, mode `residue` `sequenceCleanupResidue`; the crash ledger's one entry; the
liveness readback HEALTHY with the observation time; the single-path cleanup.

```
cargo test -p arkdeck-provider-hdc --lib capture_files     14 passed
cargo test -p arkdeck-provider-hdc --test capture_files    1 passed
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings   clean
cargo fmt --all --check                                    clean
```

The fourteen unit tests port the Swift contract tests' cases: the owned path suffixes and
refusals, the request bounds, the step mapping naming one file across a product's legs, the
exact argv of every leg with its timeouts and continue flags, the trace judged by its listing
(not hitrace's exit), the ring's anchor from the readback it already has, the tree and still,
the sequence's gaps and its cleanup proof, the receive's every branch over real host files
(including a symlink and a directory at the destination, and an over-budget file never
digested), the crash ledger (a middle `******` separator is an entry, as Swift keeps it), the
liveness table, the persisted forms, and the runner's sequence and landing rules over a
scripted dispatch.

## Declared differences from Swift (T1/T2)

- `FileReceipt` carries every process that ran and the landed file; Swift's aggregate
  `stdout`/`stderr`/`durationSeconds` of a sequence are not reconstructed (no verdict reads
  them).
- Whitespace splitting uses Rust's Unicode `char::is_whitespace` where Swift uses
  `Character.isWhitespace`; newline splitting uses Swift's exact newline set.
- Error text: `FileActionError` spells Swift's `unsupportedAction(…)` and `HDCE0RequestError`
  messages; the daemon's refusal codes are the method owner's.

## What stays with other owners

- Wiring: `arkdeck-hoststore`'s `device_steps::action` (lane A) maps only `Action`; the file
  legs join the planner and runner there, with the Job's products (`trace.htrace`,
  `ui-tree.json`, `screenshot.png/.jpeg`, `crash-index.txt`, `crash-log.txt`,
  `advanced-dump.txt`, `application-liveness.json`) published by the store owner.
- The daemon-level T0 oracle for these legs (a `capture.diagnostics@1` request selecting them
  over the shared fake, recorded through `RuntimeControlPlaneHandler`) and its Rust replay, to be
  sequenced with the wiring; the argv parity here is T1 over the driver's log.
- Whether the unmaterialized legs are M1 or M2 (maintainer).
