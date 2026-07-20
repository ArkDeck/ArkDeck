# TASK-UD-CAPTURE-HARNESS-001 run record — 2026-07-20

- Evidence class: `hostOnlyContract` (`fakeRunner` + synthetic local files)
- Core baseline: `CORE-2.0.0`
- Change: `CHG-2026-008-ui-dump-hidumper-wrapper@r6` (`approved`)
- Implementation base: `48efe9733b63d72a4b79896563fda0d544e1f5f1`
- Harness source revision: `9977ab6c2b04cd89a9b9635d64df784b3fb57e26`
- Branch: `agent/task-ud-capture-harness-001`
- Hardware / installed HDC / device / network dispatch count: `0`
- Destructive dispatch count: `0`

This run validates only `INT-UD-HARNESS-001` / `TEST-INT-UD-HARNESS-001`.
`REQ-DUMP-005` and `REQ-DUMP-008` are read-only Safety inputs; this host-only run
does not claim either canonical AC/Test PASS, Recipe success, real-hardware
evidence, compatibility, support, conformance, or release status.

## Fixed environment

- Host: macOS 26.5.2 (25F84), arm64.
- Required interpreter: `<MAIN_CHECKOUT>/.venv-sdd/bin/python` (the observed
  absolute path is home-masked here because CHG-008 forbids committing user
  paths; this is the main checkout's readiness-pinned `.venv-sdd`, while the
  current git worktree does not contain its own `.venv-sdd`).
