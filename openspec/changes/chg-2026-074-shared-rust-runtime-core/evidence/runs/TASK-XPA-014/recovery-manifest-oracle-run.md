# TASK-XPA-014 — recovery port, slice 1a: the recovery-manifest Swift oracle

Change: CHG-2026-074-shared-rust-runtime-core@r11. The maintainer (lvye) ruled design §L.1 item 13
on 2026-09-19: recovery is ported exactly as the carrier code named by
`evidence/adr-0009-decision-package-20260914.md` (its Ruling section). This is the first slice of
that port, recorded from Swift so that the Rust slice that replays it (1b) changes no Swift file
(r11 rule 10). Host-local measurement only: no device, no HDC, no daemon, no store.

Base: protected main `74c3b2b1` (#2016). Branch `agent/xpa-014-recovery-manifest-oracle-20260919`,
no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RecoveryManifestOracleContractTests.swift` (new);
- `rust/tests/fixtures/recovery-manifest/` (new: `cases.json`, `provenance.json`, 69 documents, 17
  canonical re-encodings);
- this record.

No Rust, production Swift, Catalog, spec, schema or control-frame change.

## Carrier and what was missing

The decision package's last carrier row for decision 4 is
`Sources/ArkDeckStorage/RecoveryManifestContract.swift` (lines 4–33 and 35–60 on `6cf99fb6`; the
file is byte-identical on `9c58e484`): a hazard's `outcomeCertainty` is `confirmed` or
`outcomeUnknown`, a `known` device mode refuses to decode without a value and evidence, and every
object refuses a member it does not name (`strictContainer`).

Re-verified on `9c58e484`:
- **Swift writes no non-null recovery manifest in production.** `RecoveryManifestRecord(` has no
  caller under `Sources/`. The Session composer seals `"recovery": .null`
  (`RuntimeSessionPublication.swift:309`, also `HDCServerLifecycleJournalAdapter.swift:547`) and
  refuses an unresolved Job ("an unresolved Job cannot be sealed as a confirmed Session"). The codec
  is read by Session manifest validation (`SessionManifest.swift` `validateRecovery`) and the
  recovery member is rewritten only by the export redaction's argument re-hash
  (`RetentionAndExport.swift:978-987`).
- **Rust reads the member but has no codec.** `session_steps.rs` `recovery()` checks the member
  inline inside the Session inventory reader; the only cross-language check of it is the slow-lane
  shadow `HostStoreShadowContractTests.testSessionRecoveryProjection`, which runs only under
  `rust/scripts/hoststore-shadow.py` (`swift-slow-lanes.yml`). No recorded oracle held the codec's
  decisions or its canonical bytes, so nothing in the merge gate pinned them.

## The oracle

`RecoveryManifestOracleContractTests` feeds `RecoveryManifestCodec.decode` one document per case
and records its decision, and for an accepted document the bytes `RecoveryManifestCodec.encode`
writes back. It asserts that each accepted record survives its own canonical round trip and that
each decision is the one the case names.

| Outcome | Cases |
| --- | --- |
| accepted | 17 |
| `invalidField(recovery)` | 10 |
| `unknownOrMissingFields` | 8 |
| `decoding` | 7 |
| `invalidField(hazard)` | 5 |
| `invalidField(lastDeviceMode)` | 5 |
| `invalidField(recoveryGuide)` | 4 |
| `invalidField(userConfirmation)` | 4 |
| `compensation` | 4 |
| `strictJSON` | 2 |
| `invalidField(unexecutedCompensations.policy)` | 2 |
| `invalidField(lastDeviceMode.state)` | 1 |

The kinds are the Swift error the codec throws: `RecoveryManifestContractError`'s two cases,
`StrictJSONError`, `DecodingError`, and `WorkflowStepValidationError` from the typed compensation
descriptor. Message text is T2 and is not recorded.

What the cases pin:
- **Every object level refuses an extra member and a missing one**: the record, a hazard, the
  guide and the confirmation as `unknownOrMissingFields`; an `unknown` device mode with a second
  member likewise; a `known` one with a fourth member as `invalidField(lastDeviceMode)`; a
  compensation descriptor as `compensation`.
- **Decision 4's two value rules**: a hazard certainty of `mixed` or `notApplicable` is refused,
  and a `known` device mode without evidence, with empty evidence or with an empty value is
  refused (`mode-known-*`).
- **The record's invariants**: empty interrupted reason, duplicate or malformed audit event ids,
  audit ids without a user confirmation, an unknown managed-process state, malformed step and
  recovery-of ids; a confirmation by anyone but the user, for any decision but
  `archiveInterrupted`, or at an impossible date.
- **Compensations**: the typed descriptor's refusals, an understated effect or binding
  (`invalidField(unexecutedCompensations.policy)`), and that the codec itself does not verify the
  arguments hash (`compensation-unverified-hash` is accepted; the Session layer checks it).
- **Canonical bytes**: `CanonicalJSONEncoders.canonical()` — sorted keys, no whitespace (the
  pretty-printed document re-encodes compact), no escaped solidus, UTF-8 as is, explicit `null`
  for absent optionals, and an uppercase compensation hash written back in lowercase.

Every document but three is the canonical encoding of a JSON object, so a writer that adds one
member to an accepted record writes exactly the refused document recorded for it. The three
textual ones are the repeated member, the trailing bytes and the pretty-printed document.

## Determinism

The test uses no clock, path or randomness: documents are built from literals and encoded with
sorted keys. A second recording (`ARKDECK_RUST_RECOVERY_MANIFEST_RECORD` to a fresh directory) is
identical to the first byte for byte, and with the fixture installed the test compares every
file and passes.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015), the unified gate is the PR's CI; locally only the
affected test class runs:

| Command | Exit | Result |
| --- | --- | --- |
| `ARKDECK_RUST_RECOVERY_MANIFEST_RECORD=/private/tmp/arkdeck-recovery-manifest-oracle-r1 sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RecoveryManifestOracleContractTests` | 0 | 1 test, 0 failures; recording r1 |
| the same into `…-r2` | 0 | 1 test, 0 failures; `diff -r` r1 r2 empty |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RecoveryManifestOracleContractTests` (fixture installed) | 0 | 1 test, 0 failures; every file compared |

`sh scripts/check-sdd.sh` for this record: see the commit body.

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2018 | `0083c30a` | 35443714140, 35443714152, 35443714404 | 11 checks passed, `app-build` skipped; merged as `e96e51c6` |

## Not in this slice

- The Rust codec and the Session reader's use of it: slice 1b replays this oracle.
- Slices 2–4 of the port (recoverable Job classification and `job.reconcile`, the superseding
  recovery epoch relation, the design §G.4 preflight table) and the M2/M4 follow-ups
  (`cleanupDebt.continue`'s recovered row, `debug.start/status/evaluate`, DEC-016
  `completeOverwriteAdmission`).
