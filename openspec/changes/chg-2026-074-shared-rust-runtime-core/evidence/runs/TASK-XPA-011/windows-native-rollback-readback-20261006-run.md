# Native rollback readback values — 2026-10-06

The native provider already verifies the backup and restored whole-file SHA,
restarted process IDs and loader maps before confirming a rollback. The Runtime
previously retained only the fact names in its public timeline and dropped the
successful outcome summary, so the caller could not read the verified values.

The existing `job.timeline` text projection now retains one bounded
`native-readback <step-id> <JSON>` row after each verified backup or rollback.
The same JSON is durable in the existing Journal outcome `summary`. The public
projection includes actual whole-file hashes, PID arrays, the exact mapped PID
subset, whole maps SHA/byte count and matching-line count, and a hash of the
loader path. It includes no command output, remote path or connection identity.
`inputABI`, `inputBuildId` and `inputSha256` describe the leased replacement,
not the previous restored ELF. `job.events` remains a metadata-only projection.

The provider's verification, capability consumption, intent, restoration and
unknown-outcome rules are unchanged. Failed, unknown and truncated receipts
produce no successful readback proof. The original fact-name rows and frozen
Swift oracle bytes/pins remain unchanged. The historical replay first asserts
the complete new rows and outcome summaries, including every value and exact
field set, then removes only these verified additions for its original byte
comparison. Missing, duplicate, changed or unknown proofs are refused.

## Local targeted checks

All commands ran from `D:/src/ArkDeck-wt/rc-smoke-path`, based on the exact
adjacent Trace layer `9fa7c90f7853392efb3a6c3ddaa5d7171fab39f2`. The fixed,
exclusive session owner is `tool-select`, using
`D:/src/ArkDeck-wt/tools/cargo-owners/tool-select` through `run-cargo.py` with
`CARGO_BUILD_JOBS=2`. The current CLI and daemon sibling images were built before
the process fixtures. Live opt-ins were cleared, and the installed account
Runtime was typed-stopped throughout this sequential validation window.

Logs below are retained under `D:/src/ArkDeck-wt/tools/logs/`. The local
`native_rollback_check.py` invokes `python -X utf8 rust/scripts/run-cargo.py`
with the listed arguments and records the actual exit. Native execution was
needed because the first sandbox invocation refused Git repository ownership;
no ownership, ACL or `safe.directory` setting was changed.

