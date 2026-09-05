# TASK-SVC-002 execution record

Status: local implementation and required unified verification complete.
TASK-SVC-002 is marked done in this delivery for maintainer review. No
protected-main approval, change verification or hardware acceptance is claimed.

Base: `600e4b72a016b38e3289103484208668e6690984` (SVC-001 merged).
Branch: `agent/task-svc-002-single-v1-durable`. The initial working tree was
clean. The implementation was committed and rebased without conflicts onto
`e8c4f1dfdab34ad78bf38a9611e056964a106c8d` for PR delivery on 2026-09-05.
`git range-diff` confirmed the implementation patch was unchanged by rebase.

## Delivered behavior

- Journal, Manifest, JobState and capability storage use the complete current
  v1. Historical version tables, operation-selected Journal writers,
  authority/campaign readers and pre-authorization fingerprint reconstruction
  are removed. Current recovery states, optional host/observation fields,
  Artifact correlations and unknown-outcome refusal remain.
- SQLite creates only the final v1 table/index layout. Existing stores must
  match the columns, constraints, indexes, logical order and row counters.
  WAL/FULL, busy waits, atomic admission, increasing row versions and admission
  sequences remain. There is no migration, creation sentinel or legacy pager.
- Durable Job and capability readers reject unsupported nested fields,
  incomplete correlations and lineage/scope/use-budget drift. Current
  reservation/consumption/outcome, ledger checkpoints, idempotency and crash
  tests remain. Missing checkpoints beside a ledger cannot create empty state.
- The production daemon validates mutation-state continuity before admission
  and capability consumption. A state-root override, retired authority state,
  unsupported/unresolved configured or default Session history, dangling state
  links, and missing capability state beside mutation history all fail closed.
  Retained SQLite Job history is checked even when its Job directory is missing.
  Rejection preserves the original bytes and cannot release a target lane.
- Removed four archive spellings (`flash status`, `flash reconcile`,
  `legacy flash status`, `legacy flash reconcile`), their historical
  archive/reconciler/authority-ledger models and compatibility-only fixtures.
  Caller inventory confirmed the session-run lock had no current producer
  outside that retired reconciler. Current `RuntimeCapabilityStore` budget and
  fault coverage remains. `flash install-binding` and Runtime Job/Session,
  Flash and complete-overwrite recovery paths remain available.
- CLI contracts/fixtures were regenerated with the existing exporter. The
  current Journal and Manifest schemas, writers and validators are aligned.
  Storage documentation describes rejection, preservation and configuration.

## Scope and compatibility

The user accepted the concrete [scope supplement](scope-review.md) on
2026-09-05 for CLI main, command registry, daemon main and the two generated
CLI contracts. The review patch accidentally included the live binding
function between retired helpers; compilation caught the caller, and that
function was restored unchanged before the successful CLI build. No Task
allowlist, checker, Catalog, safety acceptance or historical change was altered.

Compatibility note: the approved single-format CHG-075 scoped delta supersedes
the old development-format decode promises. Current conservative
`outcomeUnknown` refusal and state-based failure projections do not select or
decode a historical format. SVC-003 evidence/descriptor labels and SVC-004
preferences/configuration remain outside this delivery.

## Final verification

On 2026-09-05, from the repository root:

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

PASS, exit 0. Final log: `/tmp/svc002-complete-gate.log`.

- Public policy, generator, schema and wrapper checks: PASS.
- Swift full parallel lane: PASS, 2,416 scheduled cases, exit 0.
- Required serialized process-identity and Viewer lanes: PASS, 1 + 5 cases.
- Design-system tests: PASS, 83 cases, zero failures.
- App build-for-testing: PASS, `TEST BUILD SUCCEEDED`.
- Control contract generator `--check` and `git diff --check`: PASS.
- CLI exporter: PASS; the full suite verifies zero generated-contract drift
  and explicit `invalidCommand` results for the removed archive commands.

The full lane uses its standard configuration; optional long stress suites were
not enabled. UI assertions were not run because the change targets durable
storage and CLI behavior, not App presentation. Hardware is not required for
this Task, and no device operation or UI action was executed. All fault and
recovery results here are host fixture results, not real-device evidence.

## Acceptance results

| Acceptance | Result and evidence |
| --- | --- |
| SVC-AC-04 | PASS for durable consumers: strict Job decoding rejects retired authority, absent original authorized requests and correlation drift; current read-only and capability paths pass. |
| SVC-AC-05 | PASS: current Journal/Manifest/recovery round trips, exact SQLite layout and logical counters, capability budgets/lineage/checkpoints, Session export and retention pass in the full suite. |
| SVC-AC-06 | PASS: old-version and same-version shape collisions, missing indexes/checkpoints, dangling paths, SQLite-only mutation history, torn-tail/crash/fault cases and raw-byte preservation pass; unknown intent is not replayed, invalid recovery proofs dispatch zero new destructive actions, valid independent recovery retains supersession behavior. |

Retired schema fixtures remain byte-identical to the base contracts (comparison
and SHA-256 checked), allowing the frozen historical corpus to retain its pins:

- Journal: `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19`.
- Manifest: `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489`.

No existing raw Artifact, hardware evidence or production authority state was
modified or relabeled.

## Development failures resolved

Earlier full/focused runs were not green: history fixtures initialized the
index after writing Jobs, HDC Manifest fixtures/producers still used the old
actor shape, and retired reader tests awaited scope consent. Those fixtures
and the current producer were corrected, the temporary startup diagnostic was
reverted, and the approved obsolete-reader removal was completed. The first
post-consent focused run scheduled 165 tests and found one error-type mismatch
in the new symlink guard; the implementation now preserves the established
`RuntimeCapabilityStoreError.ioFailure` contract without weakening its test.

The first post-consent unified gate passed 2,415 parallel Swift cases plus six
serialized cases and the App build (`/tmp/svc002-approved-gate.log`). Subsequent
review added the SQLite-only history regression, then reran the complete gate
successfully as recorded above. Earlier red runs remain earlier red runs;
focused rechecks were not substituted for the final complete result.

## Rebase and PR delivery

The post-rebase unified gate passed, exit 0, with 2,430 scheduled parallel
Swift cases, six serialized cases, all 83 design-system cases, public checks
and App `TEST BUILD SUCCEEDED`. Log: `/tmp/svc002-rebased-gate.log`.
Before push, the required path preflight refused exactly the five previously
user-reviewed scope additions because it reads the Task allowlist from main.
The [scope supplement PR #1738](https://github.com/ArkDeck/ArkDeck/pull/1738)
records only those accepted paths for maintainer review. It was created by
`github-actions[bot]`, is ready for review, and its checks passed. The implementation initially remained local because the path checker requires
the allowlist in the base tree.

PR #1738 merged as `ac8681dd72f0bcc48a8f6b1778aefcbc39a0e3e8` on 2026-09-05.
The implementation was rebased onto that commit without conflict; `git range-diff`
confirmed the patch was identical. The only tree difference from the verified
implementation was the merged Task scope document. The existing full-gate
results therefore cover the unchanged production/test/schema files; final
scope/document checks and the base-tree path preflight passed before push.
