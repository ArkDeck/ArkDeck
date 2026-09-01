// App-facing Trace projection over Runtime's closed typed XPC door.
//
// capture.diagnostics@1 publishes a typed traceCategories leg, but the App
// read surface does not currently return the per-target hitrace/bytrace probe,
// raw help, parameter snapshots or mutation receipts required by the accepted
// Trace contract. This facade exposes that gap alongside exact Catalog facts;
// Submission is limited to capture.diagnostics@1 and a target/binding pair
// obtained from Runtime. It has no parameter-write or arbitrary command path.

import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckRuntime
import Foundation
import os

public enum TraceApplicationAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct TraceOperationPresentation: Sendable, Equatable {
  public let reference: String
  public let title: String
  public let availability: TraceApplicationAvailability
  public let minimumEffect: String
  public let permittedEffects: [String]
  public let durationSecondsRange: ClosedRange<Int>?
  public let traceBufferKBRange: ClosedRange<Int>?
  public let maximumTraceTagCount: Int?
  public let traceStepCancellation: String?
  public let artifactNames: [String]
  public let supportsTypedTraceCategories: Bool
  public let supportsRawTraceArtifact: Bool
  public let supportsFilteredTraceArtifact: Bool
  public let supportsCaptureLogArtifact: Bool
  public let exposesAdapterCapabilityFacts: Bool
  public let exposesParameterSnapshotFacts: Bool

  public init(
    reference: String,
    title: String,
    availability: TraceApplicationAvailability,
    minimumEffect: String,
    permittedEffects: [String],
    durationSecondsRange: ClosedRange<Int>?,
    traceBufferKBRange: ClosedRange<Int>?,
    maximumTraceTagCount: Int?,
    traceStepCancellation: String?,
    artifactNames: [String],
    supportsTypedTraceCategories: Bool,
    supportsRawTraceArtifact: Bool,
    supportsFilteredTraceArtifact: Bool,
    supportsCaptureLogArtifact: Bool,
    exposesAdapterCapabilityFacts: Bool,
    exposesParameterSnapshotFacts: Bool
  ) {
    self.reference = reference
    self.title = title
    self.availability = availability
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.durationSecondsRange = durationSecondsRange
    self.traceBufferKBRange = traceBufferKBRange
    self.maximumTraceTagCount = maximumTraceTagCount
    self.traceStepCancellation = traceStepCancellation
    self.artifactNames = artifactNames
    self.supportsTypedTraceCategories = supportsTypedTraceCategories
    self.supportsRawTraceArtifact = supportsRawTraceArtifact
    self.supportsFilteredTraceArtifact = supportsFilteredTraceArtifact
    self.supportsCaptureLogArtifact = supportsCaptureLogArtifact
    self.exposesAdapterCapabilityFacts = exposesAdapterCapabilityFacts
    self.exposesParameterSnapshotFacts = exposesParameterSnapshotFacts
  }
}

public struct TraceTargetPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let bindingRevision: Int
  public let toolVersion: String
  public let adoptedAtUTC: String
  public let deviceName: String?
  public let systemVersion: String?
  public let connectKey: String?
  public let transport: String?

  public init(
    id: String,
    bindingRevision: Int,
    toolVersion: String,
    adoptedAtUTC: String,
    deviceName: String? = nil,
    systemVersion: String? = nil,
    connectKey: String? = nil,
    transport: String? = nil
  ) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
    self.deviceName = deviceName
    self.systemVersion = systemVersion
    self.connectKey = connectKey
    self.transport = transport
  }

  public var connectionSummary: String? {
    let values = [
      Self.nonempty(systemVersion),
      Self.nonempty(connectKey).map(Self.abbreviatedIdentifier),
      Self.nonempty(transport)?.uppercased(),
    ].compactMap { $0 }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }

  public var accessibleConnectionSummary: String? {
    let values = [
      Self.nonempty(systemVersion),
      Self.nonempty(connectKey),
      Self.nonempty(transport)?.uppercased(),
    ].compactMap { $0 }
    return values.isEmpty ? nil : values.joined(separator: ", ")
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func abbreviatedIdentifier(_ value: String) -> String {
    guard value.count > 10 else { return value }
    return "\(value.prefix(4))…\(value.suffix(5))"
  }
}

