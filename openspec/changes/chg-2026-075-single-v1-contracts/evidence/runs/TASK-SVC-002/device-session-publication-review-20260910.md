# Device Session publication repair review

## Measured failure

GJ-4 Job `job-668735b572ec56dd44120abe9e428e36` completed successfully on
2026-09-10. All three flash artifacts passed full byte-count and SHA-256 readback,
and the subsequent observe Job succeeded. Its Session publication failed with
`sourceIntegrityFailed`. Read-only inspection of its durable publication marker
returned this exact reason:

> device-bound Session publication needs target and toolchain facts this Job record does not carry

`RuntimeSessionManifestComposer.manifestTarget` currently refuses every device
branch. The delivered 2026-09-08 implementation explicitly describes itself as a
host-only subset. The current record does contain a machine observation, exact
provider version/digest, binding revision, materialized identity/plan and Runtime
admission correlation. Its original Journal carries matching device targets and
confirmed intent/outcome pairs. These facts must be checked, not replaced by the
currently attached device or by user-supplied evidence.

A new fixture-backed real Engine/Journal/Session-owner test reproduces the failure:
the device Job succeeds but publication remains failed and Session count stays 0.
Log: `/private/tmp/svc002-device-publication-before-2.log` (two failed assertions).
This is a host contract test, not hardware evidence.

## Approved implementation boundary

The user explicitly approved this boundary on 2026-09-10. Implement the existing TASK-SVC-002 Session slice in these exact
areas, followed by ordinary maintainer PR review:

- `RuntimeSessionPublication.swift`: derive device Session audit data only from
  the same durable Job and its Journal after all checks below.
- `Storage/SessionManifest.swift` and `openspec/contracts/manifest.schema.json`:
  add one closed `runtimeProvider` toolchain shape and its required
  `runtimeAuthority` audit object; keep existing shapes strict.
- `RuntimeJobEngine.swift`: allow the existing typed `job reconcile` to retry
  only a confirmed terminal Session failure that provably stopped before any
  publication seal. This branch must not dispatch a Provider or replay the Job.
- `Storage/RetentionAndExport.swift`: preserve structural audit vocabulary while
  applying the existing default identity redaction. Exported audit data is not
  Runtime authority.
- Existing contract tests and Session documentation: positive, refusal, restart,
  exact readback/export and no-dispatch regression coverage.

All implementation paths are within the base TASK-SVC-002 allowlist. This review
neither broadens TASK-XPA-003 nor changes Task approval/status by itself.

### Closed data shapes

`toolchain.kind = runtimeProvider` contains exactly `kind`, `providerIdentity`,
`profileIdentifier`, `reportedVersion`, and `sha256`. Provider identity is limited
to the already published `hdc` and `arkforge` Providers. This is recorded audit
metadata, not a new Provider, device profile, transport, tool selection or caller
input. In particular, an ArkForge tool digest cannot be mislabeled as an HDC
server snapshot.

The required `runtimeAuthority` contains exactly `kind`, `reference`,
`admittedAtUtc`, `validUntilUtc`, `consumptionFingerprintSha256`, `reservationId`,
`useOrdinal`, `planDigest`, `stepSetDigest`, `targetBindingDigest`, and
`artifactDigest`. It is copied from the existing Runtime-owned admission evidence:

- `defaultReadOnlyPolicy`: no mutation intent and no capability-consumption fields.
- `runtimeCapability`: existing consumption fingerprint, reservation, ordinal and
  exact plan/step-set/target correlation are required. Missing consumption is not
  replaced by an interactive actor, a confirmation, a generated capability or a
  claim that no mutation happened.

No change to Runtime capability generation, reservation, consumption, recovery,
Provider coverage or hardware evidence is permitted. This metadata cannot become
an input to admission.

### Required proof and refusal conditions

The composer must match the request target and binding revision, any materialized
identity/plan, verified observation and every device intent (including compensation
intents). The opaque address is copied from those original Journal targets;
no current-device lookup or invented address is allowed. Tool identity must be
nonempty and digest-valid; confirmed machine readback must belong to this Job's
execution interval. Conflicting targets, revisions, keys, tool facts, missing
outcomes, unknown outcomes or missing admission correlation refuse publication.

The Manifest-to-Journal validator must cross-check the derived binding against
the original targets, identities and revisions. Mutation/compensation rows require
consumed Runtime capability audit. No existing binding, source-integrity or
unknown-outcome requirement may be disabled to admit the new shape.

Recovered Jobs stay unsupported until their separate complete recovery audit can
be expressed; they cannot be converted to ordinary success by this repair.

### Historical retry boundary

