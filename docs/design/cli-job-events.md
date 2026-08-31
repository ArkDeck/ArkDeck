# Durable CLI Job observation

This implements the event path in the CLI product specification §§7.3 and 8.3.
It improves GJ-1–GJ-5 observation without changing operation admission, dispatch,
recovery, journal canonicalization, or the Catalog digest.

## Published surface

The negotiated 2.0.0 control vocabulary adds `job.events` and `job.status`.
Protocol 1.0.0 `job.status` remains unchanged; 1.0.0 cannot call `job.events`.

```text
arkdeck job events --job J --output json
arkdeck job events --job J --after-cursor CURSOR --page-size 100 --output json
arkdeck job watch --job J --output jsonl --timeout 30s
arkdeck job wait --job J --output jsonl --timeout 5m
arkdeck job wait --job J --require-protocol 2 --output json --timeout 5m
arkdeck job status --job J --require-protocol 2 --output json
```

`events` returns one `arkdeck.cli.page/1` envelope, with `pageKind:eventStream`,
`order:streamPositionAsc`, an ordered `items` array, decimal-string
`snapshotRevision`, `hasMore`, and non-null `nextCursor`. The first event's
position is `1` (journal sequence `0`). Every row carries its stable journal
`eventId`, decimal-string `streamPosition`, page high-water `runtimeRevision`,
exclusive `cursor`, `type`, and bounded `data`.

Rows use `stateChanged` for journal state transitions and `journalEvent` for
other accepted journal kinds. The data contains Job/session identity, journal
kind, timestamp, optional step/attempt/binding revision, and typed from/to state
for transitions. Raw payload, diagnostic reason prose, paths, executable/argv,
inputs, provider output, and capability material are never projected.

## Persistence and bounds

The producer reads the existing Job WAL while holding its existing publication
lock. It neither rewrites the WAL nor adds a second authoritative event store.
Each page reads 64 KiB chunks, bounded records, origin and cursor boundary
checks, and the final complete record for the high-water mark; it does not load
or replay the complete history on every poll. Completed malformed records fail;
an incomplete final line is withheld until completed. The reader accepts a
maximum 16 MiB canonical journal record. Oversized/corrupt records return
`recordUnreadable` rather than truncating JSON or skipping events.

Page size is a count ceiling (1–1000, default 100). A conservative 1 MiB
projection budget can return fewer rows, with an advancing cursor and
`hasMore:true`, below the 8 MiB control-frame cap. Large raw payloads yield small
metadata projections. The reader retains at most bounded record buffers and one
page, independent of complete Job history length.

Cursors are authenticated, encrypted tokens scoped to `job.events`, its order,
Job identity, exact exclusive position, and observed high-water relation. They
do not expose file offsets or paths. A private 0600 key lives with the Job;
tokens need no accumulating cursor table or expiring snapshot cache and survive
Runtime restart. Page size may change while resuming because it is a count
ceiling, not an event filter.

Malformed, forged, cross-Job and non-event cursors return `invalidCursor`.
Journal replacement/truncation, changed cursor-boundary bytes, or corrupt key
fail closed with `recordUnreadable`. The existing Job retention has no published
summary-only state or independent event-history eviction: a queryable complete
Job must retain its complete WAL/key. This implementation does not invent such
a policy or silently reset to an earliest/tail position. A reclaimed whole Job
returns `resourceNotFound`. A future summary-only policy must explicitly add
the specification's authenticated `eventHistoryUnavailable` gap projection.

## Client lifetime

`watch` keeps observing after Job completion and ends on client timeout,
interruption or an explicit read failure. `wait` drains events, reads the typed
Job next action, and stops on terminal, human action or unknown/reconcile. After
observing terminal it drains again before returning, so events appended between
the preceding page and status read are not lost. Neither path invokes `run`,
`cancel`, `abandon`, or any device operation.

Every unary request has a fresh response-matched transport ID. JSONL rows share
the invocation's `controlRequestId`, have invocation-local sequence numbers
starting at 1, and end with exactly one terminal frame. The terminal carries
the exact process exit code and the last delivered event cursor, or null if no
Runtime event was delivered. A failed/cancelled terminal Job retains its result
with `ok:true` and exit 1. Timeout, human action, and unknown outcome use
`ok:false`, exit 75; SIGINT uses exit 130 without cancelling the Job. An error's
bounded details also retain the polling cursor for a call that saw no new row.

An explicit timeout is one continuous/UTC budget across negotiation, reconnect,
reads, and backoff, capped at 24h. Without an explicit overall timeout, each
unary exchange is bounded to 30s and the observer remains open. SIGINT can stop
a stalled read without waiting for that 30s deadline. Transient connection
unavailability gets at most two retries with the same exclusive cursor.

Unmodified `job wait` human/JSON calls retain their legacy snapshot behavior;
JSONL, cursor/page flags, or `--require-protocol 2` select the new event path.
The final default-v2 migration is a separate remaining product slice.

## Validation and remaining scope

Contract tests cover origin/exclusive/per-row continuation, cross-Job/forged
cursors, key privacy, torn/completed corruption, retention failures, more than
1000 events, large redacted projections, Runtime restart, strict page decoding,
and real CLI subprocess wait/watch/timeout/SIGINT/failed-terminal behavior on a
synthetic typed provider. They also prove observation does not add dispatches.
These are host tests, not `REAL_DEVICE_PASS`.

The full CLI is not complete: fixed Job list snapshots, remaining resource
lifecycles, Job/control-action HAR ownership, machine-contract bundle export,
default-v2 migration, and protected-main GJ-1–GJ-5 real-device acceptance remain.
