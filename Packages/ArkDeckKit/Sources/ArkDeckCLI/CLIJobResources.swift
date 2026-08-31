import ArkDeckAgentClient
import ArkDeckCore
import Foundation

extension RuntimeCLI {
  static func usesJobReadResource(_ verb: String, rest: [String]) -> Bool {
    if ["show", "timeline"].contains(verb) { return true }
    guard ["list", "status", "evidence", "result"].contains(verb) else { return false }
    return rest.contains { ["--require-protocol", "--timeout", "--state", "--operation", "--target", "--thread",
      "createdAtDescJobIdAsc", "createdAtAscJobIdAsc"].contains($0) }
  }

  static func emitJobReadResource(_ verb: String, rest: [String], session original: CLIRuntimeSession) throws {
    var session = original
    let options = try CLIOptions(rest.filter { !["--include-current", "--include-timeline"].contains($0) })
    let method = "job.\(verb)"
    var fields: [String: JSONValue] = [:]
    if verb != "list" {
      guard let id = options.value("--job"), AgentExecutionIntent.validIdentifier(id) else {
        throw session.fail(.invalidInput, "an exact Job identity is required")
      }
      fields["jobId"] = .string(id)
    }
    if verb == "list" || verb == "timeline" {
      if let text = options.value("--page-size"), let count = Int64(text) { fields["pageSize"] = .integer(count) }
      if let cursor = options.value("--cursor") { fields["cursor"] = .string(cursor) }
    }
    if verb == "list" {
      for (flag, key) in [("--order", "order"), ("--state", "state"), ("--operation", "operation"), ("--target", "target"), ("--thread", "thread")] {
        if let value = options.value(flag) { fields[key] = .string(value) }
      }
      if rest.contains("--include-current") { fields["includeCurrent"] = .bool(true) }
      if rest.contains("--include-timeline") { fields["includeTimeline"] = .bool(true) }
    }
    let timeout = options.value("--timeout") ?? "30s"
    guard let duration = CLIDuration.parse(timeout, maximumMilliseconds: 86_400_000) else {
      throw session.fail(.invalidInput, "timeout must be a bounded duration")
    }
    session.client = session.client.bounded(by: try AgentClientWaitDeadline(milliseconds: duration.milliseconds))
    do {
      try session.negotiate(requiredMajor: 2, forMethod: method)
      let result = try session.request(method, fields)
      let exit = try CLIJobReadValidation.validate(result, verb: verb,
        jobID: CLIJobEventPage.string(fields["jobId"]), options: fields, session: session)
      session.emit(result)
      if exit != 0 { throw CLIError(exitCode: exit, message: "Job outcome or evidence requires attention") }
    } catch let error as CLIRegistryError { throw session.stamped(error) }
  }
}

