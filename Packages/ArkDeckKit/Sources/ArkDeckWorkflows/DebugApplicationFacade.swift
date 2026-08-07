// App-facing Debug workspace projection over Runtime's read-only XPC door.
//
// This surface reads published operation availability, adopted target facts,
// and related jobs. It cannot import a HAP, submit a job, create a forward,
// clear a device buffer, request root, or run a command. Keeping those verbs
// absent is load-bearing: the UI can explain what the current Runtime supports
// without accidentally becoming a second admission path.

import ArkDeckCore
import Foundation
import os

public enum DebugRuntimeAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct DebugOperationPresentation: Sendable, Equatable, Identifiable {
  public let reference: String
  public let title: String
  public let minimumEffect: String
  public let permittedEffects: [String]
  public let timeoutSeconds: Int
  public let outputByteBudget: Int
  public let availability: DebugRuntimeAvailability
  public let fields: [DebugFieldPresentation]
  public let steps: [DebugStepPresentation]
  public let artifacts: [DebugArtifactPresentation]

  public var id: String { reference }

  public init(
    reference: String,
    title: String,
    minimumEffect: String,
    permittedEffects: [String],
    timeoutSeconds: Int,
    outputByteBudget: Int,
    availability: DebugRuntimeAvailability,
    fields: [DebugFieldPresentation],
    steps: [DebugStepPresentation],
    artifacts: [DebugArtifactPresentation]
  ) {
    self.reference = reference
    self.title = title
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.timeoutSeconds = timeoutSeconds
    self.outputByteBudget = outputByteBudget
    self.availability = availability
    self.fields = fields
    self.steps = steps
    self.artifacts = artifacts
  }
}

public struct DebugFieldPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let type: String
  public let isRequired: Bool
  public let constraintSummary: String

  public var id: String { name }

  public init(name: String, type: String, isRequired: Bool, constraintSummary: String) {
    self.name = name
    self.type = type
    self.isRequired = isRequired
    self.constraintSummary = constraintSummary
  }
}

public struct DebugStepPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let effect: String
  public let isOptional: Bool
  public let actionReference: String?

  public init(
    id: String, kind: String, effect: String, isOptional: Bool, actionReference: String?
  ) {
    self.id = id
    self.kind = kind
    self.effect = effect
    self.isOptional = isOptional
    self.actionReference = actionReference
  }
}

public struct DebugArtifactPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let role: String
  public let mediaType: String
  public let privacy: String
  public let isRequired: Bool

  public var id: String { name }

  public init(
    name: String, role: String, mediaType: String, privacy: String, isRequired: Bool
  ) {
    self.name = name
    self.role = role
    self.mediaType = mediaType
    self.privacy = privacy
    self.isRequired = isRequired
  }
}

public struct DebugTargetPresentation: Sendable, Equatable, Identifiable {
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

public struct DebugJobPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let operationReference: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let outstandingResidueCount: Int

  public var needsAttention: Bool {
    waitingForHuman || outcomeUnknown || outstandingResidueCount > 0
  }

  public var isActive: Bool {
    switch state {
    case "queued", "preflighting", "running", "cancelling", "reconciling": true
    default: false
    }
  }

  public init(
    id: String,
    operationReference: String,
    targetID: String,
    state: String,
    waitingForHuman: Bool,
    outcomeUnknown: Bool,
    outstandingResidueCount: Int
  ) {
    self.id = id
    self.operationReference = operationReference
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
  }
}

public struct DebugWorkspacePresentation: Sendable, Equatable {
  public let operations: [DebugOperationPresentation]
  public let targets: [DebugTargetPresentation]
  public let jobs: [DebugJobPresentation]
  public let targetLoadFailure: String?
  public let jobLoadFailure: String?

