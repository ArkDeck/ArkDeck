# TASK-XPA-018 — The legacy `--json` rendering on the Rust CLI (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. `trace probe` (#2180) found this gap, and
the hub queued it first, as its own slice. Base: `main` `6c173b8a5` (#2179).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). What changes:

- `arkdeck-cli`;
- `arkdeck-contract`, which gains the Foundation encoder that
  `arkdeck-hoststore` used for Swift's durable documents; hoststore now calls
  it;
- one new Swift oracle test, in a test target, and the oracle it recorded.

No Runtime, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change.

## What Swift does

Swift's registry declares `--json` on 189 of its 209 leaves. It asks for the
legacy rendering (`CLIRendering.legacyJSON`), not the versioned envelope:

- An answer is `CLIRuntimeSession.legacyDocument(value)`: the value as
  `CanonicalJSONEncoders.canonicalPretty()` writes it, then one LF. That is
  Foundation's `JSONEncoder` with sorted keys, pretty printing and no escaped
  solidus.
- A failure raised after the parse is the legacy document of
  `CLIResultEnvelope.legacyFailure(error)`, `{"error":{"code","message"}}`. It
  goes on stdout, with nothing on stderr.
- A refusal by Swift's registry parser stays prose on stderr, because its
  bootstrap output mode ignores `--json`.
- Stream rows are printed only in the human and `jsonl` renderings. The submit
  note, a compatibility leaf's warning and a person's prompt appear in the
  human rendering only.

## What changes

Until now, this CLI accepted `--json` only on `debug probe`, `trace probe` and
the service leaves, and wrote compact canonical JSON. It now does the
following:

- It accepts `--json` exactly where its registry copy declares it, and never
  beside `--output`.
- It writes an answer as Swift's legacy document. The Foundation encoder moves
  from `arkdeck-hoststore` into `arkdeck-contract::foundation_json`, so the CLI
  and hoststore share one implementation.
- It answers a refusal made where Swift's registry accepts the argv with the
  legacy failure document on stdout. That covers its own checks before a
  request, a leaf it does not serve yet (which `--output json` already answers
  with an envelope) and `--socket` off macOS. A refusal Swift's registry would
  make stays prose on stderr.
- It prints no stream rows, no submit note and no person's prompt under
  `--json`. The exit status of a settled Job and its stderr line are
  unchanged.

The runtime service leaves are left as they were (see "Found in passing").

## Found and fixed: how Foundation spells a large `Double`

Swift's oracle spells a `Double` exponentially above 2^53 and below 1e-4. For
example: `9.87654321e+15`, `9.007199254740994e+15`, `9.999e-05`. It keeps
`9007199254740992`, `1234567890123456.8` and `-0.0001` fixed.

The moved encoder spelled a number fixed up to 1e16. So the doubles between
2^53 and 1e16, which are all integral, came out as 16-digit integers. It now
follows Swift. This also changes hoststore's durable documents for a `Double`
in that range, which now match Swift's. Hoststore's existing spellings (`1e+16`,
`1000000000000000`, `1e-07`, `5e-324`) are unchanged.

## Found in passing, not changed here

- **The runtime service leaves' `--json`**: Swift's service handler renders
  through the same session, so its `--json` answer is the legacy document. This
  CLI still writes compact canonical JSON there. Every parse refusal of these
  leaves that was probed is also Swift's registry refusal, so it stays prose.
  The service leaves belong to the cutover lane, not this one.
- **The stderr line of a plain `CLIError`**: Swift writes it as
  `arkdeck <family>: <reason>`. Examples are a failed terminal state of
  `job run|wait`, of `workspace continuation run` and of `agent run`. This CLI
  writes `arkdeck: <reason>`, in every mode.
- **A mutation refused before anything is sent**: `session pin` whose
  `--socket` parent is not an owner-only directory is reported as
  `outcomeUnknown` (75) here, in every mode. Swift's client failure mapping,
  recorded for the human-action resume slice, reports a connection that never
  opened as `runtimeUnavailable`, mutations included. Whether Swift's endpoint
  check fails the same way is for that slice to record.

## Tests

| Test | What it holds |
| --- | --- |
| `CLILegacyJSONOracleContractTests` (Swift, new) | Records `legacyDocument` of 8 values that cover the format, and `legacyFailure` of 3 failures, into `rust/tests/fixtures/legacy-json`. The values cover empty containers, nesting and key order, 64-bit integers, `Double` spellings and their boundaries, and string escapes. Otherwise it compares against that oracle |
| `legacy_json.rs::each_value_is_rendered_as_swifts_legacy_document` | The Rust legacy document of each oracle value and failure is Swift's, byte for byte |
| `legacy_json.rs::every_leaf_takes_json_exactly_where_swifts_registry_declares_it` | Takes the valid argv of each copied fixture and adds `--json`. It is taken as the legacy rendering on each of the 121 leaves that declare it, and refused beside `--output`. `debug template list`, which declares none, refuses it |
| `legacy_json.rs::a_refusal_swifts_handler_makes_is_the_legacy_document_and_its_parsers_is_prose` | `job status --job bad:id --json` gets the legacy `invalidInput` document on stdout (65). `job status --json` without `--job` gets Swift's registry prose on stderr (64) |
| `legacy_json.rs::a_refusal_this_parser_makes_where_swifts_registry_accepts_is_the_legacy_document` | The predicate: `--json` present and Swift's registry accepting. A leaf this CLI does not serve yet (the first one declaring `--json` and no required option) is refused with the legacy document on stdout (64). Off macOS, `--socket` is refused the same way |
| `legacy_json.rs::runtime::a_result_and_a_refusal_are_each_one_legacy_document` (macOS) | Against a fake Runtime serving Swift's recorded status, the answer is its legacy document. The Runtime's refusal is the legacy failure document, with its code and words and nothing on stderr |
| `legacy_json.rs::runtime::a_wait_prints_only_the_settled_status_and_exits_by_it` (macOS) | A failed Job's wait prints its legacy document, exits 1 and writes one stderr line |
| `job_wait.rs::the_legacy_json_stream_prints_only_the_settled_status_document` (macOS) | The events path under `--json` prints no row, only the settled status's legacy document |
| `job_submit.rs::submit_builds_the_same_request_as_plan_and_names_itself` (extended) | The generated-identity note is announced in the human rendering only, not under `--output json` or `--json` |
| `debug_probe.rs` (tightened) | The legacy `--json` answer is compared byte for byte, where it was only parsed |
| `foundation_json.rs` unit test (new) | Where the spelling turns exponential, both ways, independent of the CLI |

## Mutations

Each mutation changed one line of the source and ran the tests that
concern it. Afterwards the file was restored and checked against its digest.
All 14 were killed (`/private/tmp/arkdeck-lj-mut.log`).

| Mutation | Killed by |
| --- | --- |
| The exponential spelling from 1e-5 down, not 1e-4 | the `foundation_json` unit test; the oracle replay |
| The exponential spelling from 1e16 up, not above 2^53 | the `foundation_json` unit test; the oracle replay |
| 2^53 itself spelled exponentially | the `foundation_json` unit test |
| `--json` taken on every leaf | the sweep; the refusal test (`debug template list`) |
| `--json` taken beside `--output` | the sweep; `debug_probe.rs` |
| No refusal in the legacy rendering at the parse | both refusal tests |
| A legacy refusal wherever `--json` appears, whatever Swift's registry says | both refusal tests |
| The legacy document without its LF | the oracle replay; the refusal test; the fake-Runtime tests |
| The legacy failure carrying `details` | the oracle replay; the refusal test; the fake-Runtime tests |
| The answer written as compact JSON | `debug_probe.rs`; the wait tests; the fake-Runtime tests |
| A refusal after the parse written as prose | the fake-Runtime refusal test |
| A refusal at the parse written as prose | both refusal tests |
| Stream rows printed under `--json` | `job_wait.rs`'s legacy stream test |
| The submit note announced under `--json` | `job_submit.rs` |

A person's prompt under `--json` has no test of its own. It is printed only
in the human branch, and the legacy branch that replaces it under `--json` is
the one the fake-Runtime refusal test reaches.

## Local targeted checks

Logs are under `/private/tmp/`. The first row ran before the rebase onto
`6c173b8a5` (#2179, CLI only); the rest ran after it.

| Check | Command | Result |
| --- | --- | --- |
| Before the rebase | clippy `-D warnings` for `arkdeck-contract`, `-hoststore`, `-cli`, `-agentd`, `-client`, `-control`, `-provider-hdc`, `-provider-arkforge` and `-soak`, `--all-targets`; `cargo test --no-fail-fast` for contract, hoststore, cli and agentd | exit 0 each. hoststore 601 passed (14 ignored); agentd 166 passed. Hoststore and agentd are unaffected by the rebase and by later test-only edits (`arkdeck-lj-*.log`) |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-lj2-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-contract -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-lj2-clippy.log`) |
| Contract tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-contract` | exit 0: 59 passed, none failed (`arkdeck-lj2-test-contract.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 301 passed, none failed (`arkdeck-lj2-test-cli.log`) |
| Swift oracle | `ARKDECK_RUST_LEGACY_JSON_RECORD=/private/tmp/arkdeck-lj-oracle-2 sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLILegacyJSONOracleContractTests`, then the same without the variable against the checked-in copy | exit 0 both; 1 test, 0 failures (`arkdeck-lj-swift-compare.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`, exit 0 (`arkdeck-lj-readonly.log`) |
| Audit | `cli-parity-audit.py <this build>` | 174 / 53 / 14 / 15; 134 of 209 leaves served (`arkdeck-lj-audit.md`). The last recorded figures (#2180) were 171 / 56 / 14 / 15 and 131. #2178's three continuation leaves make the difference; this slice serves no new leaf |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-lj-sdd.log`) |

Not run: `generate-contract.py --check`, because no contract input changed.

While probing refusal renderings, `runtime service update --json` and
`runtime service verify --json` from this build were each run once against
this host. `update` refused at its signing-receipt precondition before
changing anything (exit 69). `verify` read the installed Runtime and
reported `ContractMismatch`. Nothing was installed, booted out, loaded or
restarted. Later probes used only argv that the parser refuses, or a
`--socket` that does not exist.

## CI

- #2179 after its replay (head `96ce83119`): `guard` (run `36113478124`)
  and `swift` (run `36113478155`) passed, and so did all four Rust lanes.
  `swift-tests` was not selected. It merged as `6c173b8a5`.
- This PR: pending.
