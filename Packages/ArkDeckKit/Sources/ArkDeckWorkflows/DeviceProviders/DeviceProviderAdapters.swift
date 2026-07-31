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
  private let nativeCodeSignHelper: HDCNativeCodeSignHelperArtifact?
  private let hostReceiveRoot: URL

  public init(
    factsPort: any HDCObservationFactsPort,
    profile: HDCCompatibilityProfile = .openHarmony320Family,
    appOwnedNativeLibraryAvailability: ProviderOperationAvailability? = nil,
    hostReceiveRoot: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-receive", isDirectory: true)
  ) {
    self.factsPort = factsPort
    self.profile = profile
    self.hostReceiveRoot = hostReceiveRoot
    let helper = try? HDCNativeCodeSignHelperArtifact.bundled()
    self.nativeCodeSignHelper = helper
    self.appOwnedNativeLibraryAvailability =
      appOwnedNativeLibraryAvailability
      ?? (helper == nil
        ? .unavailable(
          reason:
            "bundled arm64 OpenHarmony code-sign helper cannot be verified")
        : .available)
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
      if step.stepID == "capture-screenshot" {
        return .hdc(
          .captureScreenshot(
            into: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: "capture-screenshot")))
      }
      if step.stepID == "capture-ui-tree" {
        return .hdc(
          .captureComponentTree(
            into: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: "capture-ui-tree")))
      }
      return .hdc(
        .captureTrace(
          try traceRequest(from: inputs),
          into: try mintStableOwnedRemotePath(
            jobID: context.jobID, stepID: "capture-trace")))
    case .receiveFile:
      // Each receive leg re-mints its own producer's owned path, which is
      // what keeps the received bytes bound to the step that wrote them.
      return .hdc(
        .receiveOwnedArtifact(
          HDCOwnedRemoteArtifact(
            path: try mintStableOwnedRemotePath(
              jobID: context.jobID, stepID: Self.fileProducerStepID(for: step.stepID)),
            expectedSHA256: nil, maximumBytes: 64 * 1024 * 1024,
            expectedLeadingBytes: step.stepID == "receive-screenshot"
              ? HDCFileMagic.png : nil)))
    case .cleanupOwnedRemotePath:
      let ownerStepID: String
      if operation.reference == "debug.hap@1" {
        if let packageSet = try stagedPackageSet(inputs: inputs, context: context) {
          return .hdc(.cleanupStagedPackageSet(packageSet))
        }
        ownerStepID = "send-hap"
      } else {
        ownerStepID = Self.fileProducerStepID(for: step.stepID)
      }
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
      // The component tree is delivered — by the `capture-ui-tree` /
      // `receive-ui-tree` / `cleanup-ui-tree-temp` steps, selected by the
      // `uiComponentTree` input (CHG-2026-053 r2). What stays refused is
      // this *stdout* action: `uitest dumpLayout` writes a device file, and
      // a captureRemoteStdout step cannot carry a file product no matter
      // which flags it is given. The contract keeps the action; nothing may
      // reach it. Do not spend another round on hidumper flag archaeology —
      // a windowId is not what was ever missing (DEVICE-COMMAND-FACTS.md §7).
      throw DeviceProviderError.unsupportedAction(
        "componentTree is a file product, not stdout: use the uiComponentTree "
          + "input, which selects the capture-ui-tree file steps; a "
          + "captureRemoteStdout step cannot carry it")
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
    // No invented default. The 2026-07-31 device window found `ohos` — the
    // value that used to stand in here — absent from `hitrace
    // --list_categories` on OH 3.2 (DAYU200), so the fallback could only ever
    // have produced a command the device rejects. The trace leg is selected
    // by the caller's own non-empty `traceCategories`, so an empty list here
    // is a contradiction; `HDCTraceCaptureRequest` refuses it.
    var categories: [String] = []
    if case .array(let requested)? = inputs["traceCategories"] {
      categories = requested.compactMap { value -> String? in
        if case .string(let text) = value { return text }
        return nil
      }
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

  /// Builds the staged package set when — and only when — the request
  /// carried additional leases. Every remote path is minted here; the
  /// leases contribute identity and hashes, never a path component.
  private func stagedPackageSet(
    inputs: [String: JSONValue], context: ProviderExecutionContext
  ) throws -> HDCStagedPackageSet? {
    guard case .array(let raw)? = inputs["additionalHapArtifactLeases"], !raw.isEmpty else {
      return nil
    }
    guard case .string(let entryLease)? = inputs["hapArtifactLease"] else {
      throw DeviceProviderError.unsupportedAction("hapArtifactLease input is required")
    }
    var leases = [entryLease]
    for value in raw {
      guard case .string(let lease) = value else {
        throw DeviceProviderError.unsupportedAction(
          "additionalHapArtifactLeases must be artifact leases")
      }
      leases.append(lease)
    }
    // Admission materializes this plan before any lease is resolved, so the
    // hashes may be absent here. The identity comes from the lease either
    // way — `lease-v1:<job>:<artifactID>` — and `lower` is where the
    // resolved bytes must match before anything is sent.
    let resolved =
      [context.resolvedInputArtifact].compactMap { $0 } + context.additionalInputArtifacts
    let directory = try HDCOwnedRemoteDirectory(
      jobID: context.jobID, stepID: "send-hap", nonce: "owned")
    let packages = try leases.enumerated().map { index, lease -> HDCStagedPackage in
      guard let artifactID = lease.split(separator: ":").last.map(String.init) else {
        throw DeviceProviderError.unsupportedAction("malformed artifact lease")
      }
      let artifact = index < resolved.count ? resolved[index] : nil
      if let artifact, artifact.artifactID != artifactID {
        throw DeviceProviderError.unsupportedAction(
          "resolved Artifact does not match the lease at position \(index)")
      }
      return try HDCStagedPackage(
        directory: directory, artifactID: artifactID,
        artifactLeaseID: lease, expectedSHA256: artifact?.sha256)
    }
    return try HDCStagedPackageSet(directory: directory, packages: packages)
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
    // The additional leases are the only thing that selects the directory
    // form. Absent, every leg below is exactly what it was (r4).
    let packageSet = try stagedPackageSet(inputs: inputs, context: context)
    switch step.kind {
    case .sendFile:
      if let packageSet { return .hdc(.sendPackageSetToStaging(packageSet)) }
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
      if let packageSet { return .hdc(.installPackageSet(packageSet, bundle: bundle)) }
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
      bytes, expectedABI: expectedABI,
      requireOpenHarmonyCodeSignature: true)
    guard facts.sha256 == resolved.sha256, facts.byteCount == resolved.byteCount else {
      throw DeviceProviderError.unsupportedAction(
        "leased native Artifact bytes drifted during materialization")
    }
    guard let nativeCodeSignHelper else {
      throw DeviceProviderError.unsupportedAction(
        "native deployment code-sign helper is unavailable")
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
      rollbackPolicy: rollback,
      codeSignHelperFacts: nativeCodeSignHelper.facts)
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
      }
    case .captureTrace(let request, let path):
      // hitrace's own exit status is the hdc client's, not the remote
      // command's, so the capture is judged by the file it was supposed to
      // write. `ls -l` is the pinned way to ask (DEVICE-COMMAND-FACTS.md §8:
      // the size field, not the exit code, is what deveco believes) and it
      // runs even when hitrace reports non-zero — a partial trace is still a
      // fact the readback should report.
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch",
          invocations: [
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "hitrace", "-t", String(request.durationSeconds), "-b",
                  String(request.bufferKB)] + request.categories + ["-o", path.remotePath],
                context: context),
              timeoutSeconds: request.durationSeconds + 30,
              continueAfterNonZero: true),
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "ls", "-l", path.remotePath], context: context),
              timeoutSeconds: 15),
          ]))
    case .captureComponentTree(let path):
      // Measured on DAYU200 / OH 3.2 (CHG-2026-053 r2): `uitest dumpLayout
      // -p <file>` needs neither `-w` nor `-d`, and answers `DumpLayout
      // saved to:<path>`. That answer is a status line from a command that
      // mutates the device, so the file — not the line — is the evidence,
      // and the `ls -l` readback is what reads it (same shape as the trace
      // leg, DEVICE-COMMAND-FACTS.md §8).
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch",
          invocations: [
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "uitest", "dumpLayout", "-p", path.remotePath],
                context: context),
              timeoutSeconds: 60,
              continueAfterNonZero: true),
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "ls", "-l", path.remotePath], context: context),
              timeoutSeconds: 15),
          ]))
    case .captureScreenshot(let path):
      // `-t png` is mandatory, not a retry: this build defaults to jpeg and
      // refuses a name whose suffix disagrees with the type (OH 3.2,
      // measured 2026-07-31). The status line it prints is not evidence —
      // the `ls -l` readback is, same as every other file leg.
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch",
          invocations: [
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "snapshot_display", "-t", "png", "-f", path.remotePath],
                context: context),
              timeoutSeconds: 60, continueAfterNonZero: true),
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "ls", "-l", path.remotePath], context: context),
              timeoutSeconds: 15),
          ]))
    case .receiveOwnedArtifact(let artifact):
      // `file recv` takes both paths; with only the remote one hdc has no
      // destination to write (DEVICE-COMMAND-FACTS.md §4). The local name is
      // deliberately the remote basename: deveco has to try `recv <remote>
      // <dir>` and `recv <remote> <dir>/<name>` separately because the
      // landing form differs by version, and naming them alike makes both
      // forms land on the same path instead of on a guess.
      let destination = hostLandingURL(for: artifact.path)
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["file", "recv", artifact.path.remotePath, destination.path],
            context: context),
          timeoutSeconds: 60),
        hostLanding: HostLandingExpectation(
          destination: destination,
          maximumBytes: artifact.maximumBytes,
          expectedSHA256: artifact.expectedSHA256))
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
    case .sendPackageSetToStaging(let set):
      // One directory, then one send per package. Same shape the native
      // family already uses (mkdir -p + several sends in one sequence);
      // multi-package needed no new step kind for it.
      guard context.additionalInputArtifacts.count + 1 == set.packages.count,
        let entry = context.resolvedInputArtifact
      else {
        throw DeviceProviderError.unsupportedAction(
          "package-set send requires the engine-resolved lease for every package")
      }
      let resolved = [entry] + context.additionalInputArtifacts
      var invocations: [TypedProcessInvocation] = [
        TypedProcessInvocation(
          arguments: try deviceArguments(
            ["shell", "mkdir", "-p", set.directory.remotePath], context: context),
          timeoutSeconds: 30)
      ]
      for (artifact, package) in zip(resolved, set.packages) {
        guard package.expectedSHA256 == artifact.sha256 else {
          throw DeviceProviderError.unsupportedAction(
            "staged package does not match its engine-resolved Artifact")
        }
        invocations.append(
          TypedProcessInvocation(
            arguments: try deviceArguments(
              ["file", "send", artifact.fileURL.path, package.remotePath],
              context: context),
            timeoutSeconds: 300))
      }
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch", invocations: invocations))
    case .installPackageSet(let set, _):
      // The whole point of the directory form: one install for the set.
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "bm", "install", "-p", set.directory.remotePath, "-r"],
            context: context),
          timeoutSeconds: 300))
    case .cleanupStagedPackageSet(let set):
      // Each package by name, then `rmdir` — never `rm -rf`. `rmdir` fails
      // on a non-empty directory, so a cleanup that did not fully clean
      // reports instead of deleting something it was not asked to.
      var commands: [TypedProcessInvocation] = try set.packages.map { package in
        TypedProcessInvocation(
          arguments: try deviceArguments(
            ["shell", "rm", "-f", package.remotePath], context: context),
          timeoutSeconds: 30, continueAfterNonZero: true)
      }
      commands.append(
        TypedProcessInvocation(
          arguments: try deviceArguments(
            ["shell", "rmdir", set.directory.remotePath], context: context),
          timeoutSeconds: 30))
      commands.append(
        TypedProcessInvocation(
          arguments: try deviceArguments(
            ["shell", "ls", "-ld", set.directory.remotePath], context: context),
          timeoutSeconds: 15))
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch", invocations: commands))
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
    // Both mutations carry their own readback, for the same reason install
    // and start have one: `hdc shell`'s exit status is the client's, and
    // `bm uninstall` answers `uninstall missing installed bundle` on a clean
    // exit when the bundle was never there. The probes are the ones the
    // reconcile path already uses, so a forward verdict and a recovery
    // verdict cannot disagree about what "gone" looks like.
    case .stopAbility(let ability):
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch",
          invocations: [
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "aa", "force-stop", ability.bundle.bundleName],
                context: context),
              timeoutSeconds: 60,
              continueAfterNonZero: true),
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "pidof", ability.bundle.bundleName], context: context),
              timeoutSeconds: 30),
          ]))
    case .uninstallPackage(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .processSequence(
          executableSHA256: "resolved-at-dispatch",
          invocations: [
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["uninstall", bundle.bundleName], context: context),
              timeoutSeconds: 120,
              continueAfterNonZero: true),
            TypedProcessInvocation(
              arguments: try deviceArguments(
                ["shell", "bm", "dump", "-n", bundle.bundleName], context: context),
              timeoutSeconds: 30),
          ]))
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
    case .readOwnedDirectoryPresence(let directory):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "ls", "-ld", directory.remotePath], context: context),
          timeoutSeconds: 15))
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
        deployment.stagingDirectoryIsJobOwned,
        let expectedHelper = deployment.codeSignHelperFacts,
        let helperRemotePath = deployment.codeSignHelperRemotePath,
        let nativeCodeSignHelper,
        nativeCodeSignHelper.facts == expectedHelper
      else {
        throw DeviceProviderError.unsupportedAction(
          "native send requires the same engine-resolved Artifact and a job-owned staging directory")
      }
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "mkdir", "-p", deployment.stagingDirectoryPath], false, 30),
          (["file", "send", resolved.fileURL.path, deployment.stagingPath], false, 300),
          ([
            "file", "send", nativeCodeSignHelper.fileURL.path,
            helperRemotePath,
          ], false, 60),
          (["shell", "chmod", "700", helperRemotePath], false, 30),
          (["shell", "sha256sum", helperRemotePath], false, 30),
        ])
    case .backupNativeLibrary(let deployment):
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "ls", "-ld", deployment.directoryPath], false, 15),
          (["shell", "ls", "-l", deployment.targetPath], false, 15),
          (["shell", "sha256sum", deployment.targetPath], false, 30),
          (["shell", "rm", "-f", deployment.backupPath], false, 30),
          (["shell", "ln", deployment.targetPath, deployment.backupPath], false, 30),
          (["shell", "sha256sum", deployment.backupPath], false, 30),
          (["shell", "ls", "-l", deployment.backupPath], false, 15),
          // Keep firmware-layout diagnosis inside this typed provider action.
          // Failure reporting only exposes a bounded hex prefix.
          (["shell", "ls", "-la", deployment.nativeLibrariesRootPath], true, 15),
        ])
    case .publishNativeLibrary(let deployment):
      guard let helperRemotePath = deployment.codeSignHelperRemotePath,
        deployment.codeSignHelperFacts != nil
      else {
        throw DeviceProviderError.unsupportedAction(
          "native publish has no persisted code-sign helper identity")
      }
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "ls", "-ln", deployment.targetPath], false, 15),
          ([
            "shell", helperRemotePath, "publish", deployment.stagingPath,
            deployment.targetPath, deployment.rollbackStagingPath,
          ], false, 60),
          (["shell", "sha256sum", deployment.targetPath], false, 30),
          ([
            "shell", helperRemotePath, "verify", deployment.targetPath,
          ], false, 30),
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
      if let helperRemotePath = deployment.codeSignHelperRemotePath {
        commands.append((["shell", "rm", "-f", helperRemotePath], true, 30))
      }
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
      if let helperRemotePath = deployment.codeSignHelperRemotePath {
        commands.append((["shell", "ls", "-ld", helperRemotePath], true, 15))
      }
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
          (["shell", "rm", "-f", deployment.rollbackStagingPath], true, 30),
          ([
            "shell", "ln", deployment.backupPath, deployment.rollbackStagingPath,
          ], true, 60),
          ([
            "shell", "mv", "-f", deployment.rollbackStagingPath,
            deployment.targetPath,
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
      guard let helperRemotePath = deployment.codeSignHelperRemotePath else {
        throw DeviceProviderError.unsupportedAction(
          "native target inspection has no persisted code-sign helper path")
      }
      commands = [
        (["shell", "sha256sum", deployment.targetPath], true, 30),
        (["shell", helperRemotePath, "verify", deployment.targetPath], true, 30),
      ]
    case .targetStopped, .targetStarted:
      commands = [
        (["shell", "pidof", deployment.bundle.bundleName], true, 30)
      ]
    case .targetLoaded:
      guard let helperRemotePath = deployment.codeSignHelperRemotePath else {
        throw DeviceProviderError.unsupportedAction(
          "native loader inspection has no persisted code-sign helper path")
      }
      var selected: [([String], Bool, Int)] = [
        (["shell", "sha256sum", deployment.targetPath], true, 30),
        (["shell", helperRemotePath, "verify", deployment.targetPath], true, 30),
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
      if let helperRemotePath = deployment.codeSignHelperRemotePath {
        selected.append(
          (["shell", "ls", "-ld", helperRemotePath], true, 15))
      }
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

  /// Which step wrote the file a receive/cleanup step is talking about.
  /// The owned remote path is minted from the *producer's* step ID, so the
  /// two legs of a file product cannot drift onto different paths.
  static func fileProducerStepID(for stepID: String) -> String {
    switch stepID {
    case "receive-ui-tree", "cleanup-ui-tree-temp":
      return "capture-ui-tree"
    case "receive-screenshot", "cleanup-screenshot-temp":
      return "capture-screenshot"
    default:
      return "capture-trace"
    }
  }

  /// The host path a received artifact must land on. Provider-owned exactly
  /// like the remote path it mirrors: the basename already carries the
  /// job/step/nonce tuple, so a fixed root cannot collide across jobs and no
  /// caller input reaches this path.
  func hostLandingURL(for remote: HDCOwnedRemotePath) -> URL {
    hostReceiveRoot.appendingPathComponent(
      URL(fileURLWithPath: remote.remotePath).lastPathComponent, isDirectory: false)
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
    case .captureTrace(_, let path):
      // Judged by the paired `ls -l` readback, never by hitrace's exit
      // status: `hdc shell` reports the client's status, so a clean exit
      // says nothing about whether the device wrote a trace.
      guard receipt.subprocesses.count == 2 else {
        return .unknown(reason: "trace capture did not produce its readback sequence")
      }
      guard let byteCount = Self.remoteRegularFileByteCount(receipt.subprocesses[1]) else {
        // Includes `ls: ...: No such file or directory`. The mutation ran,
        // so this is genuinely unknown rather than a clean failure: the
        // engine keeps the intent outstanding for reconcile instead of
        // guessing which side the truth is on.
        return .unknown(
          reason: "trace readback did not describe \(path.remotePath) as a regular file")
      }
      guard byteCount > 0 else {
        return .failed(
          code: "emptyTrace",
          detail: "hitrace left a zero-byte file at \(path.remotePath)")
      }
      return .verified(summary: ["remoteByteCount": String(byteCount)])
    case .captureComponentTree(let path):
      guard receipt.subprocesses.count == 2 else {
        return .unknown(reason: "component tree dump did not produce its readback sequence")
      }
      guard let byteCount = Self.remoteRegularFileByteCount(receipt.subprocesses[1]) else {
        return .unknown(
          reason: "tree readback did not describe \(path.remotePath) as a regular file")
      }
      guard byteCount > 0 else {
        return .failed(
          code: "emptyComponentTree",
          detail: "uitest left a zero-byte file at \(path.remotePath)")
      }
      return .verified(summary: ["remoteByteCount": String(byteCount)])

    case .captureScreenshot(let path):
      guard receipt.subprocesses.count == 2 else {
        return .unknown(reason: "screenshot did not produce its readback sequence")
      }
      guard let byteCount = Self.remoteRegularFileByteCount(receipt.subprocesses[1]) else {
        return .unknown(
          reason: "screenshot readback did not describe \(path.remotePath) as a regular file")
      }
      guard byteCount > 0 else {
        return .failed(
          code: "emptyScreenshot",
          detail: "snapshot_display left a zero-byte file at \(path.remotePath)")
      }
      return .verified(summary: ["remoteByteCount": String(byteCount)])

    case .receiveOwnedArtifact(let artifact):
      // The step's whole purpose is host bytes, so the verdict is read off
      // the file the dispatcher measured. `file recv` exits 0 on forms that
      // transfer nothing, and its stdout is a progress line, so neither the
      // exit status nor the receipt bytes can decide this.
      guard let landed = receipt.landedArtifact else {
        return .unknown(
          reason: "receive left no file at the declared destination")
      }
      guard landed.byteCount > 0 else {
        return .failed(
          code: "emptyArtifact",
          detail: "received file for \(artifact.path.remotePath) is empty")
      }
      guard landed.byteCount <= artifact.maximumBytes else {
        return .failed(
          code: "oversizedArtifact",
          detail:
            "received \(landed.byteCount) bytes over the \(artifact.maximumBytes) byte budget")
      }
      guard let sha256 = landed.sha256 else {
        return .unknown(reason: "received file could not be digested")
      }
      if let expected = artifact.expectedSHA256, expected != sha256 {
        return .failed(
          code: "hashMismatch",
          detail: "received bytes do not match the pinned content hash")
      }
      if let magic = artifact.expectedLeadingBytes,
        !landed.leadingBytes.starts(with: magic)
      {
        // A device that answered with an error page, a truncated write or
        // the wrong image type must not become a published artifact.
        return .failed(
          code: "unexpectedFormat",
          detail: "received bytes do not begin with the pinned magic")
      }
      // The name, not the path: the summary is journalled and published, and
      // the host directory layout is not evidence.
      return .verified(summary: [
        "localArtifact": landed.localURL.lastPathComponent,
        "byteCount": String(landed.byteCount),
        "sha256": sha256,
      ])
    case .cleanupOwnedRemotePath(let path):
      guard receipt.exitStatus == 0 else {
        // Cleanup failure is debt, never silently dropped - the engine
        // records it for later reconcile.
        return .failed(code: "cleanupDebt", detail: "remote cleanup failed for \(path.remotePath)")
      }
      return .verified(summary: ["cleaned": path.remotePath])

    case .sendPackageSetToStaging(let set):
      guard receipt.subprocesses.count == set.packages.count + 1 else {
        return .unknown(reason: "package-set send did not produce one result per package")
      }
      guard receipt.subprocesses.allSatisfy({ $0.exitStatus == 0 }) else {
        return .failed(
          code: "sendFailed", detail: "one package of the set did not transfer cleanly")
      }
      return .verified(summary: [
        "stagedAt": set.directory.remotePath,
        "packageCount": String(set.packages.count),
      ])

    case .installPackageSet:
      // Same rule as the single-package install: the readback decides.
      guard let exitStatus = receipt.exitStatus else {
        return .unknown(reason: "install produced no process result")
      }
      guard exitStatus == 0 else {
        return .failed(code: "installFailed", detail: "install process reported failure")
      }
      return .unknown(reason: "install requires package readback before it can be believed")

    case .cleanupStagedPackageSet(let set):
      // `ls -d` on the directory is the evidence: absent means the whole
      // set is gone, present means something is still staged.
      guard let listing = receipt.subprocesses.last,
        let present = pathPresence(
          exitStatus: listing.exitStatus, stdout: listing.stdout,
          stderr: listing.stderr, stdoutTruncated: listing.stdoutTruncated)
      else {
        return .unknown(reason: "staged directory readback has no definite result")
      }
      guard !present else {
        return .failed(
          code: "cleanupDebt",
          detail: "staged package directory \(set.directory.remotePath) still exists")
      }
      return .verified(summary: ["cleaned": set.directory.remotePath])

    case .sendArtifactToStaging(let staged):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "sendFailed", detail: "artifact transfer did not complete")
      }
      return .verified(summary: ["stagedAt": staged.path.remotePath])

    case .sendNativeLibraryToStaging(let deployment):
      guard receipt.exitStatus == 0,
        receipt.subprocesses.count == 5,
        let expectedHelper = deployment.codeSignHelperFacts,
        sha256(receipt.subprocesses[4]) == expectedHelper.sha256
      else {
        return .failed(
          code: "nativeSendFailed",
          detail:
            "native library and the pinned code-sign helper did not both transfer cleanly")
      }
      return .unknown(
        reason: "native staging send requires remote hash readback")

    case .backupNativeLibrary(let deployment):
      guard receipt.subprocesses.count == 8 else {
        return .unknown(reason: "native backup did not produce its complete readback sequence")
      }
      let observedTargetHash = sha256(receipt.subprocesses[2])
      let observedBackupHash = sha256(receipt.subprocesses[5])
      let observedBackupMatches =
        observedBackupHash != nil && observedBackupHash == observedTargetHash
      guard isDirectoryListing(receipt.subprocesses[0]),
        isRegularFileListing(receipt.subprocesses[1]),
        let targetHash = observedTargetHash,
        let backupHash = observedBackupHash,
        targetHash == backupHash,
        receipt.subprocesses[3].exitStatus == 0,
        receipt.subprocesses[4].exitStatus == 0,
        isRegularFileListing(receipt.subprocesses[6])
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
            + "removeOldBackupExit=\(exitSummary(receipt.subprocesses[3])), "
            + "hardLinkExit=\(exitSummary(receipt.subprocesses[4])), "
            + "backupHashExit=\(exitSummary(receipt.subprocesses[5])), "
            + "backupHashMatches=\(observedBackupMatches), "
            + "backupExit=\(exitSummary(receipt.subprocesses[6])), "
            + "backupListed=\(isRegularFileListing(receipt.subprocesses[6])), "
            + "diagnostics=\(diagnostics))")
      }
      return .verified(summary: [
        "backupSha256": backupHash,
        "backupPath": deployment.backupPath,
      ])

    case .publishNativeLibrary(let deployment):
      guard receipt.subprocesses.count == 5,
        let originalIdentity = nativeFileIdentity(receipt.subprocesses[0]),
        let publishedIdentity = nativeFileIdentity(receipt.subprocesses[4]),
        originalIdentity == publishedIdentity,
        let publishedCodeSignDigest = codeSignDigest(
          receipt.subprocesses[1], marker: "ARKDECK_CODE_SIGN_PUBLISHED"),
        sha256(receipt.subprocesses[2]) == deployment.artifactFacts.sha256,
        codeSignDigest(
          receipt.subprocesses[3], marker: "ARKDECK_CODE_SIGN_VERIFIED")
          == publishedCodeSignDigest
      else {
        let diagnostics = receipt.subprocesses.enumerated().map {
          "\($0.offset):\(boundedProcessDiagnostic($0.element))"
        }.joined(separator: ";")
        return .failed(
          code: "nativePublishMismatch",
          detail:
            "atomic publish did not preserve app-owned mode/uid/gid "
            + "or read back the leased ELF hash and fs-verity state "
            + "(subprocessCount=\(receipt.subprocesses.count), "
            + "diagnostics=\(diagnostics))")
      }
      return .verified(summary: [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "targetPath": deployment.targetPath,
        "fsVerityDigest": publishedCodeSignDigest,
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
        + (deployment.codeSignHelperRemotePath == nil ? 0 : 1)
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

    // D2 in `DEVICE-COMMAND-FACTS.md` §10, closed by readback rather than by
    // the status strings: absence is proven by the same probes reconcile
    // uses, so neither verdict depends on parsing `aa`/`bm` prose that no
    // device window has pinned.
    case .stopAbility(let ability):
      guard receipt.subprocesses.count == 2 else {
        return .unknown(reason: "stop did not produce its process readback")
      }
      guard let running = Self.processPresence(receipt.subprocesses[1]) else {
        return .unknown(
          reason: "process readback for \(ability.bundle.bundleName) is ambiguous")
      }
      guard !running else {
        return .failed(
          code: "stopIneffective",
          detail: "\(ability.bundle.bundleName) is still running after force-stop")
      }
      return .verified(summary: ["stopped": ability.bundle.bundleName])

    case .uninstallPackage(let bundle):
      guard receipt.subprocesses.count == 2 else {
        return .unknown(reason: "uninstall did not produce its package readback")
      }
      guard let installed = Self.packagePresence(
        receipt.subprocesses[1], bundleName: bundle.bundleName)
      else {
        return .unknown(reason: "package readback for \(bundle.bundleName) is ambiguous")
      }
      guard !installed else {
        return .failed(
          code: "uninstallIneffective",
          detail: "\(bundle.bundleName) is still installed after uninstall")
      }
      return .verified(summary: ["uninstalled": bundle.bundleName])

    case .createPortForward(let spec), .removePortForward(let spec):
      guard receipt.exitStatus == 0 else {
        return .failed(code: "portForwardFailed", detail: "tcp:\(spec.localPort)")
      }
      return .verified(summary: ["localPort": String(spec.localPort)])
    case .readPackagePresence(let bundle):
      guard let present = Self.packagePresence(
        Self.soleSubprocess(of: receipt), bundleName: bundle.bundleName)
      else {
        return .unknown(reason: "package presence readback is not trustworthy")
      }
      return .verified(summary: ["present": present ? "true" : "false"])
    case .readProcessPresence:
      guard let present = Self.processPresence(Self.soleSubprocess(of: receipt)) else {
        return .unknown(reason: "process presence readback is ambiguous")
      }
      return .verified(summary: ["present": present ? "true" : "false"])
    case .readOwnedDirectoryPresence:
      guard
        let present = pathPresence(
          exitStatus: receipt.exitStatus, stdout: receipt.stdout,
          stderr: receipt.stderr, stdoutTruncated: receipt.stdoutTruncated)
      else {
        return .unknown(reason: "owned-directory presence readback has no definite result")
      }
      return .verified(summary: ["present": present ? "true" : "false"])
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
      guard subprocesses.count == 2,
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256,
        let digest = codeSignDigest(
          subprocesses[1], marker: "ARKDECK_CODE_SIGN_VERIFIED")
      else {
        return .failed(
          code: "nativeTargetHashMismatch",
          detail: "published target hash or fs-verity state differs")
      }
      return .verified(summary: [
        "publishedSha256": deployment.artifactFacts.sha256,
        "fsVerityDigest": digest,
      ])
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
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256,
        subprocesses.count >= 2,
        let verityDigest = codeSignDigest(
          subprocesses[1], marker: "ARKDECK_CODE_SIGN_VERIFIED")
      else {
        return .failed(
          code: "nativeTargetHashMismatch",
          detail: "loader verification target hash differs from the leased ELF")
      }
      var summary = [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "abi": deployment.artifactFacts.abi.rawValue,
        "fsVerityDigest": verityDigest,
      ]
      if deployment.verificationProfile != .hashOnly {
        guard subprocesses.count >= 3,
          let pids = processIDs(subprocesses[2]), !pids.isEmpty
        else {
          return .failed(
            code: "nativeTargetNotRunning",
            detail: "loader verification found no target process")
        }
        summary["processIds"] = pids.map(String.init).joined(separator: ",")
        if deployment.verificationProfile == .hashProcessAndMaps {
          guard subprocesses.count == 4,
            mapsContain(
              subprocesses[3], targetPath: deployment.loaderVisiblePath,
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
        + (deployment.codeSignHelperRemotePath == nil ? 0 : 1)
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

  private func codeSignDigest(
    _ receipt: ProviderSubprocessReceipt,
    marker: String
  ) -> String? {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      receipt.stderr.isEmpty,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let lines = text.split(
      omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    guard lines.count == 1 else { return nil }
    let fields = lines[0].split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, fields[0] == Substring(marker),
      fields[1].hasPrefix("sha256:")
    else {
      return nil
    }
    let digest = String(fields[1].dropFirst("sha256:".count))
    guard digest.count == 64,
      digest.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
    else {
      return nil
    }
    return digest
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

  /// Views a single-process receipt as the subprocess it is, so one probe
  /// parser serves both the standalone reconcile probes and the readback leg
  /// of a mutation sequence.
  static func soleSubprocess(of receipt: ProviderProcessReceipt) -> ProviderSubprocessReceipt {
    ProviderSubprocessReceipt(
      exitStatus: receipt.exitStatus, stdout: receipt.stdout, stderr: receipt.stderr,
      stdoutTruncated: receipt.stdoutTruncated, durationSeconds: receipt.durationSeconds)
  }

  /// Three-valued reading of a `pidof <bundleName>` probe: running, not
  /// running, or `nil` when the output proves neither.
  ///
  /// Absence is empty output, and the exit status is deliberately not
  /// consulted. The 2026-07-31 device window measured all three shapes on
  /// DAYU200/hdc 3.2.0f:
  ///
  ///     pidof <running>   -> exit 0, "443"
  ///     pidof <stopped>   -> exit 0, ""
  ///     pidof <nonsense>  -> exit 0, ""
  ///
  /// `pidof` itself exits 1 for a name it cannot find, but `hdc shell`
  /// reports the *client's* status, so that 1 never crosses the transport —
  /// the same fact that makes exit codes useless for `aa`/`bm`. An earlier
  /// version of this helper required exit 1 for the absent case, a shape
  /// production could never produce, so every successful stop landed in
  /// `.unknown` and wedged the target's automatic-E1 lineage.
  ///
  /// Noise (a non-numeric token) still yields `nil`: a stop that reports
  /// success because the probe was unreadable is what this readback exists
  /// to prevent.
  static func processPresence(_ receipt: ProviderSubprocessReceipt) -> Bool? {
    guard !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let tokens = text.split(whereSeparator: \.isWhitespace)
    if tokens.isEmpty { return false }
    guard
      tokens.allSatisfy({ token in
        guard let value = UInt32(token) else { return false }
        return value > 0
      })
    else {
      return nil
    }
    return true
  }

  /// Three-valued reading of a `bm dump -n <bundleName>` probe. The bundle
  /// name is matched on its own boundaries so `com.example.demo` is not
  /// found inside `com.example.demo.helper`.
  ///
  /// Kept separate from `queryPackageReadback`'s verdict on purpose: that
  /// one answers "did install put it there", where absence is a definite
  /// failure. This one answers "is it there", where an unreadable probe is
  /// not an answer at all.
  static func packagePresence(
    _ receipt: ProviderSubprocessReceipt, bundleName: String
  ) -> Bool? {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let escaped = NSRegularExpression.escapedPattern(for: bundleName)
    return text.range(
      of: "(^|[^A-Za-z0-9_.])\(escaped)([^A-Za-z0-9_.]|$)",
      options: .regularExpression) != nil
  }

  /// Size of a remote regular file from one `ls -l` line, or `nil` when the
  /// line does not describe one (`ls: …: No such file or directory`, a
  /// directory, truncated output).
  ///
  /// Read from stdout, never from the exit status: `hdc shell` reports the
  /// client's status, so a missing file can still arrive with exit 0. Field
  /// order is the pinned one (`-rw-r--r-- 1 user group <size> …`,
  /// DEVICE-COMMAND-FACTS.md §8); the size column is field 5.
  static func remoteRegularFileByteCount(
    _ receipt: ProviderSubprocessReceipt
  ) -> Int? {
    guard !receipt.stdoutTruncated,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return nil
    }
    let fields = text.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 5, fields[0].first == "-", let size = Int(fields[4]) else {
      return nil
    }
    return size
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
    case .hdc(.captureTrace(_, let path)), .hdc(.cleanupOwnedRemotePath(let path)),
      .hdc(.captureComponentTree(let path)), .hdc(.captureScreenshot(let path)):
      readback = .hdc(.readOwnedPathPresence(path))
    case .hdc(.sendArtifactToStaging(let staged)):
      readback = .hdc(.readOwnedPathPresence(staged.path))
    case .hdc(.installPackage(_, let bundle)), .hdc(.uninstallPackage(let bundle)),
      .hdc(.installPackageSet(_, let bundle)):
      readback = .hdc(.readPackagePresence(bundle))
    case .hdc(.sendPackageSetToStaging(let set)), .hdc(.cleanupStagedPackageSet(let set)):
      readback = .hdc(.readOwnedDirectoryPresence(set.directory))
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
    case .hdc(.captureTrace), .hdc(.captureComponentTree), .hdc(.captureScreenshot),
      .hdc(.sendArtifactToStaging), .hdc(.installPackage),
      .hdc(.startAbility), .hdc(.createPortForward),
      .hdc(.sendPackageSetToStaging), .hdc(.installPackageSet):
      desiredPresence = true
    case .hdc(.cleanupOwnedRemotePath), .hdc(.stopAbility), .hdc(.uninstallPackage),
      .hdc(.removePortForward), .hdc(.cleanupStagedPackageSet):
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
    case .hdc(.captureTrace), .hdc(.captureComponentTree), .hdc(.captureScreenshot),
      .hdc(.cleanupOwnedRemotePath):
      // Remote-temp mutations reconcile by re-listing the owned path in a
      // later read; without that evidence the outcome stays unknown.
      return .stillUnknown(
        reason: "owned-path mutation needs a re-observation pass to conclude")
    case .hdc(.sendArtifactToStaging), .hdc(.installPackage), .hdc(.startAbility),
      .hdc(.stopAbility), .hdc(.uninstallPackage), .hdc(.createPortForward),
      .hdc(.sendPackageSetToStaging), .hdc(.installPackageSet),
      .hdc(.cleanupStagedPackageSet),
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

public protocol RockchipRuntimeFactsPort: Sendable {
  func currentFacts(targetID: String) async throws -> ProviderFacts
}

public struct RockchipFlashProviderAdapter: DeviceProvider {
  public let providerID = "rockchip"
  private let factsPort: (any RockchipRuntimeFactsPort)?
  private let availability: ProviderOperationAvailability

  public init(
    factsPort: (any RockchipRuntimeFactsPort)? = nil,
    availability: ProviderOperationAvailability = .unavailable(
      reason: "production Rockchip dispatcher is not registered")
  ) {
    self.factsPort = factsPort
    self.availability = availability
  }

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard operation.reference == "flash.dayu200@1" else {
      return .unavailable(
        reason: "Rockchip provider has no typed plan for \(operation.reference)")
    }
    return availability
  }

  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
    guard let factsPort else {
      throw DeviceProviderError.factsUnavailable(
        "production Rockchip target facts are not registered")
    }
    return try await factsPort.currentFacts(targetID: targetID)
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    throw DeviceProviderError.unsupportedAction(
      "\(step.stepID) requires engine-resolved target and Artifact facts")
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard operation.reference == "flash.dayu200@1" else {
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no Rockchip action for \(operation.reference)")
    }
    guard let connectKey = context.connectKey, !connectKey.isEmpty,
      let identity = context.expectedIdentitySHA256,
      identity.count == 64,
      identity.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else {
      throw DeviceProviderError.unsupportedAction(
        "\(step.stepID) requires a descriptor-bound target identity")
    }
    switch (step.stepID, step.kind) {
    case ("enter-loader-mode", .enterUpdater):
      return .rockchip(.enterLoader(connectKey: connectKey))
    case ("wait-loader-disconnect", .waitForDisconnect):
      return .rockchip(.waitForHDCDisconnect(connectKey: connectKey))
    case ("wait-loader-reconnect", .waitForReconnect):
      return .rockchip(.waitForLoader(stableIdentitySHA256: identity))
    case ("rebind-loader-identity", .probeDevice):
      return .rockchip(.rebindLoader(stableIdentitySHA256: identity))
    case ("flash-partitions", .flashPartition):
      return .rockchip(.flashPartitions(
        try flashBundle(inputs: inputs, context: context)))
    case ("verify-flash-readback", .verifyRemoteState):
      return .rockchip(.verifyFlashReadback(
        try flashBundle(inputs: inputs, context: context)))
    case ("reboot-device", .rebootDevice):
      return .rockchip(.rebootToNormal(stableIdentitySHA256: identity))
    case ("wait-for-hdc", .waitForReconnect):
      return .rockchip(.waitForHDCReconnect(connectKey: connectKey))
    case ("rebind-and-verify-build", .probeDevice):
      return .rockchip(.verifyBuild(connectKey: connectKey))
    case ("capture-post-flash-diagnostics", .captureRemoteStdout):
      return .rockchip(.capturePostFlashDiagnostics(
        connectKey: connectKey,
        request: try HDCHilogCaptureRequest(
          durationSeconds: 30, filters: [], byteBudget: 16 * 1024 * 1024)))
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.stepID) has no registered Rockchip runtime action")
    }
  }

  public func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .rockchip(let rockchipAction) = action else {
      throw DeviceProviderError.unsupportedAction("non-Rockchip action given to rockchip provider")
    }
    let descriptor: String
    switch rockchipAction {
    case .enterLoader:
      descriptor = "rockchip.hdc.enter-loader.v1"
    case .waitForHDCDisconnect:
      descriptor = "rockchip.hdc.wait-disconnect.v1"
    case .waitForLoader:
      descriptor = "rockchip.rockusb.wait-loader.v1"
    case .rebindLoader:
      descriptor = "rockchip.rockusb.rebind-loader.v1"
    case .flashPartitions(let bundle):
      descriptor =
        "rockchip.rockusb.flash-dayu200.v1:"
        + String(bundle.sha256.prefix(16))
    case .verifyFlashReadback(let bundle):
      descriptor =
        "rockchip.rockusb.verify-dayu200.v1:"
        + String(bundle.sha256.prefix(16))
    case .rebootToNormal:
      descriptor = "rockchip.rockusb.reboot-normal.v1"
    case .waitForHDCReconnect:
      descriptor = "rockchip.hdc.wait-reconnect.v1"
    case .verifyBuild:
      descriptor = "rockchip.hdc.verify-build.v1"
    case .capturePostFlashDiagnostics:
      descriptor = "rockchip.hdc.capture-post-flash-hilog.v1"
    }
    guard let bindingRevision = context.bindingRevision,
      let connectKey = context.connectKey, !connectKey.isEmpty,
      let expectedIdentitySHA256 = context.expectedIdentitySHA256,
      let providerExecutableSHA256 = context.toolSHA256
    else {
      throw DeviceProviderError.factsUnavailable(
        "\(context.stepID) has no complete host-managed target/tool correlation")
    }
    let actionEncoder = JSONEncoder()
    actionEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encodedAction = try actionEncoder.encode(
      try PersistedTypedProviderAction(action))
    let actionSHA256 = SHA256.hash(data: encodedAction)
      .map { String(format: "%02x", $0) }.joined()
    return TypedProcessPlan(
      action: action,
      kind: .hostManaged(
        HostManagedProcessDescriptor(
          identifier: descriptor,
          jobID: context.jobID,
          stepID: context.stepID,
          targetID: context.targetID,
          bindingRevision: bindingRevision,
          connectKey: connectKey,
          expectedIdentitySHA256: expectedIdentitySHA256,
          providerExecutableSHA256: providerExecutableSHA256,
          actionSHA256: actionSHA256)))
  }

  public func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    guard let recordID = receipt.hostManagedRecordID, !recordID.isEmpty else {
      // No step can verify from a bare exit status. The production
      // dispatcher must return its correlated durable semantic receipt.
      return .unknown(reason: "host-managed execution returned no durable record reference")
    }
    guard case .rockchip = action else {
      throw DeviceProviderError.unsupportedAction("non-Rockchip action given to rockchip provider")
    }
    return .verified(summary: ["recordId": recordID])
  }

  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    if intent.action.effect <= .readOnly {
      return .confirmedNotExecuted
    }
    return .stillUnknown(reason: "Rockchip mutation has no completed dedicated readback")
  }

  public func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    let action: TypedProviderAction
    switch intent.action {
    case .rockchip(.enterLoader):
      guard let identity = context.expectedIdentitySHA256 else {
        throw DeviceProviderError.factsUnavailable(
          "Loader transition recovery has no stable target identity")
      }
      action = .rockchip(.waitForLoader(stableIdentitySHA256: identity))
    case .rockchip(.flashPartitions(let bundle)):
      action = .rockchip(.verifyFlashReadback(bundle))
    case .rockchip(.rebootToNormal):
      guard let connectKey = context.connectKey, !connectKey.isEmpty else {
        throw DeviceProviderError.factsUnavailable(
          "normal-mode recovery has no descriptor-bound connect key")
      }
      action = .rockchip(.waitForHDCReconnect(connectKey: connectKey))
    default:
      return nil
    }
    return try lower(action: action, context: context)
  }

  public func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome {
    guard let plan = try reconciliationReadback(intent: intent, context: context) else {
      return .stillUnknown(reason: "Rockchip mutation has no dedicated readback")
    }
    switch try verify(
      receipt: receipt, action: plan.action, context: context)
    {
    case .verified(let summary):
      return .confirmedCompleted(summary: summary)
    case .failed(let code, let detail):
      return .stillUnknown(
        reason: "\(code): \(detail); destructive state is not safe to replay")
    case .unknown(let reason), .unsupported(let reason):
      return .stillUnknown(reason: reason)
    }
  }

  private func flashBundle(
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> RockchipRuntimeFlashBundle {
    guard case .string("dayu200@1")? = inputs["deviceProfile"] else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the exact dayu200@1 device profile")
    }
    guard case .string(let artifactLeaseID)? = inputs["imageBundleLease"],
      !artifactLeaseID.isEmpty
    else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the engine-resolved imageBundleLease")
    }
    guard case .array(let values)? = inputs["partitionPlan"] else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires an ordered partitionPlan")
    }
    let partitions: [String] = try values.map { value in
      guard case .string(let name) = value else {
        throw DeviceProviderError.unsupportedAction(
          "partitionPlan contains a non-string value")
      }
      return name
    }
    let expected = RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName)
    guard partitions == expected else {
      throw DeviceProviderError.unsupportedAction(
        "partitionPlan must exactly match the pinned DAYU200 order")
    }
    guard let artifact = context.resolvedInputArtifact,
      artifact.sha256 == RockchipFlashProfile.dayu200.archiveSHA256,
      artifact.byteCount == Int(RockchipFlashProfile.dayu200.archiveSizeBytes)
    else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the engine-resolved pinned DAYU200 image bundle")
    }
    return RockchipRuntimeFlashBundle(
      artifactLeaseID: artifactLeaseID,
      artifactID: artifact.artifactID,
      fileURL: artifact.fileURL,
      sha256: artifact.sha256,
      byteCount: artifact.byteCount,
      partitionNames: partitions)
  }
}
