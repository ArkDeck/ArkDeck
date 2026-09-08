# SVC acceptance follow-up — 2026-09-08

This record accompanies the production fixes under `TASK-AIN-021`. It does not mark
`TASK-SVC-005` done or certify a final hardware-verified Swift baseline. The current
development baseline below can be consumed independently by CHG-2026-074.

## Published development baseline

`origin/main` was fetched and GitHub reported the branch protected before this run.
The checkout was clean at `a076ca31ef97ef4285981af053d07b7fe0f052bd`.
The signed helper used for the production reads was built from that clean tree, before
the candidate source changes. Only this published helper was installed.

| Identity | Value |
| --- | --- |
| Swift commit | `a076ca31ef97ef4285981af053d07b7fe0f052bd` |
| Control version | `1.0.0` |
| Contract identity | `1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d` |
| Control JSON blob | `f47372feb9034ba17560b59d5dbde91206cb9aae` |
| Generated Swift blob | `6d3c1fb680d6a338ba59cb80af53aa46505196cb` |
| Method schemas, 96 files | `5a127a679b587a61cd8f515e3f73137e050607db1a863d40a0e6e17cfa646a42` |
| Frame corpus, 96 files | `4ad7766288b8b679c821acb9c5ef2bd4f675834929a6eb1a9e542a26b116e849` |
| Runtime Catalog digest | `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` |
| Catalog tree, 35 files | `b84ffac89462797d0d5bb4ac2d39d30803d71365af187e0898893135c58d721b` |
| Published helper executable SHA-256 | `fa5a3f321f3a23fa7516c0ae7775eabc2b97073e142a21b9b1098907bcf258c7` |
| Published CLI build identity | `sha256:00011a6658500d7562757428a79a296c9a3d032fc8ce7cce56fa5758c35ffa92` |

The schema, corpus and Catalog **tree** digests hash sorted Git object IDs and
repository-relative paths, with one trailing newline per row:

```sh
git ls-tree -r a076ca31ef97ef4285981af053d07b7fe0f052bd \
  --format='%(objectname) %(path)' -- spec/control/methods | LC_ALL=C sort | shasum -a 256
```

Use the same command with `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames`
and `Catalog` respectively. The Runtime Catalog digest has its existing runtime
definition and is distinct from the Git tree digest.

The old `eac476cd` XPA pin and `371cd9d2` SVC handoff predate #1760–#1764. Those
changes already carry unknown step kinds as `null` through `job.show`, `job.evidence`
and Agent methods, with matching schemas and corpus. The control registry blobs
and contract identity remained unchanged; the schema/corpus directory digests did
change. Copying only the old baseline's commit line is no longer sufficient.

## Defects corrected by this candidate

- Flash facts previously ignored a stored post-flash alias that could not cover the
  active target. A newer alias revision, foreign target or same-revision Loader
  identity conflict could therefore survive admission and fail only after partition
  writes. These conflicts now refuse facts before capability admission and dispatch.
  An older alias for the same target remains supersedable through the existing publisher.
- Delegated Flash reconciliation previously fell back to model/build readback when
  the exact ArkForge completion receipt was absent or invalid. That read cannot prove
  all destructive effects. The fallback now records the missing proof and retains
  `waitingForRecovery` / `outcomeUnknown`; canonical correlated completion and existing
  independently proven complete-overwrite recovery remain available.
- CLI `job evidence` / `job result` had closed reason allowlists even though their
  published schemas use open strings. The daemon's current `stepKindsUnprovable`
  result was rejected as `recordUnreadable`. The client now retains those reasons,
  preserves nonzero failure/wait exits and still rejects false `verified` results.
- History now renders unreported typed steps explicitly in both languages instead
  of leaving the section empty. `actualStepKinds: null` never means zero execution.

Compatibility note: these changes enforce the existing `POL-RECOVERY-001` and
`POL-AGENT-002` requirements; they introduce no new operation, authority surface,
schema, capability administration or destructive admission policy.

## Production observations and preserved state

Raw command outputs are local under `/private/tmp/arkdeck-svc-a-20260908/`.
They are not rewritten into hardware evidence. `service-status-current.json` reports
the published helper above, healthy control transport and the current Catalog.
`doctor.json` exits 0 with readiness true but degraded operation availability (23 of
30 entries, including the Flash alias); this does not establish device health.

`device-candidates.json` exits 70 with `observationFailed`, and
`flash-bootloader-status.json` reports no Loader. No new Flash run or reconcile was
submitted. `current-observe-job-show.json` identifies the precise observation failure:
`target line is not the registered 5-column family`. Host-tool and HDC-server probes
had succeeded. This is not sufficient evidence that the device is simply unplugged;
normal-mode connectivity and the observed HDC output need to be resolved through the
published product path.

