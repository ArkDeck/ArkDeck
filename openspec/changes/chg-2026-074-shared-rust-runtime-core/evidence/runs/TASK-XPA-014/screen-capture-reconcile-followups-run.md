# TASK-XPA-014 — a parked screen sequence and a JPEG still reconciled in Rust, and a screen sequence Job's `job.show` published (M2, macOS, 2026-09-24)

TASK-XPA-014 remains in progress. Base: protected main `a7229512d` (#2138). The follow-ups of
G5 slice 8 (`mutation-reconcile-resume-run.md`) and of slice 4 (`capture-diagnostics-legs-run.md`):
two Swift defects that slice found are fixed in Rust and declared, one control contract gap is
closed, and `cleanupDebt.continue` spells a refusal as Swift does. Every Swift behaviour cited is
read from Swift source or replayed from the `device-mutation-reconcile` oracle; the Rust-only
scenarios below have no oracle. None of it is device evidence, installed-Runtime activation or GJ
acceptance (POL-VERIFY-001, POL-MODE-001).

## Authority for the declared differences

The maintainer's rule of 2026-09-20 — a defect found in the Swift Runtime being retired is fixed in
Rust, not in Swift, and recorded as a declared difference — applied to these two defects by the
coordinating session's ruling of 2026-09-24 (the S17 assignment): "screen-sequence Job 停在 capture
或 cleanup 步骤上时永远 reconcile 不了 … Rust 让它们走与 capture 文件腿同类的专用读回 … unknown 仍停放、
永不重放" and "JPEG 截图的 receive/cleanup 按默认 PNG 后缀重建路径 … Rust 改为按记录里实际的文件名/格式重建
路径". Swift is not changed; the frames of the recorded oracle that come from the defect are
marked as declared differences in the test that replays them, and no fixture was edited.

## What a user sees

- A `capture.screen-sequence@1` Job parked on its capture or its cleanup can now be reconciled.
  Before, the reconcile began (`waitingForRecovery → reconciling`), then failed `internalError`
  ("persisted typed provider action kind hdc.captureScreenSequence is unknown"), and the Job could
  never be concluded, its Target's automatic capability lineage blocked for good. Now the parked
  step is read back once, never resent: the capture by `ls -ld` of its archive and of its frames
  directory, the cleanup by `ls -ld` of the frames directory. A capture whose archive is there
  completed, and `job.run` resumes the Job to receive, clean up and finish; one that left neither
  archive nor frames was not executed, and the Job fails (`executionConfirmedNotPerformed`, its use
  `safeToReflash`); one that left its frames without their archive ran in part, and stays parked.
  A cleanup whose frames directory is gone completed; one whose directory remains was not
  executed. Anything the probes cannot answer, or a probe that cannot be dispatched, stays parked.
- A JPEG still of `capture.diagnostics@1` (`screenshotImageType: jpeg`) parked on its receive or
  cleanup can now be reconciled, and its refused cleanup's debt can now be continued. Before, both
  were refused (`persisted … remote path does not match its owned components`), because the path
  was rebuilt with the PNG suffix the device never wrote.
- `job.show` of a screen sequence Job answers what its run of stills measured (`screenSequence`).
  Before, the published schema pinned the member to `null`, so the Rust control plane rewrote the
  answer to `internalError` ("the result does not conform to the current contract").
- A refused `cleanupDebt.continue` whose persisted action cannot be materialized is answered
  `internalError` with Swift's wording, the detail alone, not `unsupportedAction("…")`.

## Swift semantics (read from source)

- `PersistedTypedProviderAction.materialize()` (`DeviceProviderContract.swift`) has no case for
  `hdc.captureScreenSequence` or `hdc.cleanupScreenSequence`: it throws
  `DeviceProviderError.unsupportedAction("persisted typed provider action kind … is unknown")`.
  `HDCObservationProviderAdapter.reconciliationReadback` has no case for them either, so even a
  materialized action would answer "original action has no dedicated readback" and never conclude.
- The same `materialize()` rebuilds `hdc.receiveOwnedArtifact` and `hdc.cleanupOwnedRemotePath`
  with `path()`, whose image type defaults to `.png`, and requires the rebuilt path to equal the
  recorded one; a JPEG still's recorded path ends `.jpeg`, so the record is refused. Only
  `hdc.captureScreenshot` persists `imageType` and rebuilds with it.
- `continueCleanupDebt` (`RuntimeJobEngine.swift`) calls `try persisted.materialize()` without
  catching; the daemon's `cleanupDebt.continue` handler (`AgentDaemon.swift`) answers any error that
  is not a `RuntimeJobEngineError` as `internalError` with `"\(error)"`. `DeviceProviderError` is
  `CustomStringConvertible` with `description` the detail alone; `HDCE0RequestError` has no custom
  description, so it interpolates as its case (`malformed(field: "…", detail: "…")`). That is the
  spelling `job.reconcile` already used (the `device-mutation-reconcile` oracle proves it for the
  unknown kind); `cleanupDebt.continue` rendered the provider error's own `Display` instead.

## Declared differences from Swift

1. **A parked screen sequence is read back.** `ParkedScreenSequence`
   (`arkdeck-provider-hdc/src/capture_files.rs`) materializes the two kinds from their persisted
   paths — the archive (`OwnedRemotePath`, suffix `.tar`) and the frames directory
   (`OwnedRemoteDirectory`, purpose `frames`), each rebuilt from `jobId`/`stepId`/`nonce` and
   required to be exactly the recorded one, the capture's request checked again as a capture checks
   it and the cleanup's frame count within its bound — and names its probes: the capture's archive
   (`hdc.readOwnedPathPresence`), then its frames directory (`hdc.readOwnedDirectoryPresence`); the
   cleanup's frames directory. `job_reconcile_device.rs` dispatches each once under the reconcile's
   step identity, read-only, and concludes only when every probe answered definitely:

   | Parked on | Archive | Frames directory | Decision |
   | --- | --- | --- | --- |
   | capture | present | present or absent | completed (`postconditionPresent`); `job.run` resumes |
   | capture | absent | absent | not executed; the Job fails, its use `safeToReflash` |
   | capture | absent | present | unknown: "frames directory … remains without its archive …; original not resent" |
   | cleanup | — | absent | completed; `job.run` resumes |
   | cleanup | — | present | not executed; the Job fails |
   | either | indefinite answer | or indefinite | unknown: "dedicated readback did not produce a definite presence" |
   | either | probe not dispatched | | unknown: "dedicated readback failed: …; original not resent" |

   The template is the capture file legs' readback (`ls -ld` of the owned file, presence against
   the presence the mutation wanted), the one Swift runs for a trace, a component tree and a
   screenshot. The capture writes two things, so "not executed" needs both absent: a capture that
   left its frames without their archive is exactly the state its own live verdict already leaves
   unknown ("sequence readback did not describe … as a regular file"), and it stays parked rather
   than being called not executed with its frames — sensitive stills — still on the device. The
   cleanup is read as a capture leg's cleanup is (its postcondition, the directory gone).