  public init(
    operations: [DebugOperationPresentation],
    targets: [DebugTargetPresentation],
    jobs: [DebugJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil
  ) {
    self.operations = operations
    self.targets = targets
    self.jobs = jobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
  }

  public static let loading = DebugWorkspacePresentation(
    operations: DebugApplicationFacade.descriptors.map {
      DebugApplicationFacade.operationPresentation(descriptor: $0, availability: .checking)
    },
    targets: [], jobs: [])

  public func operation(_ reference: String) -> DebugOperationPresentation? {
    operations.first { $0.reference == reference }
  }
}

public struct DebugCommandTemplatePresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let effect: String
  public let parameterNames: [String]
  public let isPublishedByRuntimeOperation: Bool

  public init(
    id: String, effect: String, parameterNames: [String], isPublishedByRuntimeOperation: Bool
  ) {
    self.id = id
    self.effect = effect
    self.parameterNames = parameterNames
    self.isPublishedByRuntimeOperation = isPublishedByRuntimeOperation
  }
}

public enum DebugPortRuleDirection: String, CaseIterable, Sendable {
  case forward
  case reverse
}

public struct DebugValidatedPortRule: Sendable, Equatable {
  public let direction: DebugPortRuleDirection
  public let localPort: Int
  public let remotePort: Int

  public init(direction: DebugPortRuleDirection, localPort: Int, remotePort: Int) {
    self.direction = direction
    self.localPort = localPort
    self.remotePort = remotePort
  }
}

public enum DebugPortRuleFailure: String, Sendable, Equatable {
  case localPortNotNumeric
  case localPortOutOfRange
  case remotePortNotNumeric
  case remotePortOutOfRange
}

public enum DebugPortRuleValidationResult: Sendable, Equatable {
  case valid(DebugValidatedPortRule)
  case invalid(DebugPortRuleFailure)
}

/// Validates two decimal port fields without ever accepting an endpoint or a
/// shell fragment. Provider-owned lowering is intentionally outside the App.
public enum DebugPortRuleValidator {
  public static func validate(
    direction: DebugPortRuleDirection, localPortText: String, remotePortText: String
  ) -> DebugPortRuleValidationResult {
    guard !localPortText.isEmpty, localPortText.allSatisfy(\.isNumber),
      let localPort = Int(localPortText)
    else { return .invalid(.localPortNotNumeric) }
    guard (1...65_535).contains(localPort) else { return .invalid(.localPortOutOfRange) }
    guard !remotePortText.isEmpty, remotePortText.allSatisfy(\.isNumber),
      let remotePort = Int(remotePortText)
    else { return .invalid(.remotePortNotNumeric) }
    guard (1...65_535).contains(remotePort) else { return .invalid(.remotePortOutOfRange) }
    return .valid(
      DebugValidatedPortRule(
        direction: direction, localPort: localPort, remotePort: remotePort))
  }
}

/// Conservative App-side validation for the structured HiLog fields. Runtime
/// remains authoritative, but an obviously free-form shell fragment never
/// appears in the UI's typed request preview.
public enum DebugTypedValueValidator {
  public static func isSafeHilogComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 200 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || "._:-".unicodeScalars.contains(scalar)
    }
  }
}

public protocol DebugApplicationProviding: Sendable {
  func refreshWorkspace() async -> DebugWorkspacePresentation
}

public enum DebugApplicationFacade {
  public static let debugHAPReference = "debug.hap@1"
  public static let captureDiagnosticsReference = "capture.diagnostics@1"

  static let descriptors: [CatalogOperationDescriptor] = [
    RuntimeOperationCatalog.descriptor(reference: captureDiagnosticsReference),
    RuntimeOperationCatalog.descriptor(reference: debugHAPReference),
  ].compactMap { $0 }

