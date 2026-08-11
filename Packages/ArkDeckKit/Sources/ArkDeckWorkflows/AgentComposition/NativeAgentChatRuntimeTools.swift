// Typed Runtime tools for the native conversational Agent.
//
// The model receives pseudonymous target/selection references and bounded
// projections. Exact target ids, resume tokens, device transport identities
// and Artifact store access stay inside this actor. Every operation still
// enters through AgentRuntimeExecutor and agentd admission.

import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckHarness
import CryptoKit
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
    "arkdeck_start_debug_task",
    "arkdeck_debug_task_status",
    "arkdeck_resume_debug_task",
    "arkdeck_cancel_debug_task",
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
  public static let maximumTaskStarts = 1

  private struct PendingPause: Sendable {
    let resumeToken: String
    let selections: [String: String]
    let userTurn: Int
  }

  private struct PendingTaskPause: Sendable {
    let taskID: String
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
  private var taskStarts = 0
  private var taskIDsByReference: [String: String] = [:]
  private var taskReferencesByID: [String: String] = [:]
  private var pendingTaskPause: PendingTaskPause?
  private var taskStatusReadTurnByID: [String: Int] = [:]

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
      HarnessAgentTool(
        name: "arkdeck_start_debug_task",
        description:
          "Start one durable bounded debug task owned by ArkDeck Harness. The daemon auto-drives "
          + "observation, evidence, analysis, and—only when an explicit isolated workspace policy "
          + "and positive E1 budget are supplied—patch/build/test/deploy/verify. Use values stated "
          + "by the user or returned by ArkDeck; never invent project, revision, path, preset, "
          + "application, Artifact lease, or device profile values.",
        parameters: Self.debugTaskStartSchema,
        execute: { [self] arguments in try await startDebugTask(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_debug_task_status",
        description:
          "Read one bounded snapshot of a durable Harness debug task. Do not poll repeatedly in "
          + "one user turn: if it is still running, report that and end the turn.",
        parameters: Self.objectSchema(
          properties: [
            "taskRef": Self.taskReferenceSchema(
              description: "Pseudonymous task reference returned by ArkDeck")
          ], required: ["taskRef"]),
        execute: { [self] arguments in try await debugTaskStatus(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_resume_debug_task",
        description:
          "Resume the exact durable Harness task after a later user message resolves its reported "
          + "human action. This cannot widen task policy or budgets.",
        parameters: Self.objectSchema(
          properties: [
            "taskRef": Self.taskReferenceSchema(
              description: "Pseudonymous task reference returned by ArkDeck"),
            "resolution": .object([
              "type": .string("string"), "minLength": .integer(1),
              "maxLength": .integer(512),
              "description": .string("User-provided resolution of the reported human action"),
            ]),
          ], required: ["taskRef", "resolution"]),
        execute: { [self] arguments in try await resumeDebugTask(arguments) }),
      HarnessAgentTool(
        name: "arkdeck_cancel_debug_task",
        description:
          "Request typed cancellation of a durable Harness task. Use only when the user explicitly "
          + "asks to stop that task; cancellation creates no replacement task or authority.",
        parameters: Self.objectSchema(
          properties: [
            "taskRef": Self.taskReferenceSchema(
              description: "Pseudonymous task reference returned by ArkDeck")
          ], required: ["taskRef"]),
        execute: { [self] arguments in try await cancelDebugTask(arguments) }),
    ]
  }

  public func beginUserTurn() {
    // Human boundaries are learned only from explicit tool results already
    // shown to the model. An invisible pre-turn refresh could otherwise let a
    // generic user message resume an action the user was never asked to take.
    userTurn += 1
  }

  private func runtimeOverview(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    _ = try strictObject(arguments, allowed: [])
    do {
      let doctor = try port.request(method: "doctor", params: nil)
      let operations = try port.request(method: "operation.list", params: nil)
      let targets = try port.request(method: "target.list", params: nil)
      let tasks = try port.request(method: "task.list", params: nil)
      registerTargets(targets)
      registerTasks(tasks)
      let value = JSONValue.object([
        "doctor": project(doctor),
        "operations": project(operations),
        "targets": project(targets),
        "debugTasks": taskListProjection(tasks),
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

  private func startDebugTask(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(
      arguments,
      allowed: [
        "targetRef", "goal", "intake", "crashSignature", "bundleName", "abilityName",
        "processName", "baselineHapArtifactLease", "projectRef", "baseWorkspaceRevision",
        "workspaceAllowedPaths", "buildPresetRef", "testPresetRef", "deviceProfile",
        "component", "maxRounds", "maxWallClockSeconds", "maxE1Mutations",
        "maxModelCalls", "maxAttempts", "maxChangedFiles", "maxDiffLines",
        "expectedBindingRevision",
      ])
    guard taskStarts < Self.maximumTaskStarts else {
      throw AgentChatRuntimeToolError.blocked(
        "This chat already used its one durable debug-task start budget. Inspect or resume that task instead.")
    }
    guard let targetReference = requiredText(fields, "targetRef", maximumBytes: 64),
      let targetID = try resolveTargetReference(targetReference)
    else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "targetRef must come from arkdeck_runtime_overview")
    }
    guard let goal = requiredText(fields, "goal", maximumBytes: 2_048) else {
      throw AgentChatRuntimeToolError.invalidArguments("goal must contain 1...2048 UTF-8 bytes")
    }

    var params: [String: JSONValue] = [
      "targetId": .string(targetID),
      "goal": .string(goal),
    ]
    try copyText(
      from: fields, to: &params, key: "intake", maximumBytes: 4_096,
      validator: Self.isBoundedText)
    try copyText(
      from: fields, to: &params, key: "crashSignature", maximumBytes: 512,
      validator: Self.isBoundedText)
    try copyText(
      from: fields, to: &params, key: "bundleName", maximumBytes: 200,
      validator: Self.isBundleName)
    try copyText(
      from: fields, to: &params, key: "abilityName", maximumBytes: 200,
      validator: { Self.isTypedName($0, allowsColon: false) })
    try copyText(
      from: fields, to: &params, key: "processName", maximumBytes: 200,
      validator: { Self.isTypedName($0, allowsColon: true) })
    try copyText(
      from: fields, to: &params, key: "baselineHapArtifactLease", maximumBytes: 384,
      validator: Self.isArtifactLeaseReference)
    try copyText(
      from: fields, to: &params, key: "projectRef", maximumBytes: 128,
      validator: Self.isWireIdentifier)
    try copyText(
      from: fields, to: &params, key: "baseWorkspaceRevision", maximumBytes: 64,
      validator: Self.isLowercaseSHA256)
    for key in ["buildPresetRef", "testPresetRef", "deviceProfile"] {
      try copyText(
        from: fields, to: &params, key: key, maximumBytes: 128,
        validator: Self.isWireIdentifier)
    }
    try copyText(
      from: fields, to: &params, key: "component", maximumBytes: 256,
      validator: Self.isBoundedText)

    if params["abilityName"] != nil, params["bundleName"] == nil {
      throw AgentChatRuntimeToolError.invalidArguments("abilityName requires bundleName")
    }
    if params["processName"] != nil, params["bundleName"] == nil {
      throw AgentChatRuntimeToolError.invalidArguments("processName requires bundleName")
    }
    if params["baselineHapArtifactLease"] != nil,
      params["bundleName"] == nil || params["abilityName"] == nil
    {
      throw AgentChatRuntimeToolError.invalidArguments(
        "baselineHapArtifactLease requires bundleName and abilityName")
    }

    if let value = fields["workspaceAllowedPaths"] {
      guard case .array(let entries) = value, (1...32).contains(entries.count) else {
        throw AgentChatRuntimeToolError.invalidArguments(
          "workspaceAllowedPaths must contain 1...32 bounded path patterns")
      }
      let paths = try entries.map { entry -> JSONValue in
        guard case .string(let path) = entry, Self.isWorkspacePathPattern(path) else {
          throw AgentChatRuntimeToolError.invalidArguments(
            "workspaceAllowedPaths contains an invalid path pattern")
        }
        return .string(path)
      }
      guard params["projectRef"] != nil, params["baseWorkspaceRevision"] != nil,
        let e1 = integer(fields["maxE1Mutations"]), e1 > 0
      else {
        throw AgentChatRuntimeToolError.invalidArguments(
          "workspace repair requires projectRef, baseWorkspaceRevision, and a positive maxE1Mutations")
      }
      params["workspaceAllowedPaths"] = .array(paths)
    } else if params["baseWorkspaceRevision"] != nil || fields["maxAttempts"] != nil
      || fields["maxChangedFiles"] != nil || fields["maxDiffLines"] != nil
      || (integer(fields["maxE1Mutations"]) ?? 0) > 0
    {
      throw AgentChatRuntimeToolError.invalidArguments(
        "workspace repair bounds require workspaceAllowedPaths")
    }

    try copyInteger(
      from: fields, to: &params, key: "maxRounds", range: 1...32)
    try copyInteger(
      from: fields, to: &params, key: "maxWallClockSeconds", range: 60...7_200)
    try copyInteger(
      from: fields, to: &params, key: "maxE1Mutations", range: 0...16)
    try copyInteger(
      from: fields, to: &params, key: "maxModelCalls", range: 0...64)
    try copyInteger(
      from: fields, to: &params, key: "maxAttempts", range: 1...8)
    try copyInteger(
      from: fields, to: &params, key: "maxChangedFiles", range: 1...50)
    try copyInteger(
      from: fields, to: &params, key: "maxDiffLines", range: 1...5_000)
    try copyInteger(
      from: fields, to: &params, key: "expectedBindingRevision", range: 1...Int.max)

    // Creating a durable task is the effect of this tool. Charge before the
    // request so an uncertain transport result cannot be retried into a
    // duplicate task by the same chat.
    taskStarts += 1
    do {
      let submitted = try port.request(method: "task.submit", params: params)
      guard case .object(let values) = submitted,
        case .string(let taskID)? = values["htaskId"], Self.isSafeTaskIdentifier(taskID)
      else {
        throw AgentChatRuntimeToolError.malformedRuntimeResponse(
          "task.submit returned no safe Harness task id")
      }
      let reference = taskReference(for: taskID)
      updateTaskPause(from: submitted, taskID: taskID, observedAtTurn: userTurn)
      let value = taskStatusProjection(submitted, taskID: taskID)
      return try result(
        value,
        display: "Started durable Harness debug task \(reference); daemon auto-drive owns progress")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func debugTaskStatus(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(arguments, allowed: ["taskRef"])
    let taskID = try resolveTaskReference(fields["taskRef"])
    guard taskStatusReadTurnByID[taskID] != userTurn else {
      throw AgentChatRuntimeToolError.blocked(
        "This task was already read in the current user turn. Report its last status and wait for the next message.")
    }
    // Charge before transport: a failed read is still not a reason for the
    // model to spin on the local daemon in the same conversational turn.
    taskStatusReadTurnByID[taskID] = userTurn
    do {
      let status = try port.request(
        method: "task.status", params: ["htaskId": .string(taskID)])
      let actions = try port.request(
        method: "task.humanActions", params: ["htaskId": .string(taskID)])
      updateTaskPause(from: status, taskID: taskID, observedAtTurn: userTurn)
      let projected = JSONValue.object([
        "task": taskStatusProjection(status, taskID: taskID),
        "openHumanAction": openHumanActionProjection(actions),
      ])
      let lifecycle = taskLifecycle(status) ?? "unknown"
      let stage = taskStage(status) ?? "unknown"
      return try result(
        projected,
        display: "\(taskReference(for: taskID)) → \(lifecycle), stage=\(stage)")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func resumeDebugTask(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(arguments, allowed: ["taskRef", "resolution"])
    let taskID = try resolveTaskReference(fields["taskRef"])
    guard let resolution = requiredText(fields, "resolution", maximumBytes: 512) else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "resolution must contain 1...512 UTF-8 bytes")
    }
    guard let pause = pendingTaskPause, pause.taskID == taskID else {
      throw AgentChatRuntimeToolError.blocked(
        "This task has no human action observed by ArkDeck in this chat. Read its status first.")
    }
    guard userTurn > pause.userTurn else {
      throw AgentChatRuntimeToolError.blocked(
        "Wait for the user's next message before resuming this Harness task.")
    }
    do {
      let resumed = try port.request(
        method: "task.resume",
        params: ["htaskId": .string(taskID), "resolution": .string(resolution)])
      pendingTaskPause = nil
      return try result(
        taskStatusProjection(resumed, taskID: taskID),
        display: "Resumed \(taskReference(for: taskID)) through its typed human-action transition")
    } catch let error as AgentChatRuntimeToolError {
      throw error
    } catch {
      throw AgentChatRuntimeToolError.runtimeFailure(sanitize("\(error)"))
    }
  }

  private func cancelDebugTask(_ arguments: JSONValue) throws -> HarnessAgentToolResult {
    let fields = try strictObject(arguments, allowed: ["taskRef"])
    let taskID = try resolveTaskReference(fields["taskRef"])
    do {
      let cancelled = try port.request(
        method: "task.cancel", params: ["htaskId": .string(taskID)])
      if pendingTaskPause?.taskID == taskID { pendingTaskPause = nil }
      return try result(
        taskStatusProjection(cancelled, taskID: taskID),
        display: "Typed cancellation requested for \(taskReference(for: taskID))")
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

  private func registerTasks(_ value: JSONValue) {
    guard case .array(let tasks) = value else { return }
    for task in tasks.prefix(32) {
      guard case .object(let fields) = task,
        case .string(let taskID)? = fields["htaskId"], Self.isSafeTaskIdentifier(taskID)
      else { continue }
      _ = taskReference(for: taskID)
    }
  }

  private func taskListProjection(_ value: JSONValue) -> JSONValue {
    guard case .array(let tasks) = value else {
      return .object(["error": .string("task.list was not an array")])
    }
    return .array(
      tasks.prefix(32).compactMap { task -> JSONValue? in
        guard case .object(let fields) = task,
          case .string(let taskID)? = fields["htaskId"], Self.isSafeTaskIdentifier(taskID)
        else { return nil }
        return taskStatusProjection(task, taskID: taskID)
      })
  }

  private func taskStatusProjection(_ value: JSONValue, taskID: String) -> JSONValue {
    guard case .object(let fields) = value else {
      return .object([
        "taskRef": .string(taskReference(for: taskID)),
        "error": .string("task status was not an object"),
      ])
    }
    var summary: [String: JSONValue] = [
      "taskRef": .string(taskReference(for: taskID))
    ]
    for key in [
      "type", HarnessTaskWireField.lifecycle, HarnessTaskWireField.stage, "waitReason",
      "conditions", HarnessTaskWireField.legacyStatus, HarnessTaskWireField.legacyPhase,
      "activeRound", "activeJobId", "cancelRequested", "version", "updatedAtUtc", "budgets",
      "consumedBudget", "allowedOperations", "result",
    ] {
      if let child = fields[key] { summary[key] = project(child) }
    }
    return .object(summary)
  }

  private func openHumanActionProjection(_ value: JSONValue) -> JSONValue {
    guard case .array(let actions) = value else { return .null }
    guard let open = actions.reversed().first(where: { action in
      guard case .object(let fields) = action else { return false }
      return fields["resolvedAtUtc"] == nil || fields["resolvedAtUtc"] == .null
    }), case .object(let fields) = open
    else { return .null }
    var summary: [String: JSONValue] = [:]
    for key in [
      "block", "reasonCode", "round", "resumeStatus", "resumePhase", "evidenceRefs",
      "generatedAtUtc",
    ] {
      if let child = fields[key] { summary[key] = project(child) }
    }
    return .object(summary)
  }

  private func updateTaskPause(
    from value: JSONValue,
    taskID: String,
    observedAtTurn: Int
  ) {
    if taskLifecycle(value) == HarnessTaskLifecycle.humanRequired.rawValue {
      if pendingTaskPause?.taskID != taskID {
        pendingTaskPause = PendingTaskPause(taskID: taskID, userTurn: observedAtTurn)
      }
    } else if pendingTaskPause?.taskID == taskID {
      pendingTaskPause = nil
    }
  }

  private func taskLifecycle(_ value: JSONValue) -> String? {
    guard case .object(let fields) = value else { return nil }
    if case .string(let lifecycle)? = fields[HarnessTaskWireField.lifecycle] { return lifecycle }
    if case .string(let status)? = fields[HarnessTaskWireField.legacyStatus] { return status }
    return nil
  }

  private func taskStage(_ value: JSONValue) -> String? {
    guard case .object(let fields) = value else { return nil }
    if case .string(let stage)? = fields[HarnessTaskWireField.stage] { return stage }
    if case .string(let phase)? = fields[HarnessTaskWireField.legacyPhase] { return phase }
    return nil
  }

  private func taskReference(for taskID: String) -> String {
    if let existing = taskReferencesByID[taskID] { return existing }
    let digest = SHA256Hex.string(of: Data("arkdeck-chat-task|\(taskID)".utf8))
    let base = "task-\(digest.prefix(12))"
    var reference = base
    var suffix = 2
    while let existing = taskIDsByReference[reference], existing != taskID {
      reference = "\(base)-\(suffix)"
      suffix += 1
    }
    taskReferencesByID[taskID] = reference
    taskIDsByReference[reference] = taskID
    return reference
  }

  private func resolveTaskReference(_ value: JSONValue?) throws -> String {
    guard case .string(let reference) = value,
      let taskID = taskIDsByReference[reference]
    else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "taskRef is unknown; refresh arkdeck_runtime_overview")
    }
    return taskID
  }

  private func requiredText(
    _ fields: [String: JSONValue],
    _ key: String,
    maximumBytes: Int
  ) -> String? {
    guard case .string(let text)? = fields[key], text.utf8.count <= maximumBytes,
      Self.isBoundedText(text)
    else { return nil }
    return text
  }

  private func copyText(
    from fields: [String: JSONValue],
    to params: inout [String: JSONValue],
    key: String,
    maximumBytes: Int,
    validator: (String) -> Bool
  ) throws {
    guard let raw = fields[key] else { return }
    guard case .string(let text) = raw, text.utf8.count <= maximumBytes,
      validator(text)
    else {
      throw AgentChatRuntimeToolError.invalidArguments("\(key) is malformed")
    }
    params[key] = .string(text)
  }

  private func copyInteger(
    from fields: [String: JSONValue],
    to params: inout [String: JSONValue],
    key: String,
    range: ClosedRange<Int>
  ) throws {
    guard let raw = fields[key] else { return }
    guard let value = integer(raw), range.contains(value) else {
      throw AgentChatRuntimeToolError.invalidArguments(
        "\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)")
    }
    params[key] = .integer(Int64(value))
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
        } else if normalized == "htaskid", case .string(let taskID) = child,
          Self.isSafeTaskIdentifier(taskID)
        {
          projected["taskRef"] = .string(taskReference(for: taskID))
        } else {
          projected[key] = project(child)
        }
      }
      return .object(projected)
    case .array(let values): return .array(values.map(project))
    case .string(let text):
      if let selection = selectionReferencesByExactValue[text] { return .string(selection) }
      if let target = targetReferencesByID[text] { return .string(target) }
      if let task = taskReferencesByID[text] { return .string(task) }
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
    for (taskID, reference) in taskReferencesByID.sorted(by: {
      $0.key.utf8.count > $1.key.utf8.count
    }) {
      sanitized = sanitized.replacingOccurrences(of: taskID, with: reference)
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

  private static func isBoundedText(_ value: String) -> Bool {
    !value.isEmpty
      && !value.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
  }

  private static func isWireIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy {
        $0.isASCII
          && (CharacterSet.alphanumerics.contains($0) || "._:@-".unicodeScalars.contains($0))
      }
  }

  private static func isArtifactLeaseReference(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 3 && parts[0] == "lease-v1"
      && parts.dropFirst().allSatisfy { isWireIdentifier(String($0)) }
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    SHA256Hex.isLowercaseSHA256(value)
  }

  private static func isWorkspacePathPattern(_ value: String) -> Bool {
    guard value.utf8.count <= 256, isBoundedText(value),
      !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\")
    else { return false }
    return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }

  private static func isSafeTaskIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix("HTASK-") else { return false }
    return isSafeIdentifier(value)
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

  private static func taskReferenceSchema(description: String) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
      "pattern": .string("^task-[a-f0-9]{12}(-[0-9]+)?$"),
    ])
  }

  private static let debugTaskStartSchema: JSONValue = objectSchema(
    properties: [
      "targetRef": .object([
        "type": .string("string"), "pattern": .string("^target-[a-f0-9]{12}(-[0-9]+)?$"),
      ]),
      "goal": .object([
        "type": .string("string"), "minLength": .integer(1), "maxLength": .integer(2_048),
      ]),
      "intake": .object(["type": .string("string"), "maxLength": .integer(4_096)]),
      "crashSignature": .object([
        "type": .string("string"), "maxLength": .integer(512),
      ]),
      "bundleName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "abilityName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "processName": .object(["type": .string("string"), "maxLength": .integer(200)]),
      "baselineHapArtifactLease": .object([
        "type": .string("string"), "maxLength": .integer(384),
      ]),
      "projectRef": .object(["type": .string("string"), "maxLength": .integer(128)]),
      "baseWorkspaceRevision": .object([
        "type": .string("string"), "pattern": .string("^[a-f0-9]{64}$"),
      ]),
      "workspaceAllowedPaths": .object([
        "type": .string("array"), "minItems": .integer(1), "maxItems": .integer(32),
        "items": .object(["type": .string("string"), "maxLength": .integer(256)]),
      ]),
      "buildPresetRef": .object([
        "type": .string("string"), "maxLength": .integer(128),
      ]),
      "testPresetRef": .object([
        "type": .string("string"), "maxLength": .integer(128),
      ]),
      "deviceProfile": .object([
        "type": .string("string"), "maxLength": .integer(128),
      ]),
      "component": .object(["type": .string("string"), "maxLength": .integer(256)]),
      "maxRounds": integerSchema(minimum: 1, maximum: 32),
      "maxWallClockSeconds": integerSchema(minimum: 60, maximum: 7_200),
      "maxE1Mutations": integerSchema(minimum: 0, maximum: 16),
      "maxModelCalls": integerSchema(minimum: 0, maximum: 64),
      "maxAttempts": integerSchema(minimum: 1, maximum: 8),
      "maxChangedFiles": integerSchema(minimum: 1, maximum: 50),
      "maxDiffLines": integerSchema(minimum: 1, maximum: 5_000),
      "expectedBindingRevision": integerSchema(minimum: 1, maximum: Int.max),
    ], required: ["targetRef", "goal"])

  private static func integerSchema(minimum: Int, maximum: Int) -> JSONValue {
    .object([
      "type": .string("integer"),
      "minimum": .integer(Int64(minimum)),
      "maximum": .integer(Int64(maximum)),
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
