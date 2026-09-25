# Planning the two Flash operations on the Rust Runtime (TASK-XPA-017, M4-4b3)

Before this change, the Rust daemon refused `job.plan` for both Flash
operations with "… is not materialized by the Rust Runtime yet". These are
the canonical `flash.full-restore@1` and its compatibility alias
`flash.dayu200`.

It now plans them as Swift's `RuntimeJobEngine.planOnly` does, following
`materializeTypedPlanBeforeAuthorization`:

- The alias's inputs are projected onto the canonical request
  (`ArkForgeFlashRequest.canonicalInputs`).
- The ArkForge provider's availability is judged, then the Rockchip
  dispatcher's, then the Artifact store's.
- The Target's facts come from the ArkForge facts port and are validated.
- The flash bundle's lease is resolved against those facts.
- Every selected step is materialized, as the engine, `arkforged` or the
  Rockchip host will perform it:
  - `arkforged`'s steps as a StepPermit bound to the lane's toolchain;
  - the host's steps as a host-managed descriptor pinning the canonical
    digest of their typed action.
- The plan document's digest is computed, and the provider's
  `executionAdmissionBlocker` is reported.

The plan is Swift's, its digest included, and so is every refusal. Nothing
is admitted: `job.submit` still refuses both operations as before.
`operation.list` is unchanged too: the Rust executor cannot run a Flash, and
a plan the planner can materialize does not make an operation executable.

