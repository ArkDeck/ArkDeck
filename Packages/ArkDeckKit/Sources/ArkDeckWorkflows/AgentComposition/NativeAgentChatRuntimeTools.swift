// Typed Runtime tools for the native conversational Agent.
//
// The model receives pseudonymous target/selection references and bounded
// projections. Exact target ids, resume tokens, device transport identities
// and Artifact store access stay inside this actor. Every operation still
// enters through AgentRuntimeExecutor and agentd admission.

import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckHarness
import Foundation

public protocol AgentChatRuntimePort: Sendable {
  func request(method: String, params: [String: JSONValue]?) throws -> JSONValue
  func run(_ request: RuntimeAgentExecutionRequest) throws -> RuntimeAgentExecutionOutcome
  func resume(
    resumeToken: String, selection: String?
  ) throws -> RuntimeAgentExecutionOutcome
}

public struct LiveAgentChatRuntimePort: AgentChatRuntimePort {
  private let client: AgentClient
  private let executor: AgentRuntimeExecutor

  public init(socketPath: String, nowUTC: @escaping @Sendable () -> String) {
    let client = AgentClient(socketPath: socketPath)
    self.client = client
    self.executor = AgentRuntimeExecutor(client: client, nowUTC: nowUTC)
  }

  public func request(method: String, params: [String: JSONValue]?) throws -> JSONValue {
    try client.request(method: method, params: params, timeoutSeconds: 120)
  }

  public func run(_ request: RuntimeAgentExecutionRequest) throws
    -> RuntimeAgentExecutionOutcome
  {
    try executor.run(request)
  }

  public func resume(
    resumeToken: String, selection: String?
  ) throws -> RuntimeAgentExecutionOutcome {
    try executor.resume(resumeToken: resumeToken, selection: selection)
  }
}

public enum AgentChatRuntimeToolError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidArguments(String)
  case blocked(String)
  case malformedRuntimeResponse(String)
  case runtimeFailure(String)

  public var description: String {
    switch self {
    case .invalidArguments(let reason): return "invalid arguments: \(reason)"
    case .blocked(let reason): return reason
    case .malformedRuntimeResponse(let reason): return "malformed Runtime response: \(reason)"
    case .runtimeFailure(let reason): return "Runtime failure: \(reason)"
    }
  }
}

