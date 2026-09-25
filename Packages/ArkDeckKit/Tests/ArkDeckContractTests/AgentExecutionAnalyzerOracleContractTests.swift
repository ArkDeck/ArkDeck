// Shared Swift oracle for a host-only agent execution (CHG-2026-074,
// TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

/// A Swift agent execution of `analyzer.extract-crash-signature@1`, the
/// oracle `rust/crates/arkdeck-hoststore/tests/agent_execution_analyzer.rs`
/// replays: the intent `arkdeck agent run --operation
/// analyzer.extract-crash-signature@1 --target <TGT> --inputs-file <file>`
/// sends, over a crash listing collected from that Target, with the daemon's
/// agent execution owner and the analyzer provider composed beside the shared
/// fake HDC (`HDCOracleHarness`). Unlike a device run, the owned Job binds no
/// device: the execution's Artifacts and evidence carry no binding revision
/// and no stable identity, which is what the published `agent.run` and
/// `agent.status` results must admit.
///
/// A run answers once its Job is owned, while the Job starts in the
/// background, so the oracle analyzer holds until the oracle creates
/// `released`; the oracle keeps the name of the Job state the accepted run
/// reads, not its value. It then releases the analyzer, waits for the
/// execution's durable completion and reads the execution, sends the same
/// intent again, and reads the Job's result, evidence and Artifacts. The
/// oracle analyzer answers with Swift's analysis of the source, computed here
/// and written into its bytes.
///
/// Record a new oracle with
/// `ARKDECK_RUST_AGENT_EXECUTION_ANALYZER_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class AgentExecutionAnalyzerOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/agent-execution-analyzer", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let executionID = "analyzer-run"
  /// What the oracle creates to release the held analyzer.
  private static let released = HDCOracleFake.root.appending(path: "released")
  /// The crash listing the execution analyzes.
  private static let source = Data(
    "Fault log list:\n******\ncppcrash-com.example.demo-20010039-20260914000000\n******\n".utf8)

  /// The oracle analyzer: it waits for the oracle's release, then prints
  /// Swift's analysis of the source.
  private static func analyzerBytes() throws -> Data {
    let analysis = String(
      decoding: try HarnessCrashLedgerDerivedAnalyzer.analyze(source), as: UTF8.self)
    let lines = [
      "#!/bin/sh",
      "# ArkDeck host-only agent execution oracle analyzer. It holds until the",
      "# oracle releases it, then answers with Swift's analysis of the source.",
      #"[ "$#" -eq 2 ] && [ "$1" = "--analyze-crash-ledger" ] || exit 64"#,
      "while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ] &&",
      #"  kill -0 "$PPID" 2>/dev/null; do"#,
      "  /bin/sleep 0.01",
      "done",
      "printf '%s' '" + analysis + "'",
    ]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  func testSwiftCompletesAHostOnlyAgentExecution() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_AGENT_EXECUTION_ANALYZER_RECORD",
      oracle: Self.oracle)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(
      handler, method, params, frameID: "agent-execution-analyzer-oracle")
  }

  private static func result(_ answer: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = answer, case .object(let result)? = fields["result"] else {
      throw CocoaError(.coderInvalidValue)
    }
    return result
  }

  /// The accepted run reads its Job while the Job starts in the background,
  /// so the state it reads is any state before the analyzer answers.
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

  /// Releases the held analyzer and waits until the execution's durable
  /// record says the Job it owns completed: the owner's last write for the
  /// run.
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
    let hdc = try HDCOracleFake.install(answers: "")
    defer { try? manager.removeItem(at: Self.settings.root) }
    let analyzerBytes = try Self.analyzerBytes()
    let analyzer = Self.settings.root.appending(path: "analyzer")
    try analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record
    let profile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path, executableSHA256: AnalyzerProvider.sha256(analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30)
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      agentExecutions: true, analyzers: [profile])
    guard let executions = composition.agentExecutions else {
      throw CocoaError(.featureUnsupported)
    }
    let handler = composition.handler
    // The crash listing, collected from the adopted Target.
    let collected = try await composition.artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-oracle-source", sessionID: "HTASK-AGENTANALYZER",
        stepID: "capture-crash-index", name: "crash-index.txt", mediaType: "text/plain",
        privacy: .standard, retentionClass: .default,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: adopted.targetID, bindingRevision: adopted.bindingRevision,
          stableIdentitySHA256: adopted.stablePhysicalIdentitySHA256),
        contents: Self.source))
    let lease = try await composition.artifactStore.leaseReference(
      jobID: collected.jobID, artifactID: collected.artifactID)
    let intent: [String: JSONValue] = [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(Self.executionID),
      "operation": .string("analyzer.extract-crash-signature@1"),
      "inputs": .object(["sourceArtifactRef": .string(lease)]),
      "target": .object(["targetId": .string(adopted.targetID)]),
      "maximumWaitMilliseconds": .string("300000"),
    ]

    var exchanges: [JSONValue] = []
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
    try? manager.removeItem(at: Self.released)
    let accepted = try await Self.send(handler, "agent.run", intent)
    let owned = try Self.result(accepted)
    guard case .string(let job)? = owned["jobId"], case .string(let state)? = owned["jobState"]
    else { throw CocoaError(.coderInvalidValue) }
    XCTAssertEqual(owned["state"], .string("jobOwned"))
    XCTAssertEqual(JobState(rawValue: state)?.isTerminal, false)
    record("analyzer.run", "agent.run", intent, Self.startIndependent(accepted), mode: "held")
    try await Self.release(awaiting: Self.executionID, in: executions.directory)
    let identity: [String: JSONValue] = ["executionId": .string(Self.executionID)]
    let completed = try await Self.send(handler, "agent.status", identity)
    let fields = try Self.result(completed)
    XCTAssertEqual(fields["state"], .string("completed"))
    XCTAssertEqual(fields["jobState"], .string("succeeded"))
    record("analyzer.status", "agent.status", identity, completed, before: "release")
    record("analyzer.rerun", "agent.run", intent, try await Self.send(handler, "agent.run", intent))
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
      record("analyzer.\(read)", method, params, try await Self.send(handler, method, params))
    }

    var files = try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "job": .string(job),
        "executionId": .string(Self.executionID),
        "exchanges": .array(exchanges),
      ]),
      answers: "",
      producer:
        "AgentExecutionAnalyzerOracleContractTests.testSwiftCompletesAHostOnlyAgentExecution",
      settings: Self.settings)
    files["analyzer"] = analyzerBytes
    return files
  }
}
