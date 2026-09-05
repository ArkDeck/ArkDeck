# Protected Flash invocation discovery

`arkdeck recovery flash-invocation list` rediscovers Runtime-owned protected
Flash recovery invocations after a client restart or lost receipt. It is a
bounded read-only resource. It cannot create an invocation, evaluate a
candidate, replay destructive intent, dispatch a device operation, or mint any
authority.

```text
arkdeck recovery flash-invocation list \
  [--page-size 100] \
  [--cursor <opaque-cursor>] \
    [--output json]
```

The CLI verifies the current v1 control identity and calls
`recovery.flash-invocation.list`. The request accepts only `pageSize` and
`cursor`; page size is bounded to `1...1000`, and a cursor is limited to 256
UTF-8 bytes.

The Runtime scans only its private `runtime-debug-invocations` owner. Every
record must be a private, same-user, single-link regular file with a bounded
size and a matching invocation identity. Each record is the current `1.0.0`
invocation document with exactly its published field shape; a record carrying
another label, or the same label over a different layout, is unreadable and
is never migrated or relabelled. An unknown directory entry, unsafe file,
corrupt or unreadable record, oversized inventory, foreign cursor, or
reclaimed snapshot fails closed. No caller path or archive path enters the
request.

The first request stores an immutable private snapshot ordered by
`createdAtUtc` descending and `invocationId` ascending. Later pages retain that
snapshot even if another invocation is created. The page schema is
`arkdeck.cli.page/1`; each compact row is
`arkdeck.recovery.flash-invocation-summary/1` and contains only:

- invocation ID and state;
- operation reference, target ID and binding revision;
- creation and expiry timestamps;
- used and maximum destructive epochs.

The list deliberately omits the seed request, typed inputs, candidate source
or build provenance, evaluation actions, free-form details and Job history.
After selecting one exact ID, callers use
`arkdeck recovery flash-invocation status --invocation <id>` for the complete
closed decision document.

Host fixtures prove pagination, snapshot stability, private projection and the
real CLI-to-daemon process path. They do not create device evidence or count as
real-device acceptance. The command itself performs no device work; hardware
acceptance remains attached to the protected Flash operation that created the
underlying Job.
