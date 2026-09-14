// Shared Swift oracle for the Rust agent execution owner's list and abandonment (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's agent execution owner answering `agent.list` and `agent.abandon`
/// over the shared fake HDC (`HDCOracleFake`), the oracle the Rust owner
/// replays. First, three executions as `agent run` leaves them: one that owns
/// a completed Job, one whose target was never adopted and one whose binding
/// revision is stale, the last two left orchestrating. Then their list: every
/// one, one per page, by state, operation and target, and the requests the
/// owner and its pager refuse. Then abandonment: a stale generation, the
/// orchestrating execution abandoned and abandoned again, an execution that
/// owns a Job, an execution never created and a generation that is not
/// canonical. Last, the abandoned execution read, run again and listed.
///
/// The engine and the owner are composed on the oracle's clock
/// (`HDCOracleHarness`). The first run holds its Job's first call as
/// `AgentExecutionOracleContractTests` does, and the oracle releases it and
/// waits for the execution's durable completion before anything else. A first
/// page stores a snapshot under a random revision: the page's revision and
/// cursor are labelled, and a request naming a cursor names the exchange whose
/// page minted it.
///
/// Record a new oracle with
/// `ARKDECK_RUST_AGENT_LIFECYCLE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class AgentLifecycleOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/agent-lifecycle", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  /// The runbook's `--maximum-wait 5m`.
  private static let budget = "300000"
  /// What the oracle creates to release a held call.
  private static let released = HDCOracleFake.root.appending(path: "released")

  func testSwiftListsAndAbandonsAgentExecutionsOverTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_AGENT_LIFECYCLE_RECORD",
      oracle: Self.oracle)
  }

  /// The intent `arkdeck agent run --execution-id <id> --operation <op>
  /// --target <TGT> [--inputs-file <file>] --maximum-wait 5m` sends.
  private static func intent(
    _ executionID: String, operation: String, inputs: [String: JSONValue] = [:],
    target: [String: JSONValue]
  ) -> [String: JSONValue] {
    [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(executionID), "operation": .string(operation),
      "inputs": .object(inputs), "maximumWaitMilliseconds": .string(budget),
      "target": .object(target),
    ]
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "agent-lifecycle-oracle")
  }

  private static func result(_ answer: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = answer, case .object(let result)? = fields["result"] else {
      throw CocoaError(.coderInvalidValue)
    }
    return result
  }

  private static func code(_ answer: JSONValue) -> JSONValue? {
    guard case .object(let fields) = answer, case .object(let error)? = fields["error"] else {
      return nil
    }
    return error["code"]
  }

  /// The accepted run reads its Job while the Job starts in the background,
  /// so the state it reads is any state before the held call.
  private static func startIndependent(_ answer: JSONValue) -> JSONValue {
    guard case .object(var fields) = answer, case .object(var result)? = fields["result"] else {
      return answer
    }
    result["jobState"] = .string("<jobState>")
    if case .object(var job)? = result["job"] {
      job["state"] = .string("<jobState>")
      job["outcome"] = .string("<jobState>")
      result["job"] = .object(job)
    }
    fields["result"] = .object(result)
    return .object(fields)
  }

  /// A page names the next one by a cursor the pager mints at random, so the
  /// oracle keeps its name, not its value.
  private static func cursorIndependent(_ answer: JSONValue) -> JSONValue {
    guard case .object(var fields) = answer, case .object(var result)? = fields["result"],
      case .string? = result["nextCursor"]
    else { return answer }
    result["nextCursor"] = .string("<nextCursor>")
    fields["result"] = .object(result)
    return .object(fields)
  }

  /// Releases the held call and waits until the execution's durable record
  /// says the Job it owns completed: the owner's last write for the run.
  private static func release(awaiting executionID: String, in directory: URL) async throws {
    try Data().write(to: released)
    let record = directory.appending(
      path: "execution-\(RuntimeAgentExecutionStore.fingerprint(Data(executionID.utf8))).json")
    let deadline = Date().addingTimeInterval(60)
    while true {
      if let data = try? Data(contentsOf: record),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["state"] as? String == "completed"
      {
        return
      }
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let answers = AgentExecutionOracleContractTests.answers
    let hdc = try HDCOracleFake.install(answers: answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      agentExecutions: true)
    guard let executions = composition.agentExecutions else {
      throw CocoaError(.featureUnsupported)
    }
    let handler = composition.handler
    let target: [String: JSONValue] = ["targetId": .string(adopted.targetID)]

    var exchanges: [JSONValue] = []
    /// One recorded exchange; `before: release` releases the held call and
    /// waits for the execution's durable completion first.
    func record(
      _ name: String, _ method: String, _ params: [String: JSONValue], _ answer: JSONValue,
      mode: String? = nil, before: String? = nil
    ) {
      var exchange = HDCOracleHarness.exchange(name, method, params, answer, mode: mode)
      if let before, case .object(var fields) = exchange {
        fields["before"] = .string(before)
        exchange = .object(fields)
      }
      exchanges.append(exchange)
    }

    // Three executions as `agent run` leaves them: one owning a completed
    // Job, and two refused before a Job and left orchestrating.
    let observed = Self.intent("life-observe", operation: "observe.device@1", target: target)
    try? manager.removeItem(at: Self.released)
    try HDCOracleFake.setMode("held")
    let accepted = try await Self.send(handler, "agent.run", observed)
    let owned = try Self.result(accepted)
    guard case .string(let job)? = owned["jobId"] else { throw CocoaError(.coderInvalidValue) }
    XCTAssertEqual(owned["state"], .string("jobOwned"))
    record("observed.run", "agent.run", observed, Self.startIndependent(accepted), mode: "held")
    let observedIdentity: [String: JSONValue] = ["executionId": .string("life-observe")]
    try await Self.release(awaiting: "life-observe", in: executions.directory)
    let completed = try await Self.send(handler, "agent.status", observedIdentity)
    XCTAssertEqual(try Self.result(completed)["state"], .string("completed"))
    record("observed.status", "agent.status", observedIdentity, completed, before: "release")
    let unadopted = Self.intent(
      "life-unadopted", operation: "observe.device@1",
      target: ["targetId": .string("TGT-000000000000")])
    let unadoptedAnswer = try await Self.send(handler, "agent.run", unadopted)
    XCTAssertEqual(Self.code(unadoptedAnswer), .string("resourceNotFound"))
    record("unadopted.run", "agent.run", unadopted, unadoptedAnswer)
    let stale = Self.intent(
      "life-stale", operation: "capture.diagnostics@1", inputs: ["durationSeconds": .integer(5)],
      target: ["targetId": .string(adopted.targetID), "expectedBindingRevision": .integer(2)])
    let staleAnswer = try await Self.send(handler, "agent.run", stale)
    XCTAssertEqual(Self.code(staleAnswer), .string("bindingRevisionStale"))
    record("staleBinding.run", "agent.run", stale, staleAnswer)

    // The list: every execution, one per page, by filter, and the refusals.
    // Refused requests send only published parameter names with a wrong
    // value, since a frame's parameters enter the derived request schema.
    var cursors: [String: String] = [:]
    func list(
      _ name: String, _ sent: [String: JSONValue], recorded: [String: JSONValue]? = nil,
      refusal: String? = nil
    ) async throws {
      let answer = try await Self.send(handler, "agent.list", sent)
      if let refusal {
        XCTAssertEqual(Self.code(answer), .string(refusal), name)
      } else if case .string(let next)? = try Self.result(answer)["nextCursor"] {
        cursors[name] = next
      }
      record("list.\(name)", "agent.list", recorded ?? sent, Self.cursorIndependent(answer))
    }
    try await list("all", [:])
    try await list("page1", ["pageSize": .integer(1)])
    try await list(
      "page2", ["pageSize": .integer(1), "cursor": .string(try XCTUnwrap(cursors["page1"]))],
      recorded: ["pageSize": .integer(1), "cursor": .string("<nextCursor of list.page1>")])
    try await list(
      "page3", ["pageSize": .integer(1), "cursor": .string(try XCTUnwrap(cursors["page2"]))],
      recorded: ["pageSize": .integer(1), "cursor": .string("<nextCursor of list.page2>")])
    XCTAssertEqual(cursors.keys.sorted(), ["page1", "page2"])
    try await list("completed", ["state": .string("completed")])
    try await list("capture", ["operation": .string("capture.diagnostics@1")])
    try await list("target", ["target": .string(adopted.targetID)])
    try await list(
      "otherQuery",
      ["pageSize": .integer(2), "cursor": .string(try XCTUnwrap(cursors["page1"]))],
      recorded: ["pageSize": .integer(2), "cursor": .string("<nextCursor of list.page1>")],
      refusal: "invalidCursor")
    try await list(
      "foreignCursor", ["pageSize": .integer(1), "cursor": .string("not-a-cursor")],
      refusal: "invalidCursor")
    try await list(
      "longCursor", ["cursor": .string(String(repeating: "c", count: 257))],
      refusal: "invalidCursor")
    try await list("zeroPageSize", ["pageSize": .integer(0)], refusal: "invalidInput")
    try await list("unknownState", ["state": .string("paused")], refusal: "invalidInput")

    // Abandonment, which never cancels a Job.
    func abandon(
      _ name: String, _ executionID: String, _ generation: String, refusal: String? = nil
    ) async throws -> JSONValue {
      let params: [String: JSONValue] = [
        "executionId": .string(executionID), "expectedGeneration": .string(generation),
      ]
      let answer = try await Self.send(handler, "agent.abandon", params)
      XCTAssertEqual(Self.code(answer), refusal.map(JSONValue.string), name)
      record("abandon.\(name)", "agent.abandon", params, answer)
      return answer
    }
    _ = try await abandon("staleGeneration", "life-unadopted", "1", refusal: "resourceConflict")
    let abandoned = try Self.result(try await abandon("orchestrating", "life-unadopted", "2"))
    XCTAssertEqual(abandoned["state"], .string("abandoned"))
    XCTAssertEqual(abandoned["generation"], .string("3"))
    let again = try Self.result(try await abandon("again", "life-unadopted", "3"))
    XCTAssertEqual(again["generation"], .string("3"))
    _ = try await abandon("jobOwned", "life-observe", "7", refusal: "resourceConflict")
    _ = try await abandon("absent", "life-absent", "1", refusal: "resourceNotFound")
    _ = try await abandon("nonCanonical", "life-stale", "02", refusal: "invalidInput")

    // The abandoned execution read, run again with its intent, and listed.
    let abandonedIdentity: [String: JSONValue] = ["executionId": .string("life-unadopted")]
    record(
      "abandoned.status", "agent.status", abandonedIdentity,
      try await Self.send(handler, "agent.status", abandonedIdentity))
    record("abandoned.rerun", "agent.run", unadopted, try await Self.send(handler, "agent.run", unadopted))
    try await list("abandoned", ["state": .string("abandoned")])

    return try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "jobs": .object(["observed": .string(job)]),
        "executions": .object([
          "observed": .string("life-observe"), "unadopted": .string("life-unadopted"),
          "staleBinding": .string("life-stale"),
        ]),
        "exchanges": .array(exchanges),
      ]),
      answers: answers,
      producer:
        "AgentLifecycleOracleContractTests.testSwiftListsAndAbandonsAgentExecutionsOverTheSharedFakeDevice",
      settings: Self.settings)
  }
}
