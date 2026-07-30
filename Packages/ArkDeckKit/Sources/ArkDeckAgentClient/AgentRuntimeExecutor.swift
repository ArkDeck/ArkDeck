// One-shot Device Runtime Agent runner (CHG-2026-049, T00).
//
// The runner composes only typed daemon methods. Human involvement is a
// persisted pause/resume record for physical assistance; it never turns a
// maintainer into the host-command executor.

import ArkDeckCore
import Dispatch
import Foundation

public enum RuntimeExecutorKind: String, Codable, Sendable {
  case agent
  case human
}

public enum RuntimeHumanActionKind: String, Codable, Sendable {
  case trustDevice
  case selectTarget
  case physicalReconnect
}

public struct RuntimeHumanActionReceipt: Codable, Sendable, Equatable {
  public let kind: RuntimeHumanActionKind
  public let prompt: String
  public let resumeToken: String
  /// Exact typed values accepted by `--selection`, when this action is a
  /// choice. A human never has to run a separate host command to discover
  /// them.
  public let selectionOptions: [String]?
  public let raisedAtUTC: String
  public var resolvedAtUTC: String?
}

public struct RuntimeAgentExecutionReceipt: Codable, Sendable, Equatable {
  public let executor: RuntimeExecutorKind
  public let executorID: String
  public let operationReference: String
  public let jobID: String?
  public let targetID: String?
  public let bindingRevision: Int?
  public let catalogDigest: String
  public let providerID: String
  public let executionMode: String
  public let actualEffect: RuntimeHardwareEvidenceEffectLevel?
  public let authority: RuntimeHardwareEvidenceAuthority?
  public let stepKinds: [String]
  public let evidenceObservation: RuntimeHardwareEvidenceObservation?
  public let firstEvidenceStepAtUTC: String?
  public let outcomeUnknown: Bool
  public let humanActions: [RuntimeHumanActionReceipt]
  public let terminalState: String
  public let artifacts: [RuntimeHardwareEvidenceArtifact]
  public let evidenceBlockers: [String]
  public let startedAtUTC: String
  public let finishedAtUTC: String

  public var authorityReference: String {
    authority?.reference ?? ""
  }
}

public enum RuntimeAgentExecutionOutcome: Sendable, Equatable {
  case completed(RuntimeAgentExecutionReceipt)
  case awaitingHumanAction(RuntimeHumanActionReceipt, RuntimeAgentExecutionReceipt)
  case failed(reason: String, receipt: RuntimeAgentExecutionReceipt)
}

public enum RuntimeAgentExecutorError: Error, Equatable, Sendable {
  case daemonUnavailable(String)
  case malformedResponse(String)
  case operationRejected(String)
  case invalidResume(String)
  case persistence(String)
  case timeout(String)
}

public struct RuntimeAgentExecutionRequest: Codable, Sendable, Equatable {
  public let operationID: String
  public let operationVersion: Int
  public let inputs: [String: JSONValue]
  public let capabilityReference: String?
  public let targetID: String?
  public let maximumWaitSeconds: Int
  /// Stable across a persisted physical-assistance pause. It is also the
  /// seed for request/idempotency identities, so resume cannot create a
  /// second runtime job.
  public let executionID: String

  public init(
    operationID: String,
    operationVersion: Int,
    inputs: [String: JSONValue] = [:],
    capabilityReference: String? = nil,
    targetID: String? = nil,
    maximumWaitSeconds: Int = 900,
    executionID: String = UUID().uuidString.lowercased()
  ) {
    self.operationID = operationID
    self.operationVersion = operationVersion
    self.inputs = inputs
    self.capabilityReference = capabilityReference
    self.targetID = targetID
    self.maximumWaitSeconds = max(1, maximumWaitSeconds)
    self.executionID = executionID
  }

  var reference: String { "\(operationID)@\(operationVersion)" }
}

public struct AgentRuntimeExecutor: Sendable {
  private struct ExecutionDeadline: Sendable {
    private let startedNanoseconds: UInt64
    private let budgetNanoseconds: UInt64

    init(seconds: Int) {
      startedNanoseconds = DispatchTime.now().uptimeNanoseconds
      let seconds64 = UInt64(clamping: seconds)
      let (budget, overflow) = seconds64.multipliedReportingOverflow(by: 1_000_000_000)
      budgetNanoseconds = overflow ? UInt64.max : budget
    }

