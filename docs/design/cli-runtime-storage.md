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
exact Runtime projection. The Runtime owner is its only fact source: a record in
this process's own `UserDefaults` is neither read nor promoted, so no App-local
preference can produce a Runtime configuration write. Each mutation carries the
generation the screen last read; a `resourceConflict` means another Runtime,
App or CLI writer published first, and the screen reads the owner back and
publishes what won rather than re-sending its own write.

Host contract coverage executes the real `arkdeck` process against an isolated
daemon and verifies status, policy CAS, root CAS, durable reload, stale-CAS
refusal, directory permission refusal, XPC admission, and zero Job creation.
This is host-only validation and does not claim real-device acceptance.

## Current durable format (TASK-SVC-002)

The Runtime accepts one current v1 Journal, Manifest and capability layout, and
one SQLite layout with `user_version=1`. The number alone is insufficient:
readers validate fields, nested records, index definitions, constraints and
ordering. A retired v1 file can therefore be refused even though its version
matches. Current row versions, admission sequences and remaining-use counters
retain their ordinary changing values.

An unsupported or unreadable store is left at its original path. Missing
admission indexes beside Job history, or missing capability checkpoints beside
a ledger, never initialize empty replacement authority. The error identifies
the affected store; retain its database, WAL, journals, ledger and raw Artifacts
together. This release supplies no automatic migration or cleanup command.
Unknown intent outcomes remain unknown, and format rejection cannot authorize
replay or release their target lane.

`arkdeck runtime storage status` reports the active storage configuration.
`runtime storage root` selects the Session output directory; it does not relocate
Runtime admission or capability state. A Session directory change cannot create
a fresh mutation budget. Inspect current history with the Job/Session resource
commands; preserve rejected historical files for offline review with the build
that originally wrote them.

The removed `flash status`, `flash reconcile` and `legacy flash` archive commands
are no longer registered. `flash install-binding`, current Runtime Flash Jobs
and complete-overwrite recovery remain available. A daemon `--state-dir`
override can serve reads but cannot open a production mutation lane; mutation
checks both configured and default Session roots and refuses retired authority
state without modifying it.
