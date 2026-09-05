# CLI Trace cache maintenance

Task: TASK-AIN-021

`arkdeck trace cache status|purge` exposes the same lease-aware derived-cache
resource used by the macOS Settings pane. The daemon owns the resource and
fixes its production root to the sandboxed ArkDeck App's cache container. The
App and CLI can send no filesystem path, database identity, raw command or
original Trace Artifact reference.

```text
arkdeck trace cache status --output json
arkdeck trace cache purge --output json
```

Both leaves verify the current v1 control identity. `status` returns
`arkdeck.trace-cache-status/1` with bounded entry, active-entry and byte counts.
It also reports the fixed scope `inactiveDerivedDatabases`; it never publishes
the cache path. `purge` returns `arkdeck.trace-cache-purge/1`, before/after
inventories and maintenance counts. Its response fixes
`originalTraceArtifactRemovalCount` to zero.

The daemon delegates to ArkTrace's public `TraceCacheMaintenanceService`.
Every removal still follows ArkTrace's key lock, exclusive entry lease and
exact-owner transaction. Active entries are skipped. The service accepts only
the reviewed sibling leaves `ArkDeck/Trace/traces` and
`ArkDeck/Trace/staging`, and original trace inputs are outside that cache.

`status` is bounded read-only. `purge` is mutation-capable even though it
touches no device and creates no Job. A lost, malformed or timed-out purge
response maps to `outcomeUnknown`; callers read `trace cache status` before
making another explicit purge request and never retry automatically. The App
uses that same reconciliation rule and keeps the uncertain result visible.

This local resource is not Runtime evidence and does not change a Job,
Artifact, Session, target, binding, capability, provider fact, admission
decision or device state. Test daemons started with `--state-dir` use an
isolated cache root beneath that test state directory so local contract tests
cannot purge a user's App cache.
