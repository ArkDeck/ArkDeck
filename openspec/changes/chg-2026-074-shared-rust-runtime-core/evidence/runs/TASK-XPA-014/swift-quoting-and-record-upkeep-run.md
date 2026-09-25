# TASK-XPA-014 — Swift's quoting of error payloads, exactly; a stale Import script removed; CI sections filled

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane A, upkeep. Host-only evidence; nothing
here is device evidence. Base: protected main `681988448` (#2174); developed and checked on
`e6119b0d3` (#2172) and rebased without conflict (#2174 touches none of these files). No
contract input changes.

## 1. `swift_quoted`: Swift's `debugDescription` of a payload, every scalar

`arkdeck-hoststore`'s `strict_json::swift_quoted` spells a `String` payload as Swift prints it when
an error case is interpolated (`String(reflecting:)`). Its callers' refusal messages carry it:
the strict JSON validator (`duplicateMemberName(path:)`, `malformed(…)`), the cleanup-debt ledger
and `cleanupDebt.continue` (`indexCorrupted`, `ioFailure`, `failed`, `outcomeUnknown`, …), the
Flash invocation broker and the Flash archive reader. It wrote an ASCII control as `\u{1b}` —
lower case, fewest digits — and its unit test expected exactly that (found by S10 while porting
`trace.probe`, whose own copy in `arkdeck-provider-hdc` already writes `\u{1B}`).

Measured with Swift 6.4 (swiftlang-6.4.0.34.1, arm64 macOS 27.0), `String(reflecting:)` and an
error case's interpolation, which printed the same for every input:

- `\0`, `\t`, `\n`, `\r`, `\"`, `\'`, `\\`; every other ASCII control as `\u{XX}`, two upper-case
  digits (`\u{01}`, `\u{0B}`, `\u{1B}`, `\u{7F}`); printable ASCII and every scalar beyond ASCII
  as itself (U+0085, U+2028, U+FEFF included) —
- except where a scalar left as itself would make one grapheme with the opening quote or with an
  escape just written (a combining or spacing mark, a joiner, an emoji modifier: 2,619 scalars
  when followed by `a`), or with the closing quote or an escape after it (the 27 prepended marks,
  U+0600…U+0605, U+06DD, U+110BD, …): that scalar is spelled `\u{XXXX}`, eight digits beyond the
  Basic Multilingual Plane (`\u{0301}`, `\u{0001F3FB}`). A mark after a base character stays as
  itself.

That is Swift's `String.debugDescription` since it guards the quotes against combining. The port
now does the same: `ascii_escape` for `escaped(asASCII: false)`, `unicode_escape` for
`escaped(asASCII: true)`, and `joins` — two scalars making one extended grapheme cluster — with
the `unicode-segmentation` crate hoststore already uses; two scalars never meet the Indic
conjunct rule, the one rule where Swift's runtime and the segmenter part (`session_graphemes`).

Every scalar U+0000…U+10FFFF, alone, followed by `a`, after `a`, between `a` and `b`, and twice
(5,560,320 strings), was quoted by Swift and by the port (scratch programs, not committed):

| | Strings quoted differently from Swift |
| --- | --- |
| Before, ASCII controls | 95 (19 scalars in all five places; U+0010…U+0019 happened to agree) |
| Before, beyond ASCII | 7,938 |
| After | 0 |

25 further multi-scalar strings (`"\u{600}a\u{600}"`, `"\u{1B}\u{301}"`, emoji sequences, CR LF,
Hangul, regional indicators, an escape between marks, …) also agree. The unit test now carries
eleven cases recorded from Swift, and names this record for the exhaustive check.

`arkdeck-provider-hdc`'s own copy (`trace_probe.rs`) spells ASCII controls right and not the
grapheme guard; its payloads are the runner's own failure reasons. Left as it is.

## 2. `rust/scripts/check-import-upload-owner.py` removed

The script (not in CI; referenced only by historical run records) started an isolated daemon
over the Swift-recorded `import-upload-current` fixture and drove the Rust CLI through a proxy
that loses one append reply. It predates the Rust Import commit owner and still expects
`artifact.import.commit`, `release` and `inspection`, `artifact import inspect` and a begin on a
proven alias to answer `operationUnavailable`. Run against current builds (the daemon and CLI
of `a6294ec3c`, then of `e6119b0d3` with one added line printing the answer the daemon
withheld), it fails at the commit step each time it gets there (7 of 7): the Rust owner
refuses this upload's commit with `resourceConflict` ("The exact Target binding is no longer
current", `phase: importOwner`, zero dispatch), a code `artifact.import.commit`'s published
schema does not list, so the daemon answers `internalError` ("the result does not conform to
the current contract", CLI exit 70). That is the pending `artifact.import.commit` error-code widening; whether
Swift refuses this fixture the same way is for that slice's recording. One of eight runs instead
timed out at the script's own 15 s bound: its proxy catches `TimeoutError`, which
`/usr/bin/python3` 3.9's `socket.timeout` is not, so the proxy ends if the CLI takes more than
0.1 s to connect.

What it checked is covered by tests that run in CI:

- the Swift snapshot read, resumed and appended without rewriting Swift's records:
  `arkdeck-hoststore` `tests/import_upload.rs`
  (`native_swift_upload_snapshot_reopens_and_resumes_without_rewriting_prior_records`,
  `exact_upload_identity_survives_restart_and_append_retry_without_changing_generation`,
  `begin_requires_runtime_binding_and_conflicting_metadata_never_changes_existing_owner`,
  `begin_and_abort_crash_windows_remain_discoverable_and_cannot_resurrect_an_upload`);
- the binding through the actual Target and a proven alias: `tests/import_target.rs`
  (`hdc_imports_are_bound_to_the_identity_their_lowercased_connect_key_names`,
  `native_alias_routes_hdc_imports_through_the_proven_alias_and_keeps_other_kind_semantics`,
  `missing_stale_or_injected_authority_never_creates_an_import`);
- the CLI's lost begin and append replies, a changed source, abort and inspection owners:
  `arkdeck-cli` `tests/import_resources.rs` (a fake Runtime);
- the real CLI with an isolated daemon — three kinds committed, restart, the same import again,
  a lost commit reply rediscovered by inspection, list, inspect, release:
  `arkdeck-agentd` `tests/import_publication_process.rs`.

No single test repeats a lost *append* reply through the real daemon; its CLI half and its owner
half are the fake-Runtime and append-retry tests above.

## 3. CI sections of S22–S25's run records

Filled from `gh` (read only), for the records whose CI section still said pending:

| Record | PR | Merged as | Runs (all success) |
| --- | --- | --- | --- |
| `TASK-XPA-014/device-mutation-lane-run.md` | #2149, head `7e8085010` | `93feeb0f8` | Agent PR 36034252376, SDD Guard 36034252254, Swift CI 36034252893 |
| `TASK-XPA-015/workspace-build-sign-run.md` | #2153, heads `8f8cabe6e` then `ed8272f01` | `4b89780f3` | first head: 36055652647, 36055652592, 36055653203; merged head: 36057643861, 36057643799, 36057644390 |
| `TASK-XPA-016/agentd-spawn-tests-own-binary-run.md` | #2156, head `bd1fc9b54` | `8e65fc877` | 36068394245, 36068394222, 36068394535 (macos-26 ran `tests/spawning`: 24 passed, 53 s) |
| `TASK-XPA-015/analyzers-trace-inspect-run.md` §8 | #2169, head `5f797e59a` | `a5a98af19` | 36094205142, 36094204890, 36094205038 |

S20's and S21's records (`workspace-isolation-run.md`, `workspace-patch-run.md`) and the other
seven sections of the analyzer record were already filled. Not touched: #2147's
`target-transactions-wait-run.md` (another session's) and M4's TASK-XPA-017 Flash records.

## Local targeted checks

With `CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, on `e6119b0d3`, and
after the rebase as noted:

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`
  (hoststore and its direct dependents), host, `--target x86_64-unknown-linux-gnu` and
  `x86_64-pc-windows-msvc`: exit 0.
- `cargo test --no-fail-fast` for the same three crates: exit 0, 99 targets, 776 passed,
  0 failed, the 14 existing ignored — among them `strict_json`'s tests, the cleanup-debt ledger's,
  `tests/cleanup_debt_continue.rs` (8, the Swift oracle replays), the Flash archive and broker
  tests and the Import owner tests named in §2. No fake `hdc` left behind.
- After the rebase onto `681988448`: `cargo fmt --all --check` exit 0; `cargo test -p
  arkdeck-hoststore --lib strict_json` exit 0.
- `sh scripts/check-sdd.sh`: exit 0 (and again after the rebase).
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract input changed),
  Swift beyond the recordings above, App, devices.

Logs: `/private/tmp/arkdeck-s26-*.log`; the Swift recordings and scratch comparisons:
`scratchpad/s26/` (`quoted_all.swift`, `quoted_multi.swift`, `quoted_unit.swift` and their
outputs).

## CI

Pending (this PR).
