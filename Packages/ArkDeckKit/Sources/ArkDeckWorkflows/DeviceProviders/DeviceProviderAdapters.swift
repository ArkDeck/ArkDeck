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

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    switch operation.reference {
    case "observe.device@1", "capture.diagnostics@1", "debug.hap@1":
      return .available
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
    case "componentTree":
      return .hdc(.captureUIDump(try HDCUIDumpRequest()))
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
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(
            ["shell", "hidumper", "-s", request.scope.rawValue], context: context),
          timeoutSeconds: 30))
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
            ["install", "-r", staged.path.remotePath], context: context),
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
            ["shell", "test", "-e", path.remotePath], context: context),
          timeoutSeconds: 15))
    case .readPortForwardPresence:
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: "resolved-at-dispatch",
          argumentSummary: try deviceArguments(["fport", "ls"], context: context),
          timeoutSeconds: 30))
    }
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
      guard !receipt.stdoutTruncated else {
        return .unknown(reason: "owned-path presence readback was truncated")
      }
      switch receipt.exitStatus {
      case 0:
        return .verified(summary: ["present": "true"])
      case 1:
        return .verified(summary: ["present": "false"])
      default:
        return .unknown(reason: "owned-path presence readback has no definite result")
      }
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
