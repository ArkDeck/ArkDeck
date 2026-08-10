import ArkDeckAgentClient
import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCLI
@testable import ArkDeckHarness

final class NativeAgentChatContractTests: XCTestCase {
  func testNativeLoopExecutesTypedToolAndReturnsItsResultToTheModel() async throws {
    let gateway = ScriptedAgentModelGateway(scripts: [
      [
        .textDelta("Checking Runtime. "),
        .toolCall(
          HarnessAgentToolCall(
            id: "call-1", name: "runtime_overview", input: .object([:]))),
        .completed(.toolUse),
      ],
      [.textDelta("The Runtime is healthy."), .completed(.endTurn)],
    ])
    let probe = AgentToolProbe()
    let tool = HarnessAgentTool(
      name: "runtime_overview", description: "overview",
      parameters: .object(["type": .string("object")])
    ) { arguments in
      await probe.record(arguments)
      return HarnessAgentToolResult(
        modelContent: #"{"healthy":true}"#,
        displayContent: "Runtime overview updated")
    }
    let session = try HarnessAgentSession(
      gateway: gateway,
      context: HarnessAgentContext(systemPrompt: "bounded"),
      tools: [tool])
    let events = LockedAgentEvents()

    try await session.runUserTurn("Check the device") { events.append($0) }

    let executions = await probe.values
    XCTAssertEqual(executions, [.object([:])])
    let contexts = gateway.capturedContexts
    XCTAssertEqual(contexts.count, 2)
    XCTAssertEqual(contexts[1].messages.map(\.role), [.user, .assistant, .tool])
    XCTAssertEqual(contexts[1].messages.last?.toolCallID, "call-1")
    XCTAssertEqual(contexts[1].messages.last?.text, #"{"healthy":true}"#)
    XCTAssertTrue(events.values.contains(.turnEnded(.endTurn)))
  }

  func testConversationCanTurnAUserGoalIntoOneDurableHarnessTask() async throws {
    let exactTarget = "device-target-secret"
    let targetRef = HarnessDecisionContext.pseudonym(forTargetID: exactTarget)
    let port = TaskBridgeRuntimePort(
      targetID: exactTarget, taskID: "HTASK-CONVERSATION01", lifecycle: "running")
    let gateway = ScriptedAgentModelGateway(scripts: [
      [
        .toolCall(
          HarnessAgentToolCall(
            id: "overview", name: "arkdeck_runtime_overview", input: .object([:]))),
        .completed(.toolUse),
      ],
      [
        .toolCall(
          HarnessAgentToolCall(
            id: "start", name: "arkdeck_start_debug_task",
            input: .object([
              "targetRef": .string(targetRef),
              "goal": .string("Investigate the launch crash"),
            ]))),
        .completed(.toolUse),
      ],
      [.textDelta("The durable debug task is running."), .completed(.endTurn)],
    ])
    let application = try AgentChatApplication(
      gateway: gateway, runtimePort: port,
      limits: HarnessAgentLoopLimits(maximumModelCalls: 3, maximumToolCalls: 2))

    try await application.runUserTurn("帮我排查这个应用为什么启动崩溃") { _ in }

    let submit = try XCTUnwrap(port.capturedRequests.first { $0.method == "task.submit" })
    XCTAssertEqual(submit.params?["targetId"], .string(exactTarget))
    XCTAssertEqual(submit.params?["goal"], .string("Investigate the launch crash"))
    XCTAssertEqual(
      gateway.capturedContexts.last?.messages.map(\.role),
      [.user, .assistant, .tool, .assistant, .tool])
  }

  func testMaxTokenToolArgumentsAreNeverExecuted() async throws {
    let gateway = ScriptedAgentModelGateway(scripts: [
      [
        .toolCall(
          HarnessAgentToolCall(
            id: "partial", name: "observe", input: .object([:]))),
        .completed(.maxTokens),
      ],
      [.textDelta("I could not safely complete that call."), .completed(.endTurn)],
    ])
    let probe = AgentToolProbe()
    let tool = HarnessAgentTool(
      name: "observe", description: "observe",
      parameters: .object(["type": .string("object")])
    ) { arguments in
      await probe.record(arguments)
      return HarnessAgentToolResult(modelContent: "unexpected", displayContent: "unexpected")
    }
    let session = try HarnessAgentSession(
      gateway: gateway,
      context: HarnessAgentContext(systemPrompt: "bounded"),
      tools: [tool])

    try await session.runUserTurn("Observe") { _ in }

    let executions = await probe.values
    XCTAssertTrue(executions.isEmpty)
    XCTAssertTrue(
      gateway.capturedContexts[1].messages.contains {
        $0.role == .tool && $0.text?.contains("not executed") == true
      })
  }

  func testLastAllowedToolResultGetsOneToolFreeSummaryCall() async throws {
    let gateway = ScriptedAgentModelGateway(scripts: [
      [
        .toolCall(
          HarnessAgentToolCall(id: "only", name: "observe", input: .object([:]))),
        .completed(.toolUse),
      ],
      [.textDelta("Observation complete."), .completed(.endTurn)],
    ])
    let tool = HarnessAgentTool(
      name: "observe", description: "observe",
      parameters: .object(["type": .string("object")])
    ) { _ in
      HarnessAgentToolResult(modelContent: "ok", displayContent: "ok")
    }
    let session = try HarnessAgentSession(
      gateway: gateway,
      context: HarnessAgentContext(systemPrompt: "bounded"),
      tools: [tool],
      limits: HarnessAgentLoopLimits(maximumToolCalls: 1))

    try await session.runUserTurn("Observe") { _ in }

    XCTAssertEqual(gateway.capturedToolNames, [["observe"], []])
  }

  func testModelAndToolBudgetsResetForEachUserTurn() async throws {
    let gateway = ScriptedAgentModelGateway(scripts: [
      [
        .toolCall(
          HarnessAgentToolCall(id: "first", name: "observe", input: .object([:]))),
        .completed(.toolUse),
      ],
      [.textDelta("First observation complete."), .completed(.endTurn)],
      [
        .toolCall(
          HarnessAgentToolCall(id: "second", name: "observe", input: .object([:]))),
        .completed(.toolUse),
      ],
      [.textDelta("Second observation complete."), .completed(.endTurn)],
    ])
    let probe = AgentToolProbe()
    let tool = HarnessAgentTool(
      name: "observe", description: "observe",
      parameters: .object(["type": .string("object")])
    ) { arguments in
      await probe.record(arguments)
      return HarnessAgentToolResult(modelContent: "ok", displayContent: "ok")
    }
    let session = try HarnessAgentSession(
      gateway: gateway,
      context: HarnessAgentContext(systemPrompt: "bounded"),
      tools: [tool],
      limits: HarnessAgentLoopLimits(maximumModelCalls: 2, maximumToolCalls: 1))

    try await session.runUserTurn("Observe once") { _ in }
    try await session.runUserTurn("Observe again") { _ in }

    let executions = await probe.values
    XCTAssertEqual(executions.count, 2)
    XCTAssertEqual(gateway.capturedToolNames, [["observe"], [], ["observe"], []])
    let consumed = await session.consumedBudget()
    XCTAssertEqual(consumed.modelCalls, 4)
    XCTAssertEqual(consumed.toolCalls, 2)
  }

  func testStreamingDecoderAccumulatesArgumentsBeforePublishingAToolCall() throws {
    var decoder = OpenAIHarnessAgentSSEDecoder()
    let first = try decoder.consume(
      line:
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"arkdeck_runtime_","arguments":"{"}}]},"finish_reason":null}]}"#)
    let second = try decoder.consume(
      line:
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"overview","arguments":"}"}}]},"finish_reason":null}]}"#)
    let completed = try decoder.consume(
      line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)

    XCTAssertTrue(first.isEmpty)
    XCTAssertTrue(second.isEmpty)
    XCTAssertEqual(
      completed,
      [
        .toolCall(
          HarnessAgentToolCall(
            id: "call-1", name: "arkdeck_runtime_overview", input: .object([:]))),
        .completed(.toolUse),
      ])
    XCTAssertNoThrow(try decoder.finish())
  }

  func testNativeRuntimeOverviewPseudonymizesIdentityAndRemovesSecrets() async throws {
    let exactTarget = "device-target-secret"
    let port = OverviewRuntimePort(targetID: exactTarget)
    let owner = NativeAgentChatRuntimeTools(port: port)
    let definitions = owner.definitions()

    XCTAssertEqual(definitions.map(\.name), NativeAgentChatRuntimeTools.activeToolNames)
    let overview = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_runtime_overview" })
    let result = try await overview.execute(.object([:]))

    XCTAssertTrue(result.modelContent.contains("target-"))
    XCTAssertFalse(result.modelContent.contains(exactTarget))
    XCTAssertFalse(result.modelContent.contains("serial-secret"))
    XCTAssertFalse(result.modelContent.contains("connect-secret"))
    XCTAssertFalse(result.modelContent.contains("stable-identity-secret"))
    XCTAssertFalse(result.modelContent.contains("/tmp/private-agentd.sock"))
    XCTAssertTrue(result.modelContent.contains(#""maxRounds":8"#))
    XCTAssertTrue(result.modelContent.contains(#""maxE1Mutations":0"#))
    XCTAssertTrue(result.modelContent.contains(#""stopOnOutcomeUnknown":true"#))
  }

  func testNativeToolsLowerOnlyToTheClosedReadOnlyOperations() async throws {
    let exactTarget = "device-target-secret"
    let port = CapturingRuntimePort(targetID: exactTarget)
    let owner = NativeAgentChatRuntimeTools(port: port)
    let definitions = owner.definitions()
    let overview = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_runtime_overview" })
    let observe = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_observe_device" })
    let capture = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_capture_diagnostics" })
    _ = try await overview.execute(.object([:]))
    let targetRef = HarnessDecisionContext.pseudonym(forTargetID: exactTarget)

    do {
      _ = try await observe.execute(.object(["targetRef": .string(targetRef)]))
      XCTFail("fake Runtime should stop after capturing the request")
    } catch {}
    do {
      _ = try await capture.execute(
        .object([
          "targetRef": .string(targetRef),
          "durationSeconds": .integer(10),
          "includeUIDump": .bool(true),
        ]))
      XCTFail("fake Runtime should stop after capturing the request")
    } catch {}

    let requests = port.capturedRuns
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].operationID, "observe.device")
    XCTAssertEqual(requests[0].operationVersion, 1)
    XCTAssertEqual(requests[0].targetID, exactTarget)
    XCTAssertTrue(requests[0].inputs.isEmpty)
    XCTAssertEqual(requests[1].operationID, "capture.diagnostics")
    XCTAssertEqual(requests[1].operationVersion, 1)
    XCTAssertEqual(requests[1].targetID, exactTarget)
    XCTAssertEqual(requests[1].inputs["redactionProfile"], .string("standard"))
    XCTAssertEqual(requests[1].inputs["uiDump"], .bool(true))
    XCTAssertNil(requests[1].inputs["traceCategories"])
    XCTAssertNil(requests[1].inputs["uiScreenshot"])
    XCTAssertTrue(requests.allSatisfy { $0.capabilityReference == nil })
  }

  func testChatStartsOneDurableDebugTaskThroughFixedTypedRequest() async throws {
    let exactTarget = "device-target-secret"
    let exactTask = "HTASK-ABCDEF012345"
    let port = TaskBridgeRuntimePort(
      targetID: exactTarget, taskID: exactTask, lifecycle: "running")
    let owner = NativeAgentChatRuntimeTools(port: port)
    let definitions = owner.definitions()
    let overview = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_runtime_overview" })
    let start = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_start_debug_task" })
    _ = try await overview.execute(.object([:]))
    let targetRef = HarnessDecisionContext.pseudonym(forTargetID: exactTarget)
    let revision = String(repeating: "a", count: 64)

    do {
      _ = try await start.execute(
        .object([
          "targetRef": .string(targetRef),
          "goal": .string("Invalid application scope"),
          "abilityName": .string("EntryAbility"),
        ]))
      XCTFail("application inputs must be validated before task.submit")
    } catch let error as AgentChatRuntimeToolError {
      guard case .invalidArguments = error else {
        return XCTFail("expected invalid arguments, got \(error)")
      }
    }
    XCTAssertFalse(port.capturedRequests.contains { $0.method == "task.submit" })

    let result = try await start.execute(
      .object([
        "targetRef": .string(targetRef),
        "goal": .string("Reproduce and fix the launch crash"),
        "bundleName": .string("com.example.demo"),
        "projectRef": .string("project-secret"),
        "baseWorkspaceRevision": .string(revision),
        "workspaceAllowedPaths": .array([.string("Sources/**")]),
        "buildPresetRef": .string("debug-build"),
        "testPresetRef": .string("unit-tests"),
        "maxE1Mutations": .integer(3),
        "maxAttempts": .integer(2),
      ]))

    let submit = try XCTUnwrap(port.capturedRequests.first { $0.method == "task.submit" })
    XCTAssertEqual(submit.params?["targetId"], .string(exactTarget))
    XCTAssertEqual(submit.params?["goal"], .string("Reproduce and fix the launch crash"))
    XCTAssertEqual(submit.params?["projectRef"], .string("project-secret"))
    XCTAssertEqual(submit.params?["baseWorkspaceRevision"], .string(revision))
    XCTAssertEqual(submit.params?["workspaceAllowedPaths"], .array([.string("Sources/**")]))
    XCTAssertEqual(submit.params?["maxE1Mutations"], .integer(3))
    XCTAssertTrue(result.modelContent.contains(#""taskRef":"task-"#))
    XCTAssertFalse(result.modelContent.contains(exactTask))
    XCTAssertFalse(result.modelContent.contains("project-secret"))
    XCTAssertFalse(result.modelContent.contains("/private/workspaces/secret"))

    do {
      _ = try await start.execute(
        .object([
          "targetRef": .string(targetRef),
          "goal": .string("Start a duplicate task"),
        ]))
      XCTFail("a chat must not submit a second durable task")
    } catch let error as AgentChatRuntimeToolError {
      guard case .blocked = error else {
        return XCTFail("expected a bounded block, got \(error)")
      }
    }
    XCTAssertEqual(port.capturedRequests.filter { $0.method == "task.submit" }.count, 1)
  }

  func testDebugTaskCanResumeOnlyOnALaterUserTurnAndCanBeCancelled() async throws {
    let exactTask = "HTASK-PAUSED012345"
    let port = TaskBridgeRuntimePort(
      targetID: "device-target-secret", taskID: exactTask,
      lifecycle: "humanRequired")
    let owner = NativeAgentChatRuntimeTools(port: port)
    let definitions = owner.definitions()
    let overview = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_runtime_overview" })
    let status = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_debug_task_status" })
    let resume = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_resume_debug_task" })
    let cancel = try XCTUnwrap(
      definitions.first { $0.name == "arkdeck_cancel_debug_task" })
    let overviewResult = try await overview.execute(.object([:]))
    let taskRef = try taskReference(fromOverview: overviewResult.modelContent)
    let arguments: JSONValue = .object(["taskRef": .string(taskRef)])

    let statusResult = try await status.execute(arguments)
    XCTAssertTrue(statusResult.modelContent.contains(#""lifecycle":"humanRequired""#))
    XCTAssertTrue(statusResult.modelContent.contains(#""reasonCode":"physicalActionRequired""#))
    XCTAssertFalse(statusResult.modelContent.contains(exactTask))
    XCTAssertFalse(statusResult.modelContent.contains("human-action-document-secret"))

    do {
      _ = try await status.execute(arguments)
      XCTFail("the model must not poll one task repeatedly in one user turn")
    } catch let error as AgentChatRuntimeToolError {
      guard case .blocked = error else {
        return XCTFail("expected a bounded block, got \(error)")
      }
    }
    XCTAssertEqual(port.capturedRequests.filter { $0.method == "task.status" }.count, 1)

    do {
      _ = try await resume.execute(
        .object([
          "taskRef": .string(taskRef), "resolution": .string("Device is unlocked"),
        ]))
      XCTFail("the same user turn must not resume a newly observed pause")
    } catch let error as AgentChatRuntimeToolError {
      guard case .blocked = error else {
        return XCTFail("expected a bounded block, got \(error)")
      }
    }
    XCTAssertFalse(port.capturedRequests.contains { $0.method == "task.resume" })

    await owner.beginUserTurn()
    let resumed = try await resume.execute(
      .object([
        "taskRef": .string(taskRef), "resolution": .string("Device is unlocked"),
      ]))
    XCTAssertTrue(resumed.modelContent.contains(#""lifecycle":"running""#))
    let resumeRequest = try XCTUnwrap(
      port.capturedRequests.first { $0.method == "task.resume" })
    XCTAssertEqual(resumeRequest.params?["htaskId"], .string(exactTask))
    XCTAssertEqual(resumeRequest.params?["resolution"], .string("Device is unlocked"))

    let cancelled = try await cancel.execute(arguments)
    XCTAssertTrue(cancelled.modelContent.contains(#""lifecycle":"cancelled""#))
    XCTAssertEqual(
      port.capturedRequests.last { $0.method == "task.cancel" }?.params?["htaskId"],
      .string(exactTask))
  }

  func testNativeModelConfigurationIsExplicitAndHTTPSOnly() throws {
    XCTAssertThrowsError(try AgentChatApplication.liveGateway(environment: [:])) { error in
      XCTAssertEqual(error as? AgentChatApplicationError, .providerRequired)
    }
    XCTAssertThrowsError(
      try AgentChatApplication.liveGateway(environment: [
        HarnessVendorConfiguration.providerKey: "claude",
        HarnessVendorConfiguration.modelKey: "model",
        HarnessVendorConfiguration.apiKeyKey: "secret",
      ])) { error in
        XCTAssertEqual(error as? AgentChatApplicationError, .unsupportedProvider("claude"))
      }
    XCTAssertThrowsError(
      try AgentChatApplication.liveGateway(environment: [
        HarnessVendorConfiguration.providerKey: "openai",
        HarnessVendorConfiguration.modelKey: "model",
        HarnessVendorConfiguration.apiKeyKey: "secret",
        HarnessVendorConfiguration.endpointKey: "http://model.invalid/v1/chat/completions",
      ])) { error in
        XCTAssertEqual(error as? AgentChatApplicationError, .malformedEndpoint)
      }

    let gateway = try AgentChatApplication.liveGateway(environment: [
      HarnessVendorConfiguration.providerKey: "openai",
      HarnessVendorConfiguration.modelKey: "gpt-test",
      HarnessVendorConfiguration.apiKeyKey: "secret",
    ])
    XCTAssertEqual(gateway.modelDescriptor.modelName, "gpt-test")
  }

  func testChatOptionsHaveNoExternalAgentExecutionSurface() throws {
    let options = try AgentChatOptions.parse([
      "--socket", "/tmp/arkdeck-agentd.sock",
      "--prompt", "检查设备状态",
      "--allow-sensitive-artifacts",
    ])
    XCTAssertEqual(options.socketPath, "/tmp/arkdeck-agentd.sock")
    XCTAssertEqual(options.initialPrompt, "检查设备状态")
    XCTAssertTrue(options.allowSensitiveArtifacts)
    XCTAssertThrowsError(try AgentChatOptions.parse(["--pi-path", "/opt/pi"])) { error in
      XCTAssertTrue((error as? CLIError)?.message.contains("unsupported") == true)
    }
    XCTAssertThrowsError(try AgentChatOptions.parse(["--socket", "relative.sock"]))
    XCTAssertThrowsError(try AgentChatOptions.parse(["--prompt", "  "]))
  }
}

private final class ScriptedAgentModelGateway: HarnessAgentModelGateway, @unchecked Sendable {
  let modelDescriptor = HarnessModelDescriptor(
    provider: "test", modelName: "scripted", adapterVersion: "1")
  private let lock = NSLock()
  private var scripts: [[HarnessAgentModelEvent]]
  private var contexts: [HarnessAgentContext] = []
  private var toolNames: [[String]] = []

  init(scripts: [[HarnessAgentModelEvent]]) { self.scripts = scripts }

  var capturedContexts: [HarnessAgentContext] {
    lock.lock()
    defer { lock.unlock() }
    return contexts
  }

  var capturedToolNames: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return toolNames
  }

  func stream(
    context: HarnessAgentContext,
    tools: [HarnessAgentTool]
  ) -> AsyncThrowingStream<HarnessAgentModelEvent, Error> {
    lock.lock()
    contexts.append(context)
    toolNames.append(tools.map(\.name))
    let events = scripts.isEmpty ? [.completed(.endTurn)] : scripts.removeFirst()
    lock.unlock()
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

private actor AgentToolProbe {
  private(set) var values: [JSONValue] = []
  func record(_ value: JSONValue) { values.append(value) }
}

private final class LockedAgentEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [HarnessAgentEvent] = []

  var values: [HarnessAgentEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ event: HarnessAgentEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }
}

private enum OverviewRuntimePortError: Error { case unexpectedExecution }

private struct OverviewRuntimePort: AgentChatRuntimePort {
  let targetID: String

  func request(method: String, params: [String: JSONValue]?) throws -> JSONValue {
    switch method {
    case "doctor":
      return .object([
        "status": .string("ok"),
        "connectKey": .string("connect-secret"),
        "socketPath": .string("/tmp/private-agentd.sock"),
      ])
    case "operation.list":
      return .array([.object(["reference": .string("observe.device@1")])])
    case "target.list":
      return .array([
        .object([
          "targetId": .string(targetID),
          "serial": .string("serial-secret"),
          "stableIdentitySha256": .string("stable-identity-secret"),
          "bindingRevision": .integer(3),
        ])
      ])
    case "task.list":
      return .array([])
    default:
      throw OverviewRuntimePortError.unexpectedExecution
    }
  }

  func run(_ request: RuntimeAgentExecutionRequest) throws -> RuntimeAgentExecutionOutcome {
    throw OverviewRuntimePortError.unexpectedExecution
  }

  func resume(
    resumeToken: String, selection: String?
  ) throws -> RuntimeAgentExecutionOutcome {
    throw OverviewRuntimePortError.unexpectedExecution
  }
}

private func taskReference(fromOverview content: String) throws -> String {
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
  guard case .object(let fields) = value,
    case .array(let tasks)? = fields["debugTasks"],
    case .object(let task)? = tasks.first,
    case .string(let reference)? = task["taskRef"]
  else {
    throw OverviewRuntimePortError.unexpectedExecution
  }
  return reference
}

private final class TaskBridgeRuntimePort: AgentChatRuntimePort, @unchecked Sendable {
  struct CapturedRequest: Sendable {
    let method: String
    let params: [String: JSONValue]?
  }

  let targetID: String
  let taskID: String
  private let lock = NSLock()
  private var lifecycle: String
  private var requests: [CapturedRequest] = []

  init(targetID: String, taskID: String, lifecycle: String) {
    self.targetID = targetID
    self.taskID = taskID
    self.lifecycle = lifecycle
  }

  var capturedRequests: [CapturedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func request(method: String, params: [String: JSONValue]?) throws -> JSONValue {
    lock.lock()
    defer { lock.unlock() }
    requests.append(CapturedRequest(method: method, params: params))
    switch method {
    case "doctor":
      return .object(["status": .string("ok")])
    case "operation.list":
      return .array([.object(["reference": .string("observe.device@1")])])
    case "target.list":
      return .array([
        .object([
          "targetId": .string(targetID),
          "bindingRevision": .integer(7),
        ])
      ])
    case "task.list":
      return .array([taskValueLocked()])
    case "task.submit", "task.status":
      return taskValueLocked()
    case "task.humanActions":
      guard lifecycle == "humanRequired" else { return .array([]) }
      return .array([
        .object([
          "htaskId": .string(taskID),
          "block": .string("environmentUnavailable"),
          "reasonCode": .string("physicalActionRequired"),
          "round": .integer(1),
          "resumeStatus": .string("running"),
          "resumePhase": .string("analyzing"),
          "evidenceRefs": .array([]),
          "generatedAtUtc": .string("2026-08-10T00:00:00Z"),
          "resolvedAtUtc": .null,
          "document": .string("human-action-document-secret"),
        ])
      ])
    case "task.resume":
      lifecycle = "running"
      return taskValueLocked()
    case "task.cancel":
      lifecycle = "cancelled"
      return taskValueLocked()
    default:
      throw OverviewRuntimePortError.unexpectedExecution
    }
  }

  func run(_ request: RuntimeAgentExecutionRequest) throws -> RuntimeAgentExecutionOutcome {
    throw OverviewRuntimePortError.unexpectedExecution
  }

  func resume(
    resumeToken: String, selection: String?
  ) throws -> RuntimeAgentExecutionOutcome {
    throw OverviewRuntimePortError.unexpectedExecution
  }

  private func taskValueLocked() -> JSONValue {
    .object([
      "htaskId": .string(taskID),
      "type": .string("debug"),
      "lifecycle": .string(lifecycle),
      "stage": .string(lifecycle == "humanRequired" ? "waiting" : "analyzing"),
      "status": .string(lifecycle),
      "phase": .string("analyzing"),
      "projectRef": .string("project-secret"),
      "evolutionWorkspace": .object([
        "path": .string("/private/workspaces/secret")
      ]),
      "budgets": .object([
        "maxRounds": .integer(8), "maxE1Mutations": .integer(3),
      ]),
      "consumedBudget": .object([
        "rounds": .integer(1), "e1Mutations": .integer(0),
      ]),
      "allowedOperations": .array([.string("observe.device@1")]),
      "result": .object(["origin": .string(taskID)]),
      "updatedAtUtc": .string("2026-08-10T00:00:00Z"),
    ])
  }
}

private final class CapturingRuntimePort: AgentChatRuntimePort, @unchecked Sendable {
  let targetID: String
  private let lock = NSLock()
  private var runs: [RuntimeAgentExecutionRequest] = []

  init(targetID: String) { self.targetID = targetID }

  var capturedRuns: [RuntimeAgentExecutionRequest] {
    lock.lock()
    defer { lock.unlock() }
    return runs
  }

  func request(method: String, params: [String: JSONValue]?) throws -> JSONValue {
    try OverviewRuntimePort(targetID: targetID).request(method: method, params: params)
  }

  func run(_ request: RuntimeAgentExecutionRequest) throws -> RuntimeAgentExecutionOutcome {
    lock.lock()
    runs.append(request)
    lock.unlock()
    throw OverviewRuntimePortError.unexpectedExecution
  }

  func resume(
    resumeToken: String, selection: String?
  ) throws -> RuntimeAgentExecutionOutcome {
    throw OverviewRuntimePortError.unexpectedExecution
  }
}
