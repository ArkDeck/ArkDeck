# TASK-XPA-018 — `trace inspect` on the Rust CLI (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. The hub cleared this leaf to be done
without changing the daemon or any contract input. Base: `main` `6c73312e4`
(#2181).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). What changes:

- `arkdeck-cli`;
- one new Swift oracle test, in a test target, and the oracle it recorded;
- Swift's argv fixture for the leaf, copied unchanged.

No Runtime, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change. The Rust daemon routes
`trace.inspect` and refuses every inspection (`operationUnavailable`, with its
owner's zero-dispatch proof), as #2176 recorded.
**The successful path has not run against a real daemon.** It runs against a
fake Runtime serving the answer Swift's daemon recorded.

## What Swift does

`RuntimeCLI.runTrace` handles `trace inspect --job <id> --artifact <id>
--allow-sensitive [--timeout <duration>]` in this order:

1. The Job and the Artifact must be exact identities, and the sensitive grant
   must be given. Otherwise it refuses with `invalidInput`: "trace inspect
   requires exact --job/--artifact identities and --allow-sensitive".
2. The inspection time defaults to `2m` and is at most `10m`. Otherwise it
   refuses: "Trace inspection timeout must be 1ms...10m".
3. The Job owner must not carry an Import's identity. Otherwise it refuses:
   "an Import identity cannot select a Job".
4. It sends one `trace.inspect` with `{owner, artifactId, allowSensitive:
   true, timeoutMs}`. The client waits five seconds longer than the
   inspection may take.
5. It checks the answer as `RuntimeTraceInspectionProjection`:
   - a closed shape, and an ephemeral inspection without device evidence;
   - the source is the one Trace a diagnostics capture publishes;
   - the engine, parser and schema identities are safe text and digests;
   - the counts are canonical;
   - the data-quality issues are known, ordered and consistent with their
     status.
   A failed check is `recordUnreadable` "Runtime returned an invalid Trace
   inspection".
6. The answer must name the owner and Artifact asked for. Otherwise it is
   `recordUnreadable` "Trace inspection belongs to another source".
7. It emits the answer as the Runtime gave it.

A refusal carrying the Trace inspection owner's zero-dispatch proof keeps its
code. That holds for `invalidInput`, `operationUnavailable`,
`resourceNotFound`, `artifactIntegrityFailed`, `recordUnreadable` and
`operationFailed`.

## What changes

This CLI now serves the leaf the same way:

- The parse requires the three options, as Swift's registry does. It also
  holds `--timeout` to the registry's grammar for this leaf: a duration of at
  most `600000ms`. So `11m`, `2h`, `0ms` or `05s` are the registry's refusal
  (64), before the handler's own ceiling is reached.
- The handler's checks run before any connection, in Swift's order and words.
  Its refusals carry the session's protocol version, as Swift's do.
- The answer check (`inspection_projection`) follows Swift's projection.
  Where Swift uses Foundation's `controlCharacters` (Cc and Cf) for safe text,
  macOS uses CoreFoundation's set. Off macOS, where Swift's CLI does not run,
  only Cc is known.
- The failure mapping gains the Trace inspection owner's proof.
- The legacy `--json` rendering comes from #2181.

## Found and aligned: a proven refusal keeps its code for every method

Swift's `CLIControlFailureMapper` has one rule for any method: a refusal whose
handler proves nothing was admitted (`phase: preAdmission`,
`newDispatchCount: 0`) keeps its code. That holds for `resourceConflict`,
`factsDrifted`, `admissionDenied`, `targetTrustPending`, `invalidInput`,
`operationUnavailable`, `inputTooLarge`, `invalidCursor`,
`idempotencyConflict`, `reviewedPlanMismatch`, `resourceNotFound`,
`humanActionExpired`, `orchestrationBudgetExpired`,
`orchestrationClockUntrusted` and `bindingRevisionStale`.

This CLI kept only `invalidInput` and `resourceConflict` for every method. It
kept `operationUnavailable`, `inputTooLarge`, `admissionDenied` and
`invalidCursor` only for the methods whose refusals had been recorded before.
The others became `internalError`. The oracle found this on
`trace.inspect`'s `operationUnavailable`, `resourceNotFound` and
`inputTooLarge`. The generic mapping now follows Swift's rule. Methods whose
failures this CLI maps elsewhere (the mutations, the owners with their own
proofs) are unchanged. All 309 CLI tests pass with it.

## Tests

| Test | What it holds |
| --- | --- |
| `CLITraceInspectOracleContractTests` (Swift, new) | Records into `rust/tests/fixtures/trace-inspect`: Swift's decisions on the recorded answer and 116 variants (21 accepted); the 51 quality scopes; 80 mapped refusals (16 wire codes × 5 kinds of evidence); and 20 handler decisions over argv |
| `trace_inspect.rs::each_answer_is_judged_as_swifts_projection_judges_it` | Each oracle answer is accepted or refused as Swift decides, with the owner and Artifact Swift reads. Off macOS the format-character cases are the declared difference |
| `trace_inspect.rs::a_quality_issue_names_only_swifts_scopes` | The scope set is Swift's |
| `trace_inspect.rs::each_refusal_maps_as_swift_maps_it` | Code, words and `details` of each mapped refusal |
| `trace_inspect.rs::the_handler_judges_each_argv_before_anything_is_sent` | Swift's 20 handler decisions replayed on `inspection_request`: order, code, words, details. Then, through this CLI: where Swift's registry lets the argv reach the handler (11 argv), the answer is Swift's handler's, or the request is sent. The 9 argv Swift's registry refuses (the missing grant, and every time past its grammar) are refused by this parser too |
| `trace_inspect.rs::runtime::*` (macOS) | Against a fake Runtime serving Swift's daemon's frames: one request, the answer emitted (envelope and legacy `--json`); the Rust daemon's refusal with its proof (69); a timed-out inspection (`operationFailed`, 1); another source's answer and a durable one (`recordUnreadable`, 2) |
| `trace_inspect.rs` unit test | 4 096 data-quality issues read, 4 097 refused |
| `argv_fixtures.rs` | The seven copied cases replay with no new deviation |

## #2181's durable-document note, recorded here

#2181 merged before the hub asked for this note, and its PR text is not
edited from this lane, so the note is recorded here. #2181 moved Foundation's
encoder into `arkdeck-contract` and aligned its exponent threshold with Swift's
(|x| > 2^53 or < 1e-4). That changes what hoststore writes: a `Double` between
2^53 and 1e16 used to be written as a 16-digit integer and is now written
exponentially.

- The production composition is not enabled, so no installed data is affected.
- In a development root, such a value that the Rust daemon wrote before will
  change its spelling the next time it is written.
- The spellings the oracle measured include `9.87654321e+15` and
  `9.007199254740994e+15`.

## Mutations

Each mutation changed one place in the source, ran the leaf's tests, the argv
replay and the library's tests, and restored the file by digest
(`/private/tmp/arkdeck-ti-mut.log`). All 17 were killed. T16, which deleted a
scope, was killed only by the compiler, so a same-length misspelling of the
scope (T16b) was also run: the scope and projection tests failed.

| Mutation | Killed by |
| --- | --- |
| A durable inspection read | the projection replay; the fake-Runtime test |
| A solidus allowed in safe text | the projection replay |
| 129 bytes of safe text allowed | the projection replay |
| No control scalar known | the projection replay |
| A non-canonical integer spelling allowed | the projection replay |
| Duplicate quality issues allowed | the projection replay |
| The status not tied to the issues | the projection replay |
| 4 096 issues refused | the unit test |
| The Import identity judged before the time | the handler replay |
| Another Artifact's answer read | the fake-Runtime test |
| The Trace inspection owner's proof ignored | the mapping replay; the fake-Runtime refusal test |
| A proven `resourceNotFound` not kept | the mapping replay |
| The `--timeout` grammar not parsed | the argv replay |
| The required options not parsed | the argv fixtures; the argv replay |
| The answer not validated | the fake-Runtime test |
| A scope misspelled (T16b) | the scope test; the projection replay |
| The default time 1m | the fake-Runtime refusal test (its `timeoutMs`) |

The client's five-second margin past the inspection's bound has no test of
its own.

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-ti-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-ti-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 309 passed, none failed (`arkdeck-ti-test.log`) |
| Swift oracle | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'CLITraceInspectOracleContractTests\|CLIDomainExecutorOracleContractTests'`: recorded twice (`ARKDECK_RUST_TRACE_INSPECT_RECORD=/private/tmp/arkdeck-ti-oracle-1` and `-2`), then compared with the checked-in copy. The build window was granted by the hub and the coordinator | exit 0 each; the two recordings are byte-identical (`arkdeck-oracles-record.log`, `arkdeck-oracles-record2.log`, `arkdeck-oracles-compare.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`, exit 0 (`arkdeck-ti-readonly.log`) |
| Audit | `cli-parity-audit.py <this build>` | 179 / 48 / 14 / 15; 135 of 209 leaves served (`arkdeck-ti-audit.md`). The leaf adds `trace.inspect` and the four App presentation entries that map to it |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-ti-sdd.log`) |

`generate-contract.py --check` (validation venv) also ran, since the copied
argv fixture sits beside the contract inputs: exit 0, 105 methods and 1009
recorded shapes, contract identity `1d7d101e83fe` (`arkdeck-ti-contract.log`).

## CI

- #2181, the legacy `--json` rendering (head `31c0e4816`): `guard` (run
  `36117373080`) and `swift` (run `36117373166`) passed, and so did all four
  Rust lanes and `swift-tests`. It merged as `6c73312e4`.
- This PR: pending.
