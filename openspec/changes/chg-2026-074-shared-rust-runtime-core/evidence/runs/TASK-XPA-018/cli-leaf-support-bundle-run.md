# TASK-XPA-018 — `runtime support-bundle preview|export` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `dc709dc3e` (#2224; no stack). This PR adds
no `tasks.md` line (the coordinator's ruling of 2026-09-26). Slice C8, ported as Swift has it (the
coordinator's ruling (a)). Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution change.
Host evidence only, in private temporary roots.

## What changes

- **`arkdeck runtime support-bundle preview --destination <dir>`** and **`… export --destination
  <dir> --preview-digest <sha256>`** are Swift's `runRuntimeSupportBundle` over its production
  provider (`RuntimeSupportBundleApplicationFacade`, `LocalDiagnosticBundle`), in
  `rust/crates/arkdeck-cli/src/support_bundle.rs`:
  - The bundle is three documents: `metadata.json` (this CLI's name, version and host platform),
    `hdc/tool-placeholder.json` (redacted and unverified states only; HDC is never probed) and
    `bundle.json` (the manifest, with Swift's sensitive-data warning as it ships). It holds only
    constants and host facts: no Runtime storage, log, file, device data, Session, journal,
    Artifact, secret or user path is read or written into it.
  - The destination is only ever the one the caller names: an absolute path Foundation would
    call canonical (`standardizedFileURL`, whose `/private` rule is now the shared
    `arkdeck_contract::foundation_path` one), under a parent that exists, belongs to this user and
    no group or other can write; it must not exist.
  - `preview` writes nothing and names the scope's digest, over the destination, its parent's
    device and inode, and every entry's bytes; `export` recomputes it, and publishes only when the
    caller hands back that exact digest (`previewDrifted` otherwise), within the bundle quota.
- `rust/crates/arkdeck-platform/src/diagnostic_bundle.rs` (macOS) publishes the tree as Swift's
  writer does: staged in a `0700` directory beside the destination with `0600` files, each synced
  (`F_FULLFSYNC`), then renamed into place without replacing anything (`renameatx_np` with
  `RENAME_EXCL`) and the parent synced; a failure before the rename removes the staging, after it
  removes the published tree, and one it cannot settle is an unknown outcome.

## Oracle and tests

- `CLISupportBundleOracleContractTests` (Swift) runs the real `arkdeck` process in a private
  temporary root and records 15 runs and the exported tree to `rust/tests/fixtures/support-bundle`:
  a preview (machine, `--json`, human), an export with a wrong digest and to another destination,
  the export, an export and a preview over an existing destination, and destinations that are
  relative, in the `/private` spelling, with a trailing slash, with `..`, under a missing parent,
  under a group-writable parent, and `/` itself. The digest binds the parent's device and inode,
  which differ between hosts, so the oracle records them and a digest is compared as a digest.
- `tests/support_bundle.rs` (`swifts_recorded_runs_replay_through_the_cli`) replays all 15 in a
  private root spelled both ways, approving this host's own preview: the same exit status, stdout
  and stderr in the machine modes, the human rendering (Swift's outline, this CLI's pretty JSON,
  T2) held to its status, and the same exported tree, byte for byte and mode for mode (only the
  generation time in `bundle.json` differs).
- The other tests pin the digest formula over the parent's identity and entries, every refusal
  leaving nothing behind, each failure point of the publication (removed before and after the
  rename, or an unknown outcome), and the CLI's options and renderings.

The replay found that Foundation keeps `/private` in a path whose remainder does not exist (a
destination spelled `/private/tmp/…/support` is canonical); the earlier port dropped it
unconditionally, and now uses the shared rule.

## Counts

- Rust CLI leaves answered: +2 (`runtime support-bundle preview`, `export`), both ported.
- `cli-parity-audit.py`, registry leaves not served: category 3 (host owner missing) −2.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-platform
  --all-targets -- -D warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and
  `--target x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-platform` —
  exit 0 (`/private/tmp/arkdeck-cli-lane-support-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLISupportBundleOracleContractTests`
  — exit 0 (recording, in the hub's Swift window; `/private/tmp/arkdeck-cli-lane-swift-support.log`).
  The comparison run against the checked-in oracle is left to CI's Swift lane.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
