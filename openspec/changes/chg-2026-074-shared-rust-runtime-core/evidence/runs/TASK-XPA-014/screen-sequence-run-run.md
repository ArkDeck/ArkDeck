# TASK-XPA-014 — the Rust owner plans, admits and runs `capture.screen-sequence@1` as Swift does, replaying the S0 Swift oracle (S1, macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `74c3b2b1` (#2016). The slice was written on
`e862d2bf` (#2007) and rebased onto `2b88705f` (#2008) without conflict, onto `111fc8a2`, which
landed the native-library planner (#2011) during the slice (see *Rebase onto #2011* below), onto
`9c58e484` (#2012, control-action frames and schemas) and onto `74c3b2b1` (#2013, #2015, #2016:
scripts and documents, no Rust source) without conflict. Every
answer and every file compared here is replayed from Swift's screen-sequence oracle (#2006,
`screen-sequence-oracle-run.md`), recorded over the shared fake HDC in a fixed-root host fixture.
None of it is device evidence, installed-Runtime activation or GJ acceptance (POL-VERIFY-001,
POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`capture.screen-sequence@1`) |
| --- | --- | --- |
| The provider's file legs (`FileAction`, TASK-XPA-016 M1); the S0 oracle (#2006); the durable mutation runner and its one-use rule (#1984, #1998, #2005); Runtime-issued capabilities (#2000) | The receive root in the HDC composition and the daemon; planning, admission, `job.run` and `agent.run`; the file-backed publication of `frames.tar`; `screenSequence` on the record and `sequence.json`; `job.result`/`job.evidence`; availability held to the mutation owner | Recovery of a parked capture (design §L.1 item 13, ruled on 2026-09-19 and ported in its own slice); `cleanupDebt.list`; any debt or cleanup for a failed capture or residue (a maintainer ruling, S0 question 2); the daemon's agent path exercised end to end; device, GJ acceptance |

## What changes

- **The receive root** (`device_facts.rs`, `arkdeck-platform` `temporary_directory.rs`, agentd
  `host.rs`). `HdcComposition::receive_root` is Swift's `hostReceiveRoot`: the host directory a
  received file lands in, under the remote file's own name. The receive argv names it, so it reaches
  the plan digest and the automatic capability. The daemon composes Swift's default,
  `FileManager.default.temporaryDirectory/arkdeck-receive`: `foundation_temporary_directory` is
  `confstr(_CS_DARWIN_USER_TEMP_DIR)`, then `TMPDIR`, then `/tmp/`, spelled as given. Probed on this
  host, Foundation answers the per-user directory even when `TMPDIR` names another one, so
  `std::env::temp_dir` (which reads `TMPDIR` first) would have planned another digest. Every other
  composition (tests, `arkdeck-soak`) names none, and a composition without one refuses to plan the
  operation.
- **Planning** (`job_plan.rs`, new `screen_sequence_plan.rs`). The operation joins `MATERIALIZED`
  (its own line). Every selected step is materialized under `job-authorization-envelope`: the engine
  steps; the evidence reads and the storage preflight as every device plan lowers them; the capture
  and the cleanup as `processSequence` rows, the receive as one `process` whose argv names the
  landing path, each with Swift's journal arguments. The lone scaled dimension is refused by the
  provider's typed preflight (`malformed(field: "width/height", …)`) and a single frame by the
  catalog (`input frameCount is below minimum 2`), both in Swift's words.
- **The steps** (`device_steps.rs`). The operation joins `DEVICE_OPERATIONS` and stays out of
  `EVIDENCE_OPERATIONS`. `StepAction::File` holds the provider's `FileAction` with the context's
  clock; `action_in` claims it for this operation only, after the HAP claim. New arms in `persisted`,
  `verify` (over the whole receipt), `effect` and `plan`; `plan_in` lowers a file leg with the
  composition's receive root (the runner's one call site). `file_journal_arguments` is Swift's
  `journalStep(for:)` for the three legs (`trace-presets`/`custom` with `frameCount`, `imageType`,
  `framesDirectory` and the archive; the archive received to `artifacts/raw/frames.tar`; the archive
  and the frame directory with `owned-<job>`), each declaring no compensation. `products` maps
  `receive-screen-sequence` to `frames.tar`, `finalize_products` the operation to `sequence.json`,
  and `FILE_BACKED` is Swift's `fileBackedArtifacts`.
