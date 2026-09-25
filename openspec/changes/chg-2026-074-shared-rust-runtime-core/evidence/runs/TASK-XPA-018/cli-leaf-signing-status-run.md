# TASK-XPA-018 — `runtime signing status` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main (no stack). This PR adds no `tasks.md`
line (the coordinator's ruling of 2026-09-26). The first leaves of slice C10. Nothing here is
device evidence (POL-VERIFY-001, POL-MODE-001). No control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change. Host evidence only: each run in a
private home, reaching no Keychain.

## What changes

- **`arkdeck runtime signing status`** and its deprecated spelling **`arkdeck signing status`**
  are Swift's `runSigning` status leaf, in `rust/crates/arkdeck-cli/src/signing_leaves.rs`, over
  the workspace provider's preset store and credential owner: whether a preset is installed,
  whether it validates with its secrets present (Swift `OpenHarmonySigningPresetStore.status()`,
  the Data Protection Keychain read without user interaction, bound to the installed daemon's
  identity), and the credential the owner ledger names. It never reads a secret's value.
- The crate edge `arkdeck-cli → arkdeck-provider-workspace` (the maintainer's Q8 ruling) is
  registered in `rust/scripts/check-readonly.py` beside the Bootstrap edge of #2217; `Cargo.lock`
  gains that one workspace dependency line and no external crate.
- Like Swift's registry, these leaves take no `--control-request-id` (nor `--socket`): the
  registry pass's refusal is reported. `--json` prints Swift's pretty spelling of the document.
- A correlation identity the CLI generates is now Swift's `CLIControlRequestID.generated()`:
  `ctl-` and a lowercase version 4 UUID (it was `ctl-` and 32 hexadecimal digits). This shows on
  every leaf's machine envelope when the caller names no identity.

## Oracle and tests

- `CLISigningStatusOracleContractTests` (Swift) runs the real `arkdeck` process under a private
  home (`CFFIXED_USER_HOME` and `HOME`) and records 7 runs to `rust/tests/fixtures/signing-status`:
  no preset (machine, human, the deprecated spelling in both and with `--json`), a receipt that
  does not decode, and an option the leaf does not take. Neither case reaches the Keychain: the
  receipt is judged before any secret is asked about.
- `tests/signing_status.rs` replays all 7: the same exit status, the same stdout and stderr byte
  for byte in the machine modes (the generated correlation identity compared as one), the same
  warning in the human rendering (Swift's outline, this CLI's pretty JSON, T2), and the same files
  left under the home — the owner's lock and, where Swift writes it, its ledger.

The first recording passed `--control-request-id`, which Swift refuses on these leaves; it was
corrected and re-recorded before any replay was taken as evidence. The re-recording then held
Swift's randomly generated identity verbatim, so Swift's own comparison run could never pass
(CI run 36194056094 on `f7f8408f1`); the oracle now records and compares it as `ctl-<uuid>`, and
the replay proves this CLI's generated identity has Swift's shape before comparing it so.

## Counts

- Rust CLI leaves answered: +2 (`runtime signing status`, `signing status`), all ported.
- `cli-parity-audit.py`, registry leaves not served: category 3 (host owner missing) −1,
  category 4 (§12 compatibility spelling) −1.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-signing-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLISigningStatusOracleContractTests`
  — exit 0 (recording, in the hub's Swift window; `/private/tmp/arkdeck-cli-lane-swift-signing2.log`),
  and exit 0 comparing against the labelled, checked-in oracle
  (`/private/tmp/arkdeck-cli-lane-swift-signing-compare.log`).
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