/// job.list does not expose the original input map. A diagnostics job can be
/// related to this workspace, but the App must not claim its optional Trace
/// leg was selected.
public struct TraceRelatedJobPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let outstandingResidueCount: Int
  public let traceLegSelectionKnown: Bool

  public var needsAttention: Bool {
    waitingForHuman || outcomeUnknown || outstandingResidueCount > 0
  }

  public init(
    id: String,
    targetID: String,
    state: String,
    waitingForHuman: Bool,
    outcomeUnknown: Bool,
    outstandingResidueCount: Int,
    traceLegSelectionKnown: Bool = false
  ) {
    self.id = id
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
    self.traceLegSelectionKnown = traceLegSelectionKnown
  }
}

public struct TraceWorkspacePresentation: Sendable, Equatable {
  public let operation: TraceOperationPresentation
  public let targets: [TraceTargetPresentation]
  public let relatedDiagnosticsJobs: [TraceRelatedJobPresentation]
  public let targetLoadFailure: String?
  public let jobLoadFailure: String?
  public let runtimeProbe: TraceRuntimeProbeSnapshot?
  public let probeFailure: String?

  public init(
    operation: TraceOperationPresentation,
    targets: [TraceTargetPresentation],
    relatedDiagnosticsJobs: [TraceRelatedJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil,
    runtimeProbe: TraceRuntimeProbeSnapshot? = nil,
    probeFailure: String? = nil
  ) {
    self.operation = operation
    self.targets = targets
    self.relatedDiagnosticsJobs = relatedDiagnosticsJobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
    self.runtimeProbe = runtimeProbe
    self.probeFailure = probeFailure
  }

  public static let loading = TraceWorkspacePresentation(
    operation: TraceApplicationFacade.operationPresentation(availability: .checking),
    targets: [],
    relatedDiagnosticsJobs: [])
}

public enum TraceNumericInputFailure: Sendable, Equatable {
  case missing
  case notDecimal
  case outsideRange(ClosedRange<Int>)
}

public enum TraceNumericInputValidation: Sendable, Equatable {
  case valid(Int)
  case invalid(TraceNumericInputFailure)
}

/// App-facing entry units for the duration field. Runtime requests remain
/// canonical seconds so the presentation choice cannot change the published
/// `capture.diagnostics@1` input contract.
public enum TraceDurationInputUnit: String, CaseIterable, Sendable, Identifiable {
  case seconds
  case minutes

  public var id: Self { self }

  public var quickValues: [Int] {
    switch self {
    case .seconds: [5, 10, 15, 30]
    case .minutes: [1, 2, 3]
    }
  }

  public func inputRange(
    forDurationSecondsRange secondsRange: ClosedRange<Int>
  ) -> ClosedRange<Int>? {
    switch self {
    case .seconds:
      return secondsRange
    case .minutes:
      guard secondsRange.lowerBound > 0 else { return nil }
      let lower = secondsRange.lowerBound / 60
        + (secondsRange.lowerBound.isMultiple(of: 60) ? 0 : 1)
      let upper = secondsRange.upperBound / 60
      guard lower <= upper else { return nil }
      return lower...upper
    }
  }

  public func durationSeconds(
    for inputValue: Int,
    allowedRange secondsRange: ClosedRange<Int>
  ) -> Int? {
    guard inputRange(forDurationSecondsRange: secondsRange)?.contains(inputValue) == true else {
      return nil
    }
    let multiplier = self == .seconds ? 1 : 60
    let (seconds, overflow) = inputValue.multipliedReportingOverflow(by: multiplier)
    guard !overflow, secondsRange.contains(seconds) else { return nil }
    return seconds
  }