- **The run** (`device_run.rs`, new `device_screen_sequence.rs`). The Job consumes its one use at the
  capture, after the storage preflight; the cleanup continues under it. After a verified step whose
  summary carries both frame counts, the record keeps `screenSequence` (Swift's setter, each span as
  Swift's `Double` reads the `%.3f` list, held as Swift's `JSONValue` holds it so that a whole span
  reads back as the integer Foundation writes). A received product is the landed bytes or nothing:
  published from the landed file with `publishFile`'s source checks, the landing copy then removed;
  refused, it is recorded missing and the Job's publication fails. An empty archive fails the Job at
  the capture and a residue at the cleanup, after `frames.tar` is published; neither owes a debt or
  runs a compensation, as in Swift. An archive the readback cannot find parks the Job with its intent
  and exact action outstanding.
- **Finalization** (`capture_documents.rs`). `sequence.json` is Swift's `sequenceDocument`: the
  counts, each span, the rate over their sum, the frames missing, or the recorded absence, in
  Foundation's sorted pretty spelling.
- **Reading and availability.** `READABLE` gains the operation (`job_result.rs`); `MUTATIONS`
  (`operation_availability.rs`) and the daemon's tool-identity list hold it to the mutation owner, so
  the isolated development daemon lists it unavailable (`runtime.mutationOwnerUnavailable`), as it
  lists the gestures, the port rules and the HAP.
- **Tests.** Each existing HDC composition names `receive_root: None`. `capability_write.rs` replays
  the screen-sequence capability store as well (five M2 stores).

## Development checks

