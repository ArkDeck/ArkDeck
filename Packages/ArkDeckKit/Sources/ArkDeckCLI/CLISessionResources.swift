import ArkDeckCore
import Foundation

extension RuntimeCLI {
  static func runSession(_ arguments: [String]) throws {
    if arguments.first == "cleanup" {
      try runSessionCleanup(Array(arguments.dropFirst()))
      return
    }
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

  private static func runSessionCleanup(_ arguments: [String]) throws {
    guard let verb = arguments.first, ["preview", "apply"].contains(verb) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing session cleanup subcommand (preview|apply)")
    }
    var rest = Array(arguments.dropFirst())
    var session = runtimeSession(&rest, command: "session.cleanup.\(verb)")
    let options = try CLIOptions(rest)
    let method = "session.cleanup.\(verb)"
    try session.negotiate(requiredMajor: 2, forMethod: method)
    var fields: [String: JSONValue] = [:]
    if verb == "apply" {
      guard let previewID = options.value("--preview-id"),
        let uuid = UUID(uuidString: previewID),
        uuid.uuidString.lowercased() == previewID,
        let digest = options.value("--preview-digest"),
        SHA256Hex.isLowercaseSHA256(digest)
      else {
        throw session.fail(.invalidInput, "Session cleanup apply requires one exact preview tuple")
      }
      fields = ["previewId": .string(previewID), "previewDigest": .string(digest)]
    }
    let result = try session.request(method, fields)
    if verb == "preview" {
      try validateSessionCleanupPreview(result, session: session)
    } else {
      try validateSessionCleanupResult(result, session: session)
    }
    session.emit(result)
  }