  /// Unit changes preserve the current duration where possible. Minutes round
  /// up, so changing presentation units never silently shortens a capture.
  public func inputValue(
    forDurationSeconds seconds: Int,
    allowedRange secondsRange: ClosedRange<Int>
  ) -> Int? {
    guard let range = inputRange(forDurationSecondsRange: secondsRange) else { return nil }
    let boundedSeconds = min(secondsRange.upperBound, max(secondsRange.lowerBound, seconds))
    let value = switch self {
    case .seconds: boundedSeconds
    case .minutes:
      boundedSeconds / 60 + (boundedSeconds.isMultiple(of: 60) ? 0 : 1)
    }
    guard range.contains(value) else { return nil }
    return value
  }
}

public struct TraceJobAcceptancePresentation: Sendable, Equatable {
  public let jobID: String

  public init(jobID: String) { self.jobID = jobID }
}

public enum TraceJobSubmissionResult: Sendable, Equatable {
  case submitted(TraceJobAcceptancePresentation)
  case failed(String)
}

public struct TraceJobTerminalPresentation: Sendable, Equatable {
  public let jobID: String
  public let state: String
  public let outcomeUnknown: Bool
  public let timeline: [String]

  public init(jobID: String, state: String, outcomeUnknown: Bool, timeline: [String]) {
    self.jobID = jobID
    self.state = state
    self.outcomeUnknown = outcomeUnknown
    self.timeline = timeline
  }
}

public enum TraceJobRunResult: Sendable, Equatable {
  case completed(TraceJobTerminalPresentation)
  case failed(String)
}

/// Fail-closed policy for handing one Runtime Artifact to the local Trace
/// parser. Selection is intentionally exact and unique: a second plausible
/// row is ambiguity, not a tie to resolve with ordering or timestamps.
public enum TracePublishedArtifactPolicy {
  public static func selectRawTrace(
    from artifacts: [RuntimeArtifactPresentation],
    operationReference: String = TraceApplicationFacade.operationReference
  ) -> RuntimeArtifactPresentation? {
    let candidates = artifacts.filter { artifact in
      artifact.name == "trace.htrace"
        && artifact.role == "raw"
        && artifact.mediaType == "application/octet-stream"
        && artifact.privacy == "sensitive"
        && artifact.status == "published"
        && artifact.sourceOperation == operationReference
        && artifact.byteCount > 0
        && isSHA256(artifact.sha256)
    }
    guard candidates.count == 1 else { return nil }
    return candidates[0]
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
      (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }
  }
}

public enum TraceNumericInputValidator {
  public static func validate(
    _ value: String,
    range: ClosedRange<Int>
  ) -> TraceNumericInputValidation {
    guard !value.isEmpty else { return .invalid(.missing) }
    guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(value) else {
      return .invalid(.notDecimal)
    }
    guard range.contains(parsed) else { return .invalid(.outsideRange(range)) }
    return .valid(parsed)
  }
}

public protocol TraceApplicationProviding: Sendable {
  func refreshWorkspace(targetID: String?) async -> TraceWorkspacePresentation
  func submitCapture(
    target: TraceTargetPresentation,
    durationSeconds: Int,
    tags: [String],
    bufferKB: Int
  ) async -> TraceJobSubmissionResult
  func run(jobID: String) async -> TraceJobRunResult
  func cancel(jobID: String) async -> Bool
}

public enum TraceApplicationFacade {
  public static let operationReference = "capture.diagnostics@1"

  private static let descriptor = RuntimeOperationCatalog.descriptor(
    reference: operationReference)!

  public static func make() -> any TraceApplicationProviding {
    TraceProductionApplicationProvider()
  }

