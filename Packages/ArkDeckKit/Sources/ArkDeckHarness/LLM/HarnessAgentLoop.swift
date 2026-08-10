// Native conversational Agent core.
//
// This layer owns only model/context/tool-call orchestration. A tool is a
// typed closure supplied by the composition root; this target still cannot
// spawn a process or reach device transport. Runtime admission, durable Job
// state and effect execution remain outside the loop.

import ArkDeckCore
import Foundation

public enum HarnessAgentMessageRole: String, Codable, Sendable {
  case user
  case assistant
  case tool
}

public struct HarnessAgentToolCall: Equatable, Sendable, Codable {
  public let id: String
  public let name: String
  public let input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

public struct HarnessAgentMessage: Equatable, Sendable, Codable {
  public let role: HarnessAgentMessageRole
  public let text: String?
  public let toolCalls: [HarnessAgentToolCall]
  public let toolCallID: String?

  public init(
    role: HarnessAgentMessageRole,
    text: String? = nil,
    toolCalls: [HarnessAgentToolCall] = [],
    toolCallID: String? = nil
  ) {
    self.role = role
    self.text = text
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  public static func user(_ text: String) -> HarnessAgentMessage {
    HarnessAgentMessage(role: .user, text: text)
  }

  public static func assistant(
    _ text: String, toolCalls: [HarnessAgentToolCall]
  ) -> HarnessAgentMessage {
    HarnessAgentMessage(
      role: .assistant, text: text.isEmpty ? nil : text,
      toolCalls: toolCalls)
  }

  public static func tool(id: String, content: String) -> HarnessAgentMessage {
    HarnessAgentMessage(role: .tool, text: content, toolCallID: id)
  }
}

public struct HarnessAgentContext: Equatable, Sendable, Codable {
  public let systemPrompt: String
  public var messages: [HarnessAgentMessage]

  public init(systemPrompt: String, messages: [HarnessAgentMessage] = []) {
    self.systemPrompt = systemPrompt
    self.messages = messages
  }

  public var encodedByteCount: Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return ((try? encoder.encode(self)) ?? Data()).count
  }

  /// Deterministic context compaction. Execution state never lives in this
  /// transcript, so older conversational turns may be dropped without
  /// changing Runtime authority or recovery. We cut only at a user-message
  /// boundary, preserving every assistant tool_call/tool result pairing in
  /// the retained suffix. What was removed is stated explicitly.
  public mutating func compacted(
    maximumMessages: Int,
    maximumEncodedBytes: Int
  ) throws -> Int {
    guard messages.count > maximumMessages || encodedByteCount > maximumEncodedBytes else {
      return 0
    }

    let originalCount = messages.count
    var start = max(0, messages.count - maximumMessages)
    while start < messages.count, messages[start].role != .user { start += 1 }
    if start == messages.count { start = 0 }

    var retained = Array(messages.dropFirst(start))
    var dropped = start
    if dropped > 0 {
      retained.insert(
        .user(
          "[conversation context compacted: \(dropped) earlier messages omitted; "
            + "ArkDeck Runtime records remain authoritative]"),
        at: 0)
    }

    func encodedSize(_ candidate: [HarnessAgentMessage]) -> Int {
      let value = HarnessAgentContext(systemPrompt: systemPrompt, messages: candidate)
      return value.encodedByteCount
    }

    while (retained.count > maximumMessages || encodedSize(retained) > maximumEncodedBytes),
      retained.count > 2
    {
      let searchStart = retained[0].text?.hasPrefix("[conversation context compacted:") == true
        ? 1 : 0
      guard let nextUser = retained.indices.dropFirst(searchStart + 1).first(where: {
        retained[$0].role == .user
      }) else { break }
      dropped += nextUser - searchStart
      retained.removeSubrange(searchStart..<nextUser)
      if searchStart == 0 {
        retained.insert(
          .user(
            "[conversation context compacted: \(dropped) earlier messages omitted; "
              + "ArkDeck Runtime records remain authoritative]"),
          at: 0)
      } else {
        retained[0] = .user(
          "[conversation context compacted: \(dropped) earlier messages omitted; "
            + "ArkDeck Runtime records remain authoritative]")
      }
    }

    guard retained.count <= maximumMessages,
      encodedSize(retained) <= maximumEncodedBytes
    else {
      throw HarnessAgentSessionError.contextTooLarge(
        bytes: encodedSize(retained), limit: maximumEncodedBytes)
    }
    messages = retained
    return max(dropped, originalCount - retained.count)
  }
}

public struct HarnessAgentToolResult: Equatable, Sendable {
  /// Bounded content sent back to the model.
  public let modelContent: String
  /// Smaller projection suitable for a terminal or UI event.
  public let displayContent: String