    func remainingSeconds() throws -> Int {
      let now = DispatchTime.now().uptimeNanoseconds
      let elapsed = now >= startedNanoseconds ? now - startedNanoseconds : 0
      guard elapsed < budgetNanoseconds else {
        throw RuntimeAgentExecutorError.timeout("execution deadline exhausted")
      }
      let remaining = budgetNanoseconds - elapsed
      let roundedUp =
        remaining / 1_000_000_000
        + (remaining % 1_000_000_000 == 0 ? 0 : 1)
      return Int(clamping: roundedUp)
    }
  }

  private struct Target: Codable, Sendable, Equatable {
    let targetID: String
    let bindingRevision: Int
  }

  private enum ResumeMode: String, Codable, Sendable {
    case retryAdoption
    case adoptedTarget
    case bootstrapCandidate
    case reconnectTarget
  }

  private struct PendingExecution: Codable, Sendable {
    let request: RuntimeAgentExecutionRequest
    let catalogDigest: String
    let startedAtUTC: String
    let humanActions: [RuntimeHumanActionReceipt]
    let resumeMode: ResumeMode
  }

  private let client: AgentClient
  private let stateDirectory: URL
  private let nowUTC: @Sendable () -> String

  public init(
    client: AgentClient,
    stateDirectory: URL? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.client = client
    self.stateDirectory =
      stateDirectory
      ?? URL(fileURLWithPath: client.socketPath).deletingLastPathComponent()
        .appendingPathComponent("agent-runtime", isDirectory: true)
    self.nowUTC = nowUTC
  }

  public func run(_ request: RuntimeAgentExecutionRequest) throws
    -> RuntimeAgentExecutionOutcome
  {
    guard Self.isSafeIdentifier(request.executionID) else {
      throw RuntimeAgentExecutorError.persistence("execution identifier is unsafe")
    }
    let startedAt = nowUTC()
    let deadline = ExecutionDeadline(seconds: request.maximumWaitSeconds)
    let digest = try healthDigest(deadline: deadline)
    return try continueRun(
      request, catalogDigest: digest, startedAtUTC: startedAt,
      humanActions: [], selectedTarget: nil, deadline: deadline)
  }

  /// Continues a persisted physical-assistance pause. `selection` is only
  /// accepted when the recorded action was target selection; the pending
  /// request, catalog digest and stable idempotency identity come from the
  /// persisted record, never from fresh caller input.
  public func resume(resumeToken: String, selection: String? = nil) throws
    -> RuntimeAgentExecutionOutcome
  {
    guard Self.isSafeIdentifier(resumeToken), resumeToken.hasPrefix("resume-") else {
      throw RuntimeAgentExecutorError.invalidResume("resume token is malformed")
    }
    let pendingURL = pendingFile(token: resumeToken)
    let pending: PendingExecution
    do {
      pending = try JSONDecoder().decode(
        PendingExecution.self, from: Data(contentsOf: pendingURL))
    } catch {
      throw RuntimeAgentExecutorError.invalidResume("resume token is unknown or unreadable")
    }
    let deadline = ExecutionDeadline(seconds: pending.request.maximumWaitSeconds)
    let currentDigest = try healthDigest(deadline: deadline)
    guard currentDigest == pending.catalogDigest else {
      throw RuntimeAgentExecutorError.invalidResume(
        "catalog digest changed while the execution was paused")
    }

    var actions = pending.humanActions
    if !actions.isEmpty {
      actions[actions.count - 1].resolvedAtUTC = nowUTC()
    }

    let selectedTarget: Target?
    switch pending.resumeMode {
    case .adoptedTarget:
      guard let selection else {
        throw RuntimeAgentExecutorError.invalidResume(
          "this pause requires an adopted target ID selection")
      }
      selectedTarget = try listTargets(deadline: deadline)
        .first { $0.targetID == selection }
      guard selectedTarget != nil else {
        throw RuntimeAgentExecutorError.invalidResume("selected target is not adopted")
      }
    case .bootstrapCandidate:
      guard let selection else {
        throw RuntimeAgentExecutorError.invalidResume(
          "this pause requires a device candidate selection")
      }
      guard Self.isSafeSelection(selection) else {
        throw RuntimeAgentExecutorError.invalidResume("device candidate selection is malformed")
      }
      let adopted = try adopt(
        request: pending.request, candidate: selection,
        catalogDigest: pending.catalogDigest, startedAtUTC: pending.startedAtUTC,
        humanActions: actions, deadline: deadline)
      switch adopted {
      case .target(let target):
        selectedTarget = target
      case .paused(let outcome):
        try? FileManager.default.removeItem(at: pendingURL)
        return outcome
      }
    case .retryAdoption, .reconnectTarget:
      guard selection == nil else {
        throw RuntimeAgentExecutorError.invalidResume(
          "this pause does not accept a target selection")
      }
      selectedTarget = nil
    }

    let outcome = try continueRun(
      pending.request, catalogDigest: pending.catalogDigest,
      startedAtUTC: pending.startedAtUTC, humanActions: actions,
      selectedTarget: selectedTarget, deadline: deadline)
    try? FileManager.default.removeItem(at: pendingURL)
    return outcome
  }

