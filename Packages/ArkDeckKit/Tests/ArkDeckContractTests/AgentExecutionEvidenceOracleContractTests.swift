// Shared Swift oracle for the evidence a completed agent execution answers
// with (CHG-2026-074, TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift agent executions whose completed answers carry evidence that the
/// published `agent.run`, `agent.status`, `agent.resume` and
/// `human-action.resume` results had never sampled, over the shared fake HDC
/// (`HDCOracleFake`) with the daemon's agent execution and human-action
/// owners, a registered workspace project's provider and the analyzer
/// provider composed beside it (`HDCOracleHarness`):
///
/// - the three pointer gestures of Golden Journey 2 on an adopted Target, as
///   `arkdeck agent run --operation <gesture> --target <TGT> --inputs-file
///   <file>` sends them, each admitted under the Runtime's standing
///   capability, whose authority names no Artifact (`artifactDigest` null);
/// - `workspace.prepare-isolated-copy@1` of the registered project, the
///   execution's target its project reference: host-only, so no binding
///   revision, stable identity or observation;
/// - a tap and a crash-signature analysis that name no target, so each waits
///   for a person to connect the device (`connectDevice`), is resumed once
///   the device is replugged, and is resumed again once complete, with
///   `agent.resume` and with `human-action.resume`: a resolved action answers
///   with its completed execution, the analysis's without a binding.
///
/// Each run's Job is held (a gesture at its injection, the copy at its
/// isolation, the analysis in its analyzer) until the oracle releases it, so
/// an answer read while the Job starts keeps the name of the Job state it
/// read, not its value. The oracle then waits for the execution's durable
/// completion, reads the execution and sends its intent again; an explicit
/// run is also read while it is held. Every Job's result, evidence and
/// Artifacts are read last. The identities the owners mint at random are
/// labelled (`HDCOracleHarness.RandomIdentities`), and each exchange names
/// the USB relations set before it, as the human-action oracle records them.
///
/// Record a new oracle with
/// `ARKDECK_RUST_AGENT_EXECUTION_EVIDENCE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class AgentExecutionEvidenceOracleContractTests: XCTestCase {
  private struct Run {
    let name: String
    let executionID: String
    let operation: String
    let inputs: [String: JSONValue]
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/agent-execution-evidence", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  /// The runbook's `--maximum-wait 5m`.
  private static let budget = "300000"
  /// What the oracle creates to release a held Job.
  private static let released = HDCOracleFake.root.appending(path: "released")
  /// The registered project's reference.
  private static let projectRef = "EvidenceOracleProject"
  /// The crash listing the assisted analysis reads.
  private static let source = Data(
    "Fault log list:\n******\ncppcrash-com.example.demo-20010039-20260914000000\n******\n".utf8)

  /// The frame every gesture is mapped against, as the pointer oracle maps
  /// them: the device's 1280x2832 screen, captured on the oracle's clock.
  private static let frame: [String: JSONValue] = [
    "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    "screenEpochUtc": .string("2026-09-14T00:00:00.000Z"),
  ]
  private static let tap = frame.merging(["x": .integer(640), "y": .integer(1500)]) { $1 }

  /// The three gestures on the adopted Target.
  private static let gestures: [Run] = [
    Run(name: "tap", executionID: "evidence-tap", operation: "input.tap@1", inputs: tap),
    Run(
      name: "longPress", executionID: "evidence-long-press", operation: "input.long-press@1",
      inputs: frame.merging([
        "x": .integer(12), "y": .integer(700), "durationMs": .integer(1200),
        "displayId": .integer(2),
      ]) { $1 }),
    Run(
      name: "swipe", executionID: "evidence-swipe", operation: "input.swipe@1",
      inputs: frame.merging([
        "fromX": .integer(100), "fromY": .integer(2200), "toX": .integer(100),
        "toY": .integer(1200), "durationMs": .integer(500),
      ]) { $1 }),
  ]

  /// The pointer oracle's device, before which the tool answers its version
  /// (as the capture oracle's does) for an adoption to verify, a `held`
  /// gesture waits at its injection until the oracle releases it, and an
  /// `offline` device list names the device offline.
  static let answers =
    #"""
    # The tool's version; a held gesture waits at its injection until the
    # oracle releases it; an offline device list names the device offline.
    case "$*" in
    "-v")
      printf 'Ver: 3.2.0d\n'
      exit 0 ;;
    *" shell uinput "*)
      if [ "$mode" = held ]; then
        while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ]; do /bin/sleep 0.01; done
      fi ;;
    "list targets -v")
      if [ "$mode" = offline ]; then
        printf '%s\t\tUSB\tOffline\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        exit 0
      fi ;;
    esac

    """# + PointerInputOracleContractTests.answers

  /// The oracle analyzer: it waits for the oracle's release, then prints
  /// Swift's analysis of the source.
  private static func analyzerBytes() throws -> Data {
    let analysis = String(
      decoding: try HarnessCrashLedgerDerivedAnalyzer.analyze(source), as: UTF8.self)
    let lines = [
      "#!/bin/sh",
      "# ArkDeck agent execution evidence oracle analyzer. It holds until the",
      "# oracle releases it, then answers with Swift's analysis of the source.",
      #"[ "$#" -eq 2 ] && [ "$1" = "--analyze-crash-ledger" ] || exit 64"#,
      "while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ] &&",
      #"  kill -0 "$PPID" 2>/dev/null; do"#,
      "  /bin/sleep 0.01",
      "done",
      "printf '%s' '" + analysis + "'",
    ]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  /// A workspace preset's executable, never run by the isolation: fixed
  /// bytes under the fixed root, so no identity of this host's tools enters
  /// the profile.
  private static let presetBytes = Data("#!/bin/sh\nexit 64\n".utf8)

  func testSwiftCompletesAgentExecutionsWithEveryEvidenceShape() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_AGENT_EXECUTION_EVIDENCE_RECORD",
      oracle: Self.oracle)
  }

  /// The workspace route, held before the Job's isolation until the oracle
  /// creates `released`, and telling the oracle when a Job reached it.
  private final class HeldIsolation: RuntimeProcessDispatching, @unchecked Sendable {
    private let base: any RuntimeProcessDispatching
    private let released: URL
    private let lock = NSLock()
    private var reached = false

    init(base: any RuntimeProcessDispatching, released: URL) {
      self.base = base
      self.released = released
    }

    var entered: Bool { lock.withLock { reached } }

    func unavailableReason(providerID: String) -> String? {
      base.unavailableReason(providerID: providerID)
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      lock.withLock { reached = true }
      while !FileManager.default.fileExists(atPath: released.path) {
        try await Task.sleep(for: .milliseconds(10))
      }
      return try await base.dispatch(plan)
    }
  }

  /// The independent USB observation, as the oracle plugs and replugs.
  private final class USBRelations: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [TargetUSBRelation] = []
    func set(_ value: [TargetUSBRelation]) { lock.withLock { current = value } }
    func read() -> [TargetUSBRelation] { lock.withLock { current } }
  }

  /// A DAYU200 in HDC-normal mode on one USB attachment.
  private static func relation(attachment: UInt64) -> TargetUSBRelation {
    TargetUSBRelation(
      serial: connectKey, location: "100", attachmentID: attachment,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID)
  }

  /// The relations as a replay sets its own USB observation to them.
  private static func recorded(_ relations: [TargetUSBRelation]) -> JSONValue {
    .array(
      relations.map {
        .object([
          "serial": .string($0.serial), "location": .string($0.location),
          "attachmentId": .integer(Int64($0.attachmentID)),
          "vendorId": .integer(Int64($0.vendorID)), "productId": .integer(Int64($0.productID)),
        ])
      })
  }

  /// The intent `arkdeck agent run --execution-id <id> --operation <op>
  /// [--target <TGT>] --inputs-file <file> --maximum-wait 5m` sends.
  private static func intent(
    _ run: Run, target: [String: JSONValue]?
  ) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(run.executionID), "operation": .string(run.operation),
      "inputs": .object(run.inputs), "maximumWaitMilliseconds": .string(budget),
    ]
    if let target { fields["target"] = .object(target) }
    return fields
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(
      handler, method, params, frameID: "agent-execution-evidence-oracle")
  }

  /// A member of an answer's result, by its path.
  private static func member(_ answer: JSONValue, _ path: String...) -> JSONValue? {
    var value = answer
    for key in ["result"] + path {
      guard case .object(let fields) = value, let next = fields[key] else { return nil }
      value = next
    }
    return value
  }

  private static func string(_ answer: JSONValue, _ path: String...) -> String? {
    var value = answer
    for key in ["result"] + path {
      guard case .object(let fields) = value, let next = fields[key] else { return nil }
      value = next
    }
    guard case .string(let text) = value else { return nil }
    return text
  }

  /// An answer read while its Job starts in the background reads any state
  /// before the held effect.
  private static func startIndependent(_ answer: JSONValue) -> JSONValue {
    guard case .object(var fields) = answer, case .object(var result)? = fields["result"] else {
      return answer
    }
    result["jobState"] = .string("<jobState>")
    if case .object(var job)? = result["job"] {
      job["state"] = .string("<jobState>")
      job["outcome"] = .string("<jobState>")
      result["job"] = .object(job)
    }
    fields["result"] = .object(result)
    return .object(fields)
  }

  /// How many injections the fake has been asked for.
  private static func injections() throws -> Int {
    String(decoding: try HDCOracleFake.invocations(), as: UTF8.self)
      .components(separatedBy: "\u{1F}uinput\u{1F}").count - 1
  }

  /// Waits until the held gesture's injection reached the fake, well inside
  /// the call's budget.
  private static func awaitInjection(after count: Int) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try injections() <= count {
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Waits until the held copy reached its isolation.
  private static func awaitIsolation(_ held: HeldIsolation) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !held.entered {
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Releases the held Job and waits until the execution's durable record
  /// says the Job it owns completed: the owner's last write for the run.
  private static func release(awaiting executionID: String, in directory: URL) async throws {
    try Data().write(to: released)
    let record = directory.appending(
      path: "execution-\(RuntimeAgentExecutionStore.fingerprint(Data(executionID.utf8))).json")
    let deadline = Date().addingTimeInterval(60)
    while true {
      if let data = try? Data(contentsOf: record),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["state"] as? String == "completed"
      {
        return
      }
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let root = Self.settings.root
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: root) }
    let analyzerBytes = try Self.analyzerBytes()
    let analyzer = root.appending(path: "analyzer")
    try analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let targets = root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record

    // The registered project: two sources, the profile pinning its root by
    // path, and presets the isolation never runs.
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: source.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appending(path: "Sources/App.txt"))
    try Data("outside the narrowed scope\n".utf8).write(
      to: source.appending(path: "Sources/Other.txt"))
    let tools = root.appending(path: "workspace-tools", directoryHint: .isDirectory)
    try manager.createDirectory(at: tools, withIntermediateDirectories: false)
    let preset = { (id: String) throws -> WorkspaceCommandPreset in
      let executable = tools.appending(path: id)
      try Self.presetBytes.write(to: executable)
      guard chmod(executable.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
      return try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: executable.path),
        fixedArguments: [], timeoutSeconds: 10)
    }
    let profile = try WorkspaceProjectProfile(
      profileID: "agent-execution-evidence-oracle@1", projectRef: Self.projectRef,
      projectRoot: source.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: try preset("inspect"), patchPreset: try preset("patch"),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let evolution = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: registry)
    let workspace = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory)),
      isolationManager: evolution, nowUTC: { Self.settings.nowUTC })
    let isolation = HeldIsolation(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: WorkspaceActionExecutableResolver(profile: profile)),
        manager: evolution),
      released: Self.released)
    let revision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)

    let usb = USBRelations()
    let analyzerProfile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path, executableSHA256: AnalyzerProvider.sha256(analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30)
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      agentExecutions: true, humanActions: true, usbRelations: { usb.read() },
      analyzers: [analyzerProfile], workspace: (workspace, isolation))
    guard let executions = composition.agentExecutions else {
      throw CocoaError(.featureUnsupported)
    }
    let handler = composition.handler
    let identities = HDCOracleHarness.RandomIdentities()
    // The crash listing, collected from the adopted Target.
    let collected = try await composition.artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-oracle-source", sessionID: "HTASK-AGENTEVIDENCE",
        stepID: "capture-crash-index", name: "crash-index.txt", mediaType: "text/plain",
        privacy: .standard, retentionClass: .default,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: adopted.targetID, bindingRevision: adopted.bindingRevision,
          stableIdentitySHA256: adopted.stablePhysicalIdentitySHA256),
        contents: Self.source))
    let lease = try await composition.artifactStore.leaseReference(
      jobID: collected.jobID, artifactID: collected.artifactID)

    var exchanges: [JSONValue] = []
    var plugged: JSONValue?
    /// The USB relations the next exchange runs under.
    func plug(_ relations: [TargetUSBRelation]) {
      usb.set(relations)
      plugged = Self.recorded(relations)
    }
    /// One exchange: the fake's mode set first when it names one, the
    /// request sent, and both recorded with their random identities
    /// labelled. `before` names what a replay does first: `heldCall` waits
    /// for the held gesture's injection, `heldIsolation` for the held copy's
    /// isolation, `release` releases the held Job and waits for the
    /// execution's durable completion.
    func exchange(
      _ name: String, _ method: String, _ params: [String: JSONValue], mode: String? = nil,
      before: String? = nil, independent: (JSONValue) -> JSONValue = { $0 }
    ) async throws -> JSONValue {
      if let mode { try HDCOracleFake.setMode(mode) }
      let answer = try await Self.send(handler, method, params)
      guard case .object(let sent) = try identities.label(.object(params)) else {
        throw CocoaError(.coderInvalidValue)
      }
      var entry = HDCOracleHarness.exchange(
        name, method, sent, try identities.label(independent(answer)), mode: mode)
      if case .object(var fields) = entry {
        if let before { fields["before"] = .string(before) }
        if let relations = plugged { fields["usbRelations"] = relations }
        entry = .object(fields)
      }
      plugged = nil
      exchanges.append(entry)
      return answer
    }
    var jobs: [(name: String, job: String)] = []
    var executed: [(name: String, execution: String)] = []

    // The gestures on the adopted Target, and the copy of the project.
    let isolate = Run(
      name: "isolate", executionID: "evidence-isolate",
      operation: "workspace.prepare-isolated-copy@1",
      inputs: [
        "projectRef": .string(Self.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(revision),
      ])
    let target: [String: JSONValue] = ["targetId": .string(adopted.targetID)]
    for run in Self.gestures + [isolate] {
      let gesture = run.name != isolate.name
      let intent = Self.intent(run, target: gesture ? target : nil)
      let identity: [String: JSONValue] = ["executionId": .string(run.executionID)]
      try? manager.removeItem(at: Self.released)
      let calls = try Self.injections()
      let accepted = try await exchange(
        "\(run.name).run", "agent.run", intent, mode: "held", independent: Self.startIndependent)
      XCTAssertEqual(Self.string(accepted, "state"), "jobOwned", run.name)
      let job = try XCTUnwrap(Self.string(accepted, "jobId"), run.name)
      XCTAssertEqual(
        JobState(rawValue: try XCTUnwrap(Self.string(accepted, "jobState")))?.isTerminal, false,
        run.name)
      jobs.append((run.name, job))
      executed.append((run.name, run.executionID))
      if gesture {
        try await Self.awaitInjection(after: calls)
      } else {
        try await Self.awaitIsolation(isolation)
      }
      let running = try await exchange(
        "\(run.name).running", "agent.status", identity,
        before: gesture ? "heldCall" : "heldIsolation")
      XCTAssertEqual(Self.string(running, "state"), "jobOwned", run.name)
      try await Self.release(awaiting: run.executionID, in: executions.directory)
      let completed = try await exchange(
        "\(run.name).status", "agent.status", identity, before: "release")
      XCTAssertEqual(Self.string(completed, "state"), "completed", run.name)
      XCTAssertEqual(Self.string(completed, "jobState"), "succeeded", run.name)
      XCTAssertEqual(Self.string(completed, "evidence", "status"), "verified", run.name)
      if gesture {
        XCTAssertEqual(
          Self.string(completed, "evidence", "authority", "kind"), "runtimeCapability", run.name)
        XCTAssertEqual(
          Self.member(completed, "evidence", "authority", "artifactDigest"), .null, run.name)
      } else {
        XCTAssertEqual(Self.string(completed, "targetId"), Self.projectRef)
        XCTAssertEqual(Self.member(completed, "bindingRevision"), .null)
        XCTAssertEqual(Self.member(completed, "evidence", "observation"), .null)
      }
      _ = try await exchange("\(run.name).rerun", "agent.run", intent)
    }

    // A tap and an analysis that name no target: each waits for the device
    // to be connected, is resumed once it is, and is resumed again, both
    // ways, once complete.
    let assisted = [
      (
        Run(
          name: "assistedTap", executionID: "evidence-assisted-tap", operation: "input.tap@1",
          inputs: Self.tap),
        "held", UInt64(18)
      ),
      (
        Run(
          name: "assistedAnalysis", executionID: "evidence-assisted-analysis",
          operation: "analyzer.extract-crash-signature@1",
          inputs: ["sourceArtifactRef": .string(lease)]),
        "normal", UInt64(19)
      ),
    ]
    for (run, mode, attachment) in assisted {
      let intent = Self.intent(run, target: nil)
      let identity: [String: JSONValue] = ["executionId": .string(run.executionID)]
      plug([])
      let waiting = try await exchange("\(run.name).run", "agent.run", intent, mode: "offline")
      XCTAssertEqual(Self.string(waiting, "state"), "waitingForHuman", run.name)
      XCTAssertEqual(
        Self.string(waiting, "humanAction", "category"), "physicalConnection", run.name)
      let action = try XCTUnwrap(Self.string(waiting, "humanAction", "actionId"), run.name)
      let reference = try XCTUnwrap(
        Self.string(waiting, "humanAction", "resumeReference"), run.name)
      // Replugged: a new USB attachment, the device connected.
      try? manager.removeItem(at: Self.released)
      plug([Self.relation(attachment: attachment)])
      let resumed = try await exchange(
        "\(run.name).resume", "agent.resume", ["resumeReference": .string(reference)],
        mode: mode, independent: Self.startIndependent)
      XCTAssertEqual(Self.string(resumed, "state"), "jobOwned", run.name)
      jobs.append((run.name, try XCTUnwrap(Self.string(resumed, "jobId"), run.name)))
      executed.append((run.name, run.executionID))
      try await Self.release(awaiting: run.executionID, in: executions.directory)
      let completed = try await exchange(
        "\(run.name).status", "agent.status", identity, before: "release")
      XCTAssertEqual(Self.string(completed, "state"), "completed", run.name)
      XCTAssertEqual(Self.string(completed, "jobState"), "succeeded", run.name)
      XCTAssertEqual(Self.string(completed, "targetId"), adopted.targetID, run.name)
      let again = try await exchange(
        "\(run.name).again", "agent.resume", ["resumeReference": .string(reference)])
      XCTAssertEqual(Self.string(again, "state"), "completed", run.name)
      XCTAssertEqual(Self.string(again, "evidence", "status"), "verified", run.name)
      let byAction = try await exchange(
        "\(run.name).againByAction", "human-action.resume",
        ["resumeReference": .string(reference), "humanAction": .string(action)])
      XCTAssertEqual(Self.string(byAction, "state"), "completed", run.name)
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
        _ = try await exchange("\(name).\(read)", method, params)
      }
    }

    var files = try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "projectRef": .string(Self.projectRef),
        "workspaceRevision": .string(revision),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "executions": .object(
          Dictionary(
            uniqueKeysWithValues: executed.map { ($0.name, JSONValue.string($0.execution)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "AgentExecutionEvidenceOracleContractTests.testSwiftCompletesAgentExecutionsWithEveryEvidenceShape",
      settings: Self.settings, identities: identities)
    files["analyzer"] = analyzerBytes
    return files
  }
}
