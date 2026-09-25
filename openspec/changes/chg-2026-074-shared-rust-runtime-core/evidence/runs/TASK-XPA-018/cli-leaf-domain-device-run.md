# TASK-XPA-018 — the remaining domain leaves without a capture preset on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `6c47b55e1`, where C1 (#2208, the domain leaves' handler)
merged; no stack. Slices C2, C3 and C4 of the CLI remaining-leaves lane, in one PR: each of the
20 leaves is one more name on C1's handler and has no code of its own, as in Swift, where every one
of them goes through `runDomainOperation` (the hub was told why). Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change. Host evidence only: a fake Runtime
answering Swift's recorded executor scripts. Per the coordinator's ruling of 2026-09-26, this PR
adds no `tasks.md` line; this record is the evidence.

## What changes

The Rust CLI serves, each over its registry `catalogOperation` through `domain_leaves`:

- C2, device leaves: `target observe` (`observe.device@1`), `input tap|long-press|swipe`,
  `port-forward create|remove`, `screen record` (`capture.screen-sequence@1`), `diagnostics
  capture` (`capture.diagnostics@1`, without a preset).
- C3, workspace changes: `workspace isolate|checkpoint|patch|revert|build|test|sign|symbolize|sweep`.
- C4, debug: `debug hap` (GJ-2), `debug template run`, `debug native deploy` (GJ-3).

The input and port-forward leaves are `deviceMutation`, and `workspace sign` of the main tree needs
a capability a person had the Runtime issue: in every case the CLI forwards the caller's
`--capability` as the reference the Runtime already holds, and without it submits no authorization,
so the Runtime decides (an isolated copy's sign is covered by the Runtime's own issuance). The CLI
creates, widens or manages no capability.

`target observe` is a domain leaf, not a Target presentation read: `target_resources` now leaves it
alone, where it had refused any `target` leaf it did not know.

## Declared differences from Swift

As C1's (`cli-leaf-domain-host-run.md`). The one that now matters: a device leaf that pauses names
`arkdeck agent resume --resume-token <token>`, which the Rust CLI still sends to the Runtime's
`agent.resume` rather than resuming the client-side pending record as Swift's `executor.resume`
does. The pause itself (its envelope, exit status and pending record) is Swift's byte for byte; the
resume is its own slice, with its own Swift oracle.

## Tests (`tests/domain_leaves.rs`, the CLI process against a fake Runtime)

- `every_scenario_replays_through_its_own_leaf`: all 29 versioned scenarios of the executor oracle
  through the leaf Swift ran them through (`workspace build`, `workspace patch`, `input tap`),
  unchanged: frames, connections, pending records, receipts, refusals and plain failures. This now
  includes `hostArtifactConsumerKeepsItsTarget`, which only `workspace patch` can replay.
- `every_leaf_replays_swifts_recorded_runs`: every served domain leaf (28 now) drives one of the 28
  name-independent scenarios in turn, with the operation named as that leaf's.
- `a_mutation_leaf_forwards_only_the_capability_it_is_given`: `workspace sign` and `input tap`,
  with `--capability` (forwarded in the submitted request's `authorization`) and without (no
  `authorization`).
- `argv_fixtures.rs` replays Swift's argv fixtures for the 20 newly served leaves (zero
  deviations). Its check that a registry node this CLI serves nothing under refuses `--help`
  now finds those nodes from the registry and the served leaves instead of naming one:
  `debug template run` is served here, and #2211 serves the `runtime update` leaves, so any fixed
  example goes stale as the lane lands (the coordinator's review of #2211 and #2212 found the
  second one; checked with #2211's commit applied on top).

Mutation check, baseline passing, each reverted after (`/private/tmp/arkdeck-cli-lane-mut-c24.py`):
`workspace patch` left unserved; `target observe` judged as a Target presentation read. Each fails a
named test above.

## Counts

- Rust CLI served leaves: 153/209 → 173/209.
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 33 → 13, category 3 15, category 4 8.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-c24-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
