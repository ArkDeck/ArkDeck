// GENERATED FILE - DO NOT EDIT BY HAND.
// Source of truth: Catalog/operations/*.json (CHG-2026-046 T04).
// Regenerate: python3 scripts/catalog_gen/generate.py --write
// Drift is a check-sdd error (bidirectional byte comparison).

extension RuntimeOperationCatalog {
  public static let catalogDigest = "17bd5443d0a660a8d657b5ba9fb15017252f42f88714bc4bc3e4e22ff76bdaff"

  public static let operations: [CatalogOperationDescriptor] = [
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
        CatalogFieldDescriptor(name: "durationSeconds", type: .integer, isRequired: true, minimum: 1, maximum: 600),
        CatalogFieldDescriptor(name: "hilogFilters", type: .stringArray, isRequired: false, maxLength: 200, maxItems: 16),
        CatalogFieldDescriptor(name: "redactionProfile", type: .string, isRequired: false, enumValues: ["standard", "strict"]),
        CatalogFieldDescriptor(name: "totalArtifactByteBudget", type: .integer, isRequired: false, minimum: 1048576, maximum: 536870912),
        CatalogFieldDescriptor(name: "traceBufferKB", type: .integer, isRequired: false, minimum: 1024, maximum: 65536),
        CatalogFieldDescriptor(name: "traceCategories", type: .stringArray, isRequired: false, maxLength: 64, maxItems: 24),
        CatalogFieldDescriptor(name: "uiComponentTree", type: .boolean, isRequired: false),
        CatalogFieldDescriptor(name: "uiDump", type: .boolean, isRequired: false)
      ],
      outputs: [
        CatalogFieldDescriptor(name: "artifactIndex", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "captureSummary", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "preflight-host-storage", kind: .preflightHostStorage, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "confirm-evidence-target", kind: .probeDevice, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "read-evidence-model", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "deviceModel")),
        CatalogStepDescriptor(stepID: "read-evidence-firmware", kind: .runApprovedRemoteRead, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild")),
        CatalogStepDescriptor(stepID: "preflight-device-storage", kind: .preflightDeviceStorage, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none),
        CatalogStepDescriptor(stepID: "capture-hilog", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: false, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "boundedHilog")),
        CatalogStepDescriptor(stepID: "capture-ui-dump", kind: .captureRemoteStdout, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none, actionReference: CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "windowInventory")),
        CatalogStepDescriptor(stepID: "capture-ui-tree", kind: .captureRemoteFile, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
        CatalogStepDescriptor(stepID: "receive-ui-tree", kind: .receiveFile, effect: .readOnly, cancellation: .immediate, binding: .confirmedDevice, isOptional: true, compensation: .none),
        CatalogStepDescriptor(stepID: "cleanup-ui-tree-temp", kind: .cleanupOwnedRemotePath, effect: .deviceMutation, cancellation: .atSafeBoundary, binding: .confirmedDevice, isOptional: true, compensation: .bestEffortCleanup),
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
        CatalogArtifactDescriptor(name: "trace.htrace", role: .raw, mediaType: "application/octet-stream", privacy: .sensitive, isRequired: false, retentionClass: .default),
        CatalogArtifactDescriptor(name: "artifact-index.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default),
        CatalogArtifactDescriptor(name: "capture-summary.json", role: .derived, mediaType: "application/json", privacy: .standard, isRequired: true, retentionClass: .default)
      ],
      profiles: ["openharmony-standard@1", "dayu200@1"]
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
        CatalogFieldDescriptor(name: "bundleName", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200),
        CatalogFieldDescriptor(name: "captureDiagnostics", type: .boolean, isRequired: false),
        CatalogFieldDescriptor(name: "cleanupPolicy", type: .string, isRequired: false, enumValues: ["uninstall", "retain", "restorePrevious"]),
        CatalogFieldDescriptor(name: "diagnosticsDurationSeconds", type: .integer, isRequired: false, minimum: 1, maximum: 300),
        CatalogFieldDescriptor(name: "hapArtifactLease", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "installPolicy", type: .string, isRequired: false, enumValues: ["installOrReplace", "installFresh"]),
        CatalogFieldDescriptor(name: "portForwardProfile", type: .string, isRequired: false, enumValues: ["none", "debugger-default"])
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
      profiles: ["openharmony-standard@1", "dayu200@1"]
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
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "libraryLogicalName", type: .string, isRequired: true, pattern: "^lib[a-zA-Z0-9_.-]+\\.so$", maxLength: 128),
        CatalogFieldDescriptor(name: "restartProfile", type: .string, isRequired: false, enumValues: ["restartAbility", "restartProcess", "none"]),
        CatalogFieldDescriptor(name: "rollbackPolicy", type: .string, isRequired: false, enumValues: ["autoRollback", "retainBackup"]),
        CatalogFieldDescriptor(name: "targetBundle", type: .string, isRequired: true, pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$", maxLength: 200),
        CatalogFieldDescriptor(name: "verificationProfile", type: .string, isRequired: false, enumValues: ["hashOnly", "hashAndProcess", "hashProcessAndMaps"])
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
      profiles: ["openharmony-standard@1", "dayu200@1"]
    ),
    CatalogOperationDescriptor(
      id: "deploy.native-library.system",
      version: 1,
      title: "Replace a system/vendor partition native library under one-shot exact-plan authorization (E2)",
      provider: .hdc,
      minimumEffect: .destructive,
      permittedEffects: [.destructive],
      authorization: [.destructive: .oneShotExactPlan],
      defaultPolicyIssuanceEnabled: false,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "expectedABI", type: .string, isRequired: true, enumValues: ["arm64-v8a", "armeabi-v7a", "x86_64"]),
        CatalogFieldDescriptor(name: "expectedBuildFingerprint", type: .string, isRequired: true, maxLength: 200),
        CatalogFieldDescriptor(name: "libraryArtifactLease", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "originalFileSHA256", type: .string, isRequired: true, pattern: "^[0-9a-f]{64}$"),
        CatalogFieldDescriptor(name: "restartPlan", type: .string, isRequired: true, enumValues: ["restartService", "rebootDevice"]),
        CatalogFieldDescriptor(name: "targetPathProfile", type: .string, isRequired: true, pattern: "^[a-z][a-z0-9-]*$", maxLength: 128)
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
      profiles: ["openharmony-standard@1", "dayu200@1"]
    ),
    CatalogOperationDescriptor(
      id: "flash.dayu200",
      version: 1,
      title: "Flash a bound DAYU200 (RK3568) from a trusted image bundle with rebind and post-flash verification (E2)",
      provider: .rockchip,
      minimumEffect: .destructive,
      permittedEffects: [.destructive],
      authorization: [.destructive: .oneShotExactPlan],
      defaultPolicyIssuanceEnabled: true,
      binding: .confirmedDevice,
      concurrencyKey: .deviceExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "deviceProfile", type: .string, isRequired: true, enumValues: ["dayu200@1"]),
        CatalogFieldDescriptor(name: "imageBundleLease", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "partitionPlan", type: .stringArray, isRequired: true, maxLength: 32, maxItems: 16),
        CatalogFieldDescriptor(name: "postFlashVerification", type: .string, isRequired: false, enumValues: ["basic", "full"])
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
      profiles: ["dayu200@1"]
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
        CatalogFieldDescriptor(name: "refreshServerFacts", type: .boolean, isRequired: false)
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
      profiles: ["openharmony-standard@1", "dayu200@1"]
    ),
    CatalogOperationDescriptor(
      id: "workspace.apply-patch",
      version: 1,
      title: "Apply an Artifact-backed patch inside declared ProjectProfile globs",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "allowedFileGlobs", type: .stringArray, isRequired: true, maxLength: 512, maxItems: 64),
        CatalogFieldDescriptor(name: "patchArtifactRef", type: .artifactLease, isRequired: true),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
      ],
      outputs: [
        CatalogFieldDescriptor(name: "appliedPatch", type: .artifactReference, isRequired: true),
        CatalogFieldDescriptor(name: "patchAttemptRef", type: .string, isRequired: true, maxLength: 64)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "apply-patch", kind: .applyWorkspacePatch, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .rollbackPublished)
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
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "buildPresetRef", type: .string, isRequired: true, maxLength: 128),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
      ],
      outputs: [
        CatalogFieldDescriptor(name: "buildLog", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "build-project", kind: .buildWorkspaceOpenHarmony, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
      ],
      timeoutSeconds: 900,
      outputByteBudget: 134217728,
      preflightAttempts: 1,
      artifacts: [
        CatalogArtifactDescriptor(name: "build.log", role: .log, mediaType: "text/plain", privacy: .standard, isRequired: true, retentionClass: .default)
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
        CatalogFieldDescriptor(name: "fileScope", type: .string, isRequired: true),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true),
        CatalogFieldDescriptor(name: "symbol", type: .string, isRequired: true)
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
      id: "workspace.revert-patch",
      version: 1,
      title: "Revert an exact durable workspace patch attempt",
      provider: .workspace,
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "patchAttemptRef", type: .string, isRequired: true, maxLength: 64),
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128)
      ],
      outputs: [
        CatalogFieldDescriptor(name: "revertReport", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "revert-patch", kind: .revertWorkspacePatch, effect: .hostOnly, cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
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
      minimumEffect: .hostOnly,
      permittedEffects: [.hostOnly],
      authorization: [.hostOnly: .defaultReadOnly],
      defaultPolicyIssuanceEnabled: true,
      binding: .none,
      concurrencyKey: .hostExclusive,
      inputs: [
        CatalogFieldDescriptor(name: "projectRef", type: .string, isRequired: true, maxLength: 128),
        CatalogFieldDescriptor(name: "testPresetRef", type: .string, isRequired: true, maxLength: 128)
      ],
      outputs: [
        CatalogFieldDescriptor(name: "testOutput", type: .artifactReference, isRequired: true)
      ],
      steps: [
        CatalogStepDescriptor(stepID: "run-tests", kind: .runWorkspaceTests, effect: .hostOnly, cancellation: .immediate, binding: .none, isOptional: false, compensation: .none)
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
