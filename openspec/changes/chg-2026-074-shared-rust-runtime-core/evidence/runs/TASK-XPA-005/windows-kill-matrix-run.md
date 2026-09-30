# TASK-XPA-005 — WM1: the XPA-AC-7 kill matrix on Windows

Change: CHG-2026-074-shared-rust-runtime-core. WM1, TASK-XPA-005 verification: "XPA-AC-7 → kill
after `stepIntent` before dispatch → `outcomeUnknown`, no replay". This is the matrix the macOS
crash-window slice measures (`evidence/runs/TASK-XPA-014/recovery-crash-window-run.md`), on NTFS.

Branch `agent/xpa-005-windows-kill-matrix-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Scope (lead, 2026-09-30)

"The XPA-AC-7 kill matrix on Windows: kill the daemon, runner or child at each durable boundary.
After restart it must read back and recover, matching the macOS matrix and its oracles." This
record covers the first of this slice's four parts. The managed HDC start/stop semantics, the
`-t <connectKey>` injection point and the XPA-006 HAR crash-resume follow as separate PRs.

## What

Only tests change; no product code differs from macOS for this matrix.

| Test | Column | What it kills, and what it proves |
| --- | --- | --- |
| `arkdeck-hoststore/tests/windows_crash_window.rs` | runner | A child of the test binary runs the oracle's `input.tap@1` and exits without unwinding at each window (`beforeConsume`, `afterReadOnlyIntent`, `afterConsume`, `afterIntent`); the system closes its handles, as on a kill. Then: (a) the store is Swift's `crash/` byte for byte (index rows, journal, record, capability store and ledger); (b) two starts (`recover_active_jobs`) answer Swift's statuses and leave Swift's `restart/` and `secondRestart/`; (c) two `job.reconcile` answer Swift's answers and leave Swift's `steps/`; (d) a new tap is admitted, or refused `admissionDenied` with the zero-dispatch proof, as in Swift; (e) every read (`job.status`, `.show`, `.result`, `.evidence`, `capability.list`, `.inspect`) answers as Swift's did; (f) the fake's log does not grow from the death to the end; (g) the leftovers match: the Target document, the Job store, the capability store, the Sessions root and the storage owner, the tree by path and kind. |
| `arkdeck-hoststore/tests/windows_artifact_publication_death.rs` | runner | A child runs an `observe.device@1` Job and parks at a publication step through the Artifact owner's fault seam (`AfterPayload`, `AfterSeal`, `AfterIndex`), announcing it on its standard output. The parent then terminates it (`TerminateProcess`). Checked: exactly one payload and no partial file. An unsealed payload is never indexed; a sealed one is indexed only after its index step. The quota counts exactly what the indexes name, and the sweep keeps the unfinished Job's products. A start recovers the Job (no refusal, no quarantine) without changing an Artifact. |
| `arkdeck-agentd/tests/windows_kill_matrix_process.rs` | daemon | The real daemon over a development root holding each window's crash store. First start: its `job.status` is Swift's `restart` status, and the store is `restart/`. The test then terminates it while it serves (no drain); what it left is still `restart/`. The next start reports the previous instance, and its status and store are Swift's `secondRestart`. The requests after the death follow; a clean stop leaves the store where they left it, and a third start answers. |

Requests after the death, through the daemon:

- A reconcile the recorded facts decide answers exactly as Swift's did, and leaves Swift's `steps/`
  store. That is `beforeConsume` and `afterConsume`, where no intent is outstanding.
- A reconcile that needs the device's facts is refused `rejected` ("this owner holds no HDC
  composition to reconcile it; nothing was dispatched or written"), and the store stays Swift's.
  That is `afterReadOnlyIntent` and `afterIntent`: the Windows HDC tuple is not registered.
- The original tap sent again is answered from its idempotency record (`deduplicated`).
- A new tap is refused before admission with the zero-dispatch proof ("provider hdc is not
  registered").
- The reads answer as Swift's did while the reconciles matched Swift's.

### Delegated minor decisions, pending the next rulings batch

- **The fake HDC answers in process.** The crash-window and publication tests answer the
  recorded fake's table (`hdc-answers.sh`) in process instead of launching the shell script the
  macOS tests launch. The crash-window fake reports the tool identity current, as the macOS
  `ProcessDispatch` over the fake's verified script does. The Windows `ProcessDispatch` never does
  before the Windows HDC tuple publishes a launch identity, so the daemon reaches no device
  mutation. What the matrix measures here is the runner, its durable writes, the recovery and the
  reconciler on NTFS.
- **Allowed differences in the daemon test.** The daemon recovers on its own clock where the
  oracle's clock was fixed. Each UTC time it writes therefore reads as the oracle's, in the same
  spelling, and each capability ledger record's digest of its own bytes reads as a label. The
  Job's index row is laid down by the Job owner from the crash record, so its initial-record
  digest is not compared. Every other byte and column is compared.
- **Reading the index.** The daemon test reads the Job index only with no daemon running, from a
  copy of the database and its write-ahead log. A read-only connection beside a serving daemon
  did not reliably see its uncheckpointed writes. The copy reads what the next start finds, and
  nothing is checkpointed in place.
- **POSIX modes.** The tree's POSIX modes are not compared; NTFS keeps owner-only descriptors.
  Sealing is checked by whether the payload opens for writing.

## Not reached, and why

- **The child column.** The HDC child killed mid-call needs a Windows `ProcessDispatch` child.
  Its kill-on-close Job object (a deadline, a cancellation or a dropped server terminates the
  child tree) is covered by `arkdeck-platform/tests/windows_tool_dispatch.rs` (#2341). No device
  child runs on Windows before the HDC tuple.
- **The Import upload kill windows.** `import_upload_process_death.rs` stays macOS: the Import
  owner has no value on Windows yet.
- **The Swift-sidecar column.** r11 builds no sidecar; the Rust starts over the Swift crash store
  stand for it, as on macOS.

## Local checks

Run on Windows 11 x64 with `CARGO_TARGET_DIR=D:\cargo-target\s1-killmatrix` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd` | 0 | all pass; no `SKIPPED` line |
| the same with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 / 101 | this slice's three tests pass. One run failed in `job_store_corpus.rs` (#2361, untouched here): an `OutcomeUnknown(PermissionDenied)` from a `persist`, the NTFS atomic replace refused access to a just-written file. Four reruns under the short `TEMP` and two under the normal one passed (1 failure in 5 short runs), so it is transient on this host and reported to the lead |
| tamper checks: one byte changed in a recorded `restart/` index or journal | — | each test fails at that snapshot, then the fixture is restored |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |
