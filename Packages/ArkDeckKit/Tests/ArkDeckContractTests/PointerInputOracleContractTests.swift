// Shared Swift oracle for the Rust `input.tap@1`, `input.long-press@1` and
// `input.swipe@1` engine (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's three pointer gestures over the shared fake HDC (`HDCOracleFake`),
/// the interactive operations of Golden Journey 2 and the third M2 oracle.
/// One device is adopted; each case plans a request for it, and a case with
/// a mode also admits it under the runtime's default policy capability and
/// runs its Job while the fake answers in that mode, so the Jobs run in
/// order over one store: a tap, a long press on a named display and a swipe
/// that `uinput` acknowledges as the device acknowledged them on 2026-08-25
/// (`TASK-IDC-002`); a tap the injector rejects as a parameter error; then,
/// last of the runs, a tap the injector answers with another gesture's
/// acknowledgement, left unknown because the gesture may or may not have
/// landed — the Job waits for recovery, and the next tap admitted under the
/// same capability is refused because the lineage holds an unknown outcome.
/// Two cases are refused at admission by the typed plan's preflight: a tap
/// whose frame is older than the freshness bound and one outside its frame,
/// nothing sent to the device either time. The other cases are refused
/// before admission: a long press shorter than the Catalog allows and a
/// swipe without a duration. Every Job's result, evidence and Artifact list
/// are read, and the capability store is read last. What the oracle keeps
/// and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_POINTER_INPUT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class PointerInputOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    let operation: String
    let inputs: [String: JSONValue]
    /// The fake's mode while this case's Job runs; a case without one only
    /// plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The code the admission is refused with, for a case that is submitted
    /// but never runs.
    var admission: String?
  }

  /// The frame every gesture is mapped against: the device's 1280x2832
  /// screen, captured on the oracle's clock.
  private static let frame: [String: JSONValue] = [
    "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    "screenEpochUtc": .string("2026-09-14T00:00:00.000Z"),
  ]

  private static func point(
    _ x: Int64, _ y: Int64, _ extra: [String: JSONValue] = [:]
  ) -> [String: JSONValue] {
    frame.merging(["x": .integer(x), "y": .integer(y)]) { $1 }.merging(extra) { $1 }
  }

  private static func travel(
    _ fromX: Int64, _ fromY: Int64, _ toX: Int64, _ toY: Int64, _ durationMs: Int64?
  ) -> [String: JSONValue] {
    var inputs = frame.merging([
      "fromX": .integer(fromX), "fromY": .integer(fromY),
      "toX": .integer(toX), "toY": .integer(toY),
    ]) { $1 }
    if let durationMs { inputs["durationMs"] = .integer(durationMs) }
    return inputs
  }

  private static let cases: [Case] = [
    Case(name: "tap", operation: "input.tap", inputs: point(640, 1500), mode: "normal", ends: "succeeded"),
    Case(
      name: "longPress", operation: "input.long-press",
      inputs: point(12, 700, ["durationMs": .integer(1200), "displayId": .integer(2)]),
      mode: "normal", ends: "succeeded"),
    Case(
      name: "swipe", operation: "input.swipe", inputs: travel(100, 2200, 100, 1200, 500),
      mode: "normal", ends: "succeeded"),
    Case(name: "rejected", operation: "input.tap", inputs: point(640, 1500), mode: "rejected", ends: "failed"),
    Case(
      name: "expired", operation: "input.tap",
      inputs: point(640, 1500, ["screenEpochUtc": .string("2026-09-13T23:59:58Z")]),
      admission: "invalidInput"),
    Case(name: "outOfFrame", operation: "input.tap", inputs: point(1280, 1500), admission: "invalidInput"),
    Case(
      name: "otherGesture", operation: "input.tap", inputs: point(640, 1500), mode: "otherGesture",
      ends: "waitingForRecovery"),
    Case(name: "afterUnknown", operation: "input.tap", inputs: point(640, 1500), admission: "admissionDenied"),
    Case(name: "shortHold", operation: "input.long-press", inputs: point(12, 700, ["durationMs": .integer(400)])),
    Case(name: "swipeWithoutDuration", operation: "input.swipe", inputs: travel(100, 2200, 100, 1200, nil)),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/pointer-input", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// What the three operations ask, answered as the device answered on
  /// 2026-08-25: the preflight reads of the adopted device, and `uinput`
  /// acknowledging each gesture with its own lines followed by the boundary
  /// hint it prints on every run — by mode: `rejected` answers a parameter
  /// error, `silent` answers nothing, `otherGesture` acknowledges a swipe
  /// whatever it was given.
  private static let answers = #"""
    # input.tap@1, input.long-press@1 and input.swipe@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell uinput "*)
      case "$mode" in
      rejected) printf 'parameter error, unable to run\n'; exit 0 ;;
      silent) exit 0 ;;
      otherGesture) printf 'startX:100, startY:2200, endX:100, endY:1200\n'; exit 0 ;;
      esac
      shift 4
      [ "$1" = -D ] && shift 2
      case "$2" in
      -c) printf '   click coordinate: (%s, %s)\nclick interval time: 100ms\n' "$3" "$4" ;;
      -d) printf 'touch down %s %s\ntouch up %s %s\n' "$3" "$4" "$8" "$9" ;;
      -m) printf 'startX:%s, startY:%s, endX:%s, endY:%s\n' "$3" "$4" "$5" "$6" ;;
      esac
      printf 'If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftInjectsPointerGesturesOnTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_POINTER_INPUT_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-pointer-\(item.name)"),
      "idempotencyKey": .string("idem-pointer-\(item.name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string(item.operation), "version": .integer(1)]),
      "inputs": .object(item.inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "pointer-input-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = [
      "operation": .string(item.operation), "inputs": .object(item.inputs),
    ]
    if let mode = item.mode { fields["mode"] = .string(mode) }
    if let ends = item.ends { fields["ends"] = .string(ends) }
    if let admission = item.admission { fields["admission"] = .string(admission) }
    return .object(fields)
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
      guard item.mode != nil || item.admission != nil else { continue }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      if let admission = item.admission {
        guard case .object(let fields) = submitted, case .object(let error)? = fields["error"]
        else {
          XCTFail("\(item.name): the admission was not refused: \(submitted)")
          continue
        }
        XCTAssertEqual(error["code"], .string(admission), item.name)
        continue
      }
      guard let mode = item.mode,
        case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else {
        XCTFail("\(item.name): the admission was refused: \(submitted)")
        continue
      }
      jobs.append((item.name, job))
      try HDCOracleFake.setMode(mode)
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        XCTFail("\(item.name): the run was refused: \(run)")
        continue
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
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
    return try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "cases": .object(
          Dictionary(uniqueKeysWithValues: Self.cases.map { ($0.name, Self.described($0)) })),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer: "PointerInputOracleContractTests.testSwiftInjectsPointerGesturesOnTheSharedFakeDevice",
      settings: Self.settings)
  }
}
