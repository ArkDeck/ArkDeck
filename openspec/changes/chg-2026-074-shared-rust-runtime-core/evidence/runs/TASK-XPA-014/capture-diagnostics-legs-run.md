# TASK-XPA-014 — every leg of `capture.diagnostics@1` on the Rust owner, replaying three Swift oracles (M1, macOS, 2026-09-24)

TASK-XPA-014 remains in progress. Base: protected main `bfe959c74` (#2133, the Rust `trace.probe`
this slice's Trace legs are bracketed by). The first part was written on `f06f83d05` (#2132) and
rebased onto `bfe959c74` without conflict. Every answer and file compared here is replayed from
Swift oracles recorded over the shared fake HDC in a fixed-root host fixture. None of it is device
evidence, installed-Runtime activation or GJ acceptance (POL-VERIFY-001, POL-MODE-001).

## What a user sees

Before this slice the Rust owner ran only the legs Swift's default request selects (host and device
storage, the evidence preflight, the HiLog drain, the window inventory) and refused every other leg
of `capture.diagnostics@1` at planning as not materialized; #2113 had reached the tree and the
screenshot for the App's UIDump Job without a Swift oracle. Now every leg the Catalog declares
plans, admits, runs, publishes and reads back as Swift's engine does:

- the component detail dump (`advancedDump` with `windowId` and `componentId`), the Faultlogger
  index (`crashLogs`) and one entry of it (`crashLogName`), and the application liveness readback
  (`bundleName`, with its ability, process and deployed digest) with its derived
  `application-liveness.json`;
- the component tree and the screenshot (PNG or JPEG): capture, readback, receive, cleanup;
- the Trace legs (`traceCategories`): a blocking `hitrace -t`, or with `ringBuffered` an armed ring
  with its coverage anchor, each received and cleaned up, the whole step loop bracketed by two
  Trace Runtime snapshots, as Swift's `executeStepsWithTraceEvidence` brackets it;
- `markers.json`'s manual marks, `crashLogCaptured` and `stepFailed` marks and a ring's coverage
  record; `artifact-index.json` and `capture-summary.json`'s Trace section;
- `job.evidence`, `job.result` and `job.show` of those Jobs, the Trace snapshots and ring coverage
  included.

## Swift semantics, by leg (the oracles)

- **Component detail** (`hidumper -s WindowManagerService -a "-w <w> -element -lastpage <c>"`, 30 s):
  bytes that are not UTF-8 or past the 8 MiB a read keeps fail the leg; an empty answer is an
  unknown outcome; the exit status is the client's and decides nothing. Planning refuses it without
  its identifiers (`componentDetail requires typed windowId and componentId inputs`) and the catalog
  a window that is not decimal.
- **Crash index** (`hidumper -s 1201 -a "-p Faultlogger -l"`, 30 s): entries between the first and
  last `******`; an empty ledger is a truthful answer (published, `entryCount` 0, whatever the
  exit); a ledger past 8 MiB fails the leg; one inside that bound but past the request's own
  `totalArtifactByteBudget` fails the Job at publication (`artifactPublicationFailed`).
- **Crash log** (`-p Faultlogger -f <name>`, 30 s): `invalid parameters.` is `faultLogNotFound`
  (the leg fails, the Job goes on); an answer without the HiviewDFX header is unknown and parks the
  Job; a published entry adds `crashLogCaptured` to `markers.json`. The catalog refuses a path as an
  entry name.
- **Liveness** (`pidof <process>`, 30 s): always verified — HEALTHY/RUNNING, UNHEALTHY/STOPPED on
  no process, UNKNOWN for an answer that is not only process IDs (`processReadbackAmbiguous`) or an
  unreadable one (`processReadbackUnavailable`); a process that dies on a signal is unknown and
  parks. The derived document binds the application reference, the Job, the operation, the
  expected binding revision and the caller's deployed digest over the one observation instant.
