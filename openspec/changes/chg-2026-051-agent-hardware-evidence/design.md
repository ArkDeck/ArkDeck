# CHG-2026-051 r6 Design — Production evidence preflight

## 1. Why r1 cannot reach production

The production daemon has exactly one `HDCObservationFactsPort` implementation:
`TargetStoreFactsPort`. Its current record contains target ID derivation inputs, binding revision,
connect key, adopted tool version and adoption time. It does not contain model, firmware,
transport or a same-operation observation time. Treating `utcNow()` at record read as a device
observation would launder cached adoption data into a fresh fact and is forbidden.

The current operation plans also cannot establish all required facts:

- `observe.device@1/probe-device` only executes target-list observation;
- `capture.diagnostics@1/preflight-device-storage` reads only product model;
- `debug.hap@1` reaches its first E1 step without any device-fact preflight.

Therefore a fake facts port can exercise projector mechanics, but the shipped daemon cannot
produce a complete receipt. r2 closes that exact gap before implementation resumes.

## 2. Catalog sequence

Each of `observe.device@1`, `capture.diagnostics@1` and `debug.hap@1` SHALL contain this required
prefix before any evidence-bearing capture or E1/E2 step:

1. `confirm-evidence-target`
   - kind: `probeDevice`
   - effect: `readOnly`
   - binding: `confirmedDevice`
   - provider action: exact target-list observation and match
2. `read-evidence-model`
   - kind: `runApprovedRemoteRead`
   - actionRef: `arkdeck-remote-operations/deviceModel`
   - effect: `readOnly`
   - binding: `confirmedDevice`
3. `read-evidence-firmware`
   - kind: `runApprovedRemoteRead`
   - actionRef: `arkdeck-remote-operations/firmwareBuild`
   - effect: `readOnly`
   - binding: `confirmedDevice`

`debug.hap@1/package-readback` SHALL also gain its existing exact
`arkdeck-remote-operations/packageInfo` actionRef so the adapter never selects behavior from a
step ID. All added steps are required. An unavailable or unverifiable read fails the job before
capture or mutation; it is not an optional evidence-only leg.

These are breaking modifications to published version-1 operations and are intentionally carried
by this Core MAJOR change. No effect is lowered: the added steps are E0 and the operation's
existing maximum/effective effect remains unchanged.

### 2.1 Action-reference contract

The Catalog schema and generator currently reserve `actionRef` for `captureRemoteStdout`. The
production preflight must not work around that rule by inferring a remote read from a step ID.
They SHALL be extended as one closed contract:

- `captureRemoteStdout` continues to require an action from its existing stdout registries;
- `runApprovedRemoteRead` requires an action from `arkdeck-remote-operations`, whose registered
  `step_kind` is exactly `runApprovedRemoteRead`;
- every other step kind continues to reject `actionRef`;
- an unknown catalog/action, a cross-kind reference, or a missing reference on either supported
  kind fails validation and generation.

The generator continues to emit both `RuntimeOperationCatalogGenerated.swift` and
`Catalog/generated/effect-authorization-matrix.md`. Since the digest covers complete operation
semantics, both generated files change with the required prefix and travel in the implementation
PR.

### 2.2 Durable journal action registry

`WorkflowStep.runApprovedRemoteRead` separately validates the `catalogId` / `actionId` written
into every durable intent. Its Swift registry and `workflow-step.schema.json` SHALL both add
exactly `deviceModel` and `firmwareBuild` beside the five existing
`arkdeck-remote-operations` actions. The engine SHALL write the Catalog step's exact actionRef
into the journal; it must not substitute an older action, derive one from the step ID, or omit
the typed registry validation.

`WorkflowStepContractTests` SHALL prove both new actions construct valid
`runApprovedRemoteRead` steps and an unknown action remains rejected. No other WorkflowStep kind,
argument rule or effect/binding invariant changes.

### 2.3 Crash-window fixture parity

