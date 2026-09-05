# Runtime Session resources

`arkdeck session list`, `show`, `pin`, and `unpin` use current v1 control
methods owned by the daemon. They never scan an App container or accept a
Session directory path.

The owner reads the active root and retention policy from the same durable
store used by `runtime storage`. `list` writes a bounded private snapshot and
returns the fixed `arkdeck.cli.page/1` envelope ordered by
`completedAtDescSessionIdAsc`; its opaque cursor remains bound to that
snapshot after the live catalog changes. `show` returns the current resource.
If the retention scan finds unaccounted or unsafe content, a fresh list/show
or pin/unpin refuses instead of presenting or mutating a partial inventory;
`runtime storage status` retains the measurement-incomplete counters for
diagnosis.

Each `arkdeck.session/1` resource includes the Session identity, catalog
generation, completion and expiry timestamps, measured bytes, pin state, and
the storage-policy generation used by retention. It deliberately omits the
private root and manifest paths.

`pin` and `unpin` require the exact catalog generation returned by `list` or
`show`. A stale generation is a `resourceConflict`. Unpinning only restores
retention eligibility; it does not run cleanup or delete Session or Artifact
data. None of these methods creates a Job or dispatches to a device.

The host-only contract fixtures exercise parsing, immutable pagination,
compare-and-swap transitions, stale refusal, XPC admission, and a real
`arkdeck` subprocess. They do not claim real-device acceptance.

The current v1 Session Manifest uses a closed confirmation actor object
`{"kind":"interactiveUser"}`. The actor records a UI decision; it does not grant
Runtime authority. Retired actor strings, authority unions and versioned
Rockchip toolchain snapshots are refused. Export preserves source Artifact
bytes and their lineage, while new manifests use only the current shape.