- **Tree and screenshot** (`uitest dumpLayout -p` / `snapshot_display -t <type> -f`, then `ls -l`,
  `file recv`, `rm -f`): `deviceMutation`, admitted under a capability the Runtime issues by its
  default policy and consumes before the first write; a screenshot-only request is scoped to the
  control session, and a second one carries the session's model and firmware readback. A
  zero-byte file fails its capture (receive and cleanup skipped as upstream of a failure); a still
  that is not the magic of its type, or an empty landing, fails the receive (the landing stays, the
  cleanup still runs); a refused cleanup owes a cleanup debt (`cleanupDebt.list`, the record's
  `outstandingResidueCount`); a file the readback cannot find, a receive that lands nothing and a
  cleanup past its 15 s budget park the Job, and an unknown outcome blocks that Target's automatic
  capability lineage (the next mutation request is `admissionDenied`).
- **Trace**: before any step, a snapshot of the trace tool and its nine parameters over the
  Target's route must name the request's Target and binding, a capture-eligible `hitrace` offering
  every requested tag and the whole parameter catalog; otherwise the Job fails (`Trace probe facts
  do not match target, binding, adapter, tags, or parameter catalog`, or `Trace before snapshot
  failed: <probe error>`). A blocking capture is judged by its `ls -l`; a ring (begin, anchor into
  `trace_marker`, `grep -c` of the ring, the window, `--trace_dump`, `--trace_finish_nodump`,
  readback) also by whether the ring held its anchor, which the record keeps as `ringCoverage` and
  `markers.json` reports (`notEstablished` when nothing reported). Once the steps end a second
  snapshot is taken: one that cannot be fails a Job whose steps succeeded (`Trace after snapshot
  failed: …`, after the products were published), and beside a step's own failure it is taken all
  the same (a parked Job keeps both snapshots). The summary and index report the tool, family,
  tags, window, buffer, the published trace and each parameter's wanted value against what the two
  snapshots read.

## Oracles (Swift-only commit)

Three new classes over `HDCOracleFake`, each recorded once and compared byte for byte twice more:

| Class | Fixture | Jobs / exchanges / files | Composition |
| --- | --- | --- | --- |
| `CaptureDiagnosticsReadLegsOracleContractTests` | `rust/tests/fixtures/capture-diagnostics-read-legs/` | 10 / 66 / 194; 57 calls | default read-only policy, no receive root |
| `CaptureDiagnosticsFileLegsOracleContractTests` | `rust/tests/fixtures/capture-diagnostics-file-legs/` | 11 / 77 / 166; 83 calls | receive root under the fixed root; four adopted devices, since an unknown outcome blocks its Target's lineage |
| `CaptureDiagnosticsTraceOracleContractTests` | `rust/tests/fixtures/capture-diagnostics-trace/` | 10 / 72 / 248; 300 calls | the engine given the production `FoundationTraceRuntimeProbe`, as the daemon gives it; the registered trace-probe resources under `resources/`; two devices |

The Trace probe's reads run concurrently, so that oracle records each exchange's calls sorted in
`hdc-calls.log` (the answers' one-append log) instead of the driver's interleaved log; a Job's step
order is its journal's and timeline's. The file-leg and Trace fakes write under umask 077, so the
landing a failed receive leaves has one mode whatever umask the caller runs under (the SwiftPM
runner sets 077, a Rust test process 022). `HDCOracleHarness` gives the engine the Trace probe it
composes (no other oracle composes one with Jobs) and can record canonical calls and resources.

**Schemas.** The published `job.evidence` and `job.result` schemas pinned `traceProbeBefore` and
`traceProbeAfter` to null and `job.show` pinned `ringCoverage` to null, so the Rust control layer
would have answered `internalError` for every Trace Job. They were re-derived from the committed
corpus plus the frames of two Trace Jobs only (a ring whose readback does not hold its anchor and
whose snapshots read an unreadable parameter; a second snapshot that could not be taken), and no
other method was derived. Each widens to `null | object` with the producer's shape (parameters'
`value` and `detail` `null | string`); `request`, `errorCode` and `errorDetails` are unchanged.
Every committed corpus line is kept (21→23, 29→31, 23→24; `job.result` stays under the 32-shape
cap, which the full set of ten Trace frames would have exceeded, dropping a committed
`resultNotReady` shape). All 243 frames the four capture oracles record validate against the new
schemas in `ControlMethodSchemaContractTests`, and every exchange of the three new fixtures, the
default capture and the screen sequence validates with jsonschema 4.26. `swift-single-v1.json`
was regenerated (952 recorded shapes, 947 before; contract identity unchanged). The read and file
legs needed no schema change.

