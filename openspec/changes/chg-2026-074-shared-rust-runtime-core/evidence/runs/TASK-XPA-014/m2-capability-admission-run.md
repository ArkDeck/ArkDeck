# TASK-XPA-014 — the Rust admitter authorizes the pointer gestures as Swift does: an automatic Runtime capability per control session, checked against the lineage of every capability, behind the device session hold (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `0be358d9`; no stack. That main carries the
capability store's writes (#1963) and the pointer-input plans (#1964), which this slice needs.
This slice admits a device mutation under a Runtime capability. No use is
consumed and nothing runs: that is the next slice. Every answer here is replayed from Swift's
pointer-input oracle, recorded over the shared fake HDC. None of it is device evidence
(POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M2 |
| --- | --- | --- |
| The pointer-input oracle (#1958); the provider's gestures (#1961); the capability store's reads | Built on the two slices before it (the store's writes, the gestures' plans): admission under a Runtime capability, meaning the session subject, the policy's identity and generations, issuance, the lineage across capabilities, the device session hold; `defaultPolicyIssuance` read as Swift reads it | Consuming a use before the first mutation, its evidence and the Job's outcome; dispatching the gesture; evidence carried from the session readback; the result readers; the port-rule, debug HAP and native library admissions; the full oracle replay |

## Why

Swift admits every M2 operation under a Runtime capability, issued at submission when the caller
names none. The Rust admitter refused every device mutation because it issued none, so no M2 Job
could exist.

## What changes

- **Admission above `readOnly`** (`job_admission.rs`, Swift `preauthorize`), in Swift's order:
  1. The device session hold.
  2. The catalog's policy for the effect.
  3. A capability the caller names, used as named. Without one, the Runtime issues its own for a
     `standingCapability` device mutation the catalog lets it issue for. Otherwise the refusal is
     `effect deviceMutation requires an explicit runtime capability`.
  4. Swift's `validateNewExecution` against that capability.

  Every refusal is `admissionDenied` in Swift's words, with the zero-dispatch proof, as Swift's
  daemon maps `authorizationRequired`. A store refusal carries Swift's `[denial:<code>]` token.
- **Automatic issuance** (`capability_policy.rs`, Swift `automaticRuntimeCapability`):
  - **Session scope.** A gesture (and a screenshot-only capture) is owned by its control session.
    Its subject keeps only the frame it was mapped against (`displayId`, `displayWidth`,
    `displayHeight`), and its plan digest leaves the scope fingerprint. Its envelope lasts an hour
    for 2000 uses; a standing one lasts thirty days for 10000.
  - **Identity.** `CAP-RT-POLICY-<the first 40 of the uppercase SHA-256 of the catalog digest, the
    engine's scope fingerprint and "ordinary">-G<generation>`. A generation that is spent (no uses
    left, or expired) and not revoked is skipped. Any other existing generation is used. A missing
    one is built as Swift builds it and installed: exact inputs, a constraint per scalar input, the
    binding revision, and the issuer `catalog:<digest>:<operation>`.
  - **Lineage first.** Before any issuance, every capability's uses on the Target binding are
    scanned in store order. One that is neither confirmed nor safe to reflash refuses the admission:
    `automatic Runtime target lineage is blocked: lineageBlocked("target binding has unresolved
    capability <id> use <n> outcome <outcome>")`.
- **The admitted Job** runs the request that names the capability; the caller's request stays its
  original submission. It carries no admission evidence until a use is consumed, as Swift's does.
- **The device session hold** (`DeviceHolds`, Swift `deviceSessionHolds`):
  - A session-scoped request holds the device for its client until two minutes after its last act.
  - Meanwhile another client's device mutation is `resourceConflict`, `a control session opened by
    <client> holds this device since <time>; it was not queued behind that session`.
  - The daemon keeps the holds in memory, as Swift's engine does.
- **`defaultPolicyIssuance`**: a descriptor that leaves it out is enabled, as Swift's generated
  catalog reads it; only `disabled` disables it. Rust read an absent value as disabled. That had no
  effect before this slice, since only `workspace.create-checkpoint@1` read it and it states
  `enabled`.
- **The store** answers the generation walk and the lineage scan (`generation`, `unresolved_use`),
  and builds an issued envelope with Swift's model check (`Capability::issued`).
- **The development daemon** authorizes from its capability store beside the Job state, with its
  own holds.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The pointer-input submissions | `cargo test --locked -p arkdeck-hoststore --test pointer_input_submit` | 3 tests pass. (1) Every plan and submission but `afterUnknown`'s is answered as Swift answered it. The three capabilities are installed exactly as Swift issued them. Each Job's request (naming its capability), original submission, plan digest, identity and binding revision match what Swift persisted, and no Job carries admission evidence. (2) Over the store the oracle left, `afterUnknown` is refused in Swift's words; the store stays byte for byte and no Job is admitted. (3) Another client is refused while a session holds the device |
| Runtime issuance in the catalog | `cargo test --locked -p arkdeck-hoststore --lib operation_catalog` | Passes |
| The two slices beneath | `cargo test --locked -p arkdeck-hoststore --test capability_write --test pointer_input_plan` | Pass |
| The whole crate | `cargo test --locked -p arkdeck-hoststore` | 259 tests pass and 10 are ignored, in 34 suites |
| The daemon | `cargo test --locked -p arkdeck-agentd` | 10 tests pass |
| The platform's host store | `cargo test --locked -p arkdeck-platform --lib host_store` | 20 tests pass, 1 ignored |
| Lints | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform --all-targets -- -D warnings` | Clean |
| Formatting | `cargo fmt --check -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform` | Clean |
| Union-merged records | `python3 scripts/check_union_merge.py` | `check_union_merge: ok` |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `743c1b1a` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 806 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-m2-capability-admission-gate-20260915-a.log`, SHA-256 `43a07103e05e1f626f7edb552e48177ad6d52cb1c5ac02eaf900cec3f6727c06` |

The amend after r1 only fills in this row.

## Not run, and why

- **Consumption, the run and the reads.** The next slice consumes a use before the first mutation
  and records its outcome.
- **Not served, and refused as before:**
  - a destructive effect, whose admission is recovery's;
  - the `runtimeCapability` policy;
  - a workspace subject.
- **Swift's production mutation-state check** (`RuntimeStateContinuity.requireMutationState`) is
  not ported. It refuses a mutation under a state-root override and proves an existing root's Jobs
  read-only before its first capability. The development daemon runs only in an isolated root with
  a fixture HDC.
- **Recovery epochs.** Swift's lineage check first reads the superseding recovery epochs, which
  creates their lock in the state root. Neither is served, because both are recovery.
- No device, no real HDC.

## Current-main integration (2026-09-19)

PR #1968 remained open at `fcda0ca038119017fe422ea92778bbadad283aae` when
rechecked. Merged current protected-main `1ee1d73d` into the PR branch. The two
`agentd/host.rs` conflicts retain both the original DeviceHolds/authority wiring
and main's Target observation, USB source and human-action owners. Main's new
read-only HAR fixture explicitly supplies `authority: None` to the extended
JobAdmitter; its prior behavior is preserved. No policy, capability lineage,
allowance, dispatch or recovery semantics were changed for conflict resolution.

Targeted integration checks: `cargo check -p arkdeck-agentd -p arkdeck-hoststore
--tests` passed. Hoststore `pointer_input_submit` (3 cases including unknown
outcome and competing-session refusals), `agent_execution`, `agent_lifecycle`
and `agent_human_action_raise` passed (6 tests total). `cargo fmt --all --check`, both packages' all-target Clippy with `-D warnings`,
and staged diff whitespace checks also passed.

The required unified planner was run against origin/main with merge-base and
include-worktree. The first attempt was stopped by sandbox permissions on the
shared SwiftPM cache. The second attempt with the necessary host permissions
passed common checks, then failed compiling unchanged main code under SDK 6.4:
`ArkDeckOpenHarmony.swift:745` uses deprecated `String(cString:)`, treated as an
error. Logs: `/private/tmp/arkdeck-capability-1968-unified-20260919.log` and
`/private/tmp/arkdeck-capability-1968-unified-20260919-r2.log`. This is the known
main SDK compatibility issue addressed in PR #1976; this capability slice does
not duplicate that unrelated fix. At that attempt full validation had not passed,
and the merge was left uncommitted/unpushed. The integration continuation below
records the subsequent explicit dependency and final validation separately.

### Explicit validation dependency and final branch rerun

The current-main merge was completed as `e6900080`. PR #1976's original commit
`b710252d1d7844f1fcd361e58c66429a06173493` was then merged, without copying its
compatibility changes, as `e2849f78`. The dependency is the original reviewed
ClientKit/SDK compatibility diff, not a second patch owned by this capability
slice. PR #1976 was still OPEN and awaiting maintainer approval/main integration
when checked; this local branch merge does not supply that approval.

The unified gate runs on this actual PR branch with the outer planner using
`/private/tmp/arkdeck-validation-venv` and the required host permissions for
Swift/Xcode caches. The planner selected the shared `.venv-sdd` for common Python checks (all
passed); Rust child commands explicitly use
`/private/tmp/arkdeck-validation-venv/bin/python` via `sys.executable`.
`ARKDECK_PYTHON` was not set. The complete unified gate passed (exit 0):
common checks, design-system checks, full Swift tests, App build-for-testing,
Rust workspace tests, published and candidate contract checks, cargo-deny and
cargo-vet. Log: `/private/tmp/arkdeck-capability-1968-unified-final-20260919.log`.
This is branch validation, not protected-main or real-device acceptance.

### Integration with merged adoption and Rust soak

After #1975, #1976 and #1977 merged, the review of `7714175e` identified that
the new soak's `JobAdmitter` needed the capability-admission field. Main
`98cb3b963e2b959287b9bc1c94e4840c747b3ccc` is now integrated as `215d2b3b`.
The soak and both newly added adoption-test constructors explicitly use
`authority: None`, preserving their read-only operation scope. All Rust
`JobAdmitter` constructors were checked, including the real daemon's existing
Runtime authority wiring. No capability is created by these fixtures.

`cargo check --offline --locked --workspace --all-targets --jobs 1` passed,
covering the actual integrated tree; formatting also passed. Log:
`/private/tmp/arkdeck-1968-integration-check.log`. The final unified gate on this
new combination remains pending; the preceding branch pass and remote CI do
not validate this newer combination. #1976 is now merged, so that dependency
no longer awaits approval.
