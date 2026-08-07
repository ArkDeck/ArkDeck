# r5 Design — remove the E2 authority lane without lowering destructive effects

## Decision shape

The selected design removes the separate human-authority lane, not the risk label:

```text
typed execute request
  -> protected-main Catalog lookup
  -> complete plan-only materialization
  -> trusted target/binding + archive/artifact facts
  -> Runtime-generated exact RuntimeCapability
  -> durable use reservation + fresh readback
  -> typed Provider dispatch
  -> durable outcome + postflight/recovery classification
```

No edge in this graph accepts an authority/capability object from the caller. A request expresses
intent; the Runtime owns admission facts and the single component allowed to mint/consume the
safety capability.

## What is removed and what remains

| Concern | r4/current | r5 candidate |
| --- | --- | --- |
| Destructive effect | `WorkflowEffect.destructive` | unchanged |
| Per-run human authority | standing authorization or same-session campaign | removed |
| Catalog policy | `oneShotExactPlan` | unified RuntimeCapability policy |
| Capability issuer | maintainer PR/campaign broker | protected-main `runtimeDefaultPolicy` |
| Exact target/plan/archive pins | authority + Runtime | Runtime-owned capability + trusted facts |
| Attempt bound | campaign: 16 / 4h / concurrency 1 | Runtime invocation: 16 / 4h / concurrency 1 |
| Unknown/unsafe replay | forbidden | unchanged |
| Evidence writer | standing/campaign provenance | RuntimeCapability provenance |
| Legacy bytes | decode/export | decode/export only, never migrated |

## RuntimeCapability envelope

For `destructive`, the generated envelope SHALL contain or cryptographically bind:

- published operation ID/version and Catalog digest;
- stable physical identity digest and current binding revision;
- exact typed-input map, including optional-field absence;
- materialized plan and ordered Step-set digests;
- archive/Artifact lease IDs and content digests;
- provider/tool identity needed by the plan;
- issue/expiry, maximum uses, concurrency key and lineage tip.

The Runtime produces the envelope only after plan-only materialization succeeds. It atomically
reserves a use before the first external effect and records the Job/reservation linkage. The caller
may reference the request/Job, but cannot pass an encoded capability or override any envelope
field. A capability created for one operation, target, binding, input, plan or Artifact never
matches another.

For a one-shot request, `maximumUses` is one. A closed automated repair/verify invocation may use
up to sixteen lineage-linked reservations within four hours, but each next reservation requires
the preceding attempt's durable `safeToReflash` classification. This budget is a Runtime safety
limit and does not restore a user-confirmation authority.

## Candidate and broker boundary

Source candidate and repairer remain in task-owned isolation with no device transport, Runtime
socket, capability store or authority bytes. They may produce a bounded build/test result and a
closed strategy. Only the protected-main broker may materialize an executable plan and reach the
Provider. Candidate drift invalidates derived facts; it never causes the broker to accept caller-
supplied argv or a new operation.

This boundary intentionally means unmerged code cannot silently replace the device executor. A
UI or client candidate may exercise the already-published Runtime contract; a Provider/Runtime
fix must be reviewed and merged before it can touch the device.

## UI semantics

The product may keep a destructive-impact sheet so a human understands userdata loss. Its button
is a UX acknowledgement only. It SHALL NOT emit `standingAuthorization`,
`evolutionCampaignConfirmation`, an AUTH-ID or any capability fields, and a headless Agent request
SHALL NOT wait for the sheet.

The standalone `manual_ui_flash.swift` driver remains outside Xcode UI test targets and default
test discovery. It may be invoked only during an explicit real-device validation window and must
report the real Job/Session/Artifact result rather than treating UI navigation as success.

## Compatibility and migration

1. Keep V1-V4 evidence and historical authority stores immutable.
2. Retain decoder/export representations for `standingAuthorization`,
   `evolutionCampaignConfirmation` and one-shot `chatConfirmation`.
3. Remove those kinds from every new admission/reservation/writer path.
4. Never convert an active or unconsumed legacy record into RuntimeCapability.
5. Emit hardware-evidence V5 for new mutation/destructive Agent runs.
6. On downgrade, reject r5 RuntimeCapability records for E2 admission; use durable Job state only
   for fail-closed recovery inspection, never replay.

## Rejected interpretations

- **Rename E2 but preserve the same standing/campaign gate:** rejected because it does not remove
  the automation blocker requested by this revision.
- **Relabel Flash as deviceMutation/readOnly:** rejected because it hides real userdata and
  partition effects and violates Core minimum effect semantics.
- **Let callers supply capability JSON or trusted digests:** rejected because it collapses the
  anti-forgery boundary.
- **Remove identity, journal or unknown-outcome rules with E2:** rejected because those prevent
  wrong-target writes and unsafe replay independently of human authorization.
- **Treat UI confirmation as the replacement authority:** rejected because headless automation
  would remain blocked and UI text cannot be a trusted Runtime fact.

## Risk accepted by approval

After r5 implementation, a syntactically and semantically valid request to the local protected-
main Runtime can cause destructive effects without a distinct human approval for that plan. The
remaining controls prove *what* operation, bytes and target are being executed and stop uncertain
recovery; they do not prove that a human intended this particular execution. Maintainer approval
of r5 explicitly accepts that loss of per-run intent proof in exchange for autonomous GJ-4 loops.
