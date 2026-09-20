# TASK-XPA-018 — `device wait` on the Rust CLI (macOS, 2026-09-20)

TASK-XPA-018 remains in progress. Base: protected main `64ff5380` (#2094); no stack — `cli-read-leaves-run.md`
(#2091) is merged. Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001): the Runtime under test is
the fake one the CLI tests serve recorded answers from. No Swift source or test, control schema,
corpus, Catalog, entitlement, `openspec/contracts`, `openspec/specs` or constitution change.

The third leaf of the audit's category 2 group that reads over routed methods, and the first that
waits.

## What changes

**`arkdeck device wait --candidate <key> --observation <id> --observation-generation <n>
--state connected|unauthorized|offline [--timeout 30s]`** (Swift `RuntimeCLI.emitDeviceWait`).

- **Unary polling, never a stream.** Every read sends `device.observations` with
  `{"following": {candidate, observationId, observationGeneration}}` — the generation as the string
  the caller wrote — and asks the Runtime to prove that same observation again, even when the state
  already matched the caller's earlier discovery snapshot.
- **One connection per read, and one deadline over all of them.** Swift's client opens and closes a
  socket per request (`AgentClient.exchange`), so every read proves the contract again before it
  asks; this leaf does the same, which is what lets a Runtime that restarted mid-wait be proved
  again instead of ending the wait. `--timeout` (default `30s`, maximum 24h) bounds the whole wait,
  contract verification and IO included, and each read is bounded by what is left of it. The backoff
  is Swift's: 100 ms doubling to 2 s, each sleep capped by what is left.
- **Each snapshot is proved before anything is read from it**, in Swift's order: the snapshot's own
  shape, schema version, `health: current`, a non-empty timestamp, a canonical decimal generation
  that never moves backwards and at most 1000 rows (`protocolMalformed`); exactly one row for the
  candidate and observation, with the published key set, `observationContinuity: relationProven` and
  a display-name generation equal to the snapshot's (`resourceConflict`, with the observation as
  `details`); a supported authorization state; an adopted-target link that is either absent on both
  sides or exact on both; and a display name that is precomposed, trimmed, 1…256 UTF-8 bytes and
  free of control characters (`protocolMalformed`).
- **The wait ends only on the proved state**, and answers
  `arkdeck.device-wait/1` — `{schemaVersion, snapshotGeneration, observedAtUtc, state, observation}`,
  the state spelled as the caller spelled it and the observation the Runtime's own row. The deadline
  is checked after the row is proved and before the match, so a wait that ran out answers the
  timeout rather than a document it proved too late.
- **A wait that ends at its deadline says what it did not do**: `clientTimeout` (exit 75),
  `stopped waiting for the exact device observation; no adoption or cancellation was requested`,
  with `candidate`, `observationId`, `observationGeneration`, `requestedState`,
  `lastObservedGeneration` when at least one snapshot was proved, and `newDispatchCount: 0`.
- **The display-name rule is now shared** (`target_resources::display_name`, renamed from `text`),
  with the host's precomposition added here.
- `support::run_partial` (tests): the per-connection harness for a leaf whose own deadline may end
  the wait before it asks for every answer the test offers; it stops waiting for an exchange that
  does not come rather than holding the full accept window for each.

## Declared differences from Swift

- **Precomposition off macOS.** The canonical mapping is the host's
  (`arkdeck_platform::host_canonical_text`, CoreFoundation form C). Where this build has no host
  mapping, the other three parts of the display-name rule stand alone. The reads that already
  validated display names (`target list|show`, the display-name receipts) never checked
  precomposition on any platform; this leaf does on macOS, and reconciling the two is left to the
  slice that revisits those reads.
- **Connections per answer.** Swift opens a socket per request everywhere. This port matches that
  where it can be observed — each poll of a wait — and reuses one connection for the adjacent reads
  that make up a single answer (`operation validate`'s descriptor and digest, #2091), which is one
  socket and one contract preflight rather than two of each.
- Inherited, not new here: human output is the pretty-printed answer rather than Swift's prose.

## Tests

| Test | What it holds |
| --- | --- |
| `device_wait.rs` (fake Runtime, macOS) | Each read is its own connection, with its own contract preflight, which is what the harness serves; the recorded snapshot that proves `offline` ends the wait with the exact document; a snapshot in another state is read again; a replaced relation is `resourceConflict` (65) with the observation as details; a stale `health` is `protocolMalformed` (70); a wait that runs out answers `clientTimeout` (75) with `newDispatchCount: 0` and the generation it last proved |
| `device_wait.rs` (unit) | The proved row, generation and timestamp, and that a generation may not move backwards; every snapshot shape the published contract still admits; every row the contract admits but the lifecycle refuses, including both halves of the adopted-target link and four display names; the timeout's details with and without a proved generation; the parse's wire shape, its default timeout, and the five values the registry's grammars refuse |
| `argv_fixtures.rs` (existing) | The leaf's Swift argv fixture is copied in and replays: 104 fixtures, 626 cases |

## Local targeted checks

Run 2026-09-20 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 192 passed, 0 failed |
| The audit, rewritten from this head | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | the tables of `cli-parity-audit-20260919.md`: 146 / 55 / 40 / 15, 104 of 209 leaves served |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

Recorded once this PR's CI finishes.
