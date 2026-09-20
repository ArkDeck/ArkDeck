// Shared Swift oracle for the Rust Debug Runtime probe (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `debug.probe` and `debug.template.run` over the shared fake HDC
/// (`HDCOracleFake`), through the daemon's control-plane handler composed
/// with the production `FoundationDebugRuntimeProbe` the daemon composes
/// beside a started HDC server host. Neither method creates a Job or a
/// capability: each is a bounded, target-bound, read-only probe.
///
/// The probe runs its three reads concurrently (`bm dump -a`, `fport ls`,
/// `rport ls`), so the fake receives them in no fixed order. The oracle
/// records each exchange's calls sorted, which is what the Rust replay
/// compares; the calls of one exchange are never mixed with another's. They
/// are the fake answers' own `hdc-calls.log`, one append per call: the
/// driver's `hdc-invocations.log` appends a call's arguments and its newline
/// separately, which concurrent calls interleave.
/// Every child reports the oracle's fixed duration, since `debug.template.run`
/// discloses how long its command ran and the host's clock is not the
/// oracle's.
///
/// What is recorded: the full portrait; each way a read is lost (a non-zero
/// exit, an unparseable inventory, an offline marker) and the warnings they
/// name; a target never adopted; every refusal the handler gives before the
/// probe; each of the four templates; a non-zero exit; an output over its
/// budget; a command killed by a signal, whose exit code is null; and output
/// that is not UTF-8.
///
/// Every request here is one a caller may send: a `targetId` that is not a
/// string is refused by the method's own request schema, so recording it
/// would put a line in the corpus that its schema refuses. The Rust replay
/// covers that refusal on its own.
///
/// The probe's runner binds every child to a product-owned working
/// directory, which `ArkDeckProcess` requires to be a real path of its own
/// (`/private/tmp` is not: it resolves to `/tmp`). The daemon binds its state
/// directory; this oracle binds one under this user's caches, removed after
/// the run. No answer reaches it: the fake writes only to its fixed root.
///
/// Record a new oracle with
/// `ARKDECK_RUST_DEBUG_PROBE_RECORD=/private/tmp/<new directory>`; otherwise
/// the checked-in oracle must match byte for byte.
final class DebugProbeOracleContractTests: XCTestCase {
  /// Every child of this oracle ran for exactly this long, as
  /// `debug.template.run` discloses it.
  private struct FixedDurationRunner: RockchipRuntimeCommandRunning {
    let base: FoundationRockchipRuntimeCommandRunner
    let seconds: Double

    func run(
      executable: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds: Int?,
      outputByteBudget: Int,
      criticalNonInterruptible: Bool
    ) async throws -> ProviderSubprocessReceipt {
      let receipt = try await base.run(
        executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds,
        outputByteBudget: outputByteBudget, criticalNonInterruptible: criticalNonInterruptible)
      return ProviderSubprocessReceipt(
        exitStatus: receipt.exitStatus, stdout: receipt.stdout, stderr: receipt.stderr,
        stdoutTruncated: receipt.stdoutTruncated, durationSeconds: seconds)
    }
  }

  /// One recorded request: the method, the fake's mode while it is answered,
  /// and the parameters as they are sent.
  private struct Case {
    let name: String
    let method: String
    var mode: String?
    var params: [String: JSONValue]
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/debug-probe", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  /// The children's working directory: host-local, and in no answer.
  private static let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Caches/com.arkdeck.ArkDeck", directoryHint: .isDirectory)
    .appending(path: "debug-probe-oracle", directoryHint: .isDirectory)
  private static let durationSeconds = 0.012
  /// A target identity the store never adopted.
  private static let unadopted = "TGT-000000000000"