Flash also reports its qualification state in `operation-list.json`:
`ArkForge is connected for assessment only (hardwareGated)`. Current
`ArkForgeAuthoritySupport.seal` returns `hardwareGated` for an empty campaign and
`hardwareCampaign` for a named campaign; there is no production support-record reader
or producer of `productionVerified` in the Swift production source. The composition
root therefore publishes Flash unavailable before target facts can be checked.
The same historical bundle was exercised using `gj4-headless-20260902`, then that
campaign was cleared; its old success did not grant production qualification.
A full-chain review distinguishes this label from dispatch authority: the published
named hardware-acceptance path still requires Runtime materialization, preauthorization,
capability reservation/consumption and a durable intent before ArkForge permit signing.
The current request decoder still rejects legacy campaign authority fields. Therefore
this authorized acceptance may use a fresh named qualification campaign while retaining
that classification; it cannot claim `productionVerified` or clear the existing
unknown/lineage blockers. A new production registry is not a prerequisite for that
staging acceptance and is not added by this repair.

`runtime service verify` without `--job` starts a read-only observe; it is not a
passive health query. The invocation in this run produced
`job-176e1924577288f076562d33b44c6e9f`, `runtimeVerified: false`,
`outcomeUnknown: true`, and typed steps `probeHostTool`, `probeHDCServer`, `probeDevice`.
It does not count as the required `agent run/resume` acceptance. The runbook now uses
`runtime service verify --job <observe-job-id>` to inspect the same Agent result.

