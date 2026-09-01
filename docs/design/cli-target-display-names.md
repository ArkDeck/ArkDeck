# CLI target display names

`arkdeck target display-name set/clear` manages the local presentation name of
one active durable target. The resource is owned by the Runtime and shared by
the App and CLI; callers do not write `UserDefaults`, the target binding
document, or a private App directory.

```text
arkdeck target display-name set \
  --target <id> --expected-generation <n> --name <text> --output json
arkdeck target display-name clear \
  --target <id> --expected-generation <n> --output json
```

Both commands require control protocol 2 and return
`arkdeck.target-display-name/1` with the exact target ID, the next generation,
the name or `null`, and the update time. The initial resource has generation
`1`, no name, and no update time. Names must already be Unicode NFC, must not
have leading or trailing whitespace or control characters, and are bounded to
256 UTF-8 bytes.

Mutation uses compare-and-swap. A stale generation returns
`resourceConflict`; an unknown or inactive alias returns `resourceNotFound`.
Ambiguous publication failures remain `outcomeUnknown` and are not safe to
retry without first reading `target show`. `target list` and `target show`
project `displayName` and `displayNameGeneration` beside existing binding
fields. Setting or clearing a name never changes target identity, binding
revision, connect key, provider facts, selection, admission, or device state.

This slice covers durable target names only. Candidate display names and their
proof-bound migration during adopt remain a separate product slice because
they are scoped to an observation ID and snapshot generation rather than a
durable target identity.
