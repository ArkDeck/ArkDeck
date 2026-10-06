# Windows workspace signing preset credential projection

Date: 2026-10-06. Base: protected main
`4acef13297d73b8aea3ece774c4c46405fa4a377`.

The live acceptance coordinator reported `runtime.signing.install` ready and
successful signing preset registration, followed by `workspace.preset.list`
refusing `internalError` because its result did not conform to the current
contract, with zero new dispatch. That acceptance attempt remains
`BLOCKED_BY_PRODUCT_DEFECT`; this source increment supplies no hardware PASS.
No private account record, signing material, Raw journal or device was accessed
by these checks.

All five preset leaves return `PresetRecord::resource`. A signing preset retains
its string credential reference even after removal. The generator now lends the
actual recorded registration credential member to list/show/update/remove,
matching registration's existing required nullable-string result field. The
other closed properties, request/error definitions, trust policy and owners are
unchanged. `workspace.project.list` contains only compact
`presetRefs(kind,presetRef,timeoutSeconds)` and needs no change.

Normal derivation also corrects historical sample-count metadata to the selected
committed corpus: update has 13 requests, 2 successes and 11 errors; remove has
11 requests, 2 successes and 9 errors. No frames were fabricated or repinned.
All unrelated derivation outputs were restored only from verified original
bytes; the four method schemas and their generated development input hashes
are the only contract outputs changed.

## Local targeted checks

All commands ran in `D:/src/ArkDeck-wt/rc-smoke-path`. Cargo used jobs 2 and the
exclusively held `D:/cargo-target/windows-mutation-tool-identity` cache. The
heavy executor acquired a host slot immediately. The Runtime was stopped for
the Rust checks. These are corpus/native validator tests, not live acceptance.

Logs are under `D:/src/ArkDeck-wt/tools/workspace-preset-list/`.

| Command | Result | Log |
| --- | --- | --- |
| `python rust/scripts/test_contract_checks.py WorkspacePresetListSchemaTests SchemaVocabularyTests -v` | exit 0; 12 passed | `schema-regression-four-leaves.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-contract --test workspace_preset_credentials --test corpus_parity` | exit 0; 3 credential and 11 corpus cases passed | `rust-validator-four-leaves.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-contract -p arkdeck-control -p arkdeck-soak -p arkdeck-provider-arkforge -p arkdeck-agentd -p arkdeck-cli -p arkdeck-bootstrap -p arkdeck-rockchip-binding -p arkdeck-client -p arkdeck-hoststore -p arkdeck-provider-hdc --all-targets -- -D warnings` | exit 0 | `clippy-four-leaves.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 | `fmt-four-leaves.log` |
| `python rust/scripts/generate-contract.py --check` | exit 0 | `generate-check-four-leaves.log` |
| `python Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | exit 0 | `control-vocabulary-check-final.log` |
| Git Bash `sh scripts/check-sdd.sh` | exit 0; 0 errors/warnings | `sdd-check-final.log` |
| `git diff --check` | exit 0 | `diff-check.log` |

The pre-fix regression (`prefix-reproduction.log`) refused the actual recorded
signing credential under the null-only list schema. Intermediate derivation and
test failures remain saved, including the Windows default-text-encoding failure;
the successful generation uses the handover's UTF-8 environment. The final
regression rederives all four closed consumer schemas in a temporary directory,
accepts actual recorded signing/null projections and refuses malformed/missing
credentials and unknown fields. Rust retains an explicit old-published-view
refusal check rather than skipping the new test under the old schema.

## CI

CI has not run for this increment yet. Local checks do not constitute maintainer
approval, current-head CI success or hardware acceptance. Full contract parity
and platform lanes remain the existing PR CI responsibility.
