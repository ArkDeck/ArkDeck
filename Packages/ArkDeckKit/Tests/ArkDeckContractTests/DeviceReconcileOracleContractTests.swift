// Shared Swift oracle for the Rust recovery of parked device Jobs
// (TASK-XPA-014, recovery port slice 2; ADR-0009 decision 2 as ruled on
// 2026-09-19).
//
// Over the shared fake HDC (`HDCOracleFake`), one device is adopted and three
// Jobs run: an `observe.device@1` that succeeds, an `observe.device@1` whose
// version probe answers nothing, parked in `waitingForRecovery` with its
// read-only intent outstanding, and an `input.tap@1` the injector acknowledges
// as another gesture, parked with its mutation intent outstanding and its
// capability use `outcomeUnknown`. The daemon then starts twice over the same
// root (`recoverActiveJobs`), each parked Job is reconciled twice through
// `job.reconcile`, the succeeded one once, and a new tap is submitted under
// the same capability. The oracle keeps every answer, the store before the
// first start, after each start and after each reconcile, every Job's reads,
// the capability store and every call the fake received — which none of the
// starts and reconciles adds to: recovery never dispatches, the read-only
// intent is settled from the device's recorded facts, and a pointer gesture
// has no dedicated readback. What the oracle keeps and how it is composed is
// `HDCOracleHarness`.
//
// Record a new oracle with
// `ARKDECK_RUST_DEVICE_RECONCILE_RECORD=/private/tmp/<new directory>`;
// otherwise the checked-in oracle must match byte for byte.

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class DeviceReconcileOracleContractTests: XCTestCase {
  private struct Job {
    let name: String
    let operation: String
    let inputs: [String: JSONValue]
    /// The fake's mode while the Job runs.
    let mode: String
    /// The state the run ends in.
    let ends: String
  }

  private static let frame: [String: JSONValue] = [
    "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    "screenEpochUtc": .string("2026-09-14T00:00:00.000Z"),
  ]
  private static let tap: [String: JSONValue] = frame.merging([
    "x": .integer(640), "y": .integer(1500),
  ]) { $1 }

  private static let jobs: [Job] = [
    Job(name: "observed", operation: "observe.device", inputs: [:], mode: "normal", ends: "succeeded"),
    Job(
      name: "observeParked", operation: "observe.device", inputs: [:], mode: "emptyVersion",
      ends: "waitingForRecovery"),
    Job(
      name: "tapParked", operation: "input.tap", inputs: tap, mode: "otherGesture",
      ends: "waitingForRecovery"),
  ]

  /// The reconcile requests once the daemon has started twice: each names a
  /// Job above. Swift's answers are recorded as they are.
  private static let reconciles: [(name: String, job: String)] = [
    ("reconcileObserveParked", "observeParked"),
    ("reconcileObserveParkedAgain", "observeParked"),
    ("reconcileTapParked", "tapParked"),
    ("reconcileTapParkedAgain", "tapParked"),
    ("reconcileObserved", "observed"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/device-reconcile", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// What `observe.device@1` and `input.tap@1` ask, answered as their own
  /// oracles answer it: `emptyVersion` answers the version probe with
  /// nothing, `otherGesture` acknowledges a swipe whatever it was given.
  private static let answers = #"""
    # observe.device@1 and input.tap@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "-v")
      [ "$mode" = emptyVersion ] || printf 'Ver: 3.2.0d\n' ;;
    "checkserver")
      printf 'Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n' ;;
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell uinput "*)
      case "$mode" in
      otherGesture) printf 'startX:100, startY:2200, endX:100, endY:1200\n'; exit 0 ;;
      esac
      shift 4
      [ "$1" = -D ] && shift 2
      case "$2" in
      -c) printf '   click coordinate: (%s, %s)\nclick interval time: 100ms\n' "$3" "$4" ;;
      esac
      printf 'If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftRecoversAndReconcilesTheParkedDeviceJobs() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_DEVICE_RECONCILE_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(
    _ name: String, operation: String, inputs: [String: JSONValue], target: String
  ) throws -> String {
    var document: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-reconcile-\(name)"),
      "idempotencyKey": .string("idem-reconcile-\(name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string(operation), "version": .integer(1)]),
    ]
    if !inputs.isEmpty { document["inputs"] = .object(inputs) }
    return String(
      decoding: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)),
      as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "device-reconcile-oracle")
  }

  /// The Job store and the capability store as a reader finds them, under
  /// `prefix`: the index and every file below them (each Job record's
  /// machine facts as labels).
  private static func snapshot(
    _ composition: HDCOracleHarness.Composition, prefix: String
  ) throws -> [String: Data] {
    let manager = FileManager.default
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "\(prefix)/index.json":
        try encoder.encode(try HDCOracleHarness.index(of: composition.jobsState))
        + Data("\n".utf8)
    ]
    for (directory, name) in [("jobs", "jobs"), ("capabilities", "capabilities")] {
      let root = composition.jobsState.appending(path: directory, directoryHint: .isDirectory)
      for path in try manager.subpathsOfDirectory(atPath: root.path).sorted() {
        let url = root.appending(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        guard metadata.st_mode & S_IFMT != S_IFDIR else { continue }
        let data = try Data(contentsOf: url)
        files["\(prefix)/\(name)/\(path)"] =
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
    let first = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings)

    var exchanges: [JSONValue] = []
    var jobIDs: [String: String] = [:]
    for job in Self.jobs {
      let params: [String: JSONValue] = [
        "requestJson": .string(
          try Self.requestJSON(
            job.name, operation: job.operation, inputs: job.inputs, target: adopted.targetID))
      ]
      let submitted = try await Self.send(first.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(job.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let jobID)? = result["jobId"]
      else {
        XCTFail("\(job.name): the admission was refused: \(submitted)")
        continue
      }
      jobIDs[job.name] = jobID
      try HDCOracleFake.setMode(job.mode)
      let run = try await Self.send(first.handler, "job.run", ["jobId": .string(jobID)])
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(job.name).run", "job.run", ["jobId": .string(jobID)], run, mode: job.mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        XCTFail("\(job.name): the run was refused: \(run)")
        continue
      }
      XCTAssertEqual(status["state"], .string(job.ends), job.name)
    }
    try HDCOracleFake.setMode("normal")
    let invocationsBefore = try HDCOracleFake.invocations()
    var files = try Self.snapshot(first, prefix: "before")

    // The daemon starts again over the same root, and then once more.
    var starts: [JSONValue] = []
    var composition = first
    for start in ["restart", "secondRestart"] {
      composition = try HDCOracleHarness.composition(
        hdc: hdc, targetStore: try RuntimeTargetStore(directoryURL: targets), targets: targets,
        settings: Self.settings)
      let recovered = try await composition.engine.recoverActiveJobs()
      starts.append(
        .object([
          "name": .string(start),
          "recovered": .array(try recovered.map { try RuntimeJobReadProjection.status($0) }),
        ]))
      files.merge(try Self.snapshot(composition, prefix: start)) { _, new in new }
    }
    XCTAssertEqual(try HDCOracleFake.invocations(), invocationsBefore, "a start dispatched")

    for step in Self.reconciles {
      let params: [String: JSONValue] = ["jobId": .string(jobIDs[step.job]!)]
      let answer = try await Self.send(composition.handler, "job.reconcile", params)
      exchanges.append(HDCOracleHarness.exchange(step.name, "job.reconcile", params, answer))
      files.merge(try Self.snapshot(composition, prefix: "steps/\(step.name)")) { _, new in new }
    }
    XCTAssertEqual(try HDCOracleFake.invocations(), invocationsBefore, "a reconcile dispatched")

    // A new tap under the same capability, once the reconciles are done.
    let afterParams: [String: JSONValue] = [
      "requestJson": .string(
        try Self.requestJSON(
          "tapAfterReconcile", operation: "input.tap", inputs: Self.tap, target: adopted.targetID))
    ]
    exchanges.append(
      HDCOracleHarness.exchange(
        "tapAfterReconcile.submit", "job.submit", afterParams,
        try await Self.send(composition.handler, "job.submit", afterParams)))

    for job in Self.jobs {
      let jobID = jobIDs[job.name]!
      for method in ["job.status", "job.show", "job.result", "job.evidence"] {
        let params: [String: JSONValue] = ["jobId": .string(jobID)]
        exchanges.append(
          HDCOracleHarness.exchange(
            "\(job.name).\(method)", method, params,
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
        "jobs": .object(
          Dictionary(
            uniqueKeysWithValues: Self.jobs.map { job in
              (
                job.name,
                JSONValue.object([
                  "operation": .string(job.operation), "inputs": .object(job.inputs),
                  "mode": .string(job.mode), "ends": .string(job.ends),
                  "jobId": .string(jobIDs[job.name] ?? ""),
                ])
              )
            })),
        "starts": .array(starts),
        "invocationsBeforeRestart": .integer(Int64(invocationsBefore.count)),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "DeviceReconcileOracleContractTests.testSwiftRecoversAndReconcilesTheParkedDeviceJobs",
      settings: Self.settings)
    files.merge(recorded) { _, new in new }
    return files
  }
}
