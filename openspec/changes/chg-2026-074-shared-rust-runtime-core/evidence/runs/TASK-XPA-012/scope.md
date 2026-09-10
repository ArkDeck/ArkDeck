# TASK-XPA-012 nightly scope request — 2026-09-10

Base: `eae27c6b97c2d9e5d67c8eee2d9353f2c0d38b93` (protected main).

The task requires at least seven nightly days of byte-equal Swift/Rust
read-only projections before host-store ownership changes. Its base scope covers
`rust/**` and the Swift contract tests, but not the existing scheduled workflow.
The actual `check_pr_paths.check_paths` probe accepted
`rust/crates/arkdeck-hoststore/src/lib.rs`, `rust/scripts/hoststore-shadow.py`
and `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostStoreShadowContractTests.swift`.
It refused `.github/workflows/swift-slow-lanes.yml` as outside TASK-XPA-012.

This openspec-only request adds exactly that workflow to the Task's scope for a
separate macOS host-store shadow job and archived digest-only receipts. Existing
slow/UI jobs, schedule, permissions and merge gates stay unchanged. The job will
run both implementations on identical isolated inputs, compare bytes, fail on
mismatch and record source/input hashes and actual run provenance. Local reruns
and manually supplied dates do not count as seven scheduled days. No fixture
result is hardware acceptance. The harness remains in already-authorized Rust
scripts/crates and Swift tests; no script scope extension is needed.

`.github/**` is in `never_self_extend`, so an in-band scope trailer cannot grant
this permission. Maintainer review and merge of this request must precede the
workflow implementation. This request changes no runtime behavior, acceptance,
Task status, schema, Catalog, device state or ownership. Harness development can
continue independently. The explicit two-PR harness/cutover instruction is the
current task's scoped delivery plan; no separate readiness/status PR is proposed.

Validation (scope-only diff):

- `ARKDECK_PYTHON=<existing pinned venv>/bin/python3 sh scripts/check-sdd.sh`:
  exit 0, zero errors/warnings, 121 acceptance IDs.
- Unified local planner with `--merge-base --include-worktree --run-local`:
  exit 0, all selected common checks passed; Swift/App/Rust lanes not selected
  for these two openspec documents.
- Final committed preflight is run before push; hosted results belong to the PR.

Local logs: `/private/tmp/xpa012-scope-sdd.log` and
`/private/tmp/xpa012-scope-gate.log`. No nightly, cutover,
rollback or GJ-1 re-pass has run for TASK-XPA-012.
