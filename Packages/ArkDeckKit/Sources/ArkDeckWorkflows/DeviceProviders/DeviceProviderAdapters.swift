// Provider adapters over the existing execution stacks (CHG-2026-047, T05).
//
// Compat-first: neither adapter builds a second state machine. The HDC
// adapter composes the existing observation surfaces behind injected
// ports (the production composition arrives with the MU-3 walking
// skeleton); the Rockchip adapter wraps RockchipFlashExecutionHost whole,
// keeping its proven journal/manifest/recovery semantics authoritative.

import ArkDeckCore
import ArkDeckOpenHarmony
import CryptoKit
import Foundation

// MARK: - HDC observation adapter

/// Ports the HDC adapter needs. Kept minimal and injectable so contract
/// tests drive the adapter without a real tool; MU-3 supplies the
/// production composition (discovery + supervisor + registered probes).
public protocol HDCObservationFactsPort: Sendable {
  func currentFacts(targetID: String) async throws -> ProviderFacts
}

private struct HDCNativeFileIdentity: Equatable {
  let mode: String
  let userID: UInt32
  let groupID: UInt32
}

public struct HDCObservationProviderAdapter: DeviceProvider {
  public let providerID = "hdc"
  private let factsPort: any HDCObservationFactsPort
  private let profile: HDCCompatibilityProfile
  private let appOwnedNativeLibraryAvailability: ProviderOperationAvailability

