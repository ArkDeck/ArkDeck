# TASK-XPA-014 — the Rust Target observation owner (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: #1957 (`c3aee2d5`) over protected main `68e8241a`.
This slice is stacked on it because the replay reads that PR's fixture. #1957's head was
re-created as `c3aee2d5` with `ab1180d2`'s exact tree, to re-run its CI after an unrelated
flake; the gate below ran over `ab1180d2`, the same tree. Every request and answer
here is synthetic host data over `/bin/sh` scripts; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Lane B's USB relation port and physical-relation proof (#1952); the Target presentation owner (TASK-XPA-012); the Target adoption oracle and its control shapes (#1957, below this one) | hoststore `TargetObservations`: snapshots, following, adoption; the `TargetStore` adoption writer and candidate-name lookup; `tests/target_adoption.rs` | The daemon's `device.observations`, `following` and `target.adopt` over this owner, and a development-only USB relation source for the real-daemon replay (A2b); `target.availability`; the HAR path's raise and resume |

## What the Rust owner does

It follows Swift's `TargetObservationCoordinator`, `RuntimeTargetStore.adoptObservedCandidate`
and `RuntimeTargetDisplayNameStore` (`TargetObservationCoordinator.swift`, `DeviceBootstrap.swift`,
`RuntimeTargetDisplayNameStore.swift`), and the handler's projections (`AgentDaemon.swift`).

- **Snapshots.** `TargetObservations::snapshot` takes lane B's bracketed reading
  (`Reading::take`: the relations, then `list targets -v`, then the relations again). It stamps the
  reading as Swift's `stamp` does:
  - Bounds: a reading may hold at most 1,000 candidates, with keys of 1 to 1,024 bytes. Otherwise it
    is refused with `operationUnavailable` "device snapshot exceeds its bounds", naming no reference.
  - Identities: a row keeps a previous row's identity and first generation only when both carry the
    same proved relation and connect key. Otherwise it gets a new `obs-` identity, first seen in the
    next generation.
  - Generations: the fact generation advances only when the rows change, and then the candidate
    names expire. Unchanged proved facts keep their generation.
  - Failures: a failed reading or a failed store step drops the snapshot, so the next reading mints
    new identities.

  A followed reference must belong to the snapshot both before and after the reading. That means
  the same identity and key, first seen no later than the reference's generation, and, when the
  snapshot is newer, a proved relation.
- **Adoption.** `adopt` follows Swift's order:
  1. The same reference again answers with its receipt, after one more reading that must still hold
     the reference.
  2. The exact observation of the current generation must have a proved relation. Otherwise the
     answer is `targetTrustPending` for a trust prompt, and `admissionDenied` for anything else.
  3. A fresh reading must still hold the observation exactly, `Connected` and proved.
  4. The tool version (`-v`), the identity readback (`list targets -v`) and the live relations are
     read. Any failure here drops the snapshot.
  5. The relation must be unchanged, exactly one usable live relation must remain, and the readback
     must name its serial. Otherwise the answer is `factsDrifted`.
  6. The store writes the adoption. The snapshot moves to the next generation with its names read
     again, and the receipt is kept, at most 1,000 of them.
- **The store.** `TargetStore::adopt_observed_candidate` materializes the Target as Swift does:
  - an alias's canonical Target;
  - the Target of the same identity, or its canonical one;
  - otherwise a new Target named `TGT-` and the identity's first twelve digits, at revision 1. If
    that Target is already bound to another key, the adoption is refused.

  In one transaction, holding both locks and checking each publication, it then:
  1. stages the candidate's name onto the Target;
  2. writes `targets.json`, only for a new Target;
  3. finishes the candidate names into the next generation.

  The binding document is written in Swift's encoding: sorted keys, pretty printed, `\/` escaped,
  no trailing newline. `candidate_display_names` answers each observation's name, which counts only
  in the generation it was set in.
- **Answers.**
  - `Snapshot::answer` gives the daemon's `device.observations` answer. A proved row names its
    Target and binding revision, and the name is the candidate's own. Device information and
    observed facts are null, as they are without a bootstrap machine or a confirmed Job observation.
  - `adoption_answer` gives the adoption's answer, and `parse_reference` is Swift's
    `targetObservationReference`.
  - Refusals carry `phase: preAdmission`, no new dispatch and the reference. Any other failure is
    `internalError` with its reason.

## Tests

`tests/target_adoption.rs` replays the oracle's observations and adoptions in process over the
shared fake HDC, under the fake's lock.
- **The root** is rebuilt as `HDCOracleFake.install` leaves it, with an empty `targets-state`. The
  Target store writes its display names when it opens, as Swift's store does at startup.
- **The owner** is composed over:
  - a `ProcessDispatch` of the fake driver;
  - the oracle's clock;
  - a USB relation source set for each exchange from the recorded `usbRelations`. For the drift
    exchange it changes to `usbRelationsAfter.relations` after the recorded read count.
- **The exchanges.** Each of the 18 is sent in order, in the mode the oracle names. The observation
  identities the owner mints are read as the oracle's labels, in order of first appearance, and a
  label in a request is read back as the identity it stands for.
- **Every answer is compared exactly:** the result, or the refusal's code, message and details.
- **The files are compared byte for byte:**
  - the fake's calls: 16 device lists and 3 tool-version reads;
  - `targets.json`: the new Target's binding, 374 bytes;
  - `target-display-names.json`.

It passed on its first run. The three availability exchanges are not replayed here, because
presence, the tool leg and the operations are the daemon's answer.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The replay | `cargo test -p arkdeck-hoststore --test target_adoption` | 1 passed: all 18 exchanges, the fake's calls, `targets.json` and the display names, byte for byte |
| Every hoststore test | `cargo test -p arkdeck-hoststore` | all pass. The library has 154 passed and 5 ignored; among them, the Target presentation owner's CAS, restart and binding-byte tests now run over the publishing transaction |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | pass; `read_only` 15 of 15 |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-execution`, `agent-lifecycle`, `observe-device` and `capture-diagnostics` | PASS on all four (29, 25, 28 and 28 exchanges; 57, 58, 57 and 57 checks); every summary byte-identical to #1956's runs |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `4ff9f168` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,676 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 2,151 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-target-observation-owner-gate-20260914-r1.log`, SHA-256 `1262b30788188ef1389303b2276b28690f049d4f3639f10e8b5fbad1e4f85229` |

The amend after r1 only fills in this row.

## Not run, and why

- **The daemon.** `device.observations` on the Rust daemon still mints identities per read, and
  `target.adopt` keeps the foundation's refusal. A2b composes this owner there and replays the
  fixture against the real daemon. That needs a development-only USB relation source; production
  keeps `NoUsbRelations`.
- **Availability.** Its answer is the daemon's: presence, the tool leg and the operations.
- **Coalescing.** Concurrent readings are serialized under the owner's lock, where Swift joins one
  in flight. The oracle is sequential, so the answers are the same.
- **Candidate names in adoption.** The oracle names no candidate. The stage and finish are ported,
  and exercised only by the empty case.
- **`rust/scripts/check-target-resources.py`.** It is a manual harness over a Target store exported
  by a Swift producer. No CI or gate runs it, and no exported store is at hand. The Target
  presentation owner's own tests cover the transaction change.
- **A restart.** The snapshot, the generations and the receipts live in memory, as in Swift, and
  restart semantics stay out until L.1 item 13 is decided.
- No device, no real HDC.