  /// The fake's answers to the probe's three reads and to each template, by
  /// mode. `packagesUnavailable` exits non-zero, `packagesUnparseable`
  /// answers text naming no bundle, `forwardUnavailable` exits non-zero and
  /// `reverseUnavailable` answers HDC's offline marker, which the read-only
  /// receipt validation refuses; `allUnavailable` loses all three.
  /// `templateFailure` exits non-zero with a diagnostic, `templateKilled`
  /// dies by a signal, `templateTruncated` answers past the parameter
  /// template's 4 KiB budget, and `templateBinary` answers bytes that are not
  /// UTF-8.
  private static let answers = #"""
    # debug.probe and debug.template.run answers of ArkDeckFakeHDCFixture, by mode.
    # The driver records a call as two appends (its arguments, then a
    # newline), which three concurrent reads interleave. This oracle records
    # its own line instead: one append, so one call is one line whatever else
    # runs beside it.
    printf '%s\n' "$*" >> "$root/hdc-calls.log"
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    packages() {
      printf 'Bundle names:\n'
      printf '\tcom.example.alpha\n'
      printf '\tcom.example.zeta\n'
    }
    case "$*" in
    "-t $key shell bm dump -a")
      case "$mode" in
      packagesUnavailable|allUnavailable) exit 1 ;;
      packagesUnparseable) printf 'no bundle is installed\n' ;;
      *) packages ;;
      esac ;;
    "-t $key fport ls")
      case "$mode" in
      forwardUnavailable|allUnavailable) exit 1 ;;
      *) printf 'tcp:9000 tcp:9001    [Forward]\n' ;;
      esac ;;
    "-t $key rport ls")
      case "$mode" in
      reverseUnavailable|allUnavailable)
        printf '[Fail]Device not founded or connected\n' >&2 ;;
      *) printf 'tcp:9100 tcp:9101    [Reverse]\n' ;;
      esac ;;
    "-t $key shell param get persist.ace.debug.enabled")
      case "$mode" in
      templateTruncated) i=0; while [ $i -lt 600 ]; do printf 'persist.ace.debug.enabled=true\n'; i=$((i+1)); done ;;
      templateBinary) printf 'persist.ace.debug.enabled=\377\n' ;;
      *) printf 'true\n' ;;
      esac ;;
    "-t $key shell hidumper -s WindowManagerService -a -a")
      printf 'WindowManagerService\n----------\nfocus window: com.example.alpha\n' ;;
    "-t $key shell uptime")
      case "$mode" in
      templateFailure)
        printf 'uptime: cannot read /proc/uptime\n' >&2
        exit 7 ;;
      templateKilled)
        kill -9 $$
        sleep 5 ;;
      *) printf ' 10:00:00 up 1 day,  2:03,  0 users\n' ;;
      esac ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftProbesTheSharedFakeDebugRuntime() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_DEBUG_PROBE_RECORD",
      oracle: Self.oracle)
  }

  private static func cases(target: String) -> [Case] {
    let adopted: [String: JSONValue] = ["targetId": .string(target)]
    func template(_ id: String, mode: String? = nil, name: String) -> Case {
      Case(
        name: name, method: "debug.template.run", mode: mode,
        params: ["targetId": .string(target), "templateId": .string(id)])
    }
    return [
      // The portrait, and each way one of its three reads is lost.
      Case(name: "probe.full", method: "debug.probe", mode: "normal", params: adopted),
      Case(
        name: "probe.packagesUnavailable", method: "debug.probe", mode: "packagesUnavailable",
        params: adopted),
      Case(
        name: "probe.packagesUnparseable", method: "debug.probe", mode: "packagesUnparseable",
        params: adopted),
      Case(
        name: "probe.forwardUnavailable", method: "debug.probe", mode: "forwardUnavailable",
        params: adopted),
      Case(
        name: "probe.reverseUnavailable", method: "debug.probe", mode: "reverseUnavailable",
        params: adopted),
      Case(
        name: "probe.allUnavailable", method: "debug.probe", mode: "allUnavailable",
        params: adopted),
      // Refused before any read.
      Case(
        name: "probe.unadopted", method: "debug.probe", mode: "normal",
        params: ["targetId": .string(unadopted)]),
      Case(name: "probe.noParameters", method: "debug.probe", params: [:]),
      Case(
        name: "probe.extraKey", method: "debug.probe",
        params: ["targetId": .string(target), "rawCommand": .string("hdc shell id")]),
      Case(name: "probe.emptyTarget", method: "debug.probe", params: ["targetId": .string("")]),
      Case(
        name: "probe.longTarget", method: "debug.probe",
        params: ["targetId": .string(String(repeating: "t", count: 129))]),
      // Each template of the closed set.
      template("device.packageInventory", mode: "normal", name: "template.packages"),
      template("device.debugParameterRead", mode: "normal", name: "template.parameter"),
      template("device.windowInventory", mode: "normal", name: "template.windows"),
      template("device.uptime", mode: "normal", name: "template.uptime"),
      // What a template's own command can leave.
      template("device.uptime", mode: "templateFailure", name: "template.failingExit"),
      template("device.uptime", mode: "templateKilled", name: "template.killed"),
      template("device.debugParameterRead", mode: "templateTruncated", name: "template.truncated"),
      template("device.debugParameterRead", mode: "templateBinary", name: "template.notUTF8"),
      // Refused before any read.
      Case(
        name: "template.unadopted", method: "debug.template.run", mode: "normal",
        params: ["targetId": .string(unadopted), "templateId": .string("device.uptime")]),
      Case(
        name: "template.unknownTemplate", method: "debug.template.run",
        params: ["targetId": .string(target), "templateId": .string("device.reboot")]),
      Case(name: "template.noParameters", method: "debug.template.run", params: [:]),
      Case(
        name: "template.noTemplate", method: "debug.template.run",
        params: ["targetId": .string(target)]),
    ]
  }

  /// What each case was recorded for, so a probe that silently loses its
  /// reads — the working directory refused, the fake's answers renamed — is a
  /// failure here rather than a recorded portrait of nothing.
  private static func assertIntent(_ item: Case, _ answer: JSONValue) {
    guard case .object(let fields) = answer else { return XCTFail(item.name) }
    guard case .object(let result)? = fields["result"] else {
      XCTAssertEqual(fields["ok"], .bool(false), item.name)
      return
    }
    switch item.name {
    case "probe.full":
      XCTAssertEqual(
        result["packages"],
        .array([.string("com.example.alpha"), .string("com.example.zeta")]), item.name)
      XCTAssertEqual(result["warnings"], .array([]), item.name)
      guard case .array(let rules)? = result["portRules"] else { return XCTFail(item.name) }
      XCTAssertEqual(rules.count, 2, item.name)
    case "probe.packagesUnavailable":
      XCTAssertEqual(
        result["warnings"], .array([.string("packageInventoryUnavailable")]), item.name)
    case "probe.packagesUnparseable":
      XCTAssertEqual(
        result["warnings"], .array([.string("packageInventoryUnparseable")]), item.name)
    case "probe.forwardUnavailable":
      XCTAssertEqual(result["warnings"], .array([.string("forwardRulesUnavailable")]), item.name)
    case "probe.reverseUnavailable":
      XCTAssertEqual(result["warnings"], .array([.string("reverseRulesUnavailable")]), item.name)
    case "probe.allUnavailable":
      XCTAssertEqual(
        result["warnings"],
        .array([
          .string("forwardRulesUnavailable"), .string("packageInventoryUnavailable"),
          .string("reverseRulesUnavailable"),
        ]), item.name)
    case "template.failingExit":
      XCTAssertEqual(result["exitCode"], .integer(7), item.name)
    case "template.killed":
      XCTAssertEqual(result["exitCode"], .null, item.name)
    case "template.truncated":
      XCTAssertEqual(result["outputTruncated"], .bool(true), item.name)
    default:
      XCTAssertEqual(result["exitCode"], .integer(0), item.name)
      XCTAssertEqual(result["outputTruncated"], .bool(false), item.name)
    }
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
    try manager.createDirectory(
      at: Self.workingDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.workingDirectory) }
    let probe = FoundationDebugRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc"),
      runner: FixedDurationRunner(
        base: FoundationRockchipRuntimeCommandRunner(workingDirectory: Self.workingDirectory),
        seconds: Self.durationSeconds))
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      debugRuntimeProbe: probe)

    var exchanges: [JSONValue] = []
    // The probe's three reads run concurrently, so each exchange's calls are
    // recorded sorted; one exchange's are never mixed with another's.
    var calls: [String] = []
    var recorded = 0
    for item in Self.cases(target: adopted.targetID) {
      if let mode = item.mode { try HDCOracleFake.setMode(mode) }
      let answer = try await HDCOracleHarness.send(
        composition.handler, item.method, item.params, frameID: "debug-probe-oracle")
      exchanges.append(
        HDCOracleHarness.exchange(item.name, item.method, item.params, answer, mode: item.mode))
      let log = Self.settings.root.appending(path: "hdc-calls.log")
      let lines = String(
        decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
      calls += lines.dropFirst(recorded).sorted()
      recorded = lines.count
      Self.assertIntent(item, answer)
    }

    // This oracle runs no Job, so it keeps only what a probe touches: the
    // fake and its answers, the calls it received, the Target document the
    // routes read, and the cases.
    var files: [String: Data] = [
      "hdc": HDCOracleFake.driver,
      "hdc-answers.sh": Data(Self.answers.utf8),
      "hdc-calls.log": Data(calls.map { $0 + "\n" }.joined().utf8),
      "targets-state/targets.json": try Data(
        contentsOf: composition.targets.appending(path: "targets.json")),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "target": .object([
            "targetId": .string(adopted.targetID),
            "bindingRevision": .integer(Int64(adopted.bindingRevision)),
            "connectKey": .string(adopted.connectKey),
            "toolVersion": .string(adopted.toolVersion),
          ]),
          "unadoptedTarget": .string(Self.unadopted),
          "exchanges": .array(exchanges),
        ])) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "DebugProbeOracleContractTests.testSwiftProbesTheSharedFakeDebugRuntime"),
          "root": .string(Self.settings.root.path),
          "nowUTC": .string(Self.settings.nowUTC),
          "home": .string(Self.settings.home),
          "hdcSHA256": .string(SHA256Hex.string(of: HDCOracleFake.driver)),
          "targetId": .string(adopted.targetID),
          "invocationSeconds": .number(Self.durationSeconds),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
