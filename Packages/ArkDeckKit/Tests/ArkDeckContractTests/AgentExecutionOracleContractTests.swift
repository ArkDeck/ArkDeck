// Shared Swift oracle for the Rust agent execution owner (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift agent executions with an explicit target over the shared fake HDC
/// (`HDCOracleFake`), the oracle the Rust agent execution owner replays:
/// Golden Journey 1's two runs as its runbook (§2) sends them -
/// `agent run --operation observe.device@1 --target <TGT> --maximum-wait 5m`
/// and the same with `capture.diagnostics@1` and `{"durationSeconds": 5}`,
/// the target without a binding revision, which the owner pins, and no
/// request file - then the owner's refusals before a Job, and the pages of an
/// Artifact list. The daemon's agent execution owner is composed with the
/// engine on the oracle's clock (`HDCOracleHarness`).
///
/// A run answers once its Job is owned, while the Job starts in the
/// background, so the fake holds the Job's first call (mode `held`) until the
/// oracle has read the running execution, then the oracle releases it and
/// waits for the execution's durable completion. The Job state the accepted
/// run reads is any state before that held call; the oracle keeps its name,
/// not its value. Each run is then read again, sent again with the same
/// intent (answered from the execution, without a new dispatch) and with
/// another budget under the same identity (`idempotencyConflict`), and its
/// Job's result, evidence and Artifacts are read; the observed Job's
/// Artifacts are also paged one at a time, and a cursor of another query, a
/// foreign cursor, an empty cursor and an absent Job owner are refused. The
/// refusals before a Job: a target never adopted and a stale binding revision
/// (each leaves its execution orchestrating), a budget outside its bound, an
/// operation the Catalog does not publish, inputs the operation rejects and an
/// execution never created. The oracle keeps every answer (a cursor by the
/// exchange whose page named it), each call the fake received, and the store:
/// the Target document, the Job index and files, every Artifact, the Sessions,
/// the storage owner and every agent execution record.
///
/// Record a new oracle with
/// `ARKDECK_RUST_AGENT_EXECUTION_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class AgentExecutionOracleContractTests: XCTestCase {
  private struct Run {
    let name: String
    let executionID: String
    let operation: String
    let inputs: [String: JSONValue]
  }

  /// Golden Journey 1's two runs, as its runbook sends them.
  private static let runs: [Run] = [
    Run(name: "observed", executionID: "gj1-observe", operation: "observe.device@1", inputs: [:]),
    Run(
      name: "captured", executionID: "gj1-capture", operation: "capture.diagnostics@1",
      inputs: ["durationSeconds": .integer(5)]),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/agent-execution", directoryHint: .isDirectory)
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

  /// The capture oracle's answers, which also answer everything
  /// `observe.device@1` asks, behind a guard that holds every call of a
  /// `held` run until the oracle creates `released`. A Job calls one at a
  /// time, so its first call is the one held, whichever it is: `-v` for
  /// `observe.device@1`, `list targets -v` for `capture.diagnostics@1`.
  static let answers =
    #"""
    # A held run: its Job's first call waits until the oracle releases it.
    if [ "$mode" = held ]; then
      while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ]; do /bin/sleep 0.01; done
    fi

    """# + CaptureDiagnosticsOracleContractTests.answers

  func testSwiftRunsAgentExecutionsOverTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_AGENT_EXECUTION_RECORD",
      oracle: Self.oracle)
  }

  /// The intent `arkdeck agent run --execution-id <id> --operation <op>
  /// [--target <TGT>] [--inputs-file <file>] --maximum-wait 5m` sends.
  private static func intent(
    _ executionID: String, operation: String, inputs: [String: JSONValue] = [:],
    target: [String: JSONValue]?, budget: String = budget
  ) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(executionID), "operation": .string(operation),
      "inputs": .object(inputs), "maximumWaitMilliseconds": .string(budget),
    ]
    if let target { fields["target"] = .object(target) }
    return fields
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "agent-execution-oracle")
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

  /// Waits until the fake has logged a call beyond its first `count` bytes:
  /// the held Job's first call, well inside the call's 15 s budget.
  private static func awaitHeldCall(after count: Int) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try HDCOracleFake.invocations().count <= count {
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
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
    let hdc = try HDCOracleFake.install(answers: Self.answers)
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
    /// One recorded exchange; `before` names what a replay does first:
    /// `heldCall` waits for the held Job's first call, `release` releases it
    /// and waits for the execution's durable completion.
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

    var jobs: [(name: String, job: String)] = []
    for run in Self.runs {
      let intent = Self.intent(
        run.executionID, operation: run.operation, inputs: run.inputs, target: target)
      try? manager.removeItem(at: Self.released)
      try HDCOracleFake.setMode("held")
      let calls = try HDCOracleFake.invocations().count
      let accepted = try await Self.send(handler, "agent.run", intent)
      let owned = try Self.result(accepted)
      guard case .string(let job)? = owned["jobId"], case .string(let state)? = owned["jobState"]
      else { throw CocoaError(.coderInvalidValue) }
      XCTAssertEqual(owned["state"], .string("jobOwned"), run.name)
      XCTAssertEqual(JobState(rawValue: state)?.isTerminal, false, run.name)
      jobs.append((run.name, job))
      record("\(run.name).run", "agent.run", intent, Self.startIndependent(accepted), mode: "held")
      try await Self.awaitHeldCall(after: calls)
      let identity: [String: JSONValue] = ["executionId": .string(run.executionID)]
      let running = try await Self.send(handler, "agent.status", identity)
      XCTAssertEqual(try Self.result(running)["state"], .string("jobOwned"), run.name)
      record("\(run.name).running", "agent.status", identity, running, before: "heldCall")
      try await Self.release(awaiting: run.executionID, in: executions.directory)
      let completed = try await Self.send(handler, "agent.status", identity)
      XCTAssertEqual(try Self.result(completed)["jobState"], .string("succeeded"), run.name)
      record("\(run.name).status", "agent.status", identity, completed, before: "release")
      record(
        "\(run.name).rerun", "agent.run", intent, try await Self.send(handler, "agent.run", intent))
      let rebudgeted = Self.intent(
        run.executionID, operation: run.operation, inputs: run.inputs, target: target,
        budget: "600000")
      let conflict = try await Self.send(handler, "agent.run", rebudgeted)
      XCTAssertEqual(Self.code(conflict), .string("idempotencyConflict"), run.name)
      record("\(run.name).conflict", "agent.run", rebudgeted, conflict)
      let reads: [(String, String, [String: JSONValue])] = [
        ("result", "job.result", ["jobId": .string(job)]),
        ("evidence", "job.evidence", ["jobId": .string(job)]),
        (
          "artifacts", "artifact.list",
          [
            "owner": .object(["kind": .string("job"), "id": .string(job)]),
            "pageSize": .integer(1000),
          ]
        ),
      ]
      for (read, method, params) in reads {
        record(
          "\(run.name).\(read)", method, params, try await Self.send(handler, method, params))
      }
    }

    // The observed Job's three Artifacts, one page each, then the cursors
    // the pager refuses and an owner that does not exist.
    let owner = JSONValue.object(["kind": .string("job"), "id": .string(jobs[0].job)])
    var cursors: [String: String] = [:]
    for (page, previous) in [("page1", nil), ("page2", "page1"), ("page3", "page2")] as [(String, String?)] {
      var sent: [String: JSONValue] = ["owner": owner, "pageSize": .integer(1)]
      var recorded = sent
      if let previous {
        sent["cursor"] = .string(try XCTUnwrap(cursors[previous]))
        recorded["cursor"] = .string("<nextCursor of observed.\(previous)>")
      }
      let answer = try await Self.send(handler, "artifact.list", sent)
      if case .string(let next)? = try Self.result(answer)["nextCursor"] { cursors[page] = next }
      record("observed.\(page)", "artifact.list", recorded, Self.cursorIndependent(answer))
    }
    XCTAssertEqual(cursors.keys.sorted(), ["page1", "page2"])
    let refusedPages: [(String, [String: JSONValue], [String: JSONValue], String)] = [
      (
        "otherQuery",
        ["owner": owner, "pageSize": .integer(2), "cursor": .string(try XCTUnwrap(cursors["page1"]))],
        ["owner": owner, "pageSize": .integer(2), "cursor": .string("<nextCursor of observed.page1>")],
        "invalidCursor"
      ),
      (
        "foreignCursor",
        ["owner": owner, "pageSize": .integer(1), "cursor": .string("not-a-cursor")],
        ["owner": owner, "pageSize": .integer(1), "cursor": .string("not-a-cursor")],
        "invalidCursor"
      ),
      (
        "emptyCursor",
        ["owner": owner, "pageSize": .integer(1), "cursor": .string("")],
        ["owner": owner, "pageSize": .integer(1), "cursor": .string("")],
        "invalidCursor"
      ),
      (
        "absentOwner",
        [
          "owner": .object([
            "kind": .string("job"), "id": .string("job-\(String(repeating: "0", count: 32))"),
          ]),
          "pageSize": .integer(1),
        ],
        [
          "owner": .object([
            "kind": .string("job"), "id": .string("job-\(String(repeating: "0", count: 32))"),
          ]),
          "pageSize": .integer(1),
        ],
        "resourceNotFound"
      ),
    ]
    for (name, sent, recorded, code) in refusedPages {
      let answer = try await Self.send(handler, "artifact.list", sent)
      XCTAssertEqual(Self.code(answer), .string(code), name)
      record("observed.\(name)", "artifact.list", recorded, answer)
    }

    // Refused before a Job.
    let refusals: [(String, [String: JSONValue], String)] = [
      (
        "unadopted",
        Self.intent(
          "gj1-unadopted", operation: "observe.device@1",
          target: ["targetId": .string("TGT-000000000000")]),
        "resourceNotFound"
      ),
      (
        "staleBinding",
        Self.intent(
          "gj1-stale", operation: "observe.device@1",
          target: ["targetId": .string(adopted.targetID), "expectedBindingRevision": .integer(2)]),
        "bindingRevisionStale"
      ),
      (
        "budgetOutOfBound",
        Self.intent("gj1-budget", operation: "observe.device@1", target: target, budget: "0"),
        "invalidInput"
      ),
      (
        "unpublishedOperation",
        Self.intent("gj1-unpublished", operation: "observe.device@2", target: target),
        "invalidInput"
      ),
      (
        "rejectedInputs",
        Self.intent(
          "gj1-inputs", operation: "capture.diagnostics@1",
          inputs: ["durationSeconds": .integer(0)], target: target),
        "invalidInput"
      ),
    ]
    for (name, intent, code) in refusals {
      let answer = try await Self.send(handler, "agent.run", intent)
      XCTAssertEqual(Self.code(answer), .string(code), name)
      record("\(name).run", "agent.run", intent, answer)
    }
    let absent: [String: JSONValue] = ["executionId": .string("gj1-absent")]
    let unknown = try await Self.send(handler, "agent.status", absent)
    XCTAssertEqual(Self.code(unknown), .string("resourceNotFound"))
    record("absentExecution.status", "agent.status", absent, unknown)

    return try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "executions": .object(
          Dictionary(
            uniqueKeysWithValues: Self.runs.map { ($0.name, JSONValue.string($0.executionID)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer: "AgentExecutionOracleContractTests.testSwiftRunsAgentExecutionsOverTheSharedFakeDevice",
      settings: Self.settings)
  }
}
