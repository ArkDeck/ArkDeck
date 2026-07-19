# TASK-PD-001 r4 headless codec remediation run

## Run identity and classification

- Execution base: `8c1311b8be74c0393c2d490f72c63ffa39b3cdb6`
  (`main`, includes merged r4 readiness `f41b6bf068948f6988fbe39216559b43d02091cc`).
- Execution branch: `agent/task-pd-001-headless-remediation`.
- Time: 2026-07-19 14:11 +0800, Asia/Shanghai.
- Environment: macOS 26.5.2 (25F84), arm64; CPython 3.14.6/stdlib for
  implementation tests; CPython 3.11.15 for the repository SDD checker.
- Evidence class: `contract`; synthetic fixtures, mocked descriptor metadata and local
  temporary directories only.
- Result: **PASS for `TEST-DECODE-DAYU200-HEADLESS-001` only.** The three platform
  Test IDs remain pending and are not executed, downgraded or reinterpreted here.
- Task disposition: implementation/evidence candidate complete; `TASK-PD-001` remains
  `ready` until a separate maintainer-reviewed status PR.

## Source identity

The run is bound to the execution base plus these complete implementation-source
SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `scripts/partition_decode/README.md` | `3c518ec1be658cb2975b2123cd3d412ab2b02a2a592c855653a965a5cbe8609e` |
| `scripts/partition_decode/decode.py` | `a413defecd8658462a821ab14c7be4326ee42ae77673325c691daf6f653fb493` |
| `scripts/partition_decode/evidence.py` | `aa97e86c5957fe4b722e99b5988b067f86d09199edbc3138a088028e87247e64` |
| `scripts/partition_decode/test_decode.py` | `6c8b7f0a61f061b1551f9ad369273bd7b0fbf32675fb1fc4cd2834c9c323634e` |

`scripts/partition_decode/macos_input_broker/**` remained read-only. `git ls-tree` and
`git hash-object` both reported the base blobs unchanged:

| Broker path | Git blob |
| --- | --- |
| `Broker.entitlements` | `7b82f33bb4e0f2764acac052010bf905161e9ea6` |
| `Info.plist` | `c855ed1a448730dba3befa55389d5025a8d38bce` |
| `README.md` | `0a62889b8559ea11aa140daa3c16c1d5ada49d0a` |
| `build_and_sign.zsh` | `9f6da2209d4d8b92b27624f3f74f2370a9fd868d` |
| `collect_platform_evidence.py` | `839b53464605c27134ba8d527dd616e078b4b2fb` |
| `main.m` | `71d183c58a82aa749807651156ed6c64204a6313` |
| `policy.json` | `519bfa75178a888db234535d14a5e3467852945a` |

## Commands and results

| Command | Result |
| --- | --- |
| `env PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=error python3 scripts/partition_decode/test_decode.py` before implementation | PASS: 35 tests, 0 failures (readiness baseline reproduced) |
| same command after remediation | PASS: 43 tests, 0 failures |
| `env PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=error python3 scripts/archive_characterization/test_scan.py` | PASS: 36 tests, 0 failures |
| `env ARKDECK_PYTHON=/opt/homebrew/bin/python3.11 scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --cached --check` after staging the task allowlist | PASS: exit 0 |
| cached-path allowlist and broker blob audit against execution base | PASS: only the four allowed implementation files, this run and the permitted `tasks.md` reference changed; all broker blobs match the base |

The 43-test suite contains the task's static production-source allowlists. It proves
the decoder still has zero archive-path open, subprocess, network, HDC/vendor-tool,
transport or device-mutation call target, and that the non-target discard path has no
second plaintext accumulator, hash, log, persistence, clone, export or history-view
surface.

## Closed codec receipt conclusions

| Contract branch | Binary result | Evidence |
| --- | --- | --- |
| Configuration/runtime separation | PASS | runtime constructor observation is exactly DEFLATE base window bits `15`, gzip zlib `wbits=31`, history upper bound `32768`; constructor has one positional argument and no preset dictionary |
| Compressed remainder | PASS | configured cap `65536`; runtime maximum is separately observed and capped; close records pre-close bytes and exactly `0` after close |
| Application plaintext lifecycle | PASS | each non-target chunk is held inside a nested `try/finally`; cancellation injected while the live counter was `1` left no `produced` binding in the traceback frame, and receipt cleanup observed live plaintext `0`; discard has no accumulator or secondary use |
| Success cleanup | PASS | one codec create/close pair through explicit `finally`; destruction point `targetBodyObtained`; codec inactive and remainder `0` after close |
| `DecodeFailure` cleanup | PASS | fault injected after a codec read; explicit `finally` closed codec/remainder and the closed receipt validated |
| Unexpected-exception cleanup | PASS | `RuntimeError` injected after a codec read; explicit `finally` closed codec/remainder and the closed receipt validated |
| Cancellation cleanup | PASS | `KeyboardInterrupt` injected inside discard after a chunk became live; the discard `finally` released it before traceback propagation, then the outer `finally` closed codec/remainder and the closed receipt validated |
| Receipt fail-closed branches | PASS | missing/extra fields; configured/observed contradiction; history/wbits mismatch; cap overflow; preset dictionary; clone/export/history view; extra non-target buffer; retained/live plaintext; duplicate/incomplete cleanup; remainder after close; and forensic-zeroization assertion are rejected; every numeric field requires exact `int` type and every boolean uses identity, with bool/float confusion rejected by both receipt and full-bundle validation |
| Existing regression | PASS | descriptor, identity, streaming, tar, closed grammar, reconciliation, deterministic create-only publication, runtime/platform receipt and broker static negative branches all remain green |

The receipt explicitly records
`allocatorResidueForensicZeroizationClaimed:false`. It proves the application-visible
reference lifecycle only; it makes no allocator-forensic claim.

## Dispatch and evidence boundary

| Action/output | Count |
| --- | ---: |
| collector launch | 0 |
| pinned archive read | 0 |
| NSOpenPanel/PowerBox or broker runtime | 0 |
| mapping/reconciliation/platform summary output | 0 |
| HDC/vendor tool/network/production child process | 0 |
| real or simulated device access/mutation/destructive dispatch | 0 |

This run does not decide `TEST-DECODE-DAYU200-PARTITION-001`,
`TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` or
`TEST-DECODE-DAYU200-RECONCILE-001`. Those remain owned by `TASK-PD-002`, which must
bind a future fresh collector run to the merged full implementation commit and signed
broker artifact on an interactively unlocked console.

## Deviations and residual risk

- One initial read-only broker-blob audit loop used zsh's special `path` variable,
  which removed command lookup for later loop iterations. It changed no file or external
  state; the audit was rerun with the task-specific `pd_file` variable and all seven blobs
  matched the execution base.
- No pinned-archive, broker signing/runtime, PowerBox or platform behavior was exercised.
  Therefore all platform AC, mapping values, reconciliation results, gap/DEC-002,
  compatibility, hardware, support and release conclusions remain pending/unchanged.
- The final merged implementation OID does not yet exist. This contract run is bound to
  the execution base and complete source hashes above; `TASK-PD-002` must use the future
  merged full commit OID, not this branch name or worktree.
