# Rust Bundle registration owner and typed RPC — macOS, 2026-09-12

Base: protected main `6be27ace`. TASK-XPA-012 remains in progress. The candidate
implements `runtime bundle register --kind daemon-bundle --file <absolute-app>`
through the Rust CLI, typed control handler and the shared Bootstrap registry.
The Swift daemon supplies the additive RPC and producer oracle; its bootstrap
CLI retains the existing local registration behavior. This phase does not
activate an installed Rust owner or claim device acceptance.

## Implemented behavior

The reused bounded platform capture from the preserved
`/private/tmp/arkdeck-xpa012-bundle-capture` worktree was inspected and copied into
this phase without changing that original worktree. It preserves raw quarantine,
normalizes only newly created capture modes, verifies complete tree/source
identity around native production validation, and exclusively publishes one
immutable content address. Unknown publication retains uncertain namespaces;
cleanup can reach only the capture object's own newly created inodes.

The Rust registry initializes only genuinely empty state, holds the same lock as
Bundle list/removal and Tool owners, accounts retained orphan/staging content,
requires native verified content before recording a Bundle, and preserves the
frozen index and SHA-256/JCS identity. Exact available registration is idempotent;
removed references are not resurrected. Existing orphan content is adopted only
after fresh complete verification. The record is published after content and is
read back before returning. An uncertain result is never automatically replayed.
No service selection, installation, execution, or capability operation is added.

The RPC accepts only kind and file. Host time, digest, trust, quota, and publication
outcome are derived by the owner. The Rust CLI preserves closed result shape,
exact reference/content identity and registration state. Lost or inconsistent
registration responses become `outcomeUnknown`.

The current Swift producer frames are committed beside this report. They use
source-created non-executable fixtures and the pre-existing Swift test-only trust
injection; those successes prove wire shape and persistence behavior, not native
Bundle acceptance. The result schema also reuses actual Bundle inspection
projections so repeat registration can preserve existing owner references.
All other method schema edits refresh only contract identity. The published-main baseline pin and generated Rust published contract are refreshed
to protected main `6be27ace`; the new method is available only in the separately
materialized candidate view until reviewed main publication and a subsequent
legitimate pin refresh.

## Validation completed

- Rust platform capture: 4 unit and 2 integration negative tests passed. Source
  changes, quarantine/modes, unrecognized/replaced/hardlinked members, missing
  root binding, invalid versions, links, unsafe modes, tree depth and byte bounds
  fail closed. The two native positive/fault tests remain ignored.
- Rust owner: 3 tests passed for invalid input, missing/corrupt index preservation,
  staging quota, shared lock, mandatory native trust refusal and source retention.
- Published-input CLI/control suite passed. Initial CLI socket tests hit sandbox
  EPERM; the identical suite passed with controlled local-socket permission.
- Candidate CLI suite passed. Candidate control suite passed after adding the
  new implemented method to the exhaustive dispatcher test's implemented set.
  Closed caller fields and unknown/unbounded replies are tested with zero device
  observation and exactly one owner invocation.
- Two current Swift `BootstrapBundleRegistrationControlContractTests` passed,
  including exact repeat/reopen receipts, nullable version, closed parameters,
  unavailable owner and classified/unclassified publication failures. Logs:
  `/private/tmp/xpa012-bundle-registration-current-swift.log`; frames are in
  `bundle-registration-producer-frames-macos-20260912/`.
- Real candidate Rust CLI/daemon process check passed with a source-created
  unsigned Bundle. It validates native trust refusal, a durable empty index,
  restart reads, shared lock, staging quota, closed requests and a deliberately
  lost owner response with no replay. The first harness run exposed a stale
  socket readiness race; the harness now waits for an actual connection before
  issuing restart queries. Log: `/private/tmp/xpa012-bundle-candidate-process-r2.log`.
- Five affected Rust crates passed warnings-denied Clippy; formatting, Python
  compilation and Swift control generator drift check passed. Logs:
  `/private/tmp/xpa012-bundle-clippy.log`,
  `/private/tmp/xpa012-bundle-cli-control-native.log`,
  `/private/tmp/xpa012-bundle-candidate-tests.log` and
  `/private/tmp/xpa012-bundle-candidate-control-r2.log`.

The first repository unified gate passed common checks, 83 design-system tests,
2,627 Swift tests plus the 5 serial tests, and App build-for-testing. Candidate
Rust corpus replay then found stale health identity after the additive method.
The existing Swift health producer was rerun against the final registry and its
two actual frames replaced the stale corpus. The final unified rerun and PR
preflight/CI are recorded below. No App presentation change or UI assertion is part of this phase.

## Explicit remaining validation and boundary

The original capture report records that automatic approval review refused the
exact existing Library signed Bundle-to-new-private-temp copy. That action was
not retried, renamed, or replaced with another signed source in this phase. The
native success/digest test and native publication-fault test remain unexecuted.
Their completion needs authorization for the specific previously refused local
copy or a maintainer-supplied permitted native validation environment. Fixture
results cannot replace that native acceptance. The original report does not
contain the full automatic-review reason, so this report does not invent one.

Installed cutover, Bundle installation/reference-owner integration, remaining
host-store writes and overall GJ acceptance remain separate work. No
`REAL_DEVICE_PASS` is claimed. The prior Allowed-path inspection annotations are
historical scope-extension descriptions; revision 10 and the current migration
request cover this additive owner method within already listed paths. No new
Allowed pattern or Scope-Extension trailer is introduced.

## Final local gate

The required repository `scripts/ci/plan.py --merge-base --include-worktree
--run-local` completed with exit 0 on the final source. Log:
`/private/tmp/xpa012-bundle-unified-gate-r4.log`. It passed common/schema checks,
83 design-system tests, 2,627 Swift tests and 5 serial tests, App
build-for-testing, both published/candidate Rust Clippy and workspace suites,
actual CLI/daemon and owner process checks, process self-test, cargo deny and
cargo vet (26 fully audited). No App presentation changed; UI assertions are not
applicable. The prior run found the exhaustive process harness still expected
`rejected` from the newly handled `runtime.bundle.register`; its empty request
now correctly expects the existing `invalidParams` refusal.
