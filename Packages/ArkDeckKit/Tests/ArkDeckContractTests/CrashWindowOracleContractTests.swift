// Shared Swift oracle for the crash-window matrix of the Rust recovery
// (TASK-XPA-014, recovery port slice 2; ADR-0009 decision 2 as ruled on
// 2026-09-19; XPA-AC-7).
//
// One `input.tap@1` runs over the shared fake HDC (`HDCOracleFake`) in
// `HDCOracleHarness`'s composition of the standalone daemon's engine, and the
// daemon dies at one of four windows, one window per pass over a fresh root.
// The windows are the four quadrants of "before or after an intent" and
// "before or after the capability consume":
//
// - `beforeConsume`: every read-only evidence step done, the capability not
//   yet consumed, no mutation intent (the engine's
//   `beforeMutationCapabilityCommit` hook);
// - `afterReadOnlyIntent`: the `read-evidence-model` intent durable and its
//   tool running, nothing consumed (the fake, answering that read);
// - `afterConsume`: the capability consumed and the Job's evidence durable,
//   no mutation intent (the engine's `beforeDispatchInstall` hook for
//   `inject-pointer-input`);
// - `afterIntent`: the `inject-pointer-input` intent durable and the injector
//   running (the fake, answering `uinput`).
//
// A death is what the daemon left on disk at that moment: the whole root is
// copied there, and once the live run has returned, the copy replaces the
// root. The daemon then starts twice over it (`recoverActiveJobs`), the Job
// is reconciled twice through `job.reconcile`, a new tap is submitted under
// the same automatic capability policy, and the Job and the capabilities are
// read. For each window the oracle keeps every answer, the store at the death
// (`crash/`), after each start and after each reconcile, and what
// `HDCOracleHarness` records of a root: every call the fake received, which
// no start and no reconcile adds to.
//
// Record a new oracle with
// `ARKDECK_RUST_CRASH_WINDOW_RECORD=/private/tmp/<new directory>`;
// otherwise the checked-in oracle must match byte for byte.

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class CrashWindowOracleContractTests: XCTestCase {
  private enum Capture {
    case beforeConsume
    case beforeMutationIntent
    /// The fake copies the root while it answers the call its mode names.
    case fake
  }

  private struct Window {
    let name: String
    /// Whether the death falls before or after an intent became durable.
    let intent: String
    /// Whether it falls before or after the capability consume.
    let consume: String
    /// The fake's mode while the Job runs.
    let mode: String
    let capture: Capture
    /// Where the root was copied, as the cases record it.
    let capturedAt: String
  }

  private static let windows: [Window] = [
    Window(
      name: "beforeConsume", intent: "before", consume: "before", mode: "normal",
      capture: .beforeConsume,
      capturedAt: "RuntimeJobEngine test hook beforeMutationCapabilityCommit"),
    Window(
      name: "afterReadOnlyIntent", intent: "after", consume: "before",
      mode: "afterReadOnlyIntent", capture: .fake,
      capturedAt: "the fake, answering read-evidence-model (param get const.product.name)"),
    Window(
      name: "afterConsume", intent: "before", consume: "after", mode: "normal",
      capture: .beforeMutationIntent,
      capturedAt: "RuntimeJobEngine test hook beforeDispatchInstall for inject-pointer-input"),
    Window(
      name: "afterIntent", intent: "after", consume: "after", mode: "afterIntent",
      capture: .fake,
      capturedAt: "the fake, answering inject-pointer-input (uinput)"),
  ]

  private static let tap: [String: JSONValue] = [
    "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    "screenEpochUtc": .string("2026-09-14T00:00:00.000Z"),
    "x": .integer(640), "y": .integer(1500),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/crash-window", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  /// Where a death copies the root, beside it under the fake's lock.
  private static let crash = URL(
    filePath: "/private/tmp/arkdeck-hdc-oracle-crash", directoryHint: .isDirectory)

  /// What `input.tap@1` asks, answered as its own oracle answers it. In mode
  /// `afterReadOnlyIntent` the model read, and in mode `afterIntent` the
  /// gesture, first copies the root to where a death is kept; the call is
  /// then answered as in `normal`, and the live run goes on to its end.
  private static let answers = #"""
    # input.tap@1 answers of the shared fake HDC; two modes copy the root first.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    crash() {
      /bin/rm -rf /private/tmp/arkdeck-hdc-oracle-crash
      /bin/cp -Rp /private/tmp/arkdeck-hdc-oracle /private/tmp/arkdeck-hdc-oracle-crash
    }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      [ "$mode" = afterReadOnlyIntent ] && crash
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell uinput "*)
      [ "$mode" = afterIntent ] && crash
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

  /// The root as the daemon left it on disk at an engine hook, copied once.
  private final class CrashCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var copied = false
    private var failure: String?

    func take() {
      lock.withLock {
        guard !copied else { return }
        copied = true
        do {
          try? FileManager.default.removeItem(at: CrashWindowOracleContractTests.crash)
          try FileManager.default.copyItem(
            at: HDCOracleFake.root, to: CrashWindowOracleContractTests.crash)
        } catch {
          failure = "\(error)"
        }
      }
    }

    var outcome: (copied: Bool, failure: String?) { lock.withLock { (copied, failure) } }
  }

  func testSwiftRecoversATapFromEachCrashWindowWithoutReplay() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_CRASH_WINDOW_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ name: String, target: String) throws -> String {
    let document: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-crash-\(name)"),
      "idempotencyKey": .string("idem-crash-\(name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string("input.tap"), "version": .integer(1)]),
      "inputs": .object(tap),
    ]
    return String(
      decoding: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)),
      as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "crash-window-oracle")
  }

  /// The Job store and the capability store as a reader finds them, under
  /// `prefix`: the index and every file below them (each Job record's
  /// machine facts as labels).
  private static func snapshot(_ jobsState: URL, prefix: String) throws -> [String: Data] {
    let manager = FileManager.default
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "\(prefix)/index.json":
        try encoder.encode(try HDCOracleHarness.index(of: jobsState)) + Data("\n".utf8)
    ]
    for (directory, name) in [("jobs", "jobs"), ("capabilities", "capabilities")] {
      let root = jobsState.appending(path: directory, directoryHint: .isDirectory)
      guard manager.fileExists(atPath: root.path) else { continue }
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
    defer {
      try? manager.removeItem(at: Self.settings.root)
      try? manager.removeItem(at: Self.crash)
    }
    var files: [String: Data] = [:]
    for window in Self.windows {
      for (path, data) in try await windowFiles(window) {
        files["\(window.name)/\(path)"] = data
      }
    }
    return files
  }

  private func windowFiles(_ window: Window) async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    try? manager.removeItem(at: Self.crash)
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let adopted = try RuntimeTargetStore(directoryURL: targets).adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record

    let capture = CrashCapture()
    let hooks: RuntimeJobEngine.Configuration.TestHooks
    switch window.capture {
    case .beforeConsume:
      hooks = .init(beforeMutationCapabilityCommit: { _ in capture.take() })
    case .beforeMutationIntent:
      hooks = .init(beforeDispatchInstall: { _, step in
        if step == "inject-pointer-input" { capture.take() }
      })
    case .fake:
      hooks = .none
    }
    let live = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: try RuntimeTargetStore(directoryURL: targets), targets: targets,
      settings: Self.settings, testHooks: hooks)

    var exchanges: [JSONValue] = []
    let params: [String: JSONValue] = [
      "requestJson": .string(try Self.requestJSON("tap", target: adopted.targetID))
    ]
    let submitted = try await Self.send(live.handler, "job.submit", params)
    exchanges.append(HDCOracleHarness.exchange("tap.submit", "job.submit", params, submitted))
    guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
      case .string(let jobID)? = result["jobId"]
    else {
      XCTFail("\(window.name): the admission was refused: \(submitted)")
      return [:]
    }
    // The live run goes on past the window to its end; only the copy the
    // window took is kept.
    try HDCOracleFake.setMode(window.mode)
    _ = try await Self.send(live.handler, "job.run", ["jobId": .string(jobID)])
    switch window.capture {
    case .beforeConsume, .beforeMutationIntent:
      let outcome = capture.outcome
      XCTAssertNil(outcome.failure, window.name)
      XCTAssertTrue(outcome.copied, "\(window.name): the hook never ran")
    case .fake:
      XCTAssertTrue(
        manager.fileExists(atPath: Self.crash.path), "\(window.name): the fake never copied")
    }
    guard manager.fileExists(atPath: Self.crash.path) else { return [:] }

    // The daemon died at the window: its root is what was on disk then.
    try manager.removeItem(at: Self.settings.root)
    try manager.copyItem(at: Self.crash, to: Self.settings.root)
    try manager.removeItem(at: Self.crash)
    try HDCOracleFake.setMode("normal")
    let jobsState = Self.settings.root.appending(path: "jobs-state", directoryHint: .isDirectory)
    var files = try Self.snapshot(jobsState, prefix: "crash")
    let invocationsAtCrash = try HDCOracleFake.invocations()

    // The daemon starts again over that root, and then once more.
    var starts: [JSONValue] = []
    var composition = live
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
      files.merge(try Self.snapshot(composition.jobsState, prefix: start)) { _, new in new }
    }
    XCTAssertEqual(
      try HDCOracleFake.invocations(), invocationsAtCrash, "\(window.name): a start dispatched")

    for name in ["reconcileCrashed", "reconcileCrashedAgain"] {
      let params: [String: JSONValue] = ["jobId": .string(jobID)]
      let answer = try await Self.send(composition.handler, "job.reconcile", params)
      exchanges.append(HDCOracleHarness.exchange(name, "job.reconcile", params, answer))
      files.merge(try Self.snapshot(composition.jobsState, prefix: "steps/\(name)")) {
        _, new in new
      }
    }
    XCTAssertEqual(
      try HDCOracleFake.invocations(), invocationsAtCrash,
      "\(window.name): a reconcile dispatched")

    // A new tap under the same automatic capability policy.
    let nextParams: [String: JSONValue] = [
      "requestJson": .string(try Self.requestJSON("tapAfterCrash", target: adopted.targetID))
    ]
    exchanges.append(
      HDCOracleHarness.exchange(
        "tapAfterCrash.submit", "job.submit", nextParams,
        try await Self.send(composition.handler, "job.submit", nextParams)))

    for method in ["job.status", "job.show", "job.result", "job.evidence"] {
      let params: [String: JSONValue] = ["jobId": .string(jobID)]
      exchanges.append(
        HDCOracleHarness.exchange(
          "tap.\(method)", method, params,
          try await Self.send(composition.handler, method, params)))
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
        "window": .object([
          "name": .string(window.name), "intent": .string(window.intent),
          "consume": .string(window.consume), "mode": .string(window.mode),
          "capturedAt": .string(window.capturedAt),
        ]),
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "job": .object([
          "operation": .string("input.tap"), "inputs": .object(Self.tap),
          "jobId": .string(jobID),
        ]),
        "starts": .array(starts),
        "invocationsAtCrash": .integer(Int64(invocationsAtCrash.count)),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "CrashWindowOracleContractTests.testSwiftRecoversATapFromEachCrashWindowWithoutReplay",
      settings: Self.settings)
    files.merge(recorded) { _, new in new }
    return files
  }
}
