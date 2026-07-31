// Vendor decision gateways (CHG-2026-055, TASK-HFA-011).
//
// Three adapters behind the one port the coordinator already talks to. What
// makes them replaceable rather than three integrations:
//
//   * the request body carries `context.transmittedBytes` and nothing else.
//     That is the same canonical serialization the ModelRun digest is taken
//     over, so "the digest represents what the model received" stays literally
//     true rather than approximately true (TASK-HFA-002);
//   * whatever comes back is bytes until the harness's strict parser accepts
//     it. An adapter extracts the model's text from the vendor envelope and
//     hands it over unexamined - it cannot widen what a decision may say;
//   * the credential is a header and only a header. It never reaches the
//     context, the decision record, the ModelRun, or a summary. The tests
//     assert that by searching every one of those for the token;
//   * a vendor error is a transport failure, which the coordinator already
//     handles by falling back to the deterministic handler and recording the
//     call. An adapter never invents a proposal.
//
// Egress remains denied by default. Configuring one of these does not enable
// it; `HarnessEgressPolicy` does, per project, explicitly.

import ArkDeckCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct HarnessModelHTTPRequest: Sendable, Equatable {
  public let url: String
  public let headers: [String: String]
  public let body: Data

  public init(url: String, headers: [String: String], body: Data) {
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct HarnessModelHTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

/// The seam the tests replace. Production uses `URLSessionModelTransport`;
/// nothing in this file opens a socket by itself.
public protocol HarnessModelTransport: Sendable {
  func send(_ request: HarnessModelHTTPRequest) async throws -> HarnessModelHTTPResponse
}

public struct URLSessionModelTransport: HarnessModelTransport {
  private let timeoutSeconds: Double

  public init(timeoutSeconds: Double = 60) {
    self.timeoutSeconds = timeoutSeconds
  }

  public func send(_ request: HarnessModelHTTPRequest) async throws -> HarnessModelHTTPResponse {
    guard let url = URL(string: request.url), url.scheme == "https" else {
      // Plain HTTP would put a bounded, redacted context on the wire in the
      // clear. It is a refusal, not a fallback.
      throw HarnessDecisionGatewayError.unavailable("modelEndpointMustBeHTTPS")
    }
    var urlRequest = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    for (field, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return HarnessModelHTTPResponse(statusCode: status, body: data)
    } catch {
      // The message is the vendor's; it is recorded as a reason code, never
      // parsed for meaning.
      throw HarnessDecisionGatewayError.transportFailure("modelTransportFailed")
    }
  }
}

/// What an adapter needs to reach one vendor. The key is held here and put in
/// a header; it is never serialized with the context.
public struct HarnessVendorCredential: Sendable {
  public let apiKey: String
  public let endpoint: String
  public let modelName: String

  public init(apiKey: String, endpoint: String, modelName: String) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.modelName = modelName
  }
}

public enum HarnessVendorConfigurationError: Error, Equatable, Sendable {
  case providerRequired
  case unsupportedProvider(String)
  case missingCredential
  case malformedModelName
  case malformedEndpoint
  case malformedExecutable
  case missingCodexWorkingDirectory
  case unexpectedConfiguration(String)
}

/// Turns explicit process configuration into exactly one vendor port. The
/// credential is required only when a provider is selected and is never
/// returned separately, logged or persisted.
public enum HarnessVendorConfiguration {
  public static let providerKey = "ARKDECK_HARNESS_MODEL_PROVIDER"
  public static let apiKeyKey = "ARKDECK_HARNESS_MODEL_API_KEY"
  public static let modelKey = "ARKDECK_HARNESS_MODEL_NAME"
  public static let endpointKey = "ARKDECK_HARNESS_MODEL_ENDPOINT"
  public static let codexPathKey = "ARKDECK_HARNESS_CODEX_PATH"
  public static let codexWorkingDirectoryKey = "ARKDECK_HARNESS_CODEX_WORKDIR"

  public static func gateway(
    environment: [String: String],
    transport: any HarnessModelTransport = URLSessionModelTransport(),
    codexTransport: any HarnessCodexTransport = CodexCLIProcessTransport()
  ) throws -> (any HarnessDecisionGateway)? {
    let configuredKeys = [
      apiKeyKey, modelKey, endpointKey, codexPathKey, codexWorkingDirectoryKey,
    ]
    guard let rawProvider = nonempty(environment[providerKey]) else {
      guard !configuredKeys.contains(where: { nonempty(environment[$0]) != nil }) else {
        throw HarnessVendorConfigurationError.providerRequired
      }
      return nil
    }
    let provider = rawProvider.lowercased()
    guard ["claude", "openai", "gemini", "codex"].contains(provider) else {
      throw HarnessVendorConfigurationError.unsupportedProvider(rawProvider)
    }
    guard let model = nonempty(environment[modelKey]), model.utf8.count <= 200,
      model.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0))
      })
    else {
      throw HarnessVendorConfigurationError.malformedModelName
    }
    if provider == "codex" {
      guard nonempty(environment[apiKeyKey]) == nil,
        nonempty(environment[endpointKey]) == nil
      else {
        throw HarnessVendorConfigurationError.unexpectedConfiguration(
          "codexDoesNotAcceptVendorCredentialOrEndpoint")
      }
      guard let path = nonempty(environment[codexPathKey]), path.hasPrefix("/") else {
        throw HarnessVendorConfigurationError.malformedExecutable
      }
      guard let workingDirectory = nonempty(environment[codexWorkingDirectoryKey]) else {
        throw HarnessVendorConfigurationError.missingCodexWorkingDirectory
      }
      return try CodexCLIDecisionGateway(
        executablePath: path, modelName: model, workingDirectory: workingDirectory,
        transport: codexTransport)
    }
    guard let apiKey = nonempty(environment[apiKeyKey]), apiKey.utf8.count <= 8_192,
      !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw HarnessVendorConfigurationError.missingCredential
    }
    let defaultEndpoint: String
    switch provider {
    case "claude": defaultEndpoint = ClaudeDecisionGateway.defaultEndpoint
    case "openai": defaultEndpoint = OpenAIDecisionGateway.defaultEndpoint
    case "gemini":
      defaultEndpoint = GeminiDecisionGateway.defaultEndpoint + "/\(model):generateContent"
    default: preconditionFailure("provider was checked above")
    }
    let endpoint = nonempty(environment[endpointKey]) ?? defaultEndpoint
    guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else {
      throw HarnessVendorConfigurationError.malformedEndpoint
    }
    let credential = HarnessVendorCredential(
      apiKey: apiKey, endpoint: endpoint, modelName: model)
    switch provider {
    case "claude":
      return ClaudeDecisionGateway(credential: credential, transport: transport)
    case "openai":
      return OpenAIDecisionGateway(credential: credential, transport: transport)
    case "gemini":
      return GeminiDecisionGateway(credential: credential, transport: transport)
    default:
      preconditionFailure("provider was checked above")
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

enum HarnessVendorEnvelope {
  /// The one instruction every adapter sends. It says what shape to answer
  /// in; it cannot widen the schema, because the parser is what decides.
  static let instruction = """
    Answer with one JSON object and nothing else: no prose, no code fence. \
    Allowed keys are kind, operationRef, inputs, hypothesis, reasonCode, \
    confidence, requiredArtifacts, expectedObservation, baseWorkspaceRevision, \
    patchSha256, unifiedDiff, touchedFiles, expectedChangedSymbols. \
    Patch fields are top-level fields, never nested under a patch key. \
    Allowed kinds are invokeOperation, proposePatch, \
    requestHuman, noSafeAction. For invokeOperation, include exactly one \
    operationRef chosen from availableOperations and do not invent operation \
    inputs or copy context metadata into inputs. For proposePatch, omit \
    operationRef and inputs, and include baseWorkspaceRevision, patchSha256, \
    unifiedDiff, touchedFiles, and expectedChangedSymbols. The context follows.
    """

  static func text(_ context: HarnessDecisionContext) -> String {
    instruction + "\n" + String(decoding: context.transmittedBytes, as: UTF8.self)
  }

  static func json(_ value: [String: JSONValue]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(JSONValue.object(value))) ?? Data("{}".utf8)
  }

  /// Vendor envelopes differ; the failure modes do not. Anything that is not
  /// a 2xx with the expected shape is a transport failure, which the caller
  /// already knows how to survive.
  static func decode(
    _ response: HarnessModelHTTPResponse,
    extract: (JSONValue) -> String?
  ) throws -> Data {
    guard (200..<300).contains(response.statusCode) else {
      throw HarnessDecisionGatewayError.transportFailure(
        "modelHTTP\(response.statusCode)")
    }
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body),
      let text = extract(decoded), !text.isEmpty
    else {
      throw HarnessDecisionGatewayError.transportFailure("modelEnvelopeUnparsable")
    }
    return Data(text.utf8)
  }

  static func string(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    return nil
  }

  static func array(_ value: JSONValue?) -> [JSONValue]? {
    if case .array(let values) = value { return values }
    return nil
  }

  static func object(_ value: JSONValue?) -> [String: JSONValue]? {
    if case .object(let fields) = value { return fields }
    return nil
  }
}

