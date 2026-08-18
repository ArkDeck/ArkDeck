// OpenAI-compatible streaming adapter for the native conversational Agent.
//
// Provider bytes are normalized into HarnessAgentModelEvent. Tool argument
// fragments are accumulated and strictly decoded before any tool_call event
// reaches the Agent loop; malformed or incomplete JSON is never executable.

import ArkDeckCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum HarnessAgentGatewayError: Error, Equatable, Sendable {
  case endpointMustBeHTTPS
  case transportFailed
  case httpStatus(Int)
  case malformedEvent
  case malformedToolArguments(String)
  case incompleteToolCall
  case tooManyToolCalls
  case streamedEventTooLarge
  case toolArgumentsTooLarge
  case unsupportedStopReason(String)
  case streamEndedWithoutStopReason
}

/// Credentials are held only by the chat gateway and never serialized into
/// model context, Runtime records, or tool results.
package struct AgentVendorCredential: Sendable {
  package let apiKey: String
  package let endpoint: String
  package let modelName: String

  package init(apiKey: String, endpoint: String, modelName: String) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.modelName = modelName
  }
}

package struct OpenAIHarnessAgentGateway: HarnessAgentModelGateway {
  package static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"

  private let credential: AgentVendorCredential
  private let maximumOutputTokens: Int

  public init(
    credential: AgentVendorCredential,
    maximumOutputTokens: Int = 4_096
  ) {
    self.credential = credential
    self.maximumOutputTokens = max(256, maximumOutputTokens)
  }

  package var modelDescriptor: AgentModelDescriptor {
    AgentModelDescriptor(
      provider: "openai-compatible", modelName: credential.modelName,
      adapterVersion: "openai-agent-stream@1")
  }

  public func stream(
    context: HarnessAgentContext,
    tools: [HarnessAgentTool]
  ) -> AsyncThrowingStream<HarnessAgentModelEvent, Error> {
    let credential = credential
    let maximumOutputTokens = maximumOutputTokens
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let url = URL(string: credential.endpoint), url.scheme == "https" else {
            throw HarnessAgentGatewayError.endpointMustBeHTTPS
          }
          var request = URLRequest(url: url, timeoutInterval: 120)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "content-type")
          request.setValue(
            "Bearer \(credential.apiKey)", forHTTPHeaderField: "authorization")
          request.httpBody = try Self.requestBody(
            model: credential.modelName,
            maximumOutputTokens: maximumOutputTokens,
            context: context,
            tools: tools)

          let (bytes, response): (URLSession.AsyncBytes, URLResponse)
          do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw HarnessAgentGatewayError.transportFailed
          }
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          guard (200..<300).contains(status) else {
            throw HarnessAgentGatewayError.httpStatus(status)
          }

          var decoder = OpenAIHarnessAgentSSEDecoder()
          for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try decoder.consume(line: line) {
              continuation.yield(event)
            }
          }
          try decoder.finish()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private static func requestBody(
    model: String,
    maximumOutputTokens: Int,
    context: HarnessAgentContext,
    tools: [HarnessAgentTool]
  ) throws -> Data {
    var messages: [JSONValue] = [
      .object([
        "role": .string("system"),
        "content": .string(context.systemPrompt),
      ])
    ]
    for message in context.messages {
      switch message.role {
      case .user:
        messages.append(
          .object([
            "role": .string("user"),
            "content": .string(message.text ?? ""),
          ]))
      case .assistant:
        var fields: [String: JSONValue] = [
          "role": .string("assistant"),
          "content": message.text.map(JSONValue.string) ?? .null,
        ]
        if !message.toolCalls.isEmpty {
          fields["tool_calls"] = .array(
            try message.toolCalls.map { call in
              .object([
                "id": .string(call.id),
                "type": .string("function"),
                "function": .object([
                  "name": .string(call.name),
                  "arguments": .string(try jsonText(call.input)),
                ]),
              ])
            })
        }
        messages.append(.object(fields))
      case .tool:
        guard let toolCallID = message.toolCallID else {
          throw HarnessAgentGatewayError.malformedEvent
        }
        messages.append(
          .object([
            "role": .string("tool"),
            "tool_call_id": .string(toolCallID),
            "content": .string(message.text ?? ""),
          ]))
      }
    }

    let toolDefinitions = tools.map { tool in
      JSONValue.object([
        "type": .string("function"),
        "function": .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "parameters": tool.parameters,
        ]),
      ])
    }
    var body: [String: JSONValue] = [
      "model": .string(model),
      "stream": .bool(true),
      "max_tokens": .integer(Int64(maximumOutputTokens)),
      "messages": .array(messages),
    ]
    if !toolDefinitions.isEmpty { body["tools"] = .array(toolDefinitions) }
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(JSONValue.object(body))
  }

  private static func jsonText(_ value: JSONValue) throws -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessAgentGatewayError.malformedEvent
    }
    return text
  }
}

