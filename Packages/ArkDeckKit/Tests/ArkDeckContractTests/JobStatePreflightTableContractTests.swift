// The shared Job-state preflight table (`spec/recovery/job-state-preflight.json`)
// pinned to the Swift implementation, and the oracle the Rust classifier
// replays (TASK-XPA-014, recovery port slice 4).
//
// Design §G.4 asks for the restart and cutover predicate to be written once,
// in `spec/`, and shared by both implementations. The table classes every Job
// state as blocking, parked (an outcomeUnknown lane, carried over and never
// replayed: ADR-0009 decision 2, ruled 2026-09-19) or terminal, and states the
// agent-execution, capability-use and restart rules beside it. This test
// holds it to what Swift does:
// - its Job states are exactly `JobState`'s, and a state is terminal exactly
//   when `JobState.isTerminal` says so;
// - its agent-execution states and capability-use outcomes are exactly the
//   Swift enums' (an exhaustive switch here fails to compile if either grows);
// - `RuntimeCLI.classifyAgentdRestartCurrentJobs`, the carrier of
//   `runtime service restart`'s carry-over, preserves a current Job exactly
//   when the table's restart rule does, over every state and every flag.
//
// It records, for the Rust replay, the table's bytes and every restart case
// with Swift's decision. Record with `ARKDECK_RUST_JOB_STATE_PREFLIGHT_RECORD=
// /private/tmp/<new directory>`; otherwise the checked-in oracle must match.
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckStorage

