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
  private enum ParameterReadOutcome: Sendable {
    case missing
    case receipt(ProviderSubprocessReceipt)
  }

  private struct ToolHelpObservation: Sendable {
    let presentation: TraceRuntimeToolObservation
    let evaluation: TraceProbeHelpEvaluation?
  }

  private struct ToolObservations: Sendable {
    let disposition: String
    let tool: String?
    let family: String?
    let tags: [String]
    let rawHelp: String?
    let rawHelpSHA256: String?
    let presentations: [TraceRuntimeToolObservation]
  }

  private struct IndexedParameterObservation: Sendable {
    let index: Int
    let presentation: TraceRuntimeParameterObservation
  }

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
    guard let route = try targetStore.hdcExecutionRoute(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    // These reads share only an immutable target route and executable
    // identity. HDC supports concurrent clients, so tool capability reads and
    // the bounded parameter catalog must not form a serial startup chain.
    // Each result is reassembled in catalog order below.
    async let tools = probeTools(executable: hdc, connectKey: route.connectKey)
    async let parameters = probeParameters(executable: hdc, connectKey: route.connectKey)
    let toolObservations = try await tools
    let parameterObservations = await parameters

    return TraceRuntimeProbeSnapshot(
      targetID: route.targetID,
      bindingRevision: route.bindingRevision,
      adapterDisposition: toolObservations.disposition,
      tool: toolObservations.tool,
      family: toolObservations.family,
      supportedTags: toolObservations.tags,
      rawHelp: toolObservations.rawHelp,
      rawHelpSHA256: toolObservations.rawHelpSHA256,
      tools: toolObservations.presentations,
      parameters: parameterObservations)
  }

  private func probeTools(
    executable: ResolvedExecutable,
    connectKey: String
  ) async throws -> ToolObservations {
    async let hitrace = probeHelp(
      tool: .hitrace, executable: executable, connectKey: connectKey)
    async let bytrace = probeHelp(
      tool: .bytrace, executable: executable, connectKey: connectKey)
    let (hitraceObservation, bytraceObservation) = await (hitrace, bytrace)

    var disposition = "unsupported"
    var selectedTool: String?
    var selectedFamily: String?
    var tags: [String] = []
    if let hitraceHelp = hitraceObservation.evaluation,
      case .captureEligible(let tool, let family) = hitraceHelp.selection
    {
      let tagReceipt = try await read(
        executable: executable,
        arguments: deviceArguments(
          connectKey: connectKey, command: ["shell", "hitrace", "-l"]),
        byteBudget: 64 * 1024)
      let tagList = TraceProbeAdapter.evaluateTagList(
        tool: .hitrace, stdout: tagReceipt.stdout, stderr: tagReceipt.stderr)
      if case .captureEligible(let tagTool, let tagFamily) = tagList.selection,
        tagTool == tool, tagFamily == family
      {
        disposition = "captureEligible"
        selectedTool = tool.rawValue
        selectedFamily = family
        tags = tagList.tags
      }
    }

    let hitraceHelp = hitraceObservation.evaluation
    return ToolObservations(
      disposition: disposition,
      tool: selectedTool,
      family: selectedFamily,
      tags: tags,
      rawHelp: hitraceHelp.flatMap { String(data: $0.rawHelp, encoding: .utf8) },
      rawHelpSHA256: hitraceHelp?.rawHelpSHA256,
      presentations: [hitraceObservation.presentation, bytraceObservation.presentation])
  }

  private func probeHelp(
    tool: TraceProbeTool,
    executable: ResolvedExecutable,
    connectKey: String
  ) async -> ToolHelpObservation {
    do {
      let receipt = try await readAllowingNonZero(
        executable: executable,
        arguments: deviceArguments(
          connectKey: connectKey,
          command: ["shell", tool.rawValue, "--help"]),
        byteBudget: 64 * 1024)
      let evaluation = TraceProbeAdapter.evaluateHelp(
        tool: tool, stdout: receipt.stdout, stderr: receipt.stderr)
      let disposition: TraceRuntimeToolDisposition
      let family: String?
      switch evaluation.selection {
      case .captureEligible(_, let selectedFamily):
        disposition = .captureEligible
        family = selectedFamily
      case .probeOnlyNotCaptureEligible(_, let selectedFamily):
        disposition = .probeOnly
        family = selectedFamily
      case .unsupported:
        disposition = .unrecognized
        family = nil
      }
      return ToolHelpObservation(
        presentation: TraceRuntimeToolObservation(
          tool: tool.rawValue,
          disposition: disposition,
          family: family,
          rawHelpSHA256: evaluation.rawHelpSHA256,
          detail: receipt.exitStatus == 0 ? nil : "probe exited non-zero"),
        evaluation: evaluation)
    } catch {
      return ToolHelpObservation(
        presentation: TraceRuntimeToolObservation(
          tool: tool.rawValue,
          disposition: .probeFailed,
          detail: "read-only probe could not complete"),
        evaluation: nil)
    }
  }

  private func probeParameters(
    executable: ResolvedExecutable,
    connectKey: String
  ) async -> [TraceRuntimeParameterObservation] {
    await withTaskGroup(of: IndexedParameterObservation.self) { group in
      for (index, definition) in TraceDebugParameterCatalog.definitions.enumerated() {
        group.addTask {
          let presentation: TraceRuntimeParameterObservation
          do {
            let outcome = try await readParameter(
              executable: executable,
              arguments: deviceArguments(
                connectKey: connectKey,
                command: ["shell", "param", "get", definition.name]),
              name: definition.name)
            switch outcome {
            case .missing:
              presentation = TraceRuntimeParameterObservation(
                name: definition.name, state: .missing)
            case .receipt(let receipt):
              presentation = Self.parameterObservation(
                definition.name, receipt: receipt)
            }
          } catch {
            presentation = TraceRuntimeParameterObservation(
              name: definition.name, state: .unreadable,
              detail: String(describing: error))
          }
          return IndexedParameterObservation(index: index, presentation: presentation)
        }
      }
      var observations: [IndexedParameterObservation] = []
      for await observation in group { observations.append(observation) }
      return observations.sorted { $0.index < $1.index }.map(\.presentation)
    }
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

  private func readParameter(
    executable: ResolvedExecutable,
    arguments: [String],
    name: String
  ) async throws -> ParameterReadOutcome {
    let receipt = try await runner.run(
      executable: executable, arguments: arguments,
      timeoutSeconds: 15, outputByteBudget: 4 * 1024,
      criticalNonInterruptible: false)
    guard !receipt.stdoutTruncated else {
      throw DeviceProviderError.factsUnavailable("read-only HDC probe output was truncated")
    }
    if Self.isExactMissingParameterReceipt(receipt, requestedName: name) {
      return .missing
    }
    try HDCReadOnlyProbeReceiptValidation.requireNoSemanticFailure(
      receipt, context: "read-only HDC probe failed")
    guard receipt.exitStatus == 0 else {
      throw DeviceProviderError.factsUnavailable(
        "read-only HDC probe exited \(receipt.exitStatus.map(String.init) ?? "unknown")")
    }
    return .receipt(receipt)
  }

  private static func isExactMissingParameterReceipt(
    _ receipt: ProviderSubprocessReceipt,
    requestedName: String
  ) -> Bool {
    // OpenHarmony's `param get` reports an absent key as a zero-exit semantic
    // failure. Promote only the exact, target-bound 106 form for the key this
    // catalog probe requested; every noisy or mismatched form stays unreadable.
    guard receipt.exitStatus == 0, receipt.stderr.isEmpty,
      let stdout = String(data: receipt.stdout, encoding: .utf8)
    else {
      return false
    }
    let expected = "Get parameter \"\(requestedName)\" fail! errNum is:106!"
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected
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
    guard !receipt.stdoutTruncated else {
      throw DeviceProviderError.factsUnavailable("read-only HDC probe output was truncated")
    }
    // Help is not an operation-success receipt. It can legitimately contain
    // words such as `ErrorCode` while documenting failure output, so the
    // generic HDC semantic parser would classify the documentation itself as
    // a failed command. The exact TraceProbeAdapter byte family below remains
    // the authority gate: a real [Fail]/offline/unknown response is retained
    // for diagnosis and evaluates unsupported, never captureEligible.
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
