# TASK-XPA-018 — `arkdeck commands` on the Rust CLI, every served leaf's argv fixture replayed, and the parity audit (macOS, 2026-09-19)

TASK-XPA-018 remains in progress. Base: protected main `674c2ed7` (#2060); no stack. Written on
`c3870c3d`; #2060 and #2061 changed nothing the CLI, the control routes or the ledger holds, and the
audit reads the same on both. Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No production Swift source, control schema, corpus,
Catalog, entitlement, `openspec/contracts`, `openspec/specs` or constitution change; one new Swift
contract test.

The coordinator's XPA-018 assignment asks for the 256 entries of
`openspec/contracts/cli-feature-coverage.json` to be reconciled against the Rust CLI's own
`arkdeck commands --output json`, adding that leaf first. This slice adds it, makes every leaf it
lists replay its Swift argv fixture, and records the audit (`cli-parity-audit-20260919.md`).

## What changes

- **`arkdeck commands`** (`command_registry.rs`, the parser, `main.rs`). It needs no daemon. Its
  `--output json` answer is Swift's `CLIRegistryProjection` — `{commandRegistrySchemaVersion,
  commands}` — for exactly the registry leaves whose path this parser serves, each entry Swift's own,
  in the registry's order, in Swift's local envelope (`local_success_envelope`: `meta` is
  `cliVersion` and `controlRequestId`, with no control protocol, as `CLIResultEnvelope.success`).
  Human output is one path per line, as Swift's. Like Swift's leaf it takes only `--output
  human|json`; `jsonl`, `--endpoint`, `--socket` and `--control-request-id` are `invalidOption`.
- **`command_registry.json`** (new): Swift's projection of its whole registry, 209 leaves, written from
  the published `openspec/contracts/cli-command-registry.yaml` (blob `f4263d41`) as
  `{"commandRegistrySchemaVersion": schemaVersion, "commands": commands}`, sorted keys, two-space
  indent. `CLIRustCommandRegistryCopyContractTests` (Swift, new) requires it to equal
  `CLIRegistryProjection.result()`, so a registry change fails there until it is written again:

  ```bash
  /private/tmp/arkdeck-validation-venv/bin/python -c 'import json,yaml; r=yaml.safe_load(open("openspec/contracts/cli-command-registry.yaml")); open("rust/crates/arkdeck-cli/src/command_registry.json","w").write(json.dumps({"commandRegistrySchemaVersion":r["schemaVersion"],"commands":r["commands"]},indent=2,sort_keys=True,ensure_ascii=False)+"\n")'
  ```

- **Argv fixtures.** The Swift argv fixtures of the 41 served leaves that had no copy, and of
  `commands`, are copied unchanged into `rust/tests/fixtures/current-cli-argv` (the 48 existing
  copies were checked byte-identical to Swift's): 90 fixtures, 577 cases. `argv_fixtures.rs` (new)
  replays all of them, and pins the 14 cases of six served leaves this parser still answers
  otherwise (the audit's table; the five `--socket` cases only on macOS, since off macOS every
  `--socket` is `unsupportedOnPlatform`, CLI spec §11.1). The fix is the next slice.
- **The audit**: `cli-parity-audit-20260919.md` and the read-only `cli-parity-audit.py` that produces
  its tables from the ledger, the registry copy, `arkdeck commands`, the pinned deviations and
  `arkdeck-control`'s method match.
- **`rust/README.md`**: one paragraph after the CLI's first examples.

`cli-feature-coverage.json` is not edited: it is Swift's export, held to the build by
`CLIMachineContractTests.testPublishedBundleMatchesThisBuild`, and its macOS status says the entry's
contract is closed, not that Rust serves it (the audit's last section).

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` `every_copied_swift_argv_fixture_replays_but_the_known_deviations` | Every case of every copied fixture: the leaf, help, or Swift's refusal code and exit status; the deviating cases are exactly the pinned ones |
| `argv_fixtures.rs` `commands_lists_the_leaves_this_cli_serves_in_the_registrys_order` | `commands` lists exactly the leaves whose fixtures replay, `help` aside, in the registry's order, each entry the registry's own |
| `argv_fixtures.rs` `the_commands_leaf_answers_as_swifts_local_envelope` | The binary's `commands --output json` is one canonical document with Swift's local meta and the registry answer; human output is one line per served leaf; `--control-request-id` and `--output jsonl` are `invalidOption` (64) |
| `CLIRustCommandRegistryCopyContractTests` (Swift) | The Rust copy equals `CLIRegistryProjection.result()` |

## Audit result

129 entries implemented, 64 with the leaf missing but the daemon routed, 42 blocked on a missing
daemon method or host subsystem, 21 tombstones under CLI spec §12. Across the registry's 209 leaves
the Rust CLI serves 89. The dashboard's CLI cell, by its own definition, reads 87 / 256
(90 parser names). The details are in `cli-parity-audit-20260919.md`.

## Local targeted checks

Run 2026-09-19 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`; each exit code was read
directly.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 162 passed, 0 failed |
| The registry copy (Swift) | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIRustCommandRegistryCopyContractTests` | exit 0; 1 test, 0 failures (0.26 s) |
| The audit | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | its output is the audit's tables |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

The first run (head `3c1860fb`, run 35453410335) failed twice. The Rust workspace on `ubuntu-latest`
and `windows-latest` failed the replay: one more `--socket` case than those named
`macosCompatibilityOption` — `runtime tool register`'s `devecoSocket` — is `unsupportedOnPlatform`
off macOS, as every per-leaf test already expects. The replay now applies that rule to every
`--socket` case, which also makes `hdcSocketRefused` a macOS-only deviation. `swift-tests` failed on
the base's `JobPlanAnalyzerOracleContractTests` (line 105), which #2062 fixed on main; this slice's
Swift test passed in that run. The branch was then moved onto `655c8199`.

The final run is recorded once it finishes.
