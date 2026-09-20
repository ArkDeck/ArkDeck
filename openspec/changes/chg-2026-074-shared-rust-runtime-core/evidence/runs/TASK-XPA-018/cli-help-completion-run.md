# TASK-XPA-018 — `help` and `completion` rendered from the registry (macOS, 2026-09-20)

TASK-XPA-018 remains in progress. Base: protected main `645f21ef` (#2076); no stack. Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
entitlement, `openspec/contracts`, `openspec/specs` or constitution change.

The last two leaves of the audit's category 2 that need no Runtime, and with them the last argv
deviation that was a defect: `help` was served only as `--help`, and `completion` not at all.

## What changes

- **`arkdeck help [path…]`** renders from the registry copy, as Swift's `CLIHelpRenderer` renders
  from the registry: the root lists the first token of every leaf this CLI serves; a node lists its
  subcommands; a leaf gives its summary, usage, published options with their placeholders and
  summaries, positionals, its exactly-one-of and at-most-one-of groups, its output modes, whether it
  connects to the Runtime, and the Catalog operation it submits. A retired leaf's help says it is
  retired and names its replacement; a refused stub says it is not caller-facing. A path the registry
  does not know is `invalidCommand`. `<leaf> --help` now renders that leaf's help instead of one
  hand-written usage string for every leaf, which is the copy that drifts (Swift replaced the same
  literal for the same reason), and `<node> --help` is that node's help, as Swift answers it — the
  parse asks the registry whether the path it could not serve is a node, which is why `is_node` reads
  the registry and not the served set the parse is deciding.
- **`arkdeck completion <shell>`** writes the script for `bash`, `zsh`, `fish` or `powershell` to
  stdout and nothing else (CLI spec §8.1), generated from the same registry as Swift's
  `CLICompletionScripts`: one row per command prefix, and each leaf completing to its published
  options, its enumerated positionals and `--help`. Identities are never completed (§10). The leaf
  takes no output mode, endpoint or correlation option; any of them, a missing shell or an unknown
  one is `invalidOption` (64), as Swift's registry answers.
- Both leaves are listed by `arkdeck commands` from this slice on, because the parser serves them.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` `every_copied_swift_argv_fixture_replays_but_the_known_deviations` | `help`'s two cases now replay; the only cases still answered otherwise are `runtime tool register`'s two `--socket` cases, the divergence recorded in the audit |
| `argv_fixtures.rs` `help_and_completion_render_the_registry_this_cli_serves` | Root, node and leaf help, `<node> --help` and its path, a node this CLI serves nothing under and a node's help in a machine mode both refused (64), a retired leaf's help, and an unknown path refused; a script for each published shell that names the served leaves and their published options and no leaf this CLI refuses; the binary's `completion zsh` is that script; the refusals of a missing or unknown shell and of an output mode |
| `argv_fixtures.rs` `commands_lists_the_leaves_this_cli_serves_in_the_registrys_order` | Now every replayed fixture's leaf, `help` included |

## Declared differences from Swift

- **`--socket` on `runtime tool register`.** Swift's parser refuses the option unless `--kind deveco`,
  because its HDC registration runs in the CLI's own process; this CLI sends every registration to
  the Runtime that owns the Bootstrap store, so the endpoint is exactly what the leaf needs and
  `tool_register.rs` drives it that way. The difference was made in `cli-parse-staging-run.md`
  (#2079) and the coordinator accepted it on 2026-09-20 as a declared difference (the `#2004`
  precedent), not a defect. It stays pinned in `argv_fixtures.rs` and named in the audit's table;
  once the Swift CLI is deleted with M5 there is no counterpart left to compare against, so the pin
  goes with it.

## Local targeted checks

Run 2026-09-20 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 164 passed, 0 failed |
| The audit, rewritten from this head | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | the tables of `cli-parity-audit-20260919.md`: 140 / 59 / 42 / 15, 100 of 209 leaves served |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

Recorded once this PR's CI finishes.
