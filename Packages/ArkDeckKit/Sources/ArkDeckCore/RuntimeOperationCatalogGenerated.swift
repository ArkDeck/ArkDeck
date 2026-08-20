// GENERATED FILE - DO NOT EDIT BY HAND.
// Source of truth: Catalog/operations/*.json (CHG-2026-046 T04).
// Regenerate: python3 scripts/catalog_gen/generate.py --write
// Drift is a check-sdd error (bidirectional byte comparison).

extension RuntimeOperationCatalog {
  public static let catalogDigest = "2f9d397dcb6add105c7a297577f229b3699be978d2262efe41d8cc3862ede0eb"

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
        CatalogFieldDescriptor(name: "maxEvents", type: .integer, isRequired: true, minimum: 1, maximum: 100000),
        CatalogFieldDescriptor(name: "maxOutputBytes", type: .integer, isRequired: true, minimum: 1024, maximum: 67108864),
        CatalogFieldDescriptor(name: "maxRows", type: .integer, isRequired: true, minimum: 1, maximum: 100000),
        CatalogFieldDescriptor(name: "pid", type: .integer, isRequired: false, minimum: 0),
        CatalogFieldDescriptor(name: "processKey", type: .integer, isRequired: false, summary: "Stable process internal identity; zero is the absent sentinel and is rejected."),
        CatalogFieldDescriptor(name: "sourceArtifactRef", type: .artifactLease, isRequired: true, summary: "Existing immutable trace artifact resolved by the Runtime lease boundary."),
        CatalogFieldDescriptor(name: "startNs", type: .integer, isRequired: false, minimum: 0, summary: "Inclusive range start; required together with endNs and mutually exclusive with timestampNs."),
        CatalogFieldDescriptor(name: "threadKey", type: .integer, isRequired: false, summary: "Stable thread internal identity; zero is the absent sentinel and is rejected."),
        CatalogFieldDescriptor(name: "thresholdNs", type: .integer, isRequired: false, minimum: 0, summary: "Minimum long-slice duration for analysis kinds; absent means zero."),
        CatalogFieldDescriptor(name: "tid", type: .integer, isRequired: false, minimum: 0),
        CatalogFieldDescriptor(name: "timeoutMs", type: .integer, isRequired: true, minimum: 100, maximum: 120000),
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
        CatalogFieldDescriptor(name: "expectedDeployedArtifactDigest", type: .string, isRequired: false, pattern: "^[0-9a-f]{64}$", maxLength: 64, summary: "Harness-owned expected digest of the deployment whose liveness is being sampled."),
        CatalogFieldDescriptor(name: "hilogFilters", type: .stringArray, isRequired: false, maxLength: 200, maxItems: 16, summary: "Typed HiLog filter expressions; no shell fragments."),
        CatalogFieldDescriptor(name: "processName", type: .string, isRequired: false, pattern: "^[a-zA-Z][a-zA-Z0-9_.:]*$", maxLength: 200, summary: "Optional process identity. Defaults to bundleName and is lowered only by the HDC provider."),
        CatalogFieldDescriptor(name: "redactionProfile", type: .string, isRequired: false, enumValues: ["standard", "strict"], defaultValue: .string("standard")),
        CatalogFieldDescriptor(name: "totalArtifactByteBudget", type: .integer, isRequired: false, minimum: 1048576, maximum: 536870912, defaultValue: .integer(134217728)),
        CatalogFieldDescriptor(name: "traceBufferKB", type: .integer, isRequired: false, minimum: 1024, maximum: 65536, defaultValue: .integer(8192)),
        CatalogFieldDescriptor(name: "traceCategories", type: .stringArray, isRequired: false, maxLength: 64, maxItems: 24, summary: "Trace categories; presence selects the remote-file trace leg and escalates the effective effect to deviceMutation."),
        CatalogFieldDescriptor(name: "uiComponentTree", type: .boolean, isRequired: false, summary: "Capture the on-screen component tree. Presence selects the file-producing dumpLayout leg and escalates the effective effect to deviceMutation; absent or false leaves the plan unchanged.", defaultValue: .bool(false)),
        CatalogFieldDescriptor(name: "uiDump", type: .boolean, isRequired: false, defaultValue: .bool(true)),
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
        CatalogFieldDescriptor(name: "abilityName", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_.]*$", maxLength: 200),
        CatalogFieldDescriptor(name: "additionalHapArtifactLeases", type: .artifactLeaseArray, isRequired: false, maxItems: 16, summary: "Feature HAPs and HSPs of the same bundle. Present means the packages are sent into one provider-owned directory and installed by a single bm install -p <dir>; absent leaves the single-package plan unchanged."),
        CatalogFieldDescriptor(name: "bundleName", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200),
        CatalogFieldDescriptor(name: "captureDiagnostics", type: .boolean, isRequired: false, defaultValue: .bool(true)),
        CatalogFieldDescriptor(name: "cleanupPolicy", type: .string, isRequired: false, enumValues: ["uninstall", "retain", "restorePrevious"], defaultValue: .string("uninstall")),
        CatalogFieldDescriptor(name: "diagnosticsDurationSeconds", type: .integer, isRequired: false, minimum: 1, maximum: 300, defaultValue: .integer(30)),
        CatalogFieldDescriptor(name: "hapArtifactLease", type: .artifactLease, isRequired: true, summary: "Entry HAP; must come from an artifact lease, arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "installPolicy", type: .string, isRequired: false, enumValues: ["installOrReplace", "installFresh"], defaultValue: .string("installOrReplace")),
        CatalogFieldDescriptor(name: "portForwardProfile", type: .string, isRequired: false, enumValues: ["none", "debugger-default"], defaultValue: .string("none")),
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
        CatalogFieldDescriptor(name: "expectedABI", type: .string, isRequired: true, enumValues: ["arm64-v8a", "armeabi-v7a", "x86_64"]),
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true, summary: "The .so must come from an artifact lease; arbitrary local paths are rejected."),
        CatalogFieldDescriptor(name: "libraryLogicalName", type: .string, isRequired: true, pattern: "^lib[a-zA-Z0-9_.-]+\\.so$", maxLength: 128),
        CatalogFieldDescriptor(name: "restartProfile", type: .string, isRequired: false, enumValues: ["restartAbility", "restartProcess", "none"], defaultValue: .string("restartAbility")),
        CatalogFieldDescriptor(name: "rollbackPolicy", type: .string, isRequired: false, enumValues: ["autoRollback", "retainBackup"], defaultValue: .string("autoRollback")),
        CatalogFieldDescriptor(name: "targetBundle", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200, summary: "Remote destination is derived from this bundle's app-owned profile directory; callers cannot submit a remote path."),
        CatalogFieldDescriptor(name: "verificationProfile", type: .string, isRequired: false, enumValues: ["hashOnly", "hashAndProcess", "hashProcessAndMaps"], defaultValue: .string("hashAndProcess"))
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
        CatalogFieldDescriptor(name: "expectedABI", type: .string, isRequired: true, enumValues: ["arm64-v8a", "armeabi-v7a", "x86_64"]),
        CatalogFieldDescriptor(name: "expectedBuildFingerprint", type: .string, isRequired: true, maxLength: 200, summary: "Must equal the device's current build fingerprint at preflight; drift invalidates the capability."),
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "originalFileSHA256", type: .string, isRequired: true, pattern: "^[0-9a-f]{64}$"),
        CatalogFieldDescriptor(name: "restartPlan", type: .string, isRequired: true, enumValues: ["restartService", "rebootDevice"]),
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
        CatalogFieldDescriptor(name: "deviceProfile", type: .string, isRequired: true, enumValues: ["dayu200"]),
        CatalogFieldDescriptor(name: "imageBundleLease", type: .artifactLease, isRequired: true, summary: "Trusted image bundle; every image hash is pinned by the Runtime-owned capability."),
        CatalogFieldDescriptor(name: "partitionPlan", type: .stringArray, isRequired: true, maxLength: 32, maxItems: 16, summary: "Ordered partition names from the profile's closed vocabulary; the Runtime capability pins the exact plan digest."),
        CatalogFieldDescriptor(name: "postFlashVerification", type: .string, isRequired: false, enumValues: ["basic", "full"], defaultValue: .string("full"))
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
        CatalogFieldDescriptor(name: "direction", type: .string, isRequired: true, enumValues: ["forward", "reverse"]),
        CatalogFieldDescriptor(name: "localPort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535),
        CatalogFieldDescriptor(name: "remotePort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535)
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
        CatalogFieldDescriptor(name: "direction", type: .string, isRequired: true, enumValues: ["forward", "reverse"]),
        CatalogFieldDescriptor(name: "localPort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535),
        CatalogFieldDescriptor(name: "remotePort", type: .integer, isRequired: true, minimum: 1024, maximum: 65535)
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
        CatalogFieldDescriptor(name: "allowedFileGlobs", type: .stringArray, isRequired: true, maxLength: 512, maxItems: 64),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "patchArtifactRef", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
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
        CatalogFieldDescriptor(name: "buildPresetRef", type: .string, isRequired: true, maxLength: 128),
        CatalogFieldDescriptor(name: "expectedWorkspaceRevision", type: .string, isRequired: false, maxLength: 128, summary: "Workspace revision the caller decided against; the provider refuses if the tree moved."),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
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
        CatalogFieldDescriptor(name: "patchAttemptRef", type: .string, isRequired: true, maxLength: 64),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
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
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128),
        CatalogFieldDescriptor(name: "testPresetRef", type: .string, isRequired: true, maxLength: 128)
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
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128),
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
        CatalogFieldDescriptor(name: "dumpArtifactRef", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128),
        CatalogFieldDescriptor(name: "symbolPresetRef", type: .string, isRequired: true, maxLength: 128)
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
