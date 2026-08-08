import ArkDeckOpenHarmony
import Foundation

public enum TraceRuntimeParameterState: String, Codable, Sendable, Equatable {
  case missing
  case unreadable
  case value
}

public struct TraceRuntimeParameterObservation: Codable, Sendable, Equatable {
  public let name: String
  public let state: TraceRuntimeParameterState
  public let value: String?
  public let detail: String?

  public init(
    name: String,
    state: TraceRuntimeParameterState,
    value: String? = nil,
    detail: String? = nil
  ) {
    self.name = name
    self.state = state
    self.value = value
    self.detail = detail
  }
}

public enum TraceRuntimeToolDisposition: String, Codable, Sendable, Equatable {
  case captureEligible
  case probeOnly
  case unrecognized
  case probeFailed
}

public struct TraceRuntimeToolObservation: Codable, Sendable, Equatable {
  public let tool: String
  public let disposition: TraceRuntimeToolDisposition
  public let family: String?
  public let rawHelpSHA256: String?
  public let detail: String?

  public init(
    tool: String,
    disposition: TraceRuntimeToolDisposition,
    family: String? = nil,
    rawHelpSHA256: String? = nil,
    detail: String? = nil
  ) {
    self.tool = tool
    self.disposition = disposition
    self.family = family
    self.rawHelpSHA256 = rawHelpSHA256
    self.detail = detail
  }
}

public struct TraceRuntimeProbeSnapshot: Codable, Sendable, Equatable {
  public let targetID: String
  public let bindingRevision: Int
  public let adapterDisposition: String
  public let tool: String?
  public let family: String?
  public let supportedTags: [String]
  public let rawHelp: String?
  public let rawHelpSHA256: String?
  public let tools: [TraceRuntimeToolObservation]
  public let parameters: [TraceRuntimeParameterObservation]

  public init(
    targetID: String,
    bindingRevision: Int,
    adapterDisposition: String,
    tool: String?,
    family: String?,
    supportedTags: [String],
    rawHelp: String?,
    rawHelpSHA256: String?,
    tools: [TraceRuntimeToolObservation],
    parameters: [TraceRuntimeParameterObservation]
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.adapterDisposition = adapterDisposition
    self.tool = tool
    self.family = family
    self.supportedTags = supportedTags
    self.rawHelp = rawHelp
    self.rawHelpSHA256 = rawHelpSHA256
    self.tools = tools
    self.parameters = parameters
  }
}

/// Read-only target capability portrait. This never creates a mutation
/// capability and cannot be used as a substitute for Runtime admission.
public protocol TraceRuntimeProbing: Sendable {
  func probeTraceRuntime(targetID: String) async throws -> TraceRuntimeProbeSnapshot
}

