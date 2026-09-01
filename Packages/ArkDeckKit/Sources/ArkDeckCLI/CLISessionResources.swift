import ArkDeckCore
import Foundation

extension RuntimeCLI {
  static func runSession(_ arguments: [String]) throws {
    guard let verb = arguments.first,
      ["list", "show", "pin", "unpin"].contains(verb)
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing session subcommand (list|show|pin|unpin)")
    }
    var rest = Array(arguments.dropFirst())
    var session = runtimeSession(&rest, command: "session.\(verb)")
    let options = try CLIOptions(rest)
    let method = "session.\(verb)"
    try session.negotiate(requiredMajor: 2, forMethod: method)

    var fields: [String: JSONValue] = [:]
    var requestedPageSize = 100
    switch verb {
    case "list":
      guard let pageSize = Int(options.value("--page-size") ?? "100") else {
        throw session.fail(.invalidInput, "Session page size is invalid")
      }
      requestedPageSize = pageSize
      fields["pageSize"] = .integer(Int64(pageSize))
      if let cursor = options.value("--cursor") {
        fields["cursor"] = .string(cursor)
      }
    case "show":
      guard let sessionID = options.value("--session") else {
        throw session.fail(.invalidInput, "Session show requires one Session identity")
      }
      fields["sessionId"] = .string(sessionID)
    case "pin", "unpin":
      guard let sessionID = options.value("--session"),
        let generation = options.value("--expected-generation")
      else {
        throw session.fail(
          .invalidInput, "Session pin transition requires an identity and generation")
      }
      fields["sessionId"] = .string(sessionID)
      fields["expectedGeneration"] = .string(generation)
    default:
      preconditionFailure("closed Session command registry drifted")
    }

    let result = try session.request(method, fields)
    if verb == "list" {
      try validateSessionPage(result, pageSize: requestedPageSize, session: session)
    } else {
      _ = try validateSessionResource(result, session: session)
    }
    session.emit(result)
  }

  private struct ValidatedSessionResource {
    let sessionID: String
    let generation: UInt64
    let completedAt: Date
  }

  private static func validateSessionPage(
    _ value: JSONValue,
    pageSize: Int,
    session: CLIRuntimeSession
  ) throws {
    func fail() -> CLIRegistryError {
      session.fail(.recordUnreadable, "the Runtime returned an invalid Session page")
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == [
        "schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore",
        "nextCursor",
      ],
      fields["schemaVersion"] == .string("arkdeck.cli.page/1"),
      fields["pageKind"] == .string("snapshot"),
      fields["order"] == .string("completedAtDescSessionIdAsc"),
      case .string(let revision)? = fields["snapshotRevision"],
      let revisionUUID = UUID(uuidString: revision),
      revisionUUID.uuidString.lowercased() == revision,
      case .array(let items)? = fields["items"], items.count <= pageSize,
      case .bool(let hasMore)? = fields["hasMore"]
    else { throw fail() }
    if hasMore {
      guard case .string(let cursor)? = fields["nextCursor"],
        !items.isEmpty, cursor.utf8.count <= 2_048,
        cursor.hasPrefix(revision + "."),
        case let cursorParts = cursor.split(
          separator: ".", omittingEmptySubsequences: false),
        cursorParts.count == 2,
        let pageToken = cursorParts.last,
        let pageUUID = UUID(uuidString: String(pageToken)),
        pageUUID.uuidString.lowercased() == pageToken
      else { throw fail() }
    } else {
      guard fields["nextCursor"] == .null else { throw fail() }
    }

    var rows: [ValidatedSessionResource] = []
    for item in items {
      rows.append(try validateSessionResource(item, session: session))
    }
    guard Set(rows.map(\.sessionID)).count == rows.count else { throw fail() }
    for pair in zip(rows, rows.dropFirst()) {
      let ordered = pair.0.completedAt > pair.1.completedAt
        || (pair.0.completedAt == pair.1.completedAt
          && pair.0.sessionID.utf8.lexicographicallyPrecedes(pair.1.sessionID.utf8))
      guard ordered, pair.0.generation == pair.1.generation else { throw fail() }
    }
  }

  @discardableResult
  private static func validateSessionResource(
    _ value: JSONValue,
    session: CLIRuntimeSession
  ) throws -> ValidatedSessionResource {
    func fail() -> CLIRegistryError {
      session.fail(.recordUnreadable, "the Runtime returned an invalid Session resource")
    }
    func decimal(_ value: JSONValue?) -> UInt64? {
      guard case .string(let text)? = value, !text.isEmpty,
        text.utf8.allSatisfy({ (48...57).contains($0) }),
        text == "0" || text.first != "0", let parsed = UInt64(text),
        parsed <= UInt64(Int64.max)
      else { return nil }
      return parsed
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == [
        "schemaVersion", "sessionId", "generation", "completedAtUtc", "expiresAtUtc",
        "sizeBytes", "pinned", "policyGeneration",
      ],
      fields["schemaVersion"] == .string("arkdeck.session/1"),
      case .string(let sessionID)? = fields["sessionId"],
      AgentExecutionIntent.validIdentifier(sessionID),
      let generation = decimal(fields["generation"]),
      case .string(let completedText)? = fields["completedAtUtc"],
      let completedAt = ISO8601Timestamps.parseCanonicalPlain(completedText),
      case .string(let expiresText)? = fields["expiresAtUtc"],
      let expiresAt = ISO8601Timestamps.parseCanonicalPlain(expiresText),
      expiresAt > completedAt,
      decimal(fields["sizeBytes"]) != nil,
      case .bool? = fields["pinned"],
      let policyGeneration = decimal(fields["policyGeneration"]), policyGeneration > 0
    else { throw fail() }
    return ValidatedSessionResource(
      sessionID: sessionID, generation: generation, completedAt: completedAt)
  }
}