Base: protected `main` `44774d58` (#2163, after #2161). Routed methods stay
**102/105**, since #2163 routed `trace.inspect`; this change routes none.
Executable operations are unchanged by this change. One contract input
widens (see [The contract](#the-contract)).

The change was first pushed on `9ae1e499` (#2160). #2161 then widened other
contract inputs, so it was rebased onto `44774d58`. The generated baseline
was then regenerated rather than merged by hand.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The Rockchip facts port, bootloader status and prerequisites (#2150); the ArkForge lane's composition (#2151, #2152); the Import owner validating a flash bundle (#2158) and the App uploading one (#2159) | `job.plan` of both Flash operations, as Swift materializes them, in both Rust compositions; the Swift oracle `flash-plan` (23 plans, 10 dispatcher states); an unresolvable Import lease refused as Swift refuses it | The two Flash operations' admission (`job.submit`) and `debug.start`/`debug.evaluate` (observe, stop); `flash.lanePlanPreview` and the Flash run, after the upstream ArkForge client change |

## The oracle

`FlashPlanOracleContractTests` drives Swift's `RuntimeControlPlaneHandler`
over `RuntimeJobEngine.planOnly`. A flash bundle is first imported through
the same handler with the production policy, and its lease is what every
request names. A second bundle, bound to another Target, is imported last.

Each exchange scripts what the plan reads beyond the bundle, and its setup
records it:

- the provider's availability, as the lane's composition decides it;
- the dispatcher's reason;
- the lane's toolchain, or no lane;
- the facts port's answer, or its error. The port has its own oracle
  (`flash-host-facts`, #2150).

There are 23 exchanges (`cases.json`):

- **Plans.** The canonical operation with full and with basic verification.
  The alias with full, with basic and with the default verification.
- **The alias refused.** A reordered and a short partition plan, which
  cannot be converted.
- **Availability.** No lane registered; a lane without a campaign
  (`hardwareGated`); the dispatcher unavailable; no lane toolchain.
- **Facts.** A facts error; a stale binding revision; an empty connect key;
  an identity and a tool that are not digests; the cross-mode binding
  unprepared, which plans with a blocker; no post-flash alias; an alias
  whose identity does not match.
- **Requests.** An unknown lease, a capability named, no expected binding
  revision, and the other Target's bundle.

Separately (`dispatch.json`), Swift's own
`ArkForgeNativeRockchipControlDispatcher` is composed as `main.swift`
composes it and asked for its reason in ten states:

- no configured `arkforged`;
- no descriptor-bound HDC;
- and, with an HDC, its record root `<state>/rockchip-runtime`:
  - absent, which Swift creates owner-only;
  - owner-only;
  - group-readable;
  - a symlink;
  - a file, and an owner-only file;
  - under a state directory that does not exist;
  - owner-only below `/private` (see below).

An Import is named at random, so the oracle is recorded once
(`ARKDECK_RUST_FLASH_PLAN_RECORD`). A later run imports nothing: it lays the
recorded Artifact root and Target store down, as the Rust replay does, and
plans every recorded request again under its recorded setup. The answers,
the tree they leave and the dispatcher's reasons must then match byte for
byte.

One file is exempt: a payload's verification cache pins its inode's
fingerprint. A payload laid down again is a new inode, so Swift verifies it
again and rewrites the cache. That cache is not an answer, so the replay
compares the recorded one.

## The Rust planner

`FlashPlanner` wraps the existing `JobPlanner`. A Flash request goes to the
Flash composition when the daemon composed one; every other request, and a
Flash request without one, goes to the planner as before.

- **Materialization** (`flash_plan.rs`). Swift's plan document is built and
  canonically encoded, and its digest is taken. The typed Rockchip actions
  are ported (`RockchipProviderAction`: its catalog identifiers and
  persisted encodings), with `journalStep`'s arguments. The build version
  the post-flash check expects is read from the leased archive, once per
  lease and digest, as Swift's daemon-lifetime cache reads it.
- **The dispatcher's reason** (`rockchip_dispatch_unavailable`). The
  configured `arkforged`'s identity comes first. The per-action host then
  refuses without a descriptor-bound HDC. Otherwise its record root is
  prepared as Swift's record store prepares it: created owner-only when
  absent, the parent synchronized, and otherwise required to be an
  owner-only real directory.
- **Composition** (`arkforge_lane.rs`, `host.rs`). Both compositions compose
  the planning from their ArkForge lane:
  - the provider's availability is the lane's absence, or why a lane without
    a campaign may not flash;
  - the dispatcher's reason is taken over the bundle's `arkforged` and, with
    an HDC, the record root beside the Job state;
  - the toolchain is the lane's.

  The facts port is the Host's Rockchip facts over its own Target store,
  measured over its HDC when it has one.

The additive `stepSetDigestSHA256` (#2121) is emitted as for every plan; the
Swift answer does not have it, so the replay checks it apart.

## Found while porting

- **An unknown Import answered with the wrong refusal.** Swift's
  `requireUsableImportInputs` refuses every lease that does not resolve with
  `invalidInput`, "Import input is released, missing or unreadable; use a
  valid committed import before submitting a new Job". The Rust Import holds
  answered an unknown Import with `resourceNotFound` ("Import does not
  exist"), and an unreadable one with `recordUnreadable`. That applied to
  every plan and submission that names an Import, the HAP and native library
  included. The holds now refuse as Swift's. It is still a refusal before
  admission, with nothing dispatched.
- **The `job.plan` contract had narrowed.** Its result schema allowed only a
  `null` provider admission blocker, since no recorded plan had one. Swift's
  handler plans with one whenever the facts report the cross-mode binding
  unprepared, as the oracle's scripted facts do, and the Rust planner answers
  those facts alike.

## Declared differences

- **A record root below `/private`.** Swift's canonical-path check compares a
  path with its `standardizedFileURL`, and Foundation strips an existing
  `/private/tmp/…` path to `/tmp/…`. Swift therefore refuses an owner-only
  record root below `/private` as soon as it exists: "Rockchip record path
  is not canonical". The oracle's `records.privatePrefix` pins that answer.

  This Runtime judges the path as spelled: absolute, naming no parent, and
  exactly as its own components rebuild it. It accepts that root. The root
  is still required to be an owner-only real directory. An isolated owner
  below `/private/tmp` needs this from its second plan on.
- **The parent's synchronization.** It is `F_FULLFSYNC` here (Rust's
  `sync_all`) where Swift calls `fsync`. This is stronger and not
  observable.

## The contract

- **Frames.** `FlashPlanOracleContractTests` was run with
  `ARKDECK_CONTROL_FRAME_LOG` and gave 23 `job.plan` frames. Against the
  committed schema one was refused: the plan carrying a blocker.
- **Corpus, append-only.** The ten committed lines are kept verbatim. Five
  frames were appended, one per new shape:
  - the canonical plan, and the canonical plan with a blocker;
  - the alias plan, with and without `postFlashVerification`;
  - the `internalError` of an alias that cannot be converted.
- **Schema, widened only.** `generate-control-contract.py
  --derive-method-schemas` ran over the corpus as a check. Beyond the sample
  counts, it differs from the committed schema only by:
  - the widening below;
  - the hand-kept `inputTooLarge` code and `stepSetDigestSHA256` property.

  The committed schema gains exactly that widening:
  `providerAdmissionBlocker` becomes `null` or a string. Its sample counts
  grew by the appended lines.
- **Generated.** `generate-contract.py --write` refreshed
  `spec/baselines/swift-single-v1.json`, and `--check` passed. That is 999
  shapes on `44774d58`: `main`'s 994 and these five. The contract identity
  is unchanged.

No Rust test plans a blocker through the control layer: the daemon's facts
port reports the post-flash alias only for a covered binding, where the
cross-mode fact is satisfied. So check-contracts' published view, which
compiles the merge base's schema, is unaffected.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0`, own
target `/private/tmp/arkdeck-m4-rust-target`, logs
`/private/tmp/arkdeck-m4-flash-plan-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift oracle, recorded | `ARKDECK_RUST_FLASH_PLAN_RECORD=<fresh> run-swiftpm.sh test --filter FlashPlanOracleContractTests` | exit 0; 17 files (`swift-record4.log`) |
| Swift oracle, replayed | `run-swiftpm.sh test --filter FlashPlanOracleContractTests` (compare mode) | exit 0 (`swift-compare.log`) |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|FlashPlanOracleContractTests'`, on `44774d58` | exit 0; 6 tests, the committed corpus and this run's frames valid (`rebase2-swift-schema.log`) |
| Rust replay | `cargo test -p arkdeck-hoststore --test flash_plan` | 2 passed: 23 plans, 10 dispatcher states |
| Composition | `cargo test -p arkdeck-agentd --bin arkdeck-agentd flash_plan_control` | 1 passed: seven compositions, and `job.submit` still refused |
| Mutations | 14: the plan and the Import hold (6), the record root (3), the composition (5). The real-directory check first survived, so the oracle gained the owner-only file; on the final oracle the record root's three and two of the plan's were run again | all killed in the end; files restored by digest |
| Frames against the schema | jsonschema (validation venv), before and after the widening | 1 refusal, then 0 |
| Schema derivation | `generate-control-contract.py --derive-method-schemas` over the corpus, as a check | differs only by the widening applied, the hand-kept code and property, and the sample counts; everything restored by digest |
| Contract | `generate-contract.py --write`, then `--check`, on `44774d58` | exit 0; 105 methods, 999 shapes (`rebase2-check.log`) |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-contract`, `arkdeck-control`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-soak`, on `44774d58` | exit 0 (`rebase2-fmt.log`, `rebase2-clippy-<crate>.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same five, on `44774d58` | exit 0 each: contract 52, control 30, hoststore 585, agentd 159, soak 4 (`rebase2-test-<crate>.log`); `arkdeck-cli`, which this change does not touch, 252 on `9ae1e499` |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv), on `44774d58` | PASS on macOS; 135 control responses (`rebase2-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh`, on `44774d58` | exit 0 (`rebase2-sdd.log`) |
| #2161's analyzer test | `cargo test -p arkdeck-agentd --test crash_ledger_analyzer`, in this checkout's view and in a published view simulated before #2161 (9ae1e499's `agent.run` and `agent.status` schemas, the view forced; `published-view-sim-agent.sh`) | 5 passed in each; restored by digest (`pubsim-agent.log`) |

**CI.**

- *First push, head `8caf6c1a` on `9ae1e499`.* Every check passed: SDD
  Guard run 36079454931, and Swift CI run 36079455136, whose `swift`
  aggregate and Rust lanes on ubuntu, macos-26 and windows passed.
- *Rebased onto `44774d58`, head `e823a407`.* SDD Guard run 36084192398
  passed. Swift CI run 36084192613 was red only in the macos-26 Rust lane's
  published contract view (job 107912369882). The failing test was
  `crash_ledger_analyzer.rs` `an_agent_execution_of_the_analyzer_runs_its_job_to_the_end`,
  #2161's own. It expected the daemon to refuse its host-only `agent.status`
  and `agent.run` answers whenever the view is the published one, on the
  assumption that the merge base predates #2161's widening. This change's
  merge base includes that widening, so the view published the answers.
- *The test fixed here.* It now reads which contract the build compiled
  (`publishes_host_only`: the five members #2161 made nullable). It expects
  the refusal only where that contract refuses them, and asserts that this
  happens only in a published view. Nothing is loosened: a checkout that
  refused them would now fail loudly.
- *Pushed again, same base.* Pending.

**#2159 (M4-4b2), recorded here.**

- *Head `7ccadf46`.* Every check passed on the first run: SDD Guard run
  36073836189, and Swift CI run 36073836337, whose `swift` aggregate and Rust
  lanes on ubuntu, macos-26 and windows passed.
- *Merged* as `3317bda0`.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence. The bundles are synthetic, and every facts answer
the oracle plans with is scripted.
