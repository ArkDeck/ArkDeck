// Shared Swift oracle for the Rust reconcile of a parked mutation by its
// dedicated readback (TASK-XPA-014, recovery port slice 2; ADR-0009
// decisions 2 and 4 as ruled on 2026-09-19).
//
// Over the shared fake HDC (`HDCOracleFake`), one device is adopted and a
// `port-forward.create@1` Job runs while `fport` dies on SIGKILL before it
// writes the rule: the outcome of the create is unknown, its mutation intent
// outstanding and its capability use `outcomeUnknown`. The daemon starts
// twice (`recoverActiveJobs`), and `job.reconcile` resolves it by the
// create's dedicated readback — one `fport ls`, which lists no such rule — as
// confirmed not executed: the Job fails and the use is resolved
// `safeToReflash` (the ledger's `resolvesUnknown`). A second create under the
// same capability is then admitted and dies the same way after it wrote its
// rule; after one more start its readback lists the rule, so reconcile
// confirms it completed and the Job waits at its confirmed safe boundary,
// its use still `outcomeUnknown` until the Job resumes; a third create is
// refused. The oracle keeps every answer, the store (Job index and files,
// capability store) before the first start, after every start and after
// every step, every Job's reads, the capability store and every call the
// fake received. What the oracle keeps and how it is composed is
// `HDCOracleHarness`.
//
// Record a new oracle with
// `ARKDECK_RUST_READBACK_RECONCILE_RECORD=/private/tmp/<new directory>`;
// otherwise the checked-in oracle must match byte for byte.

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class ReadbackReconcileOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/readback-reconcile", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// `port-forward.create@1` and its readback, answered as the port-forward
  /// oracle answers them; by mode, `fport` creating a rule dies on SIGKILL
  /// before it writes the rule (`createKilledBefore`) or after it
  /// (`createKilledAfter`).
  private static let answers = #"""
    # port-forward.create@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    marker() { printf '%s/device-rule-%s' "$root" "$(printf '%s' "$*" | tr ': ' '__')"; }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key fport ls")
      for rule in "$root"/device-rule-*; do
        [ -e "$rule" ] || continue
        IFS= read -r row < "$rule"
        printf '%s    %s\n' "$key" "$row"
      done ;;
    "-t $key fport rm "*)
      rule=$(marker "$5" "$6")
      if [ ! -e "$rule" ]; then
        printf '[Fail]Remove forward ruler failed, ruler is not exist\n'
        exit 1
      fi
      rm -f "$rule"
      printf 'Remove forward ruler success, ruler:%s %s\n' "$5" "$6" ;;
    "-t $key fport tcp:"*)
      [ "$mode" = createKilledBefore ] && kill -KILL $$
      printf '%s %s    [Forward]\n' "$4" "$5" > "$(marker "$4" "$5")"
      [ "$mode" = createKilledAfter ] && kill -KILL $$
      printf 'Forwardport result:OK\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftReconcilesParkedPortRulesByTheirDedicatedReadback() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_READBACK_RECONCILE_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ name: String, local: Int64, remote: Int64, target: String)
    throws -> String
  {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-readback-\(name)"),
      "idempotencyKey": .string("idem-readback-\(name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string("port-forward.create"), "version": .integer(1)]),
      "inputs": .object([
        "direction": .string("forward"), "localPort": .integer(local),
        "remotePort": .integer(remote),
      ]),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "readback-reconcile-oracle")
  }

  /// The Job store and the capability store as a reader finds them, under
  /// `prefix`: the index and every file below them (each Job record's
  /// machine facts as labels), and the calls the fake has received so far.
  private static func snapshot(
    _ composition: HDCOracleHarness.Composition, prefix: String
  ) throws -> [String: Data] {
    let manager = FileManager.default
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "\(prefix)/index.json":
        try encoder.encode(try HDCOracleHarness.index(of: composition.jobsState))
        + Data("\n".utf8),
      "\(prefix)/hdc-invocations.log": try HDCOracleFake.invocations(),
    ]
    for directory in ["jobs", "capabilities"] {
      let root = composition.jobsState.appending(path: directory, directoryHint: .isDirectory)
      for path in try manager.subpathsOfDirectory(atPath: root.path).sorted() {
        let url = root.appending(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        guard metadata.st_mode & S_IFMT != S_IFDIR else { continue }
        let data = try Data(contentsOf: url)
        files["\(prefix)/\(directory)/\(path)"] =
          url.lastPathComponent == "job-record.json"
          ? HDCOracleHarness.machineIndependent(data) : data
      }
    }
    return files
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
    var composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings)

    var exchanges: [JSONValue] = []
    var files: [String: Data] = [:]
    var steps: [JSONValue] = []
    var jobIDs: [String: String] = [:]

    func record(_ name: String) throws {
      files.merge(try Self.snapshot(composition, prefix: "steps/\(name)")) { _, new in new }
      steps.append(.string(name))
    }
    func submit(_ name: String, local: Int64, remote: Int64) async throws -> JSONValue {
      let params: [String: JSONValue] = [
        "requestJson": .string(
          try Self.requestJSON(name, local: local, remote: remote, target: adopted.targetID))
      ]
      let answer = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(HDCOracleHarness.exchange("\(name).submit", "job.submit", params, answer))
      if case .object(let fields) = answer, case .object(let result)? = fields["result"],
        case .string(let jobID)? = result["jobId"]
      {
        jobIDs[name] = jobID
      }
      try record("\(name).submit")
      return answer
    }
    func run(_ name: String, mode: String) async throws -> JSONValue {
      try HDCOracleFake.setMode(mode)
      let params: [String: JSONValue] = ["jobId": .string(jobIDs[name]!)]
      let answer = try await Self.send(composition.handler, "job.run", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(name).run", "job.run", params, answer, mode: mode))
      try HDCOracleFake.setMode("normal")
      try record("\(name).run")
      return answer
    }
    func start(_ name: String) async throws {
      composition = try HDCOracleHarness.composition(
        hdc: hdc, targetStore: try RuntimeTargetStore(directoryURL: targets), targets: targets,
        settings: Self.settings)
      let recovered = try await composition.engine.recoverActiveJobs()
      exchanges.append(
        .object([
          "name": .string(name), "method": .string("recoverActiveJobs"),
          "answer": .array(try recovered.map { try RuntimeJobReadProjection.status($0) }),
        ]))
      try record(name)
    }
    func reconcile(_ name: String, job: String) async throws -> JSONValue {
      let params: [String: JSONValue] = ["jobId": .string(jobIDs[job]!)]
      let answer = try await Self.send(composition.handler, "job.reconcile", params)
      exchanges.append(HDCOracleHarness.exchange(name, "job.reconcile", params, answer))
      try record(name)
      return answer
    }
    func state(_ answer: JSONValue) -> JSONValue? {
      guard case .object(let fields) = answer, case .object(let result)? = fields["result"] else {
        return nil
      }
      return result["state"]
    }

    // A create killed before it writes its rule parks unknown; two starts
    // carry it; its readback lists no rule, so it is confirmed not executed.
    _ = try await submit("killedBefore", local: 23461, remote: 34571)
    let killedBefore = try await run("killedBefore", mode: "createKilledBefore")
    XCTAssertEqual(state(killedBefore), .string("waitingForRecovery"))
    let capabilityDirectory = composition.jobsState.appending(
      path: "capabilities", directoryHint: .isDirectory)
    let parkedCapabilities = try [
      "runtime-capabilities.json", "runtime-capabilities.ledger",
    ].map { ($0, try Data(contentsOf: capabilityDirectory.appending(path: $0))) }
    try await start("restart")
    try await start("secondRestart")
    let reconciledBefore = try await reconcile("reconcileKilledBefore", job: "killedBefore")
    XCTAssertEqual(state(reconciledBefore), .string("failed"))
    _ = try await reconcile("reconcileKilledBeforeAgain", job: "killedBefore")

    // The production crash window after that reconcile: the journal and the
    // terminal Job are durable, the capability outcome append is not. As
    // Swift's own contract test recreates it
    // (`testTerminalLineageRepairsWithoutRedispatchForReconcileAndNextSubmit`),
    // the capability store's files are put back as they stood when the Job
    // parked. Reconcile repairs the lineage from the journal's proof without
    // a dispatch; put back again, the next submission repairs it before it
    // materializes.
    func loseTheOutcome(_ name: String) throws {
      for (file, data) in parkedCapabilities {
        try DurableFileWriter.createOrReplaceAtomically(
          destination: capabilityDirectory.appending(path: file), data: data)
      }
      exchanges.append(
        .object([
          "name": .string(name), "method": .string("restoreParkedCapabilityStore"),
          "answer": .array(parkedCapabilities.map { .string($0.0) }),
        ]))
      try record(name)
    }
    try loseTheOutcome("killedBeforeOutcomeLost")
    _ = try await reconcile("reconcileKilledBeforeRepairs", job: "killedBefore")
    try loseTheOutcome("killedBeforeOutcomeLostAgain")

    // The submission repairs the use to safe to reflash, so the create is
    // admitted; killed after it wrote its rule, it parks unknown; after a
    // start its readback lists the rule, so it is confirmed completed.
    _ = try await submit("killedAfter", local: 23462, remote: 34572)
    let killedAfter = try await run("killedAfter", mode: "createKilledAfter")
    XCTAssertEqual(state(killedAfter), .string("waitingForRecovery"))
    try await start("thirdRestart")
    _ = try await reconcile("reconcileKilledAfter", job: "killedAfter")
    _ = try await reconcile("reconcileKilledAfterAgain", job: "killedAfter")

    // Its use is still unknown until the Job resumes: a third create is
    // refused.
    let third = try await submit("thirdCreate", local: 23463, remote: 34573)
    if case .object(let fields) = third, case .object(let error)? = fields["error"] {
      XCTAssertEqual(error["code"], .string("admissionDenied"))
    } else {
      XCTFail("the third create was admitted: \(third)")
    }

    for name in ["killedBefore", "killedAfter"] {
      let params: [String: JSONValue] = ["jobId": .string(jobIDs[name]!)]
      for method in ["job.status", "job.show", "job.result", "job.evidence"] {
        exchanges.append(
          HDCOracleHarness.exchange(
            "\(name).\(method)", method, params,
            try await Self.send(composition.handler, method, params)))
      }
    }
    let capabilities = try await Self.send(composition.handler, "capability.list", [:])
    exchanges.append(
      HDCOracleHarness.exchange("capabilities.list", "capability.list", [:], capabilities))
    guard case .object(let listed) = capabilities, case .array(let items)? = listed["result"]
    else { throw CocoaError(.coderInvalidValue) }
    for (index, item) in items.enumerated() {
      guard case .object(let fields) = item, case .string(let id)? = fields["capabilityId"]
      else { throw CocoaError(.coderInvalidValue) }
      let params: [String: JSONValue] = ["capabilityId": .string(id)]
      exchanges.append(
        HDCOracleHarness.exchange(
          "capabilities.inspect\(index)", "capability.inspect", params,
          try await Self.send(composition.handler, "capability.inspect", params)))
    }
    let recorded = try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "jobs": .object(jobIDs.mapValues(JSONValue.string)),
        "steps": .array(steps),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "ReadbackReconcileOracleContractTests.testSwiftReconcilesParkedPortRulesByTheirDedicatedReadback",
      settings: Self.settings)
    files.merge(recorded) { _, new in new }
    return files
  }
}
