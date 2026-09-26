# The durable Rockchip host's typed actions and write-ahead records (TASK-XPA-017, F6 S5)

This slice ports three parts of Swift's Rockchip runtime host to
`arkdeck-hoststore`:

- the typed Rockchip provider action and its persisted form;
- the record store that keeps each action's write-ahead records;
- the durable host that runs an action only behind those records.

The executor that talks to HDC and RockUSB is a trait here. No production
code calls the durable host yet; the executor and the dispatcher that routes
a host-managed step to it come with S6. The Flash planner now uses the typed
action and the store's own availability check.

Developed on protected `main` `952e28604` (#2251), then rebased onto
`20130b631` (#2252 and #2254, which change none of this slice's files). After
the rebase, fmt, clippy (`arkdeck-hoststore`, `-agentd`), the Rockchip unit
tests and the flash-plan and Flash run replays were run again. No contract
input, Catalog or `tasks.md` changes. No device, and nothing here is device
evidence.

## What is ported

### `rockchip_action`

Swift `RockchipProviderAction`, `PersistedTypedProviderAction` and
`RockchipHostManagedActionCatalog`.

- **Ten actions.** Two are device mutations (`enterLoader`,
  `rebootToNormal`); the rest are read-only. Each has its catalog identifier
  and its persisted form, `{kind, arguments}`.
- **`sha256()`** is the digest of the persisted form's canonical JSON, which
  the host-managed descriptor pins.
- **`descriptor(...)`** builds a step's host-managed descriptor. **`matches`**
  checks the identifier, and the connect key or identity the action names,
  against the descriptor.
- **`from_persisted`** is Swift `materialize()`. It decodes every kind and
  refuses in Swift's words:
  - the legacy in-process write intent (`rockchip.flashPartitions`);
  - the retired `rockchip.verifyBuild`;
  - an unknown kind;
  - a missing or mistyped argument;
  - an invalid HDC binding expectation;
  - a capture request out of bounds.
- **`CaptureRequest`** allows 1–600 s, at most 16 filters of bounded ASCII
  tokens, and a budget of 1 KiB–128 MiB. Its errors read as Swift renders
  them. The command timeout is the duration plus 15 s, never under 45 s.
- **The Flash planner uses this type.** Its private copy of the eight actions
  it names is removed. The digests of its descriptors are unchanged: the
  flash-plan oracle replays green.

### `rockchip_records`

Swift `RockchipRuntimeActionRecordStore` and
`DurableRockchipRuntimeActionHost` (`RockchipRuntimeActionHost.swift`).

Records live under `<state>/rockchip-runtime/<job>/<step>/`: `intent.json`
before the action runs, `receipt.json` after it. Each is canonical JSON,
owner-only (0600 files in 0700 directories), written to an exclusive
temporary file, synchronized, renamed, and its directory synchronized.

The host follows Swift's order:

1. **The descriptor must hold.** It needs a positive binding revision, a
   lowercase SHA-256 identity, and the provider executable's digest. The
   action's digest must be the descriptor's, and the action must match it.
   Otherwise nothing is written.
2. **Job and step ids** must be bounded path components.
3. **A new step:** its intent is made durable, the executor runs, then the
   receipt is written. The result's summary names the receipt (`recordID`).
4. **An existing step:** the intent on disk must be the same record. A
   receipt of this step is replayed (its summary, no streams, no
   subprocesses), and nothing runs.
5. **No receipt:** a read-only step runs again. A device mutation is an
   unknown outcome and is never resent.
6. **Drift or an unreadable record** refuses: failed for a read, unknown for
   a mutation.
7. **A receipt that cannot be made durable** after the action ran is unknown
   for a mutation, since its effect happened, and failed for a read.

Checks use Swift's Characters. A digest is 64 lowercase hexadecimal
Characters, fullwidth digits included, as `Character.isHexDigit` admits
them. Summary keys and values are bounded in grapheme clusters.

`unavailable_reason` is the executor's, then the record root's.

### Declared differences

- **A record that does not decode** is refused as "the Rockchip record does
  not decode", not with Swift's `DecodingError` description.
- **The root's standardization.** Swift compares the root with its
  standardized form, and Foundation strips `/private` from an existing
  `/private/tmp/…` path, so Swift refuses such a root once it exists. This
  port requires an absolute path spelled exactly as its components rebuild
  it, and does not strip `/private`. The Flash planner's check already did
  this; it is unchanged.

### Not in this slice

- **The executor and the dispatcher** (S6).
- **Swift `flashPostflightObservation(for:)`.** This read-only projection of
  the record store is what `evidenceSnapshot` falls back to when a Flash Job
  has no evidence observation. The Rust Flash run sets that observation
  itself (`publish_postflight_facts`). Whether any Flash record reaches
  `job.evidence` without one is checked with S6.

## Tests

- **`rockchip_action`, 6 tests:**
  - the persisted form and digest of the two actions Swift's own records hold
    in the Loader binding oracle;
  - every action's round trip;
  - the catalog identifiers and effects;
  - the descriptor match;
  - `materialize()`'s refusals in Swift's words;
  - the capture timeout.
- **`rockchip_records`, 12 tests:**
  - write-ahead, then replay;
  - the records byte for byte Swift's (`record-reconcile-intent.json` and
    `record-reconcile-receipt.json` of the Loader binding oracle);
  - the reactivation proof reader (`rockchip_reactivation.rs`) takes what
    this host writes as its proof;
  - a read reruns without its receipt, a mutation does not;
  - drifted intents, invalid receipts, unreadable records;
  - a receipt that cannot be persisted;
  - descriptor checks that write nothing;
  - an executor's failure;
  - the unavailable reasons;
  - Swift's Character semantics.
- **Mutations.** Eight hand mutations of the record store, each killed:
  - a mutation rerun without its receipt;
  - intent drift ignored;
  - replay without `recordID`;
  - a receipt's identity ignored;
  - a persistence failure always failed;
  - path components unchecked;
  - no intent before execution;
  - counts in scalars.
- **Existing replays.** The flash-plan oracle (`tests/flash_plan.rs`) and the
  Flash run stories replay unchanged.

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target`, `CARGO_BUILD_JOBS=2`. Logs are under
the session's scratchpad `s5-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`: `arkdeck-hoststore` and its dependents `-agentd`, `-soak` | exit 0 (`clippy.log`) |
| `cargo test -p arkdeck-hoststore` | exit 0: 682 passed, 18 ignored, in 89 test binaries. The library's 363 unit tests include the 18 new ones; the binaries include the flash-plan oracle and the Flash run stories (`test-hoststore.log`) |
| `cargo test -p arkdeck-agentd` | exit 0: 187 passed in 22 test binaries (`test-agentd.log`) |
| the eight mutations | each caught as above; the restored tree passes (`mutations.log`) |
| `sh scripts/check-sdd.sh` | exit 0 (`check-sdd.log`) |
| after the rebase: fmt; clippy `arkdeck-hoststore`, `-agentd`; `--lib rockchip_`, `--test flash_plan`, `--test flash_run` | exit 0 each: 18, 2 and 12 passed (`rebased-*.log`) |

Not run:

- **Cross clippy.** Every changed file compiles only on macOS
  (`cfg(target_os = "macos")`).
- **`arkdeck-soak` tests.** Nothing of it changed or calls the new modules;
  its clippy above compiles it.
- **Swift.** Nothing of it changed.
- **`generate-contract.py --check`.** No contract input changed.

**CI.** Pending.

The CI of #2252 (S1) was green before it merged as `f9d6cac06`.
