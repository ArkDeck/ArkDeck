# Runtime Session cleanup

Task: TASK-AIN-021

`arkdeck session cleanup preview` and `arkdeck session cleanup apply` expose
retention cleanup through the daemon-owned Session storage resource. Neither
command accepts a Session path, Artifact path, executable, or device command.

Preview persists an immutable Runtime-private record for ten minutes. Its
canonical digest binds the storage and catalog generations, retention policy,
active Runtime Session leases, pin state, measured Session bytes, and every
Artifact identity, digest, role, byte count, and privacy classification. Raw
and partial Artifacts are classified as sensitive; other roles remain unknown
instead of being promoted to standard. The response contains no filesystem
paths and reports zero device dispatches.

Apply requires exactly the lowercase preview UUID and SHA-256 digest returned
by preview. This exact tuple is the explicit confirmation; there is no separate
`confirm` command or parameter. Before deleting anything, Runtime revalidates
the configuration, complete catalog snapshot, active leases, pin state, and
expiry. Drift returns `resourceConflict` with zero deletion. The final snapshot
comparison and anchored deletion run under the catalog lock, so a concurrent
pin cannot land between validation and deletion.

Runtime durably marks a preview as applying before the first delete. A
successful apply stores an immutable receipt, and retries return that receipt
without another deletion. If execution stops after it enters applying state and
the exact outcome cannot be proven, apply returns `outcomeUnknown` forever for
that preview and never replays it.

The contract fixtures cover parsing, protocol and XPC admission, preview digest
validation, Artifact binding, lease and pin drift, expiry, partial deletion,
durable retry, and a real `arkdeck` subprocess. Cleanup is host-owned and makes
no device dispatch, so these tests do not claim real-device acceptance.