  /// Joins durable Runtime target facts with ArkDeck's one current device
  /// observation. The App never probes HDC from the Trace workspace: model,
  /// firmware, route identifier and transport all come from the same shared
  /// projection used by the Devices and UI Dump surfaces.
  public static func rejoin(
    targets: [TraceTargetPresentation],
    with observation: DeviceListPresentation
  ) -> [TraceTargetPresentation] {
    guard case .available = observation.availability else { return targets }
    let candidates = Dictionary(grouping: observation.candidates) { $0.adoptedTargetID }
    return targets.map { target in
      let matches = candidates[target.id, default: []].filter {
        $0.bindingRevision == target.bindingRevision
      }
      guard matches.count == 1, let candidate = matches.first else { return target }
      return TraceTargetPresentation(
        id: target.id,
        bindingRevision: target.bindingRevision,
        toolVersion: target.toolVersion,
        adoptedAtUTC: target.adoptedAtUTC,
        deviceName: candidate.deviceInformation?.name ?? candidate.observedFacts?.model,
        systemVersion: candidate.deviceInformation?.systemVersion
          ?? candidate.observedFacts?.firmware,
        connectKey: candidate.connectKey,
        transport: candidate.deviceInformation?.transport ?? candidate.observedFacts?.transport)
    }
  }

  static func operationPresentation(
    availability: TraceApplicationAvailability
  ) -> TraceOperationPresentation {
    let duration = descriptor.inputs.first { $0.name == "durationSeconds" }
    let buffer = descriptor.inputs.first { $0.name == "traceBufferKB" }
    let categories = descriptor.inputs.first { $0.name == "traceCategories" }
    let traceStep = descriptor.steps.first { $0.stepID == "capture-trace" }
    let artifactNames = descriptor.artifacts.map(\.name)
    return TraceOperationPresentation(
      reference: descriptor.reference,
      title: descriptor.title,
      availability: availability,
      minimumEffect: descriptor.minimumEffect.rawValue,
      permittedEffects: descriptor.permittedEffects.map(\.rawValue),
      durationSecondsRange: closedRange(duration),
      traceBufferKBRange: closedRange(buffer),
      maximumTraceTagCount: categories?.maxItems,
      traceStepCancellation: traceStep?.cancellation.rawValue,
      artifactNames: artifactNames,
      supportsTypedTraceCategories: categories?.type == .stringArray,
      supportsRawTraceArtifact: artifactNames.contains("trace.htrace"),
      supportsFilteredTraceArtifact: artifactNames.contains("trace-filtered.htrace"),
      supportsCaptureLogArtifact: artifactNames.contains("capture.log"),
      exposesAdapterCapabilityFacts: descriptor.inputs.contains {
        $0.name == "traceAdapterCapabilities"
      },
      exposesParameterSnapshotFacts: descriptor.inputs.contains {
        $0.name == "traceParameterSnapshots"
      })
  }

