# Change Design

## Context and constraints

- Change: `CHG-2026-058-arktrace-summary-analyzer@r1` (`proposed`).
- ArkDeck audit baseline: `60bfa76d6fba3ff1ea9abad031aefa077f5fbbfe`.
- Core baseline: `CORE-3.0.0`.
- Existing public contract: `analyzer.summarize-trace@1`; its descriptor is immutable in this
  change.
- Cross-repository input: ArkTrace signed CLI distribution manifest format 1, JSON contract 1.0,
  arm64/macOS 14+, product 0.1.0 build 1. Final implementation pins an exact reviewed artifact,
  not a source checkout or mutable path.

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| ATI-REQ-001 / ATI-AC-1 | Existing Catalog descriptor remains unchanged | blob/hash lock + generator tests |
| ATI-REQ-002 / ATI-AC-2,3 | `ArkTraceSummaryAnalyzerProfile` + action-specific resolver | profile/order/drift negative matrix |
| ATI-REQ-003 / ATI-AC-2 | operation-specific availability probe | manifest + doctor fault injection |
| ATI-REQ-004 / ATI-AC-4,5,6,7 | lease revalidation, fixed lowering, envelope validator, exact Artifact publisher | argv/receipt/persistence/restart tests |
| ATI-REQ-005 / ATI-AC-5,8 | existing host-only dispatcher/job lifecycle | cancellation/restart/no-route tests |

## Architecture and data flow

```text
owner-only versioned install directory
  └─ distribution-manifest.json (exact descriptor pin)
       ├─ Contents/MacOS/arktrace SHA/CodeDirectory
       ├─ TraceStreamer SHA/manifest/provenance
       └─ JSON contract 1.0 + product/build/layout/signing/notary facts
                  │
                  ▼
ArkTraceSummaryAnalyzerProfileLoader
  ├─ physical containment / closed schema / exact identities
  ├─ descriptor-bound copy to daemon-private tree-SHA generation
  ├─ fixed analyzerRef = trace-summary@1
  ├─ fixed argv = summary --json + reviewed limits
  └─ bounded doctor --self-test --json
                  │
                  ▼
AnalyzerProvider.runtimeAvailability(operation)
                  │
immutable sourceArtifactRef lease ──revalidate──┐
                                                ▼
AnalyzerInvocation(trace-summary@1) → action-specific executable resolver
                                                │
                                                ▼
DescriptorBoundProcessDispatcher (identity-bound spawn, bounded stdout)
                                                │
                                                ▼
ArkTraceSummaryEnvelopeValidator
  ├─ JSON 1.0 / tool / command / result kind
  ├─ envelope trace SHA == leased source SHA
  ├─ parser/tool/request/limits provenance complete
  └─ no path-bearing or human diagnostic fields
                                                │
                                                ▼
exact validated bytes → trace-summary.json + Runtime Artifact metadata
```

### Profile ownership

The daemon consumes an administrator-selected descriptor that names an absolute physical
versioned distribution root and the SHA-256 of its `distribution-manifest.json`. The manifest
then names only closed relative paths. Requests carry neither root, manifest, executable nor
arguments. The loader walks every component without following symlinks, remeasures exact regular
bytes and copies the complete closed tree through retained descriptors into an owner-only daemon
state generation keyed by the full source tree SHA-256. Profile, doctor and dispatch paths refer
only to that private generation. Its creation, collision handling, publication and cleanup are
relative to one retained root fd, so replacing the public snapshot-root pathname or the external
install cannot redirect writes or rebind the active bundle namespace.

The profile snapshot includes:

- `analyzerRef = trace-summary@1` and a versioned integration profile ID;
- ArkTrace product version/build and JSON contract 1.0;
- absolute executable path derived from the verified root plus exact executable SHA;
- parser binary/manifest/provenance identities;
- fixed arguments and timeout/output limits;
- distribution manifest SHA, source revision/tree identity, signing/notarization identity.

The Runtime Job materializes this snapshot before dispatch. Upgrade selects a different verified
private generation atomically; an already materialized Job never switches executable or bundle
resources mid-flight. The source Artifact is separately opened and verified once, then exposed to
the child only through its stable device/inode alias with the descriptor retained until drain.

### Action-specific resolver

`RuntimeExecutableResolving.resolveExecutable(for:)` is already an action-level port, but the
current `AnalyzerExecutableResolver` does not override it and therefore falls back to one
provider-level entry built from `profiles.first`. The implementation SHALL override the action
method, extract only the closed analyzer case, select by `AnalyzerInvocation.analyzerRef`, and
cross-check the invocation SHA with the selected profile. Provider-level availability SHALL NOT
be used as the identity source for a specific action.

Crash and hilog registrations remain independent. Reordering profile input cannot change the
table or selected binary; duplicate analyzer refs and conflicting identities fail construction.

### Availability

Availability is a pre-admission, read-only decision with a bounded cache keyed by the complete
profile identity. It performs, in order:

1. descriptor/root/manifest physical containment and closed-schema validation;
2. exact tool/parser/manifest bytes, architecture, executable mode and supported JSON contract;
3. distribution signature/provenance policy facts required by the reviewed profile;
4. a bounded identity-bound `doctor --self-test --json --no-cache` execution;
5. exact doctor success envelope/tool/parser identity validation.

Any identity change invalidates the cache. Failure returns a stable reason such as not found,
manifest drift, contract mismatch, parser drift, tool drift or self-test failure. It does not
create a running Job, reserve authority or dispatch a summary process.

### Lowering and exact output

