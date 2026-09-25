# TASK-XPA-018 — contracts export S5: the feature coverage and the App's capability registry (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is contracts-export slice S5, the
last of the bundle's products. It covers `cli-feature-coverage.json` and
`app-product-capability-registry.yaml`. With it, the Rust export renders
all 235 products of the bundle byte for byte as published. Base: `main`
`acace84a7`, where S4 (#2191) merged.

It also makes the machine-contracts test hold in the contract views, which
a contract-input change runs it in (see "The contract views").

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs`,
constitution or Swift change; the bundle itself is unchanged.

## What changes

- A new module, `feature_coverage`, ports Swift's
  `CLIMachineContracts.FeatureCoverage` and `appRegistryDocument`. The
  manifest has one entry for each control method, published Catalog
  operation, App capability and command leaf, each saying how the product
  surface reaches it:
  - the 105 control-method rulings (`daemonMethodCoverage`: a fronting leaf,
    with a lifecycle, a note or compatibility spellings, or plumbing behind a
    leaf), generated from Swift's table by a script rather than copied by
    hand. Swift's table rules no method `refused`, so that case is not
    ported;
  - the classification rules (the `local` roots, runtime groups, commands and
    prefixes, and the one direct selection under a local group), the
    macOS-only families, and Swift's target command, fixture and platform
    rules;
  - the Catalog's operations from the compiled Catalog, each fronted by the
    leaves whose `catalogOperation` names it, or reached generically through
    `job submit`, an alias noted as such;
  - the App's capabilities, each resolved to the leaves its CLI patterns
    name;
  - every leaf nothing above reaches, with its tombstone, refusal or
    supersession note;
  - Swift's validation: each feature once, closed vocabularies, every
    pattern and leaf resolved, every leaf covered.
- The App's capability table is copied from the published registry into
  `rust/crates/arkdeck-cli/src/app_capability_registry.json`, in the App's
  order, by `rust/scripts/copy-app-capability-registry.py` (new, with a
  `--check` mode). It is the S3 registry copy's pattern; see "Why a copy".
- `machine_contracts` lists both products in Swift's order.
  `app-product-capability-registry.yaml` carries no contract input, so its
  digest joins `owned.json`. `cli-feature-coverage.json` carries the Catalog's
  digest and follows the Catalog and the method set, so like the registry
  YAML it is compared with the committed file wherever a checkout has it.

Both products rendered byte for byte as published on the first run.

## The contract views

The contract views carry `rust/` and the contract inputs
(`generate-contract.py`'s `INPUTS`). Among those inputs are six files of
`openspec/contracts`: the control-plane, result, error-registry,
canonical-vector, journal-event and workflow-step documents. So a view does
have that directory, with just those six files in it.

The S2 and S3 records here (and this test's comments until now) said a view
carries no `openspec/contracts`. That was wrong. What decides a skip is
whether the file is there, not whether the directory is.

A contract-input change runs `cargo test --workspace` in both views. With
unchanged inputs only the candidate view runs, and only `arkdeck-contract`'s
tests, so S1–S4 never met this case. Two things would have failed there:

- The test looked for `openspec/contracts` as a directory. In a view it found
  the directory, then failed to read `cli-command-registry.yaml`, which no
  view carries. So any contract-input change would fail both views.
- The view of the published inputs compiles the merge base's contract into
  this tree's code. So a PR that changes the method set would render
  products that differ from the merge base's committed files, by design.

The machine-contracts test now:

- compares each product built from the compiled contract with its committed
  file, one file at a time, where the file exists. A checkout has all four; a
  view has the result and control-plane schemas;
- compares none of them in the view of the published inputs
  (`published_view()`, inputs of kind `development` naming their commit, the
  same check the daemon tests use);
- requires the coverage's rulings to match the compiled methods everywhere
  but that view.

A read error other than a missing file still fails the test.

The coverage follows two contract inputs, the compiled method set and the
Catalog. Swift's `build()` refuses a method without a ruling and a ruling for
no method. Ported as is, that would panic in the published view of any PR
that adds or removes a control method. So the manifest takes the methods it
has a ruling for, and `machine_contracts::coverage_problems()` reports the
two differences, which the checkout and the candidate view require to be
none. A unit test renders the manifest over a method set with one method
removed and one unruled method added. It shows the manifest covers the rest
and reports both differences rather than panicking. The Catalog needs no such
care: an operation the view's Catalog lacks leaves its leaves covered in
their own right, and nothing refuses.

### Verified with a synthetic contract-input change

Setup:

- a scratch branch off this slice, discarded afterwards;
- the change: `spec/control/methods/trace.cache.status.json` gained an
  optional result field, a relaxation, and
  `generate-contract.py --write` regenerated the checkout's manifest. The
  contract identity is unchanged, since it follows `control-protocol.json`
  alone;
- `check-contracts.py` then ran both views in full, with
  `CARGO_BUILD_JOBS=2`.

| Run | View of the published inputs | Candidate view |
| --- | --- | --- |
| Before the hardening (`/private/tmp/arkdeck-s5-views-before.log`) | red: `every_owned_product_is_the_published_bytes` panicked reading `openspec/contracts/cli-command-registry.yaml`, which the view does not carry | red: the same |
| After (`/private/tmp/arkdeck-s5-views-after.log`) | green: every step, `cargo test --workspace` with both machine-contracts tests among them | green: every step, the owner scripts included; the run ends "Published and candidate contract checks passed" |

Before the hardening, only that test failed in either view. The views' test
run stops at the first failing test binary, so the binaries after
`machine_contracts` did not run then; the run after the hardening ran them
all. In a checkout the hardening changes nothing, since every file is
there and the view check is false. So no mutation of it can be told apart
there, and this run is its test.

## Why a copy (the hub's decision)

The hub chose the copy, and Swift keeps the App's table. Its reasons:

1. `tasks.md` asks only that the Rust export equal the published bundle
   before the source of truth moves. A copy does that. Making a
   language-neutral JSON the App table's single source, with the Swift table
   generated from it, would change how the App's source is kept. It would
   touch ClientKit and Workflows sources, run the App lane and risk App
   regressions, which is beyond a parity port.
2. The copy is derived by a Python script from the committed registry, not
   held only by a Swift test. `plan.py` selects the Swift lane only for paths
   under `Packages/ArkDeckKit/`, so a PR that changed just the copy in
   `rust/` would run the Rust lanes alone. A copy held only by a Swift test
   could then drift into `main` and fail at the next unrelated
   `Packages/` change. The script's `--check` against the committed file
   stops that in the host-independent lane.
3. The copy carries exactly the registry's fields (`id`, `title`, `owner`,
   `surface`, `classification`, `cliEquivalent`). The coverage needs no
   other, so the registry is not widened for it.

The single source is deferred until after M5, as an option, for when the
App's table needs a language-neutral source. No Swift test is added: the
copy is held transitively. The published registry holds the copy through
the copy's digest, and Swift's own contract tests hold the published
registry to the App's table.

## Changing the App's capability table

A change to `AppProductCapabilityRegistry` changes the App registry and the
coverage. Swift's contract tests already require the bundle to be
regenerated. The Rust side then needs, in the same PR:

1. `python rust/scripts/copy-app-capability-registry.py`;
2. `python rust/scripts/refresh-contract-digests.py`.

A change to Swift's coverage rulings or classification rules needs the same
change in `feature_coverage.rs`. The checkout's comparison of the coverage
fails until it is made.

## Tests

| Test | What it holds |
| --- | --- |
| `machine_contracts.rs::every_owned_product_is_the_published_bytes` | All 235 products: 231 render to their committed digests; the command registry, the feature coverage, and the result and control-plane schemas equal their committed files where a file is there, outside the view of the published inputs |
| `machine_contracts.rs::every_control_method_has_one_coverage_ruling` | Outside the view of the published inputs, every compiled control method has one ruling and every ruling a method |
| `feature_coverage::tests::another_method_set_is_covered_where_ruled_and_reported` | Over another method set, the manifest covers the ruled methods and reports the rest, without a panic |

## Mutations

Each mutation changed one place in `feature_coverage.rs`, ran
`tests/machine_contracts.rs` and the library's unit tests after an unmutated
baseline, and restored the file by digest (`/private/tmp/arkdeck-s5-mut.log`).

All 15 were killed.

| Mutation | Killed by |
| --- | --- |
| The tool selection local like its group | the coverage comparison |
| A leaf that is not executable classified direct | the coverage comparison |
| A legacy leaf required on every platform | the coverage comparison |
| An exactly-one group joined otherwise in a target command | the coverage comparison |
| A ruling's lifecycle ignored | the coverage comparison |
| Plumbing classified as its leaf | the coverage comparison; the method-set test |
| An operation referenced without its version | the coverage comparison |
| A method without a ruling refused, as Swift's `build()` does | the method-set test |
| A generic operation's fixture another leaf's | the coverage comparison |
| A tombstone's replacement worded otherwise | the coverage comparison |
| Another platform reported implemented | the coverage comparison |
| Full function never claimed | the coverage comparison |
| A source counted by its whole name | the coverage comparison; the method-set test |
| The App registry with another vocabulary | the App registry's digest |
| A ruling for no method not reported | the method-set test |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-s5-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s5-clippy.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s5-winclippy.log`) |
| clippy, Linux | the same with `--target x86_64-unknown-linux-gnu` | exit 0 (`arkdeck-s5-linuxclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 337 passed, none failed (`arkdeck-s5-test.log`) |
| Digest table | `verify_contract_bundle_digests()` against the checkout; `refresh-contract-digests.py --check` | passes (231 products); exit 0 |
| App registry copy | `python rust/scripts/copy-app-capability-registry.py --check` | exit 0; a drifted copy fails with exit 1, naming the fix, and a rewrite restores it byte for byte |
| Registry copy | `python rust/scripts/copy-command-registry.py --check` | exit 0 |
| Mutations | `s5_mutations.py` (scratch) | 15 of 15 killed |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s5-sdd.log`) |

Not run: `generate-contract.py --check` and the contract views, because no
contract input changes; `check-contracts.py`'s own tests, because the script
is unchanged in this slice. No Swift code changes, so no Swift test runs.

## CI

- S4 (#2191): its third run (36142496189, head `ffc33d878`) passed every
  lane, and it merged as `acace84a7`.
- This PR: pending.
