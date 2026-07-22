# TASK-AIN-005 contract implementation run — 2026-07-22

- Task: `TASK-AIN-005 — authorized-agent locked contract closure`
- Branch: `agent/ain-005-contract-implementation`
- Approved base: readiness PR #300 merged as
  `0da9df4e69c958938c6e0a2b72bbdd44d08ae996`
- Environment: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Swift 6.3.3
- Classification: host-only contract/storage validation; real device, real HDC, network and
  product external-process dispatch were all zero

## Work performed

1. Added change-local Manifest v2, journal-event v2, authorization-usage v1 schema drafts and
   provider-contract v2 delta. Current `openspec/contracts/**` v1 files were not modified.
2. Added the closed `AuthorizationReference` shape and durable host-wide authorization usage
   ledger. Reserve uses an owner-safe stable lock, same-directory temporary file, full file sync,
   atomic replace, path/inode revalidation and directory sync. Retry, ordinal/maxRuns, terminal,
   crash-window, symlink/hardlink and replacement behavior fail closed.
3. Added journal v2 encode/decode plus append/replay correlation. A v2 authorized-agent
   `jobCreated`, destructive `stepIntent` and matching `stepOutcome` must carry one exact
   authorization/reservation pair; mixed versions and missing/drifted/borrowed correlation fail.
   Historical v1 replay behavior remains unchanged.
4. Added Manifest v2 authorization and closed actor objects, one-to-one destructive intent IDs,
   journal/Manifest correlation, and redacted-export preservation for non-device provenance IDs and
   OIDs. Existing v1 behavior remains intact; v2 standardAgent, plan-only and simulated
   destructive-success records fail closed.

## Verification commands and results

### Schema and SDD

```text
python3 -m json.tool <each of the three change-local JSON schemas>
RESULT: PASS

/opt/homebrew/anaconda3/bin/python Draft202012Validator.check_schema(<each draft>)
RESULT: 3 schemas PASS

ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python ./scripts/check-sdd.sh
RESULT: check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs
```

The first default `bash scripts/check-sdd.sh` attempt could not import PyYAML from the PATH Python.
No repository dependency was changed; the check was rerun with the existing host Python that has
PyYAML 6.0 and passed.

### AIN-focused and storage regressions

```text
swift test --package-path Packages/ArkDeckKit --filter AuthorizationUsageLedgerContractTests
RESULT: 4 tests, 0 failures

swift test --package-path Packages/ArkDeckKit --filter JournalRecoveryContractTests
RESULT: 31 tests, 0 failures

swift test --package-path Packages/ArkDeckKit --filter SessionArtifactStorageContractTests
RESULT: 59 tests, 0 failures
```

Focused total: **94 tests, 0 failures**. Canonical summaries emitted:

```text
TEST-AIN-CONTRACT-001 usage-idempotency-limit=PASS device_dispatch=0
TEST-AIN-CONTRACT-001 journal-v2=PASS device_dispatch=0 external_process=0
TEST-AIN-CONTRACT-001 manifest-v2=PASS device_dispatch=0 external_process=0
```

Coverage includes v2 positive round-trip and terminal publication, v1 regression reading,
standardAgent and simulated destructive-success rejection, missing/drifted refs, actor drift, ghost
intent refs, mixed-version journal, outcome correlation drift, usage
concurrency/idempotency/limit, four reserve crash windows, and lock/ledger
symlink-hardlink-path substitution. Redacted export retained the authorization/reservation/OID and
intent-event correlation and removed the fixture target identifier.

### Full Swift regression

```text
swift test --package-path Packages/ArkDeckKit
RESULT: 330 tests executed, 1 skipped manual sleep/wake observation, 0 failures
```

The existing full suite includes its own controlled local process fixtures. The new
AIN-CONTRACT-001 tests invoke no product process executor and perform no device/HDC/network
operation.

### Source hygiene

```text
xcrun swift-format format --in-place <nine allowed Swift source/test paths>
git diff --check
RESULT: PASS
```

## Acceptance conclusion

- `AIN-CONTRACT-001`: **PASS** for the TASK-AIN-005 persistence/semantic scope.
- `AC-FLASH-015-01/02/03` persistence surface: **PASS**; no dispatch authority is minted here.
- Simulation/fake/plan-only and v1/v2/real-authorized record classes remain distinguishable.
- Device/HDC/network/product external-process dispatch attributable to TASK-AIN-005: **0**.

## Deviations and residual risk

- No scope or acceptance deviation.
- This task intentionally validates only stored shape, correlation, durability and usage ceilings.
  GitHub provenance/fact resolution and executor wiring remain unavailable until independently
  approved TASK-AIN-006 and TASK-AIN-007 changes land.
- The change-local schemas are drafts and do not replace current contract files. Promotion to
  `openspec/contracts/**` requires its separate archive/current-contract PR.
- Manual production sleep/wake observation remained skipped exactly as in the baseline and is
  unrelated to this host-only contract task.