  private enum AdoptionResult {
    case target(Target)
    case paused(RuntimeAgentExecutionOutcome)
  }

  private func continueRun(
    _ request: RuntimeAgentExecutionRequest,
    catalogDigest: String,
    startedAtUTC: String,
    humanActions: [RuntimeHumanActionReceipt],
    selectedTarget: Target?,
    deadline: ExecutionDeadline
  ) throws -> RuntimeAgentExecutionOutcome {
    let target: Target
    if let selectedTarget {
      target = selectedTarget
    } else if let explicitTargetID = request.targetID {
      let listed = try listTargets(deadline: deadline)
      guard let explicit = listed.first(where: { $0.targetID == explicitTargetID }) else {
        return try pause(
          request: request, kind: .physicalReconnect,
          prompt: "Reconnect the selected target before resuming this execution.",
          mode: .reconnectTarget, catalogDigest: catalogDigest,
          startedAtUTC: startedAtUTC, humanActions: humanActions)
      }
      target = explicit
    } else {
      let listed = try listTargets(deadline: deadline)
      if listed.count == 1 {
        target = listed[0]
      } else if listed.count > 1 {
        return try pause(
          request: request, kind: .selectTarget,
          prompt: "Multiple adopted targets are available; select one target ID.",
          mode: .adoptedTarget, catalogDigest: catalogDigest,
          startedAtUTC: startedAtUTC, humanActions: humanActions,
          selectionOptions: listed.map(\.targetID))
      } else {
        switch try adopt(
          request: request, candidate: nil, catalogDigest: catalogDigest,
          startedAtUTC: startedAtUTC, humanActions: humanActions,
          deadline: deadline)
        {
        case .target(let adopted):
          target = adopted
        case .paused(let outcome):
          return outcome
        }
      }
    }

    var payload: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("2.0.0"),
      "requestId": .string("agent-request-\(request.executionID)"),
      "idempotencyKey": .string("agent-execution-\(request.executionID)"),
      "target": .object([
        "targetId": .string(target.targetID),
        "expectedBindingRevision": .integer(Int64(target.bindingRevision)),
      ]),
      "operation": .object([
        "id": .string(request.operationID),
        "version": .integer(Int64(request.operationVersion)),
      ]),
    ]
    if !request.inputs.isEmpty { payload["inputs"] = .object(request.inputs) }
    if let capability = request.capabilityReference {
      payload["authorization"] = .object(["capabilityId": .string(capability)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let requestJSON = try? encoder.encode(JSONValue.object(payload)),
      let requestText = String(data: requestJSON, encoding: .utf8)
    else {
      throw RuntimeAgentExecutorError.malformedResponse("cannot encode runtime request")
    }

    let submitted: JSONValue
    do {
      submitted = try call(
        method: "job.submit", params: ["requestJson": .string(requestText)],
        deadline: deadline)
    } catch let error as AgentClientError {
      if case .daemonError(_, let message) = error {
        return .failed(
          reason: message,
          receipt: receipt(
            request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
            actions: humanActions, jobID: nil, target: target, state: "rejected"))
      }
      throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
    }
    guard case .object(let submitFields) = submitted,
      case .string(let jobID)? = submitFields["jobId"],
      Self.isSafeIdentifier(jobID)
    else {
      throw RuntimeAgentExecutorError.malformedResponse("submit returned an unsafe job id")
    }

    let finished: JSONValue
    do {
      finished = try call(
        method: "job.run", params: ["jobId": .string(jobID)],
        deadline: deadline)
    } catch {
      _ = try? call(
        method: "job.cancel", params: ["jobId": .string(jobID)],
        timeoutSeconds: min(30, request.maximumWaitSeconds))
      return .failed(
        reason: "bounded job.run failed; typed cancellation requested: \(error)",
        receipt: receipt(
          request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
          actions: humanActions, jobID: jobID, target: target,
          state: "transportFailure"))
    }
    guard case .object(let statusFields) = finished,
      case .string(let state)? = statusFields["state"]
    else {
      throw RuntimeAgentExecutorError.malformedResponse("run returned no state")
    }
    let terminalStates: Set<String> = ["succeeded", "failed", "cancelled", "waitingForRecovery"]
    guard terminalStates.contains(state) else {
      _ = try? call(
        method: "job.cancel", params: ["jobId": .string(jobID)],
        timeoutSeconds: min(30, request.maximumWaitSeconds))
      return .failed(
        reason: "job.run returned non-terminal state \(state); typed cancellation requested",
        receipt: receipt(
          request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
          actions: humanActions, jobID: jobID, target: target, state: state))
    }

    var trustedFacts: RuntimeHardwareEvidenceTrustedFacts?
    var evidenceBlockers: [String] = []
    do {
      let evidence = try call(
        method: "job.evidence", params: ["jobId": .string(jobID)],
        deadline: deadline)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(evidence)
      trustedFacts = try JSONDecoder().decode(
        RuntimeHardwareEvidenceTrustedFacts.self, from: data)
    } catch {
      evidenceBlockers.append("trustedEvidenceQuery:\(error)")
    }

    _ = try listArtifactIDs(
      jobID: jobID, deadline: deadline)
    let final = receipt(
      request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
      actions: humanActions, jobID: jobID, target: target, state: state,
      trustedFacts: trustedFacts, blockers: evidenceBlockers)
    if state == "succeeded" { return .completed(final) }
    let terminalReason = Self.lastTimelineReason(statusFields) ?? "job ended in \(state)"
    if state == "waitingForRecovery" {
      return .failed(
        reason: "job requires typed reconcile: \(terminalReason)", receipt: final)
    }
    return .failed(reason: terminalReason, receipt: final)
  }

  private func adopt(
    request: RuntimeAgentExecutionRequest,
    candidate: String?,
    catalogDigest: String,
    startedAtUTC: String,
    humanActions: [RuntimeHumanActionReceipt],
    deadline: ExecutionDeadline
  ) throws -> AdoptionResult {
    var params: [String: JSONValue] = [:]
    if let candidate { params["candidate"] = .string(candidate) }
    let adopted: JSONValue
    do {
      adopted = try call(
        method: "target.adopt", params: params,
        deadline: deadline)
    } catch let error as AgentClientError {
      guard case .daemonError(_, let message) = error else {
        throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
      }
      return .paused(
        .failed(
          reason: message,
          receipt: receipt(
            request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
            actions: humanActions, jobID: nil, target: nil, state: "adoptRefused")))
    }
    guard case .object(let fields) = adopted,
      case .string(let outcome)? = fields["outcome"]
    else {
      throw RuntimeAgentExecutorError.malformedResponse("adopt returned no outcome")
    }
    switch outcome {
    case "adopted":
      guard case .string(let targetID)? = fields["targetId"],
        Self.isSafeIdentifier(targetID),
        let revision = Self.exactInt(fields["bindingRevision"])
      else {
        throw RuntimeAgentExecutorError.malformedResponse(
          "adopt returned malformed target binding")
      }
      return .target(Target(targetID: targetID, bindingRevision: revision))
    case "waitingForHuman":
      let prompt: String
      if case .string(let value)? = fields["prompt"] {
        prompt = value
      } else {
        prompt = "Complete the requested physical device action, then resume this execution."
      }
      guard case .string(let kindRaw)? = fields["humanActionKind"],
        let kind = RuntimeHumanActionKind(rawValue: kindRaw)
      else {
        throw RuntimeAgentExecutorError.malformedResponse(
          "adopt returned no recognized human action kind")
      }
      return .paused(
        try pause(
          request: request, kind: kind, prompt: prompt,
          mode: .retryAdoption, catalogDigest: catalogDigest,
          startedAtUTC: startedAtUTC, humanActions: humanActions))
    case "needsSelection":
      let selectionOptions: [String]
      if case .array(let candidates)? = fields["candidates"] {
        selectionOptions = candidates.compactMap { candidate in
          guard case .object(let values) = candidate,
            case .string(let value)? = values["candidate"],
            Self.isSafeSelection(value)
          else {
            return nil
          }
          return value
        }
      } else {
        selectionOptions = []
      }
      guard !selectionOptions.isEmpty else {
        throw RuntimeAgentExecutorError.malformedResponse(
          "adopt returned no safe candidate selection values")
      }
      return .paused(
        try pause(
          request: request, kind: .selectTarget,
          prompt: "Select one of \(selectionOptions.count) visible device candidates.",
          mode: .bootstrapCandidate, catalogDigest: catalogDigest,
          startedAtUTC: startedAtUTC, humanActions: humanActions,
          selectionOptions: selectionOptions))
    default:
      throw RuntimeAgentExecutorError.malformedResponse(
        "adopt returned unknown outcome \(outcome)")
    }
  }

  private func pause(
    request: RuntimeAgentExecutionRequest,
    kind: RuntimeHumanActionKind,
    prompt: String,
    mode: ResumeMode,
    catalogDigest: String,
    startedAtUTC: String,
    humanActions: [RuntimeHumanActionReceipt],
    selectionOptions: [String]? = nil
  ) throws -> RuntimeAgentExecutionOutcome {
    let token = "resume-\(UUID().uuidString.lowercased())"
    let action = RuntimeHumanActionReceipt(
      kind: kind, prompt: prompt, resumeToken: token,
      selectionOptions: selectionOptions,
      raisedAtUTC: nowUTC(), resolvedAtUTC: nil)
    let allActions = humanActions + [action]
    try persist(
      PendingExecution(
        request: request, catalogDigest: catalogDigest,
        startedAtUTC: startedAtUTC, humanActions: allActions, resumeMode: mode),
      to: pendingFile(token: token))
    return .awaitingHumanAction(
      action,
      receipt(
        request: request, digest: catalogDigest, startedAtUTC: startedAtUTC,
        actions: allActions, jobID: nil, target: nil,
        state: "awaitingHumanAction"))
  }

  private func healthDigest(deadline: ExecutionDeadline) throws -> String {
    let health: JSONValue
    do {
      health = try call(method: "health", deadline: deadline)
    } catch {
      throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
    }
    guard case .object(let fields) = health,
      case .string(let digest)? = fields["catalogDigest"], !digest.isEmpty
    else {
      throw RuntimeAgentExecutorError.malformedResponse("health lacks catalog digest")
    }
    return digest
  }

  private func listTargets(deadline: ExecutionDeadline) throws -> [Target] {
    let listed = try call(method: "target.list", deadline: deadline)
    guard case .array(let rows) = listed else {
      throw RuntimeAgentExecutorError.malformedResponse("target.list is not an array")
    }
    return try rows.map { row in
      guard case .object(let fields) = row,
        case .string(let targetID)? = fields["targetId"],
        Self.isSafeIdentifier(targetID),
        let revision = Self.exactInt(fields["bindingRevision"])
      else {
        throw RuntimeAgentExecutorError.malformedResponse(
          "target.list contains malformed binding")
      }
      return Target(targetID: targetID, bindingRevision: revision)
    }
  }

  private func listArtifactIDs(jobID: String, deadline: ExecutionDeadline) throws -> [String] {
    let listed = try call(
      method: "artifact.list", params: ["jobId": .string(jobID)],
      deadline: deadline)
    guard case .array(let rows) = listed else {
      throw RuntimeAgentExecutorError.malformedResponse("artifact.list is not an array")
    }
    return try rows.map { row in
      guard case .object(let fields) = row,
        case .string(let artifactID)? = fields["artifactId"],
        Self.isSafeIdentifier(artifactID)
      else {
        throw RuntimeAgentExecutorError.malformedResponse(
          "artifact.list contains an unsafe artifact id")
      }
      return artifactID
    }.sorted()
  }

  private func call(
    method: String, params: [String: JSONValue]? = nil, timeoutSeconds: Int
  ) throws -> JSONValue {
    try client.request(
      method: method, params: params,
      id: "agent-\(UUID().uuidString.lowercased())",
      timeoutSeconds: timeoutSeconds)
  }

  private func call(
    method: String, params: [String: JSONValue]? = nil, deadline: ExecutionDeadline
  ) throws -> JSONValue {
    try call(
      method: method, params: params,
      timeoutSeconds: try deadline.remainingSeconds())
  }

  private func receipt(
    request: RuntimeAgentExecutionRequest,
    digest: String,
    startedAtUTC: String,
    actions: [RuntimeHumanActionReceipt],
    jobID: String?,
    target: Target?,
    state: String,
    trustedFacts: RuntimeHardwareEvidenceTrustedFacts? = nil,
    blockers: [String] = []
  ) -> RuntimeAgentExecutionReceipt {
    let bindingRevision: Int?
    let receiptStartedAtUTC: String
    let receiptFinishedAtUTC: String
    if let trustedFacts {
      // A daemon-owned snapshot is authoritative. Missing values remain
      // missing instead of being filled from runner-local observations.
      bindingRevision = trustedFacts.bindingRevision
      receiptStartedAtUTC = trustedFacts.startedAtUTC ?? ""
      receiptFinishedAtUTC = trustedFacts.finishedAtUTC ?? ""
    } else {
      bindingRevision = target?.bindingRevision
      receiptStartedAtUTC = startedAtUTC
      receiptFinishedAtUTC = nowUTC()
    }
    return RuntimeAgentExecutionReceipt(
      executor: .agent,
      executorID: "arkdeck-device-runtime-agent",
      operationReference: trustedFacts?.operationReference ?? request.reference,
      jobID: trustedFacts?.jobID ?? jobID,
      targetID: trustedFacts?.targetID ?? target?.targetID,
      bindingRevision: bindingRevision,
      catalogDigest: trustedFacts?.catalogDigest ?? digest,
      providerID: trustedFacts?.providerID ?? "",
      executionMode: trustedFacts?.executionMode ?? "execute",
      actualEffect: trustedFacts?.actualEffect,
      authority: trustedFacts?.authority,
      stepKinds: trustedFacts?.actualStepKinds ?? [],
      evidenceObservation: trustedFacts?.observation,
      firstEvidenceStepAtUTC: trustedFacts?.firstEvidenceStepAtUTC,
      outcomeUnknown: trustedFacts?.outcomeUnknown ?? false,
      humanActions: actions,
      terminalState: trustedFacts?.terminalState ?? state,
      artifacts: trustedFacts?.artifacts ?? [],
      evidenceBlockers: blockers + (trustedFacts?.blockers ?? []),
      startedAtUTC: receiptStartedAtUTC,
      finishedAtUTC: receiptFinishedAtUTC)
  }

  private func pendingFile(token: String) -> URL {
    stateDirectory.appendingPathComponent("\(token).json")
  }

  private func persist<T: Encodable>(_ value: T, to destination: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let temporary = stateDirectory.appendingPathComponent(
        ".pending-\(UUID().uuidString.lowercased())")
      try encoder.encode(value).write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      throw RuntimeAgentExecutorError.persistence("\(error)")
    }
  }

  private static func exactInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let raw)?:
      return Int(exactly: raw)
    case .unsignedInteger(let raw)?:
      return Int(exactly: raw)
    default:
      return nil
    }
  }

  private static func lastTimelineReason(_ statusFields: [String: JSONValue]) -> String? {
    guard case .array(let timeline)? = statusFields["timeline"] else { return nil }
    return timeline.reversed().compactMap { item -> String? in
      guard case .string(let entry) = item, entry.hasPrefix("reason: ") else {
        return nil
      }
      return String(entry.dropFirst("reason: ".count))
    }.first
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
      options: .regularExpression) != nil
  }

  private static func isSafeSelection(_ value: String) -> Bool {
    (1...255).contains(value.utf8.count)
      && !value.unicodeScalars.contains { scalar in
        scalar.value == 0 || CharacterSet.newlines.contains(scalar)
      }
  }
}
