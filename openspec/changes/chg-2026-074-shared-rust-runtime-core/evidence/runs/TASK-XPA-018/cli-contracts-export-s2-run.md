# TASK-XPA-018 — contracts export S2: the error registry, the canonical vectors and the envelope and control-plane schemas (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is contracts-export slice S2: the
error registry and the canonical vectors, then the result, event and
control-plane schemas. It also fixes `blockedByProductDefect`'s exit code.
Base: `main` `24fb6c692` (S1 is #2186; #2187 moved the client failure
mapping into one port, which this slice's registry now also serves).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change; the bundle itself is unchanged.

## What changes

- `arkdeck-cli`: a new public module `error_registry`, a port of Swift's
  `CLIErrorCode` and `CLIExitCategory` (`CLIErrorRegistry.swift`). It holds
  the 45 codes in Swift's order, each with its category, and the 12
  categories with their exit statuses and machine names. It also answers
  whether a code's control request is retryable and whether it needs
  attention. The CLI kept three hand copies of this table. All now read the
  registry:
  - `CliError::exit_code` (a match with a default);
  - the failure envelope's `controlRequestRetryable` and `attentionRequired`;
  - `agent_executions`' list of codes an execution's `failureCode` may name.
- **A fix:** `blockedByProductDefect` now exits 69, in the `unavailable`
  category, as Swift's registry has it. The old match had no arm for it, so it
  fell to the default, 70. The hub asked for this fix in S2.
- `machine_contracts` gains:
  - `yaml_document`, a port of Swift's `ContractYAML`. It writes the generated
    notice, then block mappings and sequences of canonical JSON scalars, keys
    included, with empty containers inline;
  - `cli-error-registry.yaml`, rendered from the registry;
  - `cli-canonical-json-vectors.json`. Its ten vectors are encoded by this
    build's canonical encoder, and its five refusals carry the reasons the
    published bundle records.
- `machine_contracts` also gains the result, event and control-plane
  schemas, ported from Swift's `Schemas.result`, `Schemas.event` and
  `Schemas.controlPlane`. Their error object enumerates the registry's codes.
  The control-plane schema is built from the compiled contract: its protocol
  version, its identity, and its methods in order, each pointing at its
  typed schema under `spec/control/methods`.
- `rust/tests/fixtures/contracts-bundle/owned.json`: three new digests (the
  error registry, the vectors, the event schema). The Rust export now owns
  15 of the 235 products.

## The 45 codes, before and after

The three hand copies on `main` `24fb6c692` were compared with the registry,
which renders the published `cli-error-registry.yaml` byte for byte, code by
code:

- `CliError::exit_code`'s match, with its default of 70;
- the failure envelope's retryable set and its attention rule (exit status 2,
  75 or 77);
- the executions' list of `failureCode` names.

| Code | Exit status | `controlRequestRetryable` | `attentionRequired` |
| --- | --- | --- | --- |
| `blockedByProductDefect` | 70 → 69 | false → false | false → false |

That is the only change among the 45. The retryable set is exactly
`clientTimeout`, `resultNotReady` and `runtimeUnavailable` before and after,
so no code became retryable. Attention is unchanged for every code. The
`failureCode` list held the same 45 codes in the same order.

## Products built from the contract

Two of the new products carry values from the contract inputs:

- the result schema: the protocol version;
- the control-plane schema: the protocol version, the contract identity and
  the method set.

A contract-input change regenerates both, so a fixed digest under `rust/`
would not hold them. It would also break the published contract view, which
compiles the merge base's inputs, on the next PR that changes them. So these
two are compared with the committed files, wherever the checkout has
`openspec/contracts`, as every CI lane's checkout does. The contract views
carry only `rust/` and the contract inputs, never `openspec/contracts`, and
there the comparison is skipped by design. The products that do not depend on
the inputs keep S1's digest table, which also holds in the views.

## The canonical refusals

The published bundle records Swift's description of each refusal, for
example `integerBeyondExactRange("9223372036854775807")`. Those words are
part of the published contract, so this build writes them as data
(`CANONICAL_REJECTIONS`). The claim behind each one also holds for this build:

- its encoder refuses the two integers beyond the exact range;
- a non-finite number cannot be held in a `serde_json::Value`
  (`Number::from_f64` refuses it), so this build never accepts one either.

`canonical_rejections_are_this_builds` holds both.

## Tests

| Test | What it holds |
| --- | --- |
| `machine_contracts.rs::every_owned_product_is_the_published_bytes` | All 15 owned products are accounted for: 13 render to their committed digests; the result and control-plane schemas equal the committed files in a checkout |
| `…::the_yaml_renderer_writes_swifts_contract_yaml` | The notice; key order; an empty mapping and sequence inline; a mapping inside a sequence with its first key on the dash's line; a sequence inside a sequence; canonical escapes |
| `…::canonical_rejections_are_this_builds` | The five refusals, in order, are refused by this build too |
| `…::every_code_exits_and_reports_as_its_registry_entry_says` | 45 distinct codes; the 12 exit statuses; every code's `CliError::exit_code`, envelope retryability and attention match its entry; `blockedByProductDefect` exits 69; exactly three codes are retryable; an unknown code is an internal failure |

## Mutations

Each mutation changed one place, ran `tests/machine_contracts.rs` and the
library's unit tests, and restored the file by digest. The driver first
checks that the unmutated tests pass (`/private/tmp/arkdeck-s2a-mut.log`,
`/private/tmp/arkdeck-s2b-mut.log`). All 15 were killed.

A first run named a test target this branch does not have, so cargo failed
before any test ran and every mutation looked killed, with no test named.
That run was discarded. The driver now checks the unmutated tests first, and
the run below names the tests that failed.

| Mutation | Killed by |
| --- | --- |
| A nested sequence item's lines under-indented | the digests, the YAML renderer test |
| An empty sequence opened on its own lines | the digests, the YAML renderer test |
| `blockedByProductDefect` an internal failure | the registry test, the digests |
| The `internal` category under its Rust name | the digests |
| An unknown outcome made retryable | the registry test, the digests, a display-name unit test |
| An integrity failure needing no attention | the registry test, the digests |
| Negative zero dropped from the vectors | the digests |
| A refusal in this build's own words | the digests |
| The YAML notice left out | the digests, the YAML renderer test |
| The result schema's protocol version taken from elsewhere | the comparison with the committed result schema |
| A published method marked unpublished | the comparison with the committed control-plane schema |
| A terminal frame's exit code allowed up to 256 | the event schema's digest |
| An error's details an array | the event schema's digest |
| A method's schema path without its extension | the comparison with the committed control-plane schema |
| A runtime event allowed to be a terminal frame | the event schema's digest |

Sorting the method table as Swift does was not mutated: the compiled
`METHODS` are already in order, so dropping the sort would change nothing
today. It stays for when they are not.

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml`, after the rebase onto `24fb6c692` | exit 0 (`arkdeck-s2-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s2-clippy.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s2-winclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli`, including #2187's client-failure tests | exit 0: 332 passed, none failed (`arkdeck-s2-test.log`) |
| Digest table | `verify_contract_bundle_digests()` against the checkout | passes (13 products) |
| Mutations | `s2a_mutations.py` and `s2b_mutations.py` (scratch), each after an unmutated baseline | 15 of 15 killed (`arkdeck-s2a-mut.log`, `arkdeck-s2b-mut.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s2-sdd.log`) |

Not run: `generate-contract.py --check` and the contract views, because no
contract input changes; `check-contracts.py`'s own tests, because the script
is unchanged.

## CI

- This PR: pending.
