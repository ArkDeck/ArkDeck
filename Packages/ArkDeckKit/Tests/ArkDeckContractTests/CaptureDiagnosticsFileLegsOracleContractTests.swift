// Shared Swift oracle for the Rust `capture.diagnostics@1` file legs (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `capture.diagnostics@1` over the shared fake HDC (`HDCOracleFake`) with the legs that
/// write a provider-owned file on the device, receive it and remove it: the component tree
/// (`uiComponentTree`: `uitest dumpLayout`, its `ls -l` readback, `file recv`, `rm -f`) and the
/// screenshot (`uiScreenshot`, PNG or JPEG: `snapshot_display`, the same three legs after it).
/// Either raises the plan's effect to `deviceMutation`, so every Job here is admitted under a
/// capability the Runtime issues by its default policy and consumes before the first write; a
/// request whose only optional legs are the screenshot's is scoped to the control session, whose
/// second Job carries the first one's model and firmware readback.
///
/// Four devices are adopted, whose `/data/local/tmp` the fake keeps between calls; each case
/// plans its request, and a case with a mode also admits it and runs its Job while the fake
/// answers in that mode, so the Jobs run in order. On the first device the tree is captured,
/// received, redacted and cleaned up; then a PNG, a JPEG and both products in one Job. Four Jobs
/// lose a leg and still succeed: a zero-byte tree (its receive and cleanup skipped as upstream of
/// a failure), a still whose bytes are not the PNG it claims, a receive that lands an empty file
/// and a cleanup the device refuses, which owes a cleanup debt. Three Jobs park on an outcome
/// nothing can observe, each on a device of its own because an unknown outcome blocks its
/// target's automatic capability lineage: a capture whose file the readback cannot find, a
/// receive that lands nothing and a cleanup that outlives its 15 s budget. A request for the
/// first of those devices is then refused at admission, and a still type the catalog does not
/// name before it. Every Job's result, evidence and Artifact list are read, then the cleanup
/// debts and the capability store.
///
/// Received files land in `receive` under the fixed root: the landing path is in the receive
/// argv, so in the materialized plan and its digest. What the oracle keeps and how it is composed
/// is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CAPTURE_FILE_LEGS_RECORD=/private/tmp/<new directory>`; otherwise the
/// checked-in oracle must match byte for byte.
final class CaptureDiagnosticsFileLegsOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    let inputs: [String: JSONValue]
    /// The fake's mode while this case's Job runs; a case without one only plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The code the admission is refused with, for a case that is submitted but never runs.
    var admission: String?
    /// The adopted device the request names, by its connect key's letter.
    var device: Character = "a"
  }

  /// The request without the HiLog drain and the window inventory, plus the case's own legs.
  private static func legs(_ inputs: [String: JSONValue]) -> [String: JSONValue] {
    var request: [String: JSONValue] = [
      "durationSeconds": .integer(5), "captureHilog": .bool(false), "uiDump": .bool(false),
    ]
    request.merge(inputs) { _, requested in requested }
    return request
  }

  private static let tree: [String: JSONValue] = ["uiComponentTree": .bool(true)]
  private static let still: [String: JSONValue] = ["uiScreenshot": .bool(true)]

  private static let cases: [Case] = [
    Case(name: "tree", inputs: legs(tree), mode: "normal", ends: "succeeded"),
    Case(name: "png", inputs: legs(still), mode: "normal", ends: "succeeded"),
    Case(
      name: "jpeg", inputs: legs(still.merging(["screenshotImageType": .string("jpeg")]) { $1 }),
      mode: "normal", ends: "succeeded"),
    Case(
      name: "treeAndStill", inputs: legs(tree.merging(still) { $1 }), mode: "normal",
      ends: "succeeded"),
    Case(name: "emptyTree", inputs: legs(tree), mode: "emptyTree", ends: "succeeded"),
    Case(name: "notPNG", inputs: legs(still), mode: "notPNG", ends: "succeeded"),
    Case(name: "emptyLanding", inputs: legs(tree), mode: "emptyLanding", ends: "succeeded"),
    Case(name: "cleanupRefused", inputs: legs(tree), mode: "cleanupRefused", ends: "succeeded"),
    Case(
      name: "stillGIF",
      inputs: legs(still.merging(["screenshotImageType": .string("gif")]) { $1 })),
    Case(
      name: "treeMissing", inputs: legs(tree), mode: "treeMissing", ends: "waitingForRecovery",
      device: "b"),
    Case(
      name: "nothingLanded", inputs: legs(tree), mode: "nothingLanded",
      ends: "waitingForRecovery", device: "c"),
    Case(
      name: "cleanupTimeout", inputs: legs(tree), mode: "cleanupTimeout",
      ends: "waitingForRecovery", device: "d"),
    Case(name: "afterUnknown", inputs: legs(still), admission: "admissionDenied", device: "b"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capture-diagnostics-file-legs", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let devices: [Character] = ["a", "b", "c", "d"]
  private static let receive = settings.root.appending(
    path: "receive", directoryHint: .isDirectory)

  /// What the file legs ask, answered as `hdc` answers them: the evidence reads of the adopted
  /// device and its storage; `uitest dumpLayout` writing a tree that carries the redacted home
  /// directory and an on-screen string, answered with its status line; `snapshot_display`
  /// writing the magic of the type it was told, answered with its `file type` line; `ls -l` of
  /// an owned path; `file recv` copying the device's file to the host path the argv names; and
  /// `rm -f` of an owned path. A readback of an absent path answers the listing grammar and
  /// exits 0, as HDC 3.2 reports its client's status. The fake writes under umask 077, so the
  /// mode of a landing a failed receive leaves does not follow its caller's umask. By mode:
  /// `emptyTree` writes a zero-byte tree, `notPNG` writes JFIF bytes where PNG was asked for,
  /// `emptyLanding` lands an empty file, `cleanupRefused` refuses the removal, `treeMissing`
  /// writes no tree, `nothingLanded` lands nothing and `cleanupTimeout` never answers the
  /// removal.
  private static let answers = #"""
    # capture.diagnostics@1 file-leg answers of the shared fake HDC, by mode.
    keys='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    cccccccccccccccccccccccccccccccc dddddddddddddddddddddddddddddddd'
    # The adopted device a call names, if it names one.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    if [ "$1" = -t ]; then
      for adopted in $keys; do [ "$2" = "$adopted" ] && key=$adopted; done
    fi
    # The devices' /data/local/tmp, kept beside the log so that a Job's owned
    # files outlive the calls that made them; every owned name carries its Job.
    device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
    /bin/mkdir -p "$root/device-tmp"
    # What `file recv` lands is owner-only whatever umask the caller runs
    # under, so that a landing a failed receive leaves has one mode.
    umask 077
    case "$*" in
    "list targets -v")
      for adopted in $keys; do
        printf '%s\t\tUSB\tConnected\tlocalhost\n' "$adopted"
      done ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell df -k /data/local/tmp")
      printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
      printf '/dev/block/data 1048576 1024 1047552 1%% /data\n' ;;
    "-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*)
      case $mode in
      emptyTree) : > "$(device "$7")" ;;
      treeMissing)
        printf 'DumpLayout failed: no window\n'
        exit 1 ;;
      *)
        printf '{"attributes":{"text":"Sign in","hint":"/private/tmp/arkdeck-hdc-oracle/home/Documents/draft.txt"},"children":[]}\n' > "$(device "$7")" ;;
      esac
      printf 'DumpLayout saved to:%s\n' "$7" ;;
    "-t $key shell snapshot_display -t "*)
      if [ "$6" = jpeg ] || [ "$mode" = notPNG ]; then
        printf '\377\330\377\340JFIF still' > "$(device "$8")"
      else
        printf '\211PNG\r\n\032\nIHDR still' > "$(device "$8")"
      fi
      printf 'process: display 0, file type: %s, width: 720, height: 1280\n' "$6" ;;
    "-t $key shell ls -l /data/local/tmp/arkdeck-"*)
      if [ -f "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key file recv /data/local/tmp/arkdeck-"*)
      case $mode in
      emptyLanding) : > "$6" ;;
      nothingLanded) ;;
      *) /bin/cp "$(device "$5")" "$6" ;;
      esac
      printf 'FileTransfer finish\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      case $mode in
      cleanupRefused)
        printf 'rm: %s: Read-only file system\n' "$6"
        exit 1 ;;
      cleanupTimeout) exec /bin/sleep 30 ;;
      *) /bin/rm -f "$(device "$6")" ;;
      esac ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCapturesTheFileLegsOfTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_CAPTURE_FILE_LEGS_RECORD",
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
      handler, method, params, frameID: "capture-diagnostics-file-legs-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = [
      "inputs": .object(item.inputs), "device": .string(String(item.device)),
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
    var adopted: [Character: RuntimeTargetRecord] = [:]
    for device in Self.devices {
      let connectKey = String(repeating: device, count: 32)
      adopted[device] = try targetStore.adopt(
        stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: connectKey),
        connectKey: connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
      ).record
    }
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      hostReceiveRoot: Self.receive)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let target = try XCTUnwrap(adopted[item.device])
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: target.targetID))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard item.mode != nil || item.admission != nil else {
        guard case .object(let fields) = plan, fields["ok"] == .bool(false) else {
          XCTFail("\(item.name): the plan was not refused: \(plan)")
          continue
        }
        continue
      }
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
    // The Runtime's debt ledger, where the refused cleanup's residue is owed.
    exchanges.append(
      HDCOracleHarness.exchange(
        "debt.list", "cleanupDebt.list", [:],
        try await Self.send(composition.handler, "cleanupDebt.list", [:])))
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
    let first = try XCTUnwrap(adopted["a"])
    return try HDCOracleHarness.files(
      composition, target: first,
      cases: .object([
        "target": .object([
          "targetId": .string(first.targetID),
          "bindingRevision": .integer(Int64(first.bindingRevision)),
          "connectKey": .string(first.connectKey),
          "toolVersion": .string(first.toolVersion),
        ]),
        "targets": .object(
          Dictionary(
            uniqueKeysWithValues: adopted.map { device, record in
              (String(device), JSONValue.string(record.targetID))
            })),
        "cases": .object(
          Dictionary(uniqueKeysWithValues: Self.cases.map { ($0.name, Self.described($0)) })),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "CaptureDiagnosticsFileLegsOracleContractTests.testSwiftCapturesTheFileLegsOfTheSharedFakeDevice",
      settings: Self.settings)
  }
}
