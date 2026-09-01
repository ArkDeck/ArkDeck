import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckRuntime
import Darwin
import Foundation

extension RuntimeCLI {
  static func usesRuntimeExecution(_ arguments: [String]) -> Bool {
    if let verb = arguments.first, ["list", "status", "abandon"].contains(verb) { return true }
    return arguments.contains { [
      "--require-protocol", "--resume-reference", "--selection-file", "--request-file", "--maximum-wait",
      "--timeout", "--expected-binding-revision", "--request-id", "--idempotency-key", "--reviewed-plan-digest",
    ].contains($0) }
  }

  static func runRuntimeExecution(_ arguments: [String], family: String = "agent") async throws {
    guard let verb = arguments.first else { throw CLIError(exitCode: EX_USAGE, message: "execution subcommand is required") }
    var rest = Array(arguments.dropFirst())
    let command = "\(family).\(verb)"
    var session = runtimeSession(&rest, command: command)
    let options = try CLIOptions(rest)
    let params: [String: JSONValue]
    switch (family, verb) {
    case ("agent", "run"):
      params = try runtimeExecutionIntent(options, session: session).fields
    case ("agent", "status"), ("agent", "abandon"):
      guard let id = options.value("--execution-id"), AgentExecutionIntent.validIdentifier(id) else {
        throw session.fail(.invalidInput, "an exact execution identity is required")
      }
      var value: [String: JSONValue] = ["executionId": .string(id)]
      if verb == "abandon" {
        guard let generation = options.value("--expected-generation"), let number = Int64(generation),
          number > 0, String(number) == generation else { throw session.fail(.invalidInput, "a positive generation is required") }
        value["expectedGeneration"] = .string(generation)
      }
      params = value
    case (_, "resume"):
      guard let reference = options.value("--resume-reference") ?? options.value("--resume-token"),
        AgentExecutionIntent.validIdentifier(reference) else { throw session.fail(.invalidInput, "an exact resume reference is required") }
      var value: [String: JSONValue] = ["resumeReference": .string(reference)]
      if family == "human-action" {
        guard let id = options.value("--human-action"), AgentExecutionIntent.validIdentifier(id) else {
          throw session.fail(.invalidInput, "an exact human-action identity is required")
        }
        value["humanAction"] = .string(id)
      }
      if let selection = options.value("--selection") { value["selection"] = .string(selection) }
      if let path = options.value("--selection-file") {
        guard value["selection"] == nil else { throw session.fail(.invalidInput, "selection sources are exclusive") }
        value["selection"] = try executionInputDocument(path, maximumBytes: 65_536, session: session)
      }
      params = value
    case ("human-action", "show"):
      guard let id = options.value("--human-action"), AgentExecutionIntent.validIdentifier(id) else {
        throw session.fail(.invalidInput, "an exact human-action identity is required")
      }
      params = ["humanAction": .string(id)]
    case (_, "list"):
      var value: [String: JSONValue] = [:]
      for (flag, key) in [("--state", "state"), ("--operation", "operation"), ("--target", "target"),
        ("--owner-kind", "ownerKind"), ("--owner", "owner"), ("--cursor", "cursor")] {
        if let text = options.value(flag) { value[key] = .string(text) }
      }
      guard (value["ownerKind"] == nil) == (value["owner"] == nil) else {
        throw session.fail(.invalidInput, "owner-kind and owner must be supplied together")
      }
      if let text = options.value("--page-size"), let count = Int64(text) { value["pageSize"] = .integer(count) }
      params = value
    default: throw session.fail(.invalidCommand, "unsupported Runtime execution command")
    }
    let deadline: AgentClientWaitDeadline?
    if let text = options.value("--timeout") {
      guard let duration = CLIDuration.parse(text, maximumMilliseconds: 86_400_000) else {
        throw session.fail(.invalidInput, "timeout must be a bounded duration")
      }
      deadline = try AgentClientWaitDeadline(milliseconds: duration.milliseconds)
      if let deadline { session.client = session.client.bounded(by: deadline) }
    } else { deadline = nil }
    var identity = params["executionId"]
    do {
      try session.negotiate(requiredMajor: 2, forMethod: command)
      var result = try session.request(command, params)
      if family == "human-action", verb == "resume" {
        if case .object(let challenge) = result,
          challenge["schemaVersion"] == .string("arkdeck.impact-approval-challenge/1")
        {
          let response = try readHDCImpactChallenge(challenge, session: session)
          var resumed = params
          resumed["challengeResponse"] = .string(response)
          result = try session.request(command, resumed)
          try emitHDCControlActionResult(result, session: session)
          return
        }
        if case .object(let action) = result,
          action["schemaVersion"] == .string("arkdeck.human-action/1"),
          case .object(let owner)? = action["owner"],
          owner["kind"] == .string("controlAction")
        {
          throw session.fail(
            .humanActionRequired,
            "impact approval requires the same foreground interactive console",
            details: ["humanAction": result])
        }
      }
      guard verb == "run" || verb == "resume" else {
        if family == "agent", verb == "status" || verb == "abandon" { _ = try executionFields(result, session: session) }
        session.emit(result)
        return
      }
      var interval = 100
      while true {
        let fields = try executionFields(result, session: session)
        identity = fields["executionId"]
        if try emitSettledExecution(fields, session: session) { return }
        guard case .string(let id)? = identity else { throw session.fail(.recordUnreadable, "execution has no identity") }
        try deadline?.check()
        let wait = min(interval, deadline?.remainingMilliseconds ?? interval)
        try await Task.sleep(for: .milliseconds(wait))
        try deadline?.check()
        result = try session.request("agent.status", ["executionId": .string(id)])
        interval = min(interval * 2, 2000)
      }
    } catch AgentClientError.deadlineExceeded {
      throw session.fail(.clientTimeout, "client stopped waiting; the Runtime execution and Job were not cancelled",
        details: identity.map { ["executionId": $0] } ?? [:])
    } catch is CancellationError {
      throw session.fail(.clientInterrupted, "client stopped waiting; no abandon or cancellation was requested",
        details: identity.map { ["executionId": $0] } ?? [:])
    } catch var error as CLIRegistryError {
      if let identity { error.details["executionId"] = identity }
      throw error
    }
  }

