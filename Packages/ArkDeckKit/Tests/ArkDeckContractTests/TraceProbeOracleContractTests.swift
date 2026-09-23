// Shared Swift oracle for the Rust Trace Runtime probe (CHG-2026-074, TASK-XPA-016).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `trace.probe` over the shared fake HDC (`HDCOracleFake`), through the
/// daemon's control-plane handler composed with the production
/// `FoundationTraceRuntimeProbe` the daemon composes beside a started HDC
/// server host, bound to a working directory as the daemon binds its state
/// directory. The method creates no Job and no capability: it is a bounded,
/// target-bound, read-only portrait of which trace tool the device offers.
///
/// The probe reads `hitrace --help` and `bytrace --help` concurrently, then
/// `hitrace -l` only when the hitrace help is the registered family, and
/// reads the nine catalog parameters beside them, so the fake receives up
/// to twelve calls in no fixed order. The oracle records each exchange's
/// calls sorted — the fake answers' own `hdc-calls.log`, one append per call
/// (the driver's `hdc-invocations.log` appends a call's arguments and its
/// newline separately, which concurrent calls interleave) — and never mixes
/// one exchange's calls with another's. Where the tag list fails, its answer
/// waits a second first: the probe then throws and the parameter reads it
/// still awaited would be cancelled, so the wait lets every parameter call
/// reach the fake in every run.
///
/// No parameter read here outlives its 15 s budget. `ArkDeckProcess` spawns
/// without close-on-exec, so a child spawned while a sibling's pipes are
/// still open in the daemon inherits them and holds that sibling's output
/// open for as long as it lives: in the run that tried it, a parameter read
/// that hung made four of its eight siblings time out with it, and which
/// ones depends on how the concurrent spawns interleave. The recorded
/// timeout is the tag list's, spawned alone once the help reads — held a
/// second in that mode — and every parameter read have ended.
///
/// The help and tag-list answers are the registered trace-probe resources
/// (`openspec/integrations/openharmony/trace-probes/1.0.0`), copied beside
/// the fake under `resources/` and recorded with the oracle; a mode restamps
/// one, drifts one byte of text, swaps the two tools' families, adds a
/// diagnostic, exits non-zero, dies by a signal or answers past the 64 KiB
/// a read keeps. The parameter reads cover each way `param get` is judged:
/// a bare value, the echoed `key = value` form, OpenHarmony's exact 106
/// miss (and its near misses), empty output, a value past 400 bytes, output
/// past the 4 KiB a read keeps, text that is not UTF-8 or begins with a
/// byte-order mark, a stderr past its budget beside a whole stdout, the
/// transport markers, a non-zero exit and a signal death. Refusals: a target
/// never adopted, an empty target and no parameters.
///
/// Every request here is one a caller may send: a `targetId` that is not a
/// string, or a parameter beside it, is refused by the method's own request
/// schema, so recording it would put a line in the corpus that its schema
/// refuses. The Rust replay covers those on its own.
///
/// Record a new oracle with
/// `ARKDECK_RUST_TRACE_PROBE_RECORD=/private/tmp/<new directory>`; otherwise
/// the checked-in oracle must match byte for byte.
final class TraceProbeOracleContractTests: XCTestCase {
  /// One recorded request: the fake's mode while it is answered, and the
  /// parameters as they are sent.
  private struct Case {
    let name: String
    var mode: String?
    var params: [String: JSONValue]
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/trace-probe", directoryHint: .isDirectory)
  /// The registered help and tag-list families the fake answers with.
  private static let pack = repository.appending(
    path: "openspec/integrations/openharmony/trace-probes/1.0.0", directoryHint: .isDirectory)
  private static let resources: [(name: String, sha256: String)] = [
    ("hitrace-help.stdout.bin", TraceProbeAdapterProfile.hitraceHelpResourceSHA256),
    ("bytrace-help.stdout.bin", TraceProbeAdapterProfile.bytraceHelpResourceSHA256),
    ("hitrace-tags.stdout.bin", TraceProbeAdapterProfile.hitraceTagListResourceSHA256),
    ("bytrace-tags.stdout.bin", TraceProbeAdapterProfile.bytraceTagListResourceSHA256),
  ]
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
    .appending(path: "trace-probe-oracle", directoryHint: .isDirectory)
  /// A target identity the store never adopted.
  private static let unadopted = "TGT-000000000000"

