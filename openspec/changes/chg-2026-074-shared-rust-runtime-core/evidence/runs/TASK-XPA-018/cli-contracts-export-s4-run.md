# TASK-XPA-018 — contracts export S4: the argv fixtures and the fixture index (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is contracts-export slice S4. It
covers the 209 argv fixtures and the fixture index, and retires the Rust
tests' copies of Swift's CLI fixtures. It also makes the Rust CLI refuse
`runtime tool register --socket` as Swift's does. Base: `main`
`dade8f042`, where S3 (#2189) merged. It was built on S3's branch, whose tree
the merge equals.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change; the bundle itself is unchanged.

## What changes

- `machine_contracts` gains a port of Swift's `ArgvFixtures`: one document
  for each of the registry's 209 leaves, with the cases Swift's generator
  builds.
  - The valid argv is the path, then each required published option, one
    member of each exactly-one group and each required positional, each
    with Swift's sample for its grammar.
  - Every leaf also gets `leafHelp`. An executable leaf gets
    `unknownOption`, `duplicateOption`, `missingRequired`, `jsonlRefused`,
    `endpointRefused` and `macosCompatibilityOption` where Swift's rules give
    them, and the registration leaf gets its two socket cases.
  - Each case's expected outcome is this CLI's own answer. A leaf that is
    not executable is answered by name (`command_registry::answer_by_name`),
    as the parser serves it. Any other is answered by the registry pass
    (`registry_parse`).
  - A refusal records its code, exit category and status, and the leaf it
    names. Where the registry publishes that leaf as legacy or deprecated, it
    also records the leaf's lifecycle (`command_registry::lifecycle`, which
    `with_lifecycle` reads too).
  - `index.json` lists every other fixture.
  - `argv_fixture(command)` returns one leaf's document, for tests.
- The registry pass now also says what Swift's parser accepts an executable
  leaf's argv as (`Accepted`, Swift's `CLIInvocation`): a dispatch with the
  handler's argv, the leaf's help, `commands` in its mode, `completion` for
  its shell, or the root's help for a bare `help`. What it leaves to the
  parser is unchanged, and `arkdeck help <path>` joins it: the parser
  answers it, and no fixture asks for it.
- The registry copy is parsed once (`command_registry::projection`), and
  the pass reads the same parse. Rendering the 225 fixtures took 7.8 s in a
  debug build, most of it spent parsing the 628 KB copy again for each
  refusal's lifecycle. It now takes 0.26 s.
- `owned.json` gains 210 digests. The export now owns 233 of the 235
  products: every fixture, and every contract but the feature coverage and
  the App's capability registry (S5).
- `rust/scripts/refresh-contract-digests.py` (new) rewrites the digest table
  from the committed bundle, with a `--check` mode; see "Changing the
  registry".

All 225 fixture files render byte for byte as published on the first run
(`diff -r` against `Fixtures/CLI/` is empty). So on every generated case,
the registry pass and the parser's by-name answers equal Swift's parser:
209 documents, 1,233 cases.

## `runtime tool register --socket` follows Swift

Swift's parser refuses `--socket` on the registration leaf unless `--kind`
is `deveco`, with "HDC registration does not accept --socket". The Rust CLI
took it for every kind. The parity audit recorded that as a declared
difference, accepted by the coordinator on 2026-09-20
(`cli-parity-audit-20260919.md`), and the argv replay pinned it as two known
deviations. On 2026-09-25 the hub ruled that the Rust CLI follows Swift.

Both the parser (`parse_argv`) and the registry pass now refuse it, with
Swift's words, details and leaf. As in Swift, the refusal comes before help,
wherever the option stands. An HDC registration still reaches another
Runtime through `ARKDECK_ENDPOINT`, which the end-to-end tests now use, as
does `rust/scripts/check-hdc-register.py` (every command it runs names its
temporary daemon there). The known-deviation list is gone. The audit script reads that list from the
test's source, so it now finds no deviation.

Off macOS, `--socket` is `unsupportedOnPlatform` (CLI spec §11.1), and that
refusal now stands where Swift's registry pass would refuse the argv too:
`parse` reported Swift's refusal over any of its own, so the new socket rule
turned the platform refusal into `invalidOption` on Linux and Windows (the
first CI run, below). Swift's parser only ever judged macOS argv. `parse_argv`
refuses no other option as the platform's, so nothing else changes.

## The copies are retired

The Rust tests read Swift's argv fixtures from 135 copies in
`rust/tests/fixtures/current-cli-argv`, which `check-contracts.py` kept
byte-identical to the bundle. One envelope came from
`rust/tests/fixtures/current-cli-envelopes`. The export now renders all of
them, and the digest table holds them to the bundle. The 21 test files that
read a copy now read the rendered document: `argv_fixture` for the argv, and
`fixture_products` for the envelope. Their assertions are unchanged.

The copies are removed, and so is `verify_current_cli_argv`. The argv replay
now covers the leaves this CLI serves (`arkdeck commands`, 135 of them),
with no deviation left.

## Changing the registry

A change to Swift's command registry rewrites argv fixtures and the fixture
index. Swift's own checks already required regenerating the bundle and the
Rust registry copy (`CLIRustCommandRegistryCopyContractTests`). It now also
requires the digest table, in the same PR:

1. regenerate the bundle with Swift's export (the commands are in the S2
   record, "Changing a contract input");
2. `python rust/scripts/copy-command-registry.py`;
3. `python rust/scripts/refresh-contract-digests.py`.

