// GENERATED FILE - DO NOT EDIT BY HAND.
// Source of truth: Catalog/operations/*.json (CHG-2026-046 T04).
// Regenerate: python3 scripts/catalog_gen/generate.py --write
// Drift is a check-sdd error (bidirectional byte comparison).

extension RuntimeOperationCatalog {
  public static let catalogDigest = "53b52b97937030c322416841b16a7d1a19317c5227c9d163ed0886f6341f802b"

  public static let operations: [CatalogOperationDescriptor] = [
    CatalogOperationDescriptor(
      id: "analyzer.analyze-trace",
      version: 1,
      title: "Run bounded typed context or deterministic analysis over a trace artifact",
      provider: .analyzer,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "endNs", type: .integer, isRequired: false, minimum: 1, summary: "Exclusive range end; required together with startNs and greater than startNs."),
        CatalogFieldDescriptor(name: "kind", type: .string, isRequired: true, enumValues: ["context", "cpu", "scheduling", "slices", "range", "hot-intervals"], summary: "Closed ArkTrace context or deterministic analysis family."),
        CatalogFieldDescriptor(name: "limit", type: .integer, isRequired: false, minimum: 1, maximum: 1000, summary: "Per-analysis section limit, additionally bounded by maxRows and maxEvents."),
        CatalogFieldDescriptor(name: "maxEvents", type: .integer, isRequired: true, minimum: 1, maximum: 100000, summary: "Upper bound on trace events the analyzer may read while producing the answer. Bounds the work, where maxRows bounds the result."),
        CatalogFieldDescriptor(name: "maxOutputBytes", type: .integer, isRequired: true, minimum: 1024, maximum: 67108864, summary: "Upper bound on the analysis document's size in bytes. The analyzer fails rather than truncating, so a bound this small for the requested kind is a refusal, not a shorter answer."),
        CatalogFieldDescriptor(name: "maxRows", type: .integer, isRequired: true, minimum: 1, maximum: 100000, summary: "Upper bound on rows the analyzer may return, applied on top of `limit`. Bounds the answer's size independently of how many the query would match."),
        CatalogFieldDescriptor(name: "pid", type: .integer, isRequired: false, minimum: 0, summary: "Operating-system process id to filter to, as recorded in the trace; omit for every process. Distinct from processKey, which is the trace's own internal identity."),
        CatalogFieldDescriptor(name: "processKey", type: .integer, isRequired: false, summary: "Stable process internal identity; zero is the absent sentinel and is rejected."),
        CatalogFieldDescriptor(name: "sourceArtifactRef", type: .artifactLease, isRequired: true, summary: "Existing immutable trace artifact resolved by the Runtime lease boundary."),
        CatalogFieldDescriptor(name: "startNs", type: .integer, isRequired: false, minimum: 0, summary: "Inclusive range start; required together with endNs and mutually exclusive with timestampNs."),
        CatalogFieldDescriptor(name: "threadKey", type: .integer, isRequired: false, summary: "Stable thread internal identity; zero is the absent sentinel and is rejected."),
        CatalogFieldDescriptor(name: "thresholdNs", type: .integer, isRequired: false, minimum: 0, summary: "Minimum long-slice duration for analysis kinds; absent means zero."),
        CatalogFieldDescriptor(name: "tid", type: .integer, isRequired: false, minimum: 0, summary: "Operating-system thread id to filter to, as recorded in the trace; omit for every thread. Distinct from threadKey, which is the trace's own internal identity."),
        CatalogFieldDescriptor(name: "timeoutMs", type: .integer, isRequired: true, minimum: 100, maximum: 120000, summary: "Wall-clock budget for the analyzer process. The provider also derives its own process deadline from this, rounded up to whole seconds and capped at 120."),
        CatalogFieldDescriptor(name: "timestampNs", type: .integer, isRequired: false, minimum: 0, summary: "Center timestamp for the reviewed 100 ms context/range window; mutually exclusive with startNs/endNs.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "analysis", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "analyze-trace", kind: .runDeterministicAnalyzer, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 67108864,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "trace-analysis.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "analyzer.extract-crash-signature",
      version: 1,
      title: "Extract a crash signature from a collected artifact",
      provider: .analyzer,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "sourceArtifactRef", type: .artifactLease, isRequired: true, summary: "Existing artifact this analysis reads; the engine resolves its lease.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "analysis", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "extract-crash-signature", kind: .runDeterministicAnalyzer, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 67108864,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "crash-signature.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "analyzer.summarize-hilog",
      version: 1,
      title: "Summarize a collected HiLog artifact",
      provider: .analyzer,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "sourceArtifactRef", type: .artifactLease, isRequired: true, summary: "Existing artifact this analysis reads; the engine resolves its lease.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "analysis", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "summarize-hilog", kind: .runDeterministicAnalyzer, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 67108864,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "hilog-summary.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "analyzer.summarize-trace",
      version: 1,
      title: "Summarize a collected trace artifact",
      provider: .analyzer,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "sourceArtifactRef", type: .artifactLease, isRequired: true, summary: "Existing artifact this analysis reads; the engine resolves its lease.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "analysis", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "summarize-trace", kind: .runDeterministicAnalyzer, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 67108864,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "trace-summary.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "capture.diagnostics",
      version: 1,
      title: "Capture bounded HiLog, UI dump and trace with a structured artifact index",
      provider: .hdc,
      minimumEffect: .readOnly,
      permittedEffects: [.readOnly, .deviceMutation],
      authorization: [.readOnly: .defaultReadOnly, .deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "abilityName", type: .string, isRequired: false, pattern: "^[a-zA-Z][a-zA-Z0-9_.]*$", maxLength: 200, summary: "Optional ability identity carried into the liveness artifact; never lowered as caller-supplied argv."),
        CatalogFieldDescriptor(name: "bundleName", type: .string, isRequired: false, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200, summary: "Optional typed application identity. When present, the same bounded job publishes an application-specific process readback."),
        CatalogFieldDescriptor(name: "crashLogName", type: .string, isRequired: false, pattern: "^[a-z]+-[A-Za-z0-9._-]{1,180}$", maxLength: 200, summary: "One Faultlogger entry to fetch, named exactly as the index lists it. An entry name, never a path."),
        CatalogFieldDescriptor(name: "crashLogs", type: .boolean, isRequired: false, summary: "Capture the device's Faultlogger index. Read-only: unlike the trace, tree and screenshot legs this does not raise the effective effect.", defaultValue: .bool(false)),
        CatalogFieldDescriptor(name: "durationSeconds", type: .integer, isRequired: true, minimum: 1, maximum: 600, summary: "Bounded HiLog capture window."),
        CatalogFieldDescriptor(name: "expectedDeployedArtifactDigest", type: .string, isRequired: false, pattern: "^[0-9a-f]{64}$", maxLength: 64, summary: "Caller-supplied expected digest of the deployment whose liveness is being sampled. Recorded with the observation so a later reader can tell which build was live; it is not trusted as a fact about the device."),
        CatalogFieldDescriptor(name: "hilogFilters", type: .stringArray, isRequired: false, maxLength: 200, maxItems: 16, summary: "Typed HiLog filter expressions; no shell fragments."),
        CatalogFieldDescriptor(name: "processName", type: .string, isRequired: false, pattern: "^[a-zA-Z][a-zA-Z0-9_.:]*$", maxLength: 200, summary: "Optional process identity. Defaults to bundleName and is lowered only by the HDC provider."),
        CatalogFieldDescriptor(name: "redactionProfile", type: .string, isRequired: false, enumValues: ["standard", "strict"], summary: "Redaction applied to published text. Only `standard` has a published implementation; `strict` is refused before authorization, so selecting it costs a round trip and gains nothing.", defaultValue: .string("standard")),
        CatalogFieldDescriptor(name: "totalArtifactByteBudget", type: .integer, isRequired: false, minimum: 1048576, maximum: 536870912, summary: "Ceiling on the total bytes this job may publish across all of its artifacts. Reaching it ends collection rather than silently dropping a product.", defaultValue: .integer(134217728)),
        CatalogFieldDescriptor(name: "traceBufferKB", type: .integer, isRequired: false, minimum: 1024, maximum: 65536, summary: "Per-capture trace buffer size in KiB. Only consulted when traceCategories selects the trace leg; ignored otherwise.", defaultValue: .integer(8192)),
        CatalogFieldDescriptor(name: "traceCategories", type: .stringArray, isRequired: false, maxLength: 64, maxItems: 24, summary: "Trace categories; presence selects the remote-file trace leg and escalates the effective effect to deviceMutation."),
        CatalogFieldDescriptor(name: "uiComponentTree", type: .boolean, isRequired: false, summary: "Capture the on-screen component tree. Presence selects the file-producing dumpLayout leg and escalates the effective effect to deviceMutation; absent or false leaves the plan unchanged.", defaultValue: .bool(false)),
        CatalogFieldDescriptor(name: "uiDump", type: .boolean, isRequired: false, summary: "Capture the accessibility/window dump. Read-only: unlike the trace, screenshot and component-tree legs this does not raise the effective effect.", defaultValue: .bool(true)),
        CatalogFieldDescriptor(name: "uiScreenshot", type: .boolean, isRequired: false, summary: "Capture a PNG screenshot of the display. Presence selects the file-producing snapshot_display leg and escalates the effective effect to deviceMutation; absent or false leaves the plan unchanged.", defaultValue: .bool(false))
      ],
      outputs: [
        CatalogFieldDescriptor(name: "applicationLiveness", type: .artifactReference, isRequired: false),
        CatalogFieldDescriptor(name: "artifactIndex", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "captureSummary", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "preflight-host-storage", kind: .preflightHostStorage, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "preflight-device-storage", kind: .preflightDeviceStorage, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "observe-application-liveness", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "capture-hilog", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "boundedHilog")),
        CatalogStepDescriptor(stepID: "capture-ui-dump", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "windowInventory")),
        CatalogStepDescriptor(stepID: "capture-crash-index", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "crashIndex")),
        CatalogStepDescriptor(stepID: "capture-crash-log", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "crashLog")),
        CatalogStepDescriptor(stepID: "capture-ui-tree", kind: .captureRemoteFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "receive-ui-tree", kind: .receiveFile, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-ui-tree-temp", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "capture-screenshot", kind: .captureRemoteFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "receive-screenshot", kind: .receiveFile, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-screenshot-temp", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "capture-trace", kind: .captureRemoteFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "receive-trace-artifact", kind: .receiveFile, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-remote-temp", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "postprocess-index", kind: .postprocessArtifact, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 536870912,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "hilog.txt", role: .raw, mediaType: "text/plain", privacy: .sensitive, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "ui-dump.json", role: .raw, mediaType: "application/json", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "ui-tree.json", role: .raw, mediaType: "application/json", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "screenshot.png", role: .raw, mediaType: "image/png", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "crash-index.txt", role: .raw, mediaType: "text/plain", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "crash-log.txt", role: .raw, mediaType: "text/plain", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "application-liveness.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "trace.htrace", role: .raw, mediaType: "application/octet-stream", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "capture.log", role: .log, mediaType: "text/plain", privacy: .standard, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "artifact-index.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "capture-summary.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "debug.hap",
      version: 1,
      title: "Install, start, observe, stop and optionally uninstall a HAP from an artifact lease",
      provider: .hdc,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "abilityName", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_.]*$", maxLength: 200, summary: "Ability to start within the bundle, as declared in module.json5, for example `EntryAbility`. Never lowered as caller-supplied argv."),
        CatalogFieldDescriptor(name: "additionalHapArtifactLeases", type: .artifactLeaseArray, isRequired: false, maxItems: 16, summary: "Feature HAPs and HSPs of the same bundle. Present means the packages are sent into one provider-owned directory and installed by a single bm install -p <dir>; absent leaves the single-package plan unchanged."),
        CatalogFieldDescriptor(name: "bundleName", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200, summary: "Application bundle name exactly as the package declares it, for example `com.example.waterflow`. The provider matches package readback against this, so a bundle that is not installed by this exact name reads as a failed install."),
        CatalogFieldDescriptor(name: "captureDiagnostics", type: .boolean, isRequired: false, summary: "Collect the bounded HiLog window while the ability runs. Read-only, and its absence does not fail the job — the diagnostics artifact is optional.", defaultValue: .bool(true)),
        CatalogFieldDescriptor(name: "cleanupPolicy", type: .string, isRequired: false, enumValues: ["uninstall", "retain", "restorePrevious"], summary: "What happens to the package when the job ends. `uninstall` removes it, `retain` leaves it installed — which is what an external observer needs, together with postRunAbilityState `running`, to keep watching after the job succeeds. `restorePrevious` is refused before authorization: no snapshot/restore step is published.", defaultValue: .string("uninstall")),
        CatalogFieldDescriptor(name: "diagnosticsDurationSeconds", type: .integer, isRequired: false, minimum: 1, maximum: 300, summary: "Length of the bounded HiLog window in seconds. A crash that happens after this window is not in the artifact, so a delayed fault needs a window that outlasts it.", defaultValue: .integer(30)),
        CatalogFieldDescriptor(name: "hapArtifactLease", type: .artifactLease, isRequired: true, summary: "Entry HAP; must come from an artifact lease, arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "installPolicy", type: .string, isRequired: false, enumValues: ["installOrReplace", "installFresh"], summary: "How an already-installed package is treated. Only `installOrReplace` has a published plan; `installFresh` is refused before authorization because no pre-install absence readback exists to make it honest.", defaultValue: .string("installOrReplace")),
        CatalogFieldDescriptor(name: "portForwardProfile", type: .string, isRequired: false, enumValues: ["none", "debugger-default"], summary: "Port forwarding to establish alongside the run. Only `none` has a published plan; `debugger-default` is refused before authorization because this operation publishes no port-forward steps — use `port-forward.create@1` separately.", defaultValue: .string("none")),
        CatalogFieldDescriptor(name: "postRunAbilityState", type: .string, isRequired: false, enumValues: ["stopped", "running"], summary: "Whether the started ability is stopped before cleanup. `running` skips stop-ability so the application is still live when the job succeeds, which is what an external observer needs; the operator then owns stopping it. A failed job still stops the ability during compensation.", defaultValue: .string("stopped"))
      ],
      outputs: [
        CatalogFieldDescriptor(name: "diagnostics", type: .artifactReference, isRequired: false),
        CatalogFieldDescriptor(name: "installReadback", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "processReadback", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "verify-hap-artifact", kind: .verifyArtifact, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "send-hap", kind: .sendFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "install-hap", kind: .installPackage, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "package-readback", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "packageInfo")),
        CatalogStepDescriptor(stepID: "start-ability", kind: .startApplication, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "process-readback", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "capture-diagnostics", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "boundedHilog")),
        CatalogStepDescriptor(stepID: "stop-ability", kind: .stopApplication, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-uninstall", kind: .uninstallPackage, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-remote-staging", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 600,
      outputByteBudget: 67108864,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "install-readback.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "process-readback.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "debug-hilog.txt", role: .raw, mediaType: "text/plain", privacy: .sensitive, isRequired: false, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "deploy.native-library.app-owned",
      version: 1,
      title: "Atomically publish an app-owned native library with verification and rollback",
      provider: .hdc,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "expectedABI", type: .string, isRequired: true, enumValues: ["arm64-v8a", "armeabi-v7a", "x86_64"], summary: "ABI the uploaded ELF must declare. Verified against the artifact's own header before anything is sent, so a mismatch fails on the host rather than on the device."),
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true, summary: "The .so must come from an artifact lease; arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "libraryLogicalName", type: .string, isRequired: true, pattern: "^lib[a-zA-Z0-9_.-]+\\.so$", maxLength: 128, summary: "File name the library is published under inside the application's own directory. Must match `lib<name>.so` and be at most 128 characters; it names a file, never a path."),
        CatalogFieldDescriptor(name: "restartProfile", type: .string, isRequired: false, enumValues: ["restartAbility", "restartProcess", "none"], summary: "How the application is restarted so it loads the new library. Only `restartAbility` has a published restart/readback plan; `restartProcess` and `none` are refused before authorization.", defaultValue: .string("restartAbility")),
        CatalogFieldDescriptor(name: "rollbackPolicy", type: .string, isRequired: false, enumValues: ["autoRollback", "retainBackup"], summary: "What happens to the previous library when verification fails. `autoRollback` restores it; `retainBackup` leaves the new one in place and keeps the backup for a later decision.", defaultValue: .string("autoRollback")),
        CatalogFieldDescriptor(name: "targetBundle", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200, summary: "Remote destination is derived from this bundle's app-owned profile directory; callers cannot submit a remote path."),
        CatalogFieldDescriptor(name: "verificationProfile", type: .string, isRequired: false, enumValues: ["hashOnly", "hashAndProcess", "hashProcessAndMaps"], summary: "How much of the deployment is proven after publication. `hashOnly` compares the published bytes, `hashAndProcess` also requires the process to be live, `hashProcessAndMaps` additionally requires the library to appear in the process's loaded maps.", defaultValue: .string("hashAndProcess"))
      ],
      outputs: [
        CatalogFieldDescriptor(name: "publishReport", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "verificationReport", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "verify-elf-locally", kind: .verifyArtifact, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "hash-library", kind: .hashFile, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "send-to-staging", kind: .sendFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "verify-remote-staging", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "backup-current-version", kind: .runApprovedRemoteMutation, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "atomic-publish", kind: .runApprovedRemoteMutation, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "restart-target", kind: .stopApplication, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "start-target", kind: .startApplication, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "verify-loaded-library", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-staging-and-backup", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 600,
      outputByteBudget: 134217728,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "publish-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "verification-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "deploy.native-library.system",
      version: 1,
      title: "Replace a system/vendor partition native library through Runtime-owned exact-plan admission",
      provider: .hdc,
      minimumEffect: .destructive,
      permittedEffects: [.destructive],
      authorization: [.destructive: .runtimeCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "expectedABI", type: .string, isRequired: true, enumValues: ["arm64-v8a", "armeabi-v7a", "x86_64"], summary: "ABI the uploaded ELF must declare, verified against the artifact's own header before anything is sent."),
        CatalogFieldDescriptor(name: "expectedBuildFingerprint", type: .string, isRequired: true, maxLength: 200, summary: "Must equal the device's current build fingerprint at preflight; drift invalidates the capability."),
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true, summary: "Lease of the imported ELF to publish, in the form `lease-v1:<jobId>:<artifactId>` from `arkdeck artifact import-native-library`. Arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "originalFileSHA256", type: .string, isRequired: true, pattern: "^[0-9a-f]{64}$", summary: "Digest of the file currently at the target path, as proof the caller is replacing what it believes it is replacing. A mismatch fails closed rather than overwriting an unexpected file."),
        CatalogFieldDescriptor(name: "restartPlan", type: .string, isRequired: true, enumValues: ["restartService", "rebootDevice"], summary: "How the system is brought back to a consistent state after replacement: restart the owning service, or reboot the device."),
        CatalogFieldDescriptor(name: "targetPathProfile", type: .string, isRequired: true, pattern: "^[a-z][a-z0-9-]*$", maxLength: 128, summary: "Named system-path profile resolved by the provider; the capability pins the exact absolute path. Callers can never submit a raw remote path, and app-owned inputs can never resolve to a system path.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "publishReport", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "verificationReport", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "verify-elf-locally", kind: .verifyArtifact, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "hash-library", kind: .hashFile, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "preflight-system-state", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "remount-writable", kind: .runApprovedRemoteMutation, effect: .destructive, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "send-to-staging", kind: .sendFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "backup-original", kind: .runApprovedRemoteMutation, effect: .destructive, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "atomic-replace", kind: .runApprovedRemoteMutation, effect: .destructive, cancellation: .criticalNonInterruptible, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "restart-per-plan", kind: .rebootDevice, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "wait-for-reconnect", kind: .waitForReconnect, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "verify-system-state", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 1800,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "publish-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "verification-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "backup-receipt.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "flash.dayu200",
      version: nil,
      title: "Flash a bound DAYU200 (RK3568) from a trusted image bundle with rebind and post-flash verification",
      provider: .rockchip,
      minimumEffect: .destructive,
      permittedEffects: [.destructive],
      authorization: [.destructive: .runtimeCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "deviceProfile", type: .string, isRequired: true, enumValues: ["dayu200"], summary: "Board profile whose partition vocabulary and layout the plan is checked against. `dayu200` is the only published board."),
        CatalogFieldDescriptor(name: "imageBundleLease", type: .artifactLease, isRequired: true, summary: "Trusted image bundle; every image hash is pinned by the Runtime-owned capability."),
        CatalogFieldDescriptor(name: "partitionPlan", type: .stringArray, isRequired: true, maxLength: 32, maxItems: 16, summary: "Ordered partition names from the profile's closed vocabulary; the Runtime capability pins the exact plan digest."),
        CatalogFieldDescriptor(name: "postFlashVerification", type: .string, isRequired: false, enumValues: ["basic", "full"], summary: "How much is verified after the write. `full` additionally captures post-flash diagnostics; `basic` omits that one optional leg and verifies the rest.", defaultValue: .string("full"))
      ],
      outputs: [
        CatalogFieldDescriptor(name: "flashReport", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "postFlashFacts", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "verify-image-bundle", kind: .verifyArtifact, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "hash-images", kind: .hashFile, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "confirm-flash-intent", kind: .requestConfirmation, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "enter-loader-mode", kind: .enterUpdater, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "wait-loader-disconnect", kind: .waitForDisconnect, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "wait-loader-reconnect", kind: .waitForReconnect, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "rebind-loader-identity", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "flash-partitions", kind: .flashPartition, effect: .destructive, cancellation: .criticalNonInterruptible, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "verify-flash-readback", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "reboot-device", kind: .rebootDevice, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "wait-for-hdc", kind: .waitForReconnect, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "rebind-and-verify-build", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "capture-post-flash-diagnostics", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "boundedHilog")),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 1800,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "flash-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "post-flash-facts.json", role: .raw, mediaType: "application/json", privacy: .sensitive, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "post-flash-hilog.txt", role: .raw, mediaType: "text/plain", privacy: .sensitive, isRequired: false, retentionClass: .default)
      ],
      profiles: ["dayu200"],
      completeOverwriteRecovery: CatalogCompleteOverwriteRecoveryDescriptor(
        contractVersion: "1.0.0",
        profiles: [CatalogCompleteOverwriteRecoveryProfileDescriptor(reference: "dayu200", coveredEffects: ["partition:uboot", "partition:resource", "partition:boot_linux", "partition:ramdisk", "partition:system", "partition:vendor", "partition:updater", "partition:chip_ckm", "partition:userdata"])],
        overwriteStepID: "flash-partitions",
        verificationStepIDs: ["verify-flash-readback", "reboot-device", "wait-for-hdc", "rebind-and-verify-build"])
    ),
    CatalogOperationDescriptor(
      id: "observe.device",
      version: 1,
      title: "Observe host tool, HDC server and bound device facts",
      provider: .hdc,
      minimumEffect: .readOnly,
      permittedEffects: [.readOnly],
      authorization: [.readOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceSharedReadOnly,
      inputs: [
        CatalogFieldDescriptor(name: "refreshServerFacts", type: .boolean, isRequired: false, summary: "Re-probe HDC server facts even when a fresh snapshot exists.", defaultValue: .bool(true))
      ],
      outputs: [
        CatalogFieldDescriptor(name: "bindingSnapshot", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "deviceFacts", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "toolFacts", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "probe-host-tool", kind: .probeHostTool, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "probe-hdc-server", kind: .probeHDCServer, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 60,
      outputByteBudget: 1048576,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "device-facts.json", role: .raw, mediaType: "application/json", privacy: .sensitive, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "tool-facts.json", role: .raw, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "binding-snapshot.json", role: .derived, mediaType: "application/json", privacy: .sensitive, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "port-forward.create",
      version: 1,
      title: "Create and verify one target-bound HDC TCP port rule",
      provider: .hdc,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "direction", type: .string, isRequired: true, enumValues: ["forward", "reverse"], summary: "Which way the rule points. `forward` lowers to hdc `fport` — a host port reaching a device port; `reverse` lowers to `rport` — a device port reaching a host port."),
        CatalogFieldDescriptor(name: "localPort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535, summary: "Port on the host side of the rule. Unprivileged range only."),
        CatalogFieldDescriptor(name: "remotePort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535, summary: "Port on the device side of the rule. Unprivileged range only.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "ruleReadback", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "create-port-rule", kind: .createPortForward, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "verify-port-rule", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 1048576,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "port-rule-readback.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "port-forward.remove",
      version: 1,
      title: "Remove and verify one target-bound HDC TCP port rule",
      provider: .hdc,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "direction", type: .string, isRequired: true, enumValues: ["forward", "reverse"], summary: "Which rule to remove; must match the direction the rule was created with. `forward` is hdc `fport`, `reverse` is `rport`."),
        CatalogFieldDescriptor(name: "localPort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535, summary: "Host-side port of the rule to remove; must match the rule exactly."),
        CatalogFieldDescriptor(name: "remotePort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535, summary: "Device-side port of the rule to remove; must match the rule exactly.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "ruleReadback", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "remove-port-rule", kind: .removePortForward, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: false, compensation: .rollbackPublished),
        CatalogStepDescriptor(stepID: "verify-port-rule", kind: .verifyRemoteState, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "finalize-session", kind: .finalizeSession, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 1048576,
      preflightAttempts: 2,
      artifacts: [
        CatalogArtifactDescriptor(name: "port-rule-readback.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.apply-patch",
      version: 1,
      title: "Apply an Artifact-backed patch inside declared ProjectProfile globs",
      provider: .workspace,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: false,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "allowedFileGlobs", type: .stringArray, isRequired: true, maxLength: 512, maxItems: 64, summary: "Paths the patch may touch, and it may not touch anything outside them. Narrower than the project profile's own globs, never wider — the request cannot widen its own scope."),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "patchArtifactRef", type: .artifactLease, isRequired: true, summary: "Lease of the unified diff to apply, in the form `lease-v1:<jobId>:<artifactId>` from `arkdeck artifact import-workspace-patch`. Arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project. This build ships `demo-app` (the WaterFlow OpenHarmony app) and `ArkDeck` (this repository); which one a host offers depends on how its daemon was configured.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "appliedPatch", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "patchAttemptRef", type: .string, isRequired: true, maxLength: 64)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "apply-patch", kind: .applyWorkspacePatch, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .rollbackPublished)
      ],
      timeoutSeconds: 180,
      outputByteBudget: 16777216,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "applied-patch.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.build-openharmony",
      version: 1,
      title: "Build through an exact repository-managed ProjectProfile preset",
      provider: .workspace,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: false,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "buildPresetRef", type: .string, isRequired: true, maxLength: 128, summary: "Build preset within that project's profile: `waterflow-debug` for `demo-app`, `arkdeck-debug` for `ArkDeck`. The preset owns the executable and every argument; the request selects one and supplies none."),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project. This build ships `demo-app` and `ArkDeck`; which one a host offers depends on how its daemon was configured.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "buildLog", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "unsignedHap", type: .artifactReference, isRequired: false, summary: "Immutable HAP when the selected ProjectProfile declares a build product.")
      ],
      steps: [
        CatalogStepDescriptor(stepID: "build-project", kind: .buildWorkspaceOpenHarmony, effect: .deviceMutation, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "build.log", role: .log, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "unsigned.hap", role: .derived, mediaType: "application/vnd.openharmony.hap", privacy: .standard, isRequired: false, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.create-checkpoint",
      version: 1,
      title: "Create a rollback checkpoint object for declared workspace source",
      provider: .workspace,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .runtimeCapability],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "checkpointFilePaths", type: .stringArray, isRequired: false, maxLength: 512, maxItems: 64, summary: "Exact profile-scoped files to seal when the ProjectProfile uses an archive checkpoint instead of Git."),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, summary: "Declared project to checkpoint; the provider resolves its root.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "inspection", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "create-checkpoint", kind: .createWorkspaceCheckpoint, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "checkpoint.txt", role: .raw, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.inspect-diff",
      version: 1,
      title: "Observe a bounded diff of declared workspace source",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "baseRevision", type: .string, isRequired: true, summary: "Revision expression the diff is taken against; never a path."),
        CatalogFieldDescriptor(name: "pathScope", type: .string, isRequired: true, summary: "Pathspec the provider joins to the resolved project root; never a caller path."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, summary: "Declared project this observation reads; the provider resolves its root.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "inspection", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "inspect-diff", kind: .inspectWorkspaceDiff, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 60,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "diff-summary.txt", role: .raw, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.inspect-git-status",
      version: 1,
      title: "Observe declared workspace source-control status",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, summary: "Declared project this observation reads; the provider resolves its root.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "inspection", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "inspect-git-status", kind: .inspectWorkspaceGitStatus, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 60,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "git-status.txt", role: .raw, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.inspect-source",
      version: 1,
      title: "Inspect declared workspace source for a symbol",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "fileScope", type: .string, isRequired: true, summary: "Glob the provider joins to the resolved project root; never a caller path."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, summary: "Declared project this inspection reads; the provider resolves its root."),
        CatalogFieldDescriptor(name: "symbol", type: .string, isRequired: true, summary: "Symbol or literal to locate in the declared source scope.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "inspection", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "inspect-workspace-source", kind: .inspectWorkspaceSource, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 120,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "source-inspection.txt", role: .raw, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.prepare-isolated-copy",
      version: 1,
      title: "Prepare an exact Runtime-owned isolated ProjectProfile copy",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "allowedFileGlobs", type: .stringArray, isRequired: true, maxLength: 512, maxItems: 64, summary: "Exact scopes for the copy; each must narrow the source ProjectProfile."),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: true, pattern: "^[0-9a-f]{64}$", maxLength: 64, summary: "Exact source revision copied and remeasured before publication."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Primary ProjectProfile to copy; the provider resolves its root.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "isolatedWorkspace", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "prepare-isolated-copy", kind: .prepareWorkspaceIsolation, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "isolated-workspace.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.read-source-range",
      version: 1,
      title: "Read a bounded line range of declared workspace source",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "filePath", type: .string, isRequired: true, summary: "Repository-relative path the ProjectProfile already declares readable."),
        CatalogFieldDescriptor(name: "lineEnd", type: .integer, isRequired: true, summary: "Last line to read; the provider bounds the span."),
        CatalogFieldDescriptor(name: "lineStart", type: .integer, isRequired: true, summary: "First line to read, one-based."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, summary: "Declared project this read belongs to; the provider resolves its root.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "inspection", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "read-source-range", kind: .readWorkspaceSourceRange, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 60,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "source-range.txt", role: .raw, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.revert-patch",
      version: 1,
      title: "Revert an exact durable workspace patch attempt",
      provider: .workspace,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: false,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "patchAttemptRef", type: .string, isRequired: true, maxLength: 64, summary: "The attempt to revert, as returned in the `patchAttemptRef` summary field of the `workspace.apply-patch@1` job that applied it. The runtime reverts from its own durable copy of that patch, not from anything the caller supplies."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project. This build ships `demo-app` and `ArkDeck`; which one a host offers depends on how its daemon was configured.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "revertReport", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "revert-patch", kind: .revertWorkspacePatch, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 180,
      outputByteBudget: 16777216,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "revert-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.run-tests",
      version: 1,
      title: "Run tests through an exact repository-managed ProjectProfile preset",
      provider: .workspace,
      minimumEffect: .deviceMutation,
      permittedEffects: [.deviceMutation],
      authorization: [.deviceMutation: .standingCapability],
      defaultPolicyIssuanceEnabled: false,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project. This build ships `demo-app` and `ArkDeck`; which one a host offers depends on how its daemon was configured."),
        CatalogFieldDescriptor(name: "testPresetRef", type: .string, isRequired: true, maxLength: 128, summary: "Test preset within that project's profile: `waterflow-tests` for `demo-app`, `arkdeck-tests` for `ArkDeck`. The preset owns the executable and every argument.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "testOutput", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "run-tests", kind: .runWorkspaceTests, effect: .deviceMutation, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "test-output.log", role: .log, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.sign-openharmony-hap",
      version: 1,
      title: "Sign an immutable OpenHarmony HAP with the installed local preset",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project whose signing material this uses. Availability additionally requires `arkdeck signing install` to have run for that same project."),
        CatalogFieldDescriptor(name: "signingPresetRef", type: .string, isRequired: true, maxLength: 128, summary: "Closed ArkDeck signing preset identity; it is not a path or key alias."),
        CatalogFieldDescriptor(name: "unsignedHapArtifactLease", type: .artifactLease, isRequired: true, summary: "Immutable ZIP-based unsigned HAP resolved by the Runtime Artifact store.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "signedHap", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "signingReport", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "sign-workspace-hap", kind: .signWorkspaceOpenHarmonyHap, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 600,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "signed.hap", role: .derived, mediaType: "application/vnd.openharmony.hap", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified),
        CatalogArtifactDescriptor(name: "signing-report.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.sweep-isolated-copies",
      version: 1,
      title: "Sweep quiescent Runtime-owned isolated ProjectProfile copies",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "dryRun", type: .boolean, isRequired: true, summary: "Classify without destroying; dispositions must match a subsequent wet sweep."),
        CatalogFieldDescriptor(name: "minimumQuiescentSeconds", type: .integer, isRequired: true, minimum: 0, maximum: 7776000, summary: "How long every referencing runtime job must already be terminal before a tree may be destroyed."),
        CatalogFieldDescriptor(name: "retainLatestCount", type: .integer, isRequired: true, minimum: 0, maximum: 64, summary: "Newest quiescent trees kept regardless of age.")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "sweepFindings", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "sweep-isolated-copies", kind: .sweepWorkspaceIsolation, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 1048576,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "sweep-findings.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .pinnedUntilVerified)
      ],
      profiles: ["workspace-host@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.symbolize-crash",
      version: 1,
      title: "Symbolize an Artifact-backed crash through an exact ProjectProfile preset",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "dumpArtifactRef", type: .artifactLease, isRequired: true, summary: "Lease of the crash text to symbolize, in the form `lease-v1:<jobId>:<artifactId>`. It wants an obfuscated ArkTS stack — a `crash-log.txt` published by `capture.diagnostics@1` with `crashLogName` set — not the Faultlogger index that lists entries."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128, summary: "Registered workspace project whose source maps resolve the stack. `demo-app` is the project that ships a symbolizer."),
        CatalogFieldDescriptor(name: "symbolPresetRef", type: .string, isRequired: true, maxLength: 128, summary: "Symbolizer preset within that project's profile. `arkts-sourcemap` is the only published one, and it exists only once the daemon is configured with an analyzer (`ARKDECK_ANALYZER_PATH`, which `arkdeck agentd install`/`update` sets).")
      ],
      outputs: [
        CatalogFieldDescriptor(name: "symbolizedCrash", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "symbolize-crash", kind: .symbolizeWorkspaceCrash, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 300,
      outputByteBudget: 67108864,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "symbolized-crash.txt", role: .derived, mediaType: "text/plain", privacy: .sensitive, isRequired: true, retentionClass: .default)
      ],
      profiles: ["workspace-host@1"]
    ),
  ]
}
