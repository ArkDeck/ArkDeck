import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCLI
@testable import ArkDeckCore

/// What Swift's client-side `AgentRuntimeExecutor` does for a domain leaf
/// (`RuntimeCLI.runDomainOperation`), recorded for the Rust CLI to replay.
///
/// Each scenario runs the executor against a scripted local Runtime. Every
/// connection's health preflight is answered as the current Runtime answers
/// it. Each business frame is answered from the scenario's script, which is
/// built from the frames Swift's daemon recorded (`Fixtures/ControlFrames`).
/// A scripted `health` answers the next preflight instead. The oracle records:
/// - each frame the executor sent, in order, with its random identity labelled;
/// - the connections it opened;
/// - the clock reads;
/// - the outcome, or the error it threw;
/// - what the CLI makes of it: `emitAgentOutcome`'s refusal for a pause, the
///   exit and words of a failure, or `CLIRuntimeSession.mapped` of a client
///   error as `job.submit`'s;
/// - the pending human-action record it persisted.
///
/// Resume tokens are labelled `resume-<uuid>`, and the scenario's temporary
/// directory `<directory>`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_DOMAIN_EXECUTOR_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIDomainExecutorOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/domain-executor", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_DOMAIN_EXECUTOR_RECORD"

  private static let jobID = "job-4c6693b5208a9a64998bb2c199676fa7"
  private static let targetID = "TGT-9834876dcfb0"
  private static let otherTargetID = "TGT-bbbbbbbbbbbb"
  private static let projectRef = "proj-alpha"

  // MARK: - Swift's recorded daemon answers

  private static func frames(_ method: String) throws -> [JSONValue] {
    let text = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/\(method).jsonl"
      ), encoding: .utf8)
    return try text.split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  private static func recorded(
    _ method: String, _ matches: (_ params: JSONValue?, _ result: JSONValue) -> Bool
  ) throws -> JSONValue {
    for frame in try frames(method) {
      guard case .object(let fields) = frame, fields["ok"] == .bool(true),
        let result = fields["result"], matches(fields["params"], result)
      else { continue }
      return result
    }
    throw XCTSkip("Swift recorded no matching \(method) answer")
  }

  private static func member(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let fields)? = value else { return nil }
    return fields[key]
  }

  /// `value` with the member at `path` replaced, or removed for `nil`.
  private static func with(_ value: JSONValue, _ path: [String], _ replacement: JSONValue?)
    -> JSONValue
  {
    guard case .object(var fields) = value, let key = path.first else { return value }
    if path.count == 1 {
      fields[key] = replacement
    } else {
      fields[key] = with(fields[key] ?? .object([:]), Array(path.dropFirst()), replacement)
    }
    return .object(fields)
  }

  private static func describe(_ reference: String) throws -> JSONValue {
    try recorded("operation.describe") { params, _ in
      member(params, "reference") == .string(reference)
    }
  }

  private static func targets(_ rows: [(String, Int)]) -> JSONValue {
    .array(
      rows.map { id, revision -> JSONValue in
        .object([
          "adoptedAtUtc": .string("2026-08-08T00:00:00Z"),
          "bindingRevision": .integer(Int64(revision)), "displayName": .null,
          "displayNameGeneration": .string("1"), "targetId": .string(id),
          "toolVersion": .string("3.2.0f"),
        ])
      })
  }

  private struct Candidate {
    let key: String
    let state: String
    let target: (String, Int)?
  }

  private static func observations(_ candidates: [Candidate]) throws -> JSONValue {
    let snapshot = try recorded("device.observations") { _, result in
      if case .array(let rows)? = member(result, "observations") { return rows.count == 2 }
      return false
    }
    return with(
      snapshot, ["observations"],
      .array(
        candidates.enumerated().map { index, candidate -> JSONValue in
          .object([
            "adoptedTargetId": candidate.target.map { JSONValue.string($0.0) } ?? .null,
            "authorizationState": .string(candidate.state),
            "bindingRevision": candidate.target.map { JSONValue.integer(Int64($0.1)) } ?? .null,
            "candidateKey": .string(candidate.key), "deviceInformation": .null,
            "displayName": .null, "displayNameGeneration": .string("1"),
            "observationContinuity": .string("relationProven"),
            "observationId": .string("obs-00000000-0000-4000-8000-00000000000\(index)"),
            "observedFacts": .null,
          ])
        }))
  }

  private static func adopted() throws -> JSONValue {
    try recorded("target.adopt") { _, result in member(result, "outcome") == .string("adopted") }
  }

  private static func accepted(_ job: String = jobID, deduplicated: Bool = false) -> JSONValue {
    .object([
      "deduplicated": .bool(deduplicated), "jobId": .string(job),
      "newDispatchCount": .integer(0), "schemaVersion": .string("arkdeck.job-acceptance/1"),
    ])
  }

  /// Swift's recorded status of a finished Job, as this scenario's Job in
  /// `state`.
  private static func status(_ state: String, failure: Bool = false) throws -> JSONValue {
    var value = try recorded("job.run") { _, result in
      member(result, "state") == .string(failure ? "failed" : "succeeded")
    }
    for path in [["jobId"], ["nextAction", "owner", "id"], ["nextAction", "resource", "id"]] {
      value = with(value, path, .string(jobID))
    }
    value = with(value, ["sessionId"], .string("session-\(jobID)"))
    value = with(value, ["state"], .string(state))
    return with(value, ["outcome"], .string(state))
  }

  private static func evidence() throws -> JSONValue {
    try recorded("job.evidence") { params, _ in member(params, "jobId") == .string(jobID) }
  }

  private static func emptyPage() throws -> JSONValue {
    try recorded("artifact.list") { params, _ in
      member(member(params, "owner"), "id") == .string(jobID)
    }
  }

  /// A page of this Job's Artifacts, from Swift's recorded one-item page of a
  /// published Artifact. Its cursor continues the page's snapshot, as the
  /// Runtime's do.
  private static func page(_ artifactID: String, next: String?) throws -> JSONValue {
    let template = try recorded("artifact.list") { params, result in
      guard case .array(let items)? = member(result, "items") else { return false }
      return items.count == 1 && member(items.first, "status") == .string("published")
        && member(member(params, "owner"), "kind") == .string("job")
        && member(params, "pageSize") == .integer(1000)
    }
    guard case .array(let items)? = member(template, "items"), var item = items.first else {
      throw XCTSkip("Swift recorded no Artifact")
    }
    item = with(item, ["artifactId"], .string(artifactID))
    item = with(item, ["owner", "id"], .string(jobID))
    item = with(item, ["lease"], .string("lease-v1:\(jobID):\(artifactID)"))
    var page = with(template, ["items"], .array([item]))
    page = with(page, ["hasMore"], .bool(next != nil))
    let revision = "00000000-0000-4000-8000-00000000abcd"
    page = with(page, ["nextCursor"], next.map { JSONValue.string("\(revision).\($0)") } ?? .null)
    return with(page, ["snapshotRevision"], .string(revision))
  }

  private static let refusal: [String: JSONValue] = [
    "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
  ]

  // MARK: - Scenarios

  private struct Scenario {
    let name: String
    let leaf: String
    let request: RuntimeAgentExecutionRequest
    let script: [(String, ScriptedRuntime.Reply)]
    var runtimeAbsent = false
  }

  private static func request(
    _ name: String, _ operation: String, version: Int? = 1,
    inputs: [String: JSONValue] = [:], capability: String? = nil, target: String? = nil,
    execution: String? = nil
  ) -> RuntimeAgentExecutionRequest {
    RuntimeAgentExecutionRequest(
      operationID: operation, operationVersion: version, inputs: inputs,
      capabilityReference: capability, targetID: target,
      executionID: execution ?? "exec-\(name)")
  }

  private typealias Script = [(String, ScriptedRuntime.Reply)]

  private static func scenarios() throws -> [Scenario] {
    let tap: JSONValue = try describe("input.tap@1")
    let build: JSONValue = try describe("workspace.build-openharmony@1")
    let patch: JSONValue = try describe("workspace.apply-patch@1")
    let tapInputs: [String: JSONValue] = [
      "x": .integer(0), "y": .integer(0), "displayWidth": .integer(1),
      "displayHeight": .integer(1),
    ]
    let owned = Candidate(key: "AAA", state: "Connected", target: (targetID, 1))
    let free = Candidate(key: "BBB", state: "Connected", target: nil)
    let evidenceAnswer: JSONValue = try evidence()
    let emptyPageAnswer: JSONValue = try emptyPage()
    let adoptedAnswer: JSONValue = try adopted()
    let succeeded: JSONValue = try status("succeeded")
    let failed: JSONValue = try status("failed", failure: true)
    let cancelled: JSONValue = try status("cancelled")
    let running: JSONValue = try status("running")
    let recovering: JSONValue = try status("waitingForRecovery", failure: true)
    let ownedAndFree: JSONValue = try observations([owned, free])
    let ownedOnly: JSONValue = try observations([owned])
    let freeOnly: JSONValue = try observations([free])
    let noCandidates: JSONValue = try observations([])
    let twoRoutes: JSONValue = try observations([
      owned, Candidate(key: "CCC", state: "Connected", target: (targetID, 1)),
    ])
    let unauthorizedOwned: JSONValue = try observations([
      Candidate(key: "AAA", state: "Unauthorized", target: (targetID, 1))
    ])
    let offlineOwned: JSONValue = try observations([
      Candidate(key: "AAA", state: "Offline", target: (targetID, 1))
    ])
    let twoFree: JSONValue = try observations([
      free, Candidate(key: "CCC", state: "Connected", target: nil),
    ])
    let unauthorizedFree: JSONValue = try observations([
      Candidate(key: "BBB", state: "Unauthorized", target: nil)
    ])
    let first: JSONValue = try page("ART-00000000000000000000000000000001", next: "2")
    let last: JSONValue = try page("ART-00000000000000000000000000000002", next: nil)
    let again: JSONValue = try page("ART-00000000000000000000000000000002", next: "2")
    let oneTarget: JSONValue = targets([(targetID, 1)])
    let cancelRequested: JSONValue = .object(["cancelRequested": .bool(true)])

    let finished: Script = [
      ("job.evidence", .result(evidenceAnswer)), ("artifact.list", .result(emptyPageAnswer)),
    ]
    let submitted: Script = [("job.submit", .result(accepted())), ("job.run", .result(succeeded))]
    let explicitTarget: Script = [
      ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
      ("device.observations", .result(ownedOnly)),
    ]
    let noAdoptedTarget: Script = [
      ("operation.describe", .result(tap)), ("target.list", .result(targets([]))),
    ]

    var list: [Scenario] = []
    func add(
      _ name: String, _ leaf: String, _ request: RuntimeAgentExecutionRequest, _ script: Script,
      runtimeAbsent: Bool = false
    ) {
      list.append(
        Scenario(
          name: name, leaf: leaf, request: request, script: script,
          runtimeAbsent: runtimeAbsent))
    }
    let project: [String: JSONValue] = ["projectRef": .string(projectRef)]

    add(
      "hostOnlyBuild", "workspace.build",
      request("hostOnlyBuild", "workspace.build-openharmony", inputs: project),
      [("operation.describe", .result(build))] + submitted + finished)
    add(
      "hostScopeMismatch", "workspace.build",
      request(
        "hostScopeMismatch", "workspace.build-openharmony", inputs: project, target: "proj-other"),
      [("operation.describe", .result(build))])
    let patchInputs: [String: JSONValue] = [
      "projectRef": .string(projectRef),
      "patchArtifactRef": .string("lease-v1:job-import:ART-patch"),
    ]
    add(
      "hostArtifactConsumerKeepsItsTarget", "workspace.patch",
      request(
        "hostArtifactConsumerKeepsItsTarget", "workspace.apply-patch", inputs: patchInputs,
        target: otherTargetID),
      [("operation.describe", .result(patch))] + submitted + finished)
    add(
      "hostDefaultScopeSubmitRefused", "workspace.build",
      request("hostDefaultScopeSubmitRefused", "workspace.build-openharmony"),
      [
        ("operation.describe", .result(build)),
        ("job.submit", .error("admissionDenied", "the Runtime admits no such request", refusal)),
      ])
    add(
      "hostUnsafeScope", "workspace.build",
      request(
        "hostUnsafeScope", "workspace.build-openharmony",
        inputs: ["projectRef": .string("proj alpha")]),
      [("operation.describe", .result(build))])

    add(
      "explicitTargetConnected", "input.tap",
      request("explicitTargetConnected", "input.tap", inputs: tapInputs, target: targetID),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
        ("device.observations", .result(ownedAndFree)),
      ] + submitted + [
        ("job.evidence", .result(evidenceAnswer)), ("artifact.list", .result(first)),
        ("artifact.list", .result(last)),
      ])
    add(
      "explicitTargetDeduplicatedSubmit", "input.tap",
      request(
        "explicitTargetDeduplicatedSubmit", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [
        ("job.submit", .result(accepted(deduplicated: true))), ("job.run", .result(succeeded)),
      ] + finished)
    add(
      "explicitTargetNotListed", "input.tap",
      request("explicitTargetNotListed", "input.tap", inputs: tapInputs, target: targetID),
      noAdoptedTarget)
    add(
      "explicitTargetWithoutRoute", "input.tap",
      request("explicitTargetWithoutRoute", "input.tap", inputs: tapInputs, target: targetID),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
        ("device.observations", .result(freeOnly)),
      ])
    add(
      "explicitTargetAmbiguousRoutes", "input.tap",
      request("explicitTargetAmbiguousRoutes", "input.tap", inputs: tapInputs, target: targetID),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
        ("device.observations", .result(twoRoutes)),
      ])
    add(
      "explicitTargetUnauthorized", "input.tap",
      request("explicitTargetUnauthorized", "input.tap", inputs: tapInputs, target: targetID),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
        ("device.observations", .result(unauthorizedOwned)),
      ])
    add(
      "explicitTargetOffline", "input.tap",
      request("explicitTargetOffline", "input.tap", inputs: tapInputs, target: targetID),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
        ("device.observations", .result(offlineOwned)),
      ])

    add(
      "oneAdoptedTargetFailedJob", "input.tap",
      request("oneAdoptedTargetFailedJob", "input.tap", inputs: tapInputs),
      [
        ("operation.describe", .result(tap)), ("target.list", .result(targets([(targetID, 2)]))),
        ("job.submit", .result(accepted())), ("job.run", .result(failed)),
        // The refusal Swift's daemon recorded for a Job it does not know.
        ("job.evidence", .error("notFound", "the referenced Job does not exist", nil)),
        ("artifact.list", .result(emptyPageAnswer)),
      ])
    add(
      "severalAdoptedTargets", "input.tap",
      request("severalAdoptedTargets", "input.tap", inputs: tapInputs),
      [
        ("operation.describe", .result(tap)),
        ("target.list", .result(targets([(targetID, 1), (otherTargetID, 3)]))),
      ])
    add(
      "adoptsTheOneCandidateCancelledJob", "input.tap",
      request("adoptsTheOneCandidateCancelledJob", "input.tap", inputs: tapInputs),
      noAdoptedTarget + [
        ("device.observations", .result(freeOnly)), ("target.adopt", .result(adoptedAnswer)),
        ("job.submit", .result(accepted())), ("job.run", .result(cancelled)),
      ] + finished)
    add(
      "adoptionWithoutCandidates", "input.tap",
      request("adoptionWithoutCandidates", "input.tap", inputs: tapInputs),
      noAdoptedTarget + [("device.observations", .result(noCandidates))])
    add(
      "adoptionWithTwoCandidates", "input.tap",
      request("adoptionWithTwoCandidates", "input.tap", inputs: tapInputs),
      noAdoptedTarget + [("device.observations", .result(twoFree))])
    add(
      "adoptionUnauthorized", "input.tap",
      request("adoptionUnauthorized", "input.tap", inputs: tapInputs),
      noAdoptedTarget + [("device.observations", .result(unauthorizedFree))])
    add(
      "adoptionRefused", "input.tap",
      request("adoptionRefused", "input.tap", inputs: tapInputs),
      noAdoptedTarget + [
        ("device.observations", .result(freeOnly)),
        (
          "target.adopt",
          .error("targetTrustPending", "the device has not confirmed its trust prompt", refusal)
        ),
      ])

    add(
      "submitReturnsAnUnsafeJob", "input.tap",
      request("submitReturnsAnUnsafeJob", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [("job.submit", .result(accepted("job with space")))])
    add(
      "runResponseLost", "input.tap",
      request("runResponseLost", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [
        ("job.submit", .result(accepted())), ("job.run", .close),
        ("job.cancel", .result(cancelRequested)),
      ])
    add(
      "runRefusedWithoutDetails", "input.tap",
      request("runRefusedWithoutDetails", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [
        ("job.submit", .result(accepted())),
        ("job.run", .error("internalError", "the Runtime failed", nil)),
        ("job.cancel", .error("notFound", "no such Job", nil)),
      ])
    add(
      "runReturnsARunningJob", "input.tap",
      request("runReturnsARunningJob", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [
        ("job.submit", .result(accepted())), ("job.run", .result(running)),
        ("job.cancel", .result(cancelRequested)),
      ])
    add(
      "runWaitsForRecovery", "input.tap",
      request("runWaitsForRecovery", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + [("job.submit", .result(accepted())), ("job.run", .result(recovering))]
        + finished)
    add(
      "artifactPagesRepeatACursor", "input.tap",
      request("artifactPagesRepeatACursor", "input.tap", inputs: tapInputs, target: targetID),
      explicitTarget + submitted + [
        ("job.evidence", .result(evidenceAnswer)), ("artifact.list", .result(first)),
        ("artifact.list", .result(again)),
      ])

    add(
      "unsafeExecutionIdentity", "input.tap",
      request(
        "unsafeExecutionIdentity", "input.tap", inputs: tapInputs, target: targetID,
        execution: "exec with space"),
      [])
    add(
      "unsafeProvider", "input.tap",
      request("unsafeProvider", "input.tap", inputs: tapInputs, target: targetID),
      [("operation.describe", .result(with(tap, ["provider"], .string("hdc provider"))))])
    let foreignContract: JSONValue = with(
      ScriptedRuntime.health, ["contractIdentity"], .string(String(repeating: "0", count: 64)))
    add(
      "preflightFails", "input.tap",
      request("preflightFails", "input.tap", inputs: tapInputs, target: targetID),
      [("health", .result(foreignContract))])
    add(
      "capabilityWithoutVersion", "input.tap",
      request(
        "capabilityWithoutVersion", "input.tap", version: nil, inputs: tapInputs,
        capability: "CAP-RT-POLICY-0001", target: targetID),
      explicitTarget + [
        (
          "job.submit",
          .error("admissionDenied", "the capability does not cover this request", refusal)
        )
      ])
    add(
      "runtimeAbsent", "input.tap",
      request("runtimeAbsent", "input.tap", inputs: tapInputs, target: targetID), [],
      runtimeAbsent: true)
    return list
  }

  // MARK: - Recording

  private static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  private static func clientError(_ error: AgentClientError) -> JSONValue {
    switch error {
    case .connectFailed(let message):
      return .object(["case": .string("connectFailed"), "message": .string(message)])
    case .transport(let message):
      return .object(["case": .string("transport"), "message": .string(message)])
    case .malformedResponse(let message):
      return .object(["case": .string("malformedResponse"), "message": .string(message)])
    case .daemonError(let code, let message):
      return .object([
        "case": .string("daemonError"), "code": .string(code), "message": .string(message),
      ])
    case .structuredDaemonError(let code, let message, let details):
      return .object([
        "case": .string("structuredDaemonError"), "code": .string(code),
        "message": .string(message), "details": .object(details),
      ])
    case .deadlineExceeded:
      return .object(["case": .string("deadlineExceeded")])
    }
  }

  private static func session(_ leaf: String) -> CLIRuntimeSession {
    var arguments = ["--output", "json", "--socket", "/tmp/arkdeck-domain-executor-no-daemon"]
    return RuntimeCLI.runtimeSession(&arguments, command: leaf)
  }

  private static func run(_ scenario: Scenario) throws -> JSONValue {
    let runtime = try ScriptedRuntime(scenario.script)
    let clock = CountingClock()
    let state = runtime.directory.appending(path: "agent-runtime", directoryHint: .isDirectory)
    let socket =
      scenario.runtimeAbsent ? runtime.directory.appending(path: "absent").path : runtime.socketPath
    let executor = AgentRuntimeExecutor(
      client: AgentClient(socketPath: socket), stateDirectory: state,
      nowUTC: { clock.now() })
    var fields: [String: JSONValue] = [
      "name": .string(scenario.name), "leaf": .string(scenario.leaf),
      "request": try encoded(scenario.request),
      "script": .array(scenario.script.map { method, reply in reply.recorded(method) }),
      "runtimeAbsent": .bool(scenario.runtimeAbsent),
    ]
    do {
      let outcome = try executor.run(scenario.request)
      switch outcome {
      case .completed(let receipt):
        fields["outcome"] = .object([
          "kind": .string("completed"), "receipt": try encoded(receipt),
        ])
      case .awaitingHumanAction(let action, let receipt):
        fields["outcome"] = .object([
          "kind": .string("awaitingHumanAction"), "action": try encoded(action),
          "receipt": try encoded(receipt),
        ])
        do {
          try RuntimeCLI.emitAgentOutcome(outcome, session: session(scenario.leaf))
          fields["cli"] = .string("emitted")
        } catch let error as CLIRegistryError {
          fields["cli"] = .object([
            "code": .string(error.code.rawValue), "message": .string(error.message),
            "details": .object(error.details),
          ])
        }
      case .failed(let reason, let receipt):
        fields["outcome"] = .object([
          "kind": .string("failed"), "reason": .string(reason), "receipt": try encoded(receipt),
        ])
      }
    } catch let error as AgentClientError {
      fields["error"] = .object([
        "type": .string("AgentClientError"), "value": clientError(error),
      ])
      let mapped = CLIRuntimeSession.mapped(error, method: "job.submit", command: scenario.leaf)
      fields["cli"] = .object([
        "code": .string(mapped.code.rawValue), "message": .string(mapped.message),
        "details": .object(mapped.details),
      ])
    } catch let error as RuntimeAgentExecutorError {
      fields["error"] = .object([
        "type": .string("RuntimeAgentExecutorError"),
        "value": .string(String(describing: error)),
      ])
    } catch let error as AgentExecutionControlFailure {
      fields["error"] = .object([
        "type": .string("AgentExecutionControlFailure"), "code": .string(error.code),
        "message": .string(error.message),
      ])
    } catch {
      fields["error"] = .object([
        "type": .string(String(describing: type(of: error))),
        "value": .string(String(describing: error)),
      ])
    }
    var pending: [JSONValue] = []
    let names = (try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []
    for name in names.sorted() {
      let content = try Data(contentsOf: state.appending(path: name))
      pending.append(
        .object([
          "file": .string(name),
          "content": try JSONDecoder().decode(JSONValue.self, from: content),
        ]))
    }
    fields["pending"] = .array(pending)
    let served = runtime.stop()
    fields["sent"] = .array(served.sent)
    fields["connections"] = .integer(Int64(served.connections))
    fields["unusedScript"] = .array(served.unused.map(JSONValue.string))
    fields["clockReads"] = .integer(Int64(clock.reads))
    return labelled(.object(fields), directory: runtime.directory.path)
  }

  /// Random identities and paths replaced by their labels.
  private static func labelled(_ value: JSONValue, directory: String) -> JSONValue {
    switch value {
    case .string(let text):
      var text = text.replacingOccurrences(of: directory, with: "<directory>")
      text = text.replacingOccurrences(
        of: #"resume-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        with: "resume-<uuid>", options: .regularExpression)
      return .string(text)
    case .array(let values):
      return .array(values.map { labelled($0, directory: directory) })
    case .object(let fields):
      return .object(fields.mapValues { labelled($0, directory: directory) })
    default:
      return value
    }
  }

  func testSwiftDomainExecutorDecisionsTheRustCLIReplays() throws {
    let cases = try Self.scenarios().map(Self.run)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["scenarios.json"] = try encoder.encode(JSONValue.array(cases)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIDomainExecutorOracleContractTests"),
          "owners": .array([
            .string("AgentRuntimeExecutor.run"), .string("RuntimeCLI.emitAgentOutcome"),
            .string("CLIRuntimeSession.mapped"),
          ]),
          "answers": .string("Fixtures/ControlFrames"),
          "catalogDigest": .string(ScriptedRuntime.catalogDigest),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}

// MARK: - Resuming a pause

extension CLIDomainExecutorOracleContractTests {
  private static let resumeOracle = repository.appending(
    path: "rust/tests/fixtures/domain-executor-resume", directoryHint: .isDirectory)
  private static let resumeRecordVariable = "ARKDECK_RUST_DOMAIN_EXECUTOR_RESUME_RECORD"

  /// One pause and its resume: the run that paused, then
  /// `agent resume --resume-token` of its token (or of `token`, when the
  /// scenario names another) with `selection`, each phase against its own
  /// scripted Runtime over the one state directory.
  private struct ResumeScenario {
    let name: String
    let request: RuntimeAgentExecutionRequest
    let pause: Script
    let resume: Script
    var token: String? = nil
    var selection: String? = nil
    var resumeHealth: JSONValue = ScriptedRuntime.health
  }

  private static func resumeScenarios() throws -> [ResumeScenario] {
    let tap: JSONValue = try describe("input.tap@1")
    let tapInputs: [String: JSONValue] = [
      "x": .integer(0), "y": .integer(0), "displayWidth": .integer(1),
      "displayHeight": .integer(1),
    ]
    let owned = Candidate(key: "AAA", state: "Connected", target: (targetID, 1))
    let free = Candidate(key: "BBB", state: "Connected", target: nil)
    let ownedOnly: JSONValue = try observations([owned])
    let freeOnly: JSONValue = try observations([free])
    let noCandidates: JSONValue = try observations([])
    let twoFree: JSONValue = try observations([
      free, Candidate(key: "CCC", state: "Connected", target: nil),
    ])
    let adoptedAnswer: JSONValue = try adopted()
    let succeeded: JSONValue = try status("succeeded")
    let failed: JSONValue = try status("failed", failure: true)
    let oneTarget: JSONValue = targets([(targetID, 1)])
    let twoTargets: JSONValue = targets([(targetID, 1), (otherTargetID, 3)])
    let finished: Script = [
      ("job.evidence", .result(try evidence())), ("artifact.list", .result(try emptyPage())),
    ]
    let submitted: Script = [("job.submit", .result(accepted())), ("job.run", .result(succeeded))]
    let notListed: Script = [
      ("operation.describe", .result(tap)), ("target.list", .result(targets([]))),
    ]
    let listed: Script = [
      ("operation.describe", .result(tap)), ("target.list", .result(oneTarget)),
      ("device.observations", .result(ownedOnly)),
    ]
    let explicit = { (name: String) in
      request(name, "input.tap", inputs: tapInputs, target: targetID)
    }
    let anyTarget = { (name: String) in request(name, "input.tap", inputs: tapInputs) }
    let severalTargets: Script = [
      ("operation.describe", .result(tap)), ("target.list", .result(twoTargets)),
    ]
    let twoCandidates: Script = notListed + [("device.observations", .result(twoFree))]
    let changedCatalog: JSONValue = with(
      ScriptedRuntime.health, ["catalogDigest"], .string(String(repeating: "1", count: 64)))
    return [
      ResumeScenario(
        name: "reconnectResumesAndCompletes", request: explicit("reconnectResumesAndCompletes"),
        pause: notListed, resume: listed + submitted + finished),
      ResumeScenario(
        name: "reconnectResumesToAFailedJob", request: explicit("reconnectResumesToAFailedJob"),
        pause: notListed,
        resume: listed + [("job.submit", .result(accepted())), ("job.run", .result(failed))]
          + finished),
      ResumeScenario(
        name: "reconnectRefusesASelection", request: explicit("reconnectRefusesASelection"),
        pause: notListed, resume: [], selection: targetID),
      ResumeScenario(
        name: "reconnectPausesAgain", request: explicit("reconnectPausesAgain"),
        pause: notListed, resume: notListed),
      ResumeScenario(
        name: "selectedAdoptedTargetResumes", request: anyTarget("selectedAdoptedTargetResumes"),
        pause: severalTargets,
        resume: [("target.list", .result(twoTargets)), ("operation.describe", .result(tap))]
          + submitted + finished,
        selection: otherTargetID),
      ResumeScenario(
        name: "adoptedTargetNeedsASelection", request: anyTarget("adoptedTargetNeedsASelection"),
        pause: severalTargets, resume: []),
      ResumeScenario(
        name: "selectedTargetIsNotAdopted", request: anyTarget("selectedTargetIsNotAdopted"),
        pause: severalTargets, resume: [("target.list", .result(twoTargets))],
        selection: "TGT-cccccccccccc"),
      ResumeScenario(
        name: "selectedCandidateIsAdopted", request: anyTarget("selectedCandidateIsAdopted"),
        pause: twoCandidates,
        resume: [
          ("device.observations", .result(twoFree)), ("target.adopt", .result(adoptedAnswer)),
          ("operation.describe", .result(tap)),
        ] + submitted + finished,
        selection: "BBB"),
      ResumeScenario(
        name: "candidateNeedsASelection", request: anyTarget("candidateNeedsASelection"),
        pause: twoCandidates, resume: []),
      ResumeScenario(
        name: "candidateSelectionIsMalformed", request: anyTarget("candidateSelectionIsMalformed"),
        pause: twoCandidates, resume: [], selection: "BB\nB"),
      ResumeScenario(
        name: "selectedCandidateIsGone", request: anyTarget("selectedCandidateIsGone"),
        pause: twoCandidates, resume: [("device.observations", .result(twoFree))],
        selection: "ZZZ"),
      ResumeScenario(
        name: "retryAdoptionResumes", request: anyTarget("retryAdoptionResumes"),
        pause: notListed + [("device.observations", .result(noCandidates))],
        resume: notListed + [
          ("device.observations", .result(freeOnly)), ("target.adopt", .result(adoptedAnswer)),
        ] + submitted + finished),
      ResumeScenario(
        name: "catalogChangedWhilePaused", request: explicit("catalogChangedWhilePaused"),
        pause: notListed, resume: [], resumeHealth: changedCatalog),
      ResumeScenario(
        name: "malformedToken", request: explicit("malformedToken"), pause: notListed,
        resume: [], token: "resume-not a token"),
      ResumeScenario(
        name: "unknownToken", request: explicit("unknownToken"), pause: notListed, resume: [],
        token: "resume-00000000-0000-4000-8000-000000000000"),
      ResumeScenario(
        name: "tokenWithoutItsPrefix", request: explicit("tokenWithoutItsPrefix"),
        pause: notListed, resume: [], token: "token-00000000-0000-4000-8000-000000000000"),
    ]
  }

  private static func pendingRecords(_ state: URL) throws -> [JSONValue] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []
    return try names.sorted().map { name in
      .object([
        "file": .string(name),
        "content": try JSONDecoder().decode(
          JSONValue.self, from: Data(contentsOf: state.appending(path: name))),
      ])
    }
  }

  private static func outcomeRecord(
    _ outcome: RuntimeAgentExecutionOutcome, command: String
  ) throws -> [String: JSONValue] {
    var fields: [String: JSONValue] = [:]
    switch outcome {
    case .completed(let receipt):
      fields["outcome"] = .object(["kind": .string("completed"), "receipt": try encoded(receipt)])
    case .awaitingHumanAction(let action, let receipt):
      fields["outcome"] = .object([
        "kind": .string("awaitingHumanAction"), "action": try encoded(action),
        "receipt": try encoded(receipt),
      ])
      do {
        try RuntimeCLI.emitAgentOutcome(outcome, session: session(command))
        fields["cli"] = .string("emitted")
      } catch let error as CLIRegistryError {
        fields["cli"] = .object([
          "code": .string(error.code.rawValue), "message": .string(error.message),
          "details": .object(error.details),
        ])
      }
    case .failed(let reason, let receipt):
      fields["outcome"] = .object([
        "kind": .string("failed"), "reason": .string(reason), "receipt": try encoded(receipt),
      ])
    }
    return fields
  }

  private static func resume(_ scenario: ResumeScenario) throws -> JSONValue {
    let clock = CountingClock()
    let root = FileManager.default.temporaryDirectory.appending(
      path: "adr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appending(path: "agent-runtime", directoryHint: .isDirectory)
    var fields: [String: JSONValue] = [
      "name": .string(scenario.name), "request": try encoded(scenario.request),
      "pauseScript": .array(scenario.pause.map { method, reply in reply.recorded(method) }),
      "resumeScript": .array(scenario.resume.map { method, reply in reply.recorded(method) }),
      "resumeHealth": scenario.resumeHealth,
      "selection": scenario.selection.map(JSONValue.string) ?? .null,
    ]

    let pauseRuntime = try ScriptedRuntime(scenario.pause)
    let paused = try AgentRuntimeExecutor(
      client: AgentClient(socketPath: pauseRuntime.socketPath), stateDirectory: state,
      nowUTC: { clock.now() }
    ).run(scenario.request)
    _ = pauseRuntime.stop()
    guard case .awaitingHumanAction(let action, _) = paused else {
      XCTFail("\(scenario.name) did not pause")
      return .null
    }
    fields["pause"] = .object(try outcomeRecord(paused, command: "input.tap"))
    fields["pendingAfterPause"] = .array(try pendingRecords(state))
    let token = scenario.token ?? action.resumeToken
    fields["token"] = .string(token)
    fields["tokenIsThePauses"] = .bool(scenario.token == nil)

    let runtime = try ScriptedRuntime(scenario.resume, health: scenario.resumeHealth)
    let executor = AgentRuntimeExecutor(
      client: AgentClient(socketPath: runtime.socketPath), stateDirectory: state,
      nowUTC: { clock.now() })
    do {
      let outcome = try executor.resume(resumeToken: token, selection: scenario.selection)
      fields["resume"] = .object(try outcomeRecord(outcome, command: "agent.resume"))
    } catch let error as AgentClientError {
      fields["resume"] = .object([
        "error": .object(["type": .string("AgentClientError"), "value": clientError(error)])
      ])
    } catch let error as RuntimeAgentExecutorError {
      fields["resume"] = .object([
        "error": .object([
          "type": .string("RuntimeAgentExecutorError"),
          "value": .string(String(describing: error)),
        ])
      ])
    }
    fields["pendingAfterResume"] = .array(try pendingRecords(state))
    let served = runtime.stop()
    fields["resumeSent"] = .array(served.sent)
    fields["resumeConnections"] = .integer(Int64(served.connections))
    fields["unusedScript"] = .array(served.unused.map(JSONValue.string))
    fields["clockReads"] = .integer(Int64(clock.reads))
    return labelled(.object(fields), directory: root.path)
  }

  func testSwiftDomainExecutorResumesTheRustCLIReplays() throws {
    let cases = try Self.resumeScenarios().map(Self.resume)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["scenarios.json"] = try encoder.encode(JSONValue.array(cases)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIDomainExecutorOracleContractTests"),
          "owners": .array([
            .string("AgentRuntimeExecutor.run"), .string("AgentRuntimeExecutor.resume"),
            .string("RuntimeCLI.emitAgentOutcome"),
          ]),
          "answers": .string("Fixtures/ControlFrames"),
          "catalogDigest": .string(ScriptedRuntime.catalogDigest),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.resumeRecordVariable, oracle: Self.resumeOracle)
  }
}

/// Reads of a fixed clock, one second apart.
private final class CountingClock: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func now() -> String {
    lock.withLock {
      count += 1
      return String(format: "2026-09-25T00:00:%02dZ", count)
    }
  }

  var reads: Int { lock.withLock { count } }
}

/// A local Runtime answering from a script: never a production Runtime or a
/// device transport. Each connection's health preflight is answered as the
/// current Runtime answers it, unless the script's next entry is `health`;
/// each business frame takes the script's next entry, which must name its
/// method. `close` ends the connection unanswered.
private final class ScriptedRuntime: @unchecked Sendable {
  enum Reply {
    case result(JSONValue)
    case error(String, String, [String: JSONValue]?)
    case close

    func recorded(_ method: String) -> JSONValue {
      switch self {
      case .result(let result):
        return .object(["method": .string(method), "result": result])
      case .error(let code, let message, let details):
        var error: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let details { error["details"] = .object(details) }
        return .object(["method": .string(method), "error": .object(error)])
      case .close:
        return .object(["method": .string(method), "close": .bool(true)])
      }
    }
  }

  static let catalogDigest = "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684"
  static let health: JSONValue = .object([
    "status": .string("ok"), "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
    "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
    "publishedMethods": .array(ArkDeckControlProtocol.methods.sorted().map(JSONValue.string)),
    "catalogDigest": .string(catalogDigest), "providers": .array([]),
  ])

  let directory: URL
  let socketPath: String
  /// What this Runtime answers a `health` the script does not name.
  private let healthAnswer: JSONValue
  private let listener: Int32
  private let lock = NSLock()
  private var script: [(String, Reply)]
  private var sent: [JSONValue] = []
  private var connections = 0
  private var stopping = false
  private let finished = DispatchSemaphore(value: 0)

  init(_ script: [(String, Reply)], health: JSONValue = ScriptedRuntime.health) throws {
    self.script = script
    healthAnswer = health
    directory = FileManager.default.temporaryDirectory.appending(
      path: "ade-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    socketPath = directory.appending(path: "s").path
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      path.utf8CString.withUnsafeBytes { source in buffer.copyMemory(from: source) }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
    DispatchQueue.global().async { [self] in serve() }
  }

  /// Stops serving: what was sent, over how many connections, and the script
  /// left unused.
  func stop() -> (sent: [JSONValue], connections: Int, unused: [String]) {
    lock.withLock { stopping = true }
    finished.wait()
    close(listener)
    try? FileManager.default.removeItem(at: directory)
    return lock.withLock { (sent, connections, script.map(\.0)) }
  }

  private func serve() {
    defer { finished.signal() }
    while true {
      var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let polled = poll(&ready, 1, 50)
      if polled <= 0 {
        if lock.withLock({ stopping }) { return }
        continue
      }
      let connection = accept(listener, nil, nil)
      guard connection >= 0 else { continue }
      lock.withLock { connections += 1 }
      handle(connection)
      close(connection)
    }
  }

  private static func label(_ id: String) -> String {
    let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    if id.range(of: "^agent-\(uuid)$", options: .regularExpression) != nil {
      return "agent-<uuid>"
    }
    if id.range(of: "^\(uuid.uppercased())$", options: .regularExpression) != nil {
      return "<UUID>"
    }
    return id
  }

  private func handle(_ connection: Int32) {
    var suppress: Int32 = 1
    _ = setsockopt(
      connection, SOL_SOCKET, SO_NOSIGPIPE, &suppress,
      socklen_t(MemoryLayout.size(ofValue: suppress)))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout.size(ofValue: timeout)))
    var buffer = Data()
    while let line = Self.line(connection, &buffer) {
      guard let frame = try? JSONDecoder().decode(JSONValue.self, from: line),
        case .object(let fields) = frame, case .string(let id)? = fields["id"],
        case .string(let method)? = fields["method"]
      else { return }
      let label = Self.label(id)
      var logged: [String: JSONValue] = ["method": .string(method), "id": .string(label)]
      if let params = fields["params"] { logged["params"] = params }
      let reply: Reply? = lock.withLock {
        sent.append(.object(logged))
        let preflight = method == "health" && label == "<UUID>"
        if method == "health", !(preflight && script.first?.0 == "health") {
          return .result(healthAnswer)
        }
        guard let next = script.first, next.0 == method else {
          sent.append(.object(["unscripted": .string(method)]))
          return nil
        }
        script.removeFirst()
        return next.1
      }
      switch reply {
      case nil, .close?:
        return
      case .result(let result)?:
        respond(connection, .object(["id": .string(id), "ok": .bool(true), "result": result]))
      case .error(let code, let message, let details)?:
        var error: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let details { error["details"] = .object(details) }
        respond(connection, .object(["id": .string(id), "ok": .bool(false), "error": .object(error)]))
      }
    }
  }

  private static func line(_ connection: Int32, _ buffer: inout Data) -> Data? {
    while true {
      if let end = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<end])
        buffer.removeSubrange(buffer.startIndex...end)
        return line
      }
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = read(connection, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk.prefix(count))
    }
  }

  private func respond(_ connection: Int32, _ value: JSONValue) {
    guard var bytes = try? CanonicalJSONEncoders.canonical().encode(value) else { return }
    bytes.append(0x0A)
    _ = bytes.withUnsafeBytes { Darwin.write(connection, $0.baseAddress!, $0.count) }
  }
}