  public init(modelContent: String, displayContent: String) {
    self.modelContent = modelContent
    self.displayContent = displayContent
  }
}

public struct HarnessAgentTool: Sendable {
  public let name: String
  public let description: String
  public let parameters: JSONValue
  private let executeBody:
    @Sendable (_ input: JSONValue) async throws -> HarnessAgentToolResult

  public init(
    name: String,
    description: String,
    parameters: JSONValue,
    execute: @escaping @Sendable (_ input: JSONValue) async throws
      -> HarnessAgentToolResult
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.executeBody = execute
  }

  public func execute(_ input: JSONValue) async throws -> HarnessAgentToolResult {
    try await executeBody(input)
  }
}

public enum HarnessAgentModelStopReason: String, Equatable, Sendable, Codable {
  case endTurn
  case toolUse
  case maxTokens
}

public enum HarnessAgentModelEvent: Equatable, Sendable {
  case textDelta(String)
  case toolCall(HarnessAgentToolCall)
  case completed(HarnessAgentModelStopReason)
}

public protocol HarnessAgentModelGateway: Sendable {
  var modelDescriptor: HarnessModelDescriptor { get }
  func stream(
    context: HarnessAgentContext,
    tools: [HarnessAgentTool]
  ) -> AsyncThrowingStream<HarnessAgentModelEvent, Error>
}

public enum HarnessAgentTurnStopReason: String, Equatable, Sendable, Codable {
  case endTurn
  case maxTokens
  case aborted
  case error
  case budgetExhausted
}

public enum HarnessAgentEvent: Equatable, Sendable {
  case assistantText(String)
  case toolCall(HarnessAgentToolCall)
  case toolResult(id: String, name: String, displayContent: String)
  case contextCompacted(droppedMessages: Int)
  case turnEnded(HarnessAgentTurnStopReason)
}

public struct HarnessAgentLoopLimits: Equatable, Sendable {
  public let maximumModelCalls: Int
  public let maximumToolCalls: Int
  public let maximumMessages: Int
  public let maximumContextBytes: Int
  public let maximumAssistantBytes: Int
  public let maximumToolResultBytes: Int