enum CLIJobReadValidation {
  static func validate(_ value: JSONValue, verb: String, jobID: String?, options: [String: JSONValue], session: CLIRuntimeSession) throws -> Int32 {
    func invalid() -> CLIRegistryError { session.fail(.recordUnreadable, "the Runtime returned an invalid Job read projection") }
    guard case .object(let fields) = value else { throw invalid() }
    switch verb {
    case "list", "timeline":
      guard Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
        fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("snapshot"),
        let revision = CLIJobEventPage.string(fields["snapshotRevision"]), UUID(uuidString: revision) != nil,
        case .bool(let more)? = fields["hasMore"], case .array(let rows)? = fields["items"], rows.count <= 1000,
        more ? (CLIJobEventPage.string(fields["nextCursor"]).map { !$0.isEmpty && $0.utf8.count <= 2048 } == true && !rows.isEmpty) : fields["nextCursor"] == .null
      else { throw invalid() }
      if case .integer(let size)? = options["pageSize"], rows.count > size { throw invalid() }
      let order = verb == "list" ? options["order"] ?? .string("createdAtDescJobIdAsc") : .string("entryIndexAscPartIndexAsc")
      guard fields["order"] == order else { throw invalid() }
      var previousDate: Date?
      var previousID: String?
      var previousIndex: Int64?
      var previousPart: Int64?
      var previousLast: Bool?
      var identities: Set<String> = []
      for row in rows {
        guard case .object(let item) = row else { throw invalid() }
        if verb == "timeline" {
          guard Set(item.keys) == ["entryIndex", "partIndex", "text", "lastPart"],
            let index = CLIJobEventPage.decimal(item["entryIndex"]), let part = CLIJobEventPage.decimal(item["partIndex"]),
            let text = CLIJobEventPage.string(item["text"]), text.utf8.count <= 64 * 1024,
            case .bool(let last)? = item["lastPart"]
          else { throw invalid() }
          if let previousIndex, let previousPart {
            guard previousIndex == index
              ? (previousLast == false && previousPart < Int64.max && part == previousPart + 1)
              : (previousLast == true && previousIndex < Int64.max && index == previousIndex + 1 && part == 0)
            else { throw invalid() }
          }
          previousIndex = index; previousPart = part; previousLast = last
        } else {
          var status = item
          guard status.removeValue(forKey: "schemaVersion") == .string("arkdeck.job-summary/1"),
            case .bool? = status.removeValue(forKey: "current"),
            let timeline = status.removeValue(forKey: "timeline") else { throw invalid() }
          status["schemaVersion"] = .string("arkdeck.job-status/1")
          let id = try validateStatus(.object(status), expectedID: nil, session: session)
          try validateTimeline(timeline, jobID: id, allowNull: options["includeTimeline"] != .bool(true), session: session)
          guard identities.insert(id).inserted, let text = CLIJobEventPage.string(status["createdAtUtc"]),
            let date = ISO8601Timestamps.parse(text) else { throw invalid() }
          if let previousDate, let previousID {
            if previousDate == date {
              guard previousID.utf8.lexicographicallyPrecedes(id.utf8) else { throw invalid() }
            } else {
              guard order == .string("createdAtDescJobIdAsc") ? previousDate > date : previousDate < date else { throw invalid() }
            }
          }
          previousDate = date; previousID = id
        }
      }
      return 0
    case "status":
      _ = try validateStatus(value, expectedID: jobID, session: session)
      return 0
    case "show":
      guard fields["schemaVersion"] == .string("arkdeck.job/1"),
        Set(fields.keys) == ["schemaVersion", "job", "request", "catalogDigest", "providerId", "materializedPlanDigest",
          "materializedBindingRevision", "materializedStableIdentitySha256", "actualStepKinds", "timeline", "events", "evidence", "ringCoverage", "screenSequence"],
        let job = fields["job"], case .object? = fields["request"],
        let digest = CLIJobEventPage.string(fields["catalogDigest"]), SHA256Hex.isLowercaseSHA256(digest),
        let timeline = fields["timeline"] else { throw invalid() }
      let id = try validateStatus(job, expectedID: jobID, session: session)
      guard fields["events"] == .object(["method": .string("job.events"), "jobId": .string(id)]),
        fields["evidence"] == .object(["method": .string("job.evidence"), "jobId": .string(id)]) else { throw invalid() }
      try validateTimeline(timeline, jobID: id, allowNull: false, session: session)
      return 0
    case "evidence": return try validateEvidence(value, jobID: jobID, session: session)
    case "result":
      guard Set(fields.keys) == ["schemaVersion", "job", "terminal", "outcomeUnknown", "evidence", "artifacts", "cleanup", "nextAction"],
        fields["schemaVersion"] == .string("arkdeck.job-result/1"), fields["terminal"] == .bool(true),
        let job = fields["job"], case .object(let status) = job,
        let raw = CLIJobEventPage.string(status["state"]), JobState(rawValue: raw)?.isTerminal == true,
        fields["outcomeUnknown"] == status["outcomeUnknown"], let evidence = fields["evidence"],
        case .array(let artifacts)? = fields["artifacts"], case .array(let cleanup)? = fields["cleanup"]
      else { throw invalid() }
      let id = try validateStatus(job, expectedID: jobID, session: session)
      let evidenceExit = try validateEvidence(evidence, jobID: id, session: session)
      var artifactIDs: Set<String> = []
      for artifact in artifacts {
        guard case .object(let row) = artifact,
          Set(row.keys) == ["artifactId", "owner", "reference", "name", "mediaType", "byteCount", "sha256", "privacy", "status", "bytesVerified"],
          row["owner"] == .object(["kind": .string("job"), "id": .string(id)]),
          let artifactID = CLIJobEventPage.string(row["artifactId"]), AgentExecutionIntent.validIdentifier(artifactID),
          artifactIDs.insert(artifactID).inserted,
          row["reference"] == .string("arkdeck-artifact://\(id)/\(artifactID)"),
          let digest = CLIJobEventPage.string(row["sha256"]),
          (SHA256Hex.isLowercaseSHA256(digest) || row["status"] == .string("missing") && digest.isEmpty),
          CLIJobEventPage.decimal(row["byteCount"]) != nil, case .bool? = row["bytesVerified"],
          CLIJobEventPage.string(row["name"])?.isEmpty == false, CLIJobEventPage.string(row["mediaType"])?.isEmpty == false,
          CLIJobEventPage.string(row["privacy"]).flatMap(CatalogArtifactPrivacy.init(rawValue:)) != nil,
          let state = CLIJobEventPage.string(row["status"]), ["published", "missing", "truncated"].contains(state)
        else { throw invalid() }
      }
      var debtIDs: Set<String> = []
      for debt in cleanup {
        guard case .object(let row) = debt, Set(row.keys) == ["cleanupDebtId", "jobId", "stepId", "recordedAtUtc", "outcomeUnknown"],
          row["jobId"] == .string(id), let debtID = CLIJobEventPage.string(row["cleanupDebtId"]),
          case .bool? = row["outcomeUnknown"] else { throw invalid() }
        guard debtIDs.insert(debtID).inserted, debtID.hasPrefix("cleanup-"), SHA256Hex.isLowercaseSHA256(String(debtID.dropFirst(8))),
          CLIJobEventPage.string(row["stepId"])?.isEmpty == false,
          CLIJobEventPage.string(row["recordedAtUtc"]).flatMap(ISO8601Timestamps.parse) != nil else { throw invalid() }
      }
      if fields["outcomeUnknown"] == .bool(true) {
        guard fields["nextAction"] == status["nextAction"] else { throw invalid() }
        return 75
      }
      if cleanup.isEmpty { guard fields["nextAction"] == .null else { throw invalid() } }
      else {
        guard case .object(let next)? = fields["nextAction"],
          Set(next.keys) == ["kind", "owner", "resource", "reasonCode"], next["kind"] == .string("cleanup"),
          next["owner"] == .object(["kind": .string("job"), "id": .string(id)]),
          case .object(let resource)? = next["resource"], Set(resource.keys) == ["kind", "id"],
          resource["kind"] == .string("cleanupDebt"), CLIJobEventPage.string(resource["id"]).map(debtIDs.contains) == true,
          next["reasonCode"] == .string("recovery.cleanupDebt") else { throw invalid() }
      }
      if evidenceExit != 0 { return evidenceExit }
      return RuntimeCLI.terminalJobExit(job)?.code ?? 0
    default: throw invalid()
    }
  }

