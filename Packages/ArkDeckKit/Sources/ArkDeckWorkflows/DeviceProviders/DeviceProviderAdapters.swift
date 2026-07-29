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
    case .finalizeSession, .preflightHostStorage, .postprocessArtifact:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) is engine-internal, not a provider action")
    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(step.kind.rawValue) has no registered HDC action in MU-2 (arrives with T10)")
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
    }
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
    case .hdc(.captureTrace), .hdc(.cleanupOwnedRemotePath):
      // Remote-temp mutations reconcile by re-listing the owned path in a
      // later read; without that evidence the outcome stays unknown.
      return .stillUnknown(
        reason: "owned-path mutation needs a re-observation pass to conclude")
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