  /// Approved action identifiers are visible for discovery, but none are
  /// represented as independently runnable: no published Runtime operation
  /// currently exposes a generic one-shot-command request.
  public static let approvedCommandTemplates: [DebugCommandTemplatePresentation] = [
    DebugCommandTemplatePresentation(
      id: "deviceSummary", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "systemProperties", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "processList", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "packageInfo", effect: "readOnly", parameterNames: ["bundleName"],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "storageUsage", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "deviceModel", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "firmwareBuild", effect: "readOnly", parameterNames: [],
      isPublishedByRuntimeOperation: false),
    DebugCommandTemplatePresentation(
      id: "requestRootMode", effect: "deviceMutation", parameterNames: [],
      isPublishedByRuntimeOperation: false),
  ]

  public static func make() -> any DebugApplicationProviding {
    DebugProductionApplicationProvider()
  }

  static func operationPresentation(
    descriptor: CatalogOperationDescriptor, availability: DebugRuntimeAvailability
  ) -> DebugOperationPresentation {
    DebugOperationPresentation(
      reference: descriptor.reference,
      title: descriptor.title,
      minimumEffect: descriptor.minimumEffect.rawValue,
      permittedEffects: descriptor.permittedEffects.map(\.rawValue),
      timeoutSeconds: descriptor.timeoutSeconds,
      outputByteBudget: descriptor.outputByteBudget,
      availability: availability,
      fields: descriptor.inputs.map {
        DebugFieldPresentation(
          name: $0.name,
          type: $0.type.rawValue,
          isRequired: $0.isRequired,
          constraintSummary: fieldConstraintSummary($0))
      },
      steps: descriptor.steps.map {
        DebugStepPresentation(
          id: $0.stepID,
          kind: $0.kind.rawValue,
          effect: $0.effect.rawValue,
          isOptional: $0.isOptional,
          actionReference: $0.actionReference.map { "\($0.catalogID)/\($0.actionID)" })
      },
      artifacts: descriptor.artifacts.map {
        DebugArtifactPresentation(
          name: $0.name,
          role: $0.role.rawValue,
          mediaType: $0.mediaType,
          privacy: $0.privacy.rawValue,
          isRequired: $0.isRequired)
      })
  }

  private static func fieldConstraintSummary(_ field: CatalogFieldDescriptor) -> String {
    var constraints: [String] = []
    if let values = field.enumValues { constraints.append(values.joined(separator: " | ")) }
    if let minimum = field.minimum { constraints.append("min \(minimum)") }
    if let maximum = field.maximum { constraints.append("max \(maximum)") }
    if let maxLength = field.maxLength { constraints.append("≤ \(maxLength) chars") }
    if let maxItems = field.maxItems { constraints.append("≤ \(maxItems) items") }
    if field.pattern != nil { constraints.append("pattern checked") }
    return constraints.isEmpty ? "—" : constraints.joined(separator: " · ")
  }
}

private actor DebugProductionApplicationProvider: DebugApplicationProviding {
  func refreshWorkspace() async -> DebugWorkspacePresentation {
    async let operations = DebugXPCReadTransport.request(method: "operation.list")
    async let targets = DebugXPCReadTransport.request(method: "target.list")
    async let jobs = DebugXPCReadTransport.request(method: "job.list")
    return DebugWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
  }
}