`AnalyzerProvider.action` continues to receive the Runtime-resolved Artifact lease. It rechecks
size and SHA through the existing immutable Artifact boundary immediately before materialization.
The provider owns every argument except the final source file path, which is appended as one
argument token. It cannot be parsed as an option or shell fragment.

The validator decodes the complete ArkTrace machine envelope, not just an arbitrary JSON value.
It binds request command/limits, tool/product/build, source trace SHA/size, parser provenance,
summary result kind and quality schema to the invocation/profile. It rejects truncation before
decode and rejects unknown/missing/extra schema according to ArkTrace JSON contract 1.0.

For Trace summary only, `RuntimeArtifactService` publishes the exact validated stdout bytes as
`trace-summary.json`; it does not replace them with the current generic key/value wrapper.
Runtime Artifact metadata separately records source and derived identities, request/limits,
profile/tool/parser identity and generation time. Time is metadata, not inserted into the
deterministic result bytes.

## Data and contract changes

- New internal `ArkTraceSummaryAnalyzerProfile`/descriptor reader and machine envelope validator.
- `AnalyzerExecutableResolver` becomes a closed `analyzerRef → ResolvedExecutable` resolver.
- Trace summary Artifact publication gains an exact-bytes path after successful validation.
- No new Catalog operation, no existing descriptor edit, no Core/spec baseline change.
- Existing durable `AnalyzerInvocation` fields remain decodable. Any added durable identity must
  be additive/defaulted or carried in provider-owned profile/job metadata with migration tests.

## Cross-repository compatibility matrix

| Boundary | ArkDeck requirement | ArkTrace distribution |
| --- | --- | --- |
| Operation | `analyzer.summarize-trace@1`, `sourceArtifactRef` only | CLI command `summary` |
| Machine contract | major 1, minor 0 | JSON contract 1.0 |
| Tool | action-pinned exact executable SHA | `Contents/MacOS/arktrace`, product 0.1.0 build 1 |
| Parser | exact signed binary + exact manifest/provenance | bundled TraceStreamer named by distribution manifest |
| Arguments | fixed `summary --json` + reviewed limits + one lease path | no caller argv, no PATH |
| Result | validated summary envelope, source SHA equal to lease | deterministic one-line machine JSON |
| Artifact | exact validated bytes + Runtime lineage | no generated timestamp in result |
| Platform | macOS arm64 | signed/notarized `LSBackgroundOnly` CLI App, macOS 14+ |

Minor contract upgrades require an explicit compatibility test and profile revision. Major,
unknown or missing contract versions are unavailable. Tool/parser bytes never float under the same
profile identity.

## Authority and production reachability

- **Production composition root**: `ArkDeckAgentDaemonMain`; an owner-selected descriptor is
  loaded once into the analyzer profile registry and an analyzer dispatcher.
- **Authority产生点**: not applicable. The operation is `hostOnly` under bounded default read-only
  policy and no RuntimeCapability is generated or consumed.
- **Effect dispatch point**: `DescriptorBoundProcessDispatcher` launches the exact identity-bound
  CLI after durable intent. Runtime records outcome and publishes through `RuntimeArtifactStore`.
- **Fake/simulation difference**: tests may inject descriptors and process receipts, but production
  only accepts physical signed-distribution bytes and the real identity-bound dispatcher. Fake
  success cannot establish production availability evidence.
- **Facts/provenance**: distribution facts come from independently measured installed bytes plus
  the reviewed manifest pin; source facts come from Runtime Artifact store/lease resolution;
  process facts come from identity-bound execution. The request cannot construct any of them.

## Failure, cancellation, and recovery

- Missing/drifted/incompatible profile: stable unavailable before submission.
- Lease missing/drifted: rejected before child dispatch.
- Nonzero, timeout, cancellation, signal or unknown wait: existing Runtime process outcome and
  reconciliation semantics; no guessed success and no blind replay of an unknown child outcome.
- Empty/truncated/oversized/malformed/mismatched output: failed Job, no derived summary Artifact.
- Crash between verified output and Artifact publication: exact Artifact bytes become durable
  before the correlated succeeded outcome. Restart may retain a complete Artifact with an
  outstanding read-only intent, but never a durable success without its required Artifact and
  never reruns based on absence alone.
- Upgrade: stage and verify a new complete versioned directory, then atomically select its profile.
- Rollback: select a retained prior descriptor only after full revalidation. Drift is unavailable.

## Security and privacy

- No shell, PATH, GUI automation, HDC, device binding, network or arbitrary environment.
- Executable and parser are selected by closed action/profile identity only.
- Physical path, cache root and source file path are execution-only and must not appear in machine
  result, durable action summary, Artifact metadata exported to Agent, or public diagnostics.
- Stdout/stderr and doctor diagnostics are bounded; failure messages use stable reason codes and
  sanitized summaries.
- Raw Artifact is immutable. Derived bytes are published separately with source hash lineage.

## Alternatives and ADRs

- **Rejected: create another summary operation.** The published operation already has the correct
  ownership and input/output shape.
- **Rejected: add optional context argv to summary.** This silently changes a published contract;
  deep analysis requires a separately reviewed typed operation.
- **Rejected: make all analyzers share `profiles.first`.** Crash/hilog and ArkTrace are unrelated
  binaries; provider-level selection makes profile order an authority input.
- **Rejected: invoke the ArkTrace GUI or shell wrapper.** It adds UI/shell authority and destroys
  deterministic argv/identity binding.
- **ADR need**: none outside this change. Versioned install/profile selection is fully specified
  here and in the ArkTrace distribution contract.
