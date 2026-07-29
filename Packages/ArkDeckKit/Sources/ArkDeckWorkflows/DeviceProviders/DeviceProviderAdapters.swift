// Provider adapters over the existing execution stacks (CHG-2026-047, T05).
//
// Compat-first: neither adapter builds a second state machine. The HDC
// adapter composes the existing observation surfaces behind injected
// ports (the production composition arrives with the MU-3 walking
// skeleton); the Rockchip adapter wraps RockchipFlashExecutionHost whole,
// keeping its proven journal/manifest/recovery semantics authoritative.

import ArkDeckCore
import ArkDeckOpenHarmony
import Foundation

// MARK: - HDC observation adapter

/// Ports the HDC adapter needs. Kept minimal and injectable so contract
/// tests drive the adapter without a real tool; MU-3 supplies the
/// production composition (discovery + supervisor + registered probes).
public protocol HDCObservationFactsPort: Sendable {
  func currentFacts(targetID: String) async throws -> ProviderFacts
}

public struct HDCObservationProviderAdapter: DeviceProvider {
  public let providerID = "hdc"
  private let factsPort: any HDCObservationFactsPort
  private let profile: HDCCompatibilityProfile

  public init(
    factsPort: any HDCObservationFactsPort,
    profile: HDCCompatibilityProfile = .openHarmony320Family
  ) {
    self.factsPort = factsPort
    self.profile = profile
  }

  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
    try await factsPort.currentFacts(targetID: targetID)
  }

  public func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    switch step.kind {
    case .probeHostTool:
      return .hdc(.observeTool)
    case .probeHDCServer:
      return .hdc(.observeServer)
    case .probeDevice:
      return .hdc(.observeDevice(connectKey: "resolved-by-binding"))
    case .sendFile, .installPackage, .startApplication, .stopApplication, .uninstallPackage:
      return try debugHAPAction(for: step, inputs: inputs)
    case .runApprovedRemoteRead, .verifyRemoteState:
      // Shared by debug.hap readbacks and future deploy verification;
      // routed by operation so a step kind never means two things at once.
      guard descriptorIsDebugHAP(operation) else {
        throw DeviceProviderError.unsupportedStepKind(
          "\(step.kind.rawValue) has no registered action for \(operation.reference)")
      }
      return try debugHAPAction(for: step, inputs: inputs)
    case .preflightDeviceStorage:
      // Device-side preflight for capture: an allowlisted read, not a
      // generic shell probe.
      return .hdc(.queryProperty(.productModel))
    case .captureRemoteStdout:
      return try captureAction(for: step, inputs: inputs)
    case .captureRemoteFile:
      return .hdc(
        .captureTrace(
          try traceRequest(from: inputs),
          into: mintOwnedRemotePath(jobID: "job", stepID: step.stepID)))
    case .receiveFile:
      return .hdc(
        .receiveOwnedArtifact(
          HDCOwnedRemoteArtifact(
            path: mintOwnedRemotePath(jobID: "job", stepID: step.stepID),
            expectedSHA256: nil, maximumBytes: 64 * 1024 * 1024)))
    case .cleanupOwnedRemotePath:
      return .hdc(
        .cleanupOwnedRemotePath(mintOwnedRemotePath(jobID: "job", stepID: step.stepID)))
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

  /// capture.diagnostics@1 and debug.hap@1 both capture stdout; the step
  /// id says which product is being gathered.
  private func captureAction(
    for step: CatalogStepDescriptor, inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    switch step.stepID {
    case "capture-ui-dump":
      return .hdc(.captureUIDump(try HDCUIDumpRequest()))
    default:
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
    for step: CatalogStepDescriptor, inputs: [String: JSONValue]
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
          mintStagedArtifact(
            jobID: "job", stepID: step.stepID, artifactLeaseID: lease, expectedSHA256: nil)))
    case .installPackage:
      guard case .string(let lease)? = inputs["hapArtifactLease"] else {
        throw DeviceProviderError.unsupportedAction("hapArtifactLease input is required")
      }
      return .hdc(
        .installPackage(
          mintStagedArtifact(
            jobID: "job", stepID: step.stepID, artifactLeaseID: lease, expectedSHA256: nil),
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

  public func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .hdc(let hdcAction) = action else {
      throw DeviceProviderError.unsupportedAction("non-HDC action given to hdc provider")
    }
    // The concrete argv/executable stays provider-internal. MU-2 exposes
    // only the audited summary; the dispatch integration that binds the
    // real descriptor arrives with the MU-3 production composition.
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
          argumentSummary: ["shell", "param", "get", property.rawValue], timeoutSeconds: 15))
    case .captureHilog(let request):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "hilog", "-x"] + request.filters,
          timeoutSeconds: request.durationSeconds + 15))
    case .captureUIDump(let request):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "hidumper", "-s", request.scope.rawValue],
          timeoutSeconds: 30))
    case .captureTrace(let request, let path):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "hitrace", "-t", String(request.durationSeconds), "-b",
            String(request.bufferKB)] + request.categories + ["-o", path.remotePath],
          timeoutSeconds: request.durationSeconds + 30))
    case .receiveOwnedArtifact(let artifact):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["file", "recv", artifact.path.remotePath], timeoutSeconds: 60))
    case .cleanupOwnedRemotePath(let path):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "rm", "-f", path.remotePath], timeoutSeconds: 15))
    case .sendArtifactToStaging(let staged):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["file", "send", "<artifact-lease>", staged.path.remotePath],
          timeoutSeconds: 300))
    case .installPackage(let staged, _):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["install", staged.path.remotePath], timeoutSeconds: 300))
    case .queryPackageReadback(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "bm", "dump", "-n", bundle.bundleName],
          timeoutSeconds: 30))
    case .startAbility(let ability):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: [
            "shell", "aa", "start", "-b", ability.bundle.bundleName, "-a", ability.abilityName,
          ], timeoutSeconds: 60))
    case .verifyProcessState(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "pidof", bundle.bundleName], timeoutSeconds: 30))
    case .stopAbility(let ability):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["shell", "aa", "force-stop", ability.bundle.bundleName],
          timeoutSeconds: 60))
    case .uninstallPackage(let bundle):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["uninstall", bundle.bundleName], timeoutSeconds: 120))
    case .createPortForward(let spec):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["fport", "tcp:\(spec.localPort)", "tcp:\(spec.remotePort)"],
          timeoutSeconds: 30))
    case .removePortForward(let spec):
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: ["fport", "rm", "tcp:\(spec.localPort)"], timeoutSeconds: 30))
    }
  }

  /// Mints a provider-owned staging path for an artifact lease. As with
  /// remote temp paths, the caller never supplies a device location.
  public func mintStagedArtifact(
    jobID: String, stepID: String, artifactLeaseID: String, expectedSHA256: String?
  ) -> HDCStagedArtifact {
    HDCStagedArtifact(
      path: mintOwnedRemotePath(jobID: jobID, stepID: stepID),
      artifactLeaseID: artifactLeaseID, expectedSHA256: expectedSHA256)
  }

  /// Mints a provider-owned remote temp path bound to job/step. The only
  /// construction point outside tests; callers cannot supply device paths.
  public func mintOwnedRemotePath(jobID: String, stepID: String) -> HDCOwnedRemotePath {
    HDCOwnedRemotePath(
      jobID: jobID, stepID: stepID, nonce: UUID().uuidString.prefix(8).lowercased())
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
    case .listDeviceCandidates, .observeDevice:
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
    case .queryProperty:
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "property output exceeded budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "property output is not UTF-8")
      }
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value.count <= 400 else {
        return .unknown(reason: "property value empty or oversized")
      }
      return .verified(summary: ["value": value])
    case .captureHilog, .captureUIDump:
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "capture exceeded its byte budget")
      }
      guard String(data: receipt.stdout, encoding: .utf8) != nil else {
        return .failed(code: "invalidEncoding", detail: "capture output is not UTF-8")
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

    case .installPackage:
      // Deliberately never `.verified`: an install is only as true as its
      // readback, and hardware has shown `hdc install` exiting zero
      // without installing. The orchestration requires the paired
      // queryPackageReadback step to decide.
      guard receipt.exitStatus != nil else {
        return .unknown(reason: "install produced no process result")
      }
      return .unknown(reason: "install requires package readback before it can be believed")

    case .queryPackageReadback(let bundle):
      guard !receipt.stdoutTruncated else {
        return .failed(code: "truncated", detail: "package readback exceeded its budget")
      }
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "package readback is not UTF-8")
      }
      let installed = text.contains(bundle.bundleName)
      guard installed else {
        return .failed(
          code: "packageNotInstalled",
          detail: "readback does not list \(bundle.bundleName)")
      }
      return .verified(summary: ["bundleName": bundle.bundleName, "installed": "true"])

    case .startAbility:
      guard receipt.exitStatus != nil else {
        return .unknown(reason: "start produced no process result")
      }
      return .unknown(reason: "start requires process readback before it can be believed")

    case .verifyProcessState(let bundle):
      guard let text = String(data: receipt.stdout, encoding: .utf8) else {
        return .failed(code: "invalidEncoding", detail: "process readback is not UTF-8")
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .decimalDigits) != nil else {
        return .failed(
          code: "processNotRunning", detail: "no live process for \(bundle.bundleName)")
      }
      return .verified(summary: ["bundleName": bundle.bundleName, "running": "true"])

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
    }
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
      .hdc(.observeDevice), .hdc(.queryProperty), .hdc(.captureHilog),
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
      .hdc(.removePortForward):
      // Device mutations need positive readback evidence to conclude; a
      // reconcile pass that has none must stay unknown rather than guess.
      return .stillUnknown(
        reason: "device mutation needs a readback pass before it can be concluded")
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
