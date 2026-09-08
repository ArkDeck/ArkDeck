# GJ-1 observation diagnostics — 2026-09-08

Task: `TASK-AIN-021`.

Implementation base: `8151907bee9919a0847edc9a9aeb1f0ff84f6d15`, the protected
main that includes the reviewed unknown-Flash proof repair (#1766), GJ-2
compensation scope supplement (#1767), and current Job failure frame repair
([#1769](https://github.com/ArkDeck/ArkDeck/pull/1769)). This is a development repair record;
it does not establish the final SVC hardware acceptance baseline.

Before PR creation, the branch was rebased onto
`94ab36d45e00fec92a15673d3a655382b22577f7`. That main-only addition is the GJ-4
diagnostic document from #1765; no tested source, contract, fixture or build
configuration changed. The validation below remains applicable without repeating
the complete suite. The current Task path preflight was rerun after the rebase.

## Observed failure

The published `a076ca31ef97ef4285981af053d07b7fe0f052bd` Runtime could not
verify the current target list. `device candidates` returned only
`candidate list could not be verified`. Observation Job
`job-176e1924577288f076562d33b44c6e9f` retained the more precise
`target line is not the registered 5-column family` in its unknown-outcome
timeline, but neither resource identified the rejected line or its columns.
The failed step did not publish a target-list stdout Artifact. Those existing
records cannot establish which unregistered bytes the tool actually emitted.
See the [original SVC readback](svc-acceptance-2026-09-08.md).

The App decoder already preserved Runtime error messages. Its shell discarded
the reason in the sidebar and treated the failed observation's empty candidate
array as evidence that a selected device had gone away.

## Complete repair path

- The existing HDC target parser keeps its registered five-column grammar and
  every acceptance/refusal condition. Malformed-output reasons now identify the
  physical line, column count and at most 256 input bytes of the rejected row.
  Control, non-ASCII, quote and backslash bytes are escaped before the reason
  can reach a terminal or journal. Long rows state the truncation; apparent
  credential/private-key text is omitted from the preview.
- The production Bootstrap observation adapter moves unchanged typed dispatch
  wiring into the Workflows module so tests can exercise it. List and identity
  failures retain the bounded parser reason. Unverified tool-version text
  continues to produce a fixed error rather than exposing arbitrary tool text.
- `device.observations`, `target.adopt`, `agent.run`, `agent.resume` and
  `human-action.resume` preserve that reason through their existing control
  error. The code and details shape remain unchanged. Discovery exits 70;
  failed mutation/continuation clients retain `outcomeUnknown` and exit 75.
  A failed read probe is not a zero-dispatch receipt.
- The existing Job transition already persists the semantic reason. Job show,
  timeline and status remain readable after restart; no new event, Artifact,
  recovery proof or outcome is fabricated. The outstanding intent stays open.
- The App's existing XPC and facade preserve the same message. The sidebar now
  shows the bounded reason, with the complete text in its tooltip. Selected
  device detail shows a selectable reason and the existing Re-check action.
  A failed observation no longer claims that the device was unplugged.
  App adoption and XPC permissions remain unchanged.

This is bounded diagnostic prose, not a raw process receipt or retained Raw
Artifact. It does not broaden HDC grammar, classify unknown as non-execution,
or allow replay. Per-method schemas, control identity, generated contract,
Catalog and corpus are unchanged; their current message fields already allow
these diagnostics.

## Verification

Local evidence directory: `/private/tmp/arkdeck-svc-a-20260908`.

- Targeted parser, production Bootstrap/daemon/CLI, discovery and Job-read
  regressions passed: 74 tests (`hdc-focus-tests-retry.log`). Tests include both
  resume surfaces, fresh adoption checks, output boundaries and malicious
  bytes, restart/readback, retained outstanding intent and zero new dispatch
  during restart and reads. Additional credential-field suffixes were then
  added to the existing preview test and passed the complete suite.
- The first unified gate passed on base `6a8a06fc`: common checks, 2,465 parallel
  Swift tests, one serialized process-identity test, five Viewer scale tests,
  design-system tests and App build-for-testing (`hdc-unified-gate.log`).
- The first gate after the App repair exposed an existing Job failure schema
  gap. The complete producer/readback regression, affected method schemas and
  corpus were repaired together in #1769 and are now in this branch's reviewed
  base. The final unified gate passed on `8151907b`: common checks, 2,466 parallel
  Swift tests, one serialized process-identity test, five Viewer scale tests,
  83 design-system tests and App build-for-testing
  (`hdc-reviewed-base-unified-gate-retry.log`). The first invocation stopped
  before Swift compilation because the sandbox could not write the configured
  shared cache; the same command passed with the required host access.
- After every related recording process had stopped, the independent
  `ControlMethodSchemaContractTests/testFramesRecordedByThisRunValidate`
  invocation passed with exit 0 (`hdc-reviewed-base-post-recording-validation.log`).
  It covered 1,301 complete frames in 169 files; the immutable recording files
  are indexed with byte counts and SHA-256 in
  `hdc-reviewed-base-frame-manifest.json`. The parallel suite's earlier validator
  is not counted as complete output coverage, and generator consistency is not
  substituted for this check.
- A presentation-only UI assertion now walks a selected device through failed
  observation and a fresh successful recheck in English and Chinese. It is not
  a device run. UI execution remains deferred: the existing wrapper attempts
  failed before assertions, and automatic approval review rejected launching
  the local App build until that exact launch receives user authorization.

The Runtime producing the historical failure has not been replaced with this
candidate. A reviewed, published build and a fresh headless observation are
still required to obtain the actual malformed-row diagnosis and complete GJ-1.
Original unknown Jobs, binding state, authority records and Raw Artifacts are
unchanged. No `REAL_DEVICE_PASS` is claimed by these host regressions.
