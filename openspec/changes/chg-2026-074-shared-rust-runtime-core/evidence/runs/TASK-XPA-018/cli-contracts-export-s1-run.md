# TASK-XPA-018 — contracts export S1: the renderer and the static products (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the first of the six contracts-export
slices the hub approved (S1–S6). The aim across them: before the source of
truth flips from Swift to Rust, Rust's `maintainer contracts export` must
write the published bundle byte for byte, and `check` must report 235 clean.
Base: `main` `b4981f5f3`.

S1 covers Swift's deterministic JSON renderer, the bundle's version constants
and the products that are pure data:

- `cli-page.schema.json` and `cli-next-action.schema.json`;
- the six `next-action/*` samples and the two `page/*` samples.

That is 10 of the 235 products.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change; the bundle itself is unchanged.

## What changes

- `arkdeck-cli`: a new public module `machine_contracts`:
  - `json_document`, a port of Swift's `ContractJSON`: keys in UTF-16
    code-unit order, two-space indentation, scalars from the canonical
    encoder (`arkdeck.cli.canonical-json/1`), empty containers inline, one LF;
  - `BUNDLE_VERSION`, the two schema versions and the generated notice;
  - `contract_products` and `fixture_products`, the two lists Swift's export
    writes, for now holding the products above. The page schema, the
    next-action union with its five branches, and the eight samples are
    ported from Swift's literals.
- `rust/tests/fixtures/contracts-bundle/owned.json`: the SHA-256 of every
  product the Rust export owns, keyed `contracts/…` or `fixtures/…`.
- `rust/scripts/check-contracts.py`: `verify_contract_bundle_digests`, next to
  `verify_current_cli_argv`, holds that table to the committed files.
- A new test, `tests/machine_contracts.rs`.

## Why digests and not copies

The committed bundle lives outside `rust/`: `openspec/contracts/` and the
contract tests' `Fixtures/CLI/`. The contract views that `check-contracts.py`
builds carry only `rust/` and the contract inputs. A Rust test that read the
bundle would pass in the checkout and fail in a view, and only on the next PR
that changes a contract input. So the Rust test compares each rendered
product with its digest under `rust/`, and the script, which runs in the
checkout, compares the digests with the committed files. This mirrors how
`current-cli-argv` works, without a second copy of the bundle as it grows to
235.

## Tests

| Test | What it holds |
| --- | --- |
| `machine_contracts.rs::every_owned_product_is_the_published_bytes` | Every product in the two lists renders to the committed digest; the owned set is exactly the table's (10 products) |
| `machine_contracts.rs::fixtures_are_listed_in_path_order` | The fixture list is in path order, as Swift sorts it |
| `machine_contracts.rs::the_renderer_writes_swifts_contract_json` | Empty containers inline; nesting and separators; keys in UTF-16 order, which differs from UTF-8 for a surrogate pair; the canonical escapes Swift's vectors pin (`\u0001`, `\"`, an unescaped `/`) |
| `check-contracts.py::verify_contract_bundle_digests` | The table matches the committed files. A checkout without the table owns nothing yet, as a checkout without `current-cli-argv` samples does |
| `test_contract_checks.py::ContractBundleDigestTests` (new) | No table passes; matching digests pass; a drifted product, a missing one and a path outside the two roots are each refused by name |

## Mutations

Each mutation changed one place in `machine_contracts.rs`, ran
`tests/machine_contracts.rs`, and restored the file by digest
(`/private/tmp/arkdeck-s1-mut.log`). All 7 were killed.

| Mutation | Killed by |
| --- | --- |
| Keys sorted in UTF-8 order | the renderer test |
| An empty object opened on its own lines | the digests and the renderer test |
| No newline after an array's last item | the digests and the renderer test |
| The bundle version written as the CLI version | the digests |
| The fixtures left unsorted | the order test |
| A resource never mirroring its owner | the digests |
| Another retry delay in the `wait` sample | the digests |

## Next

S2 moves the error-code table, the canonical vectors, the control-plane
schema and the result and event schemas. It also fixes
`blockedByProductDefect`'s exit code (70 → 69), as the hub ruled.

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-s1-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s1-clippy.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s1-winclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 315 passed, none failed (`arkdeck-s1-test.log`) |
| Digest table | `verify_contract_bundle_digests()` from `rust/scripts/check-contracts.py`, run on its own against the checkout | passes |
| Script regression tests | `python rust/scripts/test_contract_checks.py` (validation venv) | 45 passed (`arkdeck-s1-contract-checks2.log`) |
| Mutations | `s1_mutations.py` (scratch) | 7 of 7 killed (`arkdeck-s1-mut.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s1-sdd.log`) |

Not run:

- the whole of `check-contracts.py`: its views change only with the contract
  inputs, which this slice does not touch; CI runs it;
- `generate-contract.py --check`: no contract input changes.

## CI

- This PR, first head `bdbe37f07`: `rust-checks / Rust host-independent
  checks` failed (run `36129983727`). The script's regression tests build
  synthetic checkouts that carry no digest table, and the new check read the
  table unconditionally: 9 of 42 errored with `FileNotFoundError`. The check
  now treats a checkout without the table as owning nothing, as
  `verify_current_cli_argv` treats one without samples. Three regression
  tests of its own were added, and the script's tests were run locally
  before the push (45 passed).
- This PR, second head: pending.
