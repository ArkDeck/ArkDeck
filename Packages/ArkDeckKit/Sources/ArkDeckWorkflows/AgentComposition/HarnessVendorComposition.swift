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
  case missingCLIWorkingDirectory
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
  public static let cliPathKey = "ARKDECK_HARNESS_CLI_PATH"
  public static let cliWorkingDirectoryKey = "ARKDECK_HARNESS_CLI_WORKDIR"

  /// Keys that named one specific CLI back when only one was supported. They
  /// are refused rather than quietly ignored: a host that still sets them
  /// would otherwise start with no gateway at all and look merely
  /// unconfigured.
  static let retiredKeys = ["ARKDECK_HARNESS_CODEX_PATH", "ARKDECK_HARNESS_CODEX_WORKDIR"]

  /// Every provider this host can be pointed at: three HTTPS vendors that
  /// need a credential, and the local agent CLIs, which need none because the
  /// CLI is already signed in. The CLI list is the closed profile set — no
  /// provider name maps to an argv fragment taken from the environment.
  public static var supportedProviders: [String] {
    ["claude", "openai", "gemini"] + HarnessLocalAgentCLIProfile.all.map(\.profileID)
  }

  public static func gateway(
    environment: [String: String],
    transport: any HarnessModelTransport = URLSessionModelTransport(),
    cliTransport: any HarnessLocalAgentCLITransport = LocalAgentCLIProcessTransport()
  ) throws -> (any HarnessDecisionGateway)? {
    if let retired = retiredKeys.first(where: { nonempty(environment[$0]) != nil }) {
      throw HarnessVendorConfigurationError.unexpectedConfiguration(
        "\(retired)IsRetiredUse\(cliPathKey)And\(cliWorkingDirectoryKey)")
    }
    let configuredKeys = [
      apiKeyKey, modelKey, endpointKey, cliPathKey, cliWorkingDirectoryKey,
    ]
    guard let rawProvider = nonempty(environment[providerKey]) else {
      guard !configuredKeys.contains(where: { nonempty(environment[$0]) != nil }) else {
        throw HarnessVendorConfigurationError.providerRequired
      }
      return nil
    }
    let provider = rawProvider.lowercased()
    guard supportedProviders.contains(provider) else {
      throw HarnessVendorConfigurationError.unsupportedProvider(rawProvider)
    }
    guard let model = nonempty(environment[modelKey]), model.utf8.count <= 200,
      model.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0))
      })
    else {
      throw HarnessVendorConfigurationError.malformedModelName
    }
    if let profile = HarnessLocalAgentCLIProfile.named(provider) {
      // A local agent CLI is already signed in; a vendor credential or
      // endpoint here would mean the operator expected an HTTPS gateway and
      // is about to get a process instead.
      guard nonempty(environment[apiKeyKey]) == nil,
        nonempty(environment[endpointKey]) == nil
      else {
        throw HarnessVendorConfigurationError.unexpectedConfiguration(
          "localAgentCLIDoesNotAcceptVendorCredentialOrEndpoint")
      }
      guard let path = nonempty(environment[cliPathKey]), path.hasPrefix("/") else {
        throw HarnessVendorConfigurationError.malformedExecutable
      }
      guard let workingDirectory = nonempty(environment[cliWorkingDirectoryKey]) else {
        throw HarnessVendorConfigurationError.missingCLIWorkingDirectory
      }
      return try LocalAgentCLIDecisionGateway(
        profile: profile, executablePath: path, modelName: model,
        workingDirectory: workingDirectory, transport: cliTransport)
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
