// App-facing Debug workspace over Runtime's closed typed XPC door.
//
// The only executable work exposed here is capture.diagnostics@1 and four
// target-bound read-only templates. There is no executable, argv, endpoint or
// authority input: the daemon owns lowering and the App receives a disclosure.

import ArkDeckCore
import ArkDeckRuntime
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
  public let runtimeProbe: DebugRuntimeProbeSnapshot?
  public let probeFailure: String?

  public init(
    operations: [DebugOperationPresentation],
    targets: [DebugTargetPresentation],
    jobs: [DebugJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil,
    runtimeProbe: DebugRuntimeProbeSnapshot? = nil,
    probeFailure: String? = nil
  ) {
    self.operations = operations
    self.targets = targets
    self.jobs = jobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
    self.runtimeProbe = runtimeProbe
    self.probeFailure = probeFailure
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
  public let isRunnable: Bool

  public init(
    id: String, effect: String, parameterNames: [String], isRunnable: Bool
  ) {
    self.id = id
    self.effect = effect
    self.parameterNames = parameterNames
    self.isRunnable = isRunnable
  }
}

public struct DebugLogJobAcceptancePresentation: Sendable, Equatable {
  public let jobID: String
  public init(jobID: String) { self.jobID = jobID }
}

public enum DebugLogJobSubmissionResult: Sendable, Equatable {
  case submitted(DebugLogJobAcceptancePresentation)
  case failed(String)
}

public struct DebugLogJobTerminalPresentation: Sendable, Equatable {
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

public enum DebugLogJobRunResult: Sendable, Equatable {
  case completed(DebugLogJobTerminalPresentation)
  case failed(String)
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
    guard (1_024...65_535).contains(localPort) else { return .invalid(.localPortOutOfRange) }
    guard !remotePortText.isEmpty, remotePortText.allSatisfy(\.isNumber),
      let remotePort = Int(remotePortText)
    else { return .invalid(.remotePortNotNumeric) }
    guard (1_024...65_535).contains(remotePort) else { return .invalid(.remotePortOutOfRange) }
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

  /// Bundle and ability names share the conservative character policy: they
  /// are Catalog-schema identifiers, and nothing that could read as a shell
  /// fragment may appear in a typed request preview.
  public static func isSafeTypedIdentifier(_ value: String) -> Bool {
    isSafeHilogComponent(value)
  }
}

public protocol DebugApplicationProviding: Sendable {
  func refreshWorkspace(targetID: String?) async -> DebugWorkspacePresentation
  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) async -> DebugLogJobSubmissionResult
  func run(jobID: String) async -> DebugLogJobRunResult
  func cancel(jobID: String) async -> Bool
  func submitPortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) async -> DebugLogJobSubmissionResult
  func runTemplate(
    target: DebugTargetPresentation,
    templateID: String
  ) async -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure>
}

public enum DebugApplicationFacade {
  public static let debugHAPReference = "debug.hap@1"
  public static let captureDiagnosticsReference = "capture.diagnostics@1"
  public static let createPortForwardReference = "port-forward.create@1"
  public static let removePortForwardReference = "port-forward.remove@1"

  static let descriptors: [CatalogOperationDescriptor] = [
    RuntimeOperationCatalog.descriptor(reference: captureDiagnosticsReference),
    RuntimeOperationCatalog.descriptor(reference: debugHAPReference),
    RuntimeOperationCatalog.descriptor(reference: createPortForwardReference),
    RuntimeOperationCatalog.descriptor(reference: removePortForwardReference),
  ].compactMap { $0 }