  public init(
    maximumModelCalls: Int = 24,
    maximumToolCalls: Int = 8,
    maximumMessages: Int = 64,
    maximumContextBytes: Int = 512 * 1_024,
    maximumAssistantBytes: Int = 128 * 1_024,
    maximumToolResultBytes: Int = 256 * 1_024
  ) {
    self.maximumModelCalls = max(1, maximumModelCalls)
    self.maximumToolCalls = max(1, maximumToolCalls)
    self.maximumMessages = max(4, maximumMessages)
    self.maximumContextBytes = max(4_096, maximumContextBytes)
    self.maximumAssistantBytes = max(1_024, maximumAssistantBytes)
    self.maximumToolResultBytes = max(1_024, maximumToolResultBytes)
  }
}

public enum HarnessAgentSessionError: Error, Equatable, Sendable {
  case duplicateTool(String)
  case emptyUserMessage
  case contextTooLarge(bytes: Int, limit: Int)
  case modelStreamEndedWithoutCompletion
  case modelStreamCompletedTwice
  case inconsistentModelCompletion
  case assistantOutputTooLarge(bytes: Int, limit: Int)
}

public actor HarnessAgentSession {
  public let modelDescriptor: HarnessModelDescriptor

  private let gateway: any HarnessAgentModelGateway
  private let tools: [HarnessAgentTool]
  private let toolMap: [String: HarnessAgentTool]
  private let limits: HarnessAgentLoopLimits
  private var context: HarnessAgentContext
  private var modelCalls = 0
  private var toolCalls = 0

  public init(
    gateway: any HarnessAgentModelGateway,
    context: HarnessAgentContext,
    tools: [HarnessAgentTool],
    limits: HarnessAgentLoopLimits = HarnessAgentLoopLimits()
  ) throws {
    var mapped: [String: HarnessAgentTool] = [:]
    for tool in tools {
      guard mapped[tool.name] == nil else {
        throw HarnessAgentSessionError.duplicateTool(tool.name)
      }
      mapped[tool.name] = tool
    }
    self.gateway = gateway
    self.modelDescriptor = gateway.modelDescriptor
    self.context = context
    self.tools = tools
    self.toolMap = mapped
    self.limits = limits
  }

  public func snapshot() -> HarnessAgentContext { context }

  public func consumedBudget() -> (modelCalls: Int, toolCalls: Int) {
    (modelCalls, toolCalls)
  }

  public func runUserTurn(
    _ rawText: String,
    emit: @escaping @Sendable (HarnessAgentEvent) -> Void
  ) async throws {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw HarnessAgentSessionError.emptyUserMessage }
    context.messages.append(.user(text))

    while true {
      if Task.isCancelled {
        emit(.turnEnded(.aborted))
        return
      }
      if modelCalls >= limits.maximumModelCalls {
        emit(.turnEnded(.budgetExhausted))
        return
      }
      let dropped = try context.compacted(
        maximumMessages: limits.maximumMessages,
        maximumEncodedBytes: limits.maximumContextBytes)
      if dropped > 0 { emit(.contextCompacted(droppedMessages: dropped)) }

      modelCalls += 1
      var assistantText = ""
      var proposedCalls: [HarnessAgentToolCall] = []
      var completion: HarnessAgentModelStopReason?
      do {
        let advertisedTools = toolCalls >= limits.maximumToolCalls ? [] : tools
        var assistantBytes = 0
        for try await event in gateway.stream(context: context, tools: advertisedTools) {
          if Task.isCancelled {
            context.messages.append(.assistant(assistantText, toolCalls: []))
            emit(.turnEnded(.aborted))
            return
          }
          switch event {
          case .textDelta(let delta):
            assistantBytes += delta.utf8.count
            guard assistantBytes <= limits.maximumAssistantBytes else {
              throw HarnessAgentSessionError.assistantOutputTooLarge(
                bytes: assistantBytes, limit: limits.maximumAssistantBytes)
            }
            assistantText += delta
            emit(.assistantText(delta))
          case .toolCall(let call):
            proposedCalls.append(call)
            emit(.toolCall(call))
          case .completed(let reason):
            guard completion == nil else {
              throw HarnessAgentSessionError.modelStreamCompletedTwice
            }
            completion = reason
          }
        }
      } catch is CancellationError {
        context.messages.append(.assistant(assistantText, toolCalls: []))
        emit(.turnEnded(.aborted))
        return
      } catch {
        context.messages.append(.assistant(assistantText, toolCalls: []))
        emit(.turnEnded(.error))
        throw error
      }

      guard let completion else {
        context.messages.append(.assistant(assistantText, toolCalls: []))
        emit(.turnEnded(.error))
        throw HarnessAgentSessionError.modelStreamEndedWithoutCompletion
      }
      if (completion == .toolUse && proposedCalls.isEmpty)
        || (completion == .endTurn && !proposedCalls.isEmpty)
      {
        context.messages.append(.assistant(assistantText, toolCalls: []))
        emit(.turnEnded(.error))
        throw HarnessAgentSessionError.inconsistentModelCompletion
      }
      context.messages.append(.assistant(assistantText, toolCalls: proposedCalls))

      if completion == .maxTokens, !proposedCalls.isEmpty {
        for call in proposedCalls {
          let result =
            "error: model output reached max_tokens; tool arguments were not executed"
          context.messages.append(.tool(id: call.id, content: result))
          emit(.toolResult(id: call.id, name: call.name, displayContent: result))
        }
        continue
      }

      if proposedCalls.isEmpty {
        emit(.turnEnded(completion == .maxTokens ? .maxTokens : .endTurn))
        return
      }

      var rejectedForBudget = false
      for call in proposedCalls {
        let modelResult: String
        let displayResult: String
        if Task.isCancelled {
          modelResult = "error: aborted"
          displayResult = modelResult
        } else if toolCalls >= limits.maximumToolCalls {
          modelResult = "error: ArkDeck Agent tool-call budget exhausted"
          displayResult = modelResult
          rejectedForBudget = true
        } else if case .object = call.input {
          toolCalls += 1
          if let tool = toolMap[call.name] {
            do {
              let result = try await tool.execute(call.input)
              if result.modelContent.utf8.count > limits.maximumToolResultBytes {
                modelResult =
                  "error: tool result exceeded ArkDeck's bounded model-context limit"
                displayResult = modelResult
              } else {
                modelResult = result.modelContent
                displayResult = Self.boundedDisplay(result.displayContent)
              }
            } catch {
              modelResult = "error: \(String(describing: error))"
              displayResult = modelResult
            }
          } else {
            modelResult = "error: tool \(call.name) is not available"
            displayResult = modelResult
          }
        } else {
          modelResult = "error: tool arguments must be one JSON object"
          displayResult = modelResult
        }
        context.messages.append(.tool(id: call.id, content: modelResult))
        emit(.toolResult(id: call.id, name: call.name, displayContent: displayResult))
      }
      if rejectedForBudget {
        emit(.turnEnded(.budgetExhausted))
        return
      }
    }
  }

  private static func boundedDisplay(_ text: String) -> String {
    let maximumBytes = 4_096
    guard text.utf8.count > maximumBytes else { return text }
    return String(decoding: text.utf8.prefix(maximumBytes), as: UTF8.self)
      + "… [terminal projection truncated]"
  }
}
