// Shared Swift oracle for the Rust `capture.diagnostics@1` read legs (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `capture.diagnostics@1` over the shared fake HDC (`HDCOracleFake`) with the legs its
/// default request leaves unselected that only read the device: the component detail dump
/// (`advancedDump`, `windowId`, `componentId`), the Faultlogger index (`crashLogs`) and one
/// entry of it (`crashLogName`), the application liveness readback (`bundleName`, with its
/// ability, process and deployed digest), the host's own marks (`markers`) and the trace ring's
/// coverage record a ring-buffered request without trace categories still writes. None of them
/// raises the plan's effect, so every Job here is admitted under the default read-only policy
/// and no capability is issued.
///
/// One device is adopted; each case plans its request, and a case with a mode also admits it
/// and runs its Job while the fake answers in that mode, so the Jobs run in order over one
/// store. `allRead` selects every read leg beside the default HiLog drain and window inventory
/// and captures all of them; the others turn the defaults off. `degraded` finds a component
/// detail that is not text, an empty ledger answered with a non-zero exit, no entry of the
/// requested name and no live process: two optional legs fail and are skipped, the Job still
/// succeeds. The liveness readback is ambiguous and unavailable in two more Jobs; a ledger past
/// the 8 MiB a read keeps fails its leg; a ledger inside that bound but past the request's own
/// `totalArtifactByteBudget` fails the Job at publication. Five requests are refused before
/// admission: a component detail without its window, a window that is not a decimal
/// identifier, a path for an entry name, a bundle that is not reverse-DNS and a mark with an
/// empty label. Last come the three outcomes nothing can observe, each of which parks its Job:
/// an entry answered without its HiviewDFX header, a component detail that outlives its 30 s
/// budget and a liveness readback whose process dies on a signal. A second run of the first
/// Job is refused, and every Job's result, evidence and Artifact list are read last. What the
/// oracle keeps and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CAPTURE_READ_LEGS_RECORD=/private/tmp/<new directory>`; otherwise the
/// checked-in oracle must match byte for byte.
final class CaptureDiagnosticsReadLegsOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    let inputs: [String: JSONValue]
    /// The fake's mode while this case's Job runs; a case without one only plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
  }

  private static let digest = String(repeating: "ab", count: 32)

  /// The request without the HiLog drain and the window inventory, plus the case's own legs.
  private static func legs(_ inputs: [String: JSONValue]) -> [String: JSONValue] {
    var request: [String: JSONValue] = [
      "durationSeconds": .integer(5), "captureHilog": .bool(false), "uiDump": .bool(false),
    ]
    request.merge(inputs) { _, requested in requested }
    return request
  }

  private static let detail: [String: JSONValue] = [
    "advancedDump": .bool(true), "windowId": .string("7"), "componentId": .string("42"),
  ]

  private static let cases: [Case] = [
    Case(
      name: "allRead",
      inputs: detail.merging([
        "durationSeconds": .integer(5), "crashLogs": .bool(true),
        "crashLogName": .string("cppcrash-com.example.demo-20010039-20260914000000"),
        "bundleName": .string("com.example.demo"), "abilityName": .string("EntryAbility"),
        "expectedDeployedArtifactDigest": .string(digest),
        "markers": .array([
          .string("2026-09-14T00:00:01Z#tap sign in"), .string("2026-09-14T00:00:02.250Z"),
        ]),
      ]) { _, requested in requested },
      mode: "normal", ends: "succeeded"),
    Case(
      name: "degraded",
      inputs: legs(
        detail.merging([
          "crashLogs": .bool(true),
          "crashLogName": .string("jscrash-com.example.demo-20010039-20260913235959"),
          "bundleName": .string("com.example.demo"),
        ]) { _, requested in requested }),
      mode: "degraded", ends: "succeeded"),
    Case(
      name: "livenessAmbiguous",
      inputs: legs([
        "bundleName": .string("com.example.demo"),
        "processName": .string("com.example.demo:render"),
      ]),
      mode: "ambiguous", ends: "succeeded"),
    Case(
      name: "livenessUnavailable", inputs: legs(["bundleName": .string("com.example.demo")]),
      mode: "unavailable", ends: "succeeded"),
    Case(
      name: "crashIndexTruncated", inputs: legs(["crashLogs": .bool(true)]), mode: "truncated",
      ends: "succeeded"),
    Case(
      name: "overBudget",
      inputs: legs(["crashLogs": .bool(true), "totalArtifactByteBudget": .integer(1_048_576)]),
      mode: "large", ends: "failed"),
    Case(
      name: "ringWithoutTrace", inputs: legs(["ringBuffered": .bool(true)]), mode: "normal",
      ends: "succeeded"),
    Case(name: "detailWithoutWindow", inputs: legs(["advancedDump": .bool(true)])),
    Case(
      name: "windowNotDecimal",
      inputs: legs(
        detail.merging(["windowId": .string("7a")]) { _, requested in requested })),
    Case(name: "pathAsEntry", inputs: legs(["crashLogName": .string("../faultlog/cppcrash")])),
    Case(name: "bundleNotReverseDNS", inputs: legs(["bundleName": .string("demo")])),
    Case(
      name: "markWithEmptyLabel",
      inputs: legs(["markers": .array([.string("2026-09-14T00:00:03Z#")])])),
    Case(
      name: "entryWithoutHeader",
      inputs: legs(["crashLogName": .string("cppcrash-com.example.demo-1")]),
      mode: "headerless", ends: "waitingForRecovery"),
    Case(name: "detailTimeout", inputs: legs(detail), mode: "hang", ends: "waitingForRecovery"),
    Case(
      name: "livenessKilled", inputs: legs(["bundleName": .string("com.example.demo")]),
      mode: "killed", ends: "waitingForRecovery"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capture-diagnostics-read-legs", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// What the read legs ask, answered as the device answers them (the Faultlogger shapes are
  /// the ones `DeviceProviderArgvContractTests` and `DiagnosticsAndHAPContractTests` pin), by
  /// mode. `degraded`: a component detail that is not UTF-8, the empty ledger with exit 1, the
  /// device's `invalid parameters.` for an entry it does not have and no process. `ambiguous`
  /// and `unavailable`: a `pidof` answer that is not only process IDs, and one that exits 127.
  /// `truncated`: a ledger past the 8 MiB a read keeps; `large`: one of 1 MB without entries.
  /// `headerless`: an entry without its HiviewDFX header. `hang`: a component detail that does
  /// not answer within its 30 s budget. `killed`: a `pidof` that dies on a signal. No answer
  /// names a host path, so the products are the same wherever a daemon runs and redacts them.
  private static let answers = #"""
    # capture.diagnostics@1 read-leg answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell df -k /data/local/tmp")
      printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
      printf '/dev/block/data 1048576 1024 1047552 1%% /data\n' ;;
    "-t $key shell hilog -x")
      printf '01-01 00:00:00 I app: hello\n' ;;
    "-t $key shell hidumper -s WindowManagerService -a -a")
      printf '{"windows":[]}\n' ;;
    "-t $key shell hidumper -s WindowManagerService -a -w 7 -element -lastpage 42")
      case $mode in
      degraded) printf 'ComponentInfo \377\376\n' ;;
      hang) exec /bin/sleep 40 ;;
      *) printf 'WindowId: 7\nComponentId: 42\ntype: Button\ntext: Sign in\n' ;;
      esac ;;
    "-t $key shell hidumper -s 1201 -a -p Faultlogger -l")
      case $mode in
      degraded)
        printf '\nFault log list:\n******\n******\nNo fault log exist.\n'
        exit 1 ;;
      truncated) /usr/bin/head -c 8400000 /dev/zero | /usr/bin/tr '\0' 'x' ;;
      large)
        /usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\0' 'y'
        printf '\n' ;;
      *)
        printf '\n-------------------------------[ability]-------------------------------\n\n'
        printf '----------------------------------HiviewService----------------------------------\n'
        printf 'Fault log list:\n******\n'
        printf 'cppcrash-com.example.demo-20010039-20260914000000\n'
        printf 'jscrash-com.example.demo-20010039-20260913235959\n******\n' ;;
      esac ;;
    "-t $key shell hidumper -s 1201 -a -p Faultlogger -f "*)
      case $mode in
      degraded) printf 'invalid parameters.\n' ;;
      headerless) printf 'Fault log list:\n' ;;
      *)
        printf 'Generated by HiviewDFX@OpenHarmony\n'
        printf '================================================================\n'
        printf 'Device info:OpenHarmony 3.2\nModule name:com.example.demo\n'
        printf 'Process name:%s\n' "${8##* }" ;;
      esac ;;
    "-t $key shell pidof "*)
      case $mode in
      degraded) : ;;
      ambiguous) printf '1234 render\n' ;;
      unavailable)
        printf '/bin/sh: pidof: inaccessible or not found\n'
        exit 127 ;;
      killed) kill -9 $$ ;;
      *) printf '1234\n' ;;
      esac ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCapturesTheReadLegsOfTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_CAPTURE_READ_LEGS_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-capture-\(item.name)"),
      "idempotencyKey": .string("idem-capture-\(item.name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string("capture.diagnostics"), "version": .integer(1)]),
      "inputs": .object(item.inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(
      handler, method, params, frameID: "capture-diagnostics-read-legs-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = ["inputs": .object(item.inputs)]
    if let mode = item.mode { fields["mode"] = .string(mode) }
    if let ends = item.ends { fields["ends"] = .string(ends) }
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
      guard let mode = item.mode else {
        guard case .object(let fields) = plan, fields["ok"] == .bool(false) else {
          XCTFail("\(item.name): the plan was not refused: \(plan)")
          continue
        }
        continue
      }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
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
    let first = ["jobId": JSONValue.string(jobs[0].job)]
    exchanges.append(
      HDCOracleHarness.exchange(
        "\(jobs[0].name).rerun", "job.run", first,
        try await Self.send(composition.handler, "job.run", first)))
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
        "cases": .object(
          Dictionary(uniqueKeysWithValues: Self.cases.map { ($0.name, Self.described($0)) })),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "CaptureDiagnosticsReadLegsOracleContractTests.testSwiftCapturesTheReadLegsOfTheSharedFakeDevice",
      settings: Self.settings)
  }
}
