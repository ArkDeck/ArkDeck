# TASK-XPA-018 — `runtime update *` and `update-feed *` answered by name on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `6c47b55e1` (#2208); no stack. The transition
of slice C9 of the CLI remaining-leaves lane, by the coordinator's ruling of 2026-09-26. Nothing
here is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema,
corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution change. Per the
coordinator's ruling of 2026-09-26, this PR adds no `tasks.md` line; this record is the evidence.

## Why these leaves are answered by name

The coordinator first ruled these leaves be §12 tombstones, then withdrew that ruling: CLI spec §6.3
(`docs/design/arkdeck-cli-product-spec.md:488-489`) keeps `runtime update check|download|handoff|
status|cancel|cleanup` and `maintainer update-feed prepare|assemble` as current product leaves, §12
schedules no removal for them (it only moves `update-feed …` under `maintainer`, :1428), and a
tombstone is the registry's to mark (§12:1462, CLI-REQ-004), which would be a contract change. The
ruling instead:

1. Now, as a declared difference: the eight leaves and the two deprecated `update-feed` spellings
   are answered `blockedByProductDefect` (exit 69, nothing dispatched). The code is §8.4's for a
   missing typed product surface the spec requires (spec :1204); `operationUnavailable` names a
   Runtime, provider, tool or platform condition, and `invalidCommand` a token the registry never
   knew. The registry is unchanged.
2. Next: `maintainer update-feed prepare|assemble` is ported (local, deterministic, no network, no
   private key; a Swift oracle, byte for byte). `runtime update` (network, download isolation,
   signature verification, handoff, and §6.3's "user consent, never a silent install") first gets a
   design note for the hub and the coordinator.
3. Both must land before the Swift CLI is retired, or the maintainer accepts the gap at cutover
   (the coordinator keeps this on the cutover list).

## What changes

- `arkdeck_cli::blocked_leaves` (new): for an argv that names one of these leaves, Swift's registry
  pass (`registry_parse::check`) judges it first, so a missing required option, a malformed value,
  an undeclared option or help asked for in a machine mode is Swift's own refusal, and the leaf's
  help is its help. An argv Swift would dispatch parses, as Swift's parser accepts it, and is then
  answered `blockedByProductDefect` with details `{command, newDispatchCount: 0}`, in the caller's
  rendering: the versioned envelope (with `meta.lifecycle` for the deprecated spelling), the legacy
  `--json` failure document where the leaf declares `--json`, or the human line on stderr (after
  the deprecation warning). Nothing is read, written or connected.
- The leaves are listed by `arkdeck commands`: the registry knows them and this CLI answers them,
  never as unknown. They are counted as served by the lane's metric (`serves()`), and the run
  records say so: answered by name, not ported.
- Only these ten. Answering every registry leaf the Rust CLI does not serve yet this way would list
  them all in `commands` as if they ran, so the other unserved leaves keep their current answer until
  their own slice.

## Tests (`tests/blocked_leaves.rs`)

- `a_blocked_leaf_is_blocked_by_a_product_defect_and_dispatches_nothing`: all ten, each with its
  required options: exit 69, the canonical envelope, the code, details and words, the deprecated
  spelling's lifecycle; the human rendering (warning first for the deprecated spelling); the legacy
  `--json` document where declared; and nothing written at `--out`.
- `the_registry_judges_a_blocked_leafs_argv_first`: `runtime update handoff` without `--consent` is
  the registry's `invalidOption` (exit 64); `--help` is the leaf's help; all ten are listed.
- `argv_fixtures.rs` replays Swift's argv fixtures for the ten newly answered leaves (zero
  deviations): an argv Swift dispatches parses here too.

Mutation check, baseline passing, each reverted after (`/private/tmp/arkdeck-cli-lane-mut-c9.py`):
refusing at parse time instead of after it (the argv fixtures' dispatch cases deviate); skipping
Swift's registry pass. Each fails a named test above.

## Counts

- Rust CLI served leaves: 153/209 → 163/209, of which these ten are answered by name, not ported.
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 33, category 3 (daemon or host owner missing) 15 → 7, category 4 (tombstone per
  §12) 8 → 6.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-c9-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
