# CHG-2026-050 Design — typed diagnostics stdout closure

## Context and constraints

- Approval input:CHG-2026-050 revision 2
- Core baseline:CORE-2.1.0
- Related authority:`REQ-WF-001`、`REQ-JOB-002`、
  `POL-WORKFLOW-001`、workflow-step schema、operation Catalog
- Current failure:Catalog step kind is valid, but its intended HiLog action
  cannot be encoded by the only permitted stdout catalog/action arm.
- The design must not add a generic remote command surface or change operation
  effect/authorization semantics.

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| `REQ-WF-001` / `AC-WF-001-01` | closed actionRef and unchanged forbidden-field checks | existing free-command negatives |
| `REQ-WF-001` / `AC-WF-001-02` | Catalog actionRef + recipe registry + schema/Swift parity | generator negative matrix and construction tests |
| `REQ-JOB-002` compatibility | actionRef becomes durable `catalogId/actionId` arguments before dispatch | WorkflowStep construction + journal contract regression |

## Architecture and data flow

```text
Catalog operation step
  { kind: captureRemoteStdout, actionRef: catalog/action }
          │
          ▼ generator validates pair against recipe registry
generated CatalogStepDescriptor(actionRef)
          │
          ▼ Runtime resolves only typed operation inputs
WorkflowStep(arguments: catalogId/actionId/parameters/artifactId)
          │
          ▼ JSON Schema + Swift validator agree
durable journal intent
          │
          ▼ existing authority/effect/binding gates
descriptor-bound provider dispatch
```

`stepID` remains an audit/order identifier. It is not an action selector and
Runtime must not infer HiLog/UI Dump from naming conventions.

## Data and contract changes

`CatalogStepDescriptor` gains:

```swift
public struct CatalogActionReference: Equatable, Sendable {
  public let catalogID: String
  public let actionID: String
}
```

The property is optional at the value-type level only because most existing
step kinds are not catalog-backed; the Catalog validator makes it required
exactly for `captureRemoteStdout` and forbidden for all other kinds in this
change.

New `diagnostics-stdout.yaml` is a closed recipe registry:

- `boundedHilog`:duration, validated filter list and byte budget;
- `componentTree`:bounded stdout UI dump.

The workflow-step schema adds a second exact arm beside the unchanged
`arkui-ui-dump` arm. Swift validation switches on catalogID and accepts the
same action set. Unknown catalogs/actions remain invalid.

## Authority and production reachability

- Production composition root:`RuntimeOperationCatalogGenerated.swift`,
  consumed by `RuntimeJobEngine`.
- Authority point:unchanged; E0 default policy/E1 capability is resolved by
  the existing engine before provider dispatch.
- Effect dispatch point:unchanged descriptor-bound dispatcher, after durable
  typed intent.
- Fake/simulation difference:this change tests construction and validation
  only; no positive hardware/effect claim is made.
- Facts/provenance:actionRef is produced only by reviewed Catalog bytes and
  generated deterministically. The operation caller cannot provide or replace
  it.

## Failure, cancellation, and recovery

- Missing/unknown/misplaced actionRef fails Catalog generation.
- Schema/Swift mismatch fails contract parity before merge.
- Runtime parameter validation failure occurs before journal intent and
  dispatch.
- Cancellation and recovery graphs are unchanged. Once a valid intent exists,
  existing stdout cancellation and journal outcome rules apply.

## Security and privacy

- No executable, argv, shell, command or remote-path field is introduced.
- HiLog filters remain bounded typed tokens, not command fragments.
- No raw device artifact is produced by this change.

## Alternatives and ADRs

- **Hard-code stepID → action in Runtime**:rejected; action identity would be
  absent from the single Catalog source and drift would recur.
- **Reuse a UI Dump actionId for HiLog**:rejected; journal and recovery evidence
  would be false.
- **Make catalogId/actionId arbitrary strings**:rejected; it recreates an
  unreviewed remote-command namespace.
- No ADR is needed:the change completes the existing closed typed-step
  architecture rather than introducing a new long-lived architectural choice.
