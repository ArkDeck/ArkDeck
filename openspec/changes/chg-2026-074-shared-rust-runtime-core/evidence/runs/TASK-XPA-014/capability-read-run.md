# Rust capability reads — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `6b7a79e3`. The slice was written on
`2b7c1405`, after #1900 (the cancellation of a running analyzer Job) and #1901, and rebased onto
#1902, #1903, #1904, `6cf99fb6` and #1906 once its gate had run (see the gate section). This slice
lets the isolated Rust development composition
answer `capability.list` and `capability.inspect` from a Runtime capability store as the Swift
daemon answers them. It only reads: nothing installs, mints, reserves or consumes a use, and
nothing installed changes. Every capability in the oracle and the harness is synthetic, written by
Swift's own store API into temporary directories, as the maintainer allowed on 2026-09-14; nothing
here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan`, `job.submit`, `job.run`, `job.result`/`job.evidence`, Session publication and `job.cancel` (a running Job included) for the analyzer (#1892–#1900). Rust admission refuses every effect above `readOnly` and never opens a capability store | Reading the Runtime capability store: `CapabilityStore` (the checkpoint and the ledger replayed under the store's lock, Swift's strict JSON check, the current-shape decode with each capability's model invariants, accounting, lineage and digest validation, Swift's error renderings), the host hook and routes for `capability.list`/`capability.inspect`, the Rust CLI's `capability list|inspect`, a Swift-recorded oracle of 42 stores, both method schemas re-derived from it, a real-process harness | Capability writes (install, consume, outcome, revocation) and the authorization ledger written by Rust; capability-bearing admission (`validateNewExecution`, the Runtime-issued capability); execution of every other operation; the §G.4 preflight's check for reserved-but-unsettled uses; recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling); GJ-1..5 |

## Behaviour

Swift answers both methods in `AgentDaemon.swift` (879–913). `capability.list` ignores its
parameters and answers one row per capability: identity, effect ceiling, maximum and remaining
uses, consumption count, whether the lineage allows a new execution and the lineage blocker.
`capability.inspect` needs a string `capabilityId` (`invalidParams` "capabilityId is required"),
answers `notFound` "unknown capability", and otherwise encodes the capability's
`RuntimeCapabilityStatus`: the whole capability, its uses and their outcomes, and the blocker, a
member only when there is one. Any store error is `internalError` with Swift's interpolation of
the error. The store (`ArkDeckStorage/RuntimeCapabilityStore.swift`) serves every call under a
blocking `flock(LOCK_EX)` on `.runtime-capabilities.lock`, created 0600. Its `loadDocument` reads
the checkpoint (`loadCheckpoint`: either file a symbolic link is refused, a missing checkpoint is
an empty store unless a ledger exists, then `StrictJSONDuplicateValidator`, the `CurrentDurableJSON`
decode of the exact current shape and `validate`), then every complete ledger line, each decoded
the same way, replays them and validates the result again.

`CapabilityStore` (`arkdeck-hoststore/src/capability_store.rs`) is that read in Rust:

- `HostDirectory::wait_lock` holds the same lock file with the same blocking `flock`.
- `strict_json.rs` ports `StrictJSONDuplicateValidator`: its messages, its byte offsets, its
  `$.records[0].remainingUses` paths, and names compared by canonical equivalence as Swift's
  `Set<String>` compares them (through the macOS host's `CFStringNormalize`).
- The typed decode follows Swift's member order and reports Swift's `DecodingError` descriptions
  (`keyNotFound`, `valueNotFound`, `typeMismatch`, `dataCorrupted`, with their coding paths); a
  capability is decoded as `RuntimeCapability.init(from:)` decodes it, its model invariants
  (`RuntimeCapability.validate()`) and its exact field shape included, and the document and each
  ledger event must be exactly what the typed values encode back to.
- The replay and `validate` port Swift's refusals word for word: unknown capabilities, event kinds
  and reservations, use accounting, lineage order, and the receipt and outcome digests (SHA-256
  over Foundation's canonical encoding of the material).
- The answers are built from the typed model as Swift encodes it.

`arkdeck-control` routes both methods to a new `capability_resource` hook, which a host without a
store answers as the read-only foundation always has. `arkdeck-agentd` composes the store beside
the isolated owner's Job state, `<root>/jobs-state/capabilities`, as the Swift daemon keeps
`<state>/capabilities` beside its Job state, and creates it 0700 at startup as Swift's `init` does.
It is no facade-local method: the Swift daemon behind a facade keeps its own store, and two
processes holding one store lock is a stop condition. The Rust CLI gains `capability list` and
`capability inspect --capability <id>`.

Found on the way, recorded by the oracle:

- Swift's interpolation escapes `'` in a string payload (`Key \'remainingUses\' not found`).
- Foundation takes `2.0` for an `Int` member, and refuses `2.5` for the whole document ("The given
  data was not valid JSON.. Underlying error: … Number 2.5 is not representable in Swift.") at no
  coding path. `JSONValue` holds `2.0` as the integer 2.
- A null optional member inside a capability fails the capability's own shape check
  ("unsupported current capability field shape"); anywhere else it fails the document's
  ("record does not match the current durable field shape").
- The contract derivation closes every object to the member names it recorded, and the Rust schema
  validator accepts only a boolean `additionalProperties`: a capability's `inputConstraints`,
  `exactInputs` and `exactArtifactFacts` are published with the names the oracle records, as
  `job.show` publishes a Job's inputs.

Deliberate differences from Swift:

- The refusal of a fractional number quotes serde's spelling of it; Foundation quotes the
  document's.
- Operating-system error texts are Rust's: an unreadable checkpoint or ledger (`cannot read
  capability store: …`, `cannot read capability ledger: …`) and a directory that cannot be made.
- A lock file that is not a private regular file with one link is refused ("cannot open capability
  store lock"), where Swift would open it.
- With several invalid input-constraint names, Swift reports whichever its dictionary yields
  first; Rust reports the first in byte order.
- The Rust control layer answers `internalError` "the result does not conform to the current
  contract" for a capability whose input maps name members the published schema lacks, until the
  derivation learns map-valued members; the Swift daemon validates no answer.

## Shared oracle

`rust/tests/fixtures/capability-read/` was recorded by Swift
`CapabilityReadOracleContractTests.testSwiftReadsTheSharedCapabilityOracle`
(`ARKDECK_RUST_CAPABILITY_READ_RECORD`, at `/private/tmp/xpa014-capability-read-oracle-r2`; r1 at
`-r1` recorded the first 34 scenarios, and r2 added the eight number, null and nested-type
defects). Each scenario's store is built in a temporary directory, then read through the daemon's
control plane by a store opened afresh over it.

| File | Content |
| --- | --- |
| `cases.json` | 42 scenarios and their 93 reads with Swift's answers, each store's directory spelled `<store>` |
| `tree.json` | the kind, mode and size of every store entry before and after the reads (a symbolic link by its target) |
| `stores/<scenario>/` | every store file as the reads found it |
| `provenance.json` | the recording test, the clock, the label and `checkpointEveryEvents` (128) |

Scenarios written by the Swift store's public API: `empty` (the reads create the lock),
`installedOnly` (a checkpoint and no ledger), `emptyLedger` (an install after a use emptied the
ledger), `ledger` (six capabilities: a device standing grant with every input-constraint kind, a
destructive Runtime-issued capability with exact inputs, Artifact facts, plan and binding, a
standing workspace grant, a revoked grant, an `outcomeUnknown` use, and a capability with 60 uses
whose 129th appended event rewrote the checkpoint; every outcome state, including an
`outcomeUnknown` later confirmed and one resolved as `safeToReflash`), and `base` (a lineage in the
checkpoint and three events in the ledger). The other 37 are `base` with one defect: a torn final
append; a missing or linked checkpoint; a linked ledger; a duplicate member; truncated and
trailing JSON; an unknown document or capability member; a broken invariant, an unknown effect,
target kind and an unsupported effect ceiling; a missing, null or mistyped member; a null optional
inside and outside a capability; `2.0` and `2.5` for an `Int`; an unsupported schema version; a
duplicate capability; inconsistent accounting; lineage order; receipt and outcome digests and an
outcome transition; and ledger events that are garbage, carry an extra member, name an unknown
kind or capability, lack their use or record, settle an untaken reservation, replay a reservation
or break the lineage.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust reads | `cargo test -p arkdeck-hoststore --test capability_read` | 1 passed: all 93 answers, every store's entries after the reads, and every store file byte-identical afterwards |
| Strict JSON port | `cargo test -p arkdeck-hoststore --lib strict_json` | 3 passed: Swift's messages and offsets, escaped names, Swift's quoting |
| CLI | `cargo test -p arkdeck-cli --test capability_resources` | 3 passed: both current Swift argv fixtures, and neither command takes a wait bound |
| Workspace | `cargo fmt --all`; warnings-denied Clippy and `cargo test` of `arkdeck-hoststore`, `-control`, `-agentd`, `-cli` and `-contract` | passed: 405 tests in 52 test binaries, none failed |
| Swift oracle | `run-swiftpm.sh test --filter CapabilityReadOracleContractTests` | r1 and r2 recorded (1 executed, 0 failures each); the compare run in a new process together with `ControlMethodSchemaContractTests`: 5 executed, 1 skipped (it checks a frame log only when one is recorded), 0 failures |
| Real processes | `python3 rust/scripts/check-capability-read.py --swift-bin-dir <run-swiftpm debug products>` | r1 PASS, 418 checks. With every oracle store placed where each daemon keeps its own (the standalone Swift daemon's `<state>/capabilities`, the Rust owner's `<root>/jobs-state/capabilities`, both created at startup), the Swift daemon answers all 93 reads as the oracle recorded them and the Rust owner answers each as the Swift daemon did, each store's directory spelled `<store>` whether the daemon names it under `/private/tmp` or `/tmp`; both leave every store as the oracle's reads left it; and both CLIs end the same five reads (a list and an inspection of a populated store, an absent capability, a corrupt store, an empty store) with the same exit and answer or error code. Summary: `/private/tmp/xpa014-capability-read-harness-r1.json`, SHA-256 `62763c245d5cbe9f1088b817274b479e9e41a886f439dd70e58f5ef4d6abec9b` |
| Contract derivation | `generate-control-contract.py --derive-method-schemas` over the committed corpus of both methods and the 93 recorded frames, their store paths labelled and pruned to the shapes the corpus lacked | 50 frames with new shapes; one 64 KiB `capability.inspect` frame was dropped, since a 4 KiB one has its shape and the schemas derive identically without it. `capability.list` publishes a string blocker; `capability.inspect` the whole capability and lineage. Corpus: `capability.inspect` 3 → 11 lines, `capability.list` 2 → 5. `rust/scripts/generate-contract.py --write` refreshed the checkout manifest (105 methods, 638 recorded shapes) |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. It ran on `7f3f9fb6`, this slice on `2b7c1405` before the gate result was added here.
Against merge base `2b7c1405` the planner classified the 146 changed files and selected the common,
design-system, Swift and Rust lanes (no App build).

- r1, `/private/tmp/xpa014-capability-read-gate-20260914-r1.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,662 tests exit 0 (`CapabilityReadOracleContractTests` and
    `ControlMethodSchemaContractTests` among them), `full-process-identity-race` 1 test exit 0,
    `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny`
    (advisories, bans, licenses and sources ok) and `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `54b92fd68397467960ba58573caa987f8adc0e36faa8c6fd1910cd77dd4e3656`.

The slice was then rebased onto `6b7a79e3` without a conflict; `rust/README.md` merged beside
#1903's paragraph. #1903 made a released owner lock unlock before its descriptor closes, which the
store's lock now does too. On the rebased tree:

- `cargo fmt --all --check`, warnings-denied Clippy and `cargo test` of `arkdeck-hoststore`,
  `-control`, `-agentd`, `-cli`, `-contract` and `-platform`: 501 tests in 63 test binaries, none
  failed.
- `check-capability-read.py` r2: PASS, 418 checks; summary
  `/private/tmp/xpa014-capability-read-harness-r2.json`, SHA-256
  `c93f494b25afb60793f35c4cb0ea2983abc06ba407d085f9887ef17960c6b421`.

The unified gate was not re-run after the rebase; CI runs its lanes on the pushed commit.

## Not run, and why

- No capability write: install, consume, outcome and revocation bytes written by Rust are the next
  step (Swift-parity of the writer, as the journal and Job store writers were done), and no Rust
  process consumes a use until capability-bearing admission is ported.
- No installed composition: the methods are not served locally by a facade.
- No recovery: it waits for the L.1 item 13 ruling.
- `check-capability-read.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather
  than inside `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
