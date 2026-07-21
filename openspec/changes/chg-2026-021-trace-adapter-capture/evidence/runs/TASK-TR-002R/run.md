# TASK-TR-002R host-contract remediation run

- Date:2026-07-22(Asia/Shanghai)
- Base:`main` `f8d7f67ccd3855d7a04d3e261d9376e3cdd3d02e`
- Branch:`agent/chg-2026-021-tr-002r-impl`
- Environment:macOS arm64;Apple Swift 6.3.3;Xcode 26.6/17F113.
- Evidence class:`contract` + `SessionArtifactStore` fault injection.All device identities and
  Artifact bytes are explicitly synthetic;storage writes use isolated temporary directories.
- Task-specific dispatch classification:real device 0,HDC 0,network 0,external process 0,
  capture dispatch 0 on every rejected rebind/parameter branch,and remote-cleanup dispatch 0 on
  every publication fault.The full regression suite also exercises pre-existing local
  fake/process fixtures;it performs no real-device Trace work.

## Readiness and scope pins

The task began only after readiness PR #277 had maintainer approval and was merged to protected
`main` at the base above.Open-PR overlap was 0.The pre-edit blob audit matched every readiness pin:

| Input | Git blob |
| --- | --- |
| `TraceCatalogContracts.swift` | `95fe72b406c615f6d99b381a4c08c770d6279c00` |
| `TraceParameterContracts.swift` | `e1e2a8b692e71c78bf66195b645335b1ba122840` |
| `TraceWorkflowContracts.swift` | `f6cbec4bb9fe8f441d83c54931b8c378c106f06d` |
| `TraceWorkflowContractTests.swift` | `553cd7d436b83ea732adb072d258151734cdc745` |
| `ArtifactStorage.swift` | `635f4da53094305dc52dff6ebdb26e1ccb026ea1` |
| `SessionLayout.swift` | `ed48f90a96ee239769e86727ae9272017fea72f7` |
| `SessionStorageTypes.swift` | `04aa1c185defc6bdc5da0c041b20d5c538e167f2` |
| `HostStorage.swift` | `e052657f08c6ef98fa1019269541a1ad5deb7000` |
| `DeviceTargeting.swift` | `13a052ba2359e90bfe86fed4884b10fa1f4dd5cf` |
| `Package.swift` | `a47bccf05a0c044ef506ddd015fe8c0ecaaa89e2` |

The final diff is limited to the four pinned Trace Swift files above plus this run record.No
accepted spec,Core,ArkDeckStorage implementation,catalog,integration,App/UI,other task evidence,or
`tasks.md` status was changed.

## Scope implemented

- Expected-rebind context construction now consumes a durable pre-reboot binding and Core-validated
  selected candidate/confirmation.The capture gate requires the expected target,exact prior
  revision + 1,connect key,transport,identity,evidence and confirmation;the new binding reference
  is retained by capture authorization and every materialized confirmed-device step.
- Pre-publication receive plans use `artifacts/partial/<artifact>.part` and contain no
  `cleanupOwnedRemotePath`.A coordinator calls the real
  `SessionArtifactStore.publish(from:request:claim:)`;only its matching `PublishedArtifact` can
  construct a typed remote-cleanup authority and bound cleanup step.
- Parameter capability receipts bind the complete durable binding,parameter name,typed probe
  disposition and persistent-write support.Catalog membership alone,missing/non-supported/stale/
  wrong-name receipts,persistent support absence,or missing confirmation all fail before mutation
  plan materialization;authorized set steps retain their intended binding.
- Reliable progress totals have no public initializer.They can be minted only by a factory when
  the current adapter capability explicitly reports reliable totals and the total is positive;
  missing,false,invalid or drifted capability remains indeterminate with elapsed time.

