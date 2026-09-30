# TASK-XPA-018 — Windows CLI coverage of the Import leaves (2026-09-30)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched.
- **Base:** protected `main` `ba756dfe` (#2412). It includes #2397, which composes the Import
  owner on the Windows daemon and uploads through the Windows CLI.

## What was measured

`arkdeck-agentd/tests/windows_import_owner_process.rs`, signed-CLI test. It runs the real CLI
against a copy of the daemon signed with the host-trusted development signer
(`ARKDECK_DEV_SIGNER_THUMBPRINT` set, not skipped). The root holds the recorded Swift Target store
of one adopted Target.

| Leaf | Result |
| --- | --- |
| `artifact import hap` | committed; receipt digest = the file's SHA-256 (#2397's hop) |
| `artifact import native-library` | the recorded code-signed ELF (`rust/tests/fixtures/deploy-native-library`) committed with its exact digest; `inspect` returns the same receipt |
| `artifact import workspace-patch` | a one-file unified diff committed with its exact digest; `inspect` returns the same receipt |
| `artifact import inspect`, `list`, `release` | the Import's receipt; all three committed Imports listed; release answers `released` |
| `artifact import abort` | an Import begun over the pipe and not committed ends `aborted` |
| `artifact import flash-bundle` | uploads, then is refused at publication (`ok: false`); nothing published. Left `partial` |

The test asserts that these entries are Windows `implemented` in the manifest the CLI renders:
`artifact.import.begin`, `append`, `commit`, `inspection` (the upload frames behind
`artifact import <kind>`), `inspect`, `list`, `release`, `abort` and `workspace-patch`.

## Changes

- `feature_coverage.rs`:
  - The four Import upload kinds leave `MACOS_HOST_LEAVES`. The Windows CLI now serves them
    through `HostImportSource`, and only the flash bundle's publication is still refused.
  - `WINDOWS_MEASURED_LEAVES` gains `artifact.import.hap|native-library|workspace-patch|inspect|list|release|abort`.
  - The unit test's expectations follow these changes.
- `cli-feature-coverage.json`, regenerated with `maintainer contracts export`:
  - Windows `implemented` 52 → 61;
  - `partial` 82 → 79;
  - `notImplemented` 6 → 0.
- The six coverage-digest pins in `rust/tests/fixtures/maintainer-contracts/oracle.json` were
  substituted, as in #2378.
- `docs/design/cli-machine-contracts.md` lists the measured leaves.
- `evidence/windows-remaining.md` is refreshed. The method census over this tree:
  - 71/105 methods answered by a composed owner (11 results, 60 owner refusals);
  - 0 non-conforming (census exit 0);
  - 34 with no owner.

## Delegated minor decisions (pending the next rulings batch)

1. **Flash bundle.** `artifact import flash-bundle` is no longer `notImplemented`: the CLI serves
   the upload on Windows. It stays `partial` because the owner refuses its publication until AF-W1
   (#2410 in flight).
2. **Abort setup.** The Import that `abort` ends is begun over the pipe, because every
   `artifact import <kind>` leaf commits in one go. The abort itself runs through the CLI.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/w1-coverage`. The `windows_tool_dispatch` wildcard-listener
  gate (#2396) is present in this tree.
- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-agentd -p arkdeck-cli`: 111 result lines ok, 0 failed, no `SKIPPED`.
- The same test run with `TEMP`/`TMP` set to an 8.3 short path on C:: 111 ok, 0 failed.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- `git diff --check`: clean.
