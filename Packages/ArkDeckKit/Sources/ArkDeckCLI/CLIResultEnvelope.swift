import ArkDeckCore
import Foundation

/// The versioned machine envelope from §8.2 of the CLI product spec.
///
/// This release emits it for the registry meta-commands (`commands`,
/// `--version`) and for every argv-level failure, which is what §8.1 asks for:
/// an agent that mistypes a flag has to be able to read the refusal without a
/// human in the loop, and that has to work before the command path is even
/// known. Migrating the Runtime leaves off `--json` and onto this envelope is
/// a separate vertical change — declaring the option everywhere before the
/// renderer honours it would publish a mode that does not work.
enum CLIResultEnvelope {
  static let schemaVersion = "arkdeck.cli.result/1"

  /// The `command` value used before a command path has been resolved (§8.1).
  static let parsePhaseCommand = "registry.parse"

  static func success(
    command: String,
    result: JSONValue,
    controlRequestID: String
  ) -> JSONValue {
    .object([
      "schemaVersion": .string(schemaVersion),
      "command": .string(command),
      "ok": .bool(true),
      "result": result,
      "meta": .object([
        "controlRequestId": .string(controlRequestID),
        "cliVersion": .string(CLIProductVersion.product),
      ]),
    ])
  }

  static func failure(
    command: String,
    error: CLIRegistryError,
    controlRequestID: String
  ) -> JSONValue {
    var errorFields: [String: JSONValue] = [
      "code": .string(error.code.rawValue),
      "message": .string(error.message),
      "controlRequestRetryable": .bool(false),
      "attentionRequired": .bool(false),
    ]
    if !error.details.isEmpty { errorFields["details"] = .object(error.details) }
    return .object([
      "schemaVersion": .string(schemaVersion),
      "command": .string(command),
      "ok": .bool(false),
      "error": .object(errorFields),
      "meta": .object([
        "controlRequestId": .string(controlRequestID),
        "cliVersion": .string(CLIProductVersion.product),
      ]),
    ])
  }

  /// One JSON document, no BOM, terminated by exactly one LF (§8.1).
  static func render(_ value: JSONValue) -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
    else {
      // §8.1 forbids falling back to the human renderer when JSON encoding
      // fails, so this stays a machine document — one the caller can still
      // branch on — rather than prose on stdout.
      return
        "{\"schemaVersion\":\"\(schemaVersion)\",\"command\":\"\(parsePhaseCommand)\","
        + "\"ok\":false,\"error\":{\"code\":\"internalError\","
        + "\"message\":\"the result could not be encoded\"}}\n"
    }
    return text + "\n"
  }
}

/// The subset of the §8.4 error registry this release can produce.
///
/// The registry is a branching contract, so the codes are spelled once and
/// carry their own exit status: a code whose exit status is decided at the
/// throw site is a code whose meaning drifts per call site.
enum CLIErrorCode: String {
  case invalidCommand
  case invalidOption
  case commandRemoved
  case invalidInput
  case internalError

  var exitCode: Int32 {
    switch self {
    case .invalidCommand, .invalidOption, .commandRemoved: return 64
    case .invalidInput: return 65
    case .internalError: return 70
    }
  }
}

struct CLIRegistryError: Error {
  let code: CLIErrorCode
  let message: String
  var details: [String: JSONValue] = [:]
  /// The canonical command this failure belongs to, or `nil` before the path
  /// was resolved.
  var command: String?

  var exitCode: Int32 { code.exitCode }
}

/// The four versions §12 keeps independent of one another.
enum CLIProductVersion {
  /// The CLI product itself.
  static let product = "0.1.0"
  /// The command registry projection shape.
  static let commandRegistrySchema = CLICommandRegistry.schemaVersion
  /// The local control protocol the client speaks.
  ///
  /// This mirrors the value `AgentClient` sends today. Removing that hard-coded
  /// second source of truth is its own vertical change (spec §13.2); until then
  /// this constant must not be edited independently of it.
  static let preferredControlProtocol = "1.0.0"
  /// The machine-contract bundle, whose components are pinned individually.
  static let machineContractBundle = "arkdeck.cli.contracts/1"
  static let resultSchema = CLIResultEnvelope.schemaVersion
}