  private static func closedRange(_ field: CatalogFieldDescriptor?) -> ClosedRange<Int>? {
    guard let minimum = field?.minimum, let maximum = field?.maximum else { return nil }
    return minimum...maximum
  }
}

private actor TraceProductionApplicationProvider: TraceApplicationProviding {
  func refreshWorkspace(targetID: String?) async -> TraceWorkspacePresentation {
    async let operations = TraceXPCReadTransport.request(method: "operation.list")
    async let targets = TraceXPCReadTransport.request(method: "target.list")
    async let jobs = TraceXPCReadTransport.request(
      method: "job.list", params: RuntimeAppJobListPolicy.recentSummaryParams)
    let base = TraceWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
    guard let selected = base.targets.first(where: { $0.id == targetID }) ?? base.targets.first
    else { return base }
    let probe = TraceRuntimeProbeResponseDecoding.snapshot(
      await TraceXPCReadTransport.request(
        method: "trace.probe", params: ["targetId": .string(selected.id)]),
      target: selected)
    switch probe {
    case .success(let snapshot):
      return TraceWorkspacePresentation(
        operation: base.operation, targets: base.targets,
        relatedDiagnosticsJobs: base.relatedDiagnosticsJobs,
        targetLoadFailure: base.targetLoadFailure,
        jobLoadFailure: base.jobLoadFailure,
        runtimeProbe: snapshot)
    case .failure(let failure):
      return TraceWorkspacePresentation(
        operation: base.operation, targets: base.targets,
        relatedDiagnosticsJobs: base.relatedDiagnosticsJobs,
        targetLoadFailure: base.targetLoadFailure,
        jobLoadFailure: base.jobLoadFailure,
        probeFailure: failure.message)
    }
  }

  func submitCapture(
    target: TraceTargetPresentation,
    durationSeconds: Int,
    tags: [String],
    bufferKB: Int
  ) async -> TraceJobSubmissionResult {
    do {
      let nonce = UUID().uuidString.lowercased()
      let request = try RuntimeOperationRequest(
        requestID: "trace-ui-\(nonce)",
        idempotencyKey: "trace-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id, expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
        inputs: try DiagnosticCapturePreset.trace(
          durationSeconds: durationSeconds,
          categories: tags,
          bufferKB: bufferKB),
        requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.traceWorkspace, targetID: target.id))
      let encoder = CanonicalJSONEncoders.canonical()
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed Trace request")
      }
      let result = try TraceXPCResponseDecoding.resultObject(
        await TraceXPCReadTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted Trace without returning a Job ID")
      }
      return .submitted(TraceJobAcceptancePresentation(jobID: jobID))
    } catch let failure as TraceResponseFailure {
      return .failed(failure.message)
    } catch let failure as DiagnosticCapturePresetError {
      return .failed(failure.reason)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func run(jobID: String) async -> TraceJobRunResult {
    do {
      let result = try TraceXPCResponseDecoding.resultObject(
        await TraceXPCReadTransport.request(
          method: "job.run", params: ["jobId": .string(jobID)]))
      guard result["jobId"] as? String == jobID,
        let state = result["state"] as? String,
        let outcomeUnknown = result["outcomeUnknown"] as? Bool,
        let timeline = result["timeline"] as? [String]
      else { return .failed("Runtime returned incomplete terminal Trace facts") }
      return .completed(
        TraceJobTerminalPresentation(
          jobID: jobID, state: state, outcomeUnknown: outcomeUnknown, timeline: timeline))
    } catch let failure as TraceResponseFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func cancel(jobID: String) async -> Bool {
    guard
      let result = try? TraceXPCResponseDecoding.resultObject(
        await TraceXPCReadTransport.request(
          method: "job.cancel", params: ["jobId": .string(jobID)]))
    else { return false }
    return result["cancelRequested"] as? Bool == true
  }
}

private enum TraceXPCResponseDecoding {
  static func resultObject(
    _ response: Result<Data, TraceXPCReadFailure>
  ) throws -> [String: Any] {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure): throw TraceResponseFailure(message: failure.message)
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TraceResponseFailure(message: "Runtime returned an unreadable response") }
    if let error = envelope["error"] as? [String: Any] {
      throw TraceResponseFailure(
        message: "Runtime refused the request: "
          + (error["message"] as? String ?? "no message"))
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any]
    else { throw TraceResponseFailure(message: "Runtime returned no result object") }
    return result
  }
}

