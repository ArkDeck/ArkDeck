# TASK-XPA-014 — what Swift's `debug.probe` and `debug.template.run` answer over the shared fake HDC, recorded for the Rust port (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `64ff5380` (#2094); no stack. This is a Swift-only contract slice of milestone
M2, recorded once from Swift under r11 rule 10, so the Rust slice that replays it changes no Swift
file. It changes no production Swift source, no Rust code and no schema. Every answer here comes from
the production `FoundationDebugRuntimeProbe` over the shared fake HDC in a contract test; nothing is
device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| The Swift probe (`DebugRuntimeProbe.swift`), the daemon's two routes, the committed schemas and a corpus recorded over test doubles; the shared fake HDC and the oracle harness | `DebugProbeOracleContractTests`: both methods through the daemon's handler over the fake, 23 frames; the oracle `rust/tests/fixtures/debug-probe`; 6 corpus lines for the shapes no frame had recorded; the finding that the schemas already admit every answer | The Rust routes for both methods, replaying this oracle (the Rust control layer still answers them with the foundation's `rejected`); the Rust CLI has no leaf for either |

## Why

`debug.probe` and `debug.template.run` are the two read-only Debug Runtime probes of M2. Neither
creates a Job or a capability, and no oracle recorded them: the committed corpus comes from test
doubles inside `DiagnosticsAndHAPContractTests`, with a fabricated target and binding revision. The
Rust port needs what the production probe answers over a real transport, and the M2 map
(2026-09-15) predicted two schema gaps that had to be proven or refuted before the port.

## The test

`DebugProbeOracleContractTests` composes the daemon's control-plane handler with the probe the
daemon composes beside a started HDC server host (`FoundationDebugRuntimeProbe` over
`FixedExecutableResolver` and `FoundationRockchipRuntimeCommandRunner`), the harness's Target store
with one adopted target, and the shared fake HDC. The harness gained one optional parameter for the
probe; no other oracle changes.

Two things this oracle had to fix to be reproducible:
- **The working directory.** The probe's runner binds every child to a product-owned directory, and
  `ArkDeckProcess` requires that path to resolve to itself. `/private/tmp` does not (it resolves to
  `/tmp`), so a child bound there never launches: the probe would answer, with every read lost, a
  portrait of nothing. The oracle binds a directory under this user's caches and removes it
  afterwards; no answer reaches it. Each case also asserts what it was recorded for, so a silent
  loss of the reads fails the test instead of recording it.
- **The call log.** The shared driver records a call as two appends — its arguments, then a newline
  — and the probe's three reads run concurrently, so the newlines land against other calls and the
  driver's `hdc-invocations.log` is not stable across runs. This oracle's own answers append one
  line per call (`hdc-calls.log`, a single write), and the fixture keeps each exchange's calls
  sorted. Two comparison runs over the committed fixture agree.

## What is recorded

23 exchanges, in the fake's mode each names:

| Case | Answer |
| --- | --- |
| `probe.full` | both packages sorted, the forward rule then the reverse rule, no warnings |
| `probe.packagesUnavailable` | `bm dump -a` exits non-zero: `packageInventoryUnavailable`, the rules kept |
| `probe.packagesUnparseable` | output naming no bundle: `packageInventoryUnparseable` |
| `probe.forwardUnavailable` | `fport ls` exits non-zero: `forwardRulesUnavailable`, the reverse rule kept |
| `probe.reverseUnavailable` | `rport ls` answers HDC's offline marker, which the read-only receipt validation refuses: `reverseRulesUnavailable` |
| `probe.allUnavailable` | all three lost, the three warnings sorted |
| `probe.unadopted` | `rejected` "Debug Runtime probe failed: target … has not been adopted" |
| `probe.noParameters`, `probe.extraKey` | `invalidParams` "Debug Runtime probe accepts only targetId" |
| `probe.emptyTarget`, `probe.longTarget` (129 bytes) | `invalidParams` "targetId must be a bounded durable target identity" |
| `template.packages`, `.parameter`, `.windows`, `.uptime` | each template's own command, exit 0, its disclosed argv with the connect key redacted, its lowering digest, 12 ms |
| `template.failingExit` | exit 7 with the command's diagnostic on stderr — the probe reports it, it is not a refusal |
| `template.killed` | the child dies on signal 9: `rejected` "Debug template failed: outcomeUnknown(…)" |
| `template.truncated` | output past the parameter template's 4 KiB budget: `outputTruncated` true |
| `template.notUTF8` | output that is not UTF-8: `rejected` "Debug template failed: Debug read-only template output is not UTF-8" |
| `template.unadopted` | `rejected` "Debug template failed: target … has not been adopted" |
| `template.unknownTemplate`, `.noParameters`, `.noTemplate` | `invalidParams` "targetId and a closed templateId are required" |

A request the schema itself refuses (`targetId` as an integer) is deliberately not recorded: it
would put a line in the corpus that its own schema refuses, and the derivation would widen the
request to admit it. The Rust replay covers that refusal on its own.

## The schemas: nothing to widen

The M2 map predicted `debug.template.run` would need a null `exitCode`, "because Swift sends null on
a timeout". The recording refutes it. `FoundationRockchipRuntimeCommandRunner` returns a receipt only
for `.exited`; a timeout, a cancellation, a signal death and an unresolved wait status each throw
`RuntimeDispatchFailure.outcomeUnknown`, which the daemon answers as `rejected`. `template.killed`
records exactly that. Through the production composition `exitCode` is always an integer, and the
committed schema is right as it stands.

Checked rather than argued:
- Every one of the 23 recorded frames and all 12 corpus lines of the two methods validate against
  the committed schemas (jsonschema 4.26): 70 values, 0 refusals.
- A derivation from every committed corpus plus these frames
  (`generate-control-contract.py --derive-method-schemas`) produces, for both methods, `$defs` byte
  identical to the committed ones; only `x-arkdeck-sampleCounts` moves. That derivation also
  rewrites the other 103 methods from their corpora alone, which narrows some of them (the #1925 and
  #1929 trap), so it was run as a check and reverted; the corpora here are the committed lines
  verbatim plus one frame per shape the corpus lacked.

The corpora grow by 6 lines: 2 for `debug.probe` (the unadopted target, the bounded-identity
refusal) and 4 for `debug.template.run` (the unadopted target, the lost outcome, the non-UTF-8
output, and a request carrying only `targetId`). `rust/scripts/generate-contract.py --write` then
refreshed the manifest: 105 methods, 910 recorded shapes (904 before), contract identity unchanged.

## Checks

Commands in this worktree on 2026-09-20 CST. The logs are in
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-native-library-plan-admit-run-ddd5a8/0a1d0f2a-9a16-4e9a-9a87-e55bd44a6bc7/scratchpad/logs/`.

| Check | Command | Result |
| --- | --- | --- |
| The recording | `ARKDECK_RUST_DEBUG_PROBE_RECORD=<fresh> ARKDECK_CONTROL_FRAME_LOG=<fresh> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter DebugProbeOracleContractTests` | 1 test, 0 failures; 23 frames; the oracle's six files |
| The oracle is stable | the same test twice with no record variable, over the committed fixture | 0 failures each (`debug-probe-compare-1.log`, `-2.log`) |
| Schemas and frames, Swift | `ARKDECK_CONTROL_FRAME_LOG=<the 23 recorded frames> … --filter 'ControlMethodSchemaContractTests\|DebugProbeOracleContractTests'` | 6 tests, 0 failures: the seeded frames and the 23 this run re-recorded validate against the committed schemas |
| Frames and corpora, jsonschema 4.26 | every recorded frame and every corpus line of the two methods against the committed schemas | 70 values, 0 refusals |
| Derivation | `generate-control-contract.py --derive-method-schemas <every committed corpus + these frames>`, then reverted | both methods' `$defs` byte identical to the committed ones; only `x-arkdeck-sampleCounts` moves |
| Rust manifest | `python3 rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 910 recorded shapes, identity unchanged; `--check` passes again after the rebase onto `64ff5380` |
| Rust contract and control | `cargo test --locked -p arkdeck-contract -p arkdeck-control` | 36 passed, 0 failed (corpus parity included); no Rust source changed |
| Records | `sh scripts/check-sdd.sh` | 0 errors, 0 warnings, 121 acceptance IDs |

Before the fixture was stable, two earlier recordings were discarded: one where every read was lost
to the refused working directory, and one whose call log differed between runs. Both are described
above; the test now asserts the first and records the second's calls itself.

## Not run

- The Rust routes and their replay of this oracle: the next slice.
- `debug.start`, `debug.status` and `debug.evaluate`: the Flash recovery broker, M4 behind design
  §L.1 item 13.
- Any device, real HDC server or the installed Runtime.