- Python: `3.14.6` (`Clang 21.0.0`); PyYAML: `6.0.3`.
- Interpreter SHA-256:
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`.
- No package installation or network access occurred.

## Delivered behavior

- Added the closed 14-id `COMMAND_SPECS` surface approved by the task:
  `HP-0`, `HP-1`, `HP-2`, `INV-1`, `R1`–`R3`, `SC-1`–`SC-3`, and
  `FX-1`–`FX-4`. Tests pin every token and compare README/runbook literal argv;
  R1–R3 keep the final `-a` payload as one argv element. R4 is not generalized
  into this list because the approved task list omits it and Phase B remains
  blocked on the separate component-provenance revision.
- Each invocation captures one command, preserving human decision points between
  canonical runbook steps. Unknown ids, forged spec objects, missing/extra
  inputs, unsafe paths, nonpositive timeouts, and output collisions fail closed.
- A targeted command accepts only a validated connect key that is the first
  token of a `Connected` row in the latest complete HP-1/HP-2 capture in the same
  controlled directory. The HP full manifest, stream filenames/hashes, exact
  `list targets` argv, and HDC resolved path/SHA-256 must also match the current
  invocation; drift or tampering is rejected before runner dispatch.
- `WINDOW_ID` accepts ASCII decimal digits only. `LOCAL_HAP_PATH` must be an
  existing regular file outside every git repository and is freshly hashed.
  `LOCAL_SIDECAR_DEST` must be the next controlled `NN-SC-2.sidecar` path inside
  the owner-only session; the harness exclusive-creates it at `0o600`, then
  verifies a single regular file and records it as a separate hashed raw origin.
- The subprocess path is argv-array-only (`subprocess.Popen`) with no shell.
  stdout/stderr are independent O_EXCL `0o600` files. The runner retains at most
  4 MiB per stream while counting and SHA-256 hashing the whole drained stream;
  timeout and truncation remain explicit, fail-closed channels.
- Every command produces a full controlled manifest and a deterministic
  `arkdeck-ud-capture-redacted-1.0.0` manifest. Connect key, window id, home/user
  directories, HAP path, and sidecar destination are masked. An output-side
  sensitive gate withholds the redacted manifest and `capture-hashes.md` on a
  leak. JSON bytes match `scripts/archive_characterization/scan.py::_serialize`.
- `capture-hashes.md` is deterministically rebuilt from redacted manifests and
  includes whole-stream SHA-256/byte counts for stdout, stderr, and any SC-2
  sidecar. Raw bytes and full manifests remain outside git.

## Source identity

All verification below ran after committing the three harness files at source
revision `9977ab6c2b04cd89a9b9635d64df784b3fb57e26`.

| File | SHA-256 |
| --- | --- |
| `scripts/ud_capture/README.md` | `345de0a3a4d24a354e41db790a2c85aa6b38cb13d2715774951ac362c1b6c5f3` |
| `scripts/ud_capture/capture.py` | `f72973807108b4c0af9788aec50a2e377e34e1f64b09432997d26f95944665ce` |
| `scripts/ud_capture/test_capture.py` | `82944fc3bb0c81deb870689068cc6d4b8918fe2cf0f2c03607374cb20ca62b59` |

## Commands and results

| Command | Result |
| --- | --- |
| `<fixed-python> -c 'import sys, yaml; ...'` | Passed: exact interpreter above, Python 3.14.6, PyYAML 6.0.3. |
| `shasum -a 256 <fixed-python>` | Passed: interpreter hash above. |
| `PYTHONDONTWRITEBYTECODE=1 <fixed-python> scripts/ud_capture/test_capture.py` | Passed: 45 unittest methods, 0 failures/skips. The matrix iterated all 14 ids through both fake success and fake timeout paths. |
| `PYTHONDONTWRITEBYTECODE=1 <fixed-python> scripts/ud_capture/test_capture.py SensitiveBoundaryTests.test_broken_redaction_withholds_repo_facing_outputs InputValidationTests.test_latest_hp_recheck_supersedes_older_inventory StreamAndManifestTests.test_truncated_stream_records_whole_and_retained_hashes_and_fails_scan` | Passed: 3 focused fail-closed demonstrations, 0 failures. |
| `ARKDECK_PYTHON=<fixed-python> scripts/check-sdd.sh` | Passed: 0 errors, 0 warnings, 111 acceptance IDs. |
| `git diff --check` | Passed. |
| `shasum -a 256 scripts/ud_capture/{README.md,capture.py,test_capture.py}` | Passed; values recorded in the source table. |
| sensitive-literal scan over this run record (home/serial/key-marker patterns) | Passed: zero matches. |

The only real subprocesses started by the suite used the current Python
interpreter to exercise exit-code, signal, timeout, bounded retention, whole-stream
hashing, and inherited-pipe behavior. The pipeline tests injected a fake runner.
No test resolved or executed an `hdc` binary, and the AST audit confirmed no
shell keyword, shell API, or network import in `capture.py`.

## Binary acceptance conclusion

| Evidence requirement | Conclusion |
| --- | --- |
| Closed allowlist and README/runbook argv parity | **PASS** |
| Strong placeholder/path/same-session HDC identity validation | **PASS** |
| No shell; fake runner only for capture pipeline; no network import | **PASS** |
| Separate O_EXCL streams/sidecar, whole-stream hash, 4 MiB cap, timeout channel | **PASS** |
| Masking, final sensitive gate, deterministic redacted manifest/serializer parity | **PASS** |
| `capture-hashes` summary and controlled naming | **PASS** |
| Installed HDC / device / network / destructive dispatch | **0** |

`TEST-INT-UD-HARNESS-001` is PASS at the pinned source revision. Per the task's
PR boundary, this implementation/evidence PR does **not** edit `tasks.md` or
draft `ready → done`; that state change belongs to a later independent status PR
after maintainer review/merge of this source and evidence.

## Deviations and residual risk

- No task-scope deviation and no Core/spec/AC/schema/platform/profile/product
  implementation change. The work is limited to the three allowed harness files
  plus this run record.
- R4 is deliberately unavailable in the current closed allowlist. Before Phase B
  can execute, its separately approved decision revision must pin component
  provenance and explicitly update/reverify the harness; current R4 dispatch is 0.
- Fake-runner evidence proves orchestration and fail-closed mechanics only. It
  does not prove target-build output families, device behavior, HDC compatibility,
  or real-hardware support. The later human capture tasks retain all runbook,
  physical-target, ownership, privacy, and hardware-evidence gates.

## Review-remediation addendum — 2026-07-20

PR #143 review identified one concrete Phase A advisory and three harness
accounting/error-channel issues. The original source revision and results above
remain the historical first run. The current PR source is superseded by:

- Remediation source revision:
  `c7f8ce81a4ee2bc3481ad9b26945cc02adc12063`.
- Evidence class remains `hostOnlyContract`; installed HDC, device, network and
  destructive dispatch counts remain `0`.

| Current source file | SHA-256 |
| --- | --- |
| `scripts/ud_capture/README.md` | `00c68f9dc386da41c751dadc710e75211a990cd94abaddb57f892a12458f3b99` |
| `scripts/ud_capture/capture.py` | `c86ad5f278cd81dc742fac7bfb47d5efb581720c6cbd2a13f102801adc0b53a2` |
| `scripts/ud_capture/test_capture.py` | `752fd342926e48b4fb70885be9bf4e43aa7457c98ca1c7f991784c0f4e3f215a` |

### Addressed findings

1. **Phase A target-list output shape (advisory):** the approved runbook and
   harness use plain `hdc list targets`, while target binding requires a row with
   the connect key as its first token and a later `Connected` field. Some HDC
   versions may emit only a bare serial unless `-v` is used. Before any Phase A
   targeted dispatch, the human maintainer must inspect HP-1 and confirm the
   approved shape. Bare-serial output intentionally keeps all targeted commands
   fail-closed with runner dispatch `0`; adding `-v` requires an approved runbook
   + harness revision and must not be improvised during capture. This host-only
   task does not resolve the real-device output-shape risk.
2. **Inherited pipe accounting:** each captured stream now records
   `drainIncomplete`. If its reader has not reached EOF after the two-second
   grace, the manifest records `sha256Scope: observedBeforeDrainCutoff`, complete
   stream scanning and `captureComplete` fail, the CLI returns STOP status `1`,
   and the summary exposes the incomplete drain. Complete streams retain
   `sha256Scope: wholeStream`. The daemonized-grandchild test now asserts the
   flag rather than proving only non-stall behavior.
3. **Redaction exit semantics:** output-side redaction failures raise the
   post-dispatch `StopRequired` channel and map to CLI status `1`; pre-dispatch
   usage/harness refusal remains status `2`.
4. **Malformed summary input:** a matching redacted-manifest filename with a
   missing/invalid `sequence` now raises `CaptureError` with file context instead
   of leaking a raw `KeyError`; stream structure is validated before summary
   rendering as well.

### Remediation commands and results

| Command | Result |
| --- | --- |
| `PYTHONDONTWRITEBYTECODE=1 <fixed-python> scripts/ud_capture/test_capture.py` | Passed: 49 unittest methods, 0 failures/skips. |
| focused HP drain rejection + drain manifest/summary + missing-sequence + CLI status cases | Passed: 4 tests, 0 failures. |
| `ARKDECK_PYTHON=<fixed-python> scripts/check-sdd.sh` | Passed: 0 errors, 0 warnings, 111 acceptance IDs. |
| `git diff --check` | Passed. |
| `shasum -a 256 scripts/ud_capture/{README.md,capture.py,test_capture.py}` | Passed; current values recorded above. |

`TEST-INT-UD-HARNESS-001` remains **PASS** at remediation source revision
`c7f8ce81a4ee2bc3481ad9b26945cc02adc12063`, subject to maintainer review/merge.
This addendum does not change the independent `ready → done` status-PR boundary
or make any real-device/output-family/compatibility claim.
