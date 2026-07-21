# TASK-UD-CAP-MUT-001 — Phase A attempt 3 complete capture

## Classification

- Window: `2026-07-21T17:09:21+08:00` through
  `2026-07-21T19:52:14+08:00` (repository-facing redacted-manifest file times).
- Change/task: `CHG-2026-008-ui-dump-hidumper-wrapper` /
  `TASK-UD-CAP-MUT-001`.
- Evidence ID: `EVD-UD-CAP-MUT-DAYU200-20260721-003`
  (`hardware-evidence.json`, schema `2.0.0`, provider `none`).
- Result: **CAPTURE PROTOCOL PASS CANDIDATE** for
  `INT-UD-CAPTURE-MUT-001`, effective only after maintainer review/merge of the
  evidence PR. R1/R2/R3 remain `unknownOutput`; this record does not claim
  Recipe success, compatibility, support, conformance, release status, or any
  canonical `AC-DUMP-*` PASS.
- Claimed operator: human maintainer `fuhanfeng`, who personally executed every
  installed-HDC command. Agent installed-HDC/device/destructive dispatch count:
  `0 / 0 / 0`.

## Pinned inputs and toolchain

- Capture checkout observed during evidence assembly:
  `78c149ce68dbed82ae88a7992fe44be3266aff19`; the capture trust identity is the
  following merged OID/hash chain rather than unrelated checkout contents.
- Original harness/alignment/ready-restore merges:
  `7978fa761dcd8a38b7fea6ea040dac21147d1f2a`,
  `ba4b75b0c118a75af4415f9492f0c5e982ef138c`,
  `6b9dfe497fced8f8ce9fba171b04ce09dd8a187f`.
- Echo remediation source/implementation merge/done merge/CAP-MUT ready-restore:
  `4049bb0de80160a696e6f8defabb3f70e4135d5a`,
  `b38d028ff821900c7c191c2bccc5951c5c719e7b`,
  `3ac44f2d759bd8bec8f95405b85281d70f89cad0`,
  `04e061e3328893b407d31ad83d19793973b02bd6`.
- Harness SHA-256:
  - `scripts/ud_capture/README.md`:
    `6e5db1827176a0c16b5a4b21431efa9e4d4dab041f03801a357f74b3db2f2601`;
  - `scripts/ud_capture/capture.py`:
    `b407aaa07260e3252428bdf00431f4d1e451c30f77c55f1f6b15a5d170d19492`;
  - `scripts/ud_capture/test_capture.py`:
    `b29c15b8fdca755f26fdfe4f5156082a8bb4a6fd80d8ceecec178419d4690070`.