  public init(
    factsPort: any HDCObservationFactsPort,
    profile: HDCCompatibilityProfile = .openHarmony320Family,
    appOwnedNativeLibraryAvailability: ProviderOperationAvailability = .unavailable(
      reason:
        "app-owned native-library replacement cannot enable OpenHarmony XPM/fs-verity "
        + "code signing for the published file")
  ) {
    self.factsPort = factsPort
    self.profile = profile
    self.appOwnedNativeLibraryAvailability = appOwnedNativeLibraryAvailability
  }

  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
    try await factsPort.currentFacts(targetID: targetID)
  }

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    switch operation.reference {
    case "observe.device@1", "capture.diagnostics@1", "debug.hap@1":
      return .available
    case "deploy.native-library.app-owned@1":
      return appOwnedNativeLibraryAvailability
    default:
      return .unavailable(
        reason: "HDC provider has no complete production typed plan for "
          + operation.reference)
    }
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    try action(
      for: step, operation: operation, inputs: inputs,
      context: ProviderExecutionContext(
        jobID: "preflight", stepID: step.stepID, targetID: "preflight",
        bindingRevision: nil, nowUTC: "1970-01-01T00:00:00Z"))
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    if descriptorIsAppOwnedNativeLibrary(operation) {
      return try nativeLibraryAction(
        for: step, inputs: inputs, context: context)
    }
    switch step.kind {
    case .probeHostTool:
      return .hdc(.observeTool)
    case .probeHDCServer:
      return .hdc(.observeServer)
    case .probeDevice:
      return .hdc(.observeDevice(connectKey: "resolved-by-binding"))
    case .sendFile, .installPackage, .startApplication, .stopApplication, .uninstallPackage:
      return try debugHAPAction(for: step, inputs: inputs, context: context)
    case .runApprovedRemoteRead:
      if descriptorIsDebugHAP(operation), step.actionReference?.actionID == "packageInfo" {
        return try debugHAPAction(for: step, inputs: inputs, context: context)
      }
      return try approvedRemoteReadAction(for: step, inputs: inputs)
    case .verifyRemoteState:
      guard descriptorIsDebugHAP(operation) else {
        throw DeviceProviderError.unsupportedStepKind(
          "\(step.kind.rawValue) has no registered action for \(operation.reference)")
      }
      return try debugHAPAction(for: step, inputs: inputs, context: context)
    case .preflightDeviceStorage:
      let requiredBytes: Int
      if case .integer(let requested)? = inputs["totalArtifactByteBudget"] {
        requiredBytes = Int(requested)
      } else {
        requiredBytes = 128 * 1024 * 1024
      }
      return .hdc(
        .observeStorage(
          try HDCStoragePreflightRequest(requiredBytes: requiredBytes)))
    case .captureRemoteStdout:
      return try captureAction(for: step, inputs: inputs)
    case .captureRemoteFile:
      return .hdc(
        .captureTrace(
          try traceRequest(from: inputs),
          into: try mintStableOwnedRemotePath(
            jobID: context.jobID, stepID: "capture-trace")))
    case .receiveFile:
      return .hdc(
        .receiveOwnedArtifact(
          HDCOwnedRemoteArtifact(
            path: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: "capture-trace"),
            expectedSHA256: nil, maximumBytes: 64 * 1024 * 1024)))
    case .cleanupOwnedRemotePath:
      let ownerStepID =
        operation.reference == "debug.hap@1" ? "send-hap" : "capture-trace"
      return .hdc(
        .cleanupOwnedRemotePath(
          try mintStableOwnedRemotePath(jobID: context.jobID, stepID: ownerStepID)))
    case .finalizeSession, .preflightHostStorage, .postprocessArtifact:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) is engine-internal, not a provider action")
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no registered HDC action in MU-2 (arrives with T10)")
    }
  }

  private func descriptorIsDebugHAP(_ operation: CatalogOperationDescriptor) -> Bool {
    operation.id == "debug.hap"
  }

  private func descriptorIsAppOwnedNativeLibrary(
    _ operation: CatalogOperationDescriptor
  ) -> Bool {
    operation.id == "deploy.native-library.app-owned"
  }

  /// Maps only the exact published remote action reference. There is no
  /// step-name, operation-name or default fallback.
  private func approvedRemoteReadAction(
    for step: CatalogStepDescriptor, inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    guard let reference = step.actionReference,
      reference.catalogID == "arkdeck-remote-operations"
    else {
      throw DeviceProviderError.unsupportedAction(
        "\(step.stepID) has no arkdeck-remote-operations actionRef")
    }
    switch reference.actionID {
    case "deviceModel":
      return .hdc(.queryProperty(.productModel))
    case "firmwareBuild":
      return .hdc(.queryProperty(.fullBuildVersion))
    case "packageInfo":
      guard case .string(let bundleName)? = inputs["bundleName"] else {
        throw DeviceProviderError.unsupportedAction("bundleName input is required")
      }
      return .hdc(.queryPackageReadback(try HDCBundleReference(bundleName: bundleName)))
    default:
      throw DeviceProviderError.unsupportedAction(
        "unregistered remote action \(reference.actionID) for \(step.stepID)")
    }
  }

  /// capture.diagnostics@1 and debug.hap@1 both capture stdout; the step
  /// id says which product is being gathered.
  private func captureAction(
    for step: CatalogStepDescriptor, inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    // Selected by the catalog's declared action, not by step-name
    // convention: renaming a step must not silently change what runs.
    // A step with no declared action gets no fallback - guessing one from
    // the step id is exactly what produced a HiLog intent labelled with a
    // UI-dump action, and the readiness forbids keeping such a path.
    guard let actionID = step.actionReference?.actionID else {
      throw DeviceProviderError.unsupportedAction(
        "\(step.stepID) declares no catalog action; refusing to infer one")
    }
    switch actionID {
    case "windowInventory":
      return .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .windowList)))
    case "componentTree":
      // No hidumper component-tree form is windowId-free, and the published
      // contract carries no windowId (diagnostics-stdout.yaml, CHG-2026-053).
      // The known windowId-free route is `uitest dumpLayout -p <remote.json>`,
      // which writes a device-side file rather than stdout, so it cannot be
      // expressed by a captureRemoteStdout step at all: adopting it needs a
      // captureRemoteFile + receiveFile + cleanup step shape, i.e. a contract
      // and Catalog change. See `DEVICE-COMMAND-FACTS.md` §7 before spending
      // another round on hidumper flag archaeology. Refusing here keeps the
      // journal from recording an intent no honest command can execute.
      throw DeviceProviderError.unsupportedAction(
        "componentTree has no windowId-free hidumper form and the published "
          + "contract carries no windowId; the windowId-free dumpLayout route "
          + "produces a device file, which a captureRemoteStdout step cannot "
          + "carry — capture windowInventory instead")
    case "boundedHilog":
      var duration = 30
      if case .integer(let requested)? = inputs["durationSeconds"] {
        duration = max(1, min(Int(requested), HDCHilogCaptureRequest.maximumDurationSeconds))
      } else if case .integer(let requested)? = inputs["diagnosticsDurationSeconds"] {
        duration = max(1, min(Int(requested), HDCHilogCaptureRequest.maximumDurationSeconds))
      }
      var filters: [String] = []
      if case .array(let requested)? = inputs["hilogFilters"] {
        filters = requested.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }
      }
      return .hdc(
        .captureHilog(try HDCHilogCaptureRequest(durationSeconds: duration, filters: filters)))
    default:
      throw DeviceProviderError.unsupportedAction(
        "unregistered stdout action \(actionID) for \(step.stepID)")
    }
  }

  private func traceRequest(from inputs: [String: JSONValue]) throws -> HDCTraceCaptureRequest {
    var categories = ["ohos"]
    if case .array(let requested)? = inputs["traceCategories"] {
      let parsed = requested.compactMap { value -> String? in
        if case .string(let text) = value { return text }
        return nil
      }
      if !parsed.isEmpty { categories = parsed }
    }
    var duration = 10
    if case .integer(let requested)? = inputs["durationSeconds"] {
      duration = max(1, min(Int(requested), HDCTraceCaptureRequest.maximumDurationSeconds))
    }
    var buffer = 8192
    if case .integer(let requested)? = inputs["traceBufferKB"] {
      buffer = max(1024, min(Int(requested), 65536))
    }
    return try HDCTraceCaptureRequest(
      durationSeconds: duration, categories: categories, bufferKB: buffer)
  }

  /// Maps debug.hap@1's steps onto typed actions. The inputs are the
  /// catalog-declared ones; nothing here accepts a device path.
  private func debugHAPAction(
    for step: CatalogStepDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard case .string(let bundleName)? = inputs["bundleName"] else {
      throw DeviceProviderError.unsupportedAction("bundleName input is required")
    }
    let bundle = try HDCBundleReference(bundleName: bundleName)
    switch step.kind {
    case .sendFile:
      guard case .string(let lease)? = inputs["hapArtifactLease"] else {
        throw DeviceProviderError.unsupportedAction("hapArtifactLease input is required")
      }
      return .hdc(
        .sendArtifactToStaging(
          HDCStagedArtifact(
            path: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: "send-hap"),
            artifactLeaseID: lease,
            expectedSHA256: context.resolvedInputArtifact?.sha256)))
    case .installPackage:
      guard case .string(let lease)? = inputs["hapArtifactLease"] else {
        throw DeviceProviderError.unsupportedAction("hapArtifactLease input is required")
      }
      return .hdc(
        .installPackage(
          HDCStagedArtifact(
            path: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: "send-hap"),
            artifactLeaseID: lease,
            expectedSHA256: context.resolvedInputArtifact?.sha256),
          bundle: bundle))
    case .runApprovedRemoteRead:
      return .hdc(.queryPackageReadback(bundle))
    case .startApplication:
      guard case .string(let abilityName)? = inputs["abilityName"] else {
        throw DeviceProviderError.unsupportedAction("abilityName input is required")
      }
      return .hdc(.startAbility(try HDCAbilityReference(bundle: bundle, abilityName: abilityName)))
    case .verifyRemoteState:
      return .hdc(.verifyProcessState(bundle))
    case .stopApplication:
      guard case .string(let abilityName)? = inputs["abilityName"] else {
        throw DeviceProviderError.unsupportedAction("abilityName input is required")
      }
      return .hdc(.stopAbility(try HDCAbilityReference(bundle: bundle, abilityName: abilityName)))
    case .uninstallPackage:
      return .hdc(.uninstallPackage(bundle))
    default:
      throw DeviceProviderError.unsupportedStepKind(step.kind.rawValue)
    }
  }

  private func nativeLibraryAction(
    for step: CatalogStepDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard case .string(let lease)? = inputs["libraryArtifactLease"] else {
      throw DeviceProviderError.unsupportedAction("libraryArtifactLease input is required")
    }
    guard case .string(let targetBundle)? = inputs["targetBundle"] else {
      throw DeviceProviderError.unsupportedAction("targetBundle input is required")
    }
    guard case .string(let logicalName)? = inputs["libraryLogicalName"] else {
      throw DeviceProviderError.unsupportedAction("libraryLogicalName input is required")
    }
    guard case .string(let abiValue)? = inputs["expectedABI"],
      let expectedABI = HDCNativeLibraryABI(rawValue: abiValue)
    else {
      throw DeviceProviderError.unsupportedAction("expectedABI input is invalid")
    }
    let restartValue: String
    if case .string(let value)? = inputs["restartProfile"] {
      restartValue = value
    } else {
      restartValue = HDCNativeRestartProfile.restartAbility.rawValue
    }
    let verificationValue: String
    if case .string(let value)? = inputs["verificationProfile"] {
      verificationValue = value
    } else {
      verificationValue = HDCNativeVerificationProfile.hashAndProcess.rawValue
    }
    let rollbackValue: String
    if case .string(let value)? = inputs["rollbackPolicy"] {
      rollbackValue = value
    } else {
      rollbackValue = HDCNativeRollbackPolicy.autoRollback.rawValue
    }
    guard let restart = HDCNativeRestartProfile(rawValue: restartValue),
      let verification = HDCNativeVerificationProfile(rawValue: verificationValue),
      let rollback = HDCNativeRollbackPolicy(rawValue: rollbackValue)
    else {
      throw DeviceProviderError.unsupportedAction("native deployment profile is invalid")
    }
    guard restart == .restartAbility else {
      throw DeviceProviderError.unsupportedAction(
        "\(restart.rawValue) has no complete app-owned restart/readback plan; refusing before authorization")
    }
    guard let resolved = context.resolvedInputArtifact,
      lease.hasSuffix(":\(resolved.artifactID)")
    else {
      throw DeviceProviderError.unsupportedAction(
        "native deployment requires an engine-resolved Artifact lease")
    }
    let bytes = try Data(contentsOf: resolved.fileURL, options: [.mappedIfSafe])
    let facts = try NativeLibraryArtifactValidator.validate(
      bytes, expectedABI: expectedABI)
    guard facts.sha256 == resolved.sha256, facts.byteCount == resolved.byteCount else {
      throw DeviceProviderError.unsupportedAction(
        "leased native Artifact bytes drifted during materialization")
    }
    let deployment = try HDCAppOwnedNativeLibraryDeployment(
      jobID: context.jobID,
      artifactLeaseID: lease,
      artifactID: resolved.artifactID,
      bundle: try HDCBundleReference(bundleName: targetBundle),
      libraryLogicalName: logicalName,
      artifactFacts: facts,
      restartProfile: restart,
      verificationProfile: verification,
      rollbackPolicy: rollback)
    switch step.stepID {
    case "send-to-staging":
      return .hdc(.sendNativeLibraryToStaging(deployment))
    case "verify-remote-staging":
      return .hdc(.inspectNativeLibrary(
        deployment, expectation: .stagingMatchesArtifact))
    case "backup-current-version":
      return .hdc(.backupNativeLibrary(deployment))
    case "atomic-publish":
      return .hdc(.publishNativeLibrary(deployment))
    case "restart-target":
      return .hdc(.stopNativeTarget(deployment))
    case "start-target":
      return .hdc(.startNativeTarget(deployment))
    case "verify-loaded-library":
      return .hdc(.inspectNativeLibrary(deployment, expectation: .targetLoaded))
    case "cleanup-staging-and-backup":
      return .hdc(.cleanupNativeLibrary(deployment))
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.stepID) has no app-owned native-library action")
    }
  }

  public func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .hdc(let hdcAction) = action else {
      throw DeviceProviderError.unsupportedAction("non-HDC action given to hdc provider")
    }
    // The argv stays provider-internal in the sense that no caller can supply
    // or extend it — but it is not a summary any more: since CHG-2026-048 T11
    // `DescriptorBoundProcessDispatcher` spawns exactly this array. Treat
    // every element below as executed, not as documentation.
    switch hdcAction {
    case .observeTool:
      return TypedProcessPlan(
        action: action,
        kind: .process(executableSHA256: "resolved-at-dispatch", argumentSummary: ["-v"], timeoutSeconds: 15))
    case .observeServer:
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch", argumentSummary: ["checkserver"],
          timeoutSeconds: 15))
    case .listDeviceCandidates, .observeDevice:
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["list", "targets", "-v"], timeoutSeconds: 15))
    case .queryProperty(let property):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "param", "get", property.rawValue], context: context),
          timeoutSeconds: 15))
    case .observeStorage:
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "df", "-k", HDCStoragePreflightRequest.remotePath],
            context: context),
          timeoutSeconds: 30))
    case .captureHilog(let request):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "hilog", "-x"] + request.filters, context: context),
          timeoutSeconds: request.durationSeconds + 15))
    case .captureUIDump(let request):
      switch request.scope {
      case .windowList:
        // Device-validated INV-1 form (CHG-2026-008): the only window-family
        // hidumper invocation that needs no windowId.
        return TypedProcessPlan(
          action: action,
          kind: .process(
            executableSHA256: "resolved-at-dispatch",
            argumentSummary: try deviceArguments(
              ["shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"],
              context: context),
            timeoutSeconds: 30))
      case .componentTree:
        // The hidumper forms are window-scoped (-w <windowId> …) and the
        // published contract carries no windowId; a scope.rawValue service
        // name is not a hidumper service and would capture error text. The
        // windowId-free alternative (`uitest dumpLayout`) is file-producing,
        // not stdout-producing, so it needs a different step kind — see
        // `DEVICE-COMMAND-FACTS.md` §7 and D1 in its §10 ledger.
        throw DeviceProviderError.unsupportedAction(
          "componentTree UI dump has no honest windowId-free stdout lowering; "
            + "use windowList until the windowId contract revision or a "
            + "file-producing dumpLayout step shape lands")
      }
    case .captureTrace(let request, let path):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "hitrace", "-t", String(request.durationSeconds), "-b",
              String(request.bufferKB)] + request.categories + ["-o", path.remotePath],
            context: context),
          timeoutSeconds: request.durationSeconds + 30))
    case .receiveOwnedArtifact(let artifact):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["file", "recv", artifact.path.remotePath], context: context),
          timeoutSeconds: 60))
    case .cleanupOwnedRemotePath(let path):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "rm", "-f", path.remotePath], context: context),
          timeoutSeconds: 15))
    case .sendArtifactToStaging(let staged):
      guard let resolved = context.resolvedInputArtifact,
        staged.artifactLeaseID.hasSuffix(":\(resolved.artifactID)"),
        staged.expectedSHA256 == resolved.sha256
      else {
        throw DeviceProviderError.unsupportedAction(
          "sendFile requires an engine-resolved Artifact lease")
      }
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["file", "send", resolved.fileURL.path, staged.path.remotePath],
            context: context),
          timeoutSeconds: 300))
    case .installPackage(let staged, _):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            [
              "shell", "bm", "install", "-p", staged.path.remotePath, "-r",
            ], context: context),
          timeoutSeconds: 300))
    case .queryPackageReadback(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "bm", "dump", "-n", bundle.bundleName], context: context),
          timeoutSeconds: 30))
    case .startAbility(let ability):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            [
              "shell", "aa", "start", "-b", ability.bundle.bundleName, "-a",
              ability.abilityName,
            ],
            context: context),
          timeoutSeconds: 60))
    case .verifyProcessState(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "pidof", bundle.bundleName], context: context),
          timeoutSeconds: 30))
    case .stopAbility(let ability):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "aa", "force-stop", ability.bundle.bundleName],
            context: context),
          timeoutSeconds: 60))
    case .uninstallPackage(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["uninstall", bundle.bundleName], context: context),
          timeoutSeconds: 120))
    case .createPortForward(let spec):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["fport", "tcp:\(spec.localPort)", "tcp:\(spec.remotePort)"],
            context: context),
          timeoutSeconds: 30))
    case .removePortForward(let spec):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["fport", "rm", "tcp:\(spec.localPort)"], context: context),
          timeoutSeconds: 30))
    case .readPackagePresence(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "bm", "dump", "-n", bundle.bundleName], context: context),
          timeoutSeconds: 30))
    case .readProcessPresence(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "pidof", bundle.bundleName], context: context),
          timeoutSeconds: 30))
    case .readOwnedPathPresence(let path):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "ls", "-ld", path.remotePath], context: context),
          timeoutSeconds: 15))
    case .readPortForwardPresence:
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(["fport", "ls"], context: context),
          timeoutSeconds: 30))
    case .sendNativeLibraryToStaging(let deployment):
      guard let resolved = context.resolvedInputArtifact,
        deployment.artifactID == resolved.artifactID,
        deployment.artifactFacts.sha256 == resolved.sha256,
        deployment.artifactFacts.byteCount == resolved.byteCount,
        deployment.stagingDirectoryIsJobOwned
      else {
        throw DeviceProviderError.unsupportedAction(
          "native send requires the same engine-resolved Artifact and a job-owned staging directory")
      }
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "mkdir", "-p", deployment.stagingDirectoryPath], false, 30),
          (["file", "send", resolved.fileURL.path, deployment.stagingPath], false, 300),
        ])
    case .backupNativeLibrary(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "ls", "-ld", deployment.directoryPath], false, 15),
          (["shell", "ls", "-l", deployment.targetPath], false, 15),
          (["shell", "sha256sum", deployment.targetPath], false, 30),
          (["shell", "cp", "-p", deployment.targetPath, deployment.backupPath], true, 60),
          (["shell", "sha256sum", deployment.backupPath], true, 30),
          (["shell", "ls", "-l", deployment.backupPath], true, 15),
          // Keep firmware-layout diagnosis inside this typed provider action.
          // Failure reporting only exposes a bounded hex prefix.
          (["shell", "ls", "-la", deployment.nativeLibrariesRootPath], true, 15),
        ])
    case .publishNativeLibrary(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "ls", "-ln", deployment.targetPath], false, 15),
          ([
            "shell", "cp", "-p", deployment.targetPath,
            deployment.rollbackStagingPath,
          ], false, 60),
          ([
            "shell", "cp", deployment.stagingPath, deployment.rollbackStagingPath,
          ], false, 60),
          (["shell", "ls", "-ln", deployment.rollbackStagingPath], false, 15),
          (["shell", "sha256sum", deployment.rollbackStagingPath], false, 30),
          ([
            "shell", "mv", "-f", deployment.rollbackStagingPath,
            deployment.targetPath,
          ], false, 60),
          (["shell", "sha256sum", deployment.targetPath], false, 30),
          (["shell", "ls", "-ln", deployment.targetPath], false, 15),
        ])
    case .stopNativeTarget(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "aa", "force-stop", deployment.bundle.bundleName], true, 60),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
        ])
    case .startNativeTarget(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          ([
            "shell", "aa", "start", "-b", deployment.bundle.bundleName, "-a",
            HDCAppOwnedNativeLibraryDeployment.entryAbility,
          ], true, 60),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
        ])
    case .cleanupNativeLibrary(let deployment):
      var commands: [([String], Bool, Int)] = [
        (["shell", "rm", "-f", deployment.stagingPath], true, 30),
      ]
      if deployment.stagingDirectoryIsJobOwned {
        commands.append(
          (["shell", "rmdir", deployment.stagingDirectoryPath], true, 30))
      }
      commands.append(
        (["shell", "rm", "-f", deployment.rollbackStagingPath], true, 30))
      if deployment.rollbackPolicy == .autoRollback {
        commands.append((["shell", "rm", "-f", deployment.backupPath], true, 30))
      }
      commands.append((["shell", "ls", "-ld", deployment.stagingPath], true, 15))
      if deployment.stagingDirectoryIsJobOwned {
        commands.append(
          (["shell", "ls", "-ld", deployment.stagingDirectoryPath], true, 15))
      }
      commands.append((["shell", "ls", "-ld", deployment.rollbackStagingPath], true, 15))
      if deployment.rollbackPolicy == .autoRollback {
        commands.append((["shell", "ls", "-ld", deployment.backupPath], true, 15))
      }
      return try nativeSequence(action: action, context: context, commands: commands)
    case .rollbackNativeLibrary(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "sha256sum", deployment.backupPath], false, 30),
          (["shell", "aa", "force-stop", deployment.bundle.bundleName], true, 60),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
          ([
            "shell", "cp", "-p", deployment.backupPath, deployment.rollbackStagingPath,
          ], true, 60),
          (["shell", "sha256sum", deployment.rollbackStagingPath], true, 30),
          ([
            "shell", "mv", "-f", deployment.rollbackStagingPath, deployment.targetPath,
          ], true, 60),
          (["shell", "sha256sum", deployment.targetPath], true, 30),
          ([
            "shell", "aa", "start", "-b", deployment.bundle.bundleName, "-a",
            HDCAppOwnedNativeLibraryDeployment.entryAbility,
          ], true, 60),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
          ([
            "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
          ], true, 30),
        ])
    case .inspectNativeLibrary(let deployment, let expectation):
      return try nativeInspectionPlan(
        action: action, deployment: deployment,
        expectation: expectation, context: context)
    }
  }

  private func nativeSequence(
    action: TypedProviderAction,
    context: ProviderExecutionContext,
    commands: [([String], Bool, Int)]
  ) throws -> TypedProcessPlan {
    TypedProcessPlan(
      action: action,
      kind: .processSequence(
        executableSHA256: "resolved-at-dispatch",
        invocations: try commands.map { command in
          TypedProcessInvocation(
            arguments: try deviceArguments(command.0, context: context),
            timeoutSeconds: command.2,
            continueAfterNonZero: command.1)
        }))
  }

  private func nativeInspectionPlan(
    action: TypedProviderAction,
    deployment: HDCAppOwnedNativeLibraryDeployment,
    expectation: HDCNativeLibraryInspection,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    let commands: [([String], Bool, Int)]
    switch expectation {
    case .stagingMatchesArtifact:
      commands = [
        (["shell", "sha256sum", deployment.stagingPath], true, 30),
        (["shell", "ls", "-l", deployment.stagingPath], true, 15),
      ]
    case .backupMatchesTarget:
      commands = [
        (["shell", "sha256sum", deployment.targetPath], true, 30),
        (["shell", "sha256sum", deployment.backupPath], true, 30),
      ]
    case .targetMatchesArtifact:
      commands = [
        (["shell", "sha256sum", deployment.targetPath], true, 30)
      ]
    case .targetStopped, .targetStarted:
      commands = [
        (["shell", "pidof", deployment.bundle.bundleName], true, 30)
      ]
    case .targetLoaded:
      var selected: [([String], Bool, Int)] = [
        (["shell", "sha256sum", deployment.targetPath], true, 30)
      ]
      if deployment.verificationProfile != .hashOnly {
        selected.append(
          (["shell", "pidof", deployment.bundle.bundleName], true, 30))
      }
      if deployment.verificationProfile == .hashProcessAndMaps {
        selected.append(
          ([
            "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
          ], true, 30))
      }
      commands = selected
    case .cleanupComplete:
      var selected: [([String], Bool, Int)] = [
        (["shell", "ls", "-ld", deployment.stagingPath], true, 15),
      ]
      if deployment.stagingDirectoryIsJobOwned {
        selected.append(
          (["shell", "ls", "-ld", deployment.stagingDirectoryPath], true, 15))
      }
      selected.append(
        (["shell", "ls", "-ld", deployment.rollbackStagingPath], true, 15))
      if deployment.rollbackPolicy == .autoRollback {
        selected.append(
          (["shell", "ls", "-ld", deployment.backupPath], true, 15))
      }
      commands = selected
    case .rollbackRestored:
      var selected: [([String], Bool, Int)] = [
        (["shell", "sha256sum", deployment.targetPath], true, 30),
        (["shell", "sha256sum", deployment.backupPath], true, 30),
        (["shell", "pidof", deployment.bundle.bundleName], true, 30),
      ]
      if deployment.verificationProfile == .hashProcessAndMaps {
        selected.append(
          ([
            "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
          ], true, 30))
      }
      commands = selected
    }
    return try nativeSequence(action: action, context: context, commands: commands)
  }

  private func deviceArguments(
    _ arguments: [String],
    context: ProviderExecutionContext
  ) throws -> [String] {
    guard let connectKey = context.connectKey, !connectKey.isEmpty else {
      throw DeviceProviderError.factsUnavailable(
        "\(context.stepID) has no descriptor-bound target connect key")
    }
    return ["-t", connectKey] + arguments
  }

  /// `param get <key>` answers either with the bare value or with
  /// `<key> = <value>`, depending on the device's init/param build. Recording
  /// the echoed form verbatim puts `const.product.model = DAYU200` into
  /// evidence where the value belongs (see `DEVICE-COMMAND-FACTS.md` §3.5).
  ///
  /// The prefix is stripped only when the output actually begins with the key
  /// this step asked for: a blind "cut at the first `=`" would truncate any
  /// value that legitimately contains one.
  static func propertyValue(
    fromParamGetOutput output: String, requestedKey: String
  ) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(requestedKey) else { return trimmed }
    let remainder = trimmed.dropFirst(requestedKey.count)
      .drop(while: { $0 == " " || $0 == "\t" })
    guard remainder.first == "=" else { return trimmed }
    return remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Mints a provider-owned staging path for an artifact lease. As with
  /// remote temp paths, the caller never supplies a device location.
  public func mintStagedArtifact(
    jobID: String, stepID: String, artifactLeaseID: String, expectedSHA256: String?
  ) throws -> HDCStagedArtifact {
    HDCStagedArtifact(
      path: try mintOwnedRemotePath(jobID: jobID, stepID: stepID),
      artifactLeaseID: artifactLeaseID, expectedSHA256: expectedSHA256)
  }

  /// Mints a provider-owned remote temp path bound to job/step. The only
  /// construction point outside tests; callers cannot supply device paths.
  public func mintOwnedRemotePath(jobID: String, stepID: String) throws -> HDCOwnedRemotePath {
    try HDCOwnedRemotePath(
      jobID: jobID, stepID: stepID, nonce: UUID().uuidString.prefix(8).lowercased())
  }

  /// Reconstructible path for a durable job recipe. All paired actions
  /// (capture/receive/cleanup or send/install/cleanup) derive the same
  /// provider-owned path without persisting or accepting a raw path.
  private func mintStableOwnedRemotePath(
    jobID: String, stepID: String
  ) throws -> HDCOwnedRemotePath {
    try HDCOwnedRemotePath(jobID: jobID, stepID: stepID, nonce: "owned")
  }

  public func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    guard case .hdc(let hdcAction) = action else {
      throw DeviceProviderError.unsupportedAction("non-HDC action given to hdc provider")
    }
    switch hdcAction {
    case .observeServer:
      // `checkserver` has its own output shape; the first device window
      // proved that reusing the `-v` parser here fails on real hardware.
      switch HDCObservationSemanticParser.parseServerCheck(
        stdout: receipt.stdout, profile: profile, truncated: receipt.stdoutTruncated)
      {
      case .parsed(let check):
        guard check.versionsAgree else {
          return .failed(
            code: "serverVersionMismatch",
            detail: "client \(check.clientVersion) vs server \(check.serverVersion)")
        }
        return .verified(summary: [
          "clientVersion": check.clientVersion, "serverVersion": check.serverVersion,
        ])
      case .unsupportedVersion(let version):
        return .unsupported(reason: "unregistered HDC version \(version)")
      case .invalidEncoding:
        return .failed(code: "invalidEncoding", detail: "stdout is not valid UTF-8")
      case .truncated:
        return .failed(code: "truncated", detail: "stdout exceeded its byte budget")
      case .empty:
        return .unknown(reason: "empty server check output")
      case .malformed(let reason):
        return .unknown(reason: reason)
      }
    case .observeTool:
      switch HDCObservationSemanticParser.parseClientVersion(
        stdout: receipt.stdout, profile: profile, truncated: receipt.stdoutTruncated)
      {
      case .parsed(let value):
        return .verified(summary: ["toolVersion": value.version])
      case .unsupportedVersion(let version):
        return .unsupported(reason: "unregistered HDC version \(version)")
      case .invalidEncoding:
        return .failed(code: "invalidEncoding", detail: "stdout is not valid UTF-8")
      case .truncated:
        return .failed(code: "truncated", detail: "stdout exceeded its byte budget")
      case .empty:
        return .unknown(reason: "empty observation output")
      case .malformed(let reason):
        return .unknown(reason: reason)
      }
    case .listDeviceCandidates:
      // Target-list verification needs the tool version fact to select the
      // profile arm; absent facts are unknown, never assumed.
      switch HDCObservationSemanticParser.parseTargetList(
        stdout: receipt.stdout, profile: profile,
        toolVersion: profile.registeredVersions.sorted().last ?? "",
        truncated: receipt.stdoutTruncated)
      {
      case .parsed(let list):
        // connectKeys lets the composition root drive bootstrap selection
        // without re-parsing device output outside the provider.
        return .verified(summary: [
          "targetCount": String(list.targets.count),
          "connectKeys": list.targets.map { "\($0.connectKey)=\($0.state)" }
            .joined(separator: ","),
        ])
      case .unsupportedVersion(let version):
        return .unsupported(reason: "unregistered HDC version \(version)")
      case .invalidEncoding:
        return .failed(code: "invalidEncoding", detail: "stdout is not valid UTF-8")
      case .truncated:
        return .failed(code: "truncated", detail: "stdout exceeded its byte budget")
      case .empty:
        return .unknown(reason: "empty observation output")
      case .malformed(let reason):
        return .unknown(reason: reason)
      }
    case .observeDevice(let actionConnectKey):
      switch HDCObservationSemanticParser.parseTargetList(
        stdout: receipt.stdout, profile: profile,
        toolVersion: context.toolVersion ?? profile.registeredVersions.sorted().last ?? "",
        truncated: receipt.stdoutTruncated)
      {
      case .parsed(let list):
        let expectedConnectKey =
          actionConnectKey == "resolved-by-binding" ? context.connectKey : actionConnectKey
        guard let expectedConnectKey, !expectedConnectKey.isEmpty else {
          return .failed(
            code: "targetFactsUnavailable",
            detail: "descriptor-bound connect key is absent")
        }
        let matches = list.targets.filter { $0.connectKey == expectedConnectKey }
        guard matches.count == 1, let match = matches.first else {
          return .failed(
            code: "targetConfirmationMismatch",
            detail: "expected exactly one matching target row, saw \(matches.count)")
        }
        guard match.state == "Connected" else {
          return .failed(
            code: "targetNotConnected", detail: "matching target state is \(match.state)")
        }
        let identity = SHA256.hash(data: Data(expectedConnectKey.lowercased().utf8))
          .map { String(format: "%02x", $0) }.joined()
        if let expectedIdentity = context.expectedIdentitySHA256,
          identity != expectedIdentity.lowercased()
        {
          return .failed(
            code: "targetIdentityMismatch",
            detail: "matching target row does not match the adopted stable identity")
        }
        return .verified(summary: [
          "deviceIdentitySHA256": identity,
          "transport": match.transport,
          "state": match.state,
        ])
      case .unsupportedVersion(let version):
        return .unsupported(reason: "unregistered HDC version \(version)")
      case .invalidEncoding:
        return .failed(code: "invalidEncoding", detail: "stdout is not valid UTF-8")
      case .truncated:
        return .failed(code: "truncated", detail: "stdout exceeded its byte budget")
      case .empty:
        return .unknown(reason: "empty observation output")
      case .malformed(let reason):
        return .unknown(reason: reason)
      }
    case .queryProperty(let property):
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "property output exceeded budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "property output is not UTF-8")
      }
      let value = Self.propertyValue(
        fromParamGetOutput: text, requestedKey: property.rawValue)
      guard !value.isEmpty, value.count <= 400 else {
        return .unknown(reason: "property value empty or oversized")
      }
      return .verified(summary: ["value": value])
    case .observeStorage(let request):
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "storage output exceeded budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "storage output is not UTF-8")
      }
      let availableKilobytes = text.split(whereSeparator: \.isNewline)
        .dropFirst()
        .compactMap { line -> UInt64? in
          let fields = line.split(whereSeparator: \.isWhitespace)
          guard fields.count >= 4 else { return nil }
          return UInt64(fields[3])
        }
        .last
      guard let availableKilobytes,
        availableKilobytes <= UInt64.max / 1024
      else {
        return .unknown(reason: "storage output has no bounded available-byte observation")
      }
      let availableBytes = availableKilobytes * 1024
      guard availableBytes >= UInt64(request.requiredBytes) else {
        return .failed(
          code: "insufficientDeviceStorage",
          detail: "requires \(request.requiredBytes) bytes; \(availableBytes) available")
      }
      return .verified(summary: ["availableBytes": String(availableBytes)])
    case .captureHilog:
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "capture exceeded its byte budget")
      }
      guard !receipt.stdout.isEmpty else {
        return .unknown(reason: "empty capture output")
      }
      // HiLog is a raw sensitive Artifact. Real DAYU200 output can contain
      // non-UTF-8 payload bytes from applications; rejecting those bytes
      // silently drops the requested evidence. Preserve them byte-for-byte
      // under the sensitive read gate. Strict-redaction requests remain
      // unavailable before authorization elsewhere in the engine.
      return .verified(summary: ["byteCount": String(receipt.stdout.count)])
    case .captureUIDump:
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "capture exceeded its byte budget")
      }
      guard String(data: receipt.stdout, encoding: .utf8) != nil else {
        return .failed(code: "invalidEncoding", detail: "UI dump is not UTF-8")
      }
      guard !receipt.stdout.isEmpty else {
        return .unknown(reason: "empty capture output")
      }
      return .verified(summary: ["byteCount": String(receipt.stdout.count)])
    case .captureTrace:
      // Trace success is decided by the subsequent artifact receive with
      // its size/hash checks; here only process-level sanity applies.
      guard receipt.exitStatus == 0 else {
        return .unknown(reason: "trace capture process did not report clean completion")
      }
      return .verified(summary: ["remoteCaptured": "pending-receive"])
    case .receiveOwnedArtifact(let artifact):
      guard let localReference = receipt.hostManagedRecordID else {
        return .unknown(reason: "receive produced no local artifact reference")
      }
      if let expected = artifact.expectedSHA256 {
        return .verified(summary: [
          "localArtifact": localReference, "expectedSha256": expected,
        ])
      }
      return .verified(summary: ["localArtifact": localReference])
    case .cleanupOwnedRemotePath(let path):
      guard receipt.exitStatus == 0 else {
        // Cleanup failure is debt, never silently dropped - the engine
        // records it for later reconcile.
        return .failed(code: "cleanupDebt", detail: "remote cleanup failed for \(path.remotePath)")
      }
      return .verified(summary: ["cleaned": path.remotePath])

    case .sendArtifactToStaging(let staged):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "sendFailed", detail: "artifact transfer did not complete")
      }
      return .verified(summary: ["stagedAt": staged.path.remotePath])

    case .sendNativeLibraryToStaging:
      guard receipt.exitStatus == 0 else {
        return .failed(
          code: "nativeSendFailed",
          detail: "native library transfer did not complete")
      }
      return .unknown(
        reason: "native staging send requires remote hash readback")

    case .backupNativeLibrary(let deployment):
      guard receipt.subprocesses.count == 7 else {
        return .unknown(reason: "native backup did not produce its complete readback sequence")
      }
      let observedTargetHash = sha256(receipt.subprocesses[2])
      let observedBackupHash = sha256(receipt.subprocesses[4])
      let observedBackupMatches =
        observedBackupHash != nil && observedBackupHash == observedTargetHash
      guard isDirectoryListing(receipt.subprocesses[0]),
        isRegularFileListing(receipt.subprocesses[1]),
        let targetHash = observedTargetHash,
        let backupHash = observedBackupHash,
        targetHash == backupHash,
        isRegularFileListing(receipt.subprocesses[5])
      else {
        let diagnostics = receipt.subprocesses.enumerated().map {
          "\($0.offset):\(boundedProcessDiagnostic($0.element))"
        }.joined(separator: ";")
        return .failed(
          code: "nativeBackupMismatch",
          detail:
            "app-owned directory, original file or verified backup snapshot is invalid "
            + "(directoryExit=\(exitSummary(receipt.subprocesses[0])), "
            + "directoryListed=\(isDirectoryListing(receipt.subprocesses[0])), "
            + "targetExit=\(exitSummary(receipt.subprocesses[1])), "
            + "targetListed=\(isRegularFileListing(receipt.subprocesses[1])), "
            + "targetHashExit=\(exitSummary(receipt.subprocesses[2])), "
            + "targetHashPresent=\(observedTargetHash != nil), "
            + "copyExit=\(exitSummary(receipt.subprocesses[3])), "
            + "backupHashExit=\(exitSummary(receipt.subprocesses[4])), "
            + "backupHashMatches=\(observedBackupMatches), "
            + "backupExit=\(exitSummary(receipt.subprocesses[5])), "
            + "backupListed=\(isRegularFileListing(receipt.subprocesses[5])), "
            + "diagnostics=\(diagnostics))")
      }
      return .verified(summary: [
        "backupSha256": backupHash,
        "backupPath": deployment.backupPath,
      ])

    case .publishNativeLibrary(let deployment):
      guard receipt.subprocesses.count == 8,
        let originalIdentity = nativeFileIdentity(receipt.subprocesses[0]),
        let preparedIdentity = nativeFileIdentity(receipt.subprocesses[3]),
        let publishedIdentity = nativeFileIdentity(receipt.subprocesses[7]),
        originalIdentity == preparedIdentity,
        preparedIdentity == publishedIdentity,
        sha256(receipt.subprocesses[4]) == deployment.artifactFacts.sha256,
        sha256(receipt.subprocesses[6]) == deployment.artifactFacts.sha256
      else {
        return .failed(
          code: "nativePublishMismatch",
          detail:
            "atomic publish did not preserve app-owned mode/uid/gid "
            + "or read back the leased ELF hash")
      }
      return .verified(summary: [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "targetPath": deployment.targetPath,
        "mode": originalIdentity.mode,
        "uid": String(originalIdentity.userID),
        "gid": String(originalIdentity.groupID),
      ])

    case .stopNativeTarget(let deployment):
      guard receipt.subprocesses.count == 4 else {
        return .unknown(
          reason: "native stop did not produce its complete bounded readback sequence")
      }
      let forceStop = receipt.subprocesses[0]
      let finalReadback = receipt.subprocesses[3]
      guard processIsAbsent(finalReadback) else {
        return .failed(
          code: "nativeTargetStillRunning",
          detail:
            "\(deployment.bundle.bundleName) remained live after stop "
            + "(forceStopExit=\(exitSummary(forceStop)), "
            + "pidofExit=\(exitSummary(finalReadback)), "
            + "pids=\(pidSummary(finalReadback)), "
            + "stdoutBytes=\(finalReadback.stdout.count), "
            + "stderrBytes=\(finalReadback.stderr.count))")
      }
      return .verified(summary: ["stopped": deployment.bundle.bundleName])

    case .startNativeTarget(let deployment):
      guard receipt.subprocesses.count == 3,
        let pids = processIDs(receipt.subprocesses[2]), !pids.isEmpty
      else {
        return .failed(
          code: "nativeTargetNotRunning",
          detail: "\(deployment.bundle.bundleName) did not start")
      }
      return .verified(summary: [
        "started": deployment.bundle.bundleName,
        "processIds": pids.map(String.init).joined(separator: ","),
      ])

    case .cleanupNativeLibrary(let deployment):
      let absenceCount =
        2 + (deployment.stagingDirectoryIsJobOwned ? 1 : 0)
        + (deployment.rollbackPolicy == .autoRollback ? 1 : 0)
      guard receipt.subprocesses.count >= absenceCount,
        receipt.subprocesses.suffix(absenceCount).allSatisfy(pathIsAbsent)
      else {
        return .failed(
          code: "cleanupDebt",
          detail: "native staging or backup path remains after cleanup")
      }
      return .verified(summary: [
        "cleaned": deployment.stagingPath,
        "backupRetained": String(deployment.rollbackPolicy == .retainBackup),
      ])

    case .rollbackNativeLibrary(let deployment):
      guard receipt.subprocesses.count == 13 else {
        return .unknown(
          reason: "native rollback did not produce its complete bounded readback sequence")
      }
      let backupHash = sha256(receipt.subprocesses[0])
      let stopReadback = receipt.subprocesses[4]
      let rollbackHash = sha256(receipt.subprocesses[6])
      let restoredHash = sha256(receipt.subprocesses[8])
      let pids = processIDs(receipt.subprocesses[11])
      let mapsMatched =
        pids.map {
          mapsContain(
            receipt.subprocesses[12],
            targetPath: deployment.loaderVisiblePath, pids: $0)
        } ?? false
      guard let backupHash,
        processIsAbsent(stopReadback),
        rollbackHash == backupHash,
        restoredHash == backupHash,
        let pids, !pids.isEmpty,
        mapsMatched
      else {
        return .failed(
          code: "nativeRollbackVerificationFailed",
          detail:
            "previous library bytes and loader state were not both restored "
            + "(forceStopExit=\(exitSummary(receipt.subprocesses[1])), "
            + "pidofExit=\(exitSummary(stopReadback)), "
            + "stopPids=\(pidSummary(stopReadback)), "
            + "rollbackHashMatches=\(rollbackHash != nil && rollbackHash == backupHash), "
            + "targetHashMatches=\(restoredHash != nil && restoredHash == backupHash), "
            + "startExit=\(exitSummary(receipt.subprocesses[9])), "
            + "startedPids=\(pids?.map(String.init).joined(separator: ",") ?? "none"), "
            + "mapsMatched=\(mapsMatched))")
      }
      return .verified(summary: [
        "restoredSha256": backupHash,
        "restored": "true",
        "processIds": pids.map(String.init).joined(separator: ","),
      ])

    case .inspectNativeLibrary(let deployment, let expectation):
      return verifyNativeInspection(
        receipt, deployment: deployment, expectation: expectation)

    case .installPackage:
      // Deliberately never `.verified`: an install is only as true as its
      // readback, and hardware has shown `hdc install` exiting zero
      // without installing. The orchestration requires the paired
      // queryPackageReadback step to decide.
      guard let exitStatus = receipt.exitStatus else {
        return .unknown(reason: "install produced no process result")
      }
      guard exitStatus == 0 else {
        return .failed(code: "installFailed", detail: "install process reported failure")
      }
      return .unknown(reason: "install requires package readback before it can be believed")

    case .queryPackageReadback(let bundle):
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "package readback exceeded its budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "package readback is not UTF-8")
      }
      let escaped = NSRegularExpression.escapedPattern(for: bundle.bundleName)
      let installed =
        text.range(
          of: "(^|[^A-Za-z0-9_.])\(escaped)([^A-Za-z0-9_.]|$)",
          options: .regularExpression) != nil
      guard installed else {
        return .failed(
          code: "packageNotInstalled",
          detail: "readback does not list \(bundle.bundleName)")
      }
      return .verified(summary: ["bundleName": bundle.bundleName, "installed": "true"])

    case .startAbility:
      guard let exitStatus = receipt.exitStatus else {
        return .unknown(reason: "start produced no process result")
      }
      guard exitStatus == 0 else {
        return .failed(code: "startFailed", detail: "start process reported failure")
      }
      return .unknown(reason: "start requires process readback before it can be believed")

    case .verifyProcessState(let bundle):
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "process readback is not UTF-8")
      }
      let processIDs = text.split(whereSeparator: \.isWhitespace)
      guard !processIDs.isEmpty,
        processIDs.allSatisfy({ token in
          guard let value = UInt32(token) else { return false }
          return value > 0
        })
      else {
        return .failed(
          code: "processNotRunning", detail: "no live process for \(bundle.bundleName)")
      }
      return .verified(summary: ["bundleName": bundle.bundleName, "running": "true"])

    // Known-weak pair (D2 in `DEVICE-COMMAND-FACTS.md` §10): unlike install and
    // start above, these two still believe the exit status alone, and the
    // exit status of an `hdc shell aa`/`bm` invocation is the client's, not
    // the remote command's. `bm uninstall` in particular answers
    // `uninstall missing installed bundle` on a clean exit when the bundle
    // was never there. Closing this needs one of: a device window that pins
    // the status strings, or a readback step after stop/uninstall
    // (debug.hap@1 has none today, so returning `.unknown` here would drive
    // every run into reconcileRequired). Do not guess the strings.
    case .stopAbility(let ability):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "stopFailed", detail: "could not stop \(ability.bundle.bundleName)")
      }
      return .verified(summary: ["stopped": ability.bundle.bundleName])

    case .uninstallPackage(let bundle):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "uninstallFailed", detail: "could not uninstall \(bundle.bundleName)")
      }
      return .verified(summary: ["uninstalled": bundle.bundleName])

    case .createPortForward(let spec), .removePortForward(let spec):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "portForwardFailed", detail: "tcp:\(spec.localPort)")
      }
      return .verified(summary: ["localPort": String(spec.localPort)])
    case .readPackagePresence(let bundle):
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
        let text = String(data: receipt.stdout, encoding: .utf8)
      else {
        return .unknown(reason: "package presence readback is not trustworthy")
      }
      let escaped = NSRegularExpression.escapedPattern(for: bundle.bundleName)
      let present =
        text.range(
          of: "(^|[^A-Za-z0-9_.])\(escaped)([^A-Za-z0-9_.]|$)",
          options: .regularExpression) != nil
      return .verified(summary: ["present": present ? "true" : "false"])
    case .readProcessPresence:
      guard !receipt.stdoutTruncated,
        let text = String(data: receipt.stdout, encoding: .utf8)
      else {
        return .unknown(reason: "process presence readback is not trustworthy")
      }
      let tokens = text.split(whereSeparator: \.isWhitespace)
      if receipt.exitStatus == 1, tokens.isEmpty {
        return .verified(summary: ["present": "false"])
      }
      guard receipt.exitStatus == 0, !tokens.isEmpty,
        tokens.allSatisfy({ token in
          guard let value = UInt32(token) else { return false }
          return value > 0
        })
      else {
        return .unknown(reason: "process presence readback is ambiguous")
      }
      return .verified(summary: ["present": "true"])
    case .readOwnedPathPresence:
      guard
        let present = pathPresence(
          exitStatus: receipt.exitStatus,
          stdout: receipt.stdout,
          stderr: receipt.stderr,
          stdoutTruncated: receipt.stdoutTruncated)
      else {
        return .unknown(reason: "owned-path presence readback has no definite result")
      }
      return .verified(summary: ["present": present ? "true" : "false"])
    case .readPortForwardPresence(let spec):
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
        let text = String(data: receipt.stdout, encoding: .utf8)
      else {
        return .unknown(reason: "port-forward presence readback is not trustworthy")
      }
      let expected = ["tcp:\(spec.localPort)", "tcp:\(spec.remotePort)"]
      let present = text.split(whereSeparator: \.isNewline).contains { line in
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        return expected.allSatisfy(fields.contains)
      }
      return .verified(summary: ["present": present ? "true" : "false"])
    }
  }

  private func verifyNativeInspection(
    _ receipt: ProviderProcessReceipt,
    deployment: HDCAppOwnedNativeLibraryDeployment,
    expectation: HDCNativeLibraryInspection
  ) -> ProviderSemanticOutcome {
    let subprocesses = receipt.subprocesses
    switch expectation {
    case .stagingMatchesArtifact:
      let observedStagingHash = subprocesses.first.flatMap(sha256)
      let observedHashExit = subprocesses.first.map(exitSummary) ?? "missing"
      let observedListing = subprocesses.dropFirst().first
      let observedListingExit = observedListing.map(exitSummary) ?? "missing"
      let observedRegularFile = observedListing.map(isRegularFileListing) ?? false
      guard subprocesses.count == 2,
        observedStagingHash == deployment.artifactFacts.sha256,
        isRegularFileListing(subprocesses[1])
      else {
        return .failed(
          code: "nativeStagingMismatch",
          detail:
            "remote staging bytes do not match the leased ELF "
            + "(hashExit=\(observedHashExit), "
            + "hashMatches=\(observedStagingHash == deployment.artifactFacts.sha256), "
            + "listingExit=\(observedListingExit), "
            + "regularFile=\(observedRegularFile))")
      }
      return .verified(summary: [
        "remoteSha256": deployment.artifactFacts.sha256,
        "remoteByteCount": String(deployment.artifactFacts.byteCount),
        "buildId": deployment.artifactFacts.buildID,
      ])
    case .backupMatchesTarget:
      guard subprocesses.count == 2,
        let targetHash = sha256(subprocesses[0]),
        sha256(subprocesses[1]) == targetHash
      else {
        return .failed(
          code: "nativeBackupMismatch", detail: "backup differs from the current target")
      }
      return .verified(summary: ["backupSha256": targetHash])
    case .targetMatchesArtifact:
      guard subprocesses.count == 1,
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256
      else {
        return .failed(
          code: "nativeTargetHashMismatch", detail: "published target hash differs")
      }
      return .verified(summary: ["publishedSha256": deployment.artifactFacts.sha256])
    case .targetStopped:
      guard subprocesses.count == 1, processIsAbsent(subprocesses[0]) else {
        return .failed(
          code: "nativeTargetStillRunning", detail: "target process is still present")
      }
      return .verified(summary: ["running": "false"])
    case .targetStarted:
      guard subprocesses.count == 1,
        let pids = processIDs(subprocesses[0]), !pids.isEmpty
      else {
        return .failed(
          code: "nativeTargetNotRunning", detail: "target process is absent")
      }
      return .verified(summary: [
        "running": "true", "processIds": pids.map(String.init).joined(separator: ","),
      ])
    case .targetLoaded:
      guard !subprocesses.isEmpty,
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256
      else {
        return .failed(
          code: "nativeTargetHashMismatch",
          detail: "loader verification target hash differs from the leased ELF")
      }
      var summary = [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "abi": deployment.artifactFacts.abi.rawValue,
      ]
      if deployment.verificationProfile != .hashOnly {
        guard subprocesses.count >= 2,
          let pids = processIDs(subprocesses[1]), !pids.isEmpty
        else {
          return .failed(
            code: "nativeTargetNotRunning",
            detail: "loader verification found no target process")
        }
        summary["processIds"] = pids.map(String.init).joined(separator: ",")
        if deployment.verificationProfile == .hashProcessAndMaps {
          guard subprocesses.count == 3,
            mapsContain(
              subprocesses[2], targetPath: deployment.loaderVisiblePath,
              pids: pids)
          else {
            return .failed(
              code: "nativeLibraryNotLoaded",
              detail: "target process maps do not contain the published app-owned library")
          }
          summary["loaderVerified"] = "true"
        }
      }
      return .verified(summary: summary)
    case .cleanupComplete:
      let expectedCount =
        2 + (deployment.stagingDirectoryIsJobOwned ? 1 : 0)
        + (deployment.rollbackPolicy == .autoRollback ? 1 : 0)
      guard subprocesses.count == expectedCount,
        subprocesses.allSatisfy(pathIsAbsent)
      else {
        return .failed(
          code: "nativeCleanupIncomplete",
          detail: "one or more provider-owned native paths still exist")
      }
      return .verified(summary: ["cleanupComplete": "true"])
    case .rollbackRestored:
      let expectedCount =
        deployment.verificationProfile == .hashProcessAndMaps ? 4 : 3
      guard subprocesses.count == expectedCount,
        let targetHash = sha256(subprocesses[0]),
        sha256(subprocesses[1]) == targetHash,
        let pids = processIDs(subprocesses[2]), !pids.isEmpty
      else {
        return .unknown(reason: "rollback readback cannot prove restored bytes and process")
      }
      if deployment.verificationProfile == .hashProcessAndMaps,
        !mapsContain(
          subprocesses[3], targetPath: deployment.loaderVisiblePath, pids: pids)
      {
        return .unknown(reason: "rollback bytes exist but restored loader state is unproven")
      }
      return .verified(summary: [
        "restoredSha256": targetHash,
        "restored": "true",
      ])
    }
  }

  private func sha256(_ receipt: ProviderSubprocessReceipt) -> String? {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8),
      let token = text.split(whereSeparator: \.isWhitespace).first
    else {
      return nil
    }
    let value = String(token)
    guard value.count == 64,
      value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
    else {
      return nil
    }
    return value
  }

  private func processIDs(_ receipt: ProviderSubprocessReceipt) -> [UInt32]? {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let values = text.split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) }
    guard !values.isEmpty,
      values.allSatisfy({ $0 > 0 }),
      values.count == text.split(whereSeparator: \.isWhitespace).count
    else {
      return nil
    }
    return values
  }

  private func processIsAbsent(_ receipt: ProviderSubprocessReceipt) -> Bool {
    guard let exitStatus = receipt.exitStatus,
      exitStatus == 0 || exitStatus == 1,
      !receipt.stdoutTruncated,
      receipt.stderr.isEmpty,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return false
    }
    return text.split(whereSeparator: \.isWhitespace).isEmpty
  }

  private func exitSummary(_ receipt: ProviderSubprocessReceipt) -> String {
    receipt.exitStatus.map(String.init) ?? "unknown"
  }

  /// Provider diagnostics are persisted in job failures, so expose only a
  /// bounded byte representation. Hex preserves enough information to
  /// distinguish remote "not found" and permission failures without copying
  /// arbitrary device text into logs or creating a general shell-output
  /// surface.
  private func boundedProcessDiagnostic(
    _ receipt: ProviderSubprocessReceipt
  ) -> String {
    let byteLimit = 512
    func field(_ data: Data) -> String {
      data.prefix(byteLimit).map { String(format: "%02x", $0) }.joined()
    }
    return
      "outBytes=\(receipt.stdout.count),outHex=\(field(receipt.stdout)),"
      + "errBytes=\(receipt.stderr.count),errHex=\(field(receipt.stderr)),"
      + "truncated=\(receipt.stdoutTruncated)"
  }

  private func pidSummary(_ receipt: ProviderSubprocessReceipt) -> String {
    processIDs(receipt)?.map(String.init).joined(separator: ",") ?? "none"
  }

  private func pathIsAbsent(_ receipt: ProviderSubprocessReceipt) -> Bool {
    pathPresence(
      exitStatus: receipt.exitStatus,
      stdout: receipt.stdout,
      stderr: receipt.stderr,
      stdoutTruncated: receipt.stdoutTruncated) == false
  }

  /// HDC 3.2 reports the client transport exit status, not the remote
  /// command's status. A remote `test -e` therefore appears as exit 0 for
  /// both present and absent paths. Use one exact `ls -ld` observation and
  /// accept only its closed listing or not-found grammar.
  private func pathPresence(
    exitStatus: Int32?,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool
  ) -> Bool? {
    guard exitStatus == 0,
      !stdoutTruncated,
      stderr.isEmpty,
      let text = String(data: stdout, encoding: .utf8)
    else {
      return nil
    }
    if stdout.count >= 2,
      let first = stdout.first,
      [UInt8(ascii: "-"), UInt8(ascii: "d"), UInt8(ascii: "l"),
        UInt8(ascii: "b"), UInt8(ascii: "c"), UInt8(ascii: "p"),
        UInt8(ascii: "s")].contains(first),
      stdout[stdout.startIndex + 1] == UInt8(ascii: "r")
        || stdout[stdout.startIndex + 1] == UInt8(ascii: "-")
    {
      return true
    }
    let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    guard lines.count == 1 else { return nil }
    let line = String(lines[0])
    guard line.hasPrefix("ls: "),
      line.hasSuffix(": No such file or directory")
    else {
      return nil
    }
    return false
  }

  private func isDirectoryListing(_ receipt: ProviderSubprocessReceipt) -> Bool {
    receipt.exitStatus == 0 && !receipt.stdoutTruncated
      && receipt.stdout.first == 0x64
  }

  private func isRegularFileListing(_ receipt: ProviderSubprocessReceipt) -> Bool {
    receipt.exitStatus == 0 && !receipt.stdoutTruncated
      && receipt.stdout.first == 0x2D
  }

  private func nativeFileIdentity(
    _ receipt: ProviderSubprocessReceipt
  ) -> HDCNativeFileIdentity? {
    guard receipt.exitStatus == 0,
      !receipt.stdoutTruncated,
      receipt.stderr.isEmpty,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let fields = text.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 4,
      fields[0].first == "-",
      let userID = UInt32(fields[2]),
      let groupID = UInt32(fields[3])
    else {
      return nil
    }
    return HDCNativeFileIdentity(
      mode: String(fields[0]), userID: userID, groupID: groupID)
  }

  private func mapsContain(
    _ receipt: ProviderSubprocessReceipt,
    targetPath: String,
    pids: [UInt32]
  ) -> Bool {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8),
      text.contains(targetPath)
    else {
      return false
    }
    return pids.contains { text.contains("/proc/\($0)/maps:") }
  }

  public func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    let readback: TypedProviderAction
    switch intent.action {
    case .hdc(.captureTrace(_, let path)), .hdc(.cleanupOwnedRemotePath(let path)):
      readback = .hdc(.readOwnedPathPresence(path))
    case .hdc(.sendArtifactToStaging(let staged)):
      readback = .hdc(.readOwnedPathPresence(staged.path))
    case .hdc(.installPackage(_, let bundle)), .hdc(.uninstallPackage(let bundle)):
      readback = .hdc(.readPackagePresence(bundle))
    case .hdc(.startAbility(let ability)), .hdc(.stopAbility(let ability)):
      readback = .hdc(.readProcessPresence(ability.bundle))
    case .hdc(.createPortForward(let spec)), .hdc(.removePortForward(let spec)):
      readback = .hdc(.readPortForwardPresence(spec))
    case .hdc(.sendNativeLibraryToStaging(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .stagingMatchesArtifact))
    case .hdc(.backupNativeLibrary(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .backupMatchesTarget))
    case .hdc(.publishNativeLibrary(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .targetMatchesArtifact))
    case .hdc(.stopNativeTarget(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .targetStopped))
    case .hdc(.startNativeTarget(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .targetStarted))
    case .hdc(.cleanupNativeLibrary(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .cleanupComplete))
    case .hdc(.rollbackNativeLibrary(let deployment)):
      readback = .hdc(.inspectNativeLibrary(
        deployment, expectation: .rollbackRestored))
    default:
      return nil
    }
    return try lower(action: readback, context: context)
  }

  public func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome {
    guard let plan = try reconciliationReadback(intent: intent, context: context) else {
      return .stillUnknown(reason: "original action has no dedicated readback")
    }
    let semantic = try verify(
      receipt: receipt, action: plan.action, context: context)
    if case .hdc(let original) = intent.action {
      switch original {
      case .sendNativeLibraryToStaging, .backupNativeLibrary,
        .stopNativeTarget, .startNativeTarget, .cleanupNativeLibrary:
        switch semantic {
        case .verified(let summary):
          return .confirmedCompleted(summary: summary)
        case .failed:
          return .confirmedNotExecuted
        case .unknown(let reason), .unsupported(let reason):
          return .stillUnknown(reason: reason)
        }
      case .publishNativeLibrary:
        switch semantic {
        case .verified(let summary):
          return .confirmedCompleted(summary: summary)
        case .failed(let code, let detail):
          return .stillUnknown(
            reason: "\(code): \(detail); publish state is not safe to replay")
        case .unknown(let reason), .unsupported(let reason):
          return .stillUnknown(reason: reason)
        }
      case .rollbackNativeLibrary:
        switch semantic {
        case .verified(let summary):
          return .confirmedCompleted(summary: summary)
        case .failed(let code, let detail):
          return .stillUnknown(reason: "\(code): \(detail)")
        case .unknown(let reason), .unsupported(let reason):
          return .stillUnknown(reason: reason)
        }
      default:
        break
      }
    }
    guard case .verified(let summary) = semantic,
      let raw = summary["present"],
      let present = Bool(raw)
    else {
      return .stillUnknown(reason: "dedicated readback did not produce a definite presence")
    }
    let desiredPresence: Bool
    switch intent.action {
    case .hdc(.captureTrace), .hdc(.sendArtifactToStaging), .hdc(.installPackage),
      .hdc(.startAbility), .hdc(.createPortForward):
      desiredPresence = true
    case .hdc(.cleanupOwnedRemotePath), .hdc(.stopAbility), .hdc(.uninstallPackage),
      .hdc(.removePortForward):
      desiredPresence = false
    default:
      return .stillUnknown(reason: "readback was not paired with a mutation")
    }
    return present == desiredPresence
      ? .confirmedCompleted(summary: ["postconditionPresent": String(present)])
      : .confirmedNotExecuted
  }

  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    // Observation actions are read-only: re-observation is always safe,
    // so an unknown outcome reconciles to "not executed" semantics and the
    // engine may re-run the read. Mutating HDC actions (T13+) must return
    // stillUnknown unless positive evidence exists.
    switch intent.action {
    case .hdc(.observeTool), .hdc(.observeServer), .hdc(.listDeviceCandidates),
      .hdc(.observeDevice), .hdc(.queryProperty), .hdc(.observeStorage), .hdc(.captureHilog),
      .hdc(.captureUIDump), .hdc(.receiveOwnedArtifact):
      // Read-only families: re-observation is always safe.
      return .confirmedNotExecuted
    case .hdc(.queryPackageReadback), .hdc(.verifyProcessState):
      return .confirmedNotExecuted
    case .hdc(.captureTrace), .hdc(.cleanupOwnedRemotePath):
      // Remote-temp mutations reconcile by re-listing the owned path in a
      // later read; without that evidence the outcome stays unknown.
      return .stillUnknown(
        reason: "owned-path mutation needs a re-observation pass to conclude")
    case .hdc(.sendArtifactToStaging), .hdc(.installPackage), .hdc(.startAbility),
      .hdc(.stopAbility), .hdc(.uninstallPackage), .hdc(.createPortForward),
      .hdc(.removePortForward), .hdc(.sendNativeLibraryToStaging),
      .hdc(.backupNativeLibrary), .hdc(.publishNativeLibrary),
      .hdc(.stopNativeTarget), .hdc(.startNativeTarget),
      .hdc(.cleanupNativeLibrary), .hdc(.rollbackNativeLibrary):
      // Device mutations need positive readback evidence to conclude; a
      // reconcile pass that has none must stay unknown rather than guess.
      return .stillUnknown(
        reason: "device mutation needs a readback pass before it can be concluded")
    case .hdc(.inspectNativeLibrary):
      return .confirmedNotExecuted
    default:
      return .stillUnknown(reason: "no reconcile evidence source for \(intent.action)")
    }
  }
}

