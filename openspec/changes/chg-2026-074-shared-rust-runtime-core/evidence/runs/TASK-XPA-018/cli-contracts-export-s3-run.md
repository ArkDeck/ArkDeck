# TASK-XPA-018 — contracts export S3: the command registry and the envelopes (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is contracts-export slice S3. It
covers the command registry YAML and the seven envelope fixtures, and turns
the one-liner that copies the registry into a script. Base: `main`
`52a64b19e`, where S2 (#2188) merged. It was built stacked on S2 and moved
onto `main` with `rebase --onto`, with the same tree as tested.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change; the bundle itself is unchanged.

## What changes

- `machine_contracts` gains:
  - `cli-command-registry.yaml`, a port of Swift's `commandRegistryDocument`.
    It is the registry projection this CLI already carries
    (`command_registry.json`, which `CLIRustCommandRegistryCopyContractTests`
    holds to Swift's projection), with the bundle's versions and the
    Catalog's digest;
  - the seven envelopes of Swift's `EnvelopeFixtures`. Each is written by the
    code this CLI answers with:
    - a success, with `local_success_envelope`;
    - a deprecated alias, with `with_lifecycle`, from the registry copy;
    - the refusal of `job status` without `--job`, and of the retired
      `agent chat`, both as this CLI's parser gives them, with
      `failure_envelope`;
    - a Runtime event line and both terminal lines, with `job_events`'
      `event_line` and `terminal_line`;
    - each rendered as one canonical JSON line (`render`).
- `command_registry::projection()` exposes the carried registry.
- `rust/scripts/copy-command-registry.py` (new): the one-liner that refreshed
  `command_registry.json` from the published registry, as a script with a
  `--check` mode. `rust/README.md` names it.
- `owned.json` gains the seven envelopes' digests. The registry YAML carries
  the Catalog's digest, a contract input, so like S2's result and
  control-plane schemas it is compared with the committed file wherever a
  checkout has `openspec/contracts`. The export now owns 23 of the 235
  products.

## Changing a contract input

Three products now follow the contract inputs, and each must be regenerated
in the same PR as the input it carries:

- `control-protocol.json`: `runtime-control-plane.schema.json` and
  `cli-result.schema.json` (since #2188);
- the Catalog: `cli-command-registry.yaml`, through its Catalog digest (since
  this slice). Swift's own bundle check already required this.

The Rust checkout test enforces all three. The regenerating commands are in
the S2 record (`cli-contracts-export-s2-run.md`, "Changing a contract
input"): Swift's `maintainer contracts export`, until the Rust export (S6)
takes over. After an export that changes the registry, also run
`python rust/scripts/copy-command-registry.py`.

## What the envelopes show

Rendering the envelopes with the CLI's own code, not literals, makes them a
parity check. The parser's two refusals equal Swift's, byte for byte: code,
words and details, the removed command's lifecycle details included. So do
the deprecated alias's `meta.lifecycle` and the terminal failure's exit
status (69, from the registry).

## The script

`copy-command-registry.py --check` passes on the committed copy and fails,
naming the fix, when the copy differs. A rewrite reproduces the committed
copy byte for byte. It writes exactly what the one-liner in `cli-commands-run.md`
wrote: the published registry's schema version and commands, pretty with
sorted keys and unescaped Unicode, then one LF.

## Tests

| Test | What it holds |
| --- | --- |
| `machine_contracts.rs::every_owned_product_is_the_published_bytes` | All 23 owned products: 20 render to their committed digests; the command registry, result and control-plane schemas equal the committed files in a checkout |
| `…::fixtures_are_listed_in_path_order` | The fixtures, envelopes included, are in path order |

## Mutations

Each mutation changed one place in `machine_contracts.rs`, ran
`tests/machine_contracts.rs` and the library's unit tests after an unmutated
baseline, and restored the file by digest (`/private/tmp/arkdeck-s3-mut.log`).
All 7 were killed.

| Mutation | Killed by |
| --- | --- |
| The registry's Catalog digest taken from elsewhere | the comparison with the committed registry |
| The registry's schema version taken from elsewhere | the comparison with the committed registry |
| The argv refusal named after the parse phase | the argv failure envelope's digest |
| The deprecated alias without its lifecycle | the deprecated alias envelope's digest |
| A terminal success exiting 1 | the terminal success line's digest |
| The Runtime failure counting a dispatch | the terminal failure line's digest |
| The Runtime event line second in its stream | the event line's digest |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-s3-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s3-clippy.log`). The first run flagged `.err().expect()` twice (`clippy::err_expect`); both are now `let Err(…) = … else` |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s3-winclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 332 passed, none failed (`arkdeck-s3-test2.log`) |
| Digest table | `verify_contract_bundle_digests()` against the checkout | passes (20 products) |
| Registry copy | `python rust/scripts/copy-command-registry.py --check` | exit 0; a drifted copy fails; a rewrite is byte for byte the committed copy |
| Mutations | `s3_mutations.py` (scratch) | 7 of 7 killed |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s3-sdd.log`) |

Not run: `generate-contract.py --check` and the contract views, because no
contract input changes; `check-contracts.py`'s own tests, because the script
is unchanged.

## CI

- This PR: pending.