  private static func readHDCImpactChallenge(
    _ challenge: [String: JSONValue], session: CLIRuntimeSession
  ) throws -> String {
    guard isatty(STDIN_FILENO) == 1,
      challenge["schemaVersion"] == .string("arkdeck.impact-approval-challenge/1"),
      challenge["interactionOrigin"] == .string("interactiveConsole"),
      case .string(let expected)? = challenge["challenge"],
      expected.utf8.count == 17, expected.hasPrefix("ARKDECK-"),
      case .object(let controlAction)? = challenge["controlAction"],
      controlAction["schemaVersion"] == .string("arkdeck.control-action/1"),
      controlAction["state"] == .string("awaitingImpactApproval"),
      case .string(let controlActionID)? = controlAction["controlActionId"],
      case .object(let preview)? = controlAction["preview"],
      let validatedPreview = try? HDCControlActionPreview(value: preview),
      validatedPreview.value["controlActionId"] == .string(controlActionID),
      case .object(let humanAction)? = challenge["humanAction"],
      humanAction["schemaVersion"] == .string("arkdeck.human-action/1"),
      case .string(let humanActionID)? = humanAction["actionId"],
      case .object(let binding)? = challenge["binding"],
      binding["controlActionId"] == .string(controlActionID),
      binding["humanActionId"] == .string(humanActionID),
      binding["previewId"] == validatedPreview.value["previewId"],
      binding["previewDigest"] == validatedPreview.value["previewDigest"]
    else {
      throw session.fail(
        .recordUnreadable,
        "Runtime impact challenge lacks its immutable control-action preview")
    }
    let review = JSONValue.object([
      "controlActionId": controlAction["controlActionId"]!,
      "generation": controlAction["generation"]!,
      "preview": .object(preview),
    ])
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    guard let bytes = try? encoder.encode(review),
      let rendered = String(data: bytes, encoding: .utf8)
    else {
      throw session.fail(.internalError, "could not render the immutable HDC impact preview")
    }
    FileHandle.standardError.write(
      Data(
        ("Review the complete immutable HDC restart impact:\n"
          + rendered + "\nType this one-time challenge exactly: \(expected)\n> ").utf8))
    var input = Data()
    while input.count <= 64 {
      var byte: UInt8 = 0
      let count = Darwin.read(STDIN_FILENO, &byte, 1)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw session.fail(.ioFailure, "could not read the foreground impact challenge")
      }
      if byte == 10 || byte == 13 { break }
      guard byte >= 32, byte != 127 else {
        throw session.fail(.invalidInput, "impact challenge contains invalid console bytes")
      }
      input.append(byte)
    }
    guard input.count <= 64, let response = String(data: input, encoding: .utf8),
      response == expected
    else {
      throw session.fail(
        .admissionDenied, "the typed impact challenge did not match; zero dispatch")
    }
    return response
  }

  private static func emitHDCControlActionResult(
    _ value: JSONValue, session: CLIRuntimeSession
  ) throws {
    guard case .object(let fields) = value,
      fields["schemaVersion"] == .string("arkdeck.control-action/1"),
      case .string(let state)? = fields["state"],
      case .integer(let dispatchCount)? = fields["dispatchCount"],
      (0...1).contains(dispatchCount)
    else {
      throw session.fail(.recordUnreadable, "HDC restart returned no valid control action")
    }
    session.emit(value)
    switch state {
    case "succeeded": return
    case "failed":
      throw session.fail(
        .operationFailed, "HDC restart failed before a confirmed external effect",
        details: ["controlAction": value])
    case "outcomeUnknown":
      throw session.fail(
        .outcomeUnknown, "HDC restart entered its launch window and requires reconciliation",
        details: ["controlAction": value])
    default:
      throw session.fail(
        dispatchCount == 0 ? .admissionDenied : .outcomeUnknown,
        "HDC restart did not reach a trustworthy terminal state",
        details: ["controlAction": value])
    }
  }

  static func runtimeExecutionIntent(_ options: CLIOptions, session: CLIRuntimeSession) throws -> AgentExecutionIntent {
    guard let duration = CLIDuration.parse(options.value("--maximum-wait") ?? "5m", maximumMilliseconds: 86_400_000) else {
      throw session.fail(.invalidInput, "maximum-wait must be a bounded duration")
    }
    var fields: [String: JSONValue] = [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(options.value("--execution-id") ?? UUID().uuidString.lowercased()),
      "maximumWaitMilliseconds": .string(String(duration.milliseconds)),
    ]
    if let path = options.value("--request-file") {
      let value = try executionInputDocument(path, maximumBytes: 3_145_728, session: session)
      guard case .object(let document) = value,
        Set(document.keys).isSubset(of: ["documentType", "schemaVersion", "requestId", "idempotencyKey", "target",
          "operation", "inputs", "requestedOutputs", "authorization", "clientContext", "reviewedPlanDigest"]) else {
        throw session.fail(.invalidInput, "request-file must be a closed typed operation request")
      }
      do {
        let bytes = try CanonicalJSONEncoders.canonical().encode(value)
        let request = try RuntimeOperationCodec.decodeRequest(bytes)
        fields["requestId"] = .string(request.requestID)
        fields["idempotencyKey"] = .string(request.idempotencyKey)
        fields["operation"] = .string(request.operation.reference)
        fields["inputs"] = .object(request.inputs)
        fields["target"] = document["target"]
        fields["requestedOutputs"] = .array(request.requestedOutputs.map { .string($0.rawValue) })
        fields["capabilityReference"] = request.authorization.map { .string($0.capabilityID) }
        fields["clientContext"] = document["clientContext"]
        fields["reviewedPlanDigest"] = document["reviewedPlanDigest"]
      } catch { throw session.fail(.invalidInput, "request-file failed typed request validation") }
    } else {
      fields["operation"] = options.value("--operation").map(JSONValue.string)
      fields["inputs"] = try options.value("--inputs-file").map {
        try executionInputDocument($0, maximumBytes: 3_145_728, session: session)
      } ?? .object([:])
      if let target = options.value("--target") {
        var value: [String: JSONValue] = ["targetId": .string(target)]
        if let revision = options.value("--expected-binding-revision"), let number = Int64(revision) {
          value["expectedBindingRevision"] = .integer(number)
        }
        fields["target"] = .object(value)
      } else if options.value("--expected-binding-revision") != nil {
        throw session.fail(.invalidInput, "expected-binding-revision requires an explicit target")
      }
      for (flag, key) in [("--request-id", "requestId"), ("--idempotency-key", "idempotencyKey"),
        ("--capability", "capabilityReference"), ("--reviewed-plan-digest", "reviewedPlanDigest")] {
        fields[key] = options.value(flag).map(JSONValue.string)
      }
    }
    do { return try AgentExecutionIntent(fields) }
    catch let error as AgentExecutionControlFailure {
      throw session.fail(CLIErrorCode(rawValue: error.code) ?? .invalidInput, error.message)
    }
  }

  private static func executionInputDocument(_ path: String, maximumBytes: Int, session: CLIRuntimeSession) throws -> JSONValue {
    do {
      let handle = path == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(filePath: path))
      defer { if path != "-" { try? handle.close() } }
      var data = Data()
      while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= maximumBytes else { throw session.fail(.inputTooLarge, "input document exceeds its byte bound") }
      }
      return try CLIStrictJSON.decode(data)
    } catch let error as CLIRegistryError { throw error }
    catch { throw session.fail(.invalidInput, "cannot read a bounded strict UTF-8 JSON document") }
  }

  private static func executionFields(_ value: JSONValue, session: CLIRuntimeSession) throws -> [String: JSONValue] {
    let required: Set<String> = ["schemaVersion", "executionId", "generation", "operation", "catalogDigest",
      "createdAt", "deadline", "lastObservedAt", "state", "targetId", "bindingRevision", "jobId", "jobState",
      "outcomeUnknown", "failureCode", "humanAction", "nextAction"]
    guard case .object(let fields) = value, fields["schemaVersion"] == .string("arkdeck.agent-execution/1"),
      required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["job", "evidence", "artifacts"])),
      case .string(let id)? = fields["executionId"], AgentExecutionIntent.validIdentifier(id),
      case .string(let state)? = fields["state"], AgentExecutionState(rawValue: state) != nil,
      case .string(let generation)? = fields["generation"], let number = Int64(generation), number > 0,
      String(number) == generation else { throw session.fail(.recordUnreadable, "invalid Runtime execution projection") }
    func unreadable() -> CLIRegistryError { session.fail(.recordUnreadable, "execution owner, Job or next-action projection is inconsistent") }
    if case .string(let jobID)? = fields["jobId"] {
      guard AgentExecutionIntent.validIdentifier(jobID), case .object(let job)? = fields["job"],
        job["jobId"] == .string(jobID), job["state"] == fields["jobState"], job["outcomeUnknown"] == fields["outcomeUnknown"],
        case .string(let raw)? = job["state"], let jobState = JobState(rawValue: raw),
        (state == "completed") == jobState.isTerminal,
        job["outcome"] == .string(fields["outcomeUnknown"] == .bool(true) ? "outcomeUnknown" : raw) else { throw unreadable() }
      if jobState.isTerminal {
        guard case .object(let evidence)? = fields["evidence"], evidence["jobId"] == .string(jobID),
          evidence["catalogDigest"] == fields["catalogDigest"], case .array(let blockers)? = evidence["blockers"],
          blockers.allSatisfy({ if case .string = $0 { return true }; return false }),
          evidence["status"] == .string(blockers.isEmpty ? "verified" : "blocked"),
          case .array(let artifacts)? = evidence["artifacts"], fields["artifacts"] == .array(artifacts),
          artifacts.allSatisfy({ artifact in
            guard case .object(let row) = artifact, row["jobId"] == .string(jobID), row["bytesVerified"] == .bool(true),
              case .string(let digest)? = row["sha256"], digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
            return true
          }) else { throw unreadable() }
      }
    } else if fields["jobId"] != .null || fields["job"] != nil || state == "completed" { throw unreadable() }
    if let next = fields["nextAction"], next != .null {
      guard case .object(let action) = next, case .string(let kind)? = action["kind"],
        case .object(let owner)? = action["owner"], Set(owner.keys) == ["kind", "id"],
        case .object(let resource)? = action["resource"], Set(resource.keys) == ["kind", "id"] else { throw unreadable() }
      let base: Set<String> = ["kind", "owner", "resource", "reasonCode"]
      switch kind {
      case "humanAction":
        guard Set(action.keys) == base.union(["resumeReference", "expiresAt"]), state == "waitingForHuman",
          owner == ["kind": .string("agentExecution"), "id": .string(id)],
          case .object(let har)? = fields["humanAction"], har["owner"] == .object(owner),
          har["schemaVersion"] == .string("arkdeck.human-action/1"), har["status"] == .string("waiting"),
          resource["kind"] == .string("humanAction"), resource["id"] == har["actionId"],
          action["resumeReference"] == har["resumeReference"], action["expiresAt"] == har["expiresAt"],
          action["reasonCode"] == har["reasonCode"] else { throw unreadable() }
      case "wait", "reconcile", "readResult":
        let expectedOwner = fields["jobId"] == .null
          ? ["kind": JSONValue.string("agentExecution"), "id": .string(id)]
          : ["kind": JSONValue.string("job"), "id": fields["jobId"]!]
        guard owner == expectedOwner, resource == owner,
          Set(action.keys) == (kind == "wait" ? base.union(["retryAfter"]) : base) else { throw unreadable() }
        if kind == "wait" {
          guard case .string(let hint)? = action["retryAfter"], CLIDuration.parse(hint, maximumMilliseconds: 86_400_000) != nil,
            action["reasonCode"] == .string(fields["jobId"] == .null ? "agent.orchestrationPending" : "job.running") else { throw unreadable() }
        } else {
          guard fields["jobId"] != .null,
            action["reasonCode"] == .string(kind == "reconcile" ? "recovery.outcomeUnknown" : "job.resultAvailable") else { throw unreadable() }
        }
      default: throw unreadable()
      }
    } else if state == "waitingForHuman" { throw unreadable() }
    return fields
  }

  private static func emitSettledExecution(_ fields: [String: JSONValue], session: CLIRuntimeSession) throws -> Bool {
    let details = ["execution": JSONValue.object(fields)]
    if fields["state"] == .string("waitingForHuman") {
      guard case .object(let action)? = fields["humanAction"], case .string(let reference)? = action["resumeReference"],
        AgentExecutionIntent.validIdentifier(reference) else { throw session.fail(.recordUnreadable, "waiting execution has no exact physical action") }
      session.progress("Physical assistance required. Resume with: arkdeck agent resume --resume-reference \(reference)")
      throw session.fail(.humanActionRequired, "Runtime execution is paused for the published physical action", details: details)
    }
    if fields["state"] == .string("abandoned") {
      var result = fields
      result["executionOutcome"] = .string("abandoned")
      session.emit(.object(result))
      throw CLIError(exitCode: 1, message: "execution was abandoned; no Job was cancelled")
    }
    if case .string(let code)? = fields["failureCode"], let reason = CLIErrorCode(rawValue: code) {
      throw session.fail(reason, "execution stopped before Job creation", details: details)
    }
    if fields["outcomeUnknown"] == .bool(true) {
      session.emit(.object(fields))
      throw session.fail(.outcomeUnknown, "inspect and reconcile the existing Job; its intent must not be replayed")
    }
    if fields["state"] == .string("completed") {
      guard let job = fields["job"], let evidence = fields["evidence"] else {
        throw session.fail(.recordUnreadable, "terminal execution lacks its bounded Job result and evidence")
      }
      session.emit(.object(fields))
      if let failure = evidenceIntegrityExit(evidence) { throw session.fail(.artifactIntegrityFailed, failure) }
      if let exit = terminalJobExit(job) { throw CLIError(exitCode: exit.code, message: exit.reason) }
      return true
    }
    if case .object(let job)? = fields["job"], job["waitingForHuman"] == .bool(true) {
      throw session.fail(.humanActionRequired, "the existing Job requires its Runtime-owned physical assistance", details: details)
    }
    return false
  }
}