enum TraceRuntimeProbeResponseDecoding {
  static func snapshot(
    _ response: Result<Data, TraceXPCReadFailure>,
    target: TraceTargetPresentation
  ) -> Result<TraceRuntimeProbeSnapshot, TraceResponseFailure> {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure):
      return .failure(TraceResponseFailure(message: failure.message))
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure(TraceResponseFailure(message: "Runtime returned an unreadable probe")) }
    if let error = envelope["error"] as? [String: Any] {
      return .failure(
        TraceResponseFailure(
          message: "Runtime refused the Trace probe: "
            + (error["message"] as? String ?? "no message")))
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any],
      result["targetId"] as? String == target.id,
      result["bindingRevision"] as? Int == target.bindingRevision,
      let disposition = result["adapterDisposition"] as? String,
      ["captureEligible", "unsupported"].contains(disposition),
      let tags = result["supportedTags"] as? [String],
      Set(tags).count == tags.count,
      let toolRows = result["tools"] as? [[String: Any]],
      let rows = result["parameters"] as? [[String: Any]]
    else {
      return .failure(TraceResponseFailure(message: "Runtime returned mismatched probe facts"))
    }

    var tools: [TraceRuntimeToolObservation] = []
    for row in toolRows {
      guard let tool = row["tool"] as? String,
        ["hitrace", "bytrace"].contains(tool),
        let dispositionText = row["disposition"] as? String,
        let toolDisposition = TraceRuntimeToolDisposition(rawValue: dispositionText)
      else {
        return .failure(TraceResponseFailure(message: "Runtime returned malformed tool facts"))
      }
      tools.append(
        TraceRuntimeToolObservation(
          tool: tool,
          disposition: toolDisposition,
          family: row["family"] as? String,
          rawHelpSHA256: row["rawHelpSha256"] as? String,
          detail: row["detail"] as? String))
    }
    guard Set(tools.map(\.tool)) == Set(["hitrace", "bytrace"]) else {
      return .failure(TraceResponseFailure(message: "Runtime omitted a required tool probe"))
    }

    let expectedNames = Set(TraceDebugParameterCatalog.definitions.map(\.name))
    var names: Set<String> = []
    var parameters: [TraceRuntimeParameterObservation] = []
    for row in rows {
      guard let name = row["name"] as? String, expectedNames.contains(name),
        names.insert(name).inserted,
        let stateText = row["state"] as? String,
        let state = TraceRuntimeParameterState(rawValue: stateText)
      else {
        return .failure(TraceResponseFailure(message: "Runtime returned malformed parameter facts"))
      }
      let value = row["value"] as? String
      let detail = row["detail"] as? String
      guard (state == .value) == (value != nil), state != .unreadable || detail != nil else {
        return .failure(
          TraceResponseFailure(message: "Runtime returned contradictory parameter facts"))
      }
      parameters.append(
        TraceRuntimeParameterObservation(
          name: name, state: state, value: value, detail: detail))
    }
    guard names == expectedNames else {
      return .failure(TraceResponseFailure(message: "Runtime omitted parameter facts"))
    }
    let tool = result["tool"] as? String
    let family = result["family"] as? String
    guard
      disposition != "captureEligible"
        || (tool == TraceProbeTool.hitrace.rawValue && family != nil && !tags.isEmpty)
    else {
      return .failure(TraceResponseFailure(message: "Runtime returned incomplete adapter facts"))
    }
    return .success(
      TraceRuntimeProbeSnapshot(
        targetID: target.id, bindingRevision: target.bindingRevision,
        adapterDisposition: disposition, tool: tool, family: family,
        supportedTags: tags,
        rawHelp: result["rawHelp"] as? String,
        rawHelpSHA256: result["rawHelpSha256"] as? String,
        tools: tools,
        parameters: parameters))
  }
}