  private static func validateStatus(_ value: JSONValue, expectedID: String?, session: CLIRuntimeSession) throws -> String {
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "jobId", "operation", "targetId", "state", "outcome", "waitingForHuman",
        "outcomeUnknown", "outstandingResidueCount", "executionMode", "sessionId", "threadId", "workspaceKind", "actualEffect",
        "createdAtUtc", "startedAtUtc", "finishedAtUtc", "supersededByRecoveryEpochId", "recoveryEpochId", "resolvedByTargetAliasResolutionId",
        "nextAction", "failure", "processProgress"],
      let id = CLIJobEventPage.string(fields["jobId"]), AgentExecutionIntent.validIdentifier(id), expectedID == nil || expectedID == id,
      fields["outcome"] == (fields["outcomeUnknown"] == .bool(true) ? .string("outcomeUnknown") : fields["state"]),
      let created = CLIJobEventPage.string(fields["createdAtUtc"]), ISO8601Timestamps.parse(created) != nil
    else { throw session.fail(.recordUnreadable, "Job status does not match its closed read schema") }
    do { _ = try RuntimeCLI.validatedObservedJobStatus(value, jobID: id, session: session) }
    catch let error as CLIRegistryError where error.code == .outcomeUnknown || error.code == .humanActionRequired {
      // Status/show query succeeds even when its next action needs attention.
    }
    return id
  }

  private static func validateTimeline(_ value: JSONValue, jobID: String, allowNull: Bool, session: CLIRuntimeSession) throws {
    if allowNull, value == .null { return }
    guard case .object(let fields) = value else { throw session.fail(.recordUnreadable, "Job timeline is unreadable") }
    switch fields["kind"] {
    case .string("inline"):
      guard Set(fields.keys) == ["kind", "entries"], case .array(let entries)? = fields["entries"],
        entries.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw session.fail(.recordUnreadable, "Job timeline is unreadable") }
    case .string("snapshotPages"):
      guard Set(fields.keys) == ["kind", "jobId", "method"], fields["method"] == .string("job.timeline"),
        fields["jobId"] == .string(jobID) else { throw session.fail(.recordUnreadable, "Job timeline reference is unreadable") }
    default: throw session.fail(.recordUnreadable, "unknown Job timeline projection")
    }
  }

  private static func validateEvidence(_ value: JSONValue, jobID: String?, session: CLIRuntimeSession) throws -> Int32 {
    guard case .object(let fields) = value, fields["schemaVersion"] == .string("arkdeck.job-evidence/1"),
      Set(fields.keys) == ["schemaVersion", "jobId", "operationReference", "catalogDigest", "targetId", "bindingRevision", "providerId",
        "actualEffect", "authority", "observation", "actualStepKinds", "executionMode", "terminalState", "outcomeUnknown", "startedAtUtc",
        "firstEvidenceStepAtUtc", "finishedAtUtc", "recoveryEpoch", "artifacts", "blockers", "status", "inventoryAvailable", "missingRequiredArtifacts"],
      jobID == nil || fields["jobId"] == .string(jobID!),
      let digest = CLIJobEventPage.string(fields["catalogDigest"]), SHA256Hex.isLowercaseSHA256(digest),
      let status = CLIJobEventPage.string(fields["status"]),
      ["verified", "artifactIntegrityFailed", "recordUnreadable", "operationUnavailable", "resultNotReady"].contains(status),
      case .array(let blockers)? = fields["blockers"], blockers.allSatisfy({ value in
        CLIJobEventPage.string(value).map(["artifactIntegrityFailed", "artifactStoreUnavailable", "recordUnreadable", "operationUnavailable", "resultNotReady"].contains) == true
      }),
      (status == "verified") == blockers.isEmpty, case .array? = fields["artifacts"],
      case .bool? = fields["inventoryAvailable"], case .array(let missing)? = fields["missingRequiredArtifacts"],
      missing.allSatisfy({ CLIJobEventPage.string($0)?.isEmpty == false })
    else { throw session.fail(.recordUnreadable, "Job evidence has no supported verification result") }
    return status == "verified" ? 0 : status == "resultNotReady" ? 75 : 2
  }
}
