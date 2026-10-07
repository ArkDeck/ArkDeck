---
id: CHG-2026-081-native-session-observation
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Native deployment records its own target and tool observation

The existing `deploy.native-library.app-owned@1` can finish deployment while
Session publication refuses its missing job-local target/tool observation.
That unfinalized durable Job also correctly blocks the complete Import-owner
census. This proposal adds the existing three read-only evidence steps to the
native Catalog plan after local ELF/hash checks and before any device mutation.
The Runtime records their actual verified results using the existing preflight
accumulator. Missing or mismatched facts prevent the first mutation.

A confirmed failed final native cleanup previously left the Job succeeded
while its actual failed Step made the unchanged Core Manifest invalid. This
proposal closes that Job known failed, preserves its failed cleanup outcome
and exact durable debt, and publishes a valid diagnostic Session. The already
verified replacement and deployment products remain; no extra rollback or
device dispatch is introduced for a final housekeeping failure. Native cleanup
and compensation debt must persist with its exact action and strict residue
count. Unconfirmed storage persistence parks without publication or replay.

This changes the native materialized plan and Catalog digest. Maintainer review
and protected-main publication are required before execution. No new operation,
provider, device profile, mutation effect, input, capability administration or
destructive policy is introduced. Existing native send, publish, verification,
rollback and cleanup lowering remains unchanged.

The GJ-3 failure-to-rollback criterion applies to deployment or loader
verification failure. CHG-2026-025 AC-DEBUG-008-03 requires rollback when the
post-publish loader verification fails. A later housekeeping failure retains
the verified replacement, fails forward acceptance and reports its own debt;
it is not a deployment PASS. This status clarification is explicitly submitted
for maintainer review with the Catalog delta, rather than relabelling a failed
dispatch as skipped, notRun or success.

An older Job with no original target/tool observation cannot acquire historical
facts from a new Job or a present observation. Its original publication failure,
Journal, authority and unknown/no-replay rules remain intact. This producer fix
does not assert that such an older Job becomes publishable or that its census
blocker has been settled.

Compatibility: the scoped Catalog delta travels with its implementation and
targeted checks; no accepted Core predicate or historical hardware result is
changed. Synthetic transport is not device acceptance.
