# TASK-XPA-018 — `maintainer update-feed prepare` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `587127475` (#2233; no stack), after #2227
(Swift writes the update feed files without a file protection class) and #2226 (Swift's generated
correlation identity). This PR adds no `tasks.md` line (the coordinator's ruling of
2026-09-26). The first leaf of slice C9. Nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001). No control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change. Host evidence only, in private temporary roots; no key is held or asked for.

## What changes

- **`arkdeck maintainer update-feed prepare`** and its deprecated spelling **`arkdeck
  update-feed prepare`** are Swift's `prepareUpdateFeed`, in
  `rust/crates/arkdeck-cli/src/update_feed.rs`, no longer answered `blockedByProductDefect`
  (#2211): the artifact measured (its bytes and SHA-256, opened without following a link and
  refused if it changes while measured — `arkdeck_platform::measure_unchanged_file`), every
  payload field Swift checks before signing (`UpdateFeedVerifier.validateUnsignedPayloadForSigning`:
  sequence, versions, timestamps, validity window, artifact URL host, scheme, port, fragment and
  suffix, notes), the canonical payload and the exact bytes to be signed (`ArkDeck.UpdateFeed.v1`,
  NUL, the production key identity, NUL, the payload) written atomically into the output
  directory (`0700`, files `0600`), and Swift's runbook lines or machine answer. It never holds or
  asks for a private key; signing happens elsewhere.
- Paths are Foundation's: the output directory is standardized before it exists (so its
  `/private` spelling stays, `arkdeck_contract::foundation_path`'s rule).
- Swift's guard `precomposedStringWithCanonicalMapping == value` compares with Swift's `==`, which
  is canonical equivalence and always holds for NFC: it never refuses, so it has no port (an
  earlier draft compared bytes and refused decomposed notes Swift accepts).
- `maintainer update-feed assemble` (both spellings) stays answered `blockedByProductDefect`: it
  verifies an Ed25519 signature, a dependency awaiting approval.

## Oracle and tests

- `CLIUpdateFeedOracleContractTests` (Swift, on a main with #2227) runs the real `arkdeck` process
  in a private root and records 31 runs and the files prepare wrote to
  `rust/tests/fixtures/update-feed`: prepare in both spellings (machine and human), 21 refusals
  (each field's grammar and range, the artifact missing or empty, a missing option), and the
  assemble refusals (a short or forged signature, a missing payload or signature). These leaves
  take no correlation identity, so the generated one is recorded and compared as `ctl-<uuid>`.
- `tests/update_feed.rs` replays the 26 prepare runs through the CLI with the arguments Swift's
  child received (Foundation's `Process` passes them decomposed): the same exit status, stdout
  and stderr (the generated identity proved `ctl-` and a lowercase v4 UUID), and the same payload
  and signature input, byte for byte, with the same modes. The assemble runs wait for that leaf's
  port; `blocked_leaves.rs` holds its answer.
- The success path of `assemble` needs a feed signed with the production key; per the
  coordinator's ruling no trust is injected for an oracle, so it stays to be recorded by the
  maintainer (the #2227 run record carries it).

## Counts

- Rust CLI leaves: +2 ported (`maintainer update-feed prepare`, `update-feed prepare`), −2
  answered by name.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-platform
  --all-targets -- -D warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and
  `--target x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-platform` —
  exit 0.
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIUpdateFeedOracleContractTests`
  — exit 0 recording (`/private/tmp/arkdeck-cli-lane-swift-feed3.log`) and exit 0 comparing
  against the checked-in oracle (`/private/tmp/arkdeck-cli-lane-swift-feed-compare.log`), in the
  hub's Swift window.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