public actor NativeAgentChatRuntimeTools {
  public static let activeToolNames = [
    "arkdeck_runtime_overview",
    "arkdeck_observe_device",
    "arkdeck_capture_diagnostics",
    "arkdeck_read_artifact",
    "arkdeck_resume_after_user_action",
  ]

  public static let maximumOperationRuns = 8
  public static let maximumRounds = maximumOperationRuns
  public static let maximumE1Mutations = 0
  public static let allowedOperationReferences = [
    "observe.device@1", "capture.diagnostics@1",
  ]
  public static let maximumWallClockSeconds = 30 * 60
  public static let maximumArtifactBytes = 64 * 1_024 * 1_024
  public static let maximumArtifactReadBytes = 4 * 1_024 * 1_024
  public static let maximumModelArtifactTextBytes = 256 * 1_024
  public static let captureArtifactBudgetBytes = 8 * 1_024 * 1_024

  private struct PendingPause: Sendable {
    let resumeToken: String
    let selections: [String: String]
    let userTurn: Int
  }

  private let port: any AgentChatRuntimePort
  private let allowSensitiveArtifacts: Bool
  private let startedAt = Date()
  private var userTurn = 0
  private var operationRuns = 0
  private var artifactBytesObserved = 0
  private var artifactBytesRead = 0
  private var consecutiveFailures = 0
  private var stoppedReason: String?
  private var pendingPause: PendingPause?
  private var targetIDsByReference: [String: String] = [:]
  private var targetReferencesByID: [String: String] = [:]
  private var selectionReferencesByExactValue: [String: String] = [:]
  private var currentChatArtifacts: [String: Set<String>] = [:]

  public init(
    port: any AgentChatRuntimePort,
    allowSensitiveArtifacts: Bool = false
  ) {
    self.port = port
    self.allowSensitiveArtifacts = allowSensitiveArtifacts
  }

  public nonisolated func definitions() -> [HarnessAgentTool] {
    [
      HarnessAgentTool(
        name: "arkdeck_runtime_overview",
        description:
          "Read ArkDeck daemon health, typed operation availability, and adopted target "
          + "references. This performs no device operation.",
        parameters: Self.objectSchema(properties: [:], required: []),
        execute: { [self] arguments in try await runtimeOverview(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_observe_device",
        description:
          "Run the published observe.device@1 read-only Runtime operation. Use targetRef "
          + "from arkdeck_runtime_overview; omit it only when ArkDeck can safely select one.",
        parameters: Self.objectSchema(
          properties: [
            "targetRef": .object([
              "type": .string("string"),
              "description": .string("Pseudonymous target reference from Runtime overview"),
              "pattern": .string("^target-[a-f0-9]{12}(-[0-9]+)?$"),
            ])
          ], required: []),
        execute: { [self] arguments in try await observeDevice(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_capture_diagnostics",
        description:
          "Run the read-only shape of capture.diagnostics@1 for bounded HiLog, window "
          + "inventory, optional crash index, and derived summaries. Trace, screenshot and "
          + "mutation legs are unavailable.",
        parameters: Self.captureSchema,
        execute: { [self] arguments in try await captureDiagnostics(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_read_artifact",
        description: allowSensitiveArtifacts
          ? "Read bounded text from an Artifact produced in this chat. Sensitive sharing is enabled; binary products are never returned."
          : "Read bounded text from a standard-privacy Artifact produced in this chat. Sensitive and binary products stay local.",
        parameters: Self.objectSchema(
          properties: [
            "jobId": Self.identifierSchema(description: "Job returned by an earlier tool"),
            "artifactId": Self.identifierSchema(
              description: "Artifact returned by an earlier tool"),
          ], required: ["jobId", "artifactId"]),
        execute: { [self] arguments in try await readArtifact(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_resume_after_user_action",
        description:
          "Resume the exact persisted Runtime execution after the user completes the "
          + "requested physical action. Call only after a new user message. selectionRef "
          + "must be one of the pseudonymous choices returned by Runtime.",
        parameters: Self.objectSchema(
          properties: [
            "selectionRef": .object([
              "type": .string("string"),
              "description": .string("Exact pseudonymous selection offered by Runtime"),
              "pattern": .string("^selection-[0-9]+$"),
            ])
          ], required: []),
        execute: { [self] arguments in try await resumeAfterUserAction(arguments) }),
    ]
  }

  public func beginUserTurn() { userTurn += 1 }

  private func runtimeOverview(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    _ = try strictObject(arguments, allowed: [])
    do {
      let doctor = try port.request(method: "doctor", params: nil)
      let operations = try port.request(method: "operation.list", params: nil)
      let targets = try port.request(method: "target.list", params: nil)
      registerTargets(targets)
      let value = JSONValue.object([
        "doctor": project(doctor),
        "operations": project(operations),
        "targets": project(targets),
        "budget": budgetValue(),
      ])
      return try result(value, display: "ArkDeck Runtime overview updated")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func observeDevice(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(arguments, allowed: ["targetRef"])
    let targetID = try resolveTargetReference(optionalString(fields["targetRef"]))
    return try runTypedOperation(
      operationID: "observe.device", version: 1, inputs: [:], targetID: targetID)
  }

  private func captureDiagnostics(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(
      arguments,
      allowed: [
        "durationSeconds", "targetRef", "bundleName", "abilityName", "processName",
        "hilogFilters", "includeUIDump", "includeCrashIndex",
      ])
    guard let duration = integer(fields["durationSeconds"]), (1...120).contains(duration) else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "durationSeconds must be an integer in 1...120")
    }
    let targetID = try resolveTargetReference(optionalString(fields["targetRef"]))
    var inputs: [String: JSONValue] = [
      "durationSeconds": .integer(Int64(duration)),
      "totalArtifactByteBudget": .integer(Int64(Self.captureArtifactBudgetBytes)),
      "redactionProfile": .string("standard"),
    ]
    if let bundle = optionalString(fields["bundleName"]) {
      guard Self.isBundleName(bundle) else {
        throw AgentChatRuntimeToolError.invalidArguments("bundleName is malformed")
      }
      inputs["bundleName"] = .string(bundle)
    }
    if let ability = optionalString(fields["abilityName"]) {
      guard Self.isTypedName(ability, allowsColon: false) else {
        throw AgentChatRuntimeToolError.invalidArguments("abilityName is malformed")
      }
      inputs["abilityName"] = .string(ability)
    }
    if let process = optionalString(fields["processName"]) {
      guard Self.isTypedName(process, allowsColon: true) else {
        throw AgentChatRuntimeToolError.invalidArguments("processName is malformed")
      }
      inputs["processName"] = .string(process)
    }
    if let value = fields["hilogFilters"] {
      guard case .array(let values) = value, values.count <= 16 else {
        throw AgentChatRuntimeToolError.invalidArguments(
          "hilogFilters must contain at most 16 strings")
      }
      let filters = try values.map { item -> JSONValue in
        guard case .string(let text) = item, !text.isEmpty, text.utf8.count <= 200,
          !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          })
        else {
          throw AgentChatRuntimeToolError.invalidArguments("hilogFilters contains an invalid item")
        }
        return .string(text)
      }
      inputs["hilogFilters"] = .array(filters)
    }
    if let flag = optionalBool(fields["includeUIDump"]) { inputs["uiDump"] = .bool(flag) }
    if let flag = optionalBool(fields["includeCrashIndex"]) {
      inputs["crashLogs"] = .bool(flag)
    }
    return try runTypedOperation(
      operationID: "capture.diagnostics", version: 1,
      inputs: inputs, targetID: targetID)
  }

  private func readArtifact(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(arguments, allowed: ["jobId", "artifactId"])
    guard let jobID = optionalString(fields["jobId"]), Self.isSafeIdentifier(jobID),
      let artifactID = optionalString(fields["artifactId"]), Self.isSafeIdentifier(artifactID)
    else {
      throw AgentChatRuntimeToolError.invalidArguments("jobId or artifactId is malformed")
    }
    guard currentChatArtifacts[jobID]?.contains(artifactID) == true else {
      throw AgentChatRuntimeToolError.blocked(
        "The Artifact was not produced by an ArkDeck operation in this chat.")
    }
    let remaining = Self.maximumArtifactReadBytes - artifactBytesRead
    guard remaining > 0 else {
      throw AgentChatRuntimeToolError.blocked("The 4 MiB Artifact read budget is exhausted.")
    }
    do {
      let metadata = try port.request(
        method: "artifact.inspect",
        params: ["jobId": .string(jobID), "artifactId": .string(artifactID)])
      guard case .object(let metadataFields) = metadata,
        case .string(let privacy)? = metadataFields["privacy"]
      else {
        throw AgentChatRuntimeToolError.malformedRuntimeResponse(
          "artifact.inspect has no privacy classification")
      }
      guard privacy == "standard" || privacy == "sensitive" else {
        return try result(
          .object([
            "metadata": project(metadata), "content": .null,
            "blocked": .string("Artifact privacy classification is unknown."),
            "budget": budgetValue(),
          ]), display: "Artifact content blocked: unknown privacy")
      }
      if privacy == "sensitive", !allowSensitiveArtifacts {
        return try result(
          .object([
            "metadata": project(metadata), "content": .null,
            "blocked": .string(
              "Sensitive Artifact text stays local. Restart agent chat with "
                + "--allow-sensitive-artifacts only when sharing is appropriate."),
            "budget": budgetValue(),
          ]), display: "Sensitive Artifact metadata shown; content stayed local")
      }
      guard case .string(let mediaType)? = metadataFields["mediaType"],
        mediaType == "application/json" || mediaType.hasPrefix("text/")
      else {
        return try result(
          .object([
            "metadata": project(metadata), "content": .null,
            "blocked": .string("Binary Artifact content is not exposed to the Agent."),
            "budget": budgetValue(),
          ]), display: "Binary Artifact content stayed local")
      }

      let maximum = min(remaining, Self.maximumModelArtifactTextBytes)
      var params: [String: JSONValue] = [
        "jobId": .string(jobID), "artifactId": .string(artifactID),
        "maxBytes": .integer(Int64(maximum)),
      ]
      if privacy == "sensitive" { params["allowSensitive"] = .bool(true) }
      let read = try port.request(method: "artifact.read", params: params)
      guard case .object(let readFields) = read,
        case .string(let base64)? = readFields["base64"],
        let data = Data(base64Encoded: base64)
      else {
        throw AgentChatRuntimeToolError.malformedRuntimeResponse(
          "artifact.read has no decodable content")
      }
      artifactBytesRead += data.count
      let text = String(decoding: data, as: UTF8.self)
      let value = JSONValue.object([
        "metadata": project(metadata),
        "content": .string(sanitize(text)),
        "truncatedForModel": .bool(optionalBool(readFields["eof"]) == false),
        "bytesReturnedToModel": .integer(Int64(data.count)),
        "budget": budgetValue(),
      ])
      return try result(
        value,
        display: "Read \(data.count) bytes from Artifact \(artifactID)")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func resumeAfterUserAction(_ arguments: JSONValue) throws
    -> HarnessAgentToolResult
  {
    let fields = try strictObject(arguments, allowed: ["selectionRef"])
    guard let pause = pendingPause else {
      throw AgentChatRuntimeToolError.blocked(
        "No ArkDeck execution is waiting for a user action.")
    }
    guard userTurn > pause.userTurn else {
      throw AgentChatRuntimeToolError.blocked(
        "Wait for the user's next message before resuming this execution.")
    }
    let declared = optionalString(fields["selectionRef"])
    let selection: String?
    if pause.selections.isEmpty {
      guard declared == nil else {
        throw AgentChatRuntimeToolError.invalidArguments(
          "this pause does not accept a selectionRef")
      }
      selection = nil
    } else {
      guard let declared, let exact = pause.selections[declared] else {
        throw AgentChatRuntimeToolError.invalidArguments(
          "selectionRef must be one of \(pause.selections.keys.sorted().joined(separator: ", "))")
      }
      selection = exact
    }
    do {
      let outcome = try port.resume(
        resumeToken: pause.resumeToken, selection: selection)
      pendingPause = nil
      stoppedReason = nil
      return try finish(outcome: outcome, operationReference: "resume")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func runTypedOperation(
    operationID: String,
    version: Int,
    inputs: [String: JSONValue],
    targetID: String?
  ) throws -> HarnessAgentToolResult {
    try assertCanRunOperation()
    operationRuns += 1
    do {
      let outcome = try port.run(
        RuntimeAgentExecutionRequest(
          operationID: operationID, operationVersion: version,
          inputs: inputs, targetID: targetID,
          maximumWaitSeconds: 900))
      return try finish(
        outcome: outcome, operationReference: "\(operationID)@\(version)")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      noteRuntimeFailure("\(error)")
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func finish(
    outcome: RuntimeAgentExecutionOutcome,
    operationReference: String
  ) throws -> HarnessAgentToolResult {
    let receipt: RuntimeAgentExecutionReceipt
    var failure: String?
    switch outcome {
    case .completed(let value):
      receipt = value
      consecutiveFailures = 0
      stoppedReason = nil
    case .awaitingHumanAction(let action, let value):
      receipt = value
      var selections: [String: String] = [:]
      selectionReferencesByExactValue.removeAll()
      for (offset, exact) in (action.selectionOptions ?? []).enumerated() {
        let reference = "selection-\(offset + 1)"
        selections[reference] = exact
        selectionReferencesByExactValue[exact] = reference
      }
      pendingPause = PendingPause(
        resumeToken: action.resumeToken, selections: selections,
        userTurn: userTurn)
      stoppedReason =
        "Runtime is waiting for a physical user action. Wait for the user's next message."
    case .failed(let reason, let value):
      receipt = value
      failure = sanitize(reason)
      noteRuntimeFailure(reason)
    }

    artifactBytesObserved += receipt.artifacts.reduce(0) { partial, artifact in
      partial + max(0, artifact.byteCount)
    }
    if receipt.outcomeUnknown {
      stoppedReason =
        "Runtime reported outcomeUnknown. No new operation will be dispatched from this chat."
    }
    if artifactBytesObserved >= Self.maximumArtifactBytes, stoppedReason == nil {
      stoppedReason = "The 64 MiB Agent Artifact budget is exhausted."
    }

    var artifacts: JSONValue = .array([])
    if let jobID = receipt.jobID, Self.isSafeIdentifier(jobID) {
      do {
        artifacts = try port.request(
          method: "artifact.list", params: ["jobId": .string(jobID)])
        rememberArtifacts(jobID: jobID, value: artifacts)
      } catch {
        artifacts = .object(["error": .string(sanitize("\(error)"))])
      }
    }
    let receiptValue = try encodedValue(receipt)
    let value = JSONValue.object([
      "execution": project(receiptValue),
      "artifacts": project(artifacts),
      "error": failure.map(JSONValue.string) ?? .null,
      "budget": budgetValue(),
    ])
    let job = receipt.jobID ?? "-"
    return try result(
      value,
      display:
        "\(operationReference) → \(receipt.terminalState), job=\(job)"
        + (stoppedReason.map { "; \($0)" } ?? ""))
  }

  private func assertCanRunOperation() throws {
    if let stoppedReason {
      throw AgentChatRuntimeToolError.blocked(stoppedReason)
    }
    if elapsedSeconds >= Self.maximumWallClockSeconds {
      stoppedReason = "The 30-minute Agent wall-clock budget is exhausted."
      throw AgentChatRuntimeToolError.blocked(stoppedReason!)
    }
    if operationRuns >= Self.maximumOperationRuns {
      stoppedReason = "The 8-operation Agent run budget is exhausted."
      throw AgentChatRuntimeToolError.blocked(stoppedReason!)
    }
    if artifactBytesObserved >= Self.maximumArtifactBytes {
      stoppedReason = "The 64 MiB Agent Artifact budget is exhausted."
      throw AgentChatRuntimeToolError.blocked(stoppedReason!)
    }
  }

  private var elapsedSeconds: Int {
    max(0, Int(Date().timeIntervalSince(startedAt)))
  }

  private func noteRuntimeFailure(_ detail: String) {
    consecutiveFailures += 1
    if detail.range(of: "authorization required", options: .caseInsensitive) != nil {
      stoppedReason =
        "Runtime requires authorization. This read-only Agent cannot widen authority."
    } else if consecutiveFailures >= 2 {
      stoppedReason =
        "Runtime failed twice consecutively. The Agent stopped instead of repeating it."
    }
  }

  private func budgetValue() -> JSONValue {
    .object([
      "operationRuns": .integer(Int64(operationRuns)),
      "maxOperationRuns": .integer(Int64(Self.maximumOperationRuns)),
      "rounds": .integer(Int64(operationRuns)),
      "maxRounds": .integer(Int64(Self.maximumRounds)),
      "e1Mutations": .integer(0),
      "maxE1Mutations": .integer(Int64(Self.maximumE1Mutations)),
      "allowedOperations": .array(Self.allowedOperationReferences.map(JSONValue.string)),
      "elapsedSeconds": .integer(Int64(elapsedSeconds)),
      "maxWallClockSeconds": .integer(Int64(Self.maximumWallClockSeconds)),
      "artifactBytesObserved": .integer(Int64(artifactBytesObserved)),
      "maxArtifactBytes": .integer(Int64(Self.maximumArtifactBytes)),
      "artifactBytesRead": .integer(Int64(artifactBytesRead)),
      "maxArtifactReadBytes": .integer(Int64(Self.maximumArtifactReadBytes)),
      "stoppedReason": stoppedReason.map(JSONValue.string) ?? .null,
      "stopOnRepeatedFailure": .bool(true),
      "stopOnOutcomeUnknown": .bool(true),
      "stopOnHumanActionRequired": .bool(true),
      "stopOnAuthorizationRequired": .bool(true),
    ])
  }

  private func registerTargets(_ value: JSONValue) {
    guard case .array(let targets) = value else { return }
    for target in targets {
      guard case .object(let fields) = target,
        case .string(let targetID)? = fields["targetId"]
      else { continue }
      _ = targetReference(for: targetID)
    }
  }

  private func targetReference(for targetID: String) -> String {
    if let existing = targetReferencesByID[targetID] { return existing }
    let base = HarnessDecisionContext.pseudonym(forTargetID: targetID)
    var reference = base
    var suffix = 2
    while let existing = targetIDsByReference[reference], existing != targetID {
      reference = "\(base)-\(suffix)"
      suffix += 1
    }
    targetReferencesByID[targetID] = reference
    targetIDsByReference[reference] = targetID
    return reference
  }

  private func resolveTargetReference(_ reference: String?) throws -> String? {
    guard let reference else { return nil }
    guard let targetID = targetIDsByReference[reference] else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "targetRef is unknown; refresh arkdeck_runtime_overview")
    }
    return targetID
  }

  private func rememberArtifacts(jobID: String, value: JSONValue) {
    guard case .array(let artifacts) = value else { return }
    let identifiers = artifacts.compactMap { item -> String? in
      guard case .object(let fields) = item,
        case .string(let identifier)? = fields["artifactId"],
        Self.isSafeIdentifier(identifier)
      else { return nil }
      return identifier
    }
    currentChatArtifacts[jobID] = Set(identifiers)
  }

  private func project(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      var projected: [String: JSONValue] = [:]
      for (key, child) in fields {
        let normalized = key.lowercased()
        if [
          "resumetoken", "connectkey", "serial", "stableidentity",
          "stableidentitysha256", "stablephysicalidentity", "stablephysicalidentitysha256",
          "stabletargetidentitysha256", "resultingtargetepochsha256", "capabilityid",
          "capabilityreference", "reservationid", "consumptionfingerprintsha256",
          "targetbindingdigest",
        ].contains(normalized)
        {
          continue
        }
        if normalized == "authority", case .object(let authority) = child {
          var safeAuthority: [String: JSONValue] = [:]
          if let kind = authority["kind"] { safeAuthority["kind"] = project(kind) }
          projected[key] = .object(safeAuthority)
        } else if normalized == "targetid", case .string(let targetID) = child {
          projected["targetRef"] = .string(targetReference(for: targetID))
        } else {
          projected[key] = project(child)
        }
      }
      return .object(projected)
    case .array(let values): return .array(values.map(project))
    case .string(let text):
      if let selection = selectionReferencesByExactValue[text] { return .string(selection) }
      if let target = targetReferencesByID[text] { return .string(target) }
      return .string(sanitize(text))
    default: return value
    }
  }

  private func sanitize(_ text: String) -> String {
    var sanitized = text
    for (targetID, reference) in targetReferencesByID.sorted(by: {
      $0.key.utf8.count > $1.key.utf8.count
    }) {
      sanitized = sanitized.replacingOccurrences(of: targetID, with: reference)
    }
    for (exact, reference) in selectionReferencesByExactValue.sorted(by: {
      $0.key.utf8.count > $1.key.utf8.count
    }) {
      sanitized = sanitized.replacingOccurrences(of: exact, with: reference)
    }
    let markers = [
      "connectKey", "stablePhysicalIdentity", "/data/local/tmp/", "/Users/", "/home/",
      "/private/", "/tmp/", "file://",
    ]
    if markers.contains(where: { sanitized.localizedCaseInsensitiveContains($0) }) {
      return "[runtime detail redacted from model context]"
    }
    return sanitized.replacingOccurrences(
      of: "resume-[A-Za-z0-9._-]+", with: "resume-[stored by ArkDeck]",
      options: .regularExpression)
  }

  private func strictObject(
    _ value: JSONValue, allowed: Set<String>
  ) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else {
      throw AgentChatRuntimeToolError.invalidArguments("arguments must be an object")
    }
    if let unknown = fields.keys.first(where: { !allowed.contains($0) }) {
      throw AgentChatRuntimeToolError.invalidArguments("unknown field \(unknown)")
    }
    return fields
  }

  private func result(
    _ value: JSONValue, display: String
  ) throws -> HarnessAgentToolResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 8 * 1_024 * 1_024,
      let text = String(data: data, encoding: .utf8)
    else {
      throw AgentChatRuntimeToolError.malformedRuntimeResponse(
        "projected tool output exceeds 8 MiB")
    }
    return HarnessAgentToolResult(modelContent: text, displayContent: display)
  }

  private func encodedValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw AgentChatRuntimeToolError.malformedRuntimeResponse("receipt is not JSON")
    }
    return decoded
  }

  private func optionalString(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    return nil
  }

  private func optionalBool(_ value: JSONValue?) -> Bool? {
    if case .bool(let flag) = value { return flag }
    return nil
  }

  private func integer(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let number): return Int(exactly: number)
    case .unsignedInteger(let number): return Int(exactly: number)
    default: return nil
    }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    guard (1...128).contains(value.utf8.count),
      let first = value.unicodeScalars.first,
      first.isASCII, CharacterSet.alphanumerics.contains(first)
    else { return false }
    return value.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
    }
  }

  private static func isBundleName(_ value: String) -> Bool {
    guard value.utf8.count <= 200 else { return false }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2 else { return false }
    return components.allSatisfy { component in
      guard let first = component.unicodeScalars.first,
        first.isASCII && first.properties.isAlphabetic
      else { return false }
      return component.unicodeScalars.allSatisfy {
        $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_")
      }
    }
  }

  private static func isTypedName(_ value: String, allowsColon: Bool) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 200,
      let first = value.unicodeScalars.first,
      first.isASCII && first.properties.isAlphabetic
    else { return false }
    let punctuation = allowsColon ? "_.:" : "_."
    return value.unicodeScalars.allSatisfy {
      $0.isASCII
        && ($0.properties.isAlphabetic || $0.properties.numericType != nil
          || punctuation.unicodeScalars.contains($0))
    }
  }

  private static func objectSchema(
    properties: [String: JSONValue], required: [String]
  ) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": .bool(false),
    ])
  }

  private static func identifierSchema(description: String) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
      "pattern": .string("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"),
    ])
  }

  private static let captureSchema: JSONValue = objectSchema(
    properties: [
      "durationSeconds": .object([
        "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(120),
      ]),
      "targetRef": .object([
        "type": .string("string"), "pattern": .string("^target-[a-f0-9]{12}(-[0-9]+)?$"),
      ]),
      "bundleName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "abilityName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "processName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "hilogFilters": .object([
        "type": .string("array"), "maxItems": .integer(16),
        "items": .object(["type": .string("string"), "maxLength": .integer(200)]),
      ]),
      "includeUIDump": .object(["type": .string("boolean")]),
      "includeCrashIndex": .object(["type": .string("boolean")]),
    ], required: ["durationSeconds"])
}
