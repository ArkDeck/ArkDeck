# CLI Runtime storage owner

Task: TASK-AIN-021

`arkdeck runtime storage status|policy|root` is the current v1 surface for one
daemon-owned Session storage resource. `status` reports the Session output domain
and immutable Runtime Artifact domain as separate typed objects. Their roots,
quotas, usage, and retention policies are never added together; the Artifact
root remains an opaque Runtime reference.

The Session resource is a canonical private document in the daemon state
directory. Policy and root mutations require the exact current generation and
publish by atomic rename. A custom root must be an existing, owner-controlled,
non-group-writable directory and pass a descriptor-bound write probe. A stale
generation is rejected before that probe, so a failed CAS has no filesystem
write side effect. The Runtime continues to refuse Artifact work at its own
quota and never treats a Session policy as authority to evict Artifacts.

The macOS Settings screen uses the same XPC-allowlisted methods and validates the
exact Runtime projection. Its former `UserDefaults` Session record is no longer
a fact source. On first refresh only, a non-default legacy record may provide a
bounded migration candidate while the Runtime owner is still at generation 1.
The daemon revalidates every value, each write uses CAS, and any concurrent
Runtime/App/CLI publication wins permanently over the legacy record.

Host contract coverage executes the real `arkdeck` process against an isolated
daemon and verifies status, policy CAS, root CAS, durable reload, stale-CAS
refusal, directory permission refusal, XPC admission, and zero Job creation.
This is host-only validation and does not claim real-device acceptance.