The original Flash `job-c9274a31cb5ba7c8aad61451416af4f4` remains
`waitingForRecovery`, `outcomeUnknown: true`, `actualStepKinds: null` with
`materializedBindingRevision: 2`. Its correlated ArkForge job is
`JOB-000001A07B12F273-0002`; the record does not carry a complete-plan receipt.
The root post-flash alias belongs to an older successful job at revision 4, while
the current adopted target is revision 2. That older success cannot supersede this
later unknown job or repair the missing lineage. The old convenience command's
idempotency key `agent-execution-gj4-20260907c` is not a persisted Agent execution;
`agent status` correctly reports it missing.
The independent [watermark review PR #1765](https://github.com/ArkDeck/ArkDeck/pull/1765)
records the same retired/live target-store mismatch and additional archive/diagnostic
issues. This candidate adds the admission-time refusal and proof correction; it does
not duplicate that review or implement an unapproved lineage reconciliation route.

These source hashes were captured before the helper update and compared afterwards:

| Original state | Bytes | SHA-256 |
| --- | ---: | --- |
| `job-c9274a31cb5ba7c8aad61451416af4f4/journal.jsonl` | 4721 | `85e7ec6adcd70d740e48acaf7d73d9102f04ed19a555765373012f0853e35f05` |
| `job-bf0b748ef707e7e2ca80d8063959e6d1/journal.jsonl` | 4425 | `a6932fee2418f3ae6c1c9a668a13a8d15436fcafb4ae9e85e2aba58fc91fadd4` |
| Active `targets/targets.json` | 374 | `9e5a3da9041fca42d8aa74b5e2af19cee139f91a06ab12c33f4df53cc3694bf4` |
| `rockchip-binding.json` | 743 | `a47f811f9b82294f814a74505533a507cbc3deb6b8cfad36315741e5dcf76a3c` |
| `rockchip-post-flash-hdc-binding.json` | 578 | `0deec6da6442afb1738d30a48c8379b03bc10f06c682f01ba8909b1c215a521f` |

No target/ledger restoration, state-directory replacement, raw artifact editing or
manual recovery proof was performed. Reconnecting the device alone cannot resolve
the missing complete-plan proof or the revision conflict.

## Acceptance results

The [SVC acceptance matrix](../../../../openspec/changes/chg-2026-075-single-v1-contracts/verification.md)
remains the acceptance authority. The original implementation records are under
[`evidence/runs`](../../../../openspec/changes/chg-2026-075-single-v1-contracts/evidence/runs/).
They document host tests and App builds; they do not certify the missing current
hardware or App assertions. Unchanged behavior can retain those host references.

| AC | Existing implementation evidence and this candidate's coverage | Current result / remaining work |
| --- | --- | --- |
| 01 — one control contract | SVC-001 `run.md`; `ControlProtocolContractTests`, `ControlProtocolVersionContractTests`, `AgentXPCTransportContractTests`; current Agent identity refusal | Current full gate and post-recording frame validation passed |
| 02 — capability parity | SVC `methods.md` maps 118 former methods to 96 published methods and callers; Job read resources and Agent execution regressions | Current Job/Agent host checks pass; affected production App and GJ results still required |
| 03 — CLI semantics | SVC-001 `run.md`; CLI process, failure mapping, deadline and exit-status suites; current real CLI subprocess → socket → daemon fixture tests | Open reason strings preserve exits 75/2/0; candidate CLI reads the real daemon's null steps and blockers with exit 75; merge/publication remains pending |
| 04 — strict current requests | SVC-001/002 `run.md`; `RuntimeOperationContractTests.testCodecDirectDecoderAndDurableJobUseTheSameCurrentContract`; old-authority/unknown-field vectors | Unchanged three-entry decoder coverage retained; no new hardware dependency for this requirement |
| 05 — current durable formats | SVC-002 `run.md`; `CurrentDurableStorageContractTests`, `JournalRecoveryContractTests`, `RuntimeCapabilityStoreContractTests`; current owner/page/restart regressions | Full current host gate passed; no production state reset |
| 06 — old state and recovery | SVC-002 `run.md`; 17 current complete-overwrite tests; original production hashes above | Missing/invalid receipt keeps uncertainty and zero fallback dispatch, including restart; real Flash unknown remains unresolved |
| 07 — evidence integrity | SVC-003 `run.md`; `HardwareEvidenceProjectionContractTests`; SVC-002 `agent-methods-unknown-steps-20260908.md`; current CLI null-step and false-verified vectors | Full host and complete frame checks pass; current observe is unknown and cannot count as real success |
| 08 — internal formats | SVC-003 `run.md`; Debug invocation/candidate/manual Flash/provider format tests; 39 current Rockchip composition tests | Current descriptor and alias refusal checks pass; unchanged permit formats retain host evidence; real Flash postflight remains unverified |
| 09 — current configuration | SVC-004 `run.md`; Settings facade/storage, service and signing suites | Existing generation/readback/material-preservation tests retained; production Settings UI and folder-picker cancellation assertions pending; interactive signing-password cancellation remains untested |
| 10 — complete delivery | This record and the updated runbook; required unified gate and App wrapper | Not complete: published fixes, current GJ-1–5, import/session export and affected App results remain required |

Current focused validation: 102 tests passed (17 complete-overwrite recovery, 24 Job
read resources, 39 Rockchip composition, 22 Agent execution). The benchmark suite
passed 122 tests; the initial sandbox-only process-inspection permission failure
was rerun with the required host access. `generate-control-contract.py --check`
and `git diff --check` passed. Generator consistency is not frame-output validation.
After the focus/full recording tests and candidate CLI reads completed, the separate
`ControlMethodSchemaContractTests/testFramesRecordedByThisRunValidate` invocation
passed with exit 0 (`frame-validation-after-recording.log`). This is the complete
post-recording check; the validator's earlier execution inside the parallel suite
is not used as coverage proof. Frames remain local in `control-frames/`.

The signed candidate CLI queried the existing published daemon without installing the
candidate Runtime. `candidate-unknown-evidence.json` returns `ok: true`, null step kinds,
and blockers `artifactIntegrityFailed`, `resultNotReady`, `stepKindsUnprovable`, exiting 75.
`candidate-unknown-result.json` returns the proper `resultNotReady` error and exits 75.
All five original state hashes above remained equal after these reads.

The prescribed unified command completed with exit 0 (`unified-gate.log`): common
checks, 83 design-system tests, the full Swift lane (2,458 parallel selections,
1 serialized process-identity test and 5 Viewer scale tests), and App
build-for-testing. Optional hardware/long-run gates retain their own skip conditions;
this is host validation, not device acceptance.

Both UI invocations built successfully but failed before assertions with
`Timed out while enabling automation mode`. The wrapper's one allowed bootstrap
retry is exhausted; no App assertion is counted as passed. The production unknown
History and storage-settings tests, plus the fixture History/recovery regression,
remain unexecuted until the host can enable test automation. Result bundles:

- `/private/tmp/arkdeck-svc-a-20260908/ui-derived/Logs/Test/Test-ArkDeck-2026.09.08_07-37-24-+0800.xcresult`
- `/private/tmp/arkdeck-svc-a-20260908/ui-derived/Logs/Test/Test-ArkDeck-2026.09.08_07-43-01-+0800.xcresult`

A subsequent attempt to open this exact built App for presentation inspection was
rejected by automatic approval review because it requires confirmation for this
local build. That App was not launched through the rejected action; the specific
user confirmation is pending. This does not affect the completed host gate.

## Remaining acceptance conditions

- Review and merge the product fixes, then publish the merged helper before any
  affected device acceptance. The candidate Runtime has not been installed.
- GJ-4 requires an exact, valid Runtime completion proof or the complete mechanical
  basis for an independent recovery under current policy. Missing proof remains a
  blocker even when normal-mode HDC becomes available; no unknown intent is replayed.
- The GJ-3 attempt used `libexample.so`, absent from its paired HAP (which contains
  `libarkdeck_gj.so`). It failed at backup before atomic publication or restart, then
  cleaned staging. A correctly paired HAP/library is needed for deployment and rollback
  acceptance; an ABI mismatch refusal alone does not demonstrate rollback.
- GJ-2 reached successful install/package-readback/start/process-readback, then its
  bounded HiLog capture timed out. Reconciliation confirmed that diagnostic step
  did not complete, but the current engine then finalized the Job without the
  required stop/uninstall/staging compensation or cleanup debt. This is a separate
  required failure-path repair. It cannot be fixed by replaying the old request or
  manually creating debt; compensation uncertainty and restart must be handled too.
- GJ-1–GJ-5 need the still-missing current published `agent run/resume` results and
  affected App checks before SVC can publish its final hardware-verified baseline.
