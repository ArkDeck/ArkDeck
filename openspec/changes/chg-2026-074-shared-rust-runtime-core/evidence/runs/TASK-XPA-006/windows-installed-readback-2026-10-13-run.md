# Windows installed History/Diagnostics/Viewer readback — 2026-10-13

## Result and scope

The complete installed-App readback now passes: **4/4, zero skips**. Both
English and Chinese cases opened the retained Diagnostics/Trace and
screenshot/tree records through the real account Runtime. This closes the
History snapshot contention defect found in the
[earlier run](windows-gj5-app-readback-2026-10-13-run.md); its failed attempts
remain recorded there.

The measured Runtime and App were produced from reviewed protected main
`aea6c663e8c79fe1501d5751a411a5b15021b3e6` (#2633), whose tree matches the
CI-tested head `1410cec2f3d96b0a3020ff2e302ace98adbb739a`. Catalog remains
`e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7`.
The package is signed with the existing host-trusted development identity;
this is not production release signing or a new device acceptance campaign.

Raw artifacts remain outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013`. The records below contain no
device serials, connect keys, account names, machine names or user-directory
paths. No capability, trusted fact or hardware-evidence declaration was made
by the acceptance harness.

## Published package and installation

The official `windows/scripts/package-rc.ps1` ran from a clean checkout of
that exact protected-main revision with `-SigningMode development -SkipMsix
-Smoke`. Its release build, signed CLI doctor and isolated real-App smoke
completed with exit 0. The isolated smoke deliberately has no HDC/target; its
Doctor blockers are the expected private-root observations, not the installed
account's health.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| RC ZIP | 73,804,206 | `4ea9bcab2e1231bf0a9d2571fff5e112dca25ae4a6a4cfecae00b33f90d6e30e` |
| Runtime ZIP | — | `1698bd2d394582ed7f1f2629c24ebf3e066f2a8a4c828c6fd4176c13a07623bb` |
| `arkdeck-agentd.exe` | 12,463,968 | `23e658ca9e006a23082f30297d11864509709c8a0c7d82e892c2df7e1934b43c` |
| `ArkDeck.exe` | 337,760 | `1845967ceae67956ac9ca9ff854b065be578c12e63cd88b8578bad8b11a71b8f` |
| `bin/arkdeck.exe` | 5,701,472 | `1e7ecbf03f5089a4b61dc9f0660ef2bc1188fa64ce1e3cccb7f490f995edc437` |

Before promotion, all 365 manifest files and the three executable signatures
were verified. All 57 account Jobs were terminal. The original Runtime was
stopped through its published service command; the existing App directory was
retained as `App-before-history-fix-20261013`, and the verified package became
the installed App. The launcher and signer pin did not need changes.

The installed CLI then reported healthy Runtime readiness and the exact
installed daemon path. The complete before/after Job items, sorted by Job ID,
were identical; the check did not compare only counts. The existing account
state and retained device artifacts were preserved. Logs are
`history-install-stage.log`, `history-install-promote.log` and the six
published CLI captures in `raw-history-fixed-install`.

## Actual App observations

`InstalledCaptureTests` ran against the installed executable and the live
account pipe, with the retained GJ-2 capture and separate Viewer capture as
inputs. It used neither a fake transport nor newly submitted Jobs.

- History and Inspector loaded together without an unavailable-page refusal.
  Historical Job, Target, Catalog and Artifact digests matched the published
  record in both languages.
- Diagnostics retained historical context and exposed no live-capture
  controls. HiLog preview matched the verified Artifact prefix. The opened
  Trace cache matched the entire source Artifact's byte count and SHA-256.
- Viewer decoded the PNG, verified screenshot coordinates and compared the
  full verified UI tree's component count, selected root type and raw node
  JSON. Historical context and exact screenshot/tree digests matched.
- Each case compared complete Job inventories before and after opening the
  record. There was no recapture. Test-owned Trace cache files were removed.

These observations do not claim the deferred Windows Trace parser, audible
Narrator acceptance, packaged-client isolation or MSIX update-feed coverage.

## Local targeted checks

- Protected-main RC producer with `-SkipMsix -Smoke`: exit 0, including 1/1
  real-App smoke; `package-history-fixed.log` and
  `rc-history-fixed/smoke.json`.
- Staged installation, typed stop, restarted health/status and complete Job
  inventory comparison: exit 0; logs and raw captures listed above.
- `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj -c Release
  --no-restore -p:Platform=x64 --filter FullyQualifiedName~InstalledCaptureTests`:
  exit 0, 4/4, zero skips, 78 seconds; `uia-history-fixed.log` and
  `uia-history-fixed/installed-history-fixed.trx`.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 at the existing
  Windows argument-length limit (error 206), before source checking;
  `results-fmt-all-check.log`. Equivalent per-edition bounded
  `rustfmt --check` batches through the same runner passed all 356 Cargo
  target roots, exit 0; `results-fmt-batched-check.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings, 121 acceptance
  IDs; `D:/src/ArkDeck-wt/tools/windows-results-sdd-20261013.log`.
  `git diff --check`: exit 0.

This follow-up changes documentation only. No Rust, Swift, contract or App
source was changed, so crate tests/clippy, Swift tests and contract generation
were not repeated. Documentation checks are recorded with this delivery;
the complete unified gate remains PR CI.

## CI

Published History fix #2633 passed SDD Guard `38373622446` and Swift CI
`38373622565`, including Windows client and Windows/macOS/Linux Rust parity
lanes, before the maintainer merged it. The installed release above uses that
reviewed source.

The adjacent MSIX packaging repair [#2634](https://github.com/ArkDeck/ArkDeck/pull/2634),
head `2145aea07839cabc41f37b4fcf5fefbefeb2604e`, passed Swift CI `38378925063`
(Windows client and required aggregate) and SDD Guard `38378924891`, with
subsequent body-update guards also successful. It still requires maintainer
review and a protected-main package rerun. This evidence follow-up is stacked
above that PR while it remains open; its own CI result is reported on its PR.