enum TraceWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, TraceXPCReadFailure>,
    targetResponse: Result<Data, TraceXPCReadFailure>,
    jobResponse: Result<Data, TraceXPCReadFailure>
  ) -> TraceWorkspacePresentation {
    let targets = decodeTargets(targetResponse)
    let jobs = decodeJobs(jobResponse)
    return TraceWorkspacePresentation(
      operation: TraceApplicationFacade.operationPresentation(
        availability: decodeAvailability(operationResponse)),
      targets: targets.value ?? [],
      relatedDiagnosticsJobs: jobs.value ?? [],
      targetLoadFailure: targets.failure,
      jobLoadFailure: jobs.failure)
  }

  private static func decodeAvailability(
    _ response: Result<Data, TraceXPCReadFailure>
  ) -> TraceApplicationAvailability {
    switch response {
    case .failure(let failure):
      return .unavailable(reasons: [failure.message])
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return .unavailable(reasons: [failure.message])
      case .success(let entries):
        guard
          let entry = entries.first(where: {
            $0["reference"] as? String == TraceApplicationFacade.operationReference
          }),
          let state = entry["availability"] as? String,
          let reasons = entry["reasons"] as? [String]
        else {
          return .unavailable(
            reasons: ["capture.diagnostics@1 is missing complete availability facts"])
        }
        return state == "available"
          ? .available
          : .unavailable(
            reasons: reasons.isEmpty
              ? ["Runtime did not report an availability reason"] : reasons)
      }
    }
  }

  private static func decodeTargets(
    _ response: Result<Data, TraceXPCReadFailure>
  ) -> TraceDecodedList<TraceTargetPresentation> {
    switch response {
    case .failure(let failure):
      return TraceDecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return TraceDecodedList(failure: failure.message)
      case .success(let entries):
        var values: [TraceTargetPresentation] = []
        for entry in entries {
          guard
            let id = entry["targetId"] as? String,
            let revision = entry["bindingRevision"] as? Int,
            let toolVersion = entry["toolVersion"] as? String,
            let adoptedAtUTC = entry["adoptedAtUtc"] as? String
          else {
            return TraceDecodedList(
              failure: "Runtime returned a target without complete binding facts")
          }
          values.append(
            TraceTargetPresentation(
              id: id,
              bindingRevision: revision,
              toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return TraceDecodedList(value: values)
      }
    }
  }

  private static func decodeJobs(
    _ response: Result<Data, TraceXPCReadFailure>
  ) -> TraceDecodedList<TraceRelatedJobPresentation> {
    switch response {
    case .failure(let failure):
      return TraceDecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return TraceDecodedList(failure: failure.message)
      case .success(let entries):
        var values: [TraceRelatedJobPresentation] = []
        for entry in entries {
          guard let operation = entry["operation"] as? String else { continue }
          guard operation == TraceApplicationFacade.operationReference else { continue }
          guard
            let id = entry["jobId"] as? String,
            let targetID = entry["targetId"] as? String,
            let state = entry["state"] as? String,
            let waitingForHuman = entry["waitingForHuman"] as? Bool,
            let outcomeUnknown = entry["outcomeUnknown"] as? Bool,
            let residueCount = entry["outstandingResidueCount"] as? Int
          else {
            return TraceDecodedList(
              failure: "Runtime returned an incomplete diagnostics job")
          }
          values.append(
            TraceRelatedJobPresentation(
              id: id,
              targetID: targetID,
              state: state,
              waitingForHuman: waitingForHuman,
              outcomeUnknown: outcomeUnknown,
              outstandingResidueCount: residueCount))
        }
        return TraceDecodedList(value: values)
      }
    }
  }

  private static func decodeResultArray(
    _ data: Data
  ) -> Result<[[String: Any]], TraceResponseFailure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(TraceResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        TraceResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard object["ok"] as? Bool == true,
      let result = object["result"] as? [[String: Any]]
    else {
      return .failure(TraceResponseFailure(message: "Runtime returned no result list"))
    }
    return .success(result)
  }
}

struct TraceResponseFailure: Error {
  let message: String
}

private struct TraceDecodedList<Value> {
  let value: [Value]?
  let failure: String?

  init(value: [Value]) {
    self.value = value
    failure = nil
  }

  init(failure: String) {
    value = nil
    self.failure = failure
  }
}

enum TraceXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

private enum TraceXPCReadTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> Result<Data, TraceXPCReadFailure> {
    await RuntimeXPCRequestTransport.request(method: method, params: params)
      .mapError { TraceXPCReadFailure.transport($0.message) }
  }
}