2. **A JPEG still's receive and cleanup keep their suffix.** `PersistedArguments::recorded_path`
   (`debug_hap.rs`) rebuilds the path with Swift's PNG suffix and, only when that does not name the
   recorded path, with the JPEG suffix; either must name exactly the recorded path, and every
   refusal and every record Swift reads stays Swift's (the second suffix differs from the first only
   for a still). The receive and cleanup materializations of both families use it; the owed
   residue of a JPEG still's cleanup is then the recorded `.jpeg` path, so `cleanupDebt.continue`
   finds and settles it.

Not a difference: `cleanupDebt.continue`'s refusal is now Swift's (`device_steps::refusal_detail`,
the rendering `job.reconcile` uses).

## Control schema: `job.show`

`spec/control/methods/job.show.json` pinned `result.screenSequence` to `{"type": "null"}`. The frame
the `device-mutation-reconcile` oracle recorded (`screenSequence/cases.json`,
`receiveKilled.job.show`: `{"capturedFrameCount": 3, "frameDurationsSeconds": [0.5, 0.5, 0.5],
"requestedFrameCount": 3}`) was written as a control frame line and `job.show` alone was re-derived
(`Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas`, in a scratch
copy of the method schemas and corpus) from the committed corpus plus that frame:

- Derived from the committed corpus alone, `job.show.json` and `job.show.jsonl` came out
  byte-identical to main's, so the derivation is the published one.
- With the frame: `screenSequence` became `anyOf` of the closed object (`capturedFrameCount`
  integer, `frameDurationsSeconds` array of number, `requestedFrameCount` integer; all required) and
  `{"type": ["null"]}`; `x-arkdeck-sampleCounts` request 24→25, result 22→23; nothing else changed.
  A structural check found exactly one differing path and the new schema covering the old one
  there. Every committed line kept (24→25 lines, below the 32-shape bound).
- jsonschema 4.26 (the validation venv): all 25 corpus frames and all 28 recorded `job.show`
  answers under `rust/tests/fixtures` validate against the new schema; against main's, exactly one
  answer is refused, the screen sequence one.
