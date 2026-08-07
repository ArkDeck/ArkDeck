// App-facing Trace projection over Runtime's read-only XPC door.
//
// capture.diagnostics@1 publishes a typed traceCategories leg, but the App
// read surface does not currently return the per-target hitrace/bytrace probe,
// raw help, parameter snapshots or mutation receipts required by the accepted
// Trace contract. This facade exposes that gap alongside exact Catalog facts;
// it has no submission, cancellation, parameter-write or artifact transport.

import ArkDeckCore
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

  public init(id: String, bindingRevision: Int, toolVersion: String, adoptedAtUTC: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
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

  public init(
    operation: TraceOperationPresentation,
    targets: [TraceTargetPresentation],
    relatedDiagnosticsJobs: [TraceRelatedJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil
  ) {
    self.operation = operation
    self.targets = targets
    self.relatedDiagnosticsJobs = relatedDiagnosticsJobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
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
  func refreshWorkspace() async -> TraceWorkspacePresentation
}

public enum TraceApplicationFacade {
  public static let operationReference = "capture.diagnostics@1"

  private static let descriptor = RuntimeOperationCatalog.descriptor(
    reference: operationReference)!

  public static func make() -> any TraceApplicationProviding {
    TraceProductionApplicationProvider()
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
  func refreshWorkspace() async -> TraceWorkspacePresentation {
    async let operations = TraceXPCReadTransport.request(method: "operation.list")
    async let targets = TraceXPCReadTransport.request(method: "target.list")
    async let jobs = TraceXPCReadTransport.request(method: "job.list")
    return TraceWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
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

private struct TraceResponseFailure: Error {
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
  static func request(method: String) async -> Result<Data, TraceXPCReadFailure> {
    let frame: Data
    do {
      frame = try JSONSerialization.data(
        withJSONObject: ["v": 1, "id": UUID().uuidString, "method": method])
    } catch {
      return .failure(.transport("Could not compose a Runtime request"))
    }
    return await withCheckedContinuation { continuation in
      let box = TraceXPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: Result<Data, TraceXPCReadFailure>) {
        let alreadyAnswered = answered.withLock { state -> Bool in
          if state { return true }
          state = true
          return false
        }
        guard !alreadyAnswered else { return }
        box.connection.invalidate()
        continuation.resume(returning: result)
      }
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { error in
          finish(
            .failure(
              .transport(
                "ArkDeck Runtime is not reachable: \(error.localizedDescription)")))
        } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure(.transport("ArkDeck Runtime is not reachable")))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure(.transport("Runtime transport refused this request: \(refusal)")))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure(.transport("Runtime returned neither a response nor a reason")))
        }
      }
    }
  }
}

/// NSXPCConnection is thread-safe by contract but predates `Sendable`.
private final class TraceXPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}
