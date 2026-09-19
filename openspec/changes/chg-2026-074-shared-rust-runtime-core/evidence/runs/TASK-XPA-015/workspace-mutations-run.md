# The seven remaining workspace methods on the Rust owner (TASK-XPA-015, M3)

The isolated Rust daemon now answers every `workspace.project.*` and
`workspace.preset.*` method. This change adds the seven that #2041 recorded:
`workspace.project.update/remove` and
`workspace.preset.register/update/remove/list/show`. The Rust CLI gains their
leaves. A preset that pins a DevEco toolchain or a signing credential goes
through Swift's crash-recovered dependency transaction, behind two pinning
owners the composition root supplies. The isolated daemon supplies neither yet,
so it refuses such a preset exactly as Swift's store refuses it without them.

Base: `main` `0ae927d1`, which carries the oracle #2041 (`3e95ac6d`).

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| Rust `workspace.project.register/list/show`; the SPK-10 signing layer (#2031); the Swift oracle for the seven methods (#2041) | The Rust owner, control routes and CLI leaves of the seven methods; the dependency transaction and its pinning interfaces; the durable Job census for projects and presets | DevEco toolchain acquire/release in the Rust registry owner; the signing credential owner (`credential-owner-v1.json`); composing both into the isolated daemon; the 13 `workspace.*` operations; GJ-5 |

## Behaviour, as Swift's owner and daemon

- **One transaction per request.** Swift's `withDocument` order is kept. The
  process lock is taken, then the Job census runs for a mutation, then the
  store lock is taken and the document is loaded and validated. A retained
  dependency mutation is reconciled before the request sees the document.
  Every write is Swift's `save`: staged, renamed, the directory flushed.
- **The clock** is a closure read where Swift reads its injected `nowUTC`,
  inside the transaction. The storage faults #2041 raised from inside the
  clock are raised from the same point here.
- **Project update and removal** follow Swift's order and refusals. An update
  inspects the new root without following links before the census, and never
  answers the root. A removal refuses while an available preset exists and
  answers Swift's removed projection.
- **Preset registration** names the preset `preset-` plus the first 24 hex
  digits of the SHA-256 of its request identity. A replay under the same
  identity and definition answers the stored preset; another definition is an
  `idempotencyConflict`. The 257th preset of an owner is refused.
- **Preset update and removal** replay a mutation under its identity, refuse
  a stale generation, and advance the generation. An update that changes no
  dependency is written at once.
- **The dependency transaction** is Swift's `reconcileDependencyMutation`. The
  owners are checked, and a credential's project binding validated, before
  the intent is written. The intent is then persisted and completed: acquire
  the new pins, publish the record, then release the pins it replaced. A
  refused pin abandons the intent and restores the document, and the refusal
  reaches the caller. An intent a dead process left behind is completed by
  the next access, and one that does not match its durable record is refused
  as `recordUnreadable` without a write.
- **Without an owner** a preset that pins a toolchain or credential answers
  `operationUnavailable` with Swift's message, before any write. A retained
  intent that names a missing owner refuses every method.
- **The Job census** is Swift's `requireNoActiveWorkspaceProjectReference` for
  a project and `requireNoActiveWorkspacePresetReference` for a preset. Every
  durable record is verified. Terminal records are skipped unless their outcome
  is unknown, and so are other providers' records. A preset is matched in the
  descriptor's preset inputs for a Job of this Catalog, and in all four closed
  preset input names for a Job of another. Without a Job owner, an update or
  removal is refused, because nothing proves no active Job names it.
- **Durable records** are Swift's, key for key. A nil optional is omitted, as
  Swift's encoder omits it. A preset record or intent with one key more is
  refused, not dropped.
- **Control and CLI.** The control layer answers Swift's `invalidParams` for
  each method, with Swift's message and no owner details, before it asks for
  the owner. The CLI leaves take Swift's options and value grammars, never
  replay an unconfirmed mutation, and check the shape of every answer.

## Tests

- `tests/workspace_mutation_oracle.rs` (hoststore) replays all 78 frames of
  #2041 in their recorded order. Each result must equal Swift's as JSON, and
  each refusal its code, message and details. Between frames the owner is
  changed as the Swift test changed it: no pinning owners, a full owner, a
  retained intent, an unreadable document, and faults raised from the clock.
  The pinning owners' calls are logged and compared with Swift's sequence.
  A mutated message makes the replay fail at its frame.
- `tests/workspace_preset_transaction.rs` (hoststore, 7) covers what the oracle
  does not record. An intent left by a dead process is completed by the next
  read. A refused pin leaves the document byte for byte as it was. A changed
  toolchain is acquired before the old one is released. Dropping or removing
  dependencies releases every pin, and a nil optional is omitted. Mismatched
  intents and a missing owner refuse without a write. A preset record, an
  intent or a proposed record with one key more is refused.
- `workspace_project::mutations::tests` (hoststore, 4) keep their project and
  preset-read cases under the new transaction.
- `actual_host_registers_updates_and_removes_presets_without_dependency_owners`
  (agentd) runs the actual Control and Host of the isolated daemon: a symbol
  preset is registered, replayed, updated and removed; a build preset is
  refused before any write; the census refuses a removal without a Job owner.
  Every answer is decoded against its method schema.
- `workspace_mutation_and_preset_parameters_answer_swift_s_refusals` (control)
  checks every `invalidParams` message of the seven methods.
- `workspace_preset_mutation_arguments_follow_the_swift_samples` (CLI) replays
  the Swift argv samples of the three new leaves and the value grammars.

**Not covered:** the census branch that finds an active workspace Job. No
workspace Job can be admitted in the Rust Runtime yet.

## Durable bytes against Swift

The frames prove the answers. To prove the document too, the owner's
`projects.json` was copied out of Swift's own run once, after frame 52, where
the replay compares it. A local, uncommitted copy step was added to the Swift
test after its project removal, the test was run (1 test, 0 failures, 10.2 s),
and the step was reverted. The file is
`rust/tests/fixtures/workspace-mutation-oracle/swift-projects.json`, with its
provenance beside it.

| Compared after frame 52 | Result |
|---|---|
| The `presets` array: a signing preset, a removed build preset, a symbol preset removed after an update | byte for byte equal |
| The project records, every field but the root, the registration root and its digest | equal |

This fixes what the frames cannot show: the definition, update and removal
digests, the omitted nil optionals, the key order and the unescaped slashes.

## Differences kept

- **Earlier Rust strictness, unchanged.** Since #1989 the control layer refuses
  `workspace.project.list` with any parameter and `workspace.project.show`
  with one key more; Swift ignores both. The Rust CLI's workspace leaves accept
  a client `--timeout`, which Swift's do not; the three new leaves follow the
  Rust family.
- **A corrupted durable preset** whose definition is invalid is refused as
  `recordUnreadable`. Swift's `load` rethrows its definition check, which
  answers `invalidInput`.
- **A Swift observation, ported as is.** If the toolchain pin succeeds and the
  credential pin is then refused, Swift abandons the intent without releasing
  the toolchain pin. The DevEco owner then keeps a reference for a preset that
  does not exist. The binding check before the intent makes this need a race
  or an I/O failure. It is left to the owner slices.

## Local targeted checks

On `0ae927d1` plus this change, with `CARGO_BUILD_JOBS` of 3 or 4:

| Check | Exit | Result |
|---|---|---|
| `cargo fmt --all --check` | 0 | |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | |
| The same clippy for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`, on the four changed crates | 0 | |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli` | 0 | 651 passed, 0 failed, 13 ignored |
| `python rust/scripts/generate-contract.py --check` | 0 | no difference; no contract input changes here |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `python rust/scripts/check-contracts.py`, which runs `check-readonly.py` against the built daemon | 0 | candidate view only; no contract input changes |
| The #2041 Swift test, once, with the local capture step, then reverted | 0 | 1 test, 0 failures |

The last clippy finding, in the oracle test's byte comparison, was fixed after
the full test run; its two test files were run again and pass.

The first two CI runs failed on ubuntu, and both causes are fixed here. The
CLI test expected `--socket` to dispatch, which the Rust CLI refuses off macOS
by design; it now asserts that refusal there. `check-readonly.py` still
expected the foundation's `rejected` for the seven methods sent without
parameters; they now answer Swift's `invalidParams`, and the script expects it.

## CI

The PR's `guard` and `swift` aggregate are the unified gate. Their result is
added by the next slice.
