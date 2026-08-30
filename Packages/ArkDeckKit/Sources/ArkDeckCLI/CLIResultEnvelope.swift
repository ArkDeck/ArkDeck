import ArkDeckCore
import CryptoKit
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

/// The four versions §12 keeps independent of one another, and the individually
/// pinned components of the machine-contract bundle.
///
/// A component this build does not publish is reported as `nil` rather than
/// omitted or filled in from the spec. Naming a schema version the binary
/// cannot actually produce would be a false capability claim, and §12 makes
/// `--version` a statement about *this client*, not about the document it was
/// written from.
enum CLIProductVersion {
  /// The CLI product itself.
  static let product = "0.1.0"
  /// The command registry projection shape.
  static let commandRegistrySchema = CLICommandRegistry.schemaVersion

  /// The local control protocol versions this client can speak, in the
  /// numeric-descending canonical order §12 requires.
  ///
  /// These mirror the single version `AgentClient` hard-codes today. Removing
  /// that second source of truth is its own vertical change (spec §13.2);
  /// until then this list must not be edited independently of it, and it must
  /// not claim a 2.x the client cannot negotiate.
  static let supportedControlProtocolExactVersions = ["1.0.0"]
  static var preferredControlProtocol: String { supportedControlProtocolExactVersions[0] }

  /// The bundle version. Its components are pinned separately below.
  static let machineContract = "arkdeck.cli.contracts/1"
  static let resultSchema: String? = CLIResultEnvelope.schemaVersion
  /// Not published by this build: the page envelope, the JSONL event stream,
  /// the `nextAction` union, the versioned error registry and the canonical
  /// JSON profile all arrive with the leaves that need them.
  static let pageSchema: String? = nil
  static let eventSchema: String? = nil
  static let nextActionSchema: String? = nil
  static let errorRegistry: String? = nil
  static let canonicalJson: String? = nil
}

/// The identity of the binary that answered, computed from the binary itself.
///
/// SwiftPM injects no revision, and a constant somebody has to remember to bump
/// is a build identity that silently stops being one. Hashing the running
/// executable cannot go stale: it is either the exact bytes that ran, or it is
/// absent because they could not be read.
enum CLIBuildIdentity {
  static func current() -> String? {
    guard let path = Bundle.main.executableURL ?? executablePathFromArgv() else { return nil }
    guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
      hasher.update(data: chunk)
    }
    return "sha256:" + SHA256Hex.hexString(hasher.finalize())
  }

  private static func executablePathFromArgv() -> URL? {
    guard let first = CommandLine.arguments.first, first.hasPrefix("/") else { return nil }
    return URL(filePath: first)
  }
}