## Rust

- `arkdeck-provider-hdc` `capture_files.rs`: `FileAction::lower_in` takes an optional host receive
  root, needed only by a receive (`receives()`); `lower` is unchanged.
- `device_steps.rs`: `file_journal_arguments` follows Swift's `journalStep(for:)` for every
  `FileAction` — the stdout legs name the catalog's own action; the liveness readback journals
  `{probeId: process-state, expectedState: running}` (it had none, so a liveness plan failed
  internally); every receive but the tree's, a still's or a sequence's lands `trace.htrace` (the
  trace receive is `receive-trace-artifact`, which the old table missed). `cleanup_residue` owes a
  capture's refused cleanup as a remote-path debt, as Swift's `cleanupResidue` does. A plan lowers
  a file leg without a receive root unless it receives.
- `job_plan.rs` / `screen_sequence_plan.rs`: every `capture.diagnostics@1` request goes through the
  file-capture materialization; a composition without a receive root plans the read legs and
  refuses only a selected receive; the ring-buffered refusal is gone; a provider refusal is
  interpolated as Swift's `DeviceProviderError` describes itself (its detail alone).
- `device_run.rs`: `application-liveness.json` is Swift's liveness document, not a facts product;
  a verified ring summary sets the record's `ringCoverage`; the step loop runs inside
  `device_trace.rs`'s `traced_steps`, Swift's `executeStepsWithTraceEvidence` over the provider's
  `trace_probe` (#2133): the before snapshot validated and kept (Swift's `Codable` form, `rawHelp`
  included) and persisted before any step, the after snapshot kept or its failure handled per
  Swift's three lanes (success, cancellation, a step's own failure).
- `capture_documents.rs`: the markers' coverage record and the index's and summary's Trace section
  (the catalog's desired values, `traceParameterJSON`, the published trace's identity).
- `job_record.rs` / `job_result.rs`: `job.evidence` and `job.result` project the snapshots as
  Swift's `encodeTraceRuntimeProbe` does, and a Job carrying them is read instead of refused.
- `tests/capture_diagnostics.rs`: one replay per oracle (the default one unchanged in substance, the
  read legs over a composition with no receive root, the file and Trace legs under the durable
  mutation authority with the oracle's receive root, comparing each exchange's sorted calls where
  the oracle's ran concurrently, the landings failed receives left and the resources the answers
  read). `tests/support` reads the receive root among a replay's leftovers.
