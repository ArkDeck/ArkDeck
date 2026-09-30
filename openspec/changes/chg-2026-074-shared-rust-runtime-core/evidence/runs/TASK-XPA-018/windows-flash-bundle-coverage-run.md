# TASK-XPA-018 — Windows CLI coverage of `artifact import flash-bundle` (2026-10-01)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Nothing was flashed: the leaf only imports an archive.
- **Base:** measured on protected `main` `2c593b28` (#2430). It includes #2424, which judges a
  flash-bundle Import by the Flash archive reader on Windows too.
- **Rebase:** rebased onto `e903da6c`, after A1's #2431 (trace cache purge, diagnostics export)
  and #2432. The coverage file was regenerated and the pins substituted on the merged tree, and
  the tests were rerun.

## What was measured

`arkdeck-agentd/tests/windows_import_owner_process.rs`, in the signed-CLI test. The real CLI ran
against a copy of the daemon signed with the host-trusted development signer
(`ARKDECK_DEV_SIGNER_THUMBPRINT` set, not skipped), over the recorded Swift Target store of one
adopted Target.

- **Valid archive.** `artifact import flash-bundle --device-profile dayu200` imported the Flash
  archive reader's recorded complete archive (`rust/tests/fixtures/flash-archive/archives/complete.tar.gz`).
  - It ended `committed`.
  - The receipt digest is the file's SHA-256, and the validation is
    `{"kind":"flash-bundle","deviceProfile":"dayu200"}`.
  - `artifact import inspect` answered the same receipt.
- **Invalid archive.** A file that is not a gzip archive was refused at publication with "Import
  content failed its registered format validator". `artifact import list` shows it as the only
  Import with no receipt; nothing was published.

The test asserts that `artifact.import.flash-bundle` is Windows `implemented` in the manifest the
CLI renders.

## Changes

- `feature_coverage.rs`:
  - `artifact.import.flash-bundle` joins `WINDOWS_MEASURED_LEAVES`.
  - The unit test now expects it to be `implemented`.
- `cli-feature-coverage.json`, regenerated with `maintainer contracts export`: Windows
  `implemented` 70 → 71 on the merged tree (#2431 made it 70), `partial` 70 → 69.
- The six coverage-digest pins in `rust/tests/fixtures/maintainer-contracts/oracle.json` were
  substituted.
- `docs/design/cli-machine-contracts.md` and `evidence/windows-remaining.md` were updated. The
  method census on the merged tree: 73/105 methods answered (13 results, 60 owner refusals),
  0 non-conforming, 32 with no owner.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/w1-coverage`. The #2396 wildcard-listener gate is present in
  this tree.
- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-agentd -p arkdeck-cli`: 115 result lines ok on the merged tree, 0 failed, no `SKIPPED` (114 before the rebase).
- The same test run with an 8.3 short `TEMP`/`TMP` on C:: 114 ok (before the rebase).
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- `git diff --check`: clean.
