// Environment-to-gateway composition for the harness decision port.
//
// Extracted from ArkDeckHarness/LLM/HarnessVendorGateways.swift: choosing and
// constructing a concrete vendor gateway — including the process-executing
// Codex CLI gateway — is composition-root work, so it lives in
// ArkDeckAgentComposition. ArkDeckHarness keeps the ports
// (HarnessDecisionGateway, HarnessModelTransport) and the pure HTTPS vendor
// adapters; it no longer links ArkDeckProcess at all.

import ArkDeckHarness
import Foundation

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
