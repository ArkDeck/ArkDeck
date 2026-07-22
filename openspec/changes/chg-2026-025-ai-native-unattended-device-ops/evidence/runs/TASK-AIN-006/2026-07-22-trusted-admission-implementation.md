# TASK-AIN-006 trusted admission implementation run — 2026-07-22

- Task: `TASK-AIN-006 — authorization provenance + trusted facts`
- Branch: `agent/ain-006-trusted-admission`
- Approved base: readiness PR #306 merged as
  `e44eafb38bcab66a2e4e208078f84a515d3ae78f`
- Environment: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Swift 6.3.3
- Classification: host/fake-only authorization contract validation; network, real device, HDC,
  rkdeveloptool, product process launch and destructive dispatch were all zero

## Work performed

1. Replaced the caller-trusted authorization/context boundary with a strict closed JSON parser and
   a protected-main provenance resolver. The resolver fixes repository, branch and registry;
   verifies current/reviewed/merged blob identity, merge ancestry, exact-head CODEOWNER approval,
   actor separation and the pinned CODEOWNERS blob; and mints an internal non-Codable typed grant.
   JSON `approvedBy` and `carrier` remain display cross-checks only.
2. Added trusted fact ports and a collector for product-validated execute plan, durable binding,
   descriptor-bound tool identity plus Loader observation, product prerequisite receipts and a
   separate actual serial/VID/PID/topology readback. All facts must correlate to one
   session/job/target; readback sequence and a maximum 30-second monotonic deadline are enforced.
   The #301 discovery seam alone cannot supply serial or mint final admission.
3. Added ordered grant → facts → durable usage admission. The real AIN-005 host-wide ledger is
   reserved only after every fact passes; reservation IDs bind authorizationRef/job/plan/target,
   exact retries are idempotent, `maxRuns=1` has one atomic winner and durable reservations are not
   refunded after failure/crash. The returned capability is internal, non-Codable, reference-typed
   and one-shot. Consume rechecks both authorization expiry and readback deadline.
4. Removed the raw authorization/context autonomous gate and its command-surface/intent success
   result. The public human gate remains, while standardAgent/ordinaryCI stay `policyBlocked`.
   The internal AI gate accepts only the verifier-minted admission and returns audit identity, not
   command strings, a workflow intent or dispatch authority.
5. Changed the CLI AI surface to strict `--authorization-id`. Because TASK-AIN-007 does not yet
   provide the production composition/executor, that branch returns `executorUnavailable` before
   archive reading, resolver/fact access, usage reservation or handoff output. Unknown, duplicate
   and retired options are rejected.

## Verification commands and results

### Focused authorization contracts

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'StandingAuthorizationContractTests|AuthorizationProvenanceContractTests|AuthorizationAdmissionContractTests'
RESULT: 12 tests executed, 0 failures
```

Canonical summaries emitted:

```text
TEST-AIN-AUTH-PROV-001 PASS source=protected-main blob=head=merge review=exact-head codeowner=pinned actor-separation=valid
TEST-AIN-FACT-001 PASS facts=trusted correlation=same-admission serial=readback capability=one-shot dispatch=0
TEST-AIN-USAGE-001 PASS maxRuns=1 atomic-winner=1 retry=idempotent crash-after-replace=consumed no-refund=true
TEST-AC-FLASH-015-01 PASS agent=policyBlocked ci=policyBlocked planOnly=allowed dispatch=0
```

Negative coverage includes invalid/path-like IDs; duplicate/unknown/missing/noncanonical JSON;
wrong repository/branch/protection/path/blob/base/author/merge/ancestry/review/CODEOWNER; unavailable
fresh source; self-asserted carrier metadata; wrong binding correlation/target/revision/serial/topology;
public receipt hash, tool profile/mode/topology/sequence and plan drift; unknown prerequisites; wrong
actual serial/VID/PID/topology/sequence; stale/expired/overlong readback; concurrent usage, exact retry
and post-replace crash recovery. Every failing fact case left the real usage ledger empty.

### Full Swift regression

```text
CI=true swift test --package-path Packages/ArkDeckKit
RESULT: 348 tests executed, 1 skipped manual sleep/wake observation, 0 failures
```

This is the readiness baseline of 336 tests plus 12 TASK-AIN-006 tests. The existing suite contains
controlled local process fixtures; TASK-AIN-006 tests themselves use only deterministic Git/GitHub
metadata fixtures, fake fact ports and temporary host filesystem ledgers.

### SDD and source hygiene

```text
ARKDECK_PYTHON=/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python scripts/check-sdd.sh
RESULT: check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

xcrun swift-format format --in-place <nine allowed Swift source/test paths>
xcrun swift-format lint --strict <nine allowed Swift source/test paths>
git diff --check
RESULT: PASS
```

Pinned input blobs were rechecked against the readiness values before implementation. Source/API
search found zero retired raw-context/gate identifiers, zero autonomous command result, and no new
stepIntent, child-process or device-dispatch path.

## Acceptance conclusion

- `AIN-AUTH-PROV-001`: **PASS** for the TASK-AIN-006 protected-main fixture scope.
- `AIN-FACT-001`: **PASS** for same-admission trusted fact correlation and fail-closed negatives.
- `AIN-USAGE-001`: **PASS** for atomic `maxRuns=1`, retry and no-refund behavior using the real
  AIN-005 ledger.
- `AC-FLASH-015-01/02` regression surface: **PASS**; public Agent/CI dispatch remains zero.
- Network/HDC/rkdeveloptool/real-device/product-process/destructive dispatch attributable to this
  run: **0**.

## Deviations and residual risk

- No task scope or acceptance deviation. Authorization carrier, current specs/contracts, Package
  manifest and unrelated sources were not modified.
- No production GitHub/network adapter, product composition root, actual serial readback adapter or
  executor is introduced by this task. Therefore CLI autonomous execute intentionally remains
  `executorUnavailable`; production authorization and realHardware capability are not claimed.
- Fixture merge/review metadata and fake device readback prove contract behavior only. They are not
  production approval, device evidence or authorization to run a destructive operation.
- TASK-AIN-006 task completion and change verification status remain unchanged; those transitions
  require later, separate maintainer-reviewed PRs.
