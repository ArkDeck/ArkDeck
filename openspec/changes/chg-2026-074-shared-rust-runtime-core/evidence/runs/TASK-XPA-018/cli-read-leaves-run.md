# TASK-XPA-018 — `runtime health` and `operation validate` on the Rust CLI (macOS, 2026-09-20)

TASK-XPA-018 remains in progress. Base: protected main `7c10f9f3` (#2086); no stack. Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
entitlement, `openspec/contracts`, `openspec/specs` or constitution change.

The first two leaves of the audit's category 2 group that reads over methods the isolated daemon
already routes. Both are read-only, neither touches a device, and both answer from what the Runtime
publishes rather than from the catalog compiled into this binary.

## What changes

- **`arkdeck runtime health`** sends `health` and answers the Runtime's own health document. The
  contract preflight *is* the call: `Client::health` exchanges the health frame, validates it
  (`validate_health`: the six published fields, `status`, the protocol version, the contract
  identity, the published method set, a lowercase digest and non-empty providers) and answers it,
  the way Swift's client skips its preflight for `health` alone
  (`verifyContract: method != "health"`). A health document off the contract is therefore this
  read's own malformed answer — `protocolMalformed`, exit 70, as Swift maps `malformedResponse` for
  a bounded read-only method — and not the `protocolVersionUnsupported` (69) that a *preflight*
  failure earns every other leaf. The leaf sends no parameters and takes only the client options.
- **`arkdeck operation validate --operation <reference> --inputs-file <path|->`** answers what the
  published descriptor fully describes, in Swift's order (`RuntimeCLI.emitOperationValidation`):
  1. `operation.describe` with `{"reference": …}` — asked before the file is read, so a caller with
     an unreadable file and an unknown operation hears about the operation first;
  2. the typed inputs are read as one bounded UTF-8 JSON document (`boundedInputDocument`): 3 MiB,
     no byte order mark, no repeated key — the repeat is found by scanning the text, because by the
     time a map exists the duplicate is already gone and which value survived would depend on the
     parser rather than on the document the caller wrote. `-` reads one document from stdin;
  3. the descriptor's published field list judges the document
     (`CLIOperationInputValidation.findings`), in the descriptor's order, then the supplied keys it
     does not declare, sorted: `notAnObject`, `missingRequired`, `unknownField`, `typeMismatch`
     (which decides alone — every other check reads the value as its declared type), `notInEnum`,
     `patternMismatch`, `outOfRange`, `tooLong` (unicode scalars) and `tooManyItems`, each with
     Swift's message;
  4. `health` on the same connection names the digest that judged them; a Runtime that cannot name
     it leaves `runtimeCatalogDigest` null rather than making the structural answer wrong.
  The one document it emits is `{reference, structurallyValid, findings, checkedAgainst}`, and it is
  emitted whatever the findings say — the caller asked what the descriptor says, and it answered.
  Findings are reported after it: `invalidInput`, exit 65, `<n> input problem(s) for <reference>`,
  with the `ok:true` document still the only thing on stdout.
- **The patterns** a descriptor may publish are matched by hand from a closed vocabulary, which is
  how `arkdeck-contract`'s schema compiler answers the same question (`schema_patterns.json`): this
  CLI has no regular-expression engine. `catalog_patterns_are_all_matched_by_hand` keeps the
  vocabulary closed against the compiled catalog, so a catalog that publishes a new pattern fails
  there rather than passing quietly.
- **`support::run_session`** (tests): a fake Runtime that serves one connection and the exchanges
  the test names, in order, and fails the test on any other request or a second connection. The
  existing `support::run` serves one request per connection, which neither of these leaves does.

## Declared differences from Swift

- **A descriptor with no input contract cannot reach its guard.** Swift answers `recordUnreadable`
  (exit 2, `the Runtime published no input contract for <reference>`) when the descriptor has no
  `inputs` array. The published `operation.describe` result requires `inputs`, and this client
  validates every result against the method's schema, so such a descriptor is refused as a malformed
  answer (`protocolMalformed`, 70) before the leaf sees it. Swift's guard is ported and kept for the
  day that contract loosens; the test pins what actually happens today.
- **An unknown field pattern passes.** A pattern outside the checked-in vocabulary is not judged,
  which is Swift's own answer for a pattern its build cannot compile: reporting it would refuse a
  document the Runtime accepts. The difference is that Swift compiles most patterns and this build
  compiles none, so the vocabulary test above is what keeps the gap from opening silently.
- Inherited, not new here: this CLI renders human output as the pretty-printed answer rather than
  Swift's prose, and bounds its connection where Swift leaves the business request unbounded.

## Tests

| Test | What it holds |
| --- | --- |
| `runtime_health.rs` | `runtime health` is exactly one exchange and answers the Runtime's document in Swift's envelope; a document off the contract is `protocolMalformed`, exit 70 |
| `operation_validate.rs` | Against the descriptor Swift recorded for `input.swipe@1` (`Fixtures/ControlFrames/operation.describe.jsonl`): a document it accepts is `structurallyValid` and names the digest; findings are reported after the answer and decide exit 65; the document is read only after the descriptor answers; `-` reads stdin rather than a file called `-`; a Runtime that cannot name its digest still answers; a descriptor without `inputs` (the difference above) |
| `operation_validation.rs` (unit) | Every finding code against one descriptor, including the order of unknown fields and that a type mismatch decides alone; the nine catalog patterns accepted and refused by what each says; the closed vocabulary pinned against the compiled catalog; the bounded document's six refusals, including a repeat a parser would resolve silently and a brace inside a string that is not structure; the emitted document and its singular/plural report |
| `argv_fixtures.rs` (existing) | Both leaves' Swift argv fixtures are copied in and replay: 103 fixtures, 619 cases, with the two pinned `--socket` cases unchanged |

## Local targeted checks

Run 2026-09-20 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli -p arkdeck-client --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 181 passed, 0 failed |
| The client suite | `cargo test -p arkdeck-client` | exit 0; 10 passed, 0 failed |
| The audit, rewritten from this head | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | the tables of `cli-parity-audit-20260919.md`: 144 / 57 / 40 / 15, 103 of 209 leaves served |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

Recorded once this PR's CI finishes.
