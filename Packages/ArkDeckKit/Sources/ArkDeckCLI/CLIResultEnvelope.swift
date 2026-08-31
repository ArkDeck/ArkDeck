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
      "controlRequestRetryable": .bool(error.code.isControlRequestRetryable),
      "attentionRequired": .bool(error.code.requiresAttention),
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

  /// §12: a leaf that is not the current published shape says so in
  /// `meta.lifecycle`, so a machine caller can tell it is driving a
  /// compatibility surface. The human-mode warning goes to stderr instead;
  /// machine stdout stays exactly one parseable document.
  static func withLifecycle(
    _ envelope: JSONValue, _ status: CLILifecycleStatus, replacement: String? = nil
  ) -> JSONValue {
    guard status != .current, case .object(var fields) = envelope,
      case .object(var meta)? = fields["meta"]
    else { return envelope }
    meta["lifecycle"] = .object([
      "status": .string(status.rawValue),
      "replacementArgvPattern": replacement.map(JSONValue.string) ?? .null,
      // §12: not guessed. No removal has been scheduled for any of these.
      "removalVersion": .null,
    ])
    fields["meta"] = .object(meta)
    return .object(fields)
  }

  /// The legacy-json rendering of a failure.
  ///
  /// §12 lists "errors are not JSON" among the defects `--json` must have fixed
  /// while keeping its shape, so a failure in this mode is a small JSON object
  /// rather than prose on stderr. It is deliberately not the envelope: that is
  /// what `--output json` is for.
  static func legacyFailure(_ error: CLIRegistryError) -> JSONValue {
    .object([
      "error": .object([
        "code": .string(error.code.rawValue),
        "message": .string(error.message),
      ])
    ])
  }

  /// One JSON document, no BOM, terminated by exactly one LF (§8.1).
  ///
  /// Rendered through `arkdeck.cli.canonical-json/1` so that this CLI and a
  /// native port produce the same bytes for the same value — Foundation's
  /// `.sortedKeys` orders keys by Unicode scalar where JCS orders by UTF-16
  /// code unit, and the two disagree exactly when a key stops being ASCII.
  static func render(_ value: JSONValue) -> String {
    do {
      return try CLICanonicalJSON.canonicalString(value) + "\n"
    } catch {
      // §8.1 forbids falling back to the human renderer when encoding fails,
      // so this stays a machine document the caller can branch on. The reason
      // is named: an integer past the exactly-representable range is a real
      // possibility, and "could not be encoded" would send a reader looking
      // for a bug that is actually a schema decision (§8.2 wants such a field
      // carried as a decimal string).
      let reason: String
      switch error {
      case CLICanonicalJSON.Failure.integerBeyondExactRange(let rendered):
        reason = "the result carries \(rendered), which no JSON number can hold exactly"
      case CLICanonicalJSON.Failure.nonFiniteNumber:
        reason = "the result carries a non-finite number, which JSON cannot represent"
      case CLICanonicalJSON.Failure.unpairedSurrogate:
        reason = "the result carries an unpaired surrogate, which UTF-8 cannot encode"
      default:
        reason = "the result could not be encoded"
      }
      return
        "{\"schemaVersion\":\"\(schemaVersion)\",\"command\":\"\(parsePhaseCommand)\","
        + "\"ok\":false,\"error\":{\"code\":\"internalError\","
        + "\"message\":\"\(reason)\"}}\n"
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
  /// How this failure must be rendered.
  ///
  /// A failure raised after the parse knows which mode the caller asked for,
  /// and carrying it here is what stops the answer arriving as prose on stderr
  /// when the caller asked for JSON — the shape §8.1 exists to guarantee.
  var rendering: CLIRendering = .human
  /// The correlation identity of the invocation that produced it.
  var controlRequestID: String?
  /// Set when a result document has already been written. The failure still
  /// carries its code and exit status, but rendering it as a second machine
  /// frame would break §8.1's one-document rule.
  var suppressesMachineRendering = false
  /// §12 attaches the alias notice "regardless of domain success or failure",
  /// so a failure envelope carries it too — otherwise a caller driving a
  /// deprecated spelling would be told only on the runs that happened to
  /// succeed.
  var lifecycle: CLILifecycleStatus = .current
  var replacementArgvPattern: String?

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
  /// Read from the wire contract rather than restated: this is what the
  /// client will actually put in a request frame, so a caller reading
  /// `--version` to decide whether to talk to this build is reading the
  /// truth. It gains a 2.x entry when the client can negotiate one, not
  /// before.
  static let supportedControlProtocolExactVersions =
    ArkDeckAgentXPC.supportedWireProtocolExactVersions
  static var preferredControlProtocol: String { supportedControlProtocolExactVersions[0] }

  /// The bundle version. Its components are pinned separately below.
  static let machineContract = "arkdeck.cli.contracts/1"
  static let resultSchema: String? = CLIResultEnvelope.schemaVersion
  /// Not published by this build: the page envelope, the JSONL event stream
  /// and the `nextAction` union arrive with the leaves that need them.
  static let pageSchema: String? = nil
  static let eventSchema: String? = nil
  static let nextActionSchema: String? = nil
  static let errorRegistry: String? = CLIErrorRegistryVersion.current
  static let canonicalJson: String? = CLICanonicalJSON.version
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
