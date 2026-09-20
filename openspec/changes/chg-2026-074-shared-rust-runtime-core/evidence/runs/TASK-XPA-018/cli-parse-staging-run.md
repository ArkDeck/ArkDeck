# TASK-XPA-018 — the Rust CLI parses as Swift's registry parses, and answers its retired and refused leaves (macOS, 2026-09-20)

TASK-XPA-018 remains in progress. Base: protected main `5205b3ec` (#2075); no stack. Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
entitlement, `openspec/contracts`, `openspec/specs` or constitution change.

The audit's first list (`cli-parity-audit-20260919.md`) was the fourteen argv cases six served
leaves answered otherwise, and the first group of category 2, the leaves that need no Runtime. This
slice closes both but `help` and `completion`, which render text and follow in the next slice, and
one case that is a divergence rather than a defect (below). The audit is updated with the new
classification: 138 entries implemented, 61 with the leaf missing but the daemon routed, 42 blocked
on an owner, 15 tombstones; 98 of the registry's 209 leaves served; the dashboard's CLI cell
96 / 256 by its own definition.

## What changes

- **The parse stops at the registry's grammar.** Swift's parser judges only what its registry
  declares — unknown, repeated or missing options, and each option's grammar — and leaves what a
  value *means* to the handler that sends the request. Five leaves judged it at parse and therefore
  answered a different code, or answered before Swift's parser had refused something else:
  - `artifact import release` took `--import` as an opaque value (the registry's grammar) instead of
    an Import identity; Swift sends the identity as given and the Runtime judges it.
  - `runtime bundle register` and `runtime tool register` take any `--file`/`--root`; which path the
    kind needs and whether it is canonical and absolute is judged in `validate_bootstrap_request`,
    before any connection, as Swift's handler judges it after the parse. A missing `--file` on the
    bundle leaf is now `invalidOption` (64), the registry's answer for a required option, and
    `--file` with `--root` is the registry's mutual exclusion.
  - `session cleanup apply` and `session export apply` require `--preview-id` and a lowercase
    SHA-256 `--preview-digest` at parse (`invalidOption`), and the preview identity is judged in
    `validate_session_request`, before any request, as Swift's handler judges it (`invalidInput`,
    "Session cleanup|export apply requires one exact preview tuple").
- **The nine leaves that are not executable** — the tombstones `agent chat`, `flash plan`,
  `flash preview`, `flash execute`, `flash continue`, `flash postflight` and the refused stubs
  `capability draft|install|revoke` — are answered from the registry copy by
  `command_registry::answer_by_name`, before any flag is judged, as Swift's `parseLeaf` answers them
  ("parsing its old flags strictly would answer a caller who typed the retired command *with its
  retired flags* by naming the flag"). A tombstone is `commandRemoved` (exit 64) with Swift's
  message and `details` (`command`, `lifecycleStatus`, `replacementArgvPattern`, `removalVersion`,
  and `reason` when nothing replaces it); a refused stub is `invalidCommand` with its reason. Help is
  still the leaf's own, and help in a machine mode is refused.
- **`runtime tool register` keeps `--socket` for every kind.** Swift's parser refuses it unless
  `--kind deveco`, because its HDC registration runs in its own process; this CLI sends every
  registration to the Runtime that owns the Bootstrap store, so the endpoint is exactly what the leaf
  needs — `tool_register.rs`'s endpoint tests drive it that way. Taking Swift's refusal here made the
  CLI answer without connecting and left those tests waiting on a connection that never came. The
  divergence is deliberate and stays pinned in `argv_fixtures.rs` and in the audit's table.
- **A refusal names its leaf.** `CliError` carries the leaf its path resolved to (Swift
  `CLIRegistryError.command`), and a machine answer prints that instead of `registry.parse`. Only the
  nine leaves above set it in this slice; the other parse refusals follow with their `details`.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` `every_copied_swift_argv_fixture_replays_but_the_known_deviations` | 99 fixtures, 595 cases: the nine leaves' fixtures are copied in, and the only cases still answered otherwise are `help`'s two |
| `argv_fixtures.rs` `a_retired_leaf_answers_swifts_removed_command_envelope` | `agent chat`'s refusal renders Swift's published envelope sample (`result-removed-command.json`, copied unchanged) byte for byte; a retired leaf is answered by name before its flags; `flash continue` carries its reason and a null replacement; `capability install` is the refused stub's `invalidCommand`; `flash plan --help` is help |
| `bundle_registration.rs`, `current_surface.rs` (changed) | The paths and preview tuples they pinned at parse are pinned where they are judged now, with Swift's codes: `invalidOption` for a missing required option, `invalidInput` before any request |

## Local targeted checks

Run 2026-09-20 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 163 passed, 0 failed |
| The audit, rewritten from this head | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | the tables of `cli-parity-audit-20260919.md` |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

Recorded once this PR's CI finishes.
