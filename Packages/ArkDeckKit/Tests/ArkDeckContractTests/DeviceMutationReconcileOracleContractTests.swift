// Shared Swift oracle for the Rust reconcile and resume of device mutation
// Jobs parked after a mutation intent (TASK-XPA-014, G5 slice 8; ADR-0009
// decisions 2 and 4 as ruled on 2026-09-19, design §L.1 item 13).
//
// Every scenario runs over the shared fake HDC (`HDCOracleFake`) at its fixed
// root, afresh, in `HDCOracleHarness`'s composition of the standalone daemon's
// engine, with one adopted device. A Job is admitted under the Runtime's
// default policy capability and run while the fake answers in a mode that
// makes its HDC call die on SIGKILL before or after the device changed, so
// the mutation's outcome is unknown: the Job parks in `waitingForRecovery`
// with its intent outstanding and its capability use `outcomeUnknown`. The
// daemon then starts again over the root (`recoverActiveJobs`), and
// `job.reconcile` decides the intent by the mutation's dedicated readback —
// or, with none, keeps it unknown — without ever resending it. A Job the
// readback confirms completed waits at its confirmed safe boundary, and
// `job.run` resumes it there (`resumeAtConfirmedSafeBoundary`): the steps its
// journal confirmed are skipped and the rest run under the capability use the
// Job already consumed. A Job whose daemon died while it ran with no intent
// outstanding is resumed by `job.run` from `running` the same way.
//
// - `portRule`: `port-forward.create@1` whose `fport` dies after writing the
//   rule; reconcile reads it back (`fport ls`), and the resumed Job reads it
//   back once more and succeeds, settling its use `confirmed`, so the next
//   create is admitted.
// - `debugHap`: `debug.hap@1` whose `bm install` dies before installing (the
//   readback finds no package: not executed, and the Job's failure
//   finalization removes its staged package), one parked on its read-only
//   HiLog capture (not executed: every declared compensation runs), and one
//   whose install dies after installing (completed; the resumed Job starts,
//   observes, stops, uninstalls and cleans up under its consumed use).
// - `nativeLibrary`: `deploy.native-library.app-owned@1` whose helper dies
//   after publishing (the readback finds the new library: completed, and the
//   resumed Job restarts, verifies and cleans up) and one whose helper dies
//   before publishing (the readback finds the old library: its publish state
//   is not safe to replay, so the Job stays parked and the lineage stays
//   blocked).
// - `screenSequence`: `capture.screen-sequence@1` whose `file recv` dies (a
//   receive is read-only: not executed, the Job fails) and one whose archive
//   the device never wrote, parked on its capture: the reconcile begins, and
//   then `PersistedTypedProviderAction.materialize()` does not know the screen
//   sequence's kinds, so it fails with nothing dispatched and the Job stays
//   parked.
// - `captureFileLegs`: `capture.diagnostics@1` with the component tree, whose
//   `uitest dumpLayout` dies before and after writing the tree (read back by
//   `ls -ld`: not executed, then completed and resumed through its receive and
//   cleanup), and a cleanup the device refuses, whose debt is continued.
// - `hapFinalizing`: `debug.hap@1` whose ability refuses to start, so the Job
//   fails and enters its failure finalization; the daemon dies as that begins
//   (the engine's `failureFinalizing` checkpoint), before any compensation.
//   The start keeps the Job `finalizing` for an explicit continuation, and
//   `job.run` continues it: the declared compensations run under the use the
//   Job consumed, and the Job fails with its original failure.
// - `tapBeforeConsume`, `tapAfterConsume`: `input.tap@1` whose daemon dies at
//   the engine's hook before the capability is consumed, or after the use and
//   the Job's evidence are durable and before the gesture's intent; after the
//   start the Job is still `running` with nothing outstanding, and `job.run`
//   resumes it: the first consumes its use, the second continues under the one
//   it holds.
//
// Each scenario keeps every answer, the store (Job index and files, the
// capability store, the fake's calls so far) after every step that writes
// one, and what `HDCOracleHarness` records of the root at the end.
//
// Record a new oracle with
// `ARKDECK_RUST_DEVICE_MUTATION_RECONCILE_RECORD=/private/tmp/<new directory>`;
// otherwise the checked-in oracle must match byte for byte.

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckClientKit
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class DeviceMutationReconcileOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/device-mutation-reconcile", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let bundleName = "com.example.demo"
  private static let receive = settings.root.appending(
    path: "receive", directoryHint: .isDirectory)
  /// Where a death copies the root, beside it under the fake's lock.
  private static let crash = URL(
    filePath: "/private/tmp/arkdeck-hdc-oracle-crash", directoryHint: .isDirectory)

  func testSwiftReconcilesAndResumesParkedDeviceMutations() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    let manager = FileManager.default
    defer {
      try? manager.removeItem(at: Self.settings.root)
      try? manager.removeItem(at: Self.crash)
    }
    var files: [String: Data] = [:]
    let scenarios: [(String, () async throws -> [String: Data])] = [
      ("portRule", portRule),
      ("debugHap", debugHap),
      ("nativeLibrary", nativeLibrary),
      ("screenSequence", screenSequence),
      ("captureFileLegs", captureFileLegs),
      ("hapFinalizing", hapFinalizing),
      ("tapBeforeConsume", { try await self.tapRunning(afterConsume: false) }),
      ("tapAfterConsume", { try await self.tapRunning(afterConsume: true) }),
    ]
    for (name, scenario) in scenarios {
      for (path, data) in try await scenario() {
        files["\(name)/\(path)"] = data
      }
    }
    try HDCOracleHarness.recordOrCompare(
      files, variable: "ARKDECK_RUST_DEVICE_MUTATION_RECONCILE_RECORD", oracle: Self.oracle)
  }

  // MARK: - The recorder every scenario shares

  /// The engine hook where a death copies the root, once.
  private final class CrashCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var copied = false
    private var failure: String?

    func take() {
      lock.withLock {
        guard !copied else { return }
        copied = true
        do {
          try? FileManager.default.removeItem(at: DeviceMutationReconcileOracleContractTests.crash)
          try FileManager.default.copyItem(
            at: HDCOracleFake.root, to: DeviceMutationReconcileOracleContractTests.crash)
        } catch {
          failure = "\(error)"
        }
      }
    }

    var outcome: (copied: Bool, failure: String?) { lock.withLock { (copied, failure) } }
  }

  /// One scenario over a fresh root: the fake with the scenario's answers, one
  /// adopted device, the daemon's engine composed over them (with the
  /// code-sign helper, the host receive root and the fixed child duration the
  /// scenario names), every request and its answer, and the store after every
  /// step that writes one.
  private final class Recorder {
    let answers: String
    let hdc: URL
    let targets: URL
    let adopted: RuntimeTargetRecord
    let helper: HDCNativeCodeSignHelperArtifact?
    let receive: URL?
    let seconds: Double?
    var composition: HDCOracleHarness.Composition
    var exchanges: [JSONValue] = []
    var files: [String: Data] = [:]
    var steps: [JSONValue] = []
    var jobs: [String: String] = [:]

    init(
      answers: String, helper: Bool = false, receive: URL? = nil, seconds: Double? = nil,
      testHooks: RuntimeJobEngine.Configuration.TestHooks = .none
    ) throws {
      self.answers = answers
      hdc = try HDCOracleFake.install(answers: answers)
      try? FileManager.default.removeItem(at: DeviceMutationReconcileOracleContractTests.crash)
      targets = DeviceMutationReconcileOracleContractTests.settings.root.appending(
        path: "targets-state", directoryHint: .isDirectory)
      adopted = try RuntimeTargetStore(directoryURL: targets).adopt(
        stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: DeviceMutationReconcileOracleContractTests.connectKey),
        connectKey: DeviceMutationReconcileOracleContractTests.connectKey,
        toolVersion: "3.2.0d",
        nowUTC: DeviceMutationReconcileOracleContractTests.settings.nowUTC
      ).record
      self.helper = helper ? try DeviceMutationReconcileOracleContractTests.installCodeSignHelper() : nil
      self.receive = receive
      self.seconds = seconds
      composition = try HDCOracleHarness.composition(
        hdc: hdc, targetStore: try RuntimeTargetStore(directoryURL: targets), targets: targets,
        settings: DeviceMutationReconcileOracleContractTests.settings,
        nativeCodeSignHelper: self.helper, hostReceiveRoot: receive,
        fixedInvocationSeconds: seconds, testHooks: testHooks)
    }

    func send(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
      try await HDCOracleHarness.send(
        composition.handler, method, params, frameID: "device-mutation-reconcile-oracle")
    }

    /// A request, sent and recorded under `name`.
    @discardableResult
    func exchange(_ name: String, _ method: String, _ params: [String: JSONValue]) async throws
      -> JSONValue
    {
      let answer = try await send(method, params)
      exchanges.append(HDCOracleHarness.exchange(name, method, params, answer))
      return answer
    }

    /// The Job store and the capability store as a reader finds them, and
    /// the calls the fake has received so far, recorded as `steps/<name>/`.
    func snapshot(_ name: String) throws {
      let manager = FileManager.default
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      let prefix = "steps/\(name)"
      files["\(prefix)/index.json"] =
        try encoder.encode(try HDCOracleHarness.index(of: composition.jobsState))
        + Data("\n".utf8)
      files["\(prefix)/hdc-invocations.log"] = try HDCOracleFake.invocations()
      for directory in ["jobs", "capabilities"] {
        let root = composition.jobsState.appending(path: directory, directoryHint: .isDirectory)
        guard manager.fileExists(atPath: root.path) else { continue }
        for path in try manager.subpathsOfDirectory(atPath: root.path).sorted() {
          let url = root.appending(path: path)
          var metadata = stat()
          guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
          guard metadata.st_mode & S_IFMT != S_IFDIR else { continue }
          let data = try Data(contentsOf: url)
          files["\(prefix)/\(directory)/\(path)"] =
            url.lastPathComponent == "job-record.json"
            ? HDCOracleHarness.machineIndependent(data) : data
        }
      }
      steps.append(.string(name))
    }

    /// `job.submit` of `request` as the Job `name`; its identity is kept.
    @discardableResult
    func submit(_ name: String, _ request: String) async throws -> JSONValue {
      let params: [String: JSONValue] = ["requestJson": .string(request)]
      let answer = try await exchange("\(name).submit", "job.submit", params)
      if case .object(let fields) = answer, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      {
        jobs[name] = job
      }
      return answer
    }

    /// `job.run` of the Job `job`, recorded as `name`, while the fake answers
    /// in `mode`, the device state files `cleared` removed first; then the
    /// fake answers normally again and the store is recorded.
    @discardableResult
    func run(
      _ name: String, job: String, mode: String = "normal", cleared: [String] = [],
      snapshot recorded: Bool = true
    ) async throws -> JSONValue {
      for state in cleared {
        try? FileManager.default.removeItem(at: HDCOracleFake.root.appending(path: state))
      }
      try HDCOracleFake.setMode(mode)
      let params: [String: JSONValue] = ["jobId": .string(jobs[job]!)]
      let answer = try await send("job.run", params)
      try HDCOracleFake.setMode("normal")
      guard case .object(var fields) = HDCOracleHarness.exchange(
        name, "job.run", params, answer, mode: mode)
      else { throw CocoaError(.coderInvalidValue) }
      if !cleared.isEmpty { fields["cleared"] = .array(cleared.map(JSONValue.string)) }
      exchanges.append(.object(fields))
      if recorded { try snapshot(name) }
      return answer
    }

    /// The daemon started again over the root: a new composition (no test
    /// hook), then `recoverActiveJobs`, recorded as `name`.
    func start(_ name: String) async throws {
      composition = try HDCOracleHarness.composition(
        hdc: hdc, targetStore: try RuntimeTargetStore(directoryURL: targets), targets: targets,
        settings: DeviceMutationReconcileOracleContractTests.settings,
        nativeCodeSignHelper: helper, hostReceiveRoot: receive, fixedInvocationSeconds: seconds)
      let recovered = try await composition.engine.recoverActiveJobs()
      exchanges.append(
        .object([
          "name": .string(name), "method": .string("recoverActiveJobs"),
          "answer": .array(try recovered.map { try RuntimeJobReadProjection.status($0) }),
        ]))
      try snapshot(name)
    }

    /// `job.reconcile` of the Job `job`, recorded as `name`, then the store.
    @discardableResult
    func reconcile(_ name: String, job: String) async throws -> JSONValue {
      let answer = try await exchange(name, "job.reconcile", ["jobId": .string(jobs[job]!)])
      try snapshot(name)
      return answer
    }

    /// Every Job's status, show, result and evidence, in `names` order.
    func reads(_ names: [String]) async throws {
      for name in names {
        let params: [String: JSONValue] = ["jobId": .string(jobs[name]!)]
        for method in ["job.status", "job.show", "job.result", "job.evidence"] {
          try await exchange("\(name).\(method)", method, params)
        }
      }
    }

    /// The capability store, listed and every capability inspected.
    func capabilities() async throws {
      let listed = try await exchange("capabilities.list", "capability.list", [:])
      guard case .object(let fields) = listed, case .array(let items)? = fields["result"] else {
        throw CocoaError(.coderInvalidValue)
      }
      for (index, item) in items.enumerated() {
        guard case .object(let capability) = item, case .string(let id)? = capability["capabilityId"]
        else { throw CocoaError(.coderInvalidValue) }
        try await exchange(
          "capabilities.inspect\(index)", "capability.inspect", ["capabilityId": .string(id)])
      }
    }

    /// What the scenario records: its steps, answers and snapshots, and what
    /// `HDCOracleHarness` records of the root.
    func finish(producer: String, extra: [String: JSONValue] = [:]) throws -> [String: Data] {
      var cases: [String: JSONValue] = [
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "jobs": .object(jobs.mapValues(JSONValue.string)),
        "steps": .array(steps),
        "exchanges": .array(exchanges),
      ]
      cases.merge(extra) { _, new in new }
      if let helper {
        cases["codeSignHelper"] = .object([
          "sha256": .string(helper.facts.sha256),
          "byteCount": .integer(Int64(helper.facts.byteCount)),
          "buildId": .string(helper.facts.buildID),
          "path": .string(helper.fileURL.path),
        ])
      }
      var recorded = try HDCOracleHarness.files(
        composition, target: adopted, cases: .object(cases), answers: answers,
        producer: "DeviceMutationReconcileOracleContractTests.\(producer)",
        settings: DeviceMutationReconcileOracleContractTests.settings)
      recorded.merge(files) { recorded, _ in recorded }
      return recorded
    }
  }

  private static func requestJSON(
    _ name: String, operation: String, inputs: [String: JSONValue], target: String
  ) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-mutation-\(name)"),
      "idempotencyKey": .string("idem-mutation-\(name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string(operation), "version": .integer(1)]),
      "inputs": .object(inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func state(_ answer: JSONValue) -> JSONValue? {
    guard case .object(let fields) = answer, case .object(let result)? = fields["result"] else {
      return nil
    }
    return result["state"]
  }

  private static func errorCode(_ answer: JSONValue) -> JSONValue? {
    guard case .object(let fields) = answer, case .object(let error)? = fields["error"] else {
      return nil
    }
    return error["code"]
  }

  // MARK: - portRule

  /// `port-forward.create@1` and its readback, answered as the port-forward
  /// oracle answers them; in mode `createKilledAfter` the `fport` creating a
  /// rule dies on SIGKILL after it wrote the rule.
  private static let portAnswers = #"""
    # port-forward.create@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    marker() { printf '%s/device-rule-%s' "$root" "$(printf '%s' "$*" | tr ': ' '__')"; }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key fport ls")
      for rule in "$root"/device-rule-*; do
        [ -e "$rule" ] || continue
        IFS= read -r row < "$rule"
        printf '%s    %s\n' "$key" "$row"
      done ;;
    "-t $key fport tcp:"*)
      printf '%s %s    [Forward]\n' "$4" "$5" > "$(marker "$4" "$5")"
      [ "$mode" = createKilledAfter ] && kill -KILL $$
      printf 'Forwardport result:OK\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  private func portRule() async throws -> [String: Data] {
    let recorder = try Recorder(answers: Self.portAnswers)
    let target = recorder.adopted.targetID
    func create(_ name: String, local: Int64, remote: Int64) throws -> String {
      try Self.requestJSON(
        name, operation: "port-forward.create",
        inputs: [
          "direction": .string("forward"), "localPort": .integer(local),
          "remotePort": .integer(remote),
        ], target: target)
    }
    try await recorder.submit("create", try create("create", local: 23461, remote: 34571))
    let parked = try await recorder.run("create.run", job: "create", mode: "createKilledAfter")
    XCTAssertEqual(Self.state(parked), .string("waitingForRecovery"))
    try await recorder.start("restart")
    let reconciled = try await recorder.reconcile("reconcile", job: "create")
    XCTAssertEqual(Self.state(reconciled), .string("resumeAtConfirmedSafeBoundary"))
    // A start at the confirmed boundary carries it as it is.
    try await recorder.start("secondRestart")
    let resumed = try await recorder.run("create.resume", job: "create")
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    let rerun = try await recorder.run("create.rerun", job: "create", snapshot: false)
    XCTAssertEqual(Self.errorCode(rerun), .string("resourceConflict"))
    try await recorder.reconcile("reconcileResumed", job: "create")
    // The use settled, the next create on the binding is admitted and runs.
    try await recorder.submit("next", try create("next", local: 23462, remote: 34572))
    let next = try await recorder.run("next.run", job: "next")
    XCTAssertEqual(Self.state(next), .string("succeeded"))
    try await recorder.reads(["create", "next"])
    try await recorder.capabilities()
    return try recorder.finish(producer: "portRule")
  }

  // MARK: - debugHap

  /// What `debug.hap@1` asks with the GJ-2 input, answered as the debug HAP
  /// oracle answers it, the installed and running state and the owned remote
  /// paths kept in marker files, by mode: `installKilledBefore` has `bm
  /// install` die on SIGKILL before it installs, `installKilledAfter` after,
  /// `emptyHilog` answers the bounded HiLog capture with nothing, and
  /// `startFailed` refuses the start.
  private static let hapAnswers = #"""
    # debug.hap@1 answers of the shared fake HDC, by mode.
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
    "-t $key file send "*)
      : > "$(marker "$6")"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell bm install -p "*" -r")
      [ "$mode" = installKilledBefore ] && kill -KILL $$
      : > "$installed"
      [ "$mode" = installKilledAfter ] && kill -KILL $$
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
      rm -f "$running" ;;
    "-t $key uninstall $bundle")
      rm -f "$installed"
      printf 'uninstall bundle successfully\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      rm -f "$(marker "$6")" ;;
    "-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
      if [ ! -e "$(marker "$6")" ]; then
        printf 'ls: %s: No such file or directory\n' "$6"
      else
        printf '%s 1 shell shell 24 2026-09-14 00:00 %s\n' -rw-r--r-- "$6"
      fi ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  /// The entry package published under the input Job as an Artifact lease
  /// bound to the adopted device, as the debug HAP oracle publishes it.
  private static func publishHap(_ recorder: Recorder) async throws -> String {
    let target = recorder.adopted
    let metadata = try await recorder.composition.artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap", stepID: "publish-hap",
        name: "entry.hap", mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified, sourceOperation: "artifact.import-hap",
        providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: target.targetID, bindingRevision: target.bindingRevision,
          stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
            connectKey: connectKey)),
        contents: Data("synthetic entry package\n".utf8)))
    return try await recorder.composition.artifactStore.leaseReference(
      jobID: metadata.jobID, artifactID: metadata.artifactID)
  }

  /// A `debug.hap@1` request with the runbook's GJ-2 input.
  private static func hapRequest(_ name: String, lease: String, target: String) throws -> String {
    try requestJSON(
      name, operation: "debug.hap",
      inputs: [
        "hapArtifactLease": .string(lease),
        "bundleName": .string(bundleName),
        "abilityName": .string("EntryAbility"),
        "installPolicy": .string("installOrReplace"),
        "cleanupPolicy": .string("uninstall"),
        "postRunAbilityState": .string("stopped"),
        "captureDiagnostics": .bool(true),
        "diagnosticsDurationSeconds": .integer(10),
      ], target: target)
  }

  private func debugHap() async throws -> [String: Data] {
    let recorder = try Recorder(answers: Self.hapAnswers)
    let lease = try await Self.publishHap(recorder)
    func hap(_ name: String) throws -> String {
      try Self.hapRequest(name, lease: lease, target: recorder.adopted.targetID)
    }
    // Killed before it installs: the readback finds no package, and the
    // failure finalization removes what the Job staged.
    try await recorder.submit("notInstalled", try hap("notInstalled"))
    let notInstalled = try await recorder.run(
      "notInstalled.run", job: "notInstalled", mode: "installKilledBefore")
    XCTAssertEqual(Self.state(notInstalled), .string("waitingForRecovery"))
    try await recorder.start("restart")
    let failed = try await recorder.reconcile("reconcileNotInstalled", job: "notInstalled")
    XCTAssertEqual(Self.state(failed), .string("failed"))
    // Parked on its read-only capture: not executed, and every compensation
    // its succeeded steps declared runs.
    try await recorder.submit("emptyHilog", try hap("emptyHilog"))
    let emptyHilog = try await recorder.run(
      "emptyHilog.run", job: "emptyHilog", mode: "emptyHilog")
    XCTAssertEqual(Self.state(emptyHilog), .string("waitingForRecovery"))
    try await recorder.start("secondRestart")
    let compensated = try await recorder.reconcile("reconcileEmptyHilog", job: "emptyHilog")
    XCTAssertEqual(Self.state(compensated), .string("failed"))
    // Killed after it installs: completed, and the Job resumes after it.
    try await recorder.submit("installed", try hap("installed"))
    let installed = try await recorder.run(
      "installed.run", job: "installed", mode: "installKilledAfter")
    XCTAssertEqual(Self.state(installed), .string("waitingForRecovery"))
    try await recorder.start("thirdRestart")
    let confirmed = try await recorder.reconcile("reconcileInstalled", job: "installed")
    XCTAssertEqual(Self.state(confirmed), .string("resumeAtConfirmedSafeBoundary"))
    let resumed = try await recorder.run("installed.resume", job: "installed")
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    try await recorder.reads(["notInstalled", "emptyHilog", "installed"])
    try await recorder.exchange("debt.list", "cleanupDebt.list", [:])
    try await recorder.capabilities()
    return try recorder.finish(producer: "debugHap", extra: ["lease": .string(lease)])
  }

  // MARK: - hapFinalizing

  /// A debug HAP whose ability refuses to start fails and enters its failure
  /// finalization; the daemon dies at the engine's `failureFinalizing`
  /// checkpoint, once the failure and the `finalizing` state are durable and
  /// before any compensation. The whole root is copied there, the live run
  /// goes on to its end, and the copy then replaces the root. The start keeps
  /// the Job `finalizing` for an explicit continuation, and `job.run`
  /// continues it.
  private func hapFinalizing() async throws -> [String: Data] {
    let capture = CrashCapture()
    let recorder = try Recorder(
      answers: Self.hapAnswers,
      testHooks: .init(debugHAPCheckpoint: { _, point in
        if point == "failureFinalizing" { capture.take() }
      }))
    let lease = try await Self.publishHap(recorder)
    try await recorder.submit(
      "startFailed",
      try Self.hapRequest("startFailed", lease: lease, target: recorder.adopted.targetID))
    // The live run goes on past the checkpoint to its end; only the copy is
    // kept, whose fake still answers in the mode the run named.
    try HDCOracleFake.setMode("startFailed")
    _ = try await recorder.send("job.run", ["jobId": .string(recorder.jobs["startFailed"]!)])
    let outcome = capture.outcome
    XCTAssertNil(outcome.failure)
    XCTAssertTrue(outcome.copied, "the checkpoint never ran")
    let manager = FileManager.default
    try manager.removeItem(at: Self.settings.root)
    try manager.copyItem(at: Self.crash, to: Self.settings.root)
    try manager.removeItem(at: Self.crash)
    try HDCOracleFake.setMode("normal")
    try recorder.snapshot("crash")
    try await recorder.start("restart")
    let continued = try await recorder.run("startFailed.continue", job: "startFailed")
    XCTAssertEqual(Self.state(continued), .string("failed"))
    let rerun = try await recorder.run("startFailed.rerun", job: "startFailed", snapshot: false)
    XCTAssertEqual(Self.errorCode(rerun), .string("resourceConflict"))
    try await recorder.reads(["startFailed"])
    try await recorder.exchange("debt.list", "cleanupDebt.list", [:])
    try await recorder.capabilities()
    return try recorder.finish(
      producer: "hapFinalizing",
      extra: [
        "lease": .string(lease),
        "window": .string("RuntimeJobEngine test hook debugHAPCheckpoint failureFinalizing"),
      ])
  }

  // MARK: - nativeLibrary

  private static let library = NativeLibraryTestFixture.arm64ELF()
  /// The attestation digest the fake's helper reports for the library the
  /// deployment replaces, and so for its backup and for the replacement.
  private static let replacedDigest = String(repeating: "0123456789abcdef", count: 4)
  /// Where the oracle keeps its copy of the bundled code-sign helper.
  private static let codeSignHelperPath = HDCOracleFake.root.appending(
    path: "host/arkdeck-code-sign-enable")
  private static let bundledCodeSignHelper = try! HDCNativeCodeSignHelperArtifact.bundled()

  /// The bundled helper's bytes at the oracle's fixed path, verified again as
  /// the provider would verify the bundle.
  private static func installCodeSignHelper() throws -> HDCNativeCodeSignHelperArtifact {
    let manager = FileManager.default
    try manager.createDirectory(
      at: codeSignHelperPath.deletingLastPathComponent(), withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try Data(contentsOf: bundledCodeSignHelper.fileURL).write(to: codeSignHelperPath)
    guard chmod(codeSignHelperPath.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let facts = try NativeLibraryArtifactValidator.validate(
      try Data(contentsOf: codeSignHelperPath), expectedABI: .arm64)
    XCTAssertEqual(facts.sha256, bundledCodeSignHelper.facts.sha256)
    return HDCNativeCodeSignHelperArtifact(
      fileURL: codeSignHelperPath,
      facts: HDCNativeCodeSignHelperFacts(
        abi: facts.abi, buildID: facts.buildID, sha256: facts.sha256, byteCount: facts.byteCount))
  }

  /// What `deploy.native-library.app-owned@1` asks with the GJ-3 input,
  /// answered as the native-library oracle answers it (the target hashes to
  /// the replaced library until the helper publishes and to the leased ELF
  /// after), by mode: the helper's `publish` dies on SIGKILL before it
  /// publishes (`publishKilledBefore`) or after (`publishKilledAfter`).
  private static let nativeAnswers = #"""
    # deploy.native-library.app-owned@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    bundle=com.example.demo
    directory=/data/app/el1/bundle/public/$bundle/libs/arm
    target=$directory/libexample.so
    loader=/data/storage/el1/bundle/libs/arm/libexample.so
    replaced=\#(replacedDigest)
    library=\#(NativeLibraryTestFixture.sha256(library))
    helper=\#(bundledCodeSignHelper.facts.sha256)
    running=$root/device-running
    published=$root/device-published
    marker() { printf '%s/device-path-%s' "$root" "$(printf '%s' "$1" | tr / _)"; }
    listed() {
      case "$1" in
      */arkdeck-native/*/*)
        printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
      "$directory"|*/libs|*/arkdeck-native/*)
        printf '%s 2 20010050 20010050 3452 2026-09-14 00:00 %s\n' drwx------ "$1" ;;
      *)
        printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
      esac
    }
    present() {
      case "$1" in
      "$directory"|"$target"|*/libs) true ;;
      *) [ -e "$(marker "$1")" ] ;;
      esac
    }
    case "$*" in
    "-t $key shell mkdir -p "*)
      : > "$(marker "$6")" ;;
    "-t $key file send "*)
      : > "$(marker "$6")"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell chmod 700 "*)
      ;;
    "-t $key shell sha256sum "*)
      if ! present "$5"; then
        printf 'sha256sum: %s: No such file or directory\n' "$5"
        exit 0
      fi
      case "$5" in
      *.staging) printf '%s  %s\n' "$library" "$5" ;;
      */arkdeck-code-sign-enable) printf '%s  %s\n' "$helper" "$5" ;;
      "$target") if [ -e "$published" ]; then printf '%s  %s\n' "$library" "$5"; else printf '%s  %s\n' "$replaced" "$5"; fi ;;
      *) printf '%s  %s\n' "$replaced" "$5" ;;
      esac ;;
    "-t $key shell ls -la "*)
      if present "$6"; then printf 'total 4\n'; listed "$6/arm"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
    "-t $key shell ls -l "*|"-t $key shell ls -ld "*|"-t $key shell ls -ln "*)
      if present "$6"; then listed "$6"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
    "-t $key shell rm -f "*)
      rm -f "$(marker "$6")" ;;
    "-t $key shell rmdir "*)
      rm -f "$(marker "$5")" ;;
    "-t $key shell ln "*)
      : > "$(marker "$6")" ;;
    "-t $key shell mv -f "*)
      rm -f "$(marker "$6")" "$published" ;;
    "-t $key shell "*"/arkdeck-code-sign-enable verify "*)
      printf 'ARKDECK_CODE_SIGN_VERIFIED sha256:%s\n' "$replaced" ;;
    "-t $key shell "*"/arkdeck-code-sign-enable publish "*)
      [ "$mode" = publishKilledBefore ] && kill -KILL $$
      : > "$published"
      [ "$mode" = publishKilledAfter ] && kill -KILL $$
      printf 'ARKDECK_CODE_SIGN_PUBLISHED sha256:%s\n' "$replaced" ;;
    "-t $key shell aa force-stop $bundle")
      rm -f "$running" ;;
    "-t $key shell aa start -b $bundle -a EntryAbility")
      : > "$running" ;;
    "-t $key shell pidof $bundle")
      [ -e "$running" ] || exit 1
      printf '4321\n' ;;
    "-t $key shell sleep 2")
      ;;
    "-t $key shell grep -F $loader /proc/*/maps")
      printf '/proc/4321/maps:7f000 %s\n' "$loader" ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  private func nativeLibrary() async throws -> [String: Data] {
    let recorder = try Recorder(answers: Self.nativeAnswers, helper: true)
    let target = recorder.adopted
    let published = try await recorder.composition.artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-native-library", sessionID: "session-input-native-library",
        stepID: "publish-native-library", name: "libexample.so",
        mediaType: "application/x-elf", privacy: .standard,
        retentionClass: .pinnedUntilVerified, sourceOperation: "artifact.import-native-library",
        providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: target.targetID, bindingRevision: target.bindingRevision,
          stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
            connectKey: Self.connectKey)),
        contents: Self.library))
    let lease = try await recorder.composition.artifactStore.leaseReference(
      jobID: published.jobID, artifactID: published.artifactID)
    func deploy(_ name: String) throws -> String {
      try Self.requestJSON(
        name, operation: "deploy.native-library.app-owned",
        inputs: [
          "libraryArtifactLease": .string(lease),
          "targetBundle": .string(Self.bundleName),
          "libraryLogicalName": .string("libexample.so"),
          "expectedABI": .string("arm64-v8a"),
          "restartProfile": .string("restartAbility"),
          "verificationProfile": .string("hashProcessAndMaps"),
          "rollbackPolicy": .string("autoRollback"),
        ], target: target.targetID)
    }
    let application = ["device-running", "device-published"]
    // The helper dies once it published: the target reads back as the new
    // library, so the publish completed and the Job resumes after it.
    try await recorder.submit("published", try deploy("published"))
    let parked = try await recorder.run(
      "published.run", job: "published", mode: "publishKilledAfter", cleared: application)
    XCTAssertEqual(Self.state(parked), .string("waitingForRecovery"))
    try await recorder.start("restart")
    let confirmed = try await recorder.reconcile("reconcilePublished", job: "published")
    XCTAssertEqual(Self.state(confirmed), .string("resumeAtConfirmedSafeBoundary"))
    let resumed = try await recorder.run("published.resume", job: "published")
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    // The helper dies before it published: the target reads back as the old
    // library, which a publish never proves not executed; the Job stays
    // parked, is not resumed, and its unknown use refuses the next request.
    try await recorder.submit("unpublished", try deploy("unpublished"))
    let unpublished = try await recorder.run(
      "unpublished.run", job: "unpublished", mode: "publishKilledBefore", cleared: application)
    XCTAssertEqual(Self.state(unpublished), .string("waitingForRecovery"))
    try await recorder.start("secondRestart")
    let unknown = try await recorder.reconcile("reconcileUnpublished", job: "unpublished")
    XCTAssertEqual(Self.state(unknown), .string("waitingForRecovery"))
    let refused = try await recorder.run("unpublished.resume", job: "unpublished", snapshot: false)
    XCTAssertEqual(Self.errorCode(refused), .string("resourceConflict"))
    let blocked = try await recorder.submit("afterUnknown", try deploy("afterUnknown"))
    XCTAssertEqual(Self.errorCode(blocked), .string("admissionDenied"))
    try await recorder.reads(["published", "unpublished"])
    try await recorder.exchange("debt.list", "cleanupDebt.list", [:])
    try await recorder.capabilities()
    return try recorder.finish(
      producer: "nativeLibrary",
      extra: [
        "lease": .string(lease),
        "library": .object([
          "sha256": .string(NativeLibraryTestFixture.sha256(Self.library)),
          "byteCount": .integer(Int64(Self.library.count)),
          "buildId": .string(NativeLibraryTestFixture.buildID),
        ]),
      ])
  }

  // MARK: - screenSequence

  /// What `capture.screen-sequence@1` asks, answered as the screen-sequence
  /// oracle answers it, the device's `/data/local/tmp` kept beside the log, by
  /// mode: `receiveKilled` has `file recv` die on SIGKILL before it copies the
  /// archive, and `missingArchive` cannot write the archive at all.
  private static let sequenceAnswers = #"""
    # capture.screen-sequence@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
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
    "-t $key shell mkdir -p /data/local/tmp/arkdeck-"*)
      mkdir -p "$(device "$6")" ;;
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
      printf '%s %sx%s\n' "${frame##*/}" "$width" "$height" > "$(device "$frame")"
      printf 'file type: %s, width: %s, height: %s\n' "$type" "$width" "$height" ;;
    "-t $key shell tar -c -f /data/local/tmp/arkdeck-"*)
      if [ "$mode" = missingArchive ]; then
        printf 'tar: %s: No space left on device\n' "$7"
        exit 1
      fi
      for still in "$(device "$9")"/*; do cat "$still"; done > "$(device "$7")" ;;
    "-t $key shell ls -l /data/local/tmp/arkdeck-"*)
      if [ -f "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key file recv /data/local/tmp/arkdeck-"*)
      [ "$mode" = receiveKilled ] && kill -KILL $$
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

  private func screenSequence() async throws -> [String: Data] {
    let recorder = try Recorder(answers: Self.sequenceAnswers, receive: Self.receive, seconds: 0.5)
    let target = recorder.adopted.targetID
    func sequence(_ name: String) throws -> String {
      try Self.requestJSON(
        name, operation: "capture.screen-sequence", inputs: ["frameCount": .integer(3)],
        target: target)
    }
    // A receive is read-only: its lost outcome is confirmed not executed.
    try await recorder.submit("receiveKilled", try sequence("receiveKilled"))
    let receiveKilled = try await recorder.run(
      "receiveKilled.run", job: "receiveKilled", mode: "receiveKilled")
    XCTAssertEqual(Self.state(receiveKilled), .string("waitingForRecovery"))
    try await recorder.start("restart")
    let failed = try await recorder.reconcile("reconcileReceiveKilled", job: "receiveKilled")
    XCTAssertEqual(Self.state(failed), .string("failed"))
    // A parked capture is never concluded: the reconcile begins (the Journal
    // moves to `reconciling` and records the attempt), and then
    // `PersistedTypedProviderAction.materialize()` does not know the screen
    // sequence's kind, so the reconcile fails with nothing dispatched and the
    // record file as it was; the engine keeps the Job resident in
    // `reconciling`, which a run refuses, and a second reconcile fails the
    // same way without writing.
    try await recorder.submit("missingArchive", try sequence("missingArchive"))
    let missing = try await recorder.run(
      "missingArchive.run", job: "missingArchive", mode: "missingArchive")
    XCTAssertEqual(Self.state(missing), .string("waitingForRecovery"))
    try await recorder.start("secondRestart")
    let unknown = try await recorder.reconcile("reconcileMissingArchive", job: "missingArchive")
    XCTAssertEqual(Self.errorCode(unknown), .string("internalError"))
    let again = try await recorder.reconcile("reconcileMissingArchiveAgain", job: "missingArchive")
    XCTAssertEqual(Self.errorCode(again), .string("internalError"))
    let refused = try await recorder.run(
      "missingArchive.resume", job: "missingArchive", snapshot: false)
    XCTAssertEqual(Self.errorCode(refused), .string("resourceConflict"))
    try await recorder.reads(["receiveKilled", "missingArchive"])
    try await recorder.exchange("debt.list", "cleanupDebt.list", [:])
    try await recorder.capabilities()
    return try recorder.finish(producer: "screenSequence")
  }

  // MARK: - captureFileLegs

  /// The component tree leg of `capture.diagnostics@1`, answered as the file
  /// legs oracle answers it, plus the owned path's `ls -ld` readback, by mode:
  /// `uitest dumpLayout` dies on SIGKILL before (`treeKilledBefore`) or after
  /// (`treeKilledAfter`) it writes the tree, and `cleanupRefused` refuses the
  /// removal.
  private static let fileLegAnswers = #"""
    # capture.diagnostics@1 component tree answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
    /bin/mkdir -p "$root/device-tmp"
    umask 077
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
    "-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*)
      [ "$mode" = treeKilledBefore ] && kill -KILL $$
      printf '{"attributes":{"text":"Sign in","hint":"/private/tmp/arkdeck-hdc-oracle/home/Documents/draft.txt"},"children":[]}\n' > "$(device "$7")"
      [ "$mode" = treeKilledAfter ] && kill -KILL $$
      printf 'DumpLayout saved to:%s\n' "$7" ;;
    "-t $key shell ls -l /data/local/tmp/arkdeck-"*)
      if [ -f "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
      if [ -e "$(device "$6")" ]; then
        printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
          "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
      else
        printf 'ls: %s: No such file or directory\n' "$6"
      fi ;;
    "-t $key file recv /data/local/tmp/arkdeck-"*)
      /bin/cp "$(device "$5")" "$6"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell rm -f /data/local/tmp/arkdeck-"*)
      if [ "$mode" = cleanupRefused ]; then
        printf 'rm: %s: Read-only file system\n' "$6"
        exit 1
      fi
      /bin/rm -f "$(device "$6")" ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  private func captureFileLegs() async throws -> [String: Data] {
    let recorder = try Recorder(answers: Self.fileLegAnswers, receive: Self.receive)
    let target = recorder.adopted.targetID
    func tree(_ name: String) throws -> String {
      try Self.requestJSON(
        name, operation: "capture.diagnostics",
        inputs: [
          "durationSeconds": .integer(5), "captureHilog": .bool(false), "uiDump": .bool(false),
          "uiComponentTree": .bool(true),
        ], target: target)
    }
    // Killed before it writes the tree: the readback finds none.
    try await recorder.submit("treeKilledBefore", try tree("treeKilledBefore"))
    let before = try await recorder.run(
      "treeKilledBefore.run", job: "treeKilledBefore", mode: "treeKilledBefore")
    XCTAssertEqual(Self.state(before), .string("waitingForRecovery"))
    try await recorder.start("restart")
    let failed = try await recorder.reconcile("reconcileTreeKilledBefore", job: "treeKilledBefore")
    XCTAssertEqual(Self.state(failed), .string("failed"))
    // Killed once it wrote the tree: completed, and the Job receives and
    // cleans it up when resumed.
    try await recorder.submit("treeKilledAfter", try tree("treeKilledAfter"))
    let after = try await recorder.run(
      "treeKilledAfter.run", job: "treeKilledAfter", mode: "treeKilledAfter")
    XCTAssertEqual(Self.state(after), .string("waitingForRecovery"))
    try await recorder.start("secondRestart")
    let confirmed = try await recorder.reconcile("reconcileTreeKilledAfter", job: "treeKilledAfter")
    XCTAssertEqual(Self.state(confirmed), .string("resumeAtConfirmedSafeBoundary"))
    let resumed = try await recorder.run("treeKilledAfter.resume", job: "treeKilledAfter")
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    // A cleanup the device refuses owes a debt, continued once it answers.
    try await recorder.submit("cleanupRefused", try tree("cleanupRefused"))
    let refused = try await recorder.run(
      "cleanupRefused.run", job: "cleanupRefused", mode: "cleanupRefused")
    XCTAssertEqual(Self.state(refused), .string("succeeded"))
    let debts = try await recorder.exchange("debt.list", "cleanupDebt.list", [:])
    guard case .object(let listed) = debts, case .array(let items)? = listed["result"],
      items.count == 1,
      case .object(let debt) = items[0], case .string(let remotePath)? = debt["remotePath"]
    else {
      XCTFail("the refused cleanup owes no single debt: \(debts)")
      return [:]
    }
    try await recorder.exchange(
      "debt.continue", "cleanupDebt.continue",
      ["jobId": .string(recorder.jobs["cleanupRefused"]!), "remotePath": .string(remotePath)])
    try recorder.snapshot("debt.continue")
    try await recorder.exchange("debt.listAfter", "cleanupDebt.list", [:])
    try await recorder.reads(["treeKilledBefore", "treeKilledAfter", "cleanupRefused"])
    try await recorder.capabilities()
    return try recorder.finish(producer: "captureFileLegs")
  }

  // MARK: - tapBeforeConsume, tapAfterConsume

  private static let tap: [String: JSONValue] = [
    "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    "screenEpochUtc": .string("2026-09-14T00:00:00.000Z"),
    "x": .integer(640), "y": .integer(1500),
  ]

  /// What `input.tap@1` asks, answered as its own oracle answers it.
  private static let tapAnswers = #"""
    # input.tap@1 answers of the shared fake HDC.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key shell uinput "*)
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

  /// The daemon dies at the engine's hook before the tap's capability is
  /// consumed, or once the use and the Job's evidence are durable and before
  /// the gesture's intent: the whole root is copied there, the live run goes
  /// on to its end, and the copy then replaces the root. After a start the Job
  /// is still `running` with nothing outstanding, and `job.run` resumes it.
  private func tapRunning(afterConsume: Bool) async throws -> [String: Data] {
    let capture = CrashCapture()
    let hooks: RuntimeJobEngine.Configuration.TestHooks =
      afterConsume
      ? .init(beforeDispatchInstall: { _, step in
        if step == "inject-pointer-input" { capture.take() }
      })
      : .init(beforeMutationCapabilityCommit: { _ in capture.take() })
    let recorder = try Recorder(answers: Self.tapAnswers, testHooks: hooks)
    let target = recorder.adopted.targetID
    try await recorder.submit(
      "tap", try Self.requestJSON("tap", operation: "input.tap", inputs: Self.tap, target: target))
    // The live run goes on past the hook to its end; only the copy is kept.
    _ = try await recorder.send("job.run", ["jobId": .string(recorder.jobs["tap"]!)])
    let outcome = capture.outcome
    XCTAssertNil(outcome.failure)
    XCTAssertTrue(outcome.copied, "the hook never ran")
    let manager = FileManager.default
    try manager.removeItem(at: Self.settings.root)
    try manager.copyItem(at: Self.crash, to: Self.settings.root)
    try manager.removeItem(at: Self.crash)
    try HDCOracleFake.setMode("normal")
    try recorder.snapshot("crash")
    try await recorder.start("restart")
    let resumed = try await recorder.run("tap.resume", job: "tap")
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    let rerun = try await recorder.run("tap.rerun", job: "tap", snapshot: false)
    XCTAssertEqual(Self.errorCode(rerun), .string("resourceConflict"))
    try await recorder.submit(
      "next", try Self.requestJSON("next", operation: "input.tap", inputs: Self.tap, target: target))
    let next = try await recorder.run("next.run", job: "next")
    XCTAssertEqual(Self.state(next), .string("succeeded"))
    try await recorder.reads(["tap", "next"])
    try await recorder.capabilities()
    return try recorder.finish(
      producer: afterConsume ? "tapAfterConsume" : "tapBeforeConsume",
      extra: [
        "window": .string(
          afterConsume
            ? "RuntimeJobEngine test hook beforeDispatchInstall for inject-pointer-input"
            : "RuntimeJobEngine test hook beforeMutationCapabilityCommit")
      ])
  }
}
