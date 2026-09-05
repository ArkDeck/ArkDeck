# CLI History saved filters

`arkdeck history filter list/save/delete` manages the one saved query preset
shown by the macOS History workspace. Runtime owns the bounded local resource;
the App and CLI use the same control methods and neither client knows the
resource file path.

```text
arkdeck history filter list --output json
arkdeck history filter save \
  --expected-generation <n> \
  [--search <text>] \
  [--status all|active|needsAttention|succeeded|failed|interrupted|cancelled] \
  [--mode all|execute|planned|simulated|unknown] \
  [--session <id>] [--target <id>] \
  [--time anyTime|lastHour|lastDay|lastWeek] \
  [--activity all|flash|viewer|trace|diagnostics|debug|device|other] \
  --output json
arkdeck history filter delete --expected-generation <n> --output json
```

The CLI commands verify the current v1 control identity. `list` returns
`arkdeck.history-filter-list/1`, the current generation, and zero or one
`arkdeck.history-filter/1` record. An empty resource begins at generation `1`.
Omitted search, status, mode, time and activity options save their documented
`all`/empty defaults; omitted Session and target mean all identities and are
represented as JSON `null`. App-private sentinel strings never enter the
contract.

`save` and `delete` use compare-and-swap. Every successful mutation advances
the generation, including deletion; the deleted tombstone remains durable so
an old generation cannot become current again after recreation. A stale
generation returns `resourceConflict`, and deleting an already-empty resource
returns `resourceNotFound`. If publication loses its reply, the result remains
`outcomeUnknown`; callers read `history filter list` to reconcile and never
repeat the mutation blindly.

The store accepts one NFC search string of at most 512 UTF-8 bytes, bounded
Session and target identities, and only the closed enum values above. Its
document and lock must be owner-only regular files in the Runtime state
directory; reads fail closed on unsafe permissions, symlinks, malformed JSON,
or an excessive document. This resource changes no Job, Artifact, target
identity, binding, capability, provider fact, admission decision, host tool or
device state.

The macOS App loads, saves and deletes through the same owner, and reads no
App-local preference: a record left by an earlier build is ignored and the
screen shows the owner's own first-run state. UI-test mode uses an in-memory
implementation of the same typed protocol rather than AppStorage. Failed App
loads expose a read-only reload action. User mutations keep the resource
controls locked through their reconciliation read so a superseded reply cannot
replace newer state.
