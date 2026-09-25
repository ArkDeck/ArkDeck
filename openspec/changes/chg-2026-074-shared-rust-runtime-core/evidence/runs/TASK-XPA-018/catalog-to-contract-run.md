# TASK-XPA-018 — the Catalog operation model moves to `arkdeck-contract` (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. Base: protected main `aa2afe6ba` (#2173);
no stack. The checks below ran on `a6294ec3` (#2171). After each rebase, onto
`681988448` (#2174) and then `aa2afe6ba`, a compile check ran (last rows). The hub ruled for option B on 2026-09-25: the CLI's workspace
continuation needs Swift's Catalog rules. G5 keeps one Runtime semantics
implementation in the repository, so the CLI uses the Runtime's own rules
rather than a second copy.

This is a pure move. No behaviour, test, Swift source, control schema,
corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution
change. Nothing here is device evidence.

## What moves

- **`operation_catalog.rs`**: the typed view of the published Catalog (Swift
  `RuntimeOperationCatalog`). It holds the exact descriptor lookup, the typed
  input validation, the host-only check, the steps a request selects and the
  effect it resolves to.
- **`catalog_pattern.rs`**: the subset of ICU patterns the published Catalog
  uses, which the input validation evaluates.

Both move from `arkdeck-hoststore` into `arkdeck-contract`, whose external
dependencies are unchanged (serde, serde_json, sha2): the two modules use
only `serde_json`, `std` and the Catalog constant the contract already
publishes.

- `operation_catalog` is public, and its former `pub(crate)` items are `pub`.
- `catalog_pattern` stays private to the contract; the validation is its only
  caller.
- `hoststore` names the module as before: `use
  arkdeck_contract::operation_catalog;` stands where `mod operation_catalog;`
  stood, under the same `cfg`. So all 28 hoststore files that
  name `crate::operation_catalog` are unchanged.

The diff inside the moved files is the path of the Catalog constant (from
`arkdeck_contract::` to `crate::`, once in `operation_catalog.rs` and once in
a `catalog_pattern.rs` unit test), `pub(crate)` to `pub`, and rustfmt joining
one signature that now fits on a line. Their unit tests move with them and run
as the contract's; no assertion changes.

## What stays, and why

`operation_request.rs`, the typed request decoder, stays in hoststore. The
contract takes no new dependency, as the ruling requires:

- It counts grapheme clusters for its length rules through
  `session_graphemes`, which needs the `unicode-segmentation` crate.
- It parses and encodes the request through `session_json`, the Foundation
  JSON codec, which is entangled with hoststore's own store types
  (`DecodedStore`, `DecodeError`).

The CLI's continuation compares the recorded request as the Runtime recorded
it, a canonical document, and reads its fields from there.

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-c2c-fmt.log`) |
| clippy | `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-contract`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-soak`, `arkdeck-cli` | exit 0 for each (`arkdeck-c2c-clippy-<crate>.log`) |
| Tests | `cargo test --no-fail-fast -p <crate>` for the same five, no test changed | exit 0 for each: contract 57 passed, among them the five moved unit tests (four `catalog_pattern::tests`, one `operation_catalog::tests`); hoststore 601 passed and 14 ignored; agentd 166, soak 4, cli 268 passed; none failed (`arkdeck-c2c-test-<crate>.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`: 136 control responses, 13 CLI envelopes, 127 valid requests; exit 0 (`arkdeck-c2c-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings, 121 acceptance IDs; exit 0 (`arkdeck-c2c-sdd.log`) |
| After the rebase onto `681988448` | `cargo check --all-targets -p` the same five | exit 0 (`arkdeck-c2c-rebased-check.log`). #2174 shares no file with this move; #2172 shares only `tasks.md`, where the entries are separate lines |
| After the rebase onto `aa2afe6ba` | the same | exit 0 (`arkdeck-c2c-rebased2-check.log`). #2173 and #2175 share only `tasks.md` with this move, where the entries are separate lines |

`check-readonly.py`'s crate-edge table is unchanged: `hoststore → contract`
and `cli → contract` were already allowed.

## CI

Pending.
