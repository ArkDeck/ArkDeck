import ArkDeckCore
import Foundation

public struct DiagnosticCaptureSnapshot: Codable, Sendable, Equatable {
  public struct Marker: Codable, Sendable, Equatable {
    public let markerId: String
    public let atHostUTC: String
    public let offsetMs: Int
    public let label: String?
  }

  public let schemaVersion: String
  public let jobId: String
  public let targetId: String
  public let bindingRevision: Int
  public let state: String
  public let jobState: String
  public let outcomeUnknown: Bool
  public let controlAvailable: Bool
  public let maximumSeconds: Int
  public let maximumMarkers: Int
  public let elapsedMs: Int
  public let stopRequested: Bool
  public let armedAtHostUTC: String?
  public let endedAtHostUTC: String?
  public let markers: [Marker]

  public var isTerminal: Bool {
    JobState(rawValue: jobState)?.isTerminal == true
  }

  package func validate(jobID: String, target: DeviceTargetPresentation) throws {
    guard schemaVersion == "1.0.0", jobId == jobID, targetId == target.id,
      bindingRevision == target.bindingRevision,
      ["preparing", "recording", "finalizing", "interrupted", "closed"].contains(state),
      JobState(rawValue: jobState) != nil,
      state != "closed" || isTerminal,
      (1...120).contains(maximumSeconds), (1...200).contains(maximumMarkers),
      (0...(maximumSeconds * 1000)).contains(elapsedMs), markers.count <= maximumMarkers,
      Set(markers.map(\.markerId)).count == markers.count,
      armedAtHostUTC.map({ ISO8601Timestamps.parse($0) != nil }) ?? true,
      endedAtHostUTC.map({ ISO8601Timestamps.parse($0) != nil }) ?? true,
      markers.allSatisfy({ !$0.markerId.isEmpty && ISO8601Timestamps.parse($0.atHostUTC) != nil
        && (0...(maximumSeconds * 1000)).contains($0.offsetMs) }),
      state != "recording" || (controlAvailable && armedAtHostUTC != nil && !outcomeUnknown)
    else { throw DiagnosticCaptureFailure("Runtime returned mismatched session state", uncertain: true) }
  }
}

public struct DiagnosticCaptureFailure: Error, Sendable, Equatable {
  public let message: String
  public let uncertain: Bool

  public init(_ message: String, uncertain: Bool = false) {
    self.message = message
    self.uncertain = uncertain
  }
}

public protocol DiagnosticCaptureProviding: Sendable {
  func preflight(target: DeviceTargetPresentation) async throws
  func submit(target: DeviceTargetPresentation, durationSeconds: Int) async throws -> String
  func run(jobID: String) async throws
  func status(jobID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot
  func mark(jobID: String, markerID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot
  func stop(jobID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot
  func cancelPreparation(jobID: String) async throws
  func history(jobID: String, target: DeviceTargetPresentation) async throws -> RuntimeHistoryWorkspaceContext
}

public enum DiagnosticCaptureFacade {
  public static let operationReference = "capture.diagnostic-session@1"
  public static let byteBudget = 128 * 1024 * 1024

  public static func request(
    target: DeviceTargetPresentation, durationSeconds: Int, nonce: String
  ) throws -> RuntimeOperationRequest {
    guard target.bindingRevision != nil, (1...120).contains(durationSeconds) else {
      throw DiagnosticCaptureFailure("Diagnostic Session duration must be 1...120 seconds")
    }
    return try RuntimeOperationRequest(
      requestID: "diagnostics-\(nonce)", idempotencyKey: "diagnostics-\(nonce)",
      target: DurableTargetReference(targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "capture.diagnostic-session", version: 1),
      inputs: [
        "durationSeconds": .integer(Int64(durationSeconds)),
        "traceCategories": .array([.string("ohos")]), "traceBufferKB": .integer(8192),
        "hilogFilters": .array([]),
        "maximumMarkers": .integer(50), "totalArtifactByteBudget": .integer(Int64(byteBudget)),
        "redactionProfile": .string("standard"),
      ], requestedOutputs: [.hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.diagnosticsWorkspace, targetID: target.id))
  }

  public static func make() -> any DiagnosticCaptureProviding { DiagnosticCaptureProvider() }
}