No hitrace/bytrace argv,help parser,output marker,golden fixture,real adapter dispatch,CLI/UI,Core
schema,storage contract or support/conformance claim was added.

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit --build-tests` | PASS. |
| `swift test --package-path Packages/ArkDeckKit --filter TraceWorkflowContractTests` | PASS;18 tests,0 failures(baseline 14 + four remediation contracts). |
| `swift test --package-path Packages/ArkDeckKit --filter SessionArtifactStorageContractTests` | PASS;58 tests,0 failures. |
| `swift test --package-path Packages/ArkDeckKit` | PASS;320 tests executed,1 existing opt-in manual sleep/wake test skipped,0 failures/0 unexpected(baseline 316 + four remediation contracts). |
| `scripts/check-sdd.sh` | PASS;0 errors,0 warnings,111 acceptance IDs. |
| `xcrun swift-format lint <four changed Swift files>` | PASS;0 diagnostics. |
| `git diff --check` | PASS. |
| `git diff --name-only origin/main` + allowed/forbidden-path audit | PASS;only the four allowed Trace Swift files and this TASK-TR-002R run record;forbidden-path matches 0. |
| secret/privacy scan over changed files | PASS;private-key/token/password patterns and real user-home paths matched 0;the only device identity literal is `SYNTHETIC-SERIAL`. |

Publication fault injection covered 13 reachable barriers:
`artifactPublicationLock`,`artifactPartialDirectorySync`,`artifactWrite`,
`artifactSourceValidation`,`artifactFileSync`,`artifactValidation`,
`artifactRecoveryRecordWrite`,`artifactRecoveryRecordSync`,
`artifactRecoveryRecordReplace`,`artifactRecoveryRecordDirectorySync`,
`artifactReplace`,`artifactDirectorySync` and `artifactSourceDirectorySync`.Every thrown path
returned no publication receipt,created no cleanup authority,kept the owned remote state present and
reported cleanup dispatch 0.

## AC and evidence conclusions

| Acceptance/evidence ID | Result | Reproducible evidence line |
| --- | --- | --- |
| `AC-TRACE-003-01` | PASS | `TEST-AC-TRACE-003-01 PASS snapshot=missing temporary_restore=false persistent_confirmation=required silent_downgrade=false real_device=0`;matching persistent capability is separately required by the local parameter matrix. |
| `AC-TRACE-004-01` | PASS | `TEST-AC-TRACE-004-01 PASS set_exit=0 readback=mismatch audited=true capture_dispatch=0 real_device=0`;preflight capability failures are covered before this readback seam. |
| `AC-TRACE-005-01` | PASS | `TEST-AC-TRACE-005-01 PASS candidates=2 state=awaitingRebindConfirmation capture_dispatch=0 real_device=0` plus the exact-rebind local line below. |
| `AC-TRACE-006-01` | PASS | `TEST-AC-TRACE-006-01 PASS host_state=partial owned_remote=retained early_cleanup=false real_device=0` plus the real-store fault matrix below. |
| `AC-TRACE-008-01` | PASS | `TEST-AC-TRACE-008-01 PASS total=unknown meter=indeterminate elapsed_ms=12345 percentage=nil real_device=0` plus the capability-drift matrix below. |
| `TRACE-REBIND-GATE-001` | PASS | `TEST-TRACE-REBIND-GATE-001 PASS unobserved_candidate=blocked invalid_receipts=9 exact_revision=3 authorization_binding=retained device_step_bindings=retained capture_dispatch=0 real_device=0 hdc=0 network=0 process=0` |
| `TRACE-ATOMIC-PUBLISH-001` | PASS | `TEST-TRACE-ATOMIC-PUBLISH-001 PASS partial_path=artifacts/partial/*.part publication_faults=13 cleanup_authority=none cleanup_dispatch=0 owned_remote=retained real_device=0 hdc=0 network=0 process=0` |
| `TRACE-PARAM-CAPABILITY-001` | PASS | `TEST-TRACE-PARAM-CAPABILITY-001 PASS missing=blocked unsupported=blocked permissionDenied=blocked needsDeveloperMode=blocked unknown=blocked stale_binding=blocked wrong_parameter=blocked persistent_support_and_confirmation=required mutation_dispatch=0 real_device=0 hdc=0 network=0 process=0` |
| `TRACE-PROGRESS-CAPABILITY-001` | PASS | `TEST-TRACE-PROGRESS-CAPABILITY-001 PASS capability_false=indeterminate zero_total=indeterminate drift=indeterminate matching_receipt_percent=25 real_device=0 hdc=0 network=0 process=0` |

The unchanged `AC-TRACE-002-01` and `AC-TRACE-009-01` rows also remained green in the targeted and
full suites,but TASK-TR-002R makes no new claim over them.

## Deviations, failed attempts and residual risk

- No scope deviation.The first plain Swift build attempt was stopped before compilation because
  the filesystem sandbox denied the compiler's user cache.The identical build was rerun through
  the approved sandbox-external Swift prefix and passed;this was an environment failure.
- The first targeted test run had 16 passing tests and two assertion failures in one new test.The
  test had incorrectly included `artifactRecoveryRecordCleanup*`,which belong to terminal-manifest
  cleanup and are not reached by `SessionArtifactStore.publish`.Those two out-of-scope expectations
  were removed;production code was unchanged,and the corrected 13 reachable publication barriers
  plus the final 18/18 targeted and 320-test full suites passed.
- TASK-TR-001 real-device provenance and TASK-TR-003 parser-golden work remain separate.No real
  hardware,firmware or adapter compatibility has been established.
- This implementation/evidence PR intentionally leaves TASK-TR-002R `ready` and the change not
  `verified`.A separate maintainer-reviewed status PR is required after this implementation merges.
