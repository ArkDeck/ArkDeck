// Shared Swift oracle for the Rust `capture.diagnostics@1` engine (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `capture.diagnostics@1` with the runbook's default input
/// (`{ "durationSeconds": 5 }`: the HiLog and UI dump captures, no trace,
/// screenshot, crash log or application liveness) over the shared fake HDC
/// (`HDCOracleFake`), the second operation of Golden Journey 1 and the M1
/// oracle lane A's Rust engine replays after `observe.device@1`. One device is
/// adopted; each case then plans a request for it, and a case with a mode
/// also admits it and runs its Job while the fake answers in that mode, so
/// the Jobs run in order over one store: one captures both products, one
/// finds the device volume too full for the collection, one finds another
/// device's row, and one gets an empty HiLog capture and parks. The other
/// cases are refused before admission: a stale binding revision, a request
/// without one and a target never adopted. A second run of the captured Job
/// is refused, and every Job's result, evidence and Artifact list are read
/// last. What the oracle keeps and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CAPTURE_DIAGNOSTICS_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CaptureDiagnosticsOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    /// The fake's mode while this case's Job runs; a case without one only
    /// plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The binding revision the request expects; none is sent when nil.
    var bindingRevision: Int? = 1
    /// A target other than the adopted one.
    var target: String?
  }

  private static let cases: [Case] = [
    Case(name: "captured", mode: "normal", ends: "succeeded"),
    Case(name: "lowStorage", mode: "lowStorage", ends: "failed"),
    Case(name: "otherDevice", mode: "otherDevice", ends: "failed"),
    Case(name: "emptyHilog", mode: "emptyHilog", ends: "waitingForRecovery"),
    Case(name: "staleBinding", bindingRevision: 2),
    Case(name: "unboundRequest", bindingRevision: nil),
    Case(name: "unadopted", target: "TGT-000000000000"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capture-diagnostics", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// What `capture.diagnostics@1` asks with the default input, answered as
  /// `ArkDeckFakeHDCFixture` and the scripted dispatcher of
  /// `DiagnosticsAndHAPContractTests` answer it, by mode: `lowStorage` leaves
  /// the device volume 16 KiB where the collection needs its budget,
  /// `otherDevice` lists another device's row, and `emptyHilog` answers the
  /// bounded HiLog capture with nothing. `AgentExecutionOracleContractTests`
  /// answers with the same fragment.
  static let answers = #"""
    # capture.diagnostics@1 answers of ArkDeckFakeHDCFixture and the scripted dispatcher, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "-v")
      printf 'Ver: 3.2.0d\n' ;;
    "checkserver")
      printf 'Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n' ;;
    "list targets -v")
      if [ "$mode" = otherDevice ]; then row=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else row=$key; fi
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$row" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell df -k /data/local/tmp")
      if [ "$mode" = lowStorage ]; then available=16; else available=1047552; fi
      printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
      printf '/dev/block/data 1048576 1024 %s 1%% /data\n' "$available" ;;
    "-t $key shell hilog -x")
      [ "$mode" = emptyHilog ] || printf '01-01 00:00:00 I app: hello\n' ;;
    "-t $key shell hidumper -s WindowManagerService -a -a")
      printf '{"windows":[]}\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCapturesDiagnosticsOfTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_CAPTURE_DIAGNOSTICS_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    var bound: [String: JSONValue] = ["targetId": .string(item.target ?? target)]
    if let revision = item.bindingRevision {
      bound["expectedBindingRevision"] = .integer(Int64(revision))
    }
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-capture-\(item.name)"),
      "idempotencyKey": .string("idem-capture-\(item.name)"),
      "target": .object(bound),
      "operation": .object(["id": .string("capture.diagnostics"), "version": .integer(1)]),
      "inputs": .object(["durationSeconds": .integer(5)]),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(
      handler, method, params, frameID: "capture-diagnostics-oracle")
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
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: adopted.targetID))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard let mode = item.mode else { continue }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else { throw CocoaError(.coderInvalidValue) }
      jobs.append((item.name, job))
      try HDCOracleFake.setMode(mode)
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        throw CocoaError(.coderInvalidValue)
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
    let captured = ["jobId": JSONValue.string(jobs[0].job)]
    exchanges.append(
      HDCOracleHarness.exchange(
        "captured.rerun", "job.run", captured,
        try await Self.send(composition.handler, "job.run", captured)))
    for (name, job) in jobs {
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
        let answer = try await Self.send(composition.handler, method, params)
        exchanges.append(HDCOracleHarness.exchange("\(name).\(read)", method, params, answer))
      }
    }
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
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "CaptureDiagnosticsOracleContractTests.testSwiftCapturesDiagnosticsOfTheSharedFakeDevice",
      settings: Self.settings)
  }
}
