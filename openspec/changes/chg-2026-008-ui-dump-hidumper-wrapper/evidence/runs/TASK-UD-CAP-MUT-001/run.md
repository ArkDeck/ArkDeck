# TASK-UD-CAP-MUT-001 — Phase A first-device attempt

## Classification

- Date/window: `2026-07-21T14:08:41+08:00` through
  `2026-07-21T14:35:58+08:00` (controlled manifest file times).
- Change: `CHG-2026-008-ui-dump-hidumper-wrapper@r8` (`approved`).
- Core baseline: `CORE-2.0.0`.
- Source revision: `2b6285987009b9cd67b69c911ea51539ac56bd42`.
- Task result: **BLOCKED / ABORTED BEFORE RECIPE CAPTURE**.
- Acceptance result: `INT-UD-CAPTURE-MUT-001` **NOT EXECUTED / NOT PASS**.
- Evidence class: partial `controlledHumanCapture`; this record is not
  `realHardware` acceptance evidence and does not claim Recipe success,
  compatibility, support, conformance, or any canonical `AC-DUMP-*` PASS.
- Claimed human operator: maintainer `lvye` (`fuhanfeng`), who personally ran the
  closed harness commands. This claim becomes attested only if the maintainer
  reviews and merges the evidence PR. Agent-installed-HDC/device/destructive
  dispatch count: `0`.

## Pinned inputs

- Harness alignment merge: `ba4b75b`; ready-restore merge: `6b9dfe4`.
- Harness file SHA-256:
  - `scripts/ud_capture/README.md`:
    `0a479a4ba790c66f9a48034318b6dcf142cbbce047775a7409e46eb67c5ae2ed`
  - `scripts/ud_capture/capture.py`:
    `2cc168b413c4ed204f6fde015bd44c902c5db42cc89167608427cc6d4f408f0b`
  - `scripts/ud_capture/test_capture.py`:
    `e83011baa5442b6446ef8dce524a1a6bef796257aea7f6178b21d25913c24ae9`
- Host-only preflight used the existing offline SDD interpreter
  `<ARKDECK_CANONICAL_ROOT>/.venv-sdd/bin/python`, Python `3.14.6`, PyYAML
  `6.0.3`: `52` harness tests, `0` failures. This preflight dispatched no HDC
  or device command.
- HDC: `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`,
  SHA-256
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`,
  version observed by `HP-0`: `Ver: 3.2.0d`.
- Fixture: `entry-default-signed.hap`, repository-external operator path omitted,
  `1512003` bytes, SHA-256
  `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8`.
- Raw root and full manifests remain in the operator-controlled `0o700`
  repository-external directory. No raw bytes or local user path are copied
  into this evidence directory.

## Human command ledger

All recorded commands used `scripts/ud_capture/capture.py`, argv arrays, the
same controlled session, and the default `120 s` timeout. Connect-key bytes are
omitted and appear only as `<connectkey>` in repository evidence.

| Seq | ID | Human dispatch | Exit | Complete | Self-check | Disposition |
| ---: | --- | --- | ---: | --- | --- | --- |
| 00 | `HP-0` | yes | 0 | true | PASS | pinned HDC hash/version matched |
| 01 | `HP-1` | yes | 0 | true | PASS | operator reported one expected USB target in `Connected` state |
| 02 | `FX-1` | yes | 0 | true | **FAIL** | stdout contained the exact local HAP path and a user-directory path; harness returned STOP |
| 03 | `FX-3` | cleanup only | 0 | true | PASS | abort-rule teardown capture completed |
| 04 | `FX-4` | cleanup only | 0 | true | PASS | abort-rule uninstall capture completed |

Before sequence 02, three operator-entered connect-key values were rejected by
the harness before process dispatch. Those refusals created no controlled
artifacts and had device dispatch count `0`; the operator then loaded the first
field directly from the same-session `01-HP-1.stdout`, which the harness bound
to `hpSequence: 1`.

## Blocker

`FX-1` completed without timeout, truncation, or incomplete drain, and the HDC
process exit code was `0`. Its `179`-byte stdout echoed the absolute local HAP
path. The approved harness therefore recorded:

- `stdout.userPathFound: true`;
- `stdout.localInputPathFound: true`;
- `stdout.completeStreamScanned: true`;
- `stdout.passed: false`;
- command-level `selfCheckPassed: false`.

Per the runbook, the CLI STOP is dispositive even though the process exited
zero. Moving or renaming the HAP is not a valid workaround: the harness compares
stdout with the exact resolved local input path, while this observed HDC family
echoes that path. The operator stopped before `FX-2`, `HP-2`, `SC-1`, `INV-1`,
and every Recipe, then ran only the permitted non-identity abort cleanup
`FX-3`/`FX-4`.

The current approved harness therefore cannot produce a passing Phase A `FX-1`
capture for this observed HDC output shape. Any change to sanitization,
self-check semantics, or command evidence requires a separately approved
remediation task/revision with fake-runner coverage; this capture task cannot
patch or bypass the pinned harness.

## Dispatch and AC conclusions

| Item | Count / result |
| --- | --- |
| Human installed-HDC process dispatches | `5` (`HP-0`, `HP-1`, `FX-1`, cleanup `FX-3`, cleanup `FX-4`) |
| Human targeted device mutations | `3` (`FX-1`, cleanup `FX-3`, cleanup `FX-4`) |
| Agent installed-HDC/device dispatches | `0` |
| Destructive dispatches | `0` |
| `FX-2` dispatches | `0` |
| `HP-2` / `SC-*` / `INV-1` dispatches | `0` |
| `R1` / `R2` / `R3` dispatches | `0 / 0 / 0` |
| UI Dump raw bytes produced | `0` |
| `INT-UD-CAPTURE-MUT-001` | **NOT EXECUTED / BLOCKED** |
| Canonical `AC-DUMP-*` claims | none |

`hardware-evidence.json` is intentionally absent: the required R1-R3 capture
never began, so emitting a schema-valid record could be mistaken for completed
`realHardware` acceptance evidence. The available repository-safe evidence is
the five harness-generated redacted manifests and `capture-hashes.md`; the FX-1
manifest truthfully preserves `selfCheckPassed: false`.

## Deviations and residual risk

- The run followed the fail-closed abort rule after the first post-dispatch
  STOP. No fallback argv, manual HDC command, alternate HAP path, or Recipe retry
  was used.
- `FX-3` and `FX-4` were the only post-STOP device commands and were permitted
  teardown. Their captures are complete with exit `0` and passing stream checks;
  no extra unapproved post-uninstall probe was dispatched.
- Raw/full manifests remain outside git for maintainer-controlled retention.
- Task state must return to `blocked` until an approved harness remediation is
  merged and a fresh Phase A run is explicitly restored to `ready`.
