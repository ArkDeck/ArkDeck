# CLI candidate display names

`arkdeck device display-name set/clear` manages a bounded local presentation
name for one exact, unadopted device observation. The Runtime owns the resource;
the CLI never writes an App preference, target binding, provider record, Job,
or device state.

```text
arkdeck device display-name set \
  --candidate <key> \
  --observation <id> \
  --observation-generation <n> \
  --name <text> \
  --output json
arkdeck device display-name clear \
  --candidate <key> \
  --observation <id> \
  --observation-generation <n> \
  --output json
```

Both commands use the current v1 control contract. A successful mutation returns
`arkdeck.candidate-display-name/1` with the exact candidate key, observation
ID, next observation generation, name or `null`, and update time. Names must
already be Unicode NFC, have no leading or trailing whitespace or control
characters, and occupy at most 256 UTF-8 bytes.

The three-part observation reference is the compare-and-swap token. A name
mutation advances the complete observation snapshot generation, so every
later mutation or adoption must use the newly projected generation. A stale,
replaced, already adopted, or otherwise unproved observation returns
`resourceConflict` with `newDispatchCount: 0`. An ambiguous publication stays
`outcomeUnknown`; the caller must read a fresh `device candidates --snapshot`
before deciding what to do next.

Candidate names never participate in identity, selection, binding, admission,
or provider routing. They expire when observed device facts drift, the
candidate relation can no longer be proved, or Runtime restarts. The next
observation cannot inherit a name from a reused connect key.

During `target adopt`, Runtime re-observes the exact physical relation, stages
the candidate name in the prospective durable target resource, publishes the
binding, and then removes the candidate record. An existing nonempty durable
target name wins. A publication failure leaves enough staged state for an
exact retry or restart reconciliation; it never exposes a new target without
its migrated name. The App still has a legacy `UserDefaults` presentation path
and does not yet consume this owner, so this slice claims the Runtime and CLI
contract only.