The existing process-level `ArkDeckEngineCrashFixture` remains the authority for
after-intent/before-dispatch and after-dispatch/before-outcome recovery windows. Its fake facts
port SHALL provide the same target ID, binding revision, stable identity and internal connect key
shape required by production preflight, and its request SHALL correlate the binding revision.
The dispatcher still stops at the first device preflight dispatch; marker timing, SIGSTOP/SIGKILL,
journal recovery and zero-redispatch assertions remain unchanged.

### 2.4 Generator implementation path parity

The r3 design already requires the stdlib Catalog generator to validate remote action references
and its tests to pin the positive/negative matrix. Both files are exact readiness pins, but the
task's Allowed paths omitted them. r6 adds exactly those two implementation paths. It does not
change the generator behavior, accepted registry, operation vocabulary or generated outputs
described in §2.1.

## 3. Exact target and provider lowering

Before provider action selection, Runtime resolves the target-store record through a product-owned
port and builds `ProviderExecutionContext` with:

- target ID and expected binding revision;
- internal connect key;
- stable identity SHA-256;
- tool version/hash.

The context is not caller-constructible and its connect key never enters receipt/evidence output.

For `confirm-evidence-target`, HDC parses the registered target-list family, selects exactly one row
whose connect key equals the durable target record, immediately hashes the serial/connect-key
identity inside the provider, and returns identity digest + transport in the semantic summary.
Zero matches, duplicate matches, unknown state/transport columns, identity mismatch or binding
drift fail closed.

For `deviceModel` and `firmwareBuild`, the adapter maps the exact actionRef to the existing closed
properties `const.product.model` and `const.ohos.fullname`. Lowering uses argument arrays:

```text
["-t", <durable-connect-key>, "shell", "param", "get", <closed-property>]
```

No shell fragment, caller property, default-target fallback or raw command surface is added.

## 4. Durable observation assembly

The job record stores an optional evidence-preflight accumulator for backward decoding:

- exact job/target/binding;
- stable identity digest and transport from confirmed target-list outcome;
- model and firmware from the two property outcomes;
- provider/tool identity;
- the three step IDs/kinds and their durable outcome timestamps.

Each fragment is written only after its own confirmed journal outcome. The accumulator becomes a
complete `RuntimeEvidenceObservation` only after all three fragments correlate. Runtime checks the
complete observation before the next evidence-bearing capture or any E1/E2 step. Missing or
mismatched fragments fail before that step; they do not merely fail the later projector.

Legacy job/target documents decode with absent optional V3 fields. They remain readable and
evidence-ineligible. No migration derives freshness from adoption time, target ID or cached tool
version.

## 5. Receipt and artifact projection

The daemon exposes a read-only `job.evidence` query combining:

- durable job/effect/authority/step/observation facts;
- immutable artifact metadata;
- a just-in-time re-hash of controlled artifact bytes.

The Agent runner decodes this response into `RuntimeAgentExecutionReceipt`. The pure projector
accepts that receipt plus only `evidenceId`, `acceptanceIds`, `validUntil` and `notes`. It cannot
reach provider dispatch, target store or capability store.

Any required-field absence, stale timestamp, job/target/binding/provider mismatch, authority/effect
mismatch, unknown outcome, non-execute mode, missing artifact or byte/hash mismatch produces
`evidenceIncomplete` with publication count zero.

## 6. Compatibility and rollback

- Current V2 evidence bytes are never rewritten; a versioned reader may continue to read them.
- V3 is the sole new writer after the implementation PR is merged.
- Existing target/job JSON decodes with absent optional V3 fields.
- Reverting the implementation PR restores V2 + blocked Agent evidence behavior as one unit.
- No implementation in this change may alter E2 authorization policy or mint a capability.

## 7. Production-shaped fixtures

The descriptor-bound fake HDC executable accepts only the two new exact property argv shapes,
including `-t <fixture-connect-key>`, and returns distinct bounded model and firmware values. It
rejects a missing/altered target selector and unknown property. The Runtime contract test resolves
that executable through `FixedExecutableResolver`, so lowering, executable identity verification,
argv dispatch and semantic parsing all run through the production composition shape with no real
device.

Existing diagnostics/HAP orchestration tests gain only the three required preflight outcomes and
durable target facts needed by the breaking Catalog prefix. Their original partial-success,
readback-only success and capability assertions remain unchanged.