- `rust/scripts/check-corpus-replay.py`: a product whose bytes carry the oracle's own clock reading
  (the liveness document's observation instant), and every product naming one of those (a
  capture's log, index and summary), is minted differently on the daemon's clock, so its recorded
  identity, digest and reference read as `<clock-bearing>` on both sides and a listing's items are
  compared as a multiset; the startup-recovery note is accepted on every parked Job, not only an
  `observe.device@1` one (the default capture oracle's parked Job failed the replay after restart
  without it).

## Local targeted checks

Rust with `CARGO_BUILD_JOBS=2` and `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`; logs
under `/private/tmp/arkdeck-s11-*`.

| Check | Command | Result |
| --- | --- | --- |
| Swift oracles | `run-swiftpm.sh test --filter <class>` for the three new classes, with the record variable, then twice without | exit 0; byte-equal each time |
| Swift schema | `run-swiftpm.sh test --filter 'CaptureDiagnostics|ControlMethodSchemaContractTests'` with `ARKDECK_CONTROL_FRAME_LOG` | exit 0: 9 tests, 243 recorded frames valid |
| Derivation | `generate-control-contract.py --derive-method-schemas` over the three methods' corpus plus five frames; structural and corpus check | every old line and shape kept; no narrowing; 0 jsonschema refusals over five fixtures |
| Contract | `rust/scripts/generate-contract.py --write`, then `--check` | exit 0 |
| Replays | `cargo test -p arkdeck-hoststore --test capture_diagnostics` | 4 passed (default, read legs, file legs, Trace legs) |
| Mutations | the Trace bracketing, the capture cleanup debt, the liveness document and the ring's held anchor each removed | each caught (exit 101); sources restored by checksum |
| Crates | `cargo test --no-fail-fast` for provider-hdc, hoststore, agentd, soak, control, contract, cli, client | exit 0: 140 targets, 1,057 passed, 14 existing ignored |
| Lint | `cargo fmt --all --check`; `cargo clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-control --all-targets -- -D warnings` | exit 0 |
| Real processes | `check-corpus-replay.py --fixture` for `capture-diagnostics-read-legs`, `capture-diagnostics`, `observe-device`, `agent-execution`, `agent-lifecycle`, `target-adoption`, `trace-probe` | PASS: 66/144, 28/64, 28/64, 29/60, 25/61, 18/26, 22/28 exchanges/checks |
| Contract views | `rust/scripts/check-contracts.py` (validation venv) | exit 0: published view (merge base `bfe959c74`, 5 commands) and candidate view (18 commands) |
| Swift harness users | `run-swiftpm.sh test --filter` the 19 oracle classes that compose `HDCOracleHarness`, and `ControlMethodSchemaContractTests` | exit 0: 24 tests (one skipped without a frame log); every oracle byte-equal |
| SDD | `sh scripts/check-sdd.sh` | exit 0 |

No fake HDC or daemon of this run outlived it. Not run here: the App scheme, signed Mach IPC, a
device.

## CI

Pending.

## Declared differences from Swift

1. A snapshot the record cannot keep durably: Swift fails the Job with `Trace before snapshot
   failed: <write error>` (or notes it after a step's failure); Rust refuses the run as a lifecycle
   it cannot complete, and after a step's failure notes that the record is unwritable. Not
   reachable from the oracles.
2. The probe's own differences (#2133): after a lost tag list Rust answers once the parameter reads
   end, where Swift cancels them; Rust never reports a sibling of a hung read as timed out.
3. A composition without a host receive root plans the legs that land no file and refuses only a
   receive; Swift always has one, and every Rust daemon composition names one.

## Not covered, and follow-ups

- `check-corpus-replay.py` cannot replay the file-leg and Trace fixtures against the isolated
  daemon: device mutation there needs the development mutation authority with a managed HDC server,
  and the daemon's receive root is Foundation's temporary directory, which the receive argv and so
  the plan digest name (as for `capture.screen-sequence@1`). They are replayed in-process only.
- Parked capture Jobs stay parked: their reconciliation and resume are queue slice 8.
  `cleanupDebt.continue` of a capture's owed cleanup is not oracled here.
- Not recorded: a received file past 64 MiB, a readback past its capture, a Trace snapshot that
  cannot be kept durably.
- Found, not fixed: `job.show` of a `capture.screen-sequence@1` Job answers the record's
  `screenSequence`, which the published schema still pins to null (no oracle records that read),
  so the Rust control layer would answer it `internalError`; widening it needs such a frame.
- `agent-human-action` is not among the `check-corpus-replay.py` oracles its own slices ran: there
  its first execution answers `waitingForHuman` where the oracle recorded `completed`, with or
  without this change (no product of it carries the oracle's clock, and the recovery note only
  widens what a restart may add). Not investigated here.
