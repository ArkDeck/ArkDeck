# Exact CLI device observation and adoption

Task: TASK-AIN-021

This GJ-1 slice adds a negotiated target adoption path without changing the
published 1.x discovery or automatic legacy adoption behavior.

```text
arkdeck device candidates --require-protocol 2 --output json
arkdeck target adopt --candidate <key> --observation <id> --observation-generation <generation> --output json
```

The first command returns `arkdeck.device-observations/1` with a decimal-string
snapshot generation, observation time, health, and observed candidates. Copy
the exact candidate key, observation ID and generation into adoption. An
unchanged set of independently proved facts retains its generation. A state
change advances the generation while retaining the observation ID only when
the same USB attachment relation is still proved.

The Runtime brackets typed HDC enumeration with IOKit USB observations. For
the existing registered DAYU200 HDC-normal profile, proof includes the
device-provided USB serial, location, vendor/product and registry entry ID for
the attachment. The registry ID is a connection-lifetime fact, not a durable
target ID. Neither address equality nor a hash of an address creates proof.
Duplicate routes, absent identity, unsupported modes/transports and failed
observations cannot bridge continuity. This introduces no new device profile.

Adoption requires the exact current snapshot, repeats observation, reads the
tool and selected device through the existing typed provider, and verifies the
USB relation again before writing the target. Generation drift returns
`resourceConflict`; identity drift during final readback returns `factsDrifted`;
an unauthorized candidate returns `targetTrustPending`; unproved identity is
`admissionDenied`. These refusals include their exact observation reference and
Runtime-owned pre-admission/zero-dispatch details. There is no ownerless HAR,
default first-device selection, device mutation or new Job. Existing target
identity and cross-mode alias lineage remain owned by the current store.

`target adopt` always negotiates major 2. The explicit discovery option cannot
be combined with legacy `--snapshot` or `--use-warm-snapshot`. Omitting it keeps
the original 1.x behavior; those generation-scoped legacy IDs do not authorize
v2 adoption. Only the new table adds `device.observations` and `target.adopt` to
the initial negotiated health surface. Structured target errors retain their
actual protocol version in JSON metadata. A missing/malformed adoption receipt
is an unknown outcome, never an invented success or a retry.

Tests cover local socket/CLI round trips, trust transitions, exact-generation
refusals, duplicate/unproved candidates, same-key attachment replacement,
mid-read identity drift and observation failure. They use injected fixture
sources and do not establish real-device acceptance. The public `device wait`
leaf, Runtime-owned AgentExecution/HAR and full portable CLI contract bundle
remain unfinished follow-up capabilities.
