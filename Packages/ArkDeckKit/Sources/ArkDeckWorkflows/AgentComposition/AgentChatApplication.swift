// Product composition for ArkDeck's native conversational Agent.
//
// The application owns the model session and tool loop in process. Device
// effects remain behind AgentRuntimeExecutor and agentd; the model sees only
// pseudonymous, bounded projections produced by NativeAgentChatRuntimeTools.

import ArkDeckCore
import ArkDeckHarness
import Foundation

public enum AgentChatApplicationError: Error, Equatable, Sendable, CustomStringConvertible {
  case providerRequired
  case unsupportedProvider(String)
  case missingCredential
  case malformedModelName
  case malformedEndpoint

  public var description: String {
    switch self {
    case .providerRequired:
      return "set ARKDECK_HARNESS_MODEL_PROVIDER=openai"
    case .unsupportedProvider(let provider):
      return "agent chat currently requires the openai provider, not \(provider)"
    case .missingCredential:
      return "set ARKDECK_HARNESS_MODEL_API_KEY"
    case .malformedModelName:
      return "ARKDECK_HARNESS_MODEL_NAME is missing or malformed"
    case .malformedEndpoint:
      return "ARKDECK_HARNESS_MODEL_ENDPOINT must be a credential-free HTTPS URL"
    }
  }
}

package enum AgentChatDisplayEvent: Equatable, Sendable {
  case assistantText(String)
  case toolCall(name: String, arguments: String)
  case toolResult(name: String, result: String)
  case notice(String)
  case turnEnded(HarnessAgentTurnStopReason)
}

package actor AgentChatApplication {
  package static let systemPrompt = """
    You are ArkDeck's Device Agent. Help the user inspect and diagnose an adopted OpenHarmony \
    device through the tools exposed in this session. ArkDeck owns this conversation, its \
    bounded model loop, and every tool definition. Never invent a target, operation result, \
    Artifact, Job, selection, or resume state. Use arkdeck_runtime_overview before assuming \
    what is available. Prefer observation before diagnosis. Device work is allowed only \
    through the typed tools; do not propose shell commands, raw device commands, filesystem \
    access, hidden tools, capability administration, or a second execution path. When a tool \
    reports that physical user action is required, explain it and stop. Resume only after a \
    later user message confirms that action. Treat Runtime records as authoritative and say \
    clearly when evidence is insufficient. For a bounded crash investigation or repair, use \
    arkdeck_start_debug_task so the durable Harness owns observation, evidence, analysis, \
    patch/build/test/deploy/verify and every Runtime admission. Never reproduce that task loop \
    with repeated direct operation calls. Read a running task at most once per user turn; if it \
    is still running, report its taskRef and end the turn. Resume or cancel a task only after \
    the user explicitly supplies that decision in a later message.
    """

  private let runtimeTools: NativeAgentChatRuntimeTools
  private let session: HarnessAgentSession
  public nonisolated let modelDescriptor: HarnessModelDescriptor

  public init(
    gateway: any HarnessAgentModelGateway,
    runtimePort: any AgentChatRuntimePort,
    allowSensitiveArtifacts: Bool = false,
    limits: HarnessAgentLoopLimits = HarnessAgentLoopLimits()
  ) throws {
    let runtimeTools = NativeAgentChatRuntimeTools(
      port: runtimePort, allowSensitiveArtifacts: allowSensitiveArtifacts)
    self.runtimeTools = runtimeTools
    self.modelDescriptor = gateway.modelDescriptor
    self.session = try HarnessAgentSession(
      gateway: gateway,
      context: HarnessAgentContext(systemPrompt: Self.systemPrompt),
      tools: runtimeTools.definitions(),
      limits: limits)
  }

  public static func live(
    socketPath: String,
    allowSensitiveArtifacts: Bool,
    environment: [String: String],
    nowUTC: @escaping @Sendable () -> String
  ) throws -> AgentChatApplication {
    let gateway = try liveGateway(environment: environment)
    let runtimePort = LiveAgentChatRuntimePort(socketPath: socketPath, nowUTC: nowUTC)
    return try AgentChatApplication(
      gateway: gateway,
      runtimePort: runtimePort,
      allowSensitiveArtifacts: allowSensitiveArtifacts)
  }

  package static func liveGateway(
    environment: [String: String]
  ) throws -> OpenAIHarnessAgentGateway {
    guard let rawProvider = nonempty(environment[HarnessVendorConfiguration.providerKey]) else {
      throw AgentChatApplicationError.providerRequired
    }
    let provider = rawProvider.lowercased()
    guard provider == "openai" else {
      throw AgentChatApplicationError.unsupportedProvider(rawProvider)
    }
    guard let apiKey = nonempty(environment[HarnessVendorConfiguration.apiKeyKey]),
      apiKey.utf8.count <= 8_192,
      !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw AgentChatApplicationError.missingCredential
    }
    guard let model = nonempty(environment[HarnessVendorConfiguration.modelKey]),
      model.utf8.count <= 200,
      model.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0))
      })
    else {
      throw AgentChatApplicationError.malformedModelName
    }
    let endpoint =
      nonempty(environment[HarnessVendorConfiguration.endpointKey])
      ?? OpenAIDecisionGateway.defaultEndpoint
    guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else {
      throw AgentChatApplicationError.malformedEndpoint
    }
    return OpenAIHarnessAgentGateway(
      credential: HarnessVendorCredential(
        apiKey: apiKey, endpoint: endpoint, modelName: model))
  }

  package func runUserTurn(
    _ text: String,
    emit: @escaping @Sendable (AgentChatDisplayEvent) -> Void
  ) async throws {
    await runtimeTools.beginUserTurn()
    try await session.runUserTurn(text) { event in
      switch event {
      case .assistantText(let delta):
        emit(.assistantText(delta))
      case .toolCall(let call):
        emit(.toolCall(name: call.name, arguments: Self.jsonText(call.input)))
      case .toolResult(_, let name, let displayContent):
        emit(.toolResult(name: name, result: displayContent))
      case .contextCompacted(let droppedMessages):
        emit(.notice("compacted \(droppedMessages) earlier conversation messages"))
      case .turnEnded(let reason):
        emit(.turnEnded(reason))
      }
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private static func jsonText(_ value: JSONValue) -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