| Arguments to `run-cargo.py` | Actual result | Log |
| --- | --- | --- |
| `fmt --all` (sandbox) | 1; Git ownership refused before Cargo | `native-readback-fmt-all-initial.log` |
| `fmt --all` (native) | 1; Windows `os error 206` | `native-readback-fmt-all-native.log` |
| `fmt -p arkdeck-provider-hdc -p arkdeck-hoststore` | 0 | `native-readback-fmt-owned.log` |
| `build -p arkdeck-cli -p arkdeck-agentd` | 0 | `native-readback-siblings-build.log` |
| `test -p arkdeck-hoststore --test native_library_run` | 0; 7 passed | `native-readback-focused-hoststore.log` |
| `clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `native-readback-clippy.log` |
| `test -p arkdeck-provider-hdc` | 0; 207 passed | `native-readback-test-provider-hdc.log` |
| `test -p arkdeck-hoststore` | 0; 562 passed, 7 existing ignored | `native-readback-test-hoststore.log` |
| `test -p arkdeck-agentd` (first run) | 101; 96 passed, 1 failed, 3 existing ignored | `native-readback-test-agentd.log` |
| Exact failed native CLI case in `--test spawning` | 0; 1 passed | `native-readback-agentd-consumer-fixed.log` |
| `test -p arkdeck-agentd` with the 39 unreached `--test` targets only | 0; 86 passed | `native-readback-agentd-remaining.log` |
| `test -p arkdeck-agentd --doc` | 0 | `native-readback-agentd-doc.log` |
| `test -p arkdeck-soak` | 0; 5 passed, 1 existing ignored | `native-readback-test-soak.log` |
| `clippy -p arkdeck-agentd --all-targets -- -D warnings` after consumer fix | 0 | `native-readback-agentd-clippy-final.log` |
| `fmt -p arkdeck-agentd --check` after consumer fix | 0 | `native-readback-agentd-fmt-final.log` |
| `fmt --all --check` | 1; Windows `os error 206` | `native-readback-fmt-all-check.log` |
| `exec python -X utf8 -B D:/src/ArkDeck-wt/tools/native_fmt_fallback.py` (each of all 13 workspace packages: `cargo fmt -p <package> --check`) | 0; all 13 passed | `native-readback-fmt-packages-check.log` |
| `sh scripts/check-sdd.sh` with the existing Python selected explicitly | 0 | `native-readback-sdd.log` |
| `git diff --check` | 0 | final source/note diff |

The first agentd failure was a real historical-comparator omission:
`gj23_replay` had its own byte-spelling closure and had not applied the exact
new-proof validation used by the hoststore replay. Its native Job-record byte
equality failed. That closure now uses the same closed, complete validation
only for `deploy-native-library`, preserving every original full-byte assertion
and all frozen corpus bytes/pins. The failed case passed on its own; the 39
unreached targets were then completed. Earlier green targets were not repeated.
This failure is not classified as an invalid load run.

Final distinct crate coverage is 957 passed and 11 existing ignored (agentd:
183 passed and 3 ignored across its completed segments). The focused 7-case
run is included in the full hoststore coverage, not counted again. The Windows
full-formatter command-length failures remain recorded; exhaustive per-package
format checks and final SDD/diff checks passed. All Cargo/test/formatter children
were drained before releasing the exclusive host window. No CI result or
hardware acceptance is inferred from these local checks.

The new regression uses the task-private shared fake HDC and real Runtime
owners. It checks exact public values, durable correlated summaries and retained
reads after reopen, with no additional dispatch. It also covers SHA/PID/maps
drift, incomplete/truncated receipts and unknown restoration. None of these
fixture runs is hardware acceptance or a `REAL_DEVICE_PASS` claim.

### Historical snapshot consumer follow-up

The actual macOS CI failures described below exposed two remaining historical
test consumers. Their replay index derives `recordSHA256` by hashing the
machine-independent reading of SQLite `initial_record_json`; it is not a
production stored SHA column. New verified timeline values correctly change
the current record bytes and their derived hash, while the frozen oracle
records the historical bytes. Projecting an already-hashed index could not
restore that historical digest.

The native-only consumer now first proves each complete current disk record's
Job ID and machine-independent digest against that actual replay index. It
validates every added readback field/value, projects only those additions and
recomputes the historical serialized record digest. Every other index column,
unchanged row, original file byte, tree entry, capability, Target and fake call
still compares exactly. This also applies at every intermediate native
published/unpublished recovery snapshot and to public answers, retaining
unknown/parked outcomes without dispatch. No production code or frozen corpus
bytes/pins changed in this follow-up.

The same exclusive owner/cache, source worktree, cleared live opt-ins and
typed-stopped Runtime were used. These are focused checks of the test consumer
increment; the previously completed unaffected crate suites were not repeated.

| Arguments to `run-cargo.py` | Actual result | Log |
| --- | --- | --- |
| `fmt -p arkdeck-hoststore` (sandbox) | 1; Git ownership refused before Cargo | `native-readback-index-fmt.log` |
| `fmt -p arkdeck-hoststore` (native account) | 0 | `native-readback-index-fmt-native.log` |
| `test -p arkdeck-hoststore --test native_readback_index` | 0; 3 passed | `native-readback-index-portable.log` |
| `test -p arkdeck-hoststore --test native_library_run` | 0; 7 passed | `native-readback-index-native-consumer.log` |
| `clippy -p arkdeck-hoststore --all-targets -- -D warnings` | 0 | `native-readback-index-clippy.log` |
| `fmt -p arkdeck-hoststore --check` | 0 | `native-readback-index-fmt-final.log` |
| `test -p arkdeck-hoststore --test native_readback_index --test native_library_run` (final source) | 0; 10 passed | `native-readback-index-final-targets.log` |
| `sh scripts/check-sdd.sh` with the existing Python selected explicitly | 0 | `native-readback-index-sdd.log` |
| `git diff --check` | 0 | final source/note diff |

The three portable cases check the actual historical serialized bytes/digests
of all committed native final and intermediate recovery snapshots. They reject
current index/disk digest or Job-ID mismatch and integrity-matching missing,
extra or changed proofs; unrelated record drift remains a historical digest
mismatch. The macOS-only `device_mutation_reconcile` execution cannot run on
this Windows host and remains required in current-head CI. No load-invalid
classification, retry, sleep or assertion waiver was used.

## CI

Native PR [#2609](https://github.com/ArkDeck/ArkDeck/pull/2609), head
`a29aa382a86ca15f2ebe634a31033ea1c0e088bd`, failed the macOS workspace in run
`37447814149`, job `112217173838`. The failures were
`device_mutation_reconcile::a_native_deployment_is_resumed_or_kept_parked_as_swift_decides`
and `native_library_run::rust_runs_every_swift_native_library_deployment_as_swift_does`,
at the whole replay-index comparisons in `support/mod.rs:254` and `:541`.
The original log is retained at
`D:/src/ArkDeck-wt/tools/logs/native-ci-macos-37447814149.log`.
Upper GJ5 PR #2611 repeated the same two failures in run `37447993881`, job
`112217782543`; its log is `ci-gj5-macos-workspace-37447993881-raw.log`.

These were code defects in the historical test consumers, not production
execution failures or an invalid load run. The follow-up retains those actual
failures. CI for the corrected follow-up has not run; protected-main
publication and current-head CI remain pending, with no earlier green result
claimed for this corrected source.