final class JobStatePreflightTableContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let tablePath = "spec/recovery/job-state-preflight.json"
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/job-state-preflight", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_JOB_STATE_PREFLIGHT_RECORD"

  private static func table() throws -> (bytes: Data, value: [String: JSONValue]) {
    let bytes = try Data(contentsOf: repository.appending(path: tablePath))
    guard case .object(let value) = try JSONDecoder().decode(JSONValue.self, from: bytes) else {
      throw CocoaError(.coderInvalidValue)
    }
    return (bytes, value)
  }

  private static func words(_ value: JSONValue?) throws -> [String: String] {
    guard case .object(let object)? = value else { throw CocoaError(.coderInvalidValue) }
    return try object.mapValues { word in
      guard case .string(let word) = word else { throw CocoaError(.coderInvalidValue) }
      return word
    }
  }

  /// Every `AgentExecutionState`, spelled; adding a case fails to compile.
  private static func word(_ state: AgentExecutionState) -> String {
    switch state {
    case .orchestrating: "orchestrating"
    case .waitingForHuman: "waitingForHuman"
    case .creatingJob: "creatingJob"
    case .jobOwned: "jobOwned"
    case .completed: "completed"
    case .failed: "failed"
    case .abandoned: "abandoned"
    case .budgetExpired: "budgetExpired"
    case .clockUntrusted: "clockUntrusted"
    }
  }

  private static let agentExecutionStates: [AgentExecutionState] = [
    .orchestrating, .waitingForHuman, .creatingJob, .jobOwned, .completed, .failed, .abandoned,
    .budgetExpired, .clockUntrusted,
  ]

  /// Every `RuntimeCapabilityUseOutcome`, spelled; adding a case fails to
  /// compile.
  private static func word(_ outcome: RuntimeCapabilityUseOutcome) -> String {
    switch outcome {
    case .pending: "pending"
    case .confirmed: "confirmed"
    case .safeToReflash: "safeToReflash"
    case .outcomeUnknown: "outcomeUnknown"
    }
  }

  private static let capabilityUseOutcomes: [RuntimeCapabilityUseOutcome] = [
    .pending, .confirmed, .safeToReflash, .outcomeUnknown,
  ]

  func testTheTableIsSwiftsJobStatesAndRecordsTheRestartOracle() throws {
    let (bytes, table) = try Self.table()
    guard case .string("arkdeck.job-state-preflight/1")? = table["schemaVersion"] else {
      return XCTFail("schema version")
    }

    // Job states: exactly JobState's, terminal exactly as isTerminal says,
    // and parked only for the outcomeUnknown lane.
    let states = try Self.words(table["states"])
    XCTAssertEqual(Set(states.keys), Set(JobState.allCases.map(\.rawValue)))
    for state in JobState.allCases {
      let word = states[state.rawValue]
      XCTAssertEqual(word == "terminal", state.isTerminal, state.rawValue)
      XCTAssertTrue(["blocking", "parked", "terminal"].contains(word), state.rawValue)
    }
    XCTAssertEqual(states.filter { $0.value == "parked" }.keys.sorted(), ["waitingForRecovery"])
    XCTAssertEqual(table["unlistedState"], .string("blocking"))

    // Agent executions and capability uses: exactly the Swift vocabularies.
    let executions = try Self.words(table["agentExecutionStates"])
    XCTAssertEqual(Set(executions.keys), Set(Self.agentExecutionStates.map(Self.word)))
    for state in Self.agentExecutionStates {
      XCTAssertEqual(executions[Self.word(state)] == "terminal", state.isTerminal, Self.word(state))
    }
    let uses = try Self.words(table["capabilityUseOutcomes"])
    XCTAssertEqual(Set(uses.keys), Set(Self.capabilityUseOutcomes.map(Self.word)))
    XCTAssertEqual(uses["pending"], "unsettled")
    XCTAssertEqual(uses["outcomeUnknown"], "parked")

    // The restart rule: Swift's classifier over every state (and one it does
    // not know) and every flag it reads, one current Job per case.
    func row(
      _ id: String, state: String, outcomeUnknown: Bool = true, waitingForHuman: Bool = false,
      residue: Int64 = 0, processProgress: JSONValue = .null,
      finishedAtUTC: JSONValue = .string("2026-08-09T03:15:26Z")
    ) -> JSONValue {
      .object([
        "jobId": .string(id), "state": .string(state),
        "outcomeUnknown": .bool(outcomeUnknown), "waitingForHuman": .bool(waitingForHuman),
        "outstandingResidueCount": .integer(residue), "processProgress": processProgress,
        "finishedAtUtc": finishedAtUTC,
      ])
    }
    var rows: [JSONValue] = []
    for state in JobState.allCases.map(\.rawValue) + ["futureState"] {
      rows.append(row("job-\(state)-closed-unknown", state: state))
      rows.append(row("job-\(state)-known", state: state, outcomeUnknown: false))
      rows.append(row("job-\(state)-human", state: state, waitingForHuman: true))
      rows.append(row("job-\(state)-residue", state: state, residue: 1))
      rows.append(
        row("job-\(state)-process", state: state,
          processProgress: .object(["phase": .string("running")])))
      rows.append(row("job-\(state)-unfinished", state: state, finishedAtUTC: .null))
      rows.append(row("job-\(state)-finished-empty", state: state, finishedAtUTC: .string("")))
    }
    let classified = try RuntimeCLI.classifyAgentdRestartCurrentJobs(rows)
    let preserved = Set(classified.preservedUnknownJobIDs)
    for value in rows {
      guard case .object(let fields) = value, case .string(let id)? = fields["jobId"],
        case .string(let state)? = fields["state"]
      else { return XCTFail("row") }
      let parked = states[state] == "parked"
      let expected = parked && id.hasSuffix("-closed-unknown")
      XCTAssertEqual(preserved.contains(id), expected, id)
    }
    XCTAssertEqual(
      Set(classified.blockingJobIDs).union(preserved).count, rows.count,
      "every current Job is either preserved or blocking")

    // Rows the classifier refuses before classifying anything.
    let malformed: [(String, JSONValue)] = [
      ("missing-job-id", .object(["state": .string("waitingForRecovery")])),
      ("empty-job-id", row("", state: "waitingForRecovery")),
      ("state-not-string", {
        guard case .object(var fields) = row("job-a", state: "waitingForRecovery") else { return .null }
        fields["state"] = .integer(1)
        return .object(fields)
      }()),
      ("unknown-not-bool", {
        guard case .object(var fields) = row("job-a", state: "waitingForRecovery") else { return .null }
        fields["outcomeUnknown"] = .string("true")
        return .object(fields)
      }()),
      ("residue-not-integer", {
        guard case .object(var fields) = row("job-a", state: "waitingForRecovery") else { return .null }
        fields["outstandingResidueCount"] = .number(0.5)
        return .object(fields)
      }()),
      ("human-missing", {
        guard case .object(var fields) = row("job-a", state: "waitingForRecovery") else { return .null }
        fields.removeValue(forKey: "waitingForHuman")
        return .object(fields)
      }()),
      ("not-an-object", .string("job-a")),
    ]
    var refusals: [JSONValue] = []
    for (name, value) in malformed {
      do {
        _ = try RuntimeCLI.classifyAgentdRestartCurrentJobs([row("job-good", state: "running"), value])
        XCTFail("\(name) must be refused")
      } catch let error as CLIError {
        XCTAssertEqual(error.exitCode, 69, name)
        refusals.append(
          .object(["name": .string(name), "row": value, "exitCode": .integer(Int64(error.exitCode))]))
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["table.json"] = bytes
    files["restart.json"] =
      try encoder.encode(
        JSONValue.object([
          "rows": .array(rows),
          "blockingJobIds": .array(classified.blockingJobIDs.map(JSONValue.string)),
          "preservedUnknownJobIds": .array(classified.preservedUnknownJobIDs.map(JSONValue.string)),
          "refusals": .array(refusals),
        ])) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    let provenance: [String: JSONValue] = [
      "producer": .string(
        "JobStatePreflightTableContractTests.testTheTableIsSwiftsJobStatesAndRecordsTheRestartOracle"),
      "table": .string(Self.tablePath),
      "restartClassifier": .string(
        "Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift RuntimeCLI.classifyAgentdRestartCurrentJobs"),
      "files": .object(digests),
    ]
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
