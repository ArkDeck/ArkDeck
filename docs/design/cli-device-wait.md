# Waiting for one exact device observation

Task: TASK-AIN-021

The GJ-1 trust transition can now be waited for through the CLI after
[exact discovery](cli-exact-observation-adoption.md):

```text
arkdeck device candidates --output json
arkdeck device wait --candidate <key> --observation <id> --observation-generation <generation> --state connected --timeout 30s --output json
```

The only states are `connected`, `unauthorized` and `offline`, matching the
provider's `Connected`, `Unauthorized` and `Offline`. Waiting always verifies the current v1 contract identity and uses unary `device.observations` reads with the original
`following` reference. Even an already-matching state requires a fresh read.
The Runtime must prove the same physical attachment throughout; a replacement,
lost relation or reused key returns `resourceConflict`, never success for the
new device. There is no adoption, binding mutation, Job creation or ownerless
human-action resource.

Success returns `arkdeck.device-wait/1`: `snapshotGeneration` as a canonical
decimal string, `observedAtUtc`, the requested lowercase `state`, and the exact
`observation` row. This final generation is the one to use for a subsequent
explicit `target adopt`. The initial generation is never silently rewritten
into a new adoption request. Polling is not a resumable event stream, so
`--output jsonl` is not offered.

The default client timeout is 30 seconds; explicit durations accept the product
grammar from 1ms through 24h. One deadline covers contract identity verification, socket connect,
writes, all partial reads and poll backoff. Nonblocking socket IO uses the
remaining total budget rather than restarting a socket timeout after every
byte. A continuous clock prevents wall-clock rollback or machine suspension
from extending the wait; a forward wall-clock jump also ends it.

Expiration returns `clientTimeout`/exit 75 and the original observation
reference, with a last-observed generation only if a snapshot actually arrived.
It closes the client connection without adopting, cancelling, or changing a
Runtime operation budget. A typed transport deadline on a mutation-capable
method still maps to `outcomeUnknown`; it does not prove non-acceptance.

Tests exercise actual CLI/local-socket trust transitions, same-key replacement,
timeout with no target or Job creation, a silent peer, trickled partial frames,
and shared identity-check/request deadlines. All device observations are explicit
fixtures. This slice does not establish real-device acceptance, migrate legacy
`job wait` or all other commands to a global deadline, provide durable events,
or complete Runtime-owned AgentExecution/HAR.