The table lists every committed fixture and the contract products it already
owns. A leaf added or removed adds or removes its fixture's row. The Rust
test then shows whether the Rust export renders the new bundle; a grammar
this port has no sample for panics, naming the grammar.

## Tests

| Test | What it holds |
| --- | --- |
| `machine_contracts.rs::every_owned_product_is_the_published_bytes` | All 233 owned products: 230 render to their committed digests; the command registry, result and control-plane schemas equal the committed files in a checkout |
| `argv_fixtures.rs::every_served_leafs_argv_fixture_replays` | Every case of the 135 served leaves' fixtures replays through the parser, with no deviation |
| `tool_register.rs::hdc_registration_refuses_socket_as_swift_does` (macOS) | Swift's refusal, in full, with `--socket` after the path, ahead of it, and ahead of `--help`; DevEco keeps the endpoint |
| `tool_register.rs::the_published_argv_fixture_replays` | The registration leaf's fixture, the socket cases included |
| `lib.rs` `tests::a_platform_refusal_stands_where_swift_refuses_too` | Off macOS, the platform's refusal of `--socket` stands over Swift's; any other refusal of that argv is Swift's. It runs on every host, since the platform branch cannot run on macOS |
| `machine_contracts::tests::a_duration_is_sampled_as_swift_samples_it` | The duration sample, which no published case uses yet |
| The 21 test files that read a copy | The same assertions, over the rendered documents |

## Mutations

Each mutation changed one place, ran `tests/machine_contracts.rs`,
`tests/argv_fixtures.rs`, `tests/tool_register.rs` and the library's unit
tests after an unmutated baseline, and restored the file by digest
(`/private/tmp/arkdeck-s4-mut.log`, `-m2.log`, `-m15.log`). All 15 were
killed.

| Mutation | Killed by |
| --- | --- |
| An opaque value sampled otherwise | the argv digests |
| Every duration sampled as 1ms | `a_duration_is_sampled_as_swift_samples_it`. It survived the first run: no published case samples a duration, since no duration option is required and each leaf's first macOS-compatibility option is `--socket`. The unit test was added for it |
| No member of an exactly-one group in the valid argv | the generator's own check that the valid argv is accepted (every test rendering the fixtures) |
| No `duplicateOption` case | the argv digests |
| The endpoint case without the registration leaf | the argv digests |
| A refusal without its leaf's lifecycle | the argv digests |
| A refusal without the leaf it names | the argv digests; the replay |
| The handler given the argv after its first path token | the argv digests |
| The registry pass taking `--socket` for an HDC | the argv digests; both replays |
| The parser taking `--socket` for an HDC | both replays; `hdc_registration_refuses_socket_as_swift_does` |
| The index without the envelopes | the index digest |
| `commands` answered in `json` by default | the argv digests; the replay |
| `help` without a path left to the parser | the generator's check (every test rendering the fixtures) |
| A retired leaf's help answered as the root's | the argv digests; the replay |
| Swift's refusal reported over a platform refusal | `a_platform_refusal_stands_where_swift_refuses_too` |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-s4-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s4-clippy.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s4-winclippy.log`). A first run found `Value` unused in `import_resources.rs` off macOS; the annotation that used it on every platform is back |
| clippy, Linux | the same with `--target x86_64-unknown-linux-gnu` | exit 0 (`arkdeck-s4-linuxclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 335 passed, none failed (`arkdeck-s4-test3.log`) |
| Digest table | `verify_contract_bundle_digests()` against the checkout | passes (230 products) |
| Refresh script | `python rust/scripts/refresh-contract-digests.py [--check]` | `--check` exit 0; a rewrite is byte for byte the table; a drifted row fails `--check` with exit 1, naming the fix, and a rewrite restores it |
| Registry copy | `python rust/scripts/copy-command-registry.py --check` | exit 0 |
| Contract-check tests | `python -m unittest test_contract_checks` in `rust/scripts` | 45 tests, OK |
| Mutations | `s4_mutations.py` (scratch) | 15 of 15 killed |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s4-sdd.log`) |
| The candidate view's owner scripts that the second CI run did not reach | `check-hdc-register.py`, `check-tool-list.py` and `check-tool-retirement.py` with `--bin-dir` of this build; `test-macos-facade.py` with this build's daemon | each exit 0 (`arkdeck-s4-hdc-register.log`, `arkdeck-s4-check-tool-list.log`, `arkdeck-s4-check-tool-retirement.log`, `arkdeck-s4-facade.log`) |

Not run: `generate-contract.py --check` and the contract views, because no
contract input changes.

## CI

- #2191, first run (head `ddc95f324`, run 36139087089): the Rust workspace
  lanes on `ubuntu-latest` and `windows-latest` failed in
  `every_served_leafs_argv_fixture_replays`. There, the registration leaf's
  two `--socket` cases answered `invalidOption` where `unsupportedOnPlatform`
  is expected off macOS. This is a defect of this change, fixed as described
  above. The lane stops at the first failing test binary, so the binaries
  after `argv_fixtures` did not run on those hosts.
- Second run (head `404c7dc42`, run 36141019071): the Linux and Windows
  lanes passed. The macOS lane failed in `check-contracts.py`'s candidate
  view, at `check-hdc-register.py`, which registered an HDC tool with
  `--socket`. That is the Swift rule this change adopts. The script now names
  its daemon in `ARKDECK_ENDPOINT`. The view stopped there, so the scripts
  after it were run locally (above).
- Third run: pending.
