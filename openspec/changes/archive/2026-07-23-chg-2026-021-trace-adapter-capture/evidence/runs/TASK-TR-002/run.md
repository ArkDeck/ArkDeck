# TASK-TR-002 host contract run

- Date:2026-07-21(Asia/Shanghai)
- Base:`main` `f3c9685ea70b32099c20bf7fe022bbc9aa688709`
- Branch:`agent/chg-2026-021-tr-002`
- Environment:macOS arm64,Apple Swift 6.3.3;SDD guard CPython 3.14.6 +
  PyYAML 6.0.3 from the existing main-checkout `.venv-sdd`.
- Evidence class:`contract`;all Trace observations are in-memory synthetic fixtures.
- Dispatch classification(task-specific suite):real device 0,HDC 0,network 0,external
  process 0.The full regression suite also exercises pre-existing local fake/process fixtures;
  it performs no real-device Trace work.

## Scope implemented

- Pinned host bindings for `trace-presets`@1.0.0 and
  `attachment-debug-profile`@1.0.0,including direct file-hash drift tests against readiness
  SHA-256 values.
- Capability-constrained configuration with exact unsupported-tag diff and a type boundary that
  requires explicit acceptance before the supported alternative becomes executable.Buffer values
  require an Adapter-confirmed unit.
- Catalog-bound typed parameter snapshots/modes,set/read-back receipts,distinct failure audit
  codes,temporary restoration and `needsAttention` on restore mismatch.
- Capture authorization that fails closed on configuration capability drift,parameter mismatch,
  or incomplete reboot binding recovery.Core `DeviceRebindPolicy` is reused and durable binding
  remains required after auto-rebind eligibility.
- Typed Core workflow steps for parameter confirmation/setup,Job-UUID isolated capture,
  typed stop compensation,partial receive,validate/hash,optional derived postprocess,verified
  cleanup and restore.
- Host receive lifecycle,indeterminate progress with elapsed time,semantic artifact validation,
  and complete Trace manifest metadata face.

No hitrace/bytrace argv,help parser,output marker,golden fixture,CLI/UI integration,Core schema,
or real adapter dispatch was added.

## Verification commands and results

| Command | Result |
| --- | --- |
| `shasum -a 256 openspec/contracts/catalogs/trace-presets.yaml openspec/contracts/catalogs/debug-parameters.yaml` | PASS;`12c0f0502cb17832f66223670a124b6fe48e903883a01c44a9cc4340fc2628cf` and `10ee4c38c4728a344a39b98b56759adae50323c260ad52345eaf4d5e4f978acc`,matching readiness pins. |
| `swift format lint <four Trace Swift files>` | PASS;0 diagnostics. |
| `swift test --package-path Packages/ArkDeckKit --filter TraceWorkflowContractTests` | PASS;14 tests,0 failures;includes all seven canonical AC rows below plus catalog drift,phased typed-plan,missing-readback,cleanup,restore and manifest support tests. |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS;316 tests executed,1 existing opt-in manual sleep/wake test skipped,0 failures/0 unexpected.Changed count is baseline 302 + 14 TASK-TR-002 tests. |
| `env ARKDECK_PYTHON=<main>/.venv-sdd/bin/python scripts/check-sdd.sh` | PASS;0 errors,0 warnings,111 acceptance IDs. |
| `git diff --check` | PASS. |

The first plain `scripts/check-sdd.sh` attempt selected the PATH Python and stopped before SDD
validation with `ModuleNotFoundError:yaml`.Per the repository interpreter contract,it was rerun
with the existing pinned main-checkout interpreter above;no dependency was installed and no
network access occurred.

One targeted Swift rerun inside the filesystem sandbox stopped before manifest compilation because
the Xcode module cache path was not writable.The same command and the final full suite passed after
using the approved sandbox-external Swift test prefix;this was an execution-environment failure,
not a product test failure.

## AC conclusions

| Acceptance | Contract result | Evidence line |
| --- | --- | --- |
| `AC-TRACE-002-01` | PASS | `TEST-AC-TRACE-002-01 PASS unsupported=binder original_executable=false explicit_acceptance=true device_dispatch=0 real_device=0` |
| `AC-TRACE-003-01` | PASS | `TEST-AC-TRACE-003-01 PASS snapshot=missing temporary_restore=false persistent_confirmation=required silent_downgrade=false real_device=0` |
| `AC-TRACE-004-01` | PASS | `TEST-AC-TRACE-004-01 PASS set_exit=0 readback=mismatch audited=true capture_dispatch=0 real_device=0` |
| `AC-TRACE-005-01` | PASS | `TEST-AC-TRACE-005-01 PASS candidates=2 state=awaitingRebindConfirmation capture_dispatch=0 real_device=0` |
| `AC-TRACE-006-01` | PASS | `TEST-AC-TRACE-006-01 PASS host_state=partial owned_remote=retained early_cleanup=false real_device=0` |
| `AC-TRACE-008-01` | PASS | `TEST-AC-TRACE-008-01 PASS total=unknown meter=indeterminate elapsed_ms=12345 percentage=nil real_device=0` |
| `AC-TRACE-009-01` | PASS | `TEST-AC-TRACE-009-01 PASS exit=0 bytes=0 succeeded=false diagnostic=emptyTrace real_device=0` |

## Deviations and residual risk

- No scope deviation.The diff adds only `Trace*` files under ArkDeckWorkflows,the corresponding
  contract test,and this change's evidence files.
- TASK-TR-001 provenance and TASK-TR-003 parser golden work remain separate.Adapter behavior and
  any real device/firmware support claim remain unverified and out of scope.
- This implementation/evidence run does not change TASK-TR-002 status or mark the change
  `verified`;those require the separate governance flow and maintainer review.