  private static func validateSessionCleanupPreview(
    _ value: JSONValue,
    session: CLIRuntimeSession
  ) throws {
    func fail() -> CLIRegistryError {
      session.fail(.recordUnreadable, "the Runtime returned an invalid Session cleanup preview")
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == [
        "schemaVersion", "previewId", "previewDigest", "digestAlgorithm", "generation",
        "policyGeneration", "createdAtUtc", "expiresAtUtc", "confirmationRequired",
        "currentBytes", "projectedBytes", "safetyTargetBytes", "reclaimBytes",
        "blocksNewHeavyWriters", "sessions", "newDispatchCount",
      ],
      fields["schemaVersion"] == .string("arkdeck.session-cleanup-preview/1"),
      fields["digestAlgorithm"] == .string("sha256-jcs"),
      fields["confirmationRequired"] == .bool(true),
      fields["newDispatchCount"] == .integer(0),
      case .string(let previewID)? = fields["previewId"],
      let uuid = UUID(uuidString: previewID), uuid.uuidString.lowercased() == previewID,
      case .string(let digest)? = fields["previewDigest"], SHA256Hex.isLowercaseSHA256(digest),
      canonicalDecimal(fields["generation"]) != nil,
      let policyGeneration = canonicalDecimal(fields["policyGeneration"]), policyGeneration > 0,
      case .string(let createdText)? = fields["createdAtUtc"],
      let created = ISO8601Timestamps.parseCanonicalPlain(createdText),
      case .string(let expiresText)? = fields["expiresAtUtc"],
      let expires = ISO8601Timestamps.parseCanonicalPlain(expiresText), expires > created,
      let current = canonicalDecimal(fields["currentBytes"]),
      let projected = canonicalDecimal(fields["projectedBytes"]),
      let target = canonicalDecimal(fields["safetyTargetBytes"]),
      let reclaim = canonicalDecimal(fields["reclaimBytes"]),
      current >= reclaim, projected == current - reclaim,
      fields["blocksNewHeavyWriters"] == .bool(projected > target),
      case .array(let rows)? = fields["sessions"]
    else { throw fail() }
    var priorID: String?
    var reclaimed: UInt64 = 0
    for row in rows {
      guard case .object(let item) = row,
        Set(item.keys) == [
          "sessionId", "disposition", "reason", "sizeBytes", "expiresAtUtc", "pinned",
          "activeLease", "artifacts",
        ],
        case .string(let sessionID)? = item["sessionId"],
        AgentExecutionIntent.validIdentifier(sessionID),
        priorID.map({ $0.utf8.lexicographicallyPrecedes(sessionID.utf8) }) ?? true,
        case .string(let disposition)? = item["disposition"],
        ["reclaim", "retain"].contains(disposition),
        case .string(let reason)? = item["reason"],
        ["activeLease", "pinned", "expiredQuotaPressure", "quotaPressure",
          "withinSafetyTarget"].contains(reason),
        let bytes = canonicalDecimal(item["sizeBytes"]),
        case .string(let expiryText)? = item["expiresAtUtc"],
        ISO8601Timestamps.parseCanonicalPlain(expiryText) != nil,
        case .bool(let pinned)? = item["pinned"],
        case .bool(let active)? = item["activeLease"],
        case .array(let artifacts)? = item["artifacts"],
        disposition == "retain" || (!pinned && !active),
        reason != "activeLease" || active,
        reason != "pinned" || (pinned && !active),
        !["expiredQuotaPressure", "quotaPressure"].contains(reason)
          || disposition == "reclaim"
      else { throw fail() }
      priorID = sessionID
      if disposition == "reclaim" {
        let sum = reclaimed.addingReportingOverflow(bytes)
        guard !sum.overflow else { throw fail() }
        reclaimed = sum.partialValue
      }
      var priorArtifact: String?
      for artifact in artifacts {
        guard case .object(let artifactFields) = artifact,
          Set(artifactFields.keys) == [
            "artifactId", "artifactDigest", "byteCount", "role", "privacy",
          ],
          case .string(let artifactID)? = artifactFields["artifactId"],
          AgentExecutionIntent.validIdentifier(artifactID),
          priorArtifact.map({ $0.utf8.lexicographicallyPrecedes(artifactID.utf8) }) ?? true,
          case .string(let artifactDigest)? = artifactFields["artifactDigest"],
          SHA256Hex.isLowercaseSHA256(artifactDigest),
          canonicalDecimal(artifactFields["byteCount"]) != nil,
          case .string(let role)? = artifactFields["role"],
          ["raw", "derived", "log", "plan", "diagnostic", "partial"].contains(role),
          case .string(let privacy)? = artifactFields["privacy"],
          ["sensitive", "unknown"].contains(privacy),
          !["raw", "partial"].contains(role) || privacy == "sensitive"
        else { throw fail() }
        priorArtifact = artifactID
      }
    }
    guard reclaimed == reclaim else { throw fail() }
    var digestFields = fields
    digestFields.removeValue(forKey: "previewDigest")
    guard SHA256Hex.string(
      of: try PortableCanonicalJSON.canonicalBytes(.object(digestFields))) == digest
    else { throw fail() }
  }

  private static func validateSessionCleanupResult(
    _ value: JSONValue,
    session: CLIRuntimeSession
  ) throws {
    func fail() -> CLIRegistryError {
      session.fail(.recordUnreadable, "the Runtime returned an invalid Session cleanup result")
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == [
        "schemaVersion", "previewId", "previewDigest", "generation", "resultGeneration",
        "appliedAtUtc", "removedSessionIds", "removedArtifacts", "reclaimedBytes",
        "remainingBytes", "newDispatchCount",
      ],
      fields["schemaVersion"] == .string("arkdeck.session-cleanup-result/1"),
      fields["newDispatchCount"] == .integer(0),
      case .string(let previewID)? = fields["previewId"],
      let uuid = UUID(uuidString: previewID), uuid.uuidString.lowercased() == previewID,
      case .string(let digest)? = fields["previewDigest"], SHA256Hex.isLowercaseSHA256(digest),
      let generation = canonicalDecimal(fields["generation"]),
      let resultGeneration = canonicalDecimal(fields["resultGeneration"]),
      resultGeneration >= generation,
      case .string(let appliedText)? = fields["appliedAtUtc"],
      ISO8601Timestamps.parseCanonicalPlain(appliedText) != nil,
      canonicalDecimal(fields["reclaimedBytes"]) != nil,
      canonicalDecimal(fields["remainingBytes"]) != nil,
      case .array(let removedRows)? = fields["removedSessionIds"],
      case .array(let artifactRows)? = fields["removedArtifacts"]
    else { throw fail() }
    let removed = try removedRows.map { row -> String in
      guard case .string(let id) = row, AgentExecutionIntent.validIdentifier(id) else {
        throw fail()
      }
      return id
    }
    guard removed == removed.sorted(), Set(removed).count == removed.count else { throw fail() }
    var priorKey: String?
    for row in artifactRows {
      guard case .object(let artifact) = row,
        Set(artifact.keys) == ["sessionId", "artifactId", "artifactDigest"],
        case .string(let sessionID)? = artifact["sessionId"], removed.contains(sessionID),
        case .string(let artifactID)? = artifact["artifactId"],
        AgentExecutionIntent.validIdentifier(artifactID),
        case .string(let artifactDigest)? = artifact["artifactDigest"],
        SHA256Hex.isLowercaseSHA256(artifactDigest)
      else { throw fail() }
      let key = "\(sessionID)\u{0}\(artifactID)"
      guard priorKey.map({ $0 < key }) ?? true else { throw fail() }
      priorKey = key
    }
  }

  private static func canonicalDecimal(_ value: JSONValue?) -> UInt64? {
    guard case .string(let text)? = value, !text.isEmpty,
      text.utf8.allSatisfy({ (48...57).contains($0) }),
      text == "0" || text.first != "0",
      let parsed = UInt64(text), parsed <= UInt64(Int64.max)
    else { return nil }
    return parsed
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
