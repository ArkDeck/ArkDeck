# TASK-XPA-014 — live host operation availability (macOS, 2026-09-19)

Base: `aeffacf8f4285ecda0a9c8bf6ff37d1da14e2d05`. This independent slice does
not include the parallel Target-availability route. TASK-XPA-014 and M1 remain
in progress. All verification below is synthetic host testing, not physical-device
acceptance or installed-Runtime verification.

## Behavior

`operation.list` and `operation.describe` now consult the daemon's current
provider/dispatcher/Artifact configuration on every request. Catalog metadata
remains cached, but operation availability is not frozen at daemon startup.
The shared projection is exposed as `Control::operation_availability()` for the
Target aggregate's later integration.

A composed Rust host can report exactly three executable operation references:
`analyzer.extract-crash-signature@1`, `observe.device@1`, and
`capture.diagnostics@1`. Planning and Job owners, required Artifact storage,
and the relevant provider/tool are necessary. The analyzer profile reuses the
planner's bounded executable-identity check. HDC revalidates the existing
VerifiedTool's retained executable identity without starting it. Each Job's own
admission and dispatch checks remain authoritative and unchanged.

Registered providers report `operation_not_supported` for missing executors,
including the three pointer operations whose plans exist but whose Rust
execution path is absent. Missing profile/owner, executable identity drift, and
missing Artifact owner carry distinct reason codes and host-configuration
origins. Unregistered providers retain their product-build reason. The ordering
is provider availability, dispatcher/Job owner, then Artifact owner, following
Swift RuntimeJobEngine.operationAvailability's host-scoped model. A managed HDC
server is not a prerequisite for an existing external HDC dispatcher.

This is host availability, not target readiness, supported-input completeness,
capability admission, or proof that a requested Job will succeed. In particular,
ring-buffered capture remains unsupported by planning. No device probe, Job,
capability, filesystem publication or process dispatch is added by discovery.

## Checks

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd`:
  31 passed (15 daemon, 1 control unit, 15 control integration).
- The two new daemon-composition tests verify exactly three available references,
  pointer refusal, list/describe agreement, missing Job/Artifact owners, analyzer
  drift and restoration, and HDC identity drift while the same Control remains
  alive. Inert test executables would create a sentinel if dispatched; none is.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib
  operation_availability`: owner classification test passed.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd
  -p arkdeck-hoststore -p arkdeck-provider-hdc --all-targets -- -D warnings`:
  passed. `git diff --check`: passed.
- First daemon-test iteration used the list's reason field names against the
  descriptor; corrected to the existing `availabilityReasons`,
  `availabilityReasonCodes`, and `availabilityReasonOrigins` contract fields.

The final unified local gate and CI belong to the submitting parent slice.
The installed path still requires managed HDC/lifecycle composition and real
protected-main GJ acceptance. This change does not modify Catalog, contracts,
authority records, capability policy, or the in-flight pointer admission work.

Repository unified local verification passed on 2026-09-19 using the CI-pinned
PyYAML 6.0.3 / jsonschema 4.26.0 environment: common checks, Rust workspace
tests/Clippy, published/candidate contract checks, cargo deny and cargo vet.