public struct ClaudeDecisionGateway: HarnessDecisionGateway {
  public static let defaultEndpoint = "https://api.anthropic.com/v1/messages"
  public static let apiVersion = "2023-06-01"

  private let credential: HarnessVendorCredential
  private let transport: any HarnessModelTransport
  private let maxOutputTokens: Int

  public init(
    credential: HarnessVendorCredential,
    transport: any HarnessModelTransport = URLSessionModelTransport(),
    maxOutputTokens: Int = 1024
  ) {
    self.credential = credential
    self.transport = transport
    self.maxOutputTokens = maxOutputTokens
  }

  public var producerID: String { "claude-gateway@1" }

  public var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(
      provider: "anthropic", modelName: credential.modelName, adapterVersion: producerID)
  }

  public func propose(_ context: HarnessDecisionContext) async throws -> Data {
    let body = HarnessVendorEnvelope.json([
      "model": .string(credential.modelName),
      "max_tokens": .integer(Int64(maxOutputTokens)),
      "messages": .array([
        .object([
          "role": .string("user"),
          "content": .string(HarnessVendorEnvelope.text(context)),
        ])
      ]),
    ])
    let response = try await transport.send(
      HarnessModelHTTPRequest(
        url: credential.endpoint,
        headers: [
          "content-type": "application/json",
          "anthropic-version": Self.apiVersion,
          "x-api-key": credential.apiKey,
        ],
        body: body))
    return try HarnessVendorEnvelope.decode(response) { decoded in
      guard let fields = HarnessVendorEnvelope.object(decoded),
        let blocks = HarnessVendorEnvelope.array(fields["content"])
      else { return nil }
      return blocks.compactMap { block in
        guard let blockFields = HarnessVendorEnvelope.object(block),
          HarnessVendorEnvelope.string(blockFields["type"]) == "text"
        else { return nil }
        return HarnessVendorEnvelope.string(blockFields["text"])
      }.joined()
    }
  }
}