package struct FoundationTraceRuntimeProbe: TraceRuntimeProbing {
  private let targetStore: RuntimeTargetStore
  private let hdcResolver: any RuntimeExecutableResolving
  private let runner: any RockchipRuntimeCommandRunning

  package init(
    targetStore: RuntimeTargetStore,
    hdcResolver: any RuntimeExecutableResolving,
    workingDirectory: URL
  ) {
    self.init(
      targetStore: targetStore,
      hdcResolver: hdcResolver,
      runner: FoundationRockchipRuntimeCommandRunner(workingDirectory: workingDirectory))
  }

  init(
    targetStore: RuntimeTargetStore,
    hdcResolver: any RuntimeExecutableResolving,
    runner: any RockchipRuntimeCommandRunning
  ) {
    self.targetStore = targetStore
    self.hdcResolver = hdcResolver
    self.runner = runner
  }

  package func probeTraceRuntime(
    targetID: String
  ) async throws -> TraceRuntimeProbeSnapshot {
    guard let target = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    var toolObservations: [TraceRuntimeToolObservation] = []
    var hitraceHelp: TraceProbeHelpEvaluation?
    for probeTool in [TraceProbeTool.hitrace, .bytrace] {
      do {
        let receipt = try await readAllowingNonZero(
          executable: hdc,
          arguments: deviceArguments(
            connectKey: target.connectKey,
            command: ["shell", probeTool.rawValue, "--help"]),
          byteBudget: 64 * 1024)
        let evaluation = TraceProbeAdapter.evaluateHelp(
          tool: probeTool, stdout: receipt.stdout, stderr: receipt.stderr)
        if probeTool == .hitrace { hitraceHelp = evaluation }
        let toolDisposition: TraceRuntimeToolDisposition
        let selectedFamily: String?
        switch evaluation.selection {
        case .captureEligible(_, let family):
          toolDisposition = .captureEligible
          selectedFamily = family
        case .probeOnlyNotCaptureEligible(_, let family):
          toolDisposition = .probeOnly
          selectedFamily = family
        case .unsupported:
          toolDisposition = .unrecognized
          selectedFamily = nil
        }
        toolObservations.append(
          TraceRuntimeToolObservation(
            tool: probeTool.rawValue,
            disposition: toolDisposition,
            family: selectedFamily,
            rawHelpSHA256: evaluation.rawHelpSHA256,
            detail: receipt.exitStatus == 0 ? nil : "probe exited non-zero"))
      } catch {
        toolObservations.append(
          TraceRuntimeToolObservation(
            tool: probeTool.rawValue,
            disposition: .probeFailed,
            detail: "read-only probe could not complete"))
      }
    }

    var disposition = "unsupported"
    var tool: String?
    var family: String?
    var tags: [String] = []
    if let hitraceHelp,
      case .captureEligible(let selectedTool, let selectedFamily) = hitraceHelp.selection
    {
      let tagReceipt = try await read(
        executable: hdc,
        arguments: deviceArguments(
          connectKey: target.connectKey, command: ["shell", "hitrace", "-l"]),
        byteBudget: 64 * 1024)
      let tagList = TraceProbeAdapter.evaluateTagList(
        tool: .hitrace, stdout: tagReceipt.stdout, stderr: tagReceipt.stderr)
      if case .captureEligible(let tagTool, let tagFamily) = tagList.selection,
        tagTool == selectedTool, tagFamily == selectedFamily
      {
        disposition = "captureEligible"
        tool = selectedTool.rawValue
        family = selectedFamily
        tags = tagList.tags
      }
    }

    var parameters: [TraceRuntimeParameterObservation] = []
    for definition in TraceDebugParameterCatalog.definitions {
      do {
        let receipt = try await read(
          executable: hdc,
          arguments: deviceArguments(
            connectKey: target.connectKey,
            command: ["shell", "param", "get", definition.name]),
          byteBudget: 4 * 1024)
        parameters.append(Self.parameterObservation(definition.name, receipt: receipt))
      } catch {
        parameters.append(
          TraceRuntimeParameterObservation(
            name: definition.name, state: .unreadable,
            detail: String(describing: error)))
      }
    }

    return TraceRuntimeProbeSnapshot(
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      adapterDisposition: disposition,
      tool: tool,
      family: family,
      supportedTags: tags,
      rawHelp: hitraceHelp.flatMap { String(data: $0.rawHelp, encoding: .utf8) },
      rawHelpSHA256: hitraceHelp?.rawHelpSHA256,
      tools: toolObservations,
      parameters: parameters)
  }

  private func deviceArguments(connectKey: String, command: [String]) -> [String] {
    ["-t", connectKey] + command
  }

  private func read(
    executable: ResolvedExecutable,
    arguments: [String],
    byteBudget: Int
  ) async throws -> ProviderSubprocessReceipt {
    let receipt = try await runner.run(
      executable: executable, arguments: arguments,
      timeoutSeconds: 15, outputByteBudget: byteBudget,
      criticalNonInterruptible: false)
    try HDCReadOnlyProbeReceiptValidation.requireNoSemanticFailure(
      receipt, context: "read-only HDC probe failed")
    guard receipt.exitStatus == 0 else {
      throw DeviceProviderError.factsUnavailable(
        "read-only HDC probe exited \(receipt.exitStatus.map(String.init) ?? "unknown")")
    }
    guard !receipt.stdoutTruncated else {
      throw DeviceProviderError.factsUnavailable("read-only HDC probe output was truncated")
    }
    return receipt
  }

  private func readAllowingNonZero(
    executable: ResolvedExecutable,
    arguments: [String],
    byteBudget: Int
  ) async throws -> ProviderSubprocessReceipt {
    let receipt = try await runner.run(
      executable: executable, arguments: arguments,
      timeoutSeconds: 15, outputByteBudget: byteBudget,
      criticalNonInterruptible: false)
    try HDCReadOnlyProbeReceiptValidation.requireNoSemanticFailure(
      receipt, context: "read-only HDC help probe failed")
    guard !receipt.stdoutTruncated else {
      throw DeviceProviderError.factsUnavailable("read-only HDC probe output was truncated")
    }
    return receipt
  }

  private static func parameterObservation(
    _ name: String,
    receipt: ProviderSubprocessReceipt
  ) -> TraceRuntimeParameterObservation {
    guard let text = String(data: receipt.stdout, encoding: .utf8) else {
      return TraceRuntimeParameterObservation(
        name: name, state: .unreadable, detail: "parameter output is not UTF-8")
    }
    let value = HDCObservationProviderAdapter.propertyValue(
      fromParamGetOutput: text, requestedKey: name)
    guard !value.isEmpty else {
      return TraceRuntimeParameterObservation(name: name, state: .missing)
    }
    guard value.utf8.count <= 400 else {
      return TraceRuntimeParameterObservation(
        name: name, state: .unreadable, detail: "parameter value is oversized")
    }
    return TraceRuntimeParameterObservation(name: name, state: .value, value: value)
  }
}