A historical failed publication is eligible only if it has a current ownership
marker, a confirmed pre-seal failure, no receipt/proposal/Journal seal/Session-root
identity, and a certain terminal Job with a complete clean original Journal.
A missing marker, an unresolved outcome, a partial publication or an identity/root
mismatch remains refused. Existing `published` receipts are returned unchanged.

The owner may append its normal final publication record after proving the
original history; it must not rewrite prior Journal bytes or any raw Artifact.
Repeated/restarted reconciliation must preserve one Job, one Session receipt and
one catalog generation, with zero new Provider dispatches. If the GJ-4 historical
facts do not pass these checks, retain the original error rather than reflash.

## Validation and delivery

1. Device Job -> Session publication and exact catalog/Manifest/Journal readback.
2. HDC and ArkForge audit fixtures, including a consumed destructive-authority case.
3. Missing/mismatched observation, binding, tool, plan, consumption and outcome cases.
4. Retry, repeated retry and restart: zero additional dispatch and no duplicate
   Session/catalog receipt; no adoption of markerless or partially sealed history.
5. Default export redaction remains valid and carries no raw device identifiers.
6. Unified local gate and path preflight, then a TASK-SVC-002 implementation PR.
7. After maintainer merge, deploy the new protected-main reader and use the typed
   publication retry; no new flash. An older reader cannot read the new Manifest
   branch, so do not publish live entries during a temporary installation that
   restores that older reader. Validate copied historical source offline first.

The automatic approval reviewer initially required explicit approval of the
validation boundary; the user supplied that approval on 2026-09-10 before the
validator/schema edits. Ordinary maintainer PR review is still required.
No live Runtime state has been edited, no repair helper installed, and no device
Job replayed.

The existing Runtime uses `runtimeE2Admission` for ArkForge `flashPartition`
and `runtime-capability-admission` for HDC `runApprovedRemoteMutation`. Those
exact typed labels resolve only when the new branch has a complete validated
consumption audit for the matching Provider. Other confirmation references
retain their existing same-Step interactive-confirmation requirement.

## Host validation record

Base: `d4e68f2e74b5f94f1791d2c57aaca5871f766fd6`.

- `RuntimeDeviceSessionPublicationContractTests`: all 8 tests passed, including
  original HDC publication, ArkForge consumption/destructive-Manifest fixtures,
  missing/conflicting facts, unknown outcomes, default export, zero-dispatch
  retry/restart and refusal of markerless/partial/unknown publication history.
- The opt-in historical-source test read the completed GJ-4 Job, composed its
  Manifest, and published a copy of its Journal through an isolated Session
  owner. The original Journal bytes remained unchanged. This proves the
  historical source can satisfy the repair; it is not a new live publication
  or hardware-acceptance claim.
- Independent Draft 2020-12 validation accepts the synthetic HDC, ArkForge and
  redacted Manifests and rejects 11 malformed audit/provider variants.
- The first complete gate found an existing privacy-refusal regression in
  `testDiagnosticExportRefusesAnArgumentItCannotRedactSafely`. Preserving all
  action/catalog constants was too broad and was removed. Only the new Runtime
  snapshot's four fixed field names are structural; their values, arbitrary
  keys and legacy snapshots retain the original redaction rules. All 8 new
  tests plus that unchanged privacy test now pass (9 total, zero failures).

Targeted log: `/private/tmp/svc002-device-tests-12.log`.
Schema fixtures: `/private/tmp/svc002-device-schema-fixtures` (synthetic only).
The test accepts `ARKDECK_DEVICE_SESSION_SCHEMA_FIXTURES` to regenerate these
samples, and `ARKDECK_HISTORICAL_DEVICE_JOB` to opt into the read-only historical
copy check. Neither environment setting is needed for the ordinary test suite.

Final complete local gate: **PASS**, exit 0 on 2026-09-10, log
`/private/tmp/svc002-device-final-gate-2.log`:

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

The selected lanes passed SDD/common checks, Catalog generation, 83 design-system
interaction tests, the full Swift lane (2,531 parallel cases plus the separately
serialized process-identity and 5 viewer-scale tests), and App/UI-test-bundle
`build-for-testing`. Python used the existing environment with PyYAML/jsonschema.
The historical-copy test was explicitly enabled for this local run. No App UI
assertions were run for this storage repair; no visible App behavior was changed.
The path probe accepted all 9 changed files against the protected-main Task;
the commit-specific preflight is run before push.

Live status remains unchanged: the original GJ-4 Job succeeded and its original
publication failure is retained until the new reader is reviewed and deployed.
No new flash or real-device pass is claimed by this repair.
