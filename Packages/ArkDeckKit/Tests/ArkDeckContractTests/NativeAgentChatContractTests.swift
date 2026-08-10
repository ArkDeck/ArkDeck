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
