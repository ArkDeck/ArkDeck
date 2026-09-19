# TASK-XPA-014 — recovery port, slice 1b: the Rust recovery-manifest codec

Change: CHG-2026-074-shared-rust-runtime-core@r11. Second half of slice 1 of the recovery port
the maintainer ruled on 2026-09-19 (design §L.1 item 13; the decision package's Ruling section):
Swift's `RecoveryManifestContract.swift` ported unchanged, replaying the oracle slice 1a recorded
(`recovery-manifest-oracle-run.md`). Host-local only: no device, no HDC, no daemon.

Base: protected main `f2bf0047` (#2017), which holds slice 1a (#2018, squash-merged; its fixture
is what this slice reads). Branch `agent/xpa-014-recovery-manifest-20260919`, no stack: it was
first pushed stacked on 1a and rebased onto main after 1a merged. No Swift file changes here.

## Already on main / delivered here / remaining

| Already on main | Delivered here | Remaining in the port |
| --- | --- | --- |
| The Session reader checks the `recovery` member inline (`session_steps.rs` `recovery()`); the slow-lane shadow compares it with Swift | `recovery_manifest.rs`: Swift's typed record, strict decoder and canonical encoder; the Session reader decodes the member through it | Slice 2: recoverable Job classification on restart and `job.reconcile` |
| Session publication seals `recovery: null` (`session_publication.rs`), as Swift does | Oracle replay in the merge gate (Rust lane) instead of only in the slow shadow lane | Slice 3: the superseding recovery epoch relation (needs its own Swift-only oracle first) |
| Journal replay derives device-mutation abandonment hazards from outstanding intents and unknown outcomes (`job_journal_replay.rs`) | — | Slice 4: the design §G.4 predicate table |

## The codec

`rust/crates/arkdeck-hoststore/src/recovery_manifest.rs` (macOS, as the Session reader is):
- `RecoveryManifest` and its parts mirror Swift's `RecoveryManifestRecord`, `…Hazard`,
  `…DeviceMode`, `…Guide` and `…AbandonConfirmation`, with the same member sets.
- `RecoveryManifest::decode` runs `strict_json::validate` (Swift `StrictJSONDuplicateValidator`)
  and then `from_value`, which decodes in Swift's order: the record's exact member set, every
  unexecuted compensation as the typed `CompensationDescriptor` decodes it (unexpected member,
  raw kind resolved against the 43 `WorkflowStepKind`s, the member types, then the compensating
  kind, identifier, digest and argument checks), their declared policies against the normalised
  ones, then each member in declaration order, then the record's invariants. The first refusal
  is reported as the kind of Swift error that `RecoveryManifestCodec.decode` throws.
- `encode` is `CanonicalJSONEncoders.canonical()` of the record, through the Session document
  encoder already used for Session manifests (`session_json::encode`): a compensation keeps its
  normalised policy, its arguments as `JSONValue` holds them and its hash in lowercase.

The Session reader's `recovery()` keeps its place but no longer restates the contract. It does
what Swift's `validateRecovery` and `validateRelationships` do:
1. each unexecuted compensation's declared hash (`compensation_hash_matches`, Swift
   `validateCompensationDescriptorHash`);
2. `RecoveryManifest::from_value` on the member;
3. the last confirmed step is one of the Session's steps, and every unexecuted compensation is
   one a step declared, unchanged.

Every refusal is still `ManifestError::Invalid`. The accept/refuse set is unchanged: the removed
inline checks were the codec's rules plus the hash check, and the codec now carries the former
(verified against Swift by the oracle) while the reader keeps the latter.

Nothing writes a non-null recovery member, in Rust or in Swift; the encoder serves the oracle's
writer proofs and keeps the T0 format in one place.

## Tests

`cargo test -p arkdeck-hoststore --lib recovery_manifest` (4 tests):
- `every_swift_decision_and_canonical_encoding_is_reproduced`: all 69 oracle documents (the
  count is asserted `>=` 69) reach Swift's decision; every accepted one encodes to Swift's
  canonical bytes and survives its own round trip.
- `a_record_rust_builds_encodes_as_swift_encodes_it`: a record built field by field encodes as
  Swift's canonical `base`.
- `a_member_more_or_less_written_by_rust_is_the_document_swift_refused`: Rust writes an accepted
  record with one member more or one fewer at each level (record, hazard, unknown and known
  device mode, guide, confirmation, compensation): 10 writes, each byte-identical to the
  document Swift refused and refused by Rust for Swift's reason.
- `the_session_reader_reads_the_member_through_the_codec`: a `failed` Session manifest Swift
  sealed (found among the checked-in oracles) with a recovery member set: accepted with the
  oracle's `base` and `minimal` members once `lastConfirmedStepId` names one of its steps;
  refused when it names none, and for five members the codec refuses.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI. Locally, in this
branch's own worktree and cargo target, with `CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy -p arkdeck-hoststore --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore` | 0 | 353 passed, 0 failed, 12 ignored, 43 test binaries |

Log: scratchpad `logs/checks-s1b.log`, SHA-256
`aa811686fd924481fe15a848f4117658b527c572caa568e7bd500516690e8e70`.

After the rebase onto `f2bf0047`: `cargo clippy -p arkdeck-hoststore --all-targets -- -D
warnings` clean, `cargo test -p arkdeck-hoststore --lib` 200 passed, 0 failed, 5 ignored,
`cargo fmt --all --check` clean.

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2018 (slice 1a) | `0083c30a` | 35443714140, 35443714152, 35443714404 | 11 checks passed, 1 skipped; merged |
| #2021 (this slice, stacked on 1a) | `bda3e990` | 35443956815, 35443956825, 35443956916 | 11 checks passed, 1 skipped |
| #2021 after the rebase | `1ee80211` | 35444424023, 35444424065, 35444424211 | 9 checks passed; `swift-tests`, `app-build`, `ds-interactions` skipped (a Rust-only diff); merged as `9f51ec00` |

## Not run, and why

- The slow-lane shadow (`rust/scripts/hoststore-shadow.py`, `HostStoreShadowContractTests`
  `testSessionRecoveryProjection`) is not part of the merge gate; it compares the Session
  reader with Swift over 44 recovery variants and runs in `swift-slow-lanes.yml`.
- No device, HDC or daemon: the codec is host-local.

## Recorded for the next slices

- `cleanupDebt.continue`'s recovered row, `debug.start/status/evaluate` (the Flash recovery
  broker) and DEC-016's `completeOverwriteAdmission` stay in M2/M4, after slices 2–4.
