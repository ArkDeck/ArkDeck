# TASK-XPA-022 / WM6 — phase A runbook (2026-09-30)

- **Kind:** documentation only, host-only. No hdc was run, the DAYU200 was not touched, and no
  certificate store or system setting was changed.
- **Base:** protected `main` `565f8b1d`.
- **Product:** `docs/design/cross-platform/windows-phase-a-runbook.md`. It is the WM6 item
  "阶段 A 的 runbook" of `docs/design/cross-platform/windows-phase-agent-prompt.md`.

## What it covers

It lists the maintainer's phase A work in the order it can be done. Each step gives its gate, the
exact command, the expected result and the record path:

| § | Step | Commands taken from |
| --- | --- | --- |
| 1 | Identity: the development daemon signer (check), the development MSIX publisher `CN=ArkDeck Development`, and production Azure Artifact Signing | `rust/scripts/windows-dev-identity.ps1`, `windows/scripts/package-rc.ps1`, `rust/scripts/windows-package-xcopy.ps1`, the SPK-4 crib, and `runs/TASK-XPA-022/windows-rc-package-run.md` |
| 2 | Sampling: the HDC and USB cribs, then WHR-001..003 | `runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md`, `runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md`, `rust/scripts/windows_sample_process.py`, CHG-2026-078 |
| 3 | The SPK-3 rows only the maintainer can run (rows 1–6) | `runs/TASK-XPA-002/spk-3-20260930-run.md`, `rust/scripts/windows-spk3.ps1` |
| 4 | GJ-1..5 on the DAYU200: the Windows differences, then each Journey's gate | `docs/design/cli-golden-journey-headless-runbook.md` §0–§7 (judging criteria unchanged) |
| 5 | Clean-host smoke | `package-rc.ps1 -SmokeZip` |
| 6 | Traceability and platform flip | `openspec/verification/traceability.md` update rule, `PLATFORM-PROFILES.lock.yaml`, `openspec/platforms/windows/*` |
| 7 | Order at a glance | — |

## Gaps named in the runbook (agent work, not maintainer)

- `package-rc.ps1` has no production mode; the production App and MSIX wait for one (§1.3).
- The Windows configuration surface for the ArkForge lane (GJ-4) replaces `runtime service update
  --arkforge-*`, which Windows does not have. Its command is TBD by TASK-XPA-010 (§4.4).
- GJ-1..5 depend on the Windows HDC registry adoption (XPA-004/005 after WHR-002) and on each
  Journey's Windows owners (XPA-008/009/010/011). Their gates are stated per Journey; none is
  bypassed.

## Delegated minor decisions (pending the next rulings batch)

1. **Location and language.** The runbook sits in `docs/design/cross-platform/`, next to
   `macos-rust-cutover-runbook.md`, and is written in English like the other Windows run records.
   It points at the Chinese headless runbook for each Journey's steps and criteria rather than
   duplicating them. This keeps one source for the judging criteria.
2. **Windows installation.** For the GJ runs, the product is installed by unpacking the RC xcopy
   zip, and the CLI is pointed at its daemon with the publisher (production) or signer
   (development) pin. There is no `runtime service install`/`update` on Windows (decision 11:
   the daemon is client-started).

## Checks

- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- `git diff --check`: clean.