// MARK: - Rockchip adapter

/// Execution port so contract tests can fake the host; production wires
/// `RockchipFlashExecutionHost.execute` behind it unchanged.
public protocol RockchipFlashExecutionPort: Sendable {
  func executeFlash(authorizationID: String) async throws -> (
    manifestID: String, succeeded: Bool, waitingForRecovery: Bool
  )
}

public struct RockchipFlashProviderAdapter: DeviceProvider {
  public let providerID = "rockchip"
  private let executionPort: any RockchipFlashExecutionPort

  public init(executionPort: any RockchipFlashExecutionPort) {
    self.executionPort = executionPort
  }

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    .unavailable(
      reason: "Rockchip migration is not production available in this recovery phase")
  }

  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(
      "rockchip facts resolve inside the execution host during migration (T17)")
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    switch step.kind {
    case .flashPartition:
      guard case .string(let authorizationID)? = inputs["authorizationId"] else {
        throw DeviceProviderError.unsupportedAction(
          "flash requires a standing authorization id input during migration")
      }
      return .rockchip(.executeFlashPlan(authorizationID: authorizationID))
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no registered Rockchip action in MU-2 (arrives with T17/T18)")
    }
  }

  public func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .rockchip(.executeFlashPlan(let authorizationID)) = action else {
      throw DeviceProviderError.unsupportedAction("non-Rockchip action given to rockchip provider")
    }
    return TypedProcessPlan(
      action: action,
      kind: .hostManaged(descriptor: "rockchip-flash-host:\(authorizationID)"))
  }

  public func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    guard receipt.hostManagedRecordID != nil else {
      // A flash without its durable manifest reference can never verify.
      return .unknown(reason: "host-managed execution returned no durable record reference")
    }
    guard case .rockchip = action else {
      throw DeviceProviderError.unsupportedAction("non-Rockchip action given to rockchip provider")
    }
    return .verified(summary: ["manifestId": receipt.hostManagedRecordID ?? ""])
  }

  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    // Destructive: without the host's own recovery verdict there is no
    // safe claim in either direction.
    return .stillUnknown(
      reason: "rockchip reconcile is owned by the execution host's recovery flow (T17)")
  }
}