  /// The fake's answers by mode. Help: `restamped` answers the registered
  /// families captured at another time; `helpExitNonZero` answers them with a
  /// non-zero exit; `helpUnregistered` drifts one word of the hitrace help and
  /// answers a missing bytrace; `helpBadTimestamp` stamps a month that does
  /// not exist; `helpStderr` adds a diagnostic; `helpSwapped` answers each
  /// tool with the other's family; `helpUnobservable` kills the hitrace read
  /// and floods the bytrace one past its budget; `helpNotUTF8` answers bytes
  /// that are not text. Tag list: `tagsUnregistered`, `tagsStderr` and
  /// `tagsSwapped` answer lists the registry does not name; `tagsExitNonZero`,
  /// `tagsFailMarker`, `tagsUnobservable`, `tagsTruncated` and `tagsTimeout`
  /// lose the read. Parameters: `parametersUnreadable` and `parametersEdge`,
  /// per parameter below.
  private static let answers = #"""
    # trace.probe answers of the shared fake HDC, by mode. The probe's reads
    # run concurrently, so each call appends its own line here (one append);
    # the driver's log appends a call's arguments and its newline apart.
    printf '%s\n' "$*" >> "$root/hdc-calls.log"
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    resources=$root/resources
    # A registered family captured at another time: the registry ignores only
    # the leading `YYYY/MM/DD HH:MM:SS ` of its enter line.
    stamped() { printf '%s' "$1"; /usr/bin/tail -c +21 "$resources/$2"; }
    lines() { i=0; while [ $i -lt "$2" ]; do printf '%s\n' "$1"; i=$((i+1)); done; }
    run() { i=0; while [ $i -lt "$2" ]; do printf '%s' "$1"; i=$((i+1)); done; printf '\n'; }
    # Seven hundred lines of about a hundred bytes: past the 64 KiB a help or
    # tag read keeps.
    flood() { lines "$1 ................................................................................" 700; }
    missing() { printf 'Get parameter "%s" fail! errNum is:106!\n' "$1"; }
    parameter() {
      case "$mode:$1" in
      parametersUnreadable:persist.ace.trace.syntax.enabled)
        printf 'Get parameter "another.parameter" fail! errNum is:106!\n' ;;
      parametersUnreadable:persist.ace.trace.layout.enabled)
        printf 'Get parameter "%s" fail! errNum is:105!\n' "$1" ;;
      parametersUnreadable:persist.ace.trace.build.enabled)
        missing "$1"
        printf 'unexpected stderr\n' >&2 ;;
      parametersUnreadable:persist.ace.trace.measure.debug.enabled)
        missing "$1"
        printf 'extra output\n' ;;
      parametersUnreadable:persist.ace.trace.sync.debug.enabled) printf 'true\377\n' ;;
      parametersUnreadable:persist.ace.debug.enabled) run x 401 ;;
      parametersUnreadable:persist.ace.performance.monitor.enabled) lines "$1=true" 600 ;;
      parametersUnreadable:persist.sys.graphic.openDebugTrace) exit 1 ;;
      parametersUnreadable:persist.rosen.animationtrace.enabled) printf 'device offline\n' ;;
      parametersEdge:persist.ace.trace.syntax.enabled) printf 'device unauthorized\n' ;;
      parametersEdge:persist.ace.trace.layout.enabled) kill -9 $$ ;;
      parametersEdge:persist.ace.trace.build.enabled)
        printf '\n  Get parameter "%s" fail! errNum is:106!  \n\n' "$1" ;;
      parametersEdge:persist.ace.trace.measure.debug.enabled) printf 'other.key = 1\n' ;;
      parametersEdge:persist.ace.trace.sync.debug.enabled) printf '%s.extra = 1\n' "$1" ;;
      parametersEdge:persist.ace.debug.enabled) run y 400 ;;
      parametersEdge:persist.ace.performance.monitor.enabled)
        printf 'true\n'
        lines 'noise noise' 600 >&2 ;;
      parametersEdge:persist.sys.graphic.openDebugTrace)
        printf '\357\273\277'
        missing "$1" ;;
      parametersEdge:persist.rosen.animationtrace.enabled) printf '%s =\n' "$1" ;;
      *:persist.ace.trace.syntax.enabled) printf 'false\n' ;;
      *:persist.ace.trace.layout.enabled) printf '%s = true\n' "$1" ;;
      *:persist.ace.trace.build.enabled) missing "$1" ;;
      *:persist.ace.trace.measure.debug.enabled) printf '%s=1\n' "$1" ;;
      *:persist.ace.trace.sync.debug.enabled) : ;;
      *:persist.ace.debug.enabled) printf '0\n' ;;
      *:persist.ace.performance.monitor.enabled) printf '\n  true  \n\n' ;;
      *:persist.sys.graphic.openDebugTrace) printf '1\n' ;;
      *:persist.rosen.animationtrace.enabled) printf 'false\n' ;;
      *)
        printf 'unregistered fixture parameter\n' >&2
        exit 24 ;;
      esac
    }
    case "$*" in
    "-t $key shell hitrace --help")
      case "$mode" in
      restamped) stamped '2026/09/14 08:30:00 ' hitrace-help.stdout.bin ;;
      helpExitNonZero)
        /bin/cat "$resources/hitrace-help.stdout.bin"
        exit 1 ;;
      helpUnregistered) /usr/bin/sed 's/buffer/BUFFER/' "$resources/hitrace-help.stdout.bin" ;;
      helpBadTimestamp) stamped '2026/13/14 08:30:00 ' hitrace-help.stdout.bin ;;
      helpStderr)
        /bin/cat "$resources/hitrace-help.stdout.bin"
        printf 'hitrace: running as shell\n' >&2 ;;
      helpSwapped) /bin/cat "$resources/bytrace-help.stdout.bin" ;;
      helpUnobservable) kill -9 $$ ;;
      helpNotUTF8) printf '\377\376 hitrace\n' ;;
      tagsTimeout)
        /bin/sleep 1
        /bin/cat "$resources/hitrace-help.stdout.bin" ;;
      *) /bin/cat "$resources/hitrace-help.stdout.bin" ;;
      esac ;;
    "-t $key shell bytrace --help")
      case "$mode" in
      restamped) stamped '2026/09/14 08:30:00 ' bytrace-help.stdout.bin ;;
      helpExitNonZero)
        /bin/cat "$resources/bytrace-help.stdout.bin"
        exit 3 ;;
      helpUnregistered)
        printf '/bin/sh: bytrace: inaccessible or not found\n'
        exit 127 ;;
      helpSwapped) /bin/cat "$resources/hitrace-help.stdout.bin" ;;
      helpUnobservable) flood 'bytrace usage' ;;
      tagsTimeout)
        /bin/sleep 1
        /bin/cat "$resources/bytrace-help.stdout.bin" ;;
      *) /bin/cat "$resources/bytrace-help.stdout.bin" ;;
      esac ;;
    "-t $key shell hitrace -l")
      case "$mode" in
      restamped) stamped '2026/09/14 08:30:00 ' hitrace-tags.stdout.bin ;;
      tagsUnregistered) /usr/bin/sed 's/Ability/ABILITY/' "$resources/hitrace-tags.stdout.bin" ;;
      tagsStderr)
        /bin/cat "$resources/hitrace-tags.stdout.bin"
        printf 'hitrace: running as shell\n' >&2 ;;
      tagsSwapped) /bin/cat "$resources/bytrace-tags.stdout.bin" ;;
      tagsExitNonZero)
        /bin/sleep 1
        /bin/cat "$resources/hitrace-tags.stdout.bin"
        exit 1 ;;
      tagsFailMarker)
        /bin/sleep 1
        printf '[Fail]ExecuteCommand need connect-key?\n' ;;
      tagsUnobservable)
        /bin/sleep 1
        kill -9 $$ ;;
      tagsTruncated)
        /bin/sleep 1
        flood 'category - description' ;;
      tagsTimeout) /bin/sleep 30 ;;
      *) /bin/cat "$resources/hitrace-tags.stdout.bin" ;;
      esac ;;
    "-t $key shell param get "*) parameter "$6" ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftProbesTheSharedFakeTraceRuntime() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_TRACE_PROBE_RECORD",
      oracle: Self.oracle)
  }

  private static func cases(target: String) -> [Case] {
    let adopted: [String: JSONValue] = ["targetId": .string(target)]
    func probe(_ mode: String, name: String) -> Case {
      Case(name: name, mode: mode, params: adopted)
    }
    return [
      // The portrait: hitrace capture-eligible, bytrace probe-only.
      probe("normal", name: "probe.captureEligible"),
      probe("restamped", name: "probe.restamped"),
      // What a help read can leave.
      probe("helpExitNonZero", name: "probe.helpExitNonZero"),
      probe("helpUnregistered", name: "probe.helpUnregistered"),
      probe("helpBadTimestamp", name: "probe.helpBadTimestamp"),
      probe("helpStderr", name: "probe.helpStderr"),
      probe("helpSwapped", name: "probe.helpSwapped"),
      probe("helpUnobservable", name: "probe.helpUnobservable"),
      probe("helpNotUTF8", name: "probe.helpNotUTF8"),
      // What the tag list can leave: an unregistered list is no authority,
      // a lost read fails the probe.
      probe("tagsUnregistered", name: "probe.tagsUnregistered"),
      probe("tagsStderr", name: "probe.tagsStderr"),
      probe("tagsSwapped", name: "probe.tagsSwapped"),
      probe("tagsExitNonZero", name: "probe.tagsExitNonZero"),
      probe("tagsFailMarker", name: "probe.tagsFailMarker"),
      probe("tagsUnobservable", name: "probe.tagsUnobservable"),
      probe("tagsTruncated", name: "probe.tagsTruncated"),
      probe("tagsTimeout", name: "probe.tagsTimeout"),
      // What the parameter reads can leave.
      probe("parametersUnreadable", name: "probe.parametersUnreadable"),
      probe("parametersEdge", name: "probe.parametersEdge"),
      // Refused before any read.
      Case(name: "probe.unadopted", mode: "normal", params: ["targetId": .string(unadopted)]),
      Case(name: "probe.emptyTarget", mode: "normal", params: ["targetId": .string("")]),
      Case(name: "probe.noParameters", params: [:]),
    ]
  }

  /// What each case was recorded for, so a probe that silently loses its
  /// reads — the working directory refused, the fake's answers or resources
  /// renamed — is a failure here rather than a recorded portrait of nothing.
  private static func assertIntent(_ item: Case, _ answer: JSONValue, registeredTags: [String]) {
    guard case .object(let fields) = answer else { return XCTFail(item.name) }
    guard case .object(let result)? = fields["result"] else {
      XCTAssertEqual(fields["ok"], .bool(false), item.name)
      guard case .object(let error)? = fields["error"] else { return XCTFail(item.name) }
      let code: String = item.mode == nil ? "invalidParams" : "rejected"
      XCTAssertEqual(error["code"], .string(code), item.name)
      XCTAssertTrue(
        item.name.hasPrefix("probe.tags") || item.name == "probe.unadopted"
          || item.name == "probe.emptyTarget" || item.name == "probe.noParameters",
        "\(item.name) must answer a portrait")
      return
    }
    func tools() -> [String] {
      guard case .array(let rows)? = result["tools"] else { return [] }
      return rows.compactMap { row in
        guard case .object(let fields) = row, case .string(let value)? = fields["disposition"]
        else { return nil }
        return value
      }
    }
    func states() -> [String] {
      guard case .array(let rows)? = result["parameters"] else { return [] }
      return rows.compactMap { row in
        guard case .object(let fields) = row, case .string(let value)? = fields["state"]
        else { return nil }
        return value
      }
    }
    let eligible = result["adapterDisposition"] == .string("captureEligible")
    switch item.name {
    case "probe.captureEligible", "probe.restamped", "probe.helpExitNonZero":
      XCTAssertTrue(eligible, item.name)
      XCTAssertEqual(result["tool"], .string("hitrace"), item.name)
      XCTAssertEqual(
        result["supportedTags"], .array(registeredTags.map(JSONValue.string)), item.name)
      XCTAssertEqual(tools(), ["captureEligible", "probeOnly"], item.name)
      XCTAssertEqual(
        result["rawHelpSha256"] == .string(TraceProbeAdapterProfile.hitraceHelpResourceSHA256),
        item.name != "probe.restamped", item.name)
      XCTAssertEqual(
        states(),
        ["value", "value", "missing", "value", "missing", "value", "value", "value", "value"],
        item.name)
    case "probe.helpUnregistered", "probe.helpSwapped":
      XCTAssertFalse(eligible, item.name)
      XCTAssertEqual(tools(), ["unrecognized", "unrecognized"], item.name)
    case "probe.helpBadTimestamp", "probe.helpStderr", "probe.helpNotUTF8":
      XCTAssertFalse(eligible, item.name)
      XCTAssertEqual(tools(), ["unrecognized", "probeOnly"], item.name)
    case "probe.helpUnobservable":
      XCTAssertFalse(eligible, item.name)
      XCTAssertEqual(tools(), ["probeFailed", "probeFailed"], item.name)
      XCTAssertEqual(result["rawHelp"], .null, item.name)
    case "probe.tagsUnregistered", "probe.tagsStderr", "probe.tagsSwapped":
      XCTAssertFalse(eligible, item.name)
      XCTAssertEqual(result["supportedTags"], .array([]), item.name)
      XCTAssertEqual(tools(), ["captureEligible", "probeOnly"], item.name)
    case "probe.parametersUnreadable":
      XCTAssertTrue(eligible, item.name)
      XCTAssertEqual(states(), Array(repeating: "unreadable", count: 9), item.name)
    case "probe.parametersEdge":
      XCTAssertTrue(eligible, item.name)
      XCTAssertEqual(
        states(),
        [
          "unreadable", "unreadable", "missing", "value", "value", "value", "value", "missing",
          "missing",
        ], item.name)
    default:
      XCTFail("\(item.name) was not expected to answer a portrait")
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    var files: [String: Data] = [:]
    let installed = Self.settings.root.appending(path: "resources", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: installed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for resource in Self.resources {
      let data = try Data(contentsOf: Self.pack.appending(path: "fixtures/\(resource.name)"))
      XCTAssertEqual(SHA256Hex.string(of: data), resource.sha256, resource.name)
      try data.write(to: installed.appending(path: resource.name))
      files["resources/\(resource.name)"] = data
    }
    struct Registry: Decodable {
      struct Capability: Decodable {
        let tool: String
        let registeredTags: [String]?
      }
      let capabilityMatrix: [Capability]
    }
    let registeredTags = try XCTUnwrap(
      try JSONDecoder().decode(
        Registry.self, from: Data(contentsOf: Self.pack.appending(path: "registry.yaml"))
      ).capabilityMatrix.first { $0.tool == "hitrace" }?.registeredTags)
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
    let probe = FoundationTraceRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc"),
      workingDirectory: Self.workingDirectory)
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      traceRuntimeProbe: probe)

    var exchanges: [JSONValue] = []
    // The probe's reads run concurrently, so each exchange's calls are
    // recorded sorted; one exchange's are never mixed with another's.
    var calls: [String] = []
    var recorded = 0
    for item in Self.cases(target: adopted.targetID) {
      if let mode = item.mode { try HDCOracleFake.setMode(mode) }
      let answer = try await HDCOracleHarness.send(
        composition.handler, "trace.probe", item.params, frameID: "trace-probe-oracle")
      exchanges.append(
        HDCOracleHarness.exchange(item.name, "trace.probe", item.params, answer, mode: item.mode))
      let log = Self.settings.root.appending(path: "hdc-calls.log")
      let lines = String(
        decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
      calls += lines.dropFirst(recorded).sorted()
      recorded = lines.count
      Self.assertIntent(item, answer, registeredTags: registeredTags)
    }

    // This oracle runs no Job, so it keeps only what a probe touches: the
    // fake, its answers and the resources they read, the calls it received,
    // the Target document the route reads, and the cases.
    files["hdc"] = HDCOracleFake.driver
    files["hdc-answers.sh"] = Data(Self.answers.utf8)
    files["hdc-calls.log"] = Data(calls.map { $0 + "\n" }.joined().utf8)
    files["targets-state/targets.json"] = try Data(
      contentsOf: composition.targets.appending(path: "targets.json"))
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
            "TraceProbeOracleContractTests.testSwiftProbesTheSharedFakeTraceRuntime"),
          "root": .string(Self.settings.root.path),
          "nowUTC": .string(Self.settings.nowUTC),
          "home": .string(Self.settings.home),
          "hdcSHA256": .string(SHA256Hex.string(of: HDCOracleFake.driver)),
          "targetId": .string(adopted.targetID),
          "resourcePack": .string(
            "openspec/integrations/openharmony/trace-probes/1.0.0/fixtures"),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