- `python rust/scripts/generate-contract.py --write` then `--check` (validation venv): only
  `spec/baselines/swift-single-v1.json` changed (`job.show` 25 requests / 23 successes, corpus 953
  shapes, the two directory digests and file digests); `ControlProtocolGenerated.swift` unchanged.

## Tests

- `arkdeck-provider-hdc`: `a_parked_screen_sequence_is_read_from_its_persisted_paths` (both kinds
  materialize from their persisted forms; probes are `ls -ld`, read-only; seven refusals),
  `a_parked_screen_sequence_concludes_only_on_definite_presences` (the table above),
  `a_jpeg_still_cleanup_is_read_with_its_own_suffix`, and
  `persisted_forms_materialize_back_as_swift_reads_them` rewritten: it pinned the JPEG refusal and
  now pins the JPEG receive and cleanup read back, and a `.gif` path or a `.jpeg` suffix on a fixed
  suffix leg still refused.
- `arkdeck-hoststore` unit: `a_parked_screen_sequence_is_concluded_by_its_probes_alone` (a scripted
  dispatcher: exact argv of each probe, one dispatch each, a failed probe ends the dispatches, every
  unknown), `a_persisted_action_is_materialized_as_swift_materializes_it` updated (the two kinds and
  a JPEG still now materialize; three new refusals), `cleanup_debt_continue`
  `a_refused_debt_action_is_answered_as_swift_interpolates_it` and
  `a_jpeg_still_cleanup_debt_names_its_own_residue`.
- `tests/device_mutation_reconcile.rs`:
  - `a_screen_sequence_is_reconciled_by_its_readbacks_where_swift_cannot` replaces the plain replay
    of `screenSequence`. Every exchange and snapshot is Swift's but the six whose Swift answer comes
    from the defect, which `sequence_declared` names and derives from Swift's answer:
    `reconcileMissingArchive` and `reconcileMissingArchiveAgain` (Swift `internalError`; Rust the
    status the second start answered, `waitingForRecovery`), `missingArchive.resume` (`is
    reconciling` → `is waitingForRecovery, not runnable`), `missingArchive.job.status` and
    `missingArchive.job.result` (the state), `missingArchive.job.show` (the state and six timeline
    entries per reconcile, less the three Swift kept resident). At both reconcile snapshots and at
    the end: every other Job file, the capability store (the use stays `outcomeUnknown`, the
    lineage blocked) and the Target document are Swift's byte for byte; the parked Job's journal is
    Swift's followed by the reconcile decisions only (no step outcome), its record Swift's last
    durable one plus the reconcile timeline, its index row one version ahead per reconcile, and the
    fake's calls Swift's plus the two `ls -ld` probes per reconcile.
  - Rust only (fresh Jobs over the scenario roots; a dispatcher loses one invocation's outcome
    before or after the fake ran it): a capture lost after its `tar` is read back complete,
    resumed, receives, cleans up and succeeds, settling its use, nothing of the capture resent; a
    capture lost before its `mkdir` is read back not executed and fails, its lineage open again; a
    cleanup lost after its `rmdir` is read back done and resumed with nothing sent, keeping what the
    capture measured; one lost before its first `rm` is read back not done and fails, the frames
    still on the device; a JPEG still whose cleanup was refused owes a debt that
    `cleanupDebt.continue` reads back and settles with one `rm`, a JPEG still's lost receive is
    reconciled not executed without a dispatch, and its lost cleanup is read back done and resumed.
    Two of them teach the recorded fakes what a device does — `ls -ld` of a regular file, and
    `snapshot_display` of a JPEG still, as the file legs oracle's fake answers it — in the rebuilt
    root only.
- `arkdeck-contract` `a_screen_sequence_job_show_carries_its_measured_run_and_the_record_stays_closed`
  and `arkdeck-control` `a_screen_sequence_job_show_passes_the_control_plane`: the recorded answer
  conforms and passes the control plane unchanged (the published view's merge-base schema may
  still rewrite it, which both tolerate); a whole-number span is accepted, `null` still is, an
  unknown member, a mistyped count, a missing count or a string span is refused.
- `tests/support`: `assert_store_except` and `Daemon::assert_capabilities` for the declared
  snapshot checks.

## Mutation checks

Each applied to the source, the tests below run, then the file restored from its copy and its
SHA-256 checked against the one taken before (`scratchpad/s17/mutate.py`; logs
`/private/tmp/arkdeck-s17-mutation-<name>.log`). The test set: the provider's `capture_files` and
`debug_hap` unit tests, the host store's `job_reconcile` and `cleanup_debt_continue` unit tests and
`tests/device_mutation_reconcile.rs`.

