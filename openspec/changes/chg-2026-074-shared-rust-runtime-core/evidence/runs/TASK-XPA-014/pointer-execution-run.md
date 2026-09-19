# Rust pointer execution and capability consumption

Status: implementation and complete unified local validation passed; CI and maintainer review pending.
Implementation base: protected main `187321ea` (Runtime capability admission).
The implementation checkpoint `d8b39c56` was integrated with protected main
`76612c9f` at `8301a443`, then `510b4650` at `d6cffa4a`, including resume,
ClientKit extraction and Artifact publication. Targeted results below precede the
latest integration; the complete unified gate below validates the integrated code. This is macOS host
fixture evidence, not installed Runtime activation or real-device acceptance.

The three pointer operations (`input.tap@1`, `input.long-press@1`, `input.swipe@1`)
now use the production Job runner, fresh materialized plan and target binding,
Runtime-owned reserved capability use, durable admission correlation, WAL,
Provider verification, and confirmed/unknown outcome settlement. Consumption and
its Job evidence precede mutation intent and dispatch. A consumed use whose Job
evidence cannot be persisted remains pending; the runner never retries an
uncertain consumption or an existing running/unknown Job. Cross-capability pending
use checks and consumption are serialized by the Runtime owner.

Admission and consumption require state continuity: the account-fixed Runtime
root, retained capability checkpoint/history, and readable configured/default
Session journals without unknown mutation intent or torn tails. A development
state-root override cannot issue or consume mutation authority and advertises
the pointer operations unavailable. The current installed Runtime has not switched
to Rust. Candidate runner implementation, isolated operation availability, and
real-device journey acceptance are separate facts. Missing account
home disables the mutation owner. Retired authorization state, root/symlink drift,
SQLite-only mutation history and nested Session journals fail closed. Root's
continuity implementation is part of this slice; it is read-only.

Session-carried model/firmware observations retain their original cache age and
are labeled `machineReadbackSessionCarried`; only a wholly fresh three-step
readback can renew that cache. Mixed carried/fresh observations cannot produce
fresh hardware evidence. Session publication validates the consumed capability
correlation with the durable Job, retaining existing refusal semantics for carried
observations. No public capability administration or recovery policy is added.

## Targeted validation

- Native `pointer-input` Swift fixture replay through production Rust owners:
  every response (apart from existing T2 refusal wording), exact fake Provider argv,
  SQLite index, capability ledger, Job/Session files, manifests, modes and digests
  match. Existing confirmed-failure and unknown-outcome cases remain distinct.
- Nine pointer tests passed, including missing owner, changed tool identity,
  consumption followed by an unwritable Job, independent capability concurrency, cancellation immediately before and after consumption,
  and real subprocess termination after consumption / after WAL intent. Reopened
  owners refuse replay and new gestures; retained ledger and dispatch log do not
  change. The subprocess dispatcher is a fake, never a real device transport.
- Four pointer admission tests passed, including selected-root override rejection
  before any capability checkpoint or ledger is issued.
- Seven continuity tests passed, covering nested journals and case aliases after
  final path revalidation; mixed-cache boundary and capability correlation
  corruption tests passed. Reservation, plan and target-binding mismatches refuse
  durable decode. The historical decoder checks step-set digest shape as Swift
  does; it does not claim independent reauthorization of historical data.
- Hoststore/agentd all-target integrated `cargo check` passed. Hoststore, agentd
  and HDC Provider all-target Clippy with `-D warnings` passed before integration.
  Initial broad owner unit run:
  163 passed, five native signing tests were denied by the sandbox; all 22 related
  native tool tests passed when rerun with authorized native inspection access.

Integrated targeted run on `8301a443`: nine execution tests, four admission tests,
eight continuity/correlation tests and one mixed-cache test passed; all-target
compilation passed.

Local logs: `/private/tmp/arkdeck-pointer-concurrent-20260919.log`,
`/private/tmp/arkdeck-pointer-submit-20260919.log`,
`/private/tmp/arkdeck-pointer-continuity-tests-v3-20260919.log`,
`/private/tmp/arkdeck-pointer-provenance-20260919.log`,
`/private/tmp/arkdeck-pointer-native-trust-escalated-20260919.log`.
Earlier attempts retained the exact oracle failures and their fixes; no fixture
bytes or accepted assertions were weakened.

## Complete unified local validation

The repository root unified entrypoint passed with exit 0 on 2026-09-19 for
`5581425f88349e1530569641fe1774e98fb4463b`, against protected-main
`510b46508d8719318114a17c2567b701297efb65`. The unfiltered planner selected
common checks and the Rust lane; Swift/App lanes were not selected for this diff.
Rust workspace tests, all-target Clippy, published and candidate contract checks,
`cargo deny` and `cargo vet` (36 fully audited) passed. Both isolated contract
recording runs completed; neither represents device acceptance.

Command (repository root):

```sh
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
ARKDECK_SWIFT_EXECUTABLE=/private/tmp/arkdeck-swift-jobs2.sh \
ARKDECK_XCODE_JOBS=2 CARGO_BUILD_JOBS=1 RUST_TEST_THREADS=1 ARKDECK_TEST_WORKERS=2 \
/private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

Log: `/private/tmp/arkdeck-pointer-unified-main510-r3-20260919.log`.
Recordings: `rust/target/readonly-check/22210b583f124f438be3719b83af198c`.
Earlier full attempts remain retained: the first failed Clippy's collapsible-if
lint in a new test (fixed in `24a87560`); the second exposed a stale availability
test expectation (fixed in `5581425f`). That test now verifies the exact
`provider_tool_unavailable` / `runtime.mutationOwnerUnavailable` /
`host_configuration` refusal for the development state root. No mutation authority,
accepted production assertion or timing threshold was relaxed.

## Remaining boundaries

CI and maintainer review remain.
This slice is not M1/M2 completion. Installed signed Runtime composition, App/CLI
journeys on that Runtime, real USB facts and GJ hardware acceptance remain separate
requirements. Neither fake transport nor this production-owner replay proves them.
