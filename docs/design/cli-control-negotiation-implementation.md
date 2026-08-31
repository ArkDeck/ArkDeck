# CLI control protocol negotiation

Task: TASK-AIN-021

This GJ-1 slice lets callers check the Runtime's exact protocol compatibility
before attempting resource operations whose target contracts cannot preserve
the published 1.x shape. It does not change an existing operation, identity
policy, provider, or destructive admission rule.

```text
arkdeck runtime health --require-protocol 2 --output json
arkdeck runtime health --require-protocol 1 --output json
```

The client sends the version-neutral `protocol.negotiate` frame first. Both
peers validate the closed bootstrap shape, request identity, canonical numeric
SemVer list, requested major, and highest common exact version. Bootstrap
frames are limited to 65,536 bytes including the final LF. Duplicate JSON keys,
invalid UTF-8/Unicode, extra fields, and cross-major selection are refused.
Negotiation errors carry `newDispatchCount: 0` in CLI details; no domain request
has been sent. A negotiated success reports the actual version in both health
and `meta.controlProtocolVersion`.

Omitting `--require-protocol` preserves the direct 1.0.0 health call. Explicit major 1
also supports the pre-bootstrap daemon's exact `malformedFrame` refusal, and
only for methods in the generated legacy fallback table. Major 2 never falls
back. A timeout, malformed reply, or arbitrary error is not a downgrade signal.

The daemon retains the original 1.0.0 health shape and App/XPC behavior. The
2.0.0 table initially publishes **health only** and reports `publishedMethods`.
Other methods, including `target.adopt` and `job.submit`, are rejected before
their handlers on 2.0.0. Advertising the wire format is not a claim that all
target CLI contracts have been implemented. Existing leaves continue using
their published 1.x behavior until their own vertical migrations land.

The language-neutral vocabulary is
`Packages/ArkDeckKit/Contracts/control-negotiation.json`; its generated Swift
projection is checked against that file in contract tests. Regenerate with
`python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py`, or pass
`--check` for a read-only drift check. The package-local location respects this
Task's path guard; it is not a replacement for the final full CLI contract
bundle required by product spec §14.

Host tests exercise real local sockets with fixture daemons and the CLI parser.
They prove protocol behavior, not real-device execution or Golden Journey
acceptance. Observation-bound adoption and Runtime-owned AgentExecution/HAR
remain separate unfinished product capabilities.
