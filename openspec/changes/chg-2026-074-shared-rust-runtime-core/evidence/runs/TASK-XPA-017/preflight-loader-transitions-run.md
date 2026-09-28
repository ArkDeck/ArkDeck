# TASK-XPA-017 — the cutover preflight refuses the Loader transitions that stop the Rust daemon's start (macOS, 2026-09-28)

Base: protected `main` `2e687ca82` (#2298). Stage S slice S3 of the 2026-09-28 close-out prompt
(runbook appendix B item 1 / P2). Host evidence only: temporary homes below `/private/tmp`, the real
`arkdeck-agentd` binary with a cleared environment; no installed service, `launchctl`, device, trusted
fact, capability, reservation or `~/Library/Application Support/ArkDeck` was touched. No Catalog
operation, contract input (`spec/**`, `control-protocol.json`, ControlFrames, CLI argv corpus), schema,
`tasks.md` or task status changes.

## The gap

The Rust daemon's start (`rust/crates/arkdeck-agentd/src/main.rs:728`,
`RockchipStartup::awaiting_transition`, `rust/crates/arkdeck-hoststore/src/rockchip_startup.rs:69-97`)
counts, once a production Loader binding carries a Target along its lineage, every active Job whose
**record** parks a DAYU200 Flash in `waitingForRecovery` with an unknown outcome at its outstanding
`enter-loader-mode` intent for that Target and the binding's previous revision
(`JobStore::loader_transitions_awaiting_binding` over `loader_transition_candidate`,
`rust/crates/arkdeck-hoststore/src/job_owner.rs:110-122`, `:593-611`). Two or more stop the start with
`jobNotRunnable("multiple unresolved Loader transitions cover target …")`; under launchd `KeepAlive`
that is a crash loop.

The preflight's existing `loaderTransitionAwaitingBinding` refusal (#2255) applies Swift's stricter
settlement predicate (record **and** journal, no ArkForge lane). Jobs outside it — lane-held, or with a
journal holding another outstanding intent — were carried over, so two of them on one Target passed the
preflight and then stopped the daemon.

## The change

- `arkdeck_contract::CutoverJob.loader_transition_candidates`: the `(targetId, expectedBindingRevision)`
  each of the Job's records parks it at, by the record alone.
- `cutover_facts::jobs()` fills it from both record sources: the index row's record for every
  non-terminal row (exactly what `active_rows` + `JobRecord::from_row` give the start; a row that does
  not decode is no candidate, as it is none there) and `jobs/<id>/job-record.json`. No journal, no
  ArkForge sidecar is consulted, since the start consults neither. The union of the two sources is the
  one conservative step beyond the start's own read (it reads the index row only); the two differ only
  in a crash window, where the table's state rules already classify the Job by its most conservative
  source.
- New `CutoverBlock::LoaderTransitionsCoverTarget { target_id, expected_binding_revision, job_ids }`,
  emitted whenever two or more Jobs share one `(target, revision)`, whatever their class. Grouped by
  revision as well as Target because the start compares against one revision
  (`proof.previous_revision`): two candidates at different revisions of one Target can never both be
  counted by one start.
- Why the records alone and not the current binding: which binding the next start finds is not a fact
  of the state root (`flash bind-loader` can publish one after the cutover), so the preflight refuses
  every state some start would refuse.
- `arkdeck-agentd --cutover-preflight` renders it as
  `{"kind": "loaderTransitionsCoverTarget", "targetId", "expectedBindingRevision", "jobIds": [...]}`
  in both passes; `runtime service update|install` renders `Jobs <a>, <b> each await a Loader binding
  of target <t> at binding revision <n> at their enter-Loader transitions, and the Rust Runtime refuses
  to start while two or more cover one target (jobNotRunnable: multiple unresolved Loader
  transitions); their outcomes stay unknown and are never replayed: stop, keep them as they are and ask
  the maintainer, then run the preflight again` (exit 75, nothing changed).
- Runbook §3 step 1 refusal table: one row for the new kind. Handling is **stop, maintainer decides**:
  Swift's `flash bind-loader` refuses the same ambiguity (`jobNotRunnable`), so there is no published
  settlement path; the outcomes are unknown and only `POL-RECOVERY-001` or a maintainer ruling moves
  them.

## Tests

- `arkdeck-agentd/tests/production_composition.rs`
  `the_loader_transitions_that_refuse_the_start_refuse_the_cutover_preflight_first`: the real production
  daemon over the `lineage.advanced` Rockchip scenario. One lane-held parked Loader transition: the
  preflight has no Loader block and carries the Job over, and the daemon starts and serves (naming it).
  A second one on the same Target: the daemon exits 69 with `jobNotRunnable("multiple unresolved Loader
  transitions cover target TGT-8b3d0a34cf32")`, and the preflight over that same state answers exactly
  `loaderTransitionsCoverTarget` naming both Jobs at revision 1, leaving the home unchanged (the index's
  `-shm` read mark aside). Before this change that state was `clear` for the Loader rules.
- `arkdeck-agentd/tests/cutover_preflight.rs`
  `two_parked_flashes_at_one_targets_loader_transition_refuse_the_cutover_the_start_would_refuse`
  (beside the 1013 test): four pairings (both lane-held; one journal with another outstanding intent;
  one strict + one lane-held; both strict) are refused in both passes with the new block, plus the
  existing strict block for each strict Job, tree unchanged; a single lane-held Job is carried over; two
  at different binding revisions are both carried over.
- `arkdeck-contract` `two_loader_transitions_for_one_target_and_revision_refuse_the_cutover_by_name`;
  `arkdeck-cli/tests/runtime_service.rs` `a_cutover_names_what_only_the_swift_runtime_can_settle`
  extended with the new block's text.

## Local targeted checks

Worktree `agent-a16bc7fbfb3a733f2`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-lane2-target`,
`CARGO_BUILD_JOBS=2`, logs under `/private/tmp/arkdeck-lane2-logs/`.

| Command | Exit |
|---|---|
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (covers the four changed crates and every dependent of `arkdeck-contract`) | 0 |
| `cargo test -p arkdeck-contract -p arkdeck-hoststore` (`test-contract-hoststore.log`) | 0 |
| `cargo test -p arkdeck-agentd -p arkdeck-cli` (`test-agentd-cli.log`; 92 test binaries, no failure) | 0 |
| `sh scripts/check-sdd.sh` (runbook and this record; `check-sdd.log`: 0 errors, 0 warnings) | 0 |

Not run: `generate-contract.py --check` (no contract input changed), Swift and App lanes (no Swift
change), the full unified gate (CI's job).

## CI

PR #2302, head `e6fca6595`, Swift CI run `36416346545`: `guard`, `plan`, the four Rust lanes
(host-independent, ubuntu-latest, macos-26, windows-latest), `ds-tokens`, `ds-interactions` and the
`swift` aggregate green; `swift-tests` and `app-build` were not selected. Merged as `092b45eb8`.
(Recorded by the RC-readiness slice, `rc-readiness-run.md`.)