Commands in `rust/` of `/private/tmp/arkdeck-screen-sequence-run-20260919`, with its own
`rust/target`, 2026-09-19 CST, during the slice; the final checks are under *Local targeted checks*.
Logs are in `$S` =
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs`.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Targeted, host store | `cargo test --locked -p arkdeck-hoststore --test screen_sequence_run --test capability_write --test debug_hap_run --test debug_hap_submit --test debug_hap_plan --test pointer_input_run --test port_forward --test capture_diagnostics --test observe_device --test native_library_plan --test native_library_submit --test job_plan --test job_run --lib` on the final tree | 0 | 224 passed, 0 failed: `screen_sequence_run` 2, `capability_write` 4, the HAP, pointer, port, diagnostics, observe, native-library and job replays, and the host store's unit tests (180, 5 ignored) (`$S/screen-sequence-run-targeted5.log`, SHA-256 `e34afddc8291adaca310297c0e45b68cb68a6ae7808d4bcdb76230130955f5fa`) |
| Targeted, daemon and platform | `cargo test --locked -p arkdeck-agentd -p arkdeck-platform -p arkdeck-soak` on the final tree | 0 | 191 passed, 0 failed, the daemon's availability tests and both temporary-directory tests included (`$S/screen-sequence-run-targeted6.log`, SHA-256 `02b772f1f37fff8095fd41beaab924542a65ebf7ecfff28632efb51b498250d3`). One earlier run, before #2011, failed `verified_process::output_overflow_kills_and_reaps_the_child` once, the known timing flake; it passed alone and in every run since |
| Workspace (before #2011) | `cargo test --workspace --locked --no-fail-fast` on the tree rebased onto `e862d2bf` | 0 | 921 passed, 0 failed, 16 ignored in 126 suites (`$S/screen-sequence-run-workspace1.log`, SHA-256 `f5bfc5ef3765d4c4ca6d685f16cb4162b3562fab82accce8c426358f4c87aef2`); the PR's CI reruns the workspace on the final tree |
| Clippy, macOS | `cargo clippy --workspace --all-targets --locked -- -D warnings` on the final tree | 0 | Clean (`$S/screen-sequence-run-clippy-macos.log`) |
| Clippy, Linux | `… --target x86_64-unknown-linux-gnu -- -D warnings` on the final tree | 0 | Clean (`$S/screen-sequence-run-clippy-x86_64-unknown-linux-gnu.log`) |
| Clippy, Windows | `… --target x86_64-pc-windows-msvc -- -D warnings` on the final tree | 0 | Clean (`$S/screen-sequence-run-clippy-x86_64-pc-windows-msvc.log`) |

`tests/screen_sequence_run.rs`, over the fixed root `/private/tmp/arkdeck-hdc-oracle` with the
Runtime's own `MutationAuthority` (the account-fixed `store` root, the Session owner), the fake HDC
spawned through `ProcessDispatch` behind a decorator that reports every child at the oracle's
`invocationSeconds` (0.5 s, Swift's `FixedDurationDispatcher`), and the oracle's `receiveRoot`:

1. `rust_captures_every_swift_screen_sequence_as_swift_does` replays 50 of the 51 exchanges — 10
   plans (two refusals), 8 submissions (the `afterUnknown` refusal included), 7 runs, 21 reads
   (`job.result`, `job.evidence`, `artifact.list` of each Job), `capability.list` and 3
   `capability.inspect` — each answered as Swift answered it, message included. The fake receives
   Swift's 84 calls in order. Every Job but `lowStorage` consumed exactly one use. Everything the
   replay leaves is Swift's byte for byte: the index (schema, rows, versions, record digests), the
   tree's kinds and modes, every Job record and journal, the capability checkpoint and ledger (six
   uses, the parked one `outcomeUnknown`), the Sessions root and the Session owner (their catalog and
   locks only), and every Artifact index and payload — four `frames.tar` and three `sequence.json`.
   No cleanup debt ledger exists, and the receive root is empty. A second `job.run` of the parked
   Job is refused (`resourceConflict`) and dispatches nothing.
2. `the_host_receive_root_is_part_of_the_plan` (no oracle records it): a composition that names no
   receive root refuses the plan and dispatches nothing; another root plans another digest; the
   oracle's root plans Swift's answer, and planning prepares no landing.

Unit tests: `measured` (both counts required, Swift's `Double` reading, whole spans as integers) and
`sequence.json` (the oracle's bytes, the recorded absence, a whole span, and a record holding one
that stays durable); the temporary directory's order. Mutation checks, each reverted before the
commit: keeping the landing copy, skipping the record setter, another receive path in the journal
arguments, and publishing `frames.tar` through the facts path each fail the replay; `measured`
without Swift's number holding fails both unit tests; `TMPDIR` before the per-user directory fails
the order test.

## Local targeted checks

The verification policy for this slice changed before it was committed: no full unified gate; the
changed crates' checks locally, and GitHub CI on the PR. On the committed Rust sources (checked on
merge base `9c58e484`; the rebase onto `74c3b2b1` changed nothing under `rust/crates` or the Cargo
manifests, and after it the one test comment edited here was checked again), from the worktree
root with `CARGO_BUILD_JOBS=2` and
`CARGO_TARGET_DIR=/private/tmp/arkdeck-screen-sequence-run-20260919/rust/target`, 2026-09-19 CST:

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | Clean (`$S/screen-sequence-run-local-fmt.log`, empty) |
| Clippy, host | `cargo clippy --manifest-path rust/Cargo.toml --locked -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | Clean (`$S/screen-sequence-run-local-clippy.log`, SHA-256 `8ff208724cf0c04081c037b021a39dac4e914bed652a41bbea2f278fdd6433e0`) |
| Tests, changed crates | `cargo test --manifest-path rust/Cargo.toml --locked --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak` | 0 | 70 suites: 544 passed, 0 failed, 16 ignored (`$S/screen-sequence-run-local-tests.log`, SHA-256 `3f9c788fcc1835e140aaf424e1a9da90b20cf3f05b837b2cc10ba34cc52e6c57`) |
| A dependent's test | `cargo test --manifest-path rust/Cargo.toml --locked -p arkdeck-cli --test agent_resume` | 0 | 2 passed (`$S/screen-sequence-run-local-cli-agent-resume.log`, SHA-256 `8fd9cc37ede2bfc2b25e0e90ba15f8d3caeecdb1e46cdc531b657fd836019e2a`); see the gate run below |
| SDD | `python3 scripts/check_sdd.py`, with the validation environment's interpreter (`/private/tmp/arkdeck-validation-venv/bin/python`; the system `python3` has no PyYAML) | 0 | `check_sdd: 0 error(s), 0 warning(s), 121 acceptance IDs` (`$S/screen-sequence-run-local-sdd.log`) |

`generate-contract.py --check` was not run: no contract input changed. The platform change adds
one function that only the daemon calls, so `arkdeck-cli`, `arkdeck-client` and
`arkdeck-provider-hdc` were not retested beyond the one test below.

