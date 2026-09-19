// Shared Swift oracle for the Rust `capture.screen-sequence@1` engine
// (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's bounded run of stills over the shared fake HDC (`HDCOracleFake`),
/// the recording operation ported with M2 and the fifth M2 oracle. One device
/// is adopted; each case plans a request for it, and a case with a mode also
/// admits it under the runtime's default policy capability and runs its Job
/// while the fake answers in that mode, so the Jobs run in order over one
/// device whose `/data/local/tmp` the fake keeps between calls: a default run
/// of three JPEG stills collected into an archive, received, cleaned up and
/// indexed; a scaled PNG run on a named display; a run whose second still the
/// device refuses, which is a gap and not a failure; a device volume too full
/// for the capture's budget; an archive the device leaves empty; a run whose
/// cleanup finds its frame directory still there because the device put a file
/// of its own in it, after the archive is published; and, last of the runs, an
/// archive the device never wrote, so the capture's outcome is unknown — the
/// Job waits for recovery, and the next request for the device is refused at
/// admission because the lineage holds an unknown outcome. The other cases are
/// refused before admission: a lone scaled dimension and a single still. Every
/// Job's result, evidence and Artifact list are read, then the cleanup debts,
/// and the capability store last.
///
/// Two things of the host would otherwise reach the bytes: where received
/// files land (this user's temporary directory, named in the receive argv
/// and so in the materialized plan and its digest) and how long each child
/// ran (every frame's duration reaches the Job record, `sequence.json` and
/// its digest). The oracle fixes both: files land in `receive` under the
/// fixed root, and every child reports half a second. What the oracle keeps
/// and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_SCREEN_SEQUENCE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ScreenSequenceOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
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

  private static func sequence(
    _ frameCount: Int64, imageType: String? = nil, width: Int64? = nil, height: Int64? = nil,
    displayId: Int64? = nil
  ) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = ["frameCount": .integer(frameCount)]
    if let imageType { inputs["imageType"] = .string(imageType) }
    if let width { inputs["width"] = .integer(width) }
    if let height { inputs["height"] = .integer(height) }
    if let displayId { inputs["displayId"] = .integer(displayId) }
    return inputs
  }

  private static let cases: [Case] = [
    Case(name: "captured", inputs: sequence(3), mode: "normal", ends: "succeeded"),
    Case(
      name: "scaled",
      inputs: sequence(2, imageType: "png", width: 360, height: 640, displayId: 0),
      mode: "normal", ends: "succeeded"),
    Case(name: "gap", inputs: sequence(4), mode: "gap", ends: "succeeded"),
    Case(name: "lowStorage", inputs: sequence(3), mode: "lowStorage", ends: "failed"),
    Case(name: "emptyArchive", inputs: sequence(3), mode: "emptyArchive", ends: "failed"),
    Case(name: "residue", inputs: sequence(3), mode: "residue", ends: "failed"),
    Case(
      name: "missingArchive", inputs: sequence(3), mode: "missingArchive",
      ends: "waitingForRecovery"),
    Case(name: "afterUnknown", inputs: sequence(3), admission: "admissionDenied"),
    Case(name: "halfScaled", inputs: sequence(3, width: 360)),
    Case(name: "singleFrame", inputs: sequence(1)),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/screen-sequence", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let receive = settings.root.appending(
    path: "receive", directoryHint: .isDirectory)
  /// What every dispatched child reports having taken.
  private static let invocationSeconds = 0.5

  /// What the operation asks, answered as `hdc` answers it: the evidence
  /// reads of the adopted device and its storage; `mkdir -p` of the frame
  /// directory, one `snapshot_display` per still (the still is a line naming
  /// itself and its size, answered with the device's `file type` line), `tar`
  /// collecting the stills in capture order (the fake's archive is their
  /// bytes in that order, not a tar: nothing the Runtime does reads its
  /// format), `ls -l` of the archive, `file recv` copying it to the host path
  /// the argv names, the exact `rm -f` of the stills and of the archive,
  /// `rmdir` of the directory and `ls -ld` reading it back. A device command
  /// that fails exits 1; the two readbacks answer an absent path with the
  /// listing grammar and exit 0, as HDC 3.2 reports its client's status. By
  /// mode: `gap` refuses the second still, `lowStorage` leaves the device
  /// volume 16 KiB, `emptyArchive` leaves a zero-byte archive, `residue` has
  /// the device put a file of its own in the frame directory, and
  /// `missingArchive` cannot write the archive at all.
  private static let answers = #"""
    # capture.screen-sequence@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    # The device's /data/local/tmp, kept beside the log so that a Job's frame
    # directory, stills and archive outlive the calls that made them.
    device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell df -k /data/local/tmp")
      if [ "$mode" = lowStorage ]; then available=16; else available=1047552; fi
      printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
      printf '/dev/block/data 1048576 1024 %s 1%% /data\n' "$available" ;;
    "-t $key shell mkdir -p /data/local/tmp/arkdeck-"*)
      mkdir -p "$(device "$6")"
      if [ "$mode" = residue ]; then : > "$(device "$6")/.nomedia"; fi ;;
    "-t $key shell snapshot_display "*)
      type=jpeg width=720 height=1280 frame=
      shift 4
      while [ $# -gt 1 ]; do
        case $1 in
        -t) type=$2 ;;
        -w) width=$2 ;;
        -h) height=$2 ;;
        -f) frame=$2 ;;
        esac
        shift 2
      done
      if [ "$mode" = gap ] && [ "${frame##*/}" = "0002.$type" ]; then
        printf 'error: snapshot display failed\n'
        exit 1
      fi
      printf '%s %sx%s\n' "${frame##*/}" "$width" "$height" > "$(device "$frame")"
      printf 'file type: %s, width: %s, height: %s\n' "$type" "$width" "$height" ;;
    "-t $key shell tar -c -f /data/local/tmp/arkdeck-"*)
      case $mode in
      missingArchive)
        printf 'tar: %s: No space left on device\n' "$7"
        exit 1 ;;
      emptyArchive)
        : > "$(device "$7")" ;;
      *)
        for still in "$(device "$9")"/*; do cat "$still"; done > "$(device "$7")" ;;
      esac ;;
    "-t $key shell ls -l /data/local/tmp/arkdeck-"*)
      if [ -f "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key file recv /data/local/tmp/arkdeck-"*)
      cp "$(device "$5")" "$6"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      shift 5
      for path; do rm -f "$(device "$path")"; done ;;
    "-t $key shell rmdir /data/local/tmp/arkdeck-"*)
      if ! rmdir "$(device "$5")" 2>/dev/null; then
        printf 'rmdir: %s: Directory not empty\n' "$5"
        exit 1
      fi ;;
    "-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
      if [ -d "$(device "$6")" ]; then
        printf '%s 2 shell shell 3452 2026-09-14 00:00 %s\n' drwxrwxrwx "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCapturesAScreenSequenceOfTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_SCREEN_SEQUENCE_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-sequence-\(item.name)"),
      "idempotencyKey": .string("idem-sequence-\(item.name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object([
        "id": .string("capture.screen-sequence"), "version": .integer(1),
      ]),
      "inputs": .object(item.inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "screen-sequence-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = ["inputs": .object(item.inputs)]
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
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      hostReceiveRoot: Self.receive, fixedInvocationSeconds: Self.invocationSeconds)

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
    // The Runtime's debt ledger, where the residue the cleanup found and the
    // frame directory the empty archive's Job never cleaned would be owed.
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
        "ScreenSequenceOracleContractTests.testSwiftCapturesAScreenSequenceOfTheSharedFakeDevice",
      settings: Self.settings)
  }
}