| Mutation | Where | Caught by |
| --- | --- | --- |
| A partial capture (frames, no archive) concluded not executed | `capture_files.rs` | 3 tests: the provider verdict table, the host store's probe test, the declared-difference replay |
| The sequence concluded completed without dispatching its probes | `job_reconcile_device.rs` | 5 tests: the probe test and all four screen sequence integration tests |
| A probe that cannot be dispatched read as absence | `job_reconcile_device.rs` | the probe test |
| A JPEG still rebuilt with the PNG suffix only, as Swift does | `debug_hap.rs` | 5 tests: both provider tests, the host store's materialization test, the debt residue test, the JPEG still integration test |
| The continuation's refusal rendered by the Rust error's `Display` | `cleanup_debt_continue.rs` | `a_refused_debt_action_is_answered_as_swift_interpolates_it` |
| The cleanup's verdict inverted | `capture_files.rs` | 3 tests: the verdict table, the probe test, the cleanup integration test |
| `job.show.json` narrowed back to main's | `spec/control/methods/job.show.json` | the contract test (and the corpus manifest tests), the control plane test (`/private/tmp/arkdeck-s17-mutation-schema-narrowed.log`) |

## Local targeted checks

All with `CARGO_BUILD_JOBS=2` and the worktree's own target `/private/tmp/arkdeck-1330-rust-target`;
logs `/private/tmp/arkdeck-s17-*.log`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | exit 0 (`clippy-r1.log`) |
| Lint, Linux target | the same four changed crates with `--target x86_64-unknown-linux-gnu` | exit 0 (`clippy-linux.log`) |
| Provider and host store | `cargo test -p arkdeck-provider-hdc -p arkdeck-hoststore --no-fail-fast` | exit 0: 689 passed, 14 ignored, 77 binaries, `device_mutation_reconcile`, `screen_sequence_run`, `capture_diagnostics` and `cleanup_debt_continue` among them (`test-provider-hoststore.log`) |
| Dependents | `cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`; `cargo test -p arkdeck-cli -p arkdeck-client --no-fail-fast` | exit 0: 200 passed (24 binaries); exit 0: 218 passed (41 binaries) |
| Contract generation | `python rust/scripts/generate-contract.py --write`, then `--check` (validation venv) | exit 0, exit 0 (`generate-write.log`, `generate-check.log`) |
| Contract views | `rust/scripts/check-contracts.py --output-dir /private/tmp/arkdeck-s17-contract-check` (validation venv, `CARGO_BUILD_JOBS=2`) | exit 0: published view (merge base `a7229512d`, 5 commands: workspace clippy and tests, the process self-test, the build, the read-only frame check) and candidate view (18 commands, the owner checks among them) both pass (`check-contracts.log`) |
| Real processes | `check-corpus-replay.py --fixture` `observe-device`, `capture-diagnostics`, `capture-diagnostics-read-legs`, `agent-execution` (daemon and CLI built from this tree) | PASS: 28/64, 28/64, 66/144, 29/60 exchanges/checks |
| Real processes, this oracle | the same for `device-mutation-reconcile/screenSequence` | not replayable, as slice 8 found: the isolated daemon refuses the first mutation's submission (`admissionDenied`, no development mutation authority without a managed HDC server), and the harness serves no `job.reconcile` |
| Swift schema consumer | `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ControlMethodSchemaContractTests` | exit 0: 5 tests, 1 skipped without a frame log; every committed corpus frame validates against its schema (`swift-control-schema.log`) |
| SDD | `sh scripts/check-sdd.sh` (validation venv) | exit 0: 0 errors, 0 warnings |
| Leftovers | `ps` for fake HDC servers, daemons and this run's watchers | none of this run's; the installed agentd and HDC untouched |

Not run: the App, other Swift tests (no Swift source changed), a device.

## CI

Pending.

## Not in this slice

- A parked capture that left its frames without their archive is kept parked for good, as its own
  live verdict leaves it; concluding it would take either a cleanup inside the reconcile (a
  mutation, which a reconcile never sends) or a maintainer decision to call a partial capture not
  executed.
- The probe proves an archive there, not whole, as the capture file legs' readback proves a
  trace, tree or still there: the resumed Job receives what is there, and an empty archive fails
  at its receive (`emptyArtifact`).
- A cleanup read back not executed fails the Job after `frames.tar` was published, the frames left
  on the device with no cleanup debt — what a residue does to Swift's live run too (a screen
  sequence's cleanup owes no debt in Swift).
- `check-corpus-replay.py` still cannot replay the device mutation oracles through a real daemon
  (development mutation authority, `job.reconcile`, starts mid-oracle), so the declared
  differences are proven in process only.
- Hardware: none of this is device evidence.
