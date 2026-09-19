# Rust History App reads

Date: 2026-09-19. Integrated base: protected main
`510b46508d8719318114a17c2567b701297efb65` (#1983). Focused validation below
preceded integration, on #1980 `760c527e41693373005c6d0ee1d5363248911a9b`. Scope: macOS TASK-XPA-019, standalone History ingress.

## Production behavior

The existing authenticated App ingress now admits the six read methods consumed
by the History UI: `job.list`, `job.show`, `job.timeline`, `job.evidence`,
`artifact.list` and `artifact.read`. They use the same `Control<Host>`, Job and
Artifact owners as the Unix transport. Current closed request schemas are
validated before entering Control; semantic identity, snapshot/cursor, range,
integrity and explicit sensitive-content permission checks remain in the owners.
There is no retry, response cache, alternate owner or Swift forwarding.

The fixed signature/euid policy and explicit isolated `history` mode are
unchanged. App execution, cancellation, imports and arbitrary export paths remain
outside this ingress. A user-selected local export continues to assemble bounded
Artifact reads in the App. No new operation or mutation authority is added.

## Verification

Focused validation: **PASS**, 5 ingress tests plus 1 startup rejection test
(`cargo test --offline --locked -p arkdeck-agentd app_ingress`, one worker).
`cargo clippy --offline --locked -p arkdeck-agentd --all-targets -- -D warnings`:
**PASS**. Logs: `/private/tmp/arkdeck-app-history-reads-focused-final-20260919.log`
and `/private/tmp/arkdeck-app-history-reads-clippy-20260919.log` (local).
Focused tests use synthetic local Job/Artifact
snapshots, the production stores and a synthetic authenticated-origin callback.
They exercise nonempty paging, shared-owner read equivalence, restart/cursor
continuation, missing identities, invalid cursors, explicit sensitive reads,
out-of-range reads and payload tampering. Boundary tests reject extra or wrongly
typed read parameters before entering Control and continue rejecting every
nonallowlisted published method.

No Mach listener, signed App UI, installed service, device operation or hardware
evidence is involved. These tests cannot establish SPK-8, installed cutover,
Swift retirement or GJ acceptance. Existing unsupported operation-result readers
remain explicit limitations of the corresponding Rust owners.

## Final integrated validation

**PASS — exit 0**, 2026-09-19, session `61491`, source `7bac1578` including
protected main `510b46508d8719318114a17c2567b701297efb65`.

```sh
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python ARKDECK_SWIFT_EXECUTABLE=/private/tmp/arkdeck-swift-jobs2.sh ARKDECK_XCODE_JOBS=2 ARKDECK_TEST_WORKERS=2 CARGO_BUILD_JOBS=1 RUST_TEST_THREADS=1 /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local
```

The unified planner selected public checks and the Rust lane for the complete
five-file diff. Formatting, Clippy, the full Rust workspace suite, 35 Python
contract harness tests, actual published/candidate contract views, cargo-deny
(advisories/bans/licenses/sources), and cargo-vet (36 fully audited) passed.
Swift/App build lanes were not selected; no lane was filtered or skipped.

Log: `/tmp/arkdeck-app-history-reads-unified-main510-20260919.log`.
Contract recordings:
`rust/target/readonly-check/11a5b6f0628e47c084946b33a6cb15e6`.
Later main changes are not claimed as locally tested combinations. Exact-head
PR checks and final main-push checks are separate evidence.