- Host-only preflight: fixed Python `3.14.6`; harness tests `63 / 63` PASS.
- HDC: `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`,
  SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`,
  version `Ver: 3.2.0d`.
- Fixture: `entry-default-signed.hap`, `1512003` bytes, SHA-256
  `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8`;
  repository-external local path omitted.
- Target: operator-confirmed same physical DAYU200 (RK3568), OpenHarmony
  `7.0.0.34`, API `26.0.0`, USB. Serial appears only in
  `hardware-evidence.json`, as permitted by the evidence contract.

## Human command ledger

All 25 harness invocations used the same fresh controlled session and default
120-second timeout. Every process recorded exit `0`; every stdout/stderr and the
one sidecar was complete, whole-stream/whole-file hashed, untruncated,
non-drain-incomplete and self-check PASS.

| Seq | ID | Exit | ms | stdout B | stderr B | sidecar B | Disposition |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 00 | `HP-0` | 0 | 35 | 12 | 0 | 0 | pinned HDC hash/version matched |
| 01 | `HP-1` | 0 | 42 | 58 | 0 | 0 | one USB / Connected target; key kept controlled |
| 02 | `FX-1` | 0 | 1584 | 179 | 0 | 0 | install; exact local-HAP echo accepted only by schema-1.1 policy |
| 03 | `FX-2` | 0 | 565 | 28 | 0 | 0 | fixture start; foreground confirmed by operator |
| 04 | `HP-2` | 0 | 20 | 58 | 0 | 0 | same target before `INV-1` |
| 05 | `SC-1` | 0 | 131 | 108 | 0 | 0 | pre-`INV-1`: absent |
| 06 | `INV-1` | 0 | 133 | 1490 | 0 | 0 | unique fixture foreground window selected locally |
| 07 | `SC-1` | 0 | 131 | 108 | 0 | 0 | post-`INV-1`: absent |
| 08 | `HP-2` | 0 | 20 | 58 | 0 | 0 | same target before `R1` |
| 09 | `SC-1` | 0 | 132 | 108 | 0 | 0 | pre-`R1`: absent |
| 10 | `R1` | 0 | 2205 | 474 | 0 | 0 | complete `unknownOutput`; not Recipe success |
| 11 | `SC-1` | 0 | 132 | 108 | 0 | 0 | post-`R1`: absent |
| 12 | `HP-2` | 0 | 20 | 58 | 0 | 0 | same target before `R2` |
| 13 | `SC-1` | 0 | 131 | 108 | 0 | 0 | pre-`R2`: absent |
| 14 | `R2` | 0 | 401 | 475 | 0 | 0 | complete `unknownOutput`; not Recipe success |
| 15 | `SC-1` | 0 | 132 | 132 | 0 | 0 | post-`R2`: newly created regular sidecar |
| 16 | `SC-2` | 0 | 77 | 78 | 0 | 866256 | owned sidecar received and full-file sensitive scan PASS |
| 17 | `SC-3` | 0 | 132 | 0 | 0 | 0 | exact owned remote sidecar removed |
| 18 | `SC-1` | 0 | 132 | 108 | 0 | 0 | post-removal re-check: absent |
| 19 | `HP-2` | 0 | 20 | 58 | 0 | 0 | same target before `R3` |
| 20 | `SC-1` | 0 | 132 | 108 | 0 | 0 | pre-`R3`: absent |
| 21 | `R3` | 0 | 3452 | 474 | 0 | 0 | complete `unknownOutput`; not Recipe success |
| 22 | `SC-1` | 0 | 132 | 108 | 0 | 0 | post-`R3`: absent |
| 23 | `FX-3` | 0 | 497 | 33 | 0 | 0 | fixture stop cleanup complete |
| 24 | `FX-4` | 0 | 3108 | 78 | 0 | 0 | fixture uninstall cleanup complete |

`HP-1` and all four `HP-2` stdout hashes are identical after repository-safe
redaction (`d8816e41…`); the human scripts also compared the unredacted first
field locally without displaying or persisting it outside the controlled state.
Every targeted command used `-t <connectkey>` sourced from the latest trusted
same-session HP capture. No default target, fallback argv, shell redirection,
manual HDC command, retry, explicit server-lifecycle command or R4 dispatch was
used.

## Recipe and sidecar conclusions

| Command | Stream bytes / SHA-256 | Result |
| --- | --- | --- |
| `R1` | stdout `474` / `91ec56506e94364e230bffddec5ca56d059c98b4a16f19881f395437cc589f37`; stderr empty | `unknownOutput`; no `option … missed`; capture complete only |
| `R2` | stdout `475` / `7e43c21f62feb04162cbca6f3099d4ff19aa1c768b19ea5997314f7cbb7773e1`; stderr empty | `unknownOutput`; no `option … missed`; capture complete only |
| `R3` | stdout `474` / `e72c5b81bf977ab0c6a25ba17dca9237358b8fabc716b9e35c73d1f2fd45667f`; stderr empty | `unknownOutput`; no `option … missed`; capture complete only |

All fixed-path pre checks were absent. `INV-1`, R1 and R3 were absent again at
post. R2 produced one newly created regular sidecar after an absent pre-state;
the harness exclusively created the controlled destination, received and fully
scanned `866256` bytes (SHA-256
`ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`),
then the operator executed the exact-path `SC-3` and confirmed absent again.
The sidecar bytes remain outside git and were not opened during evidence
assembly.

The `FX-1` stdout self-check records policy
`fx1-stdout-exact-local-hap-v1`, `expectedLocalInputEchoFound=true`,
`unexpectedUserPathFound=false`, `unexpectedLocalInputPathFound=false` and
command-level PASS. All other streams use `strict-sensitive-output-v1`.

## Repository-facing evidence and validation

- `25` schema-`1.1.0` redacted manifests, sequences `00`–`24`, copied
  byte-identically from the controlled directory.
- `capture-hashes.md`: `51` whole origins (`50` stdout/stderr streams plus one
  sidecar), no truncation or drain incompleteness; file SHA-256
  `2d5561b9ca720c82d6c437709e9c3b080a0bc52f3147b09ead458f49b4ed261b`.
- `hardware-evidence.json`: schema `2.0.0`, provider `none`; artifact paths and
  per-file SHA-256 recorded there.
- Repository-sensitive scan rejects user-home/local session/HAP path, known
  serial outside `hardware-evidence.json`, connect-key literals and unmasked
  window IDs. Raw/full manifests and received sidecar bytes remain outside git.
- JSON-schema validation: `/opt/homebrew/bin/pipx` `1.15.0` launched
  `check-jsonschema` `0.37.4`; command
  `pipx run check-jsonschema --schemafile openspec/contracts/hardware-evidence.schema.json <attempt-3-hardware-evidence>`
  returned `ok -- validation done` / exit `0`.

## Dispatch counts and AC conclusion

| Item | Count / result |
| --- | --- |
| Human installed-HDC process dispatches | `25` |
| Human explicitly targeted (`-t`) commands | `19` |
| `HP-0` / `HP-1` / `HP-2` | `1 / 1 / 4` |
| `INV-1` / `R1` / `R2` / `R3` | `1 / 1 / 1 / 1` |
| `SC-1` / `SC-2` / `SC-3` | `9 / 1 / 1` |
| `FX-1` / `FX-2` / `FX-3` / `FX-4` | `1 / 1 / 1 / 1` |
| R4 dispatches | `0` |
| Agent installed-HDC/device/destructive dispatches | `0 / 0 / 0` |
| Human destructive dispatches in attempt 3 | `0` |
| `INT-UD-CAPTURE-MUT-001` | **PASS candidate for controlled capture protocol, subject to maintainer evidence-PR review/merge** |
| Canonical `AC-DUMP-*` claims | none |

## Deviations and residual risks

- Attempt 2 was aborted after sequence 10 because the human operator reflashed
  the device outside the runbook. It is preserved separately, not reused or
  rejudged; attempt 3 restarted at `HP-0`. The reflash's exact command, image
  digest and exact time were not captured; the operator confirmed the same
  physical board and approved firmware/API tuple before attempt-3 `HP-1`.
- The written physical confirmation occurred after `HP-0` and before `HP-1`;
  `hardware-evidence.confirmedAt` uses the immediately following `HP-1`
  redacted-manifest file time as the recorded boundary.
- During coordination the operator pasted a transient window identifier and
  limited controlled stdout excerpts into the task conversation. No connect
  key, serial, user-home/local path, full manifest or sidecar bytes were pasted.
  The values are not repeated here; every repository-facing harness self-check
  and the independent repository scan passed.
- This is one DAYU200 / OpenHarmony 7.0.0.34 / API 26.0.0 / HDC 3.2.0d / USB
  observation. Any device firmware or HDC version change requires
  revalidation. R1/R2/R3 output semantics remain unresolved and require the
  separate approved decision revision before Phase B/R4 can become ready.

## Boundary

This evidence closes only the human Phase A capture protocol candidate. It does
not close the task state in this PR, does not change `verification.md`, does not
register a Recipe success family or component token, and does not authorize R4.
After this evidence PR is reviewed and merged, a separate status-only PR may
propose `TASK-UD-CAP-MUT-001 ready→done`.