public struct OpenAIDecisionGateway: HarnessDecisionGateway {
  public static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"

  private let credential: HarnessVendorCredential
  private let transport: any HarnessModelTransport

  public init(
    credential: HarnessVendorCredential,
    transport: any HarnessModelTransport = URLSessionModelTransport()
  ) {
    self.credential = credential
    self.transport = transport
  }

  public var producerID: String { "openai-gateway@1" }

  public var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(
      provider: "openai", modelName: credential.modelName, adapterVersion: producerID)
  }

  public func propose(_ context: HarnessDecisionContext) async throws -> Data {
    let body = HarnessVendorEnvelope.json([
      "model": .string(credential.modelName),
      "messages": .array([
        .object([
          "role": .string("user"),
          "content": .string(HarnessVendorEnvelope.text(context)),
        ])
      ]),
      "response_format": .object(["type": .string("json_object")]),
    ])
    let response = try await transport.send(
      HarnessModelHTTPRequest(
        url: credential.endpoint,
        headers: [
          "content-type": "application/json",
          "authorization": "Bearer \(credential.apiKey)",
        ],
        body: body))
    return try HarnessVendorEnvelope.decode(response) { decoded in
      guard let fields = HarnessVendorEnvelope.object(decoded),
        let choices = HarnessVendorEnvelope.array(fields["choices"]),
        let first = choices.first,
        let choice = HarnessVendorEnvelope.object(first),
        let message = HarnessVendorEnvelope.object(choice["message"])
      else { return nil }
      return HarnessVendorEnvelope.string(message["content"])
    }
  }
}

public struct GeminiDecisionGateway: HarnessDecisionGateway {
  public static let defaultEndpoint =
    "https://generativelanguage.googleapis.com/v1beta/models"

  private let credential: HarnessVendorCredential
  private let transport: any HarnessModelTransport

  public init(
    credential: HarnessVendorCredential,
    transport: any HarnessModelTransport = URLSessionModelTransport()
  ) {
    self.credential = credential
    self.transport = transport
  }

  public var producerID: String { "gemini-gateway@1" }

  public var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(
      provider: "google", modelName: credential.modelName, adapterVersion: producerID)
  }

  public func propose(_ context: HarnessDecisionContext) async throws -> Data {
    let body = HarnessVendorEnvelope.json([
      "contents": .array([
        .object([
          "role": .string("user"),
          "parts": .array([
            .object(["text": .string(HarnessVendorEnvelope.text(context))])
          ]),
        ])
      ]),
      "generationConfig": .object(["responseMimeType": .string("application/json")]),
    ])
    let response = try await transport.send(
      HarnessModelHTTPRequest(
        url: credential.endpoint,
        headers: [
          "content-type": "application/json",
          // Header, not a query parameter: a key in a URL ends up in logs and
          // in anything that records the request line.
          "x-goog-api-key": credential.apiKey,
        ],
        body: body))
    return try HarnessVendorEnvelope.decode(response) { decoded in
      guard let fields = HarnessVendorEnvelope.object(decoded),
        let candidates = HarnessVendorEnvelope.array(fields["candidates"]),
        let first = candidates.first,
        let candidate = HarnessVendorEnvelope.object(first),
        let content = HarnessVendorEnvelope.object(candidate["content"]),
        let parts = HarnessVendorEnvelope.array(content["parts"])
      else { return nil }
      return parts.compactMap { part in
        HarnessVendorEnvelope.string(HarnessVendorEnvelope.object(part)?["text"])
      }.joined()
    }
  }
}