  /// The exact read-only template set implemented by the daemon. No member
  /// accepts user text; the Debug parameter key is fixed in provider code.
  public static let approvedCommandTemplates: [DebugCommandTemplatePresentation] = [
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.packageInventory.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.debugParameterRead.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.windowInventory.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.uptime.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
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
  func refreshWorkspace(targetID: String?) async -> DebugWorkspacePresentation {
    async let operations = DebugXPCReadTransport.request(method: "operation.list")
    async let targets = DebugXPCReadTransport.request(method: "target.list")
    async let jobs = DebugXPCReadTransport.request(method: "job.list")
    let base = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
    guard let target = base.targets.first(where: { $0.id == targetID }) ?? base.targets.first
    else { return base }
    switch DebugRuntimeResponseDecoding.snapshot(
      await DebugXPCReadTransport.request(
        method: "debug.probe", params: ["targetId": .string(target.id)]),
      target: target)
    {
    case .success(let snapshot):
      return DebugWorkspacePresentation(
        operations: base.operations, targets: base.targets, jobs: base.jobs,
        targetLoadFailure: base.targetLoadFailure, jobLoadFailure: base.jobLoadFailure,
        runtimeProbe: snapshot)
    case .failure(let failure):
      return DebugWorkspacePresentation(
        operations: base.operations, targets: base.targets, jobs: base.jobs,
        targetLoadFailure: base.targetLoadFailure, jobLoadFailure: base.jobLoadFailure,
        probeFailure: failure.message)
    }
  }

  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) async -> DebugLogJobSubmissionResult {
    guard (1...600).contains(durationSeconds), filters.count <= 16,
      filters.allSatisfy(DebugTypedValueValidator.isSafeHilogComponent)
    else { return .failed("HiLog request is outside the published bounds") }
    do {
      let nonce = UUID().uuidString.lowercased()
      let request = try RuntimeOperationRequest(
        requestID: "debug-logs-ui-\(nonce)",
        idempotencyKey: "debug-logs-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id, expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
        inputs: [
          "durationSeconds": .integer(Int64(durationSeconds)),
          "hilogFilters": .array(filters.map(JSONValue.string)),
          "uiDump": .bool(false),
          "crashLogs": .bool(false),
          "uiScreenshot": .bool(false),
          "uiComponentTree": .bool(false),
          "redactionProfile": .string("standard"),
        ],
        requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeClientContext(clientName: "ArkDeckApp.DebugWorkspace.Logs"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed HiLog request")
      }
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted HiLog capture without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func run(jobID: String) async -> DebugLogJobRunResult {
    do {
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.run", params: ["jobId": .string(jobID)]))
      guard result["jobId"] as? String == jobID,
        let state = result["state"] as? String,
        let outcomeUnknown = result["outcomeUnknown"] as? Bool,
        let timeline = result["timeline"] as? [String]
      else { return .failed("Runtime returned incomplete terminal HiLog facts") }
      return .completed(
        DebugLogJobTerminalPresentation(
          jobID: jobID, state: state, outcomeUnknown: outcomeUnknown, timeline: timeline))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func cancel(jobID: String) async -> Bool {
    guard let result = try? DebugRuntimeResponseDecoding.resultObject(
      await DebugXPCReadTransport.request(
        method: "job.cancel", params: ["jobId": .string(jobID)]))
    else { return false }
    return result["cancelRequested"] as? Bool == true
  }

  func submitPortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) async -> DebugLogJobSubmissionResult {
    guard (1_024...65_535).contains(rule.localPort),
      (1_024...65_535).contains(rule.remotePort)
    else { return .failed("Port rule is outside the published bounds") }
    do {
      let nonce = UUID().uuidString.lowercased()
      let operationID = removing ? "port-forward.remove" : "port-forward.create"
      let request = try RuntimeOperationRequest(
        requestID: "debug-network-ui-\(nonce)",
        idempotencyKey: "debug-network-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id, expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: operationID, version: 1),
        inputs: [
          "direction": .string(rule.direction.rawValue),
          "localPort": .integer(Int64(rule.localPort)),
          "remotePort": .integer(Int64(rule.remotePort)),
        ],
        requestedOutputs: [.derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeClientContext(
          clientName: "ArkDeckApp.DebugWorkspace.Network"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed port rule")
      }
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted the port rule without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func runTemplate(
    target: DebugTargetPresentation,
    templateID: String
  ) async -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure> {
    guard DebugRuntimeCommandTemplate(rawValue: templateID) != nil else {
      return .failure(.transport("Unknown Debug template"))
    }
    return DebugRuntimeResponseDecoding.command(
      await DebugXPCReadTransport.request(
        method: "debug.template.run",
        params: [
          "targetId": .string(target.id),
          "templateId": .string(templateID),
        ]),
      target: target, templateID: templateID)
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
              || operation == DebugApplicationFacade.createPortForwardReference
              || operation == DebugApplicationFacade.removePortForwardReference
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

enum DebugRuntimeResponseDecoding {
  static func resultObject(
    _ response: Result<Data, DebugXPCReadFailure>
  ) throws -> [String: Any] {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure): throw failure
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw DebugXPCReadFailure.transport("Runtime returned an unreadable response") }
    if let error = envelope["error"] as? [String: Any] {
      throw DebugXPCReadFailure.transport(
        "Runtime refused the request: " + (error["message"] as? String ?? "no message"))
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any]
    else { throw DebugXPCReadFailure.transport("Runtime returned no result object") }
    return result
  }

  static func snapshot(
    _ response: Result<Data, DebugXPCReadFailure>,
    target: DebugTargetPresentation
  ) -> Result<DebugRuntimeProbeSnapshot, DebugXPCReadFailure> {
    do {
      let result = try resultObject(response)
      guard result["targetId"] as? String == target.id,
        result["bindingRevision"] as? Int == target.bindingRevision,
        let packages = result["packages"] as? [String],
        Set(packages).count == packages.count,
        packages.allSatisfy({ DebugTypedValueValidator.isSafeTypedIdentifier($0) }),
        let ruleRows = result["portRules"] as? [[String: Any]],
        let warnings = result["warnings"] as? [String]
      else { return .failure(.transport("Runtime returned mismatched Debug probe facts")) }
      var rules: [DebugRuntimePortRule] = []
      for row in ruleRows {
        guard let directionText = row["direction"] as? String,
          let direction = DebugRuntimePortDirection(rawValue: directionText),
          let localPort = row["localPort"] as? Int,
          let remotePort = row["remotePort"] as? Int,
          (1...65_535).contains(localPort), (1...65_535).contains(remotePort)
        else { return .failure(.transport("Runtime returned malformed port rules")) }
        rules.append(
          DebugRuntimePortRule(
            direction: direction, localPort: localPort, remotePort: remotePort))
      }
      return .success(
        DebugRuntimeProbeSnapshot(
          targetID: target.id, bindingRevision: target.bindingRevision,
          packages: packages, portRules: rules, warnings: warnings))
    } catch let failure as DebugXPCReadFailure {
      return .failure(failure)
    } catch {
      return .failure(.transport(String(describing: error)))
    }
  }

  static func command(
    _ response: Result<Data, DebugXPCReadFailure>,
    target: DebugTargetPresentation,
    templateID: String
  ) -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure> {
    do {
      let result = try resultObject(response)
      guard result["targetId"] as? String == target.id,
        result["bindingRevision"] as? Int == target.bindingRevision,
        result["templateId"] as? String == templateID,
        result["effect"] as? String == "readOnly",
        result["executable"] as? String == "hdc",
        let executableSHA256 = result["executableSha256"] as? String,
        executableSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
        let arguments = result["arguments"] as? [String],
        arguments.first == "-t", arguments.dropFirst().first == "<redacted-connect-key>",
        let loweringSHA256 = result["loweringSha256"] as? String,
        loweringSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
        let durationMilliseconds = result["durationMilliseconds"] as? Int,
        durationMilliseconds >= 0,
        let stdout = result["stdout"] as? String,
        let stderr = result["stderr"] as? String,
        let outputTruncated = result["outputTruncated"] as? Bool
      else { return .failure(.transport("Runtime returned mismatched Debug command facts")) }
      let exitCode = result["exitCode"] as? Int
      return .success(
        DebugRuntimeCommandResult(
          targetID: target.id, bindingRevision: target.bindingRevision,
          templateID: templateID, effect: "readOnly", executable: "hdc",
          executableSHA256: executableSHA256, argumentDisclosure: arguments,
          loweringSHA256: loweringSHA256, exitCode: exitCode,
          durationMilliseconds: durationMilliseconds,
          stdout: stdout, stderr: stderr, outputTruncated: outputTruncated))
    } catch let failure as DebugXPCReadFailure {
      return .failure(failure)
    } catch {
      return .failure(.transport(String(describing: error)))
    }
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

public enum DebugXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  public var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

enum DebugXPCReadTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> Result<Data, DebugXPCReadFailure> {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
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
