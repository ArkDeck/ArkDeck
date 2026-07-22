# TASK-AIN-007 Rockchip executor implementation run — 2026-07-22

- Task: `TASK-AIN-007 — product-owned Rockchip typed executor`
- Branch: `agent/ain-007-rockchip-executor`
- Approved base: readiness PR #314 merged as
  `80bad5b75ab48905fe9a3ca8392a284acb91ac3b`
- Environment: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Swift 6.3.3
- Classification: repository-built fake descriptor execution plus host filesystem contracts only;
  real device, HDC, real rkdeveloptool, network dispatch and host shell dispatch were all zero

## Work performed

1. Replaced the CLI autonomous `executorUnavailable` branch with a high-level request containing
   only the strict authorization ID, archive URL and target location selector. The human handoff
   remains separate, and autonomous callers cannot inject an executable, argv, facts, storage root,
   journal, Manifest or command line.
2. Added a product-owned composition root for fresh protected-main provenance, the durable usage
   ledger and binding snapshot, product Keychain/bookmark configuration, USB fact/readback probes,
   owned Session storage, idle-sleep activity, sleep/wake notifications and descriptor-bound
   `FoundationProcessExecutor`. Dependency injection remains package-internal for contract tests.
3. Added closed typed lowering for exactly `ld`, `ppt`, nine ordered `wlx` writes and `rd`. Every
   process launch rechecks the product executable descriptor receipt against admission; no `wl`,
   shell, sudo, caller command or fallback surface is available.
4. Added in-process streaming gzip/tar staging for the exact nine Profile members. Traversal,
   duplicate, link/special, undeclared/member-set, size/hash and archive drift fail before spawn.
   Staged files are owner-only, fsynced, made read-only, retained by no-follow descriptors and passed
   to the child only through stable descriptor paths with inode/size/hash revalidation.
5. Added bounded semantic evaluation for Loader identity, the exact 15-row partition table, every
   write marker and reset marker. Exit zero alone is insufficient; stderr, nonzero exit, invalid
   UTF-8, oversized output and missing/malformed markers fail closed.
6. Added journal-backed 2.1 job/intent/outcome/authorization correlation, raw stdout/stderr Artifact
   publication, postflight identity validation and write-once terminal Manifest publication. Fake
   execution is persisted as `contractFake` and cannot assert hardware support or realHardware
   evidence.
7. Added safe-boundary execution for all nine critical write windows. Cancellation never reaches
   the active fake child, blocks every later Step and releases the power activity. Product sleep/
   wake notifications are durably paired in the journal and force recovery before another Step.

## Verification commands and results

### Focused executor and fault contracts

```text
swift test --package-path Packages/ArkDeckKit \
  --filter 'RockchipFlashExecution(Contract|FaultContract)Tests'
RESULT: 12 tests executed, 0 failures
```

The focused total is three positive/surface contracts plus nine fault-contract methods. The
critical cancellation method iterates all nine partition positions. Coverage includes exact argv,
2.1 journal/Manifest correlation, raw Artifacts, fake classification, public request injection,
missing staged images, admission rejection, semantic failure classes, archive traversal/duplicate/
link and staged-path replacement, executable replacement before spawn, intent durability failure,
ENOSPC, unknown write outcome, postflight mismatch, sleep/wake and power release.

Canonical summary emitted by the real fake-descriptor end-to-end run:

```text
TEST-AIN-DISPATCH-001 PASS argv=1ld+1ppt+9wlx+1rd schema=2.1.0 evidence=contractFake realDevice=0 hdc=0 network=0 shell=0
```

Only `ArkDeckFakeRockchipFixture`, built from this repository, was launched by TASK-AIN-007 tests.
The successful run produced twelve exact argv arrays and no handoff/shell command dispatch.

### Full regression

```text
CI=true swift test --package-path Packages/ArkDeckKit
RESULT: 358 tests executed, 1 skipped manual sleep/wake observation, 0 failures
```

The readiness baseline was 346 tests. TASK-AIN-007 adds twelve discovered tests, producing the
expected total of 358. Existing regressions cover Provider/profile, authorization provenance and
usage, process identity binding, Runtime power/sleep-wake contracts, Storage/Artifact publication,
journal recovery and Manifest 2.1 validation. The existing suite contains controlled local process
fixtures; no TASK-AIN-007 test contacted a device or network service.

### SDD, formatting and source hygiene

```text
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/private/tmp/arkdeck-sdd-python sh scripts/check-sdd.sh
RESULT: check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

xcrun swift-format lint --strict <all nine allowed Swift/package paths>
git diff --check
RESULT: PASS
```

The final status/scope audit contains only the two allowed modified files, four allowed new
Workflows files, two allowed new contract-test files, the allowed fake fixture and this run record.
Searches found no `/bin/sh`, `Process()`, `system`, `popen`, sudo or HDC dispatch surface. Production
configuration mentions rkdeveloptool only as the pinned bookmark identity; tests never launched it.

## Acceptance conclusion

- `AIN-DISPATCH-001`: **PASS** for the repository-built fake descriptor scope.
- `AC-FLASH-008-01` contract surface: **PASS** across all nine critical write positions; the active
  child was never force-killed and later dispatch remained zero.
- `AC-FLASH-012-01`: **PASS**; exit zero without the exact typed semantic result cannot succeed.
- `AC-FLASH-013-01`: **PASS**; unknown write outcome, sleep/wake and postflight mismatch stop later
  dispatch and reopen as `waitingForRecovery/outcomeUnknown`.
- `AC-FLASH-015-03` contract half: **PASS** with authorized-agent 2.1 correlation and honest
  `contractFake` evidence. Its real-hardware half remains assigned to TASK-AIN-004.
- Real device/HDC/real rkdeveloptool/network/host-shell dispatch attributable to this run: **0**.

## Deviations and residual risk

- No task-scope or acceptance deviation. The approved Package path was used only to register the
  fake executable and its test dependency. The anticipated Runtime target dependency was not
  needed: the executable receipt/executor already belong to `ArkDeckProcess`, while product power
  and lifecycle adapters remain inside the allowed Workflows composition without widening the
  repository's locked module-import boundary.
- This run is not hardware validation, a standing authorization, a support declaration or proof
  that the production tool/bookmark/device configuration is installed. Production execution still
  fails closed without the Keychain GitHub token, security-scoped pinned tool bookmark, durable
  binding snapshot, storage admission and exact USB identity.
- GitHub and USB production adapters were compiled and contract-wired but not invoked by this
  fake-only verification. TASK-AIN-004 must obtain a new readiness pin and valid merged standing
  authorization before any real destructive dispatch or v3 realHardware evidence is possible.
- TASK-AIN-007 remains `ready`; this implementation PR does not mark the task done and does not
  change the change-level verified state. Those transitions require later independent PRs.