A unified gate run queued before the policy changed ran on this slice (merge base `9c58e484`,
2026-09-19 20:35:46–20:36:37 CST, load 23.8–33.4) and exited 1 at `arkdeck-cli`
`agent_resume::runtime::resume_sends_once_preserves_receipts_and_never_replays_lost_responses`,
`WouldBlock` (os error 35) on a socket, before any crate this slice changes was tested
(`$S/screen-sequence-run-gate-r1.log`, SHA-256
`680da46c125aa629949591517377ffab86038b6a48a20a7a013299dcbb822bb8`). `arkdeck-cli` is untouched and
the test passes alone (above). A run queued earlier, on the tree before the rebase onto `9c58e484`,
was stopped when main moved (`$S/screen-sequence-run-gate-r1-stopped.log`).

## CI

Pending: the coordinating session pushes the branch; the PR's GitHub CI (guard and the Swift
aggregate) is the unified gate. PR number, run id and conclusion to be recorded when it runs.

## Not replayed, and why

- **`cleanupDebt.list`**: not served by this Runtime (as for the HAP). Its recorded answer, `[]`, is
  checked as the ledger's absence (`artifacts/cleanup-debt.json` does not exist).
- **The parked `missingArchive` Job beyond its recorded answers**: its reconciliation and the
  settlement of its `outcomeUnknown` use are recovery (design §L.1 item 13, ruled on 2026-09-19 and
  ported in its own slice); this runner refuses to run it again.
- **Not oracled** (S0's list): cancellation; a receive that fails (an empty file, one over 64 MiB,
  nothing landed); a landed file refused at publication; a timeout; a `totalArtifactByteBudget`
  other than the default; the Artifact quota refusing the host preflight.
- **The daemon's agent path** (`agent.run` through the agentd composition, which now names the
  receive root) and `scripts/check-corpus-replay.py` against the isolated daemon: that daemon has no
  account-fixed mutation owner, so it lists the operation unavailable and admits no capture.
- No device, HDC server, installed Runtime or GJ acceptance; no Swift source, Catalog, schema, spec
  or fixture changed.

## Declared differences from Swift

1. **Publishing the landed archive.** Swift's `publishFile` streams the landed file descriptor to
   descriptor into a staging inode and links it. Rust reads the landed file once (at most 64 MiB,
   the receive's own bound) with the same source checks — no link followed, the declared regular
   file of the declared size and digest, its inode, size and timestamps unchanged — and publishes
   those bytes through the store's ordinary write-and-seal path (a binary product is not redacted).
   The bytes, identity, metadata, mode and index are the same. On a source that fails twice over,
   the refusal named may differ: Swift refuses an already-bound name or a full quota before reading
   the source, Rust after.
2. **A composition without a receive root** refuses to plan the operation (`rejected`); Swift always
   has one. Every production composition names Swift's default.
3. **Inherited, not new:** the tool-identity proof at each mutation, here the capture and the
   cleanup (HAP record, question 2), and the first consumption's refusal wording (question 3).

## The S0 record's maintainer questions, as they affect S1

1. **Gaps read each still's exit status.** S1 reproduces the provider's verdict as recorded
   (`FileAction::verify` is unchanged). Counting stills in the directory or the archive would change
   the provider, Swift first; nothing in the host store depends on which rule holds.
2. **A failed capture or a residue leaves the device dirty with no debt.** S1 matches Swift: no
   debt, no compensation, `compensationDescriptors: []`, no ledger, `outstandingResidueCount` 0. If
   the ruling adds an exact cleanup or a debt (design §L.1), the HAP's ledger (`cleanup_debt.rs`) and
   failure lane can carry it, after the Swift and Catalog change and a re-recorded oracle.
3. **The plan digest follows the landing root.** S1 reproduces it, and spells the daemon's root as
   Foundation does, so the same user on the same host plans one digest under both runtimes; the new
   test pins that another root plans another digest. A root-independent digest (a landing resolved
   at dispatch, as `executableSHA256` already is) would be a Swift contract change first.

## Rebase onto #2011

#2011 (native-library planning and admission) merged while this slice was in progress. Four files
conflicted: `device_facts.rs`, `device_run.rs`, `device_steps.rs` and `job_plan.rs`. Each was
resolved by keeping both operations: both `MATERIALIZED` lines (eleven), separate `StepAction`
variants and arms, separate planner modules and branches, and `plan_in` delegating to #2011's
context-taking `plan`. Two semantic union fixes: the native-library test composition
(`tests/support/native_library.rs`) names `receive_root: None`, and this slice's test composition
names `code_sign_helper: None`. The native-library run slice, still in flight, will meet this slice
at `DEVICE_OPERATIONS`, `MUTATIONS` and its test, the daemon's tool-identity and availability-test
lists, the runner's `plan_in` call and `publish`, and any new HDC composition (`receive_root`).
