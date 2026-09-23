// Shared Swift oracle for the Rust `capture.diagnostics@1` Trace legs (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `capture.diagnostics@1` over the shared fake HDC (`HDCOracleFake`) with its Trace legs:
/// `traceCategories` selects `capture-trace` (a blocking `hitrace -t`, or with `ringBuffered`
/// an armed ring with a coverage anchor written into the device's `trace_marker` and read back,
/// then snapshotted with `--trace_dump`), `receive-trace-artifact` (`file recv` of the owned
/// `.htrace`) and `cleanup-remote-temp` (`rm -f`). The legs raise the plan's effect to
/// `deviceMutation`, so each Job is admitted under a capability the Runtime issues by its default
/// policy. The engine is composed, as the daemon composes it, with the production
/// `FoundationTraceRuntimeProbe`, which brackets the steps with two snapshots of the trace tool
/// and its nine parameters: a Trace capture needs a capture-eligible `hitrace` offering every
/// requested tag before it starts, and records what the parameters read before and after it.
///
/// Two devices are adopted, whose `/data/local/tmp` the fake keeps between calls. On the first,
/// a blocking capture of three tags; a ring whose readback holds its anchor, with its own buffer
/// size; the same ring whose readback does not; every leg of the operation in one Job; a zero-
/// byte trace, whose receive and cleanup are skipped as upstream of a failure; a cleanup the
/// device refuses, which owes a cleanup debt; a tag the device does not offer, a tag list the
/// first snapshot cannot read, and one the second snapshot cannot read after the products are
/// published — each failing its Job. On the second device, a trace the readback cannot find parks
/// its Job, whose second snapshot is still taken. Two requests are refused before admission: a
/// category that is not an identifier and more categories than the catalog allows. Every Job's
/// result, evidence and Artifact list are read, each ring's record through `job.show`, then the
/// cleanup debts and the capability store.
///
/// The probe's reads run concurrently, so the oracle records each exchange's calls sorted, from
/// the answers' own one-append log (`hdc-calls.log`); the order of a Job's steps is its journal's
/// and its timeline's. The probe's help and tag-list answers are the registered trace-probe
/// resources (`openspec/integrations/openharmony/trace-probes/1.0.0`), copied beside the fake
/// under `resources/` and recorded with the oracle. Received files land in `receive` under the
/// fixed root. What the oracle keeps and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CAPTURE_TRACE_RECORD=/private/tmp/<new directory>`; otherwise the checked-in
/// oracle must match byte for byte.
final class CaptureDiagnosticsTraceOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    let inputs: [String: JSONValue]
    /// The fake's mode while this case's Job runs; a case without one only plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
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

  private static func tags(_ names: String...) -> [String: JSONValue] {
    ["traceCategories": .array(names.map(JSONValue.string))]
  }

  private static let ring: [String: JSONValue] = tags("ace").merging([
    "ringBuffered": .bool(true), "traceBufferKB": .integer(16_384),
  ]) { $1 }

  private static let cases: [Case] = [
    Case(
      name: "blocking", inputs: legs(tags("ability", "ace", "graphic")), mode: "normal",
      ends: "succeeded"),
    Case(name: "ring", inputs: legs(ring), mode: "normal", ends: "succeeded"),
    Case(name: "ringNotHeld", inputs: legs(ring), mode: "ringNotHeld", ends: "succeeded"),
    Case(
      name: "everyLeg",
      inputs: tags("ace", "graphic").merging([
        "durationSeconds": .integer(5), "advancedDump": .bool(true), "windowId": .string("7"),
        "componentId": .string("42"), "crashLogs": .bool(true),
        "crashLogName": .string("cppcrash-com.example.demo-20010039-20260914000000"),
        "bundleName": .string("com.example.demo"), "uiComponentTree": .bool(true),
        "uiScreenshot": .bool(true),
        "markers": .array([.string("2026-09-14T00:00:01Z#every leg")]),
      ]) { $1 },
      mode: "normal", ends: "succeeded"),
    Case(name: "emptyTrace", inputs: legs(tags("ace")), mode: "emptyTrace", ends: "succeeded"),
    Case(
      name: "cleanupRefused", inputs: legs(tags("ace")), mode: "cleanupRefused",
      ends: "succeeded"),
    Case(name: "tagNotOffered", inputs: legs(tags("notATag")), mode: "normal", ends: "failed"),
    Case(name: "tagListLost", inputs: legs(tags("ace")), mode: "tagListLost", ends: "failed"),
    Case(
      name: "afterTagListLost", inputs: legs(tags("ace")), mode: "afterTagListLost",
      ends: "failed"),
    Case(name: "categoryNotIdentifier", inputs: legs(tags("ab-c"))),
    Case(
      name: "tooManyCategories",
      inputs: legs(["traceCategories": .array((0..<25).map { .string("tag\($0)") })])),
    Case(
      name: "traceMissing", inputs: legs(tags("ace")), mode: "traceMissing",
      ends: "waitingForRecovery", device: "b"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capture-diagnostics-trace", directoryHint: .isDirectory)
  /// The registered help and tag-list families the fake answers with.
  private static let pack = repository.appending(
    path: "openspec/integrations/openharmony/trace-probes/1.0.0", directoryHint: .isDirectory)
  private static let resources: [(name: String, sha256: String)] = [
    ("hitrace-help.stdout.bin", TraceProbeAdapterProfile.hitraceHelpResourceSHA256),
    ("bytrace-help.stdout.bin", TraceProbeAdapterProfile.bytraceHelpResourceSHA256),
    ("hitrace-tags.stdout.bin", TraceProbeAdapterProfile.hitraceTagListResourceSHA256),
  ]
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let devices: [Character] = ["a", "b"]
  private static let receive = settings.root.appending(
    path: "receive", directoryHint: .isDirectory)
  /// The probe children's working directory: host-local, and in no answer.
  private static let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Caches/com.arkdeck.ArkDeck", directoryHint: .isDirectory)
    .appending(path: "capture-trace-oracle", directoryHint: .isDirectory)

  /// What the Trace legs and the probe around them ask, answered as `hdc` answers them: the
  /// evidence reads of the adopted devices and their storage; the probe's `hitrace --help`,
  /// `bytrace --help` and `hitrace -l` with the registered resources, and its nine `param get`
  /// reads (a bare value, an echoed `key = value`, the 106 miss, empty output); a blocking
  /// `hitrace -t` writing its owned `.htrace`; a ring's `--trace_begin`, the anchor written into
  /// the device's `trace_marker` and counted back from its ring, the window (`sleep`, answered at
  /// once), `--trace_dump` writing what the ring holds and `--trace_finish_nodump`; `ls -l`,
  /// `file recv` and `rm -f` of an owned path; and every other leg `everyLeg` selects, as the
  /// read-leg and file-leg oracles answer them. The fake writes under umask 077. By mode:
  /// `ringNotHeld` counts no anchor back and cannot read one parameter, `emptyTrace` writes a
  /// zero-byte trace, `cleanupRefused`
  /// refuses the removal, `tagListLost` answers every tag list with a transport marker,
  /// `afterTagListLost` only the second, and `traceMissing` writes no trace.
  private static let answers = #"""
    # capture.diagnostics@1 Trace-leg answers of the shared fake HDC, by mode.
    # The probe's reads run concurrently, so each call appends its own line
    # here (one append); the driver's log appends a call's arguments and its
    # newline apart.
    printf '%s\n' "$*" >> "$root/hdc-calls.log"
    keys='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    # The adopted device a call names, if it names one.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    if [ "$1" = -t ]; then
      for adopted in $keys; do [ "$2" = "$adopted" ] && key=$adopted; done
    fi
    resources=$root/resources
    # The devices' /data/local/tmp and trace ring, kept beside the log so that
    # a Job's owned files outlive the calls that made them; every owned name
    # carries its Job.
    device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
    /bin/mkdir -p "$root/device-tmp"
    umask 077
    parameter() {
      case "$mode:$1" in
      ringNotHeld:persist.rosen.animationtrace.enabled)
        printf 'device offline\n'
        exit 1 ;;
      esac
      case "$1" in
      persist.ace.trace.syntax.enabled) printf 'false\n' ;;
      persist.ace.trace.layout.enabled) printf '%s = true\n' "$1" ;;
      persist.ace.trace.build.enabled) printf 'Get parameter "%s" fail! errNum is:106!\n' "$1" ;;
      persist.ace.trace.measure.debug.enabled) printf '%s=1\n' "$1" ;;
      persist.ace.trace.sync.debug.enabled) : ;;
      persist.ace.debug.enabled) printf '0\n' ;;
      persist.ace.performance.monitor.enabled) printf '\n  true  \n\n' ;;
      persist.sys.graphic.openDebugTrace) printf '1\n' ;;
      persist.rosen.animationtrace.enabled) printf 'false\n' ;;
      *)
        printf 'unregistered fixture parameter\n' >&2
        exit 24 ;;
      esac
    }
    case "$*" in
    "list targets -v")
      for adopted in $keys; do
        printf '%s\t\tUSB\tConnected\tlocalhost\n' "$adopted"
      done ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell param get "*) parameter "$6" ;;
    "-t $key shell df -k /data/local/tmp")
      printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
      printf '/dev/block/data 1048576 1024 1047552 1%% /data\n' ;;
    "-t $key shell hitrace --help") /bin/cat "$resources/hitrace-help.stdout.bin" ;;
    "-t $key shell bytrace --help") /bin/cat "$resources/bytrace-help.stdout.bin" ;;
    "-t $key shell hitrace -l")
      case $mode in
      tagListLost) printf '[Fail]ExecuteCommand need connect-key?\n' ;;
      afterTagListLost)
        if [ -e "$root/tag-list-read" ]; then
          printf '[Fail]ExecuteCommand need connect-key?\n'
        else
          : > "$root/tag-list-read"
          /bin/cat "$resources/hitrace-tags.stdout.bin"
        fi ;;
      *) /bin/cat "$resources/hitrace-tags.stdout.bin" ;;
      esac ;;
    "-t $key shell pidof "*) printf '1234\n' ;;
    "-t $key shell hilog -x") printf '01-01 00:00:00 I app: hello\n' ;;
    "-t $key shell hidumper -s WindowManagerService -a -a") printf '{"windows":[]}\n' ;;
    "-t $key shell hidumper -s WindowManagerService -a -w 7 -element -lastpage 42")
      printf 'WindowId: 7\nComponentId: 42\ntype: Button\ntext: Sign in\n' ;;
    "-t $key shell hidumper -s 1201 -a -p Faultlogger -l")
      printf 'Fault log list:\n******\ncppcrash-com.example.demo-20010039-20260914000000\n******\n' ;;
    "-t $key shell hidumper -s 1201 -a -p Faultlogger -f "*)
      printf 'Generated by HiviewDFX@OpenHarmony\nProcess name:%s\n' "${8##* }" ;;
    "-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*)
      printf '{"attributes":{"text":"Sign in"},"children":[]}\n' > "$(device "$7")"
      printf 'DumpLayout saved to:%s\n' "$7" ;;
    "-t $key shell snapshot_display -t "*)
      printf '\211PNG\r\n\032\nIHDR still' > "$(device "$8")"
      printf 'process: display 0, file type: %s, width: 720, height: 1280\n' "$6" ;;
    "-t $key shell hitrace -t "*)
      # The owned path is the last argument, after `-o`.
      for owned; do :; done
      case $mode in
      emptyTrace) : > "$(device "$owned")" ;;
      traceMissing)
        printf 'hitrace: capture failed\n'
        exit 1 ;;
      *)
        printf '# tracer: nop\n  hitrace-1 [000] ....  1.000000: tracing_mark_write: B|1|capture\n' \
          > "$(device "$owned")" ;;
      esac
      printf 'hitrace enter, running_state is RECORDING_SHORT_TEXT\n' ;;
    "-t $key shell hitrace --trace_begin -b "*)
      : > "$root/device-ring"
      printf 'hitrace enter, running_state is RECORDING_LONG_BEGIN\n' ;;
    "-t $key shell echo ARKDECKANCHOR"*)
      marker=${4#echo }
      printf '%s\n' "${marker%% *}" >> "$root/device-ring" ;;
    "-t $key shell grep -c ARKDECKANCHOR"*)
      marker=${4#grep -c }
      if [ "$mode" = ringNotHeld ]; then
        printf '0\n'
      else
        /usr/bin/grep -c "${marker%% *}" "$root/device-ring"
      fi ;;
    "-t $key shell sleep "*) : ;;
    "-t $key shell hitrace --trace_dump -o /data/local/tmp/arkdeck-"*)
      {
        printf '# tracer: nop\n'
        while IFS= read -r line; do
          printf '  <...>-1 [000] ....  1.000000: tracing_mark_write: %s\n' "$line"
        done < "$root/device-ring"
      } > "$(device "$7")"
      printf 'hitrace enter, running_state is SNAPSHOT_DUMP\n' ;;
    "-t $key shell hitrace --trace_finish_nodump")
      printf 'hitrace enter, running_state is RECORDING_LONG_FINISH_NODUMP\n' ;;
    "-t $key shell ls -l /data/local/tmp/arkdeck-"*)
      if [ -f "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key file recv /data/local/tmp/arkdeck-"*)
      /bin/cp "$(device "$5")" "$6"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      case $mode in
      cleanupRefused)
        printf 'rm: %s: Read-only file system\n' "$6"
        exit 1 ;;
      *) /bin/rm -f "$(device "$6")" ;;
      esac ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCapturesTheTraceLegsOfTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_CAPTURE_TRACE_RECORD",
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
      handler, method, params, frameID: "capture-diagnostics-trace-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = [
      "inputs": .object(item.inputs), "device": .string(String(item.device)),
    ]
    if let mode = item.mode { fields["mode"] = .string(mode) }
    if let ends = item.ends { fields["ends"] = .string(ends) }
    return .object(fields)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    var resources: [String: Data] = [:]
    let installed = Self.settings.root.appending(path: "resources", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: installed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for resource in Self.resources {
      let data = try Data(contentsOf: Self.pack.appending(path: "fixtures/\(resource.name)"))
      XCTAssertEqual(SHA256Hex.string(of: data), resource.sha256, resource.name)
      try data.write(to: installed.appending(path: resource.name))
      resources["resources/\(resource.name)"] = data
    }
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
    try manager.createDirectory(
      at: Self.workingDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.workingDirectory) }
    let probe = FoundationTraceRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc"),
      workingDirectory: Self.workingDirectory)
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      hostReceiveRoot: Self.receive, traceRuntimeProbe: probe)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    // The probe's reads run concurrently, so each exchange's calls are
    // recorded sorted; one exchange's are never mixed with another's.
    var calls: [String] = []
    var recorded = 0
    func record(_ exchange: JSONValue) {
      exchanges.append(exchange)
      let lines = String(
        decoding: (try? Data(contentsOf: Self.settings.root.appending(path: "hdc-calls.log")))
          ?? Data(), as: UTF8.self
      )
      .split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast()
      .map(String.init)
      calls += lines.dropFirst(recorded).sorted()
      recorded = lines.count
    }
    for item in Self.cases {
      let target = try XCTUnwrap(adopted[item.device])
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: target.targetID))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      record(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard let mode = item.mode else {
        guard case .object(let fields) = plan, fields["ok"] == .bool(false) else {
          XCTFail("\(item.name): the plan was not refused: \(plan)")
          continue
        }
        continue
      }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      record(HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else {
        XCTFail("\(item.name): the admission was refused: \(submitted)")
        continue
      }
      jobs.append((item.name, job))
      try HDCOracleFake.setMode(mode)
      try? manager.removeItem(at: Self.settings.root.appending(path: "tag-list-read"))
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      record(
        HDCOracleHarness.exchange(
          "\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        XCTFail("\(item.name): the run was refused: \(run)")
        continue
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
    for (name, job) in jobs {
      var reads: [(String, String, [String: JSONValue])] = [
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
      // A ring's record keeps its coverage, which `job.show` publishes.
      if name.hasPrefix("ring") {
        reads.append(("show", "job.show", ["jobId": .string(job)]))
      }
      for (read, method, params) in reads {
        let answer = try await Self.send(composition.handler, method, params)
        record(HDCOracleHarness.exchange("\(name).\(read)", method, params, answer))
      }
    }
    // The Runtime's debt ledger, where the refused cleanup's residue is owed.
    record(
      HDCOracleHarness.exchange(
        "debt.list", "cleanupDebt.list", [:],
        try await Self.send(composition.handler, "cleanupDebt.list", [:])))
    let capabilities = try await Self.send(composition.handler, "capability.list", [:])
    record(HDCOracleHarness.exchange("capabilities.list", "capability.list", [:], capabilities))
    guard case .object(let listed) = capabilities, case .array(let items)? = listed["result"]
    else { throw CocoaError(.coderInvalidValue) }
    for (index, item) in items.enumerated() {
      guard case .object(let fields) = item, case .string(let id)? = fields["capabilityId"]
      else { throw CocoaError(.coderInvalidValue) }
      let params: [String: JSONValue] = ["capabilityId": .string(id)]
      record(
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
        "CaptureDiagnosticsTraceOracleContractTests.testSwiftCapturesTheTraceLegsOfTheSharedFakeDevice",
      settings: Self.settings,
      calls: Data(calls.map { $0 + "\n" }.joined().utf8), resources: resources)
  }
}
