# TASK-XPA-018 — parse refusals reported as Swift's CLI reports them (a3, macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the third slice of the Rust CLI's
batch 1 (G5 queue slice 14; a3 in the audit's split). It was first pushed
stacked on #2172's head `275a827b`. After #2172 merged it was rebased onto
`main` `e6119b0d3` (#2172, on #2171's `job wait`), together with the fix for
its first CI run (below).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime
is involved: parsing happens before any connection. No Swift source or test,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change.

## What changes

Before this slice, a Rust CLI parse refusal named its leaf only for the nine
leaves answered by name. Every other refusal printed `registry.parse` as its
command, no `details`, and wording of its own. Swift's refusals come from its
registry parser before any handler runs. Each one carries its words and
`details`, and names the leaf once the path resolved
(`CLIRegistryError.command`).

- **Swift's registry pass is ported** (`registry_parse.rs`) over the
  registry copy, `command_registry.json`, in Swift's order:
  1. The global options ahead of the command path: `--help`, `-h`,
     `--version`, `--output`.
  2. The command path, walked down the registry's nodes to a leaf. An
     unknown command, an unknown subcommand, a node without its subcommand
     and an option before it each get Swift's words, and the node's children
     in Swift's `childTokens` order.
  3. The leaf's own options, the trailing global region and the positionals.
     A duplicate is `<token> was given more than once`, a missing value
     `<token> requires a value`, and an option the leaf does not declare
     ``​`<path>` does not accept <token>; run `arkdeck help <path>` for its options``.
  4. The output mode against the leaf's `outputModes`.
  5. Swift's `validate`. It checks each option's requirement and grammar in
     declaration order:
     - opaque;
     - positive and non-negative integers with Swift's `outOfRange` bound;
     - the control-request pattern;
     - `hexDigest` as Swift's `Character` reads it;
     - a duration of at most the grammar's maximum;
     - an enumeration.

     Then the mutual exclusions, the exactly-one-of groups and the
     positionals. Each refusal has Swift's `details` and leaf.
- **It reports refusals; it never decides them.** `parse` first runs this
  parser, as before, which accepts or refuses.
  - A refusal that Swift's registry pass also makes is answered as Swift's,
    since Swift's parser would have refused first.
  - A refusal only this parser makes, about what a value means, keeps its
    words and now names the leaf the path resolved to, as Swift's handler
    failures do.
  - A path that the registry names but this CLI does not serve keeps its own
    `invalidCommand`.

  Nothing accepted before is refused now. The options this parser serves
  beyond Swift's registry (`--timeout` on `target display-name set`, for
  one) stay served.
- **A global option ahead of the path is judged where Swift reads it.**
  CLI spec §5.1 lets a global option stand ahead of the first path token or
  after the leaf's arguments. This parser reads `--control-request-id`,
  `--timeout` and `--socket` in either place; Swift's parser reads only
  `--help`, `-h`, `--version` and `--output` ahead of the path.
  - The pass therefore judges each of those three, with its value, just
    after the leaf's path, as the leaf's own. The leaf must declare it, the
    same option given again after the leaf's arguments is a duplicate, and
    its grammar applies.
  - When the path names no leaf, they are left out: Swift refuses the path
    first.
  - They are not moved past an option Swift refuses ahead of the path, and
    that option is still refused there.
  - The first push lacked this, and CI's read-only host check went red on it
    (see CI).
- **The argv replay now checks the leaf** a refusal names against Swift's
  fixtures. Swift's generator records `command` exactly when its
  `CLIRegistryError` has one. All 425 failure cases of the 130 copied
  fixtures (784 cases, `job.wait.json` included) name the same leaf as
  Swift's.

Swift's check that refuses `--socket` on `runtime tool register` unless the
kind is DevEco is left out. It stays the declared divergence of that leaf.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` `every_copied_swift_argv_fixture_replays_but_the_known_deviations` | Every copied case replays: dispatch, help, and each refusal's code, exit status and now its leaf. The known deviations are unchanged |
| `argv_fixtures.rs` `a_refusal_is_reported_as_swifts_parser_reports_it` | Through `parse`: a missing required option, a duplicate, an undeclared option, an output mode outside the leaf's, an integer out of range and a value outside an enumeration, each with Swift's words, `details` and leaf. Also: a meaning-level refusal naming its leaf, an unknown command naming none, and an option beyond Swift's registry still accepted |
| `registry_parse::tests` (unit) | The pass itself: the leaf and details of each kind of refusal, the path walk (unknown command and subcommand, a node needing its subcommand, an option before it, one before the path), help left to the parser and refused in a machine mode given ahead of the path, and each grammar's words |
| `registry_parse::tests::a_global_option_ahead_of_the_path_is_judged_where_swift_reads_it` (unit, added with the fix) | The read-only host check's two refusal argv (an unknown `job` subcommand, `doctor --shell`) refused for what follows the leading options. A leading option judged as the leaf's own: a required option still missing, a leaf that does not declare it, the same option again after the leaf's arguments, and its grammar. Nothing moved past an option Swift refuses ahead of the path, into a path without a leaf, or without its value |
| `argv_fixtures.rs` `a_refusal_is_reported_as_swifts_parser_reports_it` (extended with the fix) | The same two argv through `parse`: `invalidCommand` naming no leaf, and `invalidOption` naming `doctor`. A leading `--control-request-id` is still accepted |
| `flash_host_facts.rs` (changed) | `flash prerequisites` and `flash lane-preview` without a required option are now refused in Swift's registry words (``​`flash lane-preview` requires --target <target-id>``) rather than its handler's. This closes the wording difference #2168 recorded for a3 |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-xpa018-a3-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-xpa018-a3-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; 265 passed on #2172's first base, then 275 on this stack (`a6294ec3`, with #2171, plus #2172) (`arkdeck-xpa018-a3-test.log`). With the fix, on `main` `e6119b0d3`: 276 passed, none failed (`arkdeck-a3fix-test.log`; fmt and clippy exit 0, `arkdeck-a3fix-fmt.log`, `arkdeck-a3fix-clippy.log`) |
| Read-only host check (with the fix) | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`, exit 0 (`arkdeck-a3fix-readonly.log`) |
| Mutations | four, one at a time: the leaf not named; Swift's refusal not taken; the registry pass deciding instead of reporting; the grammars skipped | each fails `argv_fixtures.rs` or the unit tests. Sources restored by digest, and those binaries and `flash_host_facts.rs` rerun green (`arkdeck-xpa018-a3-mutations.log`, `…-rerun.log`) |
| Mutation (with the fix) | the leading options left where they stand | the read-only host check fails on its `unknown-command` case with CI's assertion, and both tests above fail. Source restored by digest, then the host check and both test binaries rerun green (`arkdeck-a3fix-mutation.log`, `…-rerun.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-xpa018-a3-sdd.log`; with the fix, `arkdeck-a3fix-sdd.log`) |

The first attempt ran the registry pass ahead of this parser, and so refused
what Swift's registry does not declare. It broke one unit test, and hung one
test harness that waited on a connection. The slice was changed to report
refusals, never to decide them (above).

Not run, because no input they read changed:

- `generate-contract.py --check`: no contract input changed.
- The Swift tests: no Swift source changed.
- The other crates: `arkdeck-cli` has no dependents.

The first push did not run the read-only host check, which runs this
CLI's binary; the fix's checks do.

## CI

- First push (head `c18150047`, run `36099271583`): `guard` passed. The
  Rust workspace lane failed on macOS, Linux and Windows, so `swift` failed.
  In the candidate contract view, `check-readonly.py` asserts `invalidCommand` for
  `arkdeck --output json --control-request-id ctl-unknown-command job
  no-such-command`. The registry pass had answered `invalidOption`, Swift's
  refusal of `--control-request-id` ahead of the path. This is a code
  failure, fixed above; no assertion was relaxed.
- With the fix, rebased onto `main` `e6119b0d3`: pending.