enum DebugWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, DebugXPCReadFailure>,
    targetResponse: Result<Data, DebugXPCReadFailure>,
    jobResponse: Result<Data, DebugXPCReadFailure>
  ) -> DebugWorkspacePresentation {
    let operations = decodeOperations(operationResponse)
    let decodedTargets = decodeTargets(targetResponse)
    let decodedJobs = decodeJobs(jobResponse)
    return DebugWorkspacePresentation(
      operations: operations,
      targets: decodedTargets.value ?? [],
      jobs: decodedJobs.value ?? [],
      targetLoadFailure: decodedTargets.failure,
      jobLoadFailure: decodedJobs.failure)
  }

  private static func decodeOperations(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> [DebugOperationPresentation] {
    let entries: [[String: Any]]
    switch response {
    case .failure(let failure):
      return DebugApplicationFacade.descriptors.map {
        DebugApplicationFacade.operationPresentation(
          descriptor: $0, availability: .unavailable(reasons: [failure.message]))
      }
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return DebugApplicationFacade.descriptors.map {
          DebugApplicationFacade.operationPresentation(
            descriptor: $0, availability: .unavailable(reasons: [failure.message]))
        }
      case .success(let result): entries = result
      }
    }
    return DebugApplicationFacade.descriptors.map { descriptor in
      guard
        let entry = entries.first(where: { $0["reference"] as? String == descriptor.reference }),
        let state = entry["availability"] as? String,
        let reasons = entry["reasons"] as? [String]
      else {
        return DebugApplicationFacade.operationPresentation(
          descriptor: descriptor,
          availability: .unavailable(
            reasons: ["\(descriptor.reference) is missing complete availability facts"]))
      }
      return DebugApplicationFacade.operationPresentation(
        descriptor: descriptor,
        availability: state == "available"
          ? .available
          : .unavailable(
            reasons: reasons.isEmpty
              ? ["Runtime did not report an availability reason"] : reasons))
    }
  }

  private static func decodeTargets(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> DecodedList<DebugTargetPresentation> {
    switch response {
    case .failure(let failure): return DecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return DecodedList(failure: failure.message)
      case .success(let entries):
        var values: [DebugTargetPresentation] = []
        for entry in entries {
          guard
            let id = entry["targetId"] as? String,
            let revision = entry["bindingRevision"] as? Int,
            let toolVersion = entry["toolVersion"] as? String,
            let adoptedAtUTC = entry["adoptedAtUtc"] as? String
          else {
            return DecodedList(
              failure: "Runtime returned a target without complete binding facts")
          }
          values.append(
            DebugTargetPresentation(
              id: id, bindingRevision: revision, toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return DecodedList(value: values)
      }
    }
  }

  private static func decodeJobs(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> DecodedList<DebugJobPresentation> {
    switch response {
    case .failure(let failure): return DecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return DecodedList(failure: failure.message)
      case .success(let entries):
        var values: [DebugJobPresentation] = []
        for entry in entries {
          guard let operation = entry["operation"] as? String else { continue }
          guard
            operation == DebugApplicationFacade.debugHAPReference
              || operation == DebugApplicationFacade.captureDiagnosticsReference
          else { continue }
          guard
            let id = entry["jobId"] as? String,
            let targetID = entry["targetId"] as? String,
            let state = entry["state"] as? String,
            let waitingForHuman = entry["waitingForHuman"] as? Bool,
            let outcomeUnknown = entry["outcomeUnknown"] as? Bool,
            let residueCount = entry["outstandingResidueCount"] as? Int
          else {
            return DecodedList(failure: "Runtime returned an incomplete Debug job")
          }
          values.append(
            DebugJobPresentation(
              id: id, operationReference: operation, targetID: targetID, state: state,
              waitingForHuman: waitingForHuman, outcomeUnknown: outcomeUnknown,
              outstandingResidueCount: residueCount))
        }
        return DecodedList(value: values)
      }
    }
  }

  private static func decodeResultArray(
    _ data: Data
  ) -> Result<[[String: Any]], DebugResponseFailure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(DebugResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        DebugResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
      return .failure(DebugResponseFailure(message: "Runtime returned no result list"))
    }
    return .success(result)
  }
}

private struct DebugResponseFailure: Error {
  let message: String
}

private struct DecodedList<Value> {
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

enum DebugXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

private enum DebugXPCReadTransport {
  static func request(method: String) async -> Result<Data, DebugXPCReadFailure> {
    let frame: Data
    do {
      frame = try JSONSerialization.data(
        withJSONObject: ["v": 1, "id": UUID().uuidString, "method": method])
    } catch {
      return .failure(.transport("Could not compose a Runtime request"))
    }
    return await withCheckedContinuation { continuation in
      let box = DebugXPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: Result<Data, DebugXPCReadFailure>) {
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
private final class DebugXPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}
