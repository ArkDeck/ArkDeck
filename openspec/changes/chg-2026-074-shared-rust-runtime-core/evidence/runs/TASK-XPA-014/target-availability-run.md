# TASK-XPA-014 — bounded Target availability (macOS, 2026-09-18)

Base: `aeffacf8f4285ecda0a9c8bf6ff37d1da14e2d05`. TASK-XPA-014 and M1 remain
in progress. This is synthetic local host verification, not device acceptance.

## Delivered behavior

`target.availability` now reaches the Rust daemon's actual Target store through
the existing typed `target.show` owner. The bounded aggregate reads a persisted
binding (including revision, adopted time, tool version and physical identity
digest), and exposes host operation entries without claiming target resolution.
It creates no Job, capability, observation, or device dispatch. Reopening the
owner after restart resolves the same binding. Unknown targets return `notFound`;
missing identities return `invalidParams`; unsafe/unreadable Target records keep
the owner failure rather than becoming an apparently ready Target.

The published presence schema currently admits only the unresolved/null shape.
This composition has no warm presentation source or managed HDC server: presence
and profile remain `unresolved`, while the managed-tool leg is `absent`, matching
Swift's behavior without those owners. A development HDC executable is not
promoted to managed-server readiness.

## Validation

`cargo test --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd`:
30 tests passed (13 daemon, 1 control unit, 16 control integration), none failed.
The daemon replay now checks all 21 Target-oracle exchanges rather than skipping
the three availability exchanges. Binding/presence/profile compare to Swift's
recording; the tool leg is adjusted for the Rust composition's absent managed
server, and host operation entries compare to this Runtime's `operation.list`.
The original fake HDC invocation log and durable Target/display-name bytes remain
equal to the recorded oracle. Added checks cover cold reopening, malformed/empty
identities, extra parameters, missing owner and corrupted Target storage. No new
HDC dispatch occurs for these availability requests.

`cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd
--all-targets -- -D warnings` and `git diff --check`: passed.

The first full test pass exposed the obsolete unimplemented-method expectation;
it now excludes the implemented route and separately checks its missing owner.
The parent slice runs the repository unified local gate before submission.

## Remaining dependencies and limits

`operation.list` still constructs the foundation's uniform
`provider_not_registered` entries. Reusing this source preserves existing public
semantics but does **not** establish actual executable-operation availability;
the live provider resolver is still required. This result must not count as
completed device readiness, executable-operation coverage or M1 acceptance.
Warm observation presentation, managed HDC ownership, target/profile resolution,
real process IPC acceptance and protected-main real-device journeys remain
separate work. No schema, authority record, Catalog or Swift runtime was changed.

Final repository unified local check passed on 2026-09-19 using CI-pinned
PyYAML/jsonschema: common gates, Rust workspace/Clippy, published and candidate
contract checks, cargo deny and vet. Initial environment runs lacked jsonschema;
a concurrent-build run exceeded the existing process overflow test's two-second
wall-clock bound. The final isolated rerun passed unchanged assertions.