struct OpenAIHarnessAgentSSEDecoder {
  private struct PendingToolCall {
    var id = ""
    var name = ""
    var arguments = ""
  }

  private var calls: [Int: PendingToolCall] = [:]
  private(set) var completed = false

  mutating func consume(line rawLine: String) throws -> [HarnessAgentModelEvent] {
    guard rawLine.utf8.count <= 512 * 1_024 else {
      throw HarnessAgentGatewayError.streamedEventTooLarge
    }
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("data:") else { return [] }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard payload != "[DONE]" else { return [] }
    guard let data = payload.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let root) = decoded,
      case .array(let choices)? = root["choices"],
      let first = choices.first,
      case .object(let choice) = first
    else { throw HarnessAgentGatewayError.malformedEvent }

    var events: [HarnessAgentModelEvent] = []
    if case .object(let delta)? = choice["delta"] {
      if case .string(let text)? = delta["content"], !text.isEmpty {
        events.append(.textDelta(text))
      }
      if case .array(let fragments)? = delta["tool_calls"] {
        for fragment in fragments {
          guard case .object(let fields) = fragment,
            let index = Self.integer(fields["index"])
          else { throw HarnessAgentGatewayError.malformedEvent }
          if calls[index] == nil, calls.count >= 16 {
            throw HarnessAgentGatewayError.tooManyToolCalls
          }
          var pending = calls[index] ?? PendingToolCall()
          if case .string(let id)? = fields["id"] { pending.id = id }
          if case .object(let function)? = fields["function"] {
            if case .string(let name)? = function["name"] { pending.name += name }
            if case .string(let arguments)? = function["arguments"] {
              pending.arguments += arguments
            }
          }
          guard pending.id.utf8.count <= 256, pending.name.utf8.count <= 256 else {
            throw HarnessAgentGatewayError.malformedEvent
          }
          calls[index] = pending
          guard calls.values.reduce(0, { $0 + $1.arguments.utf8.count }) <= 256 * 1_024
          else { throw HarnessAgentGatewayError.toolArgumentsTooLarge }
        }
      }
    }

    if case .string(let finishReason)? = choice["finish_reason"] {
      guard !completed else { throw HarnessAgentSessionError.modelStreamCompletedTwice }
      let stopReason: HarnessAgentModelStopReason
      switch finishReason {
      case "stop": stopReason = .endTurn
      case "tool_calls": stopReason = .toolUse
      case "length": stopReason = .maxTokens
      default: throw HarnessAgentGatewayError.unsupportedStopReason(finishReason)
      }
      for index in calls.keys.sorted() {
        guard let call = calls[index], !call.id.isEmpty, !call.name.isEmpty else {
          throw HarnessAgentGatewayError.incompleteToolCall
        }
        let argumentsText = call.arguments.isEmpty ? "{}" : call.arguments
        guard let argumentsData = argumentsText.data(using: .utf8),
          let arguments = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
          case .object = arguments
        else {
          throw HarnessAgentGatewayError.malformedToolArguments(call.name)
        }
        events.append(
          .toolCall(
            HarnessAgentToolCall(id: call.id, name: call.name, input: arguments)))
      }
      calls.removeAll()
      completed = true
      events.append(.completed(stopReason))
    }
    return events
  }

  func finish() throws {
    guard completed else {
      if !calls.isEmpty { throw HarnessAgentGatewayError.incompleteToolCall }
      throw HarnessAgentGatewayError.streamEndedWithoutStopReason
    }
  }

  private static func integer(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let number): return Int(exactly: number)
    case .unsignedInteger(let number): return Int(exactly: number)
    default: return nil
    }
  }
}
