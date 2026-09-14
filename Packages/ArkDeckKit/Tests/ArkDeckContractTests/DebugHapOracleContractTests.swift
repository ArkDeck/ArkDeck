// Shared Swift oracle for the Rust `debug.hap@1` engine (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `debug.hap@1` with the runbook's GJ-2 input (§3: install or replace,
/// stop the ability, uninstall at the end, a ten-second HiLog window) over
/// the shared fake HDC (`HDCOracleFake`), the first operation of Golden
/// Journey 2 and the M2 oracle lane A's Rust engine replays after the M1
/// operations. One device is adopted and an entry HAP and a feature package
/// are published under one input Job as Artifact leases; each case then
/// plans a request for the device, and a case with a mode also admits it
/// under the runtime's default policy capability and runs its Job while the
/// fake answers in that mode, so the Jobs run in order over one store: one
/// installs, starts, observes, stops and uninstalls the package, one sends
/// both packages as a set and installs the directory, one installs a package
/// the readback never lists, one cannot start the ability, one stops an
/// ability that keeps running, one uninstalls a package that stays
/// installed, one cannot remove its staged package and fails with the
/// residue recorded, and one gets an empty HiLog capture and parks. The other cases are refused before admission: a
/// stale binding revision, a request without one, a target never adopted, a
/// lease the store does not hold and a bundle name the Catalog rejects. A
/// second run of the installed Job is refused, every Job's result, evidence
/// and Artifact list are read, the cleanup debt the two dirty Jobs left is
/// listed, continued and listed again, and the capability store is read
/// last. What the oracle keeps and how it is composed is `HDCOracleHarness`.
///
/// Record a new oracle with `ARKDECK_RUST_DEBUG_HAP_RECORD=/private/tmp/<new
/// directory>`; otherwise the checked-in oracle must match byte for byte.
final class DebugHapOracleContractTests: XCTestCase {
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
    /// A lease other than the published entry HAP's.
    var lease: String?
    var bundleName = "com.example.demo"
    /// Whether the feature package rides along as an additional lease.
    var packageSet = false
  }

  private static let cases: [Case] = [
    Case(name: "installed", mode: "normal", ends: "succeeded"),
    Case(name: "packageSet", mode: "normal", ends: "succeeded", packageSet: true),
    Case(name: "notInstalled", mode: "notInstalled", ends: "failed"),
    Case(name: "startFailed", mode: "startFailed", ends: "failed"),
    Case(name: "stillRunning", mode: "stillRunning", ends: "failed"),
    Case(name: "stillInstalled", mode: "stillInstalled", ends: "succeeded"),
    Case(name: "cleanupDebt", mode: "cleanupDebt", ends: "failed"),
    Case(name: "emptyHilog", mode: "emptyHilog", ends: "waitingForRecovery"),
    Case(name: "staleBinding", bindingRevision: 2),
    Case(name: "unboundRequest", bindingRevision: nil),
    Case(name: "unadopted", target: "TGT-000000000000"),
    Case(
      name: "unknownLease",
      lease: "lease-v1:job-input-hap:ART-00000000000000000000000000000000"),
    Case(name: "badBundleName", bundleName: "demo"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/debug-hap", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let bundleName = "com.example.demo"

  /// The fake keeps the device's state between calls in marker files beside
  /// its log: whether the package is installed and whether the ability runs
  /// (cleared before every Job), and which provider-owned remote paths exist
  /// (each Job's own, kept, so that the residue a Job leaves is what its
  /// cleanup debt continuation finds).
  private static let applicationState = ["device-installed", "device-running"]

  /// What `debug.hap@1` asks with the GJ-2 input, answered as the scripted
  /// dispatcher of `DiagnosticsAndHAPContractTests` answers it, with the
  /// installed and running state and the owned remote paths kept in marker
  /// files so that the package readback after `bm install` and the one after
  /// `uninstall` differ and a path is listed until it is removed, by mode: `notInstalled` installs nothing, `startFailed` refuses the start,
  /// `stillRunning` ignores the force-stop, `stillInstalled` ignores the
  /// uninstall, `cleanupDebt` refuses to remove anything, and `emptyHilog`
  /// answers the bounded HiLog capture with nothing.
  private static let answers = #"""
    # debug.hap@1 answers of the scripted dispatcher of DiagnosticsAndHAPContractTests, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    bundle=com.example.demo
    installed=$root/device-installed
    running=$root/device-running
    marker() { printf '%s/device-path-%s' "$root" "$(printf '%s' "$1" | tr / _)"; }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell mkdir -p /data/local/tmp/arkdeck-"*)
      : > "$(marker "$6")" ;;
    "-t $key file send "*)
      : > "$(marker "$6")"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell bm install -p "*" -r")
      [ "$mode" = notInstalled ] || : > "$installed"
      printf 'install bundle successfully.\n' ;;
    "-t $key shell bm dump -n $bundle")
      if [ -e "$installed" ]; then
        printf '%s:\n' "$bundle"
        printf '{"applicationInfo":{"nativeLibraryPath":"libs/arm64","cpuAbi":"arm64-v8a"},"hapModuleInfos":[{"nativeLibraryFileNames":["libentry.so"]}]}\n'
      fi ;;
    "-t $key shell aa start -b $bundle -a EntryAbility")
      [ "$mode" = startFailed ] && exit 1
      : > "$running"
      printf 'start ability successfully\n' ;;
    "-t $key shell pidof $bundle")
      [ -e "$running" ] || exit 1
      printf '3421\n' ;;
    "-t $key shell hilog -x")
      [ "$mode" = emptyHilog ] || printf '01-01 00:00:00 I app: hello\n' ;;
    "-t $key shell aa force-stop $bundle")
      [ "$mode" = stillRunning ] || rm -f "$running" ;;
    "-t $key uninstall $bundle")
      [ "$mode" = stillInstalled ] || rm -f "$installed"
      printf 'uninstall bundle successfully\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      if [ "$mode" = cleanupDebt ]; then
        printf 'rm: %s: Permission denied\n' "$6" >&2
        exit 1
      fi
      rm -f "$(marker "$6")" ;;
    "-t $key shell rmdir /data/local/tmp/arkdeck-"*)
      rm -f "$(marker "$5")" ;;
    "-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
      if [ ! -e "$(marker "$6")" ]; then
        printf 'ls: %s: No such file or directory\n' "$6"
      elif [ -z "${6##*-packages}" ]; then
        printf '%s 2 shell shell 3452 2026-09-14 00:00 %s\n' drwxr-xr-x "$6"
      else
        printf '%s 1 shell shell 24 2026-09-14 00:00 %s\n' -rw-r--r-- "$6"
      fi ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftDebugsAHapOnTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_DEBUG_HAP_RECORD", oracle: Self.oracle)
  }

  private static func requestJSON(
    _ item: Case, target: String, entry: String, feature: String
  ) throws -> String {
    var bound: [String: JSONValue] = ["targetId": .string(item.target ?? target)]
    if let revision = item.bindingRevision {
      bound["expectedBindingRevision"] = .integer(Int64(revision))
    }
    var inputs: [String: JSONValue] = [
      "hapArtifactLease": .string(item.lease ?? entry),
      "bundleName": .string(item.bundleName),
      "abilityName": .string("EntryAbility"),
      "installPolicy": .string("installOrReplace"),
      "cleanupPolicy": .string("uninstall"),
      "postRunAbilityState": .string("stopped"),
      "captureDiagnostics": .bool(true),
      "diagnosticsDurationSeconds": .integer(10),
    ]
    if item.packageSet {
      inputs["additionalHapArtifactLeases"] = .array([.string(feature)])
    }
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-hap-\(item.name)"),
      "idempotencyKey": .string("idem-hap-\(item.name)"),
      "target": .object(bound),
      "operation": .object(["id": .string("debug.hap"), "version": .integer(1)]),
      "inputs": .object(inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "debug-hap-oracle")
  }

  /// Publishes one input package under the input Job and returns its lease.
  private static func publish(
    _ store: RuntimeArtifactStore, name: String, contents: String, target: RuntimeTargetRecord
  ) async throws -> String {
    let metadata = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap", stepID: "publish-hap",
        name: name, mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified, sourceOperation: "artifact.import-hap",
        providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: target.targetID, bindingRevision: target.bindingRevision,
          stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
            connectKey: connectKey)),
        contents: Data(contents.utf8)))
    return try await store.leaseReference(jobID: metadata.jobID, artifactID: metadata.artifactID)
  }

  private static func resetApplication() {
    for name in applicationState {
      try? FileManager.default.removeItem(at: HDCOracleFake.root.appending(path: name))
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
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings)
    let entry = try await Self.publish(
      composition.artifactStore, name: "entry.hap", contents: "synthetic entry package\n",
      target: adopted)
    let feature = try await Self.publish(
      composition.artifactStore, name: "feature.hsp", contents: "synthetic feature package\n",
      target: adopted)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let params: [String: JSONValue] = [
        "requestJson": .string(
          try Self.requestJSON(item, target: adopted.targetID, entry: entry, feature: feature))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard let mode = item.mode else { continue }
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
      Self.resetApplication()
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
    let installed = ["jobId": JSONValue.string(jobs[0].job)]
    exchanges.append(
      HDCOracleHarness.exchange(
        "installed.rerun", "job.run", installed,
        try await Self.send(composition.handler, "job.run", installed)))
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
    // The two dirty Jobs' residue: the package `stillInstalled` left on the
    // device (installed again by the parked Job) and the staged package
    // `cleanupDebt` could not remove. Both are continued while the fake
    // answers normally, so each is found present, removed and read absent.
    let byName = Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, $0.job) })
    guard let stillInstalled = byName["stillInstalled"], let cleanupDebt = byName["cleanupDebt"]
    else { throw CocoaError(.coderInvalidValue) }
    try HDCOracleFake.setMode("normal")
    let continuations: [(String, [String: JSONValue])] = [
      ("debt.list", [:]),
      (
        "debt.continueBundle",
        ["jobId": .string(stillInstalled), "bundleName": .string(Self.bundleName)]
      ),
      (
        "debt.continuePath",
        [
          "jobId": .string(cleanupDebt),
          "remotePath": .string("/data/local/tmp/arkdeck-\(cleanupDebt)-send-hap-owned.hap"),
        ]
      ),
      ("debt.listAfter", [:]),
    ]
    for (name, params) in continuations {
      let method = params.isEmpty ? "cleanupDebt.list" : "cleanupDebt.continue"
      let answer = try await Self.send(composition.handler, method, params)
      exchanges.append(HDCOracleHarness.exchange(name, method, params, answer, mode: "normal"))
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
        "leases": .object(["entry": .string(entry), "feature": .string(feature)]),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer: "DebugHapOracleContractTests.testSwiftDebugsAHapOnTheSharedFakeDevice",
      settings: Self.settings)
  }
}
