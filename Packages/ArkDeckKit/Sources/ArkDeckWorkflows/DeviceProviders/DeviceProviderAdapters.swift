// Provider adapters over the runtime's execution stack (CHG-2026-047, T05).
//
// Neither adapter builds a second state machine. The HDC adapter composes the
// existing observation surfaces behind injected ports; the Rockchip adapter
// lowers each typed action for the engine's per-action host. It used to wrap
// the in-process RockchipFlashExecutionHost whole — that host was retired in
// T25, and the engine is now the only thing that executes ArkForge Flash.

import ArkDeckCore
import ArkDeckOpenHarmony
import CryptoKit
import Foundation

// MARK: - HDC observation adapter

/// Ports the HDC adapter needs. Kept minimal and injectable so contract
/// tests drive the adapter without a real tool; MU-3 supplies the
/// production composition (discovery + supervisor + registered probes).
package protocol HDCObservationFactsPort: Sendable {
  func currentFacts(targetID: String) async throws -> ProviderFacts
}

private struct HDCNativeFileIdentity: Equatable {
  let mode: String
  let userID: UInt32
  let groupID: UInt32
}

package struct HDCObservationProviderAdapter: DeviceProvider {
  /// The HDC provider's stable identity for a target, derived from the HDC
  /// connect key — the address the provider actually verifies against a live
  /// target row. This is the single source for both the daemon's facts port
  /// and the `confirm-evidence-target` verification below; the two MUST agree
  /// or every device-bound operation fails its identity check.
  ///
  /// It is deliberately NOT the target store's `stablePhysicalIdentitySHA256`:
  /// after a Loader-mode flash the Rockchip binding lineage advances that
  /// field to the Loader-mode identity (its campaign semantics), while the
  /// adopted record keeps its normal-mode connect key precisely so the Debug
  /// Runtime can come back. Feeding the campaign identity to this provider's
  /// verification made every observe/debug operation fail with
  /// `targetIdentityMismatch` from binding revision 2 onward (GJ-1 re-run,
  /// 2026-08-05).
  package static func stableIdentitySHA256(connectKey: String) -> String {
    SHA256Hex.string(of: Data(connectKey.lowercased().utf8))
  }

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
      .appending(path: "arkdeck-receive", directoryHint: .isDirectory)
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
          code: .providerToolUnavailable,
          reason: "bundled arm64 OpenHarmony code-sign helper cannot be verified")
        : .available)
  }

  package func resolveFacts(targetID: String) async throws -> ProviderFacts {
    try await factsPort.currentFacts(targetID: targetID)
  }

  /// Keep the native-library facts the package readback already fetched.
  ///
  /// `bm dump -n <bundle>` answers with the installed bundle in full, and the
  /// readback used it for one thing: whether the bundle name appears.
  /// Everything else was discarded — including the three fields that say
  /// whether the device accepted the libraries the package ships.
  ///
  /// That mattered on real hardware. An app whose `.so` was present in the
  /// HAP, valid for the device's architecture and correctly signed still could
  /// not load it, and every install reported nothing but `installed: true`.
  /// The dump had been saying `nativeLibraryPath: ""`, `cpuAbi: ""` and
  /// `nativeLibraryFileNames: []` all along — the device matched none of the
  /// packaged ABI directories. Finding that took several deploy rounds and two
  /// readings taken by hand, from bytes this step had already read.
  ///
  /// Empty values are the finding, so they are recorded rather than skipped:
  /// absent and empty are two different answers here. Parsing is best-effort
  /// and never changes the verdict above — the bundle-name gate stays a text
  /// match, so a dump this cannot decode still installs.
  static func appendNativeLibraryFacts(from text: String, to summary: inout [String: String]) {
    // `bm dump` prints `<bundleName>:` before the document.
    guard let start = text.firstIndex(of: "{"),
      let parsed = try? JSONSerialization.jsonObject(
        with: Data(text[start...].utf8)) as? [String: Any]
    else { return }

    if let application = parsed["applicationInfo"] as? [String: Any] {
      if let path = application["nativeLibraryPath"] as? String {
        summary["nativeLibraryPath"] = path
      }
      if let abi = application["cpuAbi"] as? String {
        summary["cpuAbi"] = abi
      }
    }
    if let modules = parsed["hapModuleInfos"] as? [[String: Any]] {
      let counted = modules.compactMap { $0["nativeLibraryFileNames"] as? [Any] }
      // Counted rather than listed: the count answers "did the device take any
      // of them", and the names are already in the HAP for anyone who needs
      // them.
      summary["nativeLibraryFileCount"] = String(counted.reduce(0) { $0 + $1.count })
    }
  }

  package func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    switch operation.reference {
    case "observe.device@1", "capture.diagnostics@1", "debug.hap@1",
      "port-forward.create@1", "port-forward.remove@1":
      return .available
    case "deploy.native-library.app-owned@1":
      return appOwnedNativeLibraryAvailability
    default:
      return .unavailable(
        code: .operationNotSupported,
        reason: "HDC provider has no complete production typed plan for "
          + operation.reference)
    }
  }

  package func action(
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

  package func action(
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
    case .createPortForward:
      return .hdc(.createPortForward(try portForwardSpec(inputs)))
    case .removePortForward:
      return .hdc(.removePortForward(try portForwardSpec(inputs)))
    case .injectPointerInput:
      return .hdc(.injectPointerInput(try pointerInputSpec(operation, inputs)))
    case .runApprovedRemoteRead:
      if descriptorIsDebugHAP(operation), step.actionReference?.actionID == "packageInfo" {
        return try debugHAPAction(for: step, inputs: inputs, context: context)
      }
      return try approvedRemoteReadAction(for: step, inputs: inputs)
    case .verifyRemoteState:
      if operation.reference == "port-forward.create@1"
        || operation.reference == "port-forward.remove@1"
      {
        return .hdc(.readPortForwardPresence(try portForwardSpec(inputs)))
      }
      if descriptorIsDebugHAP(operation) {
        return try debugHAPAction(for: step, inputs: inputs, context: context)
      }
      if operation.reference == "capture.diagnostics@1",
        step.stepID == "observe-application-liveness"
      {
        return try applicationLivenessAction(inputs: inputs)
      }
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no registered action for \(operation.reference)")
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

  /// The gesture is the operation's identity, never an input: `input.tap@1`
  /// can only ever inject a tap. Coordinates and the swipe duration are the
  /// operation's typed inputs, already schema-bounded by admission.
  private func pointerInputSpec(
    _ operation: CatalogOperationDescriptor,
    _ inputs: [String: JSONValue]
  ) throws -> HDCPointerInputSpec {
    let gesture: HDCPointerGesture
    switch operation.reference {
    case "input.tap@1": gesture = .tap
    case "input.long-press@1": gesture = .longPress
    case "input.swipe@1": gesture = .swipe
    default:
      throw DeviceProviderError.unsupportedAction(
        "\(operation.reference) has no registered pointer gesture")
    }
    func requiredCoordinate(_ key: String) throws -> Int {
      guard case .integer(let value)? = inputs[key], let coordinate = Int(exactly: value)
      else {
        throw DeviceProviderError.unsupportedAction("\(key) is required for a pointer input")
      }
      return coordinate
    }
    func optionalInteger(_ key: String) throws -> Int? {
      guard let raw = inputs[key] else { return nil }
      guard case .integer(let value) = raw, let integer = Int(exactly: value) else {
        throw DeviceProviderError.unsupportedAction("\(key) must be an integer")
      }
      return integer
    }
    if gesture == .swipe {
      return try HDCPointerInputSpec(
        gesture: gesture,
        x: try requiredCoordinate("fromX"), y: try requiredCoordinate("fromY"),
        toX: try requiredCoordinate("toX"), toY: try requiredCoordinate("toY"),
        durationMs: try requiredCoordinate("durationMs"),
        displayID: try optionalInteger("displayId"))
    }
    return try HDCPointerInputSpec(
      gesture: gesture,
      x: try requiredCoordinate("x"), y: try requiredCoordinate("y"),
      displayID: try optionalInteger("displayId"))
  }

  private func portForwardSpec(
    _ inputs: [String: JSONValue]
  ) throws -> HDCPortForwardSpec {
    guard case .string(let directionText)? = inputs["direction"],
      let direction = HDCPortForwardDirection(rawValue: directionText),
      case .integer(let localValue)? = inputs["localPort"],
      case .integer(let remoteValue)? = inputs["remotePort"],
      let localPort = Int(exactly: localValue),
      let remotePort = Int(exactly: remoteValue)
    else {
      throw DeviceProviderError.unsupportedAction(
        "direction, localPort and remotePort are required for a port rule")
    }
    return try HDCPortForwardSpec(
      direction: direction, localPort: localPort, remotePort: remotePort)
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
      // `const.product.model` may expose only a generic platform/build value.
      // The user-facing product label comes from `const.product.name`; keep
      // the published action ID for durable compatibility while reading that
      // property.
      return .hdc(.queryProperty(.productName))
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
    case "crashIndex":
      return .hdc(.captureCrashIndex(byteBudget: 8 * 1024 * 1024))
    case "crashLog":
      guard case .string(let name)? = inputs["crashLogName"] else {
        throw DeviceProviderError.unsupportedAction(
          "crashLogName input is required to fetch one Faultlogger entry")
      }
      return .hdc(
        .captureCrashLog(try HDCFaultLogName(name), byteBudget: 8 * 1024 * 1024))
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

  private func applicationLivenessAction(
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    guard case .string(let bundleName)? = inputs["bundleName"] else {
      throw DeviceProviderError.unsupportedAction(
        "bundleName is required for application liveness")
    }
    let abilityName: String?
    if case .string(let value)? = inputs["abilityName"] {
      abilityName = value
    } else {
      abilityName = nil
    }
    let processName: String?
    if case .string(let value)? = inputs["processName"] {
      processName = value
    } else {
      processName = nil
    }
    let deployedDigest: String?
    if case .string(let value)? = inputs["expectedDeployedArtifactDigest"] {
      deployedDigest = value
    } else {
      deployedDigest = nil
    }
    return .hdc(
      .observeApplicationLiveness(
        try HDCApplicationLivenessRequest(
          bundle: HDCBundleReference(bundleName: bundleName),
          abilityName: abilityName, processName: processName,
          expectedDeployedArtifactDigest: deployedDigest)))
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
        "\(restart.rawValue) has no complete app-owned restart/readback plan; refusing before authorization"
      )
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
      return .hdc(
        .inspectNativeLibrary(
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

  package func lower(
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
        kind: .process(
          executableSHA256: "resolved-at-dispatch", argumentSummary: ["-v"], timeoutSeconds: 15))
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
          timeoutSeconds: request.commandTimeoutSeconds),
        // `hilog -x` has no duration flag — it drains the current buffers and
        // exits, which is why `durationSeconds` bounds the timeout above rather
        // than the argv. The byte budget is the bound that does belong to the
        // output, and it has to travel with the plan: the request's default is
        // 16 MiB and the dispatcher's is 8 MiB.
        outputByteBudget: request.byteBudget)
    case .captureCrashIndex:
      // The `-p …` payload is a single argv element after `-a`, exactly as
      // §6 records it. Faultlogger's SA id is 1201.
      //
      // `-l` rather than the bare form: both return the same list here, but
      // `-l` is the option Faultlogger's own usage text documents, and the
      // bare form relies on an implicit default. `-f` below has no such
      // alternative — it is undocumented and depended upon, which is why
      // its verdict fails closed instead of degrading to an empty result
      // (TASK-DHA-005 evidence, faultlogger-format-2026-07-31.md).
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger -l"],
            context: context),
          timeoutSeconds: 30))
    case .captureCrashLog(let name, _):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger -f \(name.value)"],
            context: context),
          timeoutSeconds: 30))
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
                [
                  "shell", "hitrace", "-t", String(request.durationSeconds), "-b",
                  String(request.bufferKB),
                ] + request.categories + ["-o", path.remotePath],
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
    case .observeApplicationLiveness(let request):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "pidof", request.processName], context: context),
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
    case .injectPointerInput(let spec):
      // `uitest uiInput` argv is positional; swipe carries a velocity derived
      // from the caller's real hold duration (px/s, closed range), never the
      // duration itself — the device command has no duration parameter.
      var uiInput: [String]
      switch spec.gesture {
      case .tap:
        uiInput = ["click", String(spec.x), String(spec.y)]
      case .longPress:
        uiInput = ["longClick", String(spec.x), String(spec.y)]
      case .swipe:
        guard let toX = spec.toX, let toY = spec.toY, let velocity = spec.swipeVelocity
        else {
          throw DeviceProviderError.unsupportedAction("a swipe needs an end point and duration")
        }
        uiInput = [
          "swipe", String(spec.x), String(spec.y), String(toX), String(toY),
          String(velocity),
        ]
      }
      if let displayID = spec.displayID { uiInput.append(String(displayID)) }
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "uitest", "uiInput"] + uiInput, context: context),
          timeoutSeconds: 30))
    case .createPortForward(let spec):
      let verb = spec.direction == .forward ? "fport" : "rport"
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            [verb, "tcp:\(spec.localPort)", "tcp:\(spec.remotePort)"],
            context: context),
          timeoutSeconds: 30))
    case .removePortForward(let spec):
      let verb = spec.direction == .forward ? "fport" : "rport"
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            [verb, "rm", "tcp:\(spec.localPort)"], context: context),
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
    case .readPortForwardPresence(let spec):
      let verb = spec.direction == .forward ? "fport" : "rport"
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments([verb, "ls"], context: context),
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
          "native send requires the same engine-resolved Artifact and a job-owned staging directory"
        )
      }
      return try nativeSequence(
        action: action, context: context,
        commands: [
          (["shell", "mkdir", "-p", deployment.stagingDirectoryPath], false, 30),
          (["file", "send", resolved.fileURL.path, deployment.stagingPath], false, 300),
          (
            [
              "file", "send", nativeCodeSignHelper.fileURL.path,
              helperRemotePath,
            ], false, 60
          ),
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
          // The backup is a hard link to the file about to be replaced, so it
          // keeps that file's attestation across the rename. Reading it here
          // is this side's own measurement of what the replacement must match,
          // independent of the branch the helper took.
          (
            [
              "shell", helperRemotePath, "verify", deployment.backupPath,
            ], true, 30
          ),
          (
            [
              "shell", helperRemotePath, "publish", deployment.stagingPath,
              deployment.targetPath, deployment.rollbackStagingPath,
            ], false, 60
          ),
          (["shell", "sha256sum", deployment.targetPath], false, 30),
          (
            [
              "shell", helperRemotePath, "verify", deployment.targetPath,
            ], true, 30
          ),
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
          (
            [
              "shell", "aa", "start", "-b", deployment.bundle.bundleName, "-a",
              HDCAppOwnedNativeLibraryDeployment.entryAbility,
            ], true, 60
          ),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
        ])
    case .cleanupNativeLibrary(let deployment):
      var commands: [([String], Bool, Int)] = [
        (["shell", "rm", "-f", deployment.stagingPath], true, 30)
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
          (
            [
              "shell", "ln", deployment.backupPath, deployment.rollbackStagingPath,
            ], true, 60
          ),
          (
            [
              "shell", "mv", "-f", deployment.rollbackStagingPath,
              deployment.targetPath,
            ], true, 60
          ),
          (["shell", "sha256sum", deployment.targetPath], true, 30),
          (
            [
              "shell", "aa", "start", "-b", deployment.bundle.bundleName, "-a",
              HDCAppOwnedNativeLibraryDeployment.entryAbility,
            ], true, 60
          ),
          (["shell", "sleep", "2"], true, 5),
          (["shell", "pidof", deployment.bundle.bundleName], true, 30),
          (
            [
              "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
            ], true, 30
          ),
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
        (["shell", helperRemotePath, "verify", deployment.backupPath], true, 30),
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
        (["shell", helperRemotePath, "verify", deployment.backupPath], true, 30),
        (["shell", helperRemotePath, "verify", deployment.targetPath], true, 30),
      ]
      if deployment.verificationProfile != .hashOnly {
        selected.append(
          (["shell", "pidof", deployment.bundle.bundleName], true, 30))
      }
      if deployment.verificationProfile == .hashProcessAndMaps {
        selected.append(
          (
            [
              "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
            ], true, 30
          ))
      }
      commands = selected
    case .cleanupComplete:
      var selected: [([String], Bool, Int)] = [
        (["shell", "ls", "-ld", deployment.stagingPath], true, 15)
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
          (
            [
              "shell", "grep", "-F", deployment.loaderVisiblePath, "/proc/*/maps",
            ], true, 30
          ))
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
    hostReceiveRoot.appending(
      path:
        URL(filePath: remote.remotePath).lastPathComponent, directoryHint: .notDirectory)
  }

  /// Mints a provider-owned staging path for an artifact lease. As with
  /// remote temp paths, the caller never supplies a device location.
  package func mintStagedArtifact(
    jobID: String, stepID: String, artifactLeaseID: String, expectedSHA256: String?
  ) throws -> HDCStagedArtifact {
    HDCStagedArtifact(
      path: try mintOwnedRemotePath(jobID: jobID, stepID: stepID),
      artifactLeaseID: artifactLeaseID, expectedSHA256: expectedSHA256)
  }

  /// Mints a provider-owned remote temp path bound to job/step. The only
  /// construction point outside tests; callers cannot supply device paths.
  package func mintOwnedRemotePath(jobID: String, stepID: String) throws -> HDCOwnedRemotePath {
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

  package func verify(
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
        let identity = Self.stableIdentitySHA256(connectKey: expectedConnectKey)
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
    case .captureCrashIndex:
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "crash index exceeded its budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "crash index is not UTF-8")
      }
      // An empty ledger is a truthful answer, not a failure: the device
      // says so in words, and the artifact records those words.
      let entries = Self.faultLogEntries(in: text)
      return .verified(summary: [
        "entryCount": String(entries.count),
        "byteCount": String(receipt.stdout.count),
      ])

    case .captureCrashLog(let name, _):
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "crash log exceeded its budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "crash log is not UTF-8")
      }
      guard !text.contains("invalid parameters.") else {
        // The device's answer for a name it does not have.
        return .failed(
          code: "faultLogNotFound", detail: "device has no entry named \(name.value)")
      }
      guard text.contains("Generated by HiviewDFX") else {
        return .unknown(reason: "crash log did not carry its HiviewDFX header")
      }
      return .verified(summary: [
        "faultLogName": name.value, "byteCount": String(receipt.stdout.count),
      ])

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
      return installDispatchOutcome(receipt)

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
      if pathPresence(
        exitStatus: receipt.subprocesses[0].exitStatus,
        stdout: receipt.subprocesses[0].stdout,
        stderr: receipt.subprocesses[0].stderr,
        stdoutTruncated: receipt.subprocesses[0].stdoutTruncated) == false
      {
        return .failed(
          code: "nativeAppOwnedDirectoryMissing",
          detail:
            "the target bundle has no app-owned native library directory; "
            + "install the signed application before deploying its library")
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
      func publishFailure() -> ProviderSemanticOutcome {
        let diagnostics = receipt.subprocesses.enumerated().map {
          "\($0.offset):\(boundedProcessDiagnostic($0.element))"
        }.joined(separator: ";")
        return .failed(
          code: "nativePublishMismatch",
          detail:
            "atomic publish did not preserve app-owned mode/uid/gid, read back "
            + "the leased ELF hash, or leave the published library at least as "
            + "attested as the one it replaced "
            + "(subprocessCount=\(receipt.subprocesses.count), "
            + "diagnostics=\(diagnostics))")
      }
      guard receipt.subprocesses.count == 6,
        let originalIdentity = nativeFileIdentity(receipt.subprocesses[0]),
        let publishedIdentity = nativeFileIdentity(receipt.subprocesses[5]),
        originalIdentity == publishedIdentity,
        sha256(receipt.subprocesses[3]) == deployment.artifactFacts.sha256
      else {
        return publishFailure()
      }
      // The backup is a hard link to the replaced file, so this reads that
      // file's attestation even though the rename has already happened.
      let replacedAttestation = readbackAttestation(receipt.subprocesses[1])
      let publishedAttestation = readbackAttestation(receipt.subprocesses[4])
      var summary = [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "targetPath": deployment.targetPath,
        "mode": originalIdentity.mode,
        "uid": String(originalIdentity.userID),
        "gid": String(originalIdentity.groupID),
      ]
      switch replacedAttestation {
      case .unreadable:
        // Not an answer about the replaced file, so nothing here can say the
        // replacement matches it.
        return publishFailure()
      case .attested:
        // Unchanged from before: an attested original still demands an
        // attested replacement, and the helper's own digest must agree with
        // what the device reads back afterwards.
        guard
          let announced = codeSignDigest(
            receipt.subprocesses[2], marker: "ARKDECK_CODE_SIGN_PUBLISHED"),
          publishedAttestation == .attested(announced)
        else {
          return publishFailure()
        }
        summary["fsVerityDigest"] = announced
        summary["attestation"] = "fsVerity"
      case .absent:
        // Stricter here than `attestationAtLeastReplaced` is later, and
        // deliberately: at this instant the helper is the only thing that
        // touched the file, so if it reports having enabled nothing and the
        // device reads back an attestation anyway, something unaccounted for
        // wrote the library. Later readbacks sit after restarts and cannot
        // attribute that, so there the rule is only the floor.
        //
        // No `fsVerityDigest` key at all rather than an empty or placeholder
        // one: a record that carries the field is read as having the property.
        guard publishedWithoutAttestation(receipt.subprocesses[2]),
          publishedAttestation == .absent
        else {
          return publishFailure()
        }
        summary["attestation"] = "matchesReplacedFile:none"
      }
      return .verified(summary: summary)

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
      return installDispatchOutcome(receipt)

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
      var summary = ["bundleName": bundle.bundleName, "installed": "true"]
      // Bind the package readback to the exact immutable Artifact whose lease
      // this job resolved.  A repairing caller compares this value with
      // the build-output digest before it may enter VERIFYING; an install exit
      // code or bundle-name match alone is not that gate (TASK-HFA-003).
      if let digest = context.resolvedInputArtifact?.sha256 {
        summary["deployedArtifactSha256"] = digest
      }
      HDCObservationProviderAdapter.appendNativeLibraryFacts(from: text, to: &summary)
      return .verified(summary: summary)

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

    case .observeApplicationLiveness(let request):
      let identityMaterial = [
        request.bundle.bundleName, request.abilityName ?? "", request.processName,
      ].joined(separator: "|")
      let applicationRef = SHA256Hex.string(of: Data(identityMaterial.utf8))
      var summary: [String: String] = [
        "applicationRef": applicationRef,
        "abilityState": "UNKNOWN",
        "observedAtUtc": context.nowUTC,
      ]
      if let digest = request.expectedDeployedArtifactDigest {
        summary["deployedArtifactDigest"] = digest
      }
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
        let text = String(data: receipt.stdout, encoding: .utf8)
      else {
        summary["state"] = "UNKNOWN"
        summary["processState"] = "UNKNOWN"
        summary["pidObserved"] = "false"
        summary["reasonCode"] =
          receipt.stdoutTruncated
          ? "processReadbackTruncated" : "processReadbackUnavailable"
        return .verified(summary: summary)
      }
      let tokens = text.split(whereSeparator: \.isWhitespace)
      if tokens.isEmpty {
        summary["state"] = "UNHEALTHY"
        summary["processState"] = "STOPPED"
        summary["pidObserved"] = "false"
        summary["reasonCode"] = "targetProcessNotRunning"
        return .verified(summary: summary)
      }
      guard
        tokens.allSatisfy({ token in
          guard let value = UInt32(token) else { return false }
          return value > 0
        })
      else {
        summary["state"] = "UNKNOWN"
        summary["processState"] = "UNKNOWN"
        summary["pidObserved"] = "false"
        summary["reasonCode"] = "processReadbackAmbiguous"
        return .verified(summary: summary)
      }
      summary["state"] = "HEALTHY"
      summary["processState"] = "RUNNING"
      summary["pidObserved"] = "true"
      summary["reasonCode"] = "targetProcessRunning"
      return .verified(summary: summary)

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
      guard
        let installed = Self.packagePresence(
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
    case .injectPointerInput(let spec):
      // uiInput exits 0 even when it rejects the input; the verdict comes from
      // its stdout. "No Error" is the success line and must be whitelisted
      // before scanning, because it contains the substring "error"
      // (DEVICE-COMMAND-FACTS §7, real-device 2026-08-25).
      guard receipt.exitStatus == 0 else {
        return .failed(
          code: "pointerInputFailed", detail: "uiInput exited \(receipt.exitStatus)")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .unknown(reason: "uiInput stdout is not UTF-8; the gesture outcome is unknown")
      }
      let lowered = text.lowercased()
      let scanned = lowered.replacingOccurrences(of: "no error", with: "")
      let failureMarks = ["illegal", "fail", "error", "incorrect", "please confirm"]
      if let mark = failureMarks.first(where: { scanned.contains($0) }) {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? mark
        return .failed(
          code: "pointerInputRejected",
          detail: firstLine.trimmingCharacters(in: .whitespaces))
      }
      guard lowered.contains("no error") else {
        return .unknown(
          reason: "uiInput printed neither the success line nor a recognized failure")
      }
      var summary = [
        "gesture": spec.gesture.rawValue,
        "x": String(spec.x),
        "y": String(spec.y),
      ]
      if let toX = spec.toX { summary["toX"] = String(toX) }
      if let toY = spec.toY { summary["toY"] = String(toY) }
      if let durationMs = spec.durationMs { summary["durationMs"] = String(durationMs) }
      if let velocity = spec.swipeVelocity { summary["loweredVelocity"] = String(velocity) }
      if let displayID = spec.displayID { summary["displayId"] = String(displayID) }
      return .verified(summary: summary)
    case .readPackagePresence(let bundle):
      guard
        let present = Self.packagePresence(
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
      guard subprocesses.count == 3,
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256,
        let attestation = attestationAtLeastReplaced(
          replaced: subprocesses[1], published: subprocesses[2])
      else {
        return .failed(
          code: "nativeTargetHashMismatch",
          detail:
            "published target hash differs, or it is less attested than the "
            + "library it replaced")
      }
      var summary = ["publishedSha256": deployment.artifactFacts.sha256]
      summary.merge(attestation) { current, _ in current }
      return .verified(summary: summary)
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
      guard subprocesses.count >= 3,
        sha256(subprocesses[0]) == deployment.artifactFacts.sha256,
        let attestation = attestationAtLeastReplaced(
          replaced: subprocesses[1], published: subprocesses[2])
      else {
        return .failed(
          code: "nativeTargetHashMismatch",
          detail:
            "loader verification target hash differs from the leased ELF, or "
            + "it is less attested than the library it replaced")
      }
      var summary = [
        "publishedSha256": deployment.artifactFacts.sha256,
        "buildId": deployment.artifactFacts.buildID,
        "abi": deployment.artifactFacts.abi.rawValue,
      ]
      summary.merge(attestation) { current, _ in current }
      // Always stated, never left to an absent key. Under a profile below
      // `hashProcessAndMaps` this step reads no `/proc/*/maps` at all, so its
      // `.verified` says only that the bytes on disk match and a process is
      // alive — and the target path and the loader-visible path are different
      // mount views, so neither implies the loader mapped the new library.
      // Silence would be indistinguishable from a run that did prove it, which
      // is exactly how a GJ-3 record could read `verified` over a library that
      // was never loaded. The compensation path holds the stronger bar
      // unconditionally: `.rollbackNativeLibrary` requires `mapsMatched`
      // whatever the profile says, so a success path that quietly proves less
      // must at least say so.
      summary["loaderVerified"] = Self.loaderNotObserved
      if deployment.verificationProfile != .hashOnly {
        guard subprocesses.count >= 4,
          let pids = processIDs(subprocesses[3]), !pids.isEmpty
        else {
          return .failed(
            code: "nativeTargetNotRunning",
            detail: "loader verification found no target process")
        }
        summary["processIds"] = pids.map(String.init).joined(separator: ",")
        if deployment.verificationProfile == .hashProcessAndMaps {
          guard subprocesses.count == 5,
            mapsContain(
              subprocesses[4], targetPath: deployment.loaderVisiblePath,
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
        // Same rule as the publish readback: under a weaker profile this read
        // never looked at the loader, and "restored" must not be read as
        // "restored and mapped".
        "loaderVerified": deployment.verificationProfile == .hashProcessAndMaps
          ? "true" : Self.loaderNotObserved,
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

  /// What a `verify` readback established about one file.
  ///
  /// Three-way on purpose. "No digest parsed" covers both "the device said
  /// this file has no fs-verity" and "the readback did not happen" — and only
  /// the first may license publishing a library with none.
  private enum ReadbackAttestation: Equatable {
    case attested(String)
    /// The device positively answered: the file is there and carries none.
    case absent
    /// No answer. A missing file, a truncated readback, an unexpected errno.
    case unreadable
  }

  /// `ENODATA` — present, no fs-verity. `EOPNOTSUPP` — this filesystem cannot
  /// carry it at all. Both are real answers about a file that exists.
  private static let unattestedErrnoFields: Set<String> = [
    "errno=61", "errno=95",
  ]

  /// `loaderVerified` when the readback never looked at `/proc/*/maps`.
  /// A distinct value rather than an absent key, for the same reason
  /// `publishedWithoutAttestation` has its own marker: silence is also what a
  /// readback that never ran produces, and a reader cannot tell those apart.
  static let loaderNotObserved = "notObserved"

  private func readbackAttestation(
    _ receipt: ProviderSubprocessReceipt
  ) -> ReadbackAttestation {
    if let digest = codeSignDigest(receipt, marker: "ARKDECK_CODE_SIGN_VERIFIED") {
      return .attested(digest)
    }
    // The errno is the failing call's, because the helper records it at the
    // point of failure rather than after its cleanup. That is what makes this
    // distinction available at all: `ENOENT` and `ENODATA` both used to
    // arrive as "no digest", and reading the first as "this file has no
    // fs-verity" would let a missing backup authorise an unattested publish.
    //
    // Read from either stream, and not gated on the exit status: the helper
    // writes this to stderr, but HDC delivers a remote command's streams
    // merged onto stdout and reports its own exit status, not the remote
    // one. Insisting on stderr and a non-zero exit passes every scripted
    // test and matches nothing a device actually returns.
    guard !receipt.stdoutTruncated,
      let out = String(data: receipt.stdout, encoding: .utf8),
      let err = String(data: receipt.stderr, encoding: .utf8)
    else {
      return .unreadable
    }
    let lines = (out + err).split(
      omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    guard lines.count == 1 else { return .unreadable }
    let fields = lines[0].split(whereSeparator: \.isWhitespace)
    guard fields.count == 4, fields[0] == "ARKDECK_CODE_SIGN_ERROR",
      fields[1] == "stage=verify", fields[2] == "code=30",
      Self.unattestedErrnoFields.contains(String(fields[3]))
    else {
      return .unreadable
    }
    return .absent
  }

  /// The published library must be at least as attested as the one it
  /// replaced. Returns the summary fields describing what it actually
  /// carries, or `nil` when that rule is broken or cannot be established.
  ///
  /// `replaced` reads the backup, which is a hard link to the file that was
  /// replaced and therefore still answers for it. The asymmetry is the point:
  /// an attested original always demands an attested replacement, while an
  /// original the platform never attested demands nothing it cannot have.
  private func attestationAtLeastReplaced(
    replaced: ProviderSubprocessReceipt,
    published: ProviderSubprocessReceipt
  ) -> [String: String]? {
    let replacedState = readbackAttestation(replaced)
    guard replacedState != .unreadable else { return nil }
    switch readbackAttestation(published) {
    case .attested(let digest):
      // At or above the floor either way — including when the original
      // carried none. The rule is a floor, not an equality.
      return ["fsVerityDigest": digest, "attestation": "fsVerity"]
    case .absent where replacedState == .absent:
      return ["attestation": "matchesReplacedFile:none"]
    case .absent, .unreadable:
      return nil
    }
  }

  /// Whether the helper reported publishing without enabling code signing,
  /// because the file it replaced carried none either.
  ///
  /// Deliberately its own marker rather than an absent
  /// `ARKDECK_CODE_SIGN_PUBLISHED` line: silence would also be what a helper
  /// that crashed before printing anything produces, and those must not
  /// verify the same way.
  private func publishedWithoutAttestation(
    _ receipt: ProviderSubprocessReceipt
  ) -> Bool {
    guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
      receipt.stderr.isEmpty,
      let text = String(data: receipt.stdout, encoding: .utf8)
    else {
      return false
    }
    let lines = text.split(
      omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    guard lines.count == 1 else { return false }
    return lines[0].split(whereSeparator: \.isWhitespace)
      == ["ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED", "replaced-file-had-none"]
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

  /// `hdc shell` reports the transport client's status, so an exit status of
  /// zero does not prove that `bm install` accepted the package. Preserve the
  /// paired package readback as the only success proof, while surfacing a
  /// bounded diagnostic when the package manager itself returned a definite
  /// non-success response. Empty output remains unknown for older registered
  /// tool shapes; arbitrary device text is never copied into the journal.
  private func installDispatchOutcome(
    _ receipt: ProviderProcessReceipt
  ) -> ProviderSemanticOutcome {
    guard let exitStatus = receipt.exitStatus else {
      return .unknown(reason: "install produced no process result")
    }
    guard exitStatus == 0 else {
      return .failed(
        code: "installFailed",
        detail: "install process reported failure; "
          + boundedProcessDiagnostic(Self.soleSubprocess(of: receipt)))
    }
    guard !receipt.stdoutTruncated else {
      return .failed(
        code: "installOutputTruncated",
        detail: boundedProcessDiagnostic(Self.soleSubprocess(of: receipt)))
    }
    if let text = String(data: receipt.stdout, encoding: .utf8) {
      if text.localizedCaseInsensitiveContains("install bundle successfully") {
        return .unknown(reason: "install requires package readback before it can be believed")
      }
      if text.contains("code:9568423"),
        text.localizedCaseInsensitiveContains("device is unauthorized")
      {
        return .failed(
          code: "deviceUDIDUnauthorized",
          detail:
            "package signing profile does not authorize the connected device "
            + "(bm code 9568423)")
      }
    }
    guard receipt.stdout.isEmpty, receipt.stderr.isEmpty else {
      return .failed(
        code: "installRejected",
        detail: boundedProcessDiagnostic(Self.soleSubprocess(of: receipt)))
    }
    return .unknown(reason: "install requires package readback before it can be believed")
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
      SHA256Hex.lowercaseHex(data.prefix(byteLimit))
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
      [
        UInt8(ascii: "-"), UInt8(ascii: "d"), UInt8(ascii: "l"),
        UInt8(ascii: "b"), UInt8(ascii: "c"), UInt8(ascii: "p"),
        UInt8(ascii: "s"),
      ].contains(first),
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

  /// The entries a Faultlogger index lists, in order. They sit between two
  /// `******` lines (measured 2026-07-31); an empty ledger prints the two
  /// markers with nothing between them and says `No fault log exist.`
  ///
  /// Note the entries are NOT file names: on disk each carries trailing
  /// milliseconds and `.log` that the index omits. Treating one as a path
  /// finds nothing.
  static func faultLogEntries(in text: String) -> [String] {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let first = lines.firstIndex(of: "******"),
      let last = lines.lastIndex(of: "******"), last > first
    else {
      return []
    }
    return lines[(first + 1)..<last].filter { !$0.isEmpty }
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

  package func reconciliationReadback(
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
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .stagingMatchesArtifact))
    case .hdc(.backupNativeLibrary(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .backupMatchesTarget))
    case .hdc(.publishNativeLibrary(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .targetMatchesArtifact))
    case .hdc(.stopNativeTarget(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .targetStopped))
    case .hdc(.startNativeTarget(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .targetStarted))
    case .hdc(.cleanupNativeLibrary(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .cleanupComplete))
    case .hdc(.rollbackNativeLibrary(let deployment)):
      readback = .hdc(
        .inspectNativeLibrary(
          deployment, expectation: .rollbackRestored))
    default:
      return nil
    }
    return try lower(action: readback, context: context)
  }

  package func verifyReconciliationReadback(
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
    case .hdc(.queryPackageReadback), .hdc(.verifyProcessState),
      .hdc(.observeApplicationLiveness):
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
    case .hdc(.injectPointerInput):
      // An injected gesture leaves no device-observable state to read back.
      // The outcome stays unknown permanently and the intent is never
      // replayed; the caller surfaces it as an unknown input result.
      return .stillUnknown(
        reason: "an injected pointer gesture has no observable readback")
    case .hdc(.inspectNativeLibrary):
      return .confirmedNotExecuted
    default:
      return .stillUnknown(reason: "no reconcile evidence source for \(intent.action)")
    }
  }
}

// MARK: - ArkForge Flash adapter

package protocol RockchipRuntimeFactsPort: Sendable {
  func currentFacts(targetID: String) async throws -> ProviderFacts
}

package struct ArkForgeFlashProviderAdapter: DeviceProvider {
  public let providerID = CatalogProvider.arkforge.rawValue
  private let factsPort: (any RockchipRuntimeFactsPort)?
  private let availability: ProviderOperationAvailability

  public init(
    factsPort: (any RockchipRuntimeFactsPort)? = nil,
    availability: ProviderOperationAvailability = .unavailable(
      code: .providerToolUnavailable,
      reason: "production ArkForge Flash lane is not registered")
  ) {
    self.factsPort = factsPort
    self.availability = availability
  }

  package func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard ArkForgeFlashOperation.contains(operation.reference) else {
      return .unavailable(
        code: .operationNotSupported,
        reason: "ArkForge provider has no typed Flash plan for \(operation.reference)")
    }
    return availability
  }

  package func resolveFacts(targetID: String) async throws -> ProviderFacts {
    guard let factsPort else {
      throw DeviceProviderError.factsUnavailable(
        "production ArkForge target facts are not registered")
    }
    return try await factsPort.currentFacts(targetID: targetID)
  }

  package func executionAdmissionBlocker(
    for operation: CatalogOperationDescriptor,
    facts: ProviderFacts
  ) -> String? {
    guard ArkForgeFlashOperation.contains(operation.reference) else { return nil }
    guard
      facts.serverFacts[TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey]
        == TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied
    else {
      return "flash.crossModeBindingUnprepared: target \(facts.targetID ?? "unknown") "
        + "is not covered by the durable DAYU200 cross-mode binding"
    }
    guard
      let identity = facts.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey],
      identity.count == 64,
      identity.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      let connectKey = facts.executionConnectKey,
      !connectKey.isEmpty,
      SHA256Hex.string(of: Data(connectKey.utf8)) == identity,
      let topology = facts.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey],
      !topology.isEmpty,
      topology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      return "flash.postFlashHDCBindingUnprepared: target \(facts.targetID ?? "unknown") "
        + "has no trusted HDC identity and USB topology for postflight"
    }
    return nil
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    throw DeviceProviderError.unsupportedAction(
      "\(step.stepID) requires engine-resolved target and Artifact facts")
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard ArkForgeFlashOperation.contains(operation.reference) else {
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no ArkForge Flash action for \(operation.reference)")
    }
    let inputs = try ArkForgeFlashRequest.canonicalInputs(
      submittedReference: operation.reference, inputs: inputs)
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
    case ("flash-partitions", .flashPartition), ("verify-flash-readback", .verifyRemoteState):
      // These two steps no longer lower to an ArkDeck provider action: the
      // write and the readback are arkforged's, reached by StepPermit rather
      // than by this adapter (CHG-2026-059). Until the permit route is wired,
      // the honest answer is that this authority cannot dispatch them — not a
      // silently different action.
      throw DeviceProviderError.unsupportedAction(
        "\(step.stepID) is dispatched by arkforged under a StepPermit; ArkDeck no longer "
        + "lowers Rockchip writes or readbacks (CHG-2026-059)")
    case ("reboot-device", .rebootDevice):
      return .rockchip(.rebootToNormal(stableIdentitySHA256: identity))
    case ("wait-for-hdc", .waitForReconnect):
      return .rockchip(
        .waitForBoundHDCReconnect(
          expectation: try hdcReconnectExpectation(context: context, connectKey: connectKey)))
    case ("rebind-and-verify-build", .probeDevice):
      let bundle = try flashBundle(inputs: inputs, context: context)
      // The version to expect is the one baked into the system image this plan
      // wrote, read from that image — not a constant carried by the profile.
      // The archive's own name cannot be used and neither can its build log:
      // the 2026-07-28 daily is named 7.0.0.35 and its log says 7.0.0.35,
      // while the device it produces answers 7.0.0.36.
      // What the device must report is what the system image this plan wrote
      // declares. The Runtime read it when it resolved the bundle, because
      // reading bytes is its job and materializing a step is not the place to
      // open a 730 MB archive.
      guard let expectedBuildVersion = context.expectedRuntimeBuildVersion,
        !expectedBuildVersion.isEmpty
      else {
        throw DeviceProviderError.unsupportedAction(
          "post-flash verification has no declared build version for the resolved bundle")
      }
      _ = bundle
      return .rockchip(
        .verifyBoundBuild(
          expectation: try hdcReconnectExpectation(
            context: context, connectKey: connectKey),
          expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
          expectedBuildVersion: expectedBuildVersion))
    case ("capture-post-flash-diagnostics", .captureRemoteStdout):
      return .rockchip(
        .capturePostFlashDiagnostics(
          connectKey: connectKey,
          request: try HDCHilogCaptureRequest(
            durationSeconds: 30, filters: [], byteBudget: 16 * 1024 * 1024)))
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.stepID) has no registered Rockchip runtime action")
    }
  }

  package func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .rockchip(let rockchipAction) = action else {
      throw DeviceProviderError.unsupportedAction("non-Rockchip action given to rockchip provider")
    }
    guard let bindingRevision = context.bindingRevision,
      let connectKey = context.connectKey, !connectKey.isEmpty,
      let expectedIdentitySHA256 = context.expectedIdentitySHA256,
      let providerExecutableSHA256 = context.toolSHA256
    else {
      throw DeviceProviderError.factsUnavailable(
        "\(context.stepID) has no complete host-managed target/tool correlation")
    }
    return TypedProcessPlan(
      action: action,
      kind: .hostManaged(
        try RockchipHostManagedActionCatalog.descriptor(
          for: rockchipAction,
          jobID: context.jobID,
          stepID: context.stepID,
          targetID: context.targetID,
          bindingRevision: bindingRevision,
          connectKey: connectKey,
          expectedIdentitySHA256: expectedIdentitySHA256,
          providerExecutableSHA256: providerExecutableSHA256)))
  }

  private func hdcReconnectExpectation(
    context: ProviderExecutionContext,
    connectKey: String
  ) throws -> RockchipHDCReconnectExpectation {
    guard
      let identity = context.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey],
      identity.count == 64,
      identity.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      let topology = context.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey],
      !topology.isEmpty,
      topology.utf8.allSatisfy({ (48...57).contains($0) }),
      SHA256Hex.string(of: Data(connectKey.utf8)) == identity
    else {
      throw DeviceProviderError.factsUnavailable(
        "post-flash HDC binding expectation is absent or malformed")
    }
    return RockchipHDCReconnectExpectation(
      previousConnectKey: connectKey,
      previousIdentitySHA256: identity,
      usbTopology: topology)
  }

  package func verify(
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
    var summary = receipt.hostManagedSummary
    summary["recordId"] = recordID
    return .verified(summary: summary)
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

  package func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    let action: TypedProviderAction
    switch intent.action {
    case .rockchip(.enterLoader(let persistedConnectKey)):
      guard let connectKey = context.connectKey, !connectKey.isEmpty,
        connectKey == persistedConnectKey
      else {
        throw DeviceProviderError.factsUnavailable(
          "Loader transition recovery has no matching descriptor-bound HDC target")
      }
      // The original command's intended postcondition was Loader. Observe the
      // same connect-key identity directly in the normal USB personality;
      // this proof does not depend on an HDC server being present. Seeing that
      // exact negative postcondition lets the engine finalize the parked job
      // without ever replaying its reboot command.
      action = .rockchip(.observeHDCNormalUSB(connectKey: connectKey))
    // A parked Rockchip write used to recover by reading the partition back
    // here. That readback is a read-domain judgement, and it moved with the
    // write: ArkDeck can no longer prove what the device holds, so it must not
    // pretend to. Falling through to `nil` keeps the job unresolved, which is
    // the truth until arkforged reconciles it.
    case .rockchip(.rebootToNormal):
      guard let connectKey = context.connectKey, !connectKey.isEmpty else {
        throw DeviceProviderError.factsUnavailable(
          "normal-mode recovery has no descriptor-bound connect key")
      }
      action = .rockchip(
        .waitForBoundHDCReconnect(
          expectation: try hdcReconnectExpectation(
            context: context, connectKey: connectKey)))
    default:
      return nil
    }
    return try lower(action: action, context: context)
  }

  package func verifyReconciliationReadback(
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
      if case .rockchip(.enterLoader) = intent.action {
        return .confirmedNotExecuted
      }
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
    guard case .string(let profileReference)? = inputs["deviceProfileRef"],
      let profile = RockchipFlashProfile.profile(reference: profileReference)
    else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the published DAYU200 device profile")
    }
    guard case .string(let artifactLeaseID)? = inputs["artifactLease"],
      !artifactLeaseID.isEmpty
    else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the engine-resolved imageBundleLease")
    }
    guard inputs["intent"] == .string("fullRestore") else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires the closed fullRestore intent")
    }
    let partitions = profile.mappedPartitions.map(\.partitionName)
    guard let artifact = context.resolvedInputArtifact else {
      throw DeviceProviderError.unsupportedAction(
        "flash requires an engine-resolved image bundle")
    }
    // Whether the archive fits the board was decided at admission, which
    // derived it from these same leased bytes after proving they had not
    // drifted. Re-reading 730 MB while materializing each step would buy
    // nothing and would make materialization depend on I/O.
    return RockchipRuntimeFlashBundle(
      artifactLeaseID: artifactLeaseID,
      artifactID: artifact.artifactID,
      fileURL: artifact.fileURL,
      sha256: artifact.sha256,
      byteCount: artifact.byteCount,
      partitionNames: partitions)
  }
}
