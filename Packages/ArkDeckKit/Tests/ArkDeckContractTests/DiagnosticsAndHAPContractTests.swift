import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// T12 + T13: capture.diagnostics@1 partial-success honesty and
/// debug.hap@1 readback-only success judgement.
final class DiagnosticsAndHAPContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-mu4-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct TraceProbe: TraceRuntimeProbing {
    func probeTraceRuntime(targetID: String) async throws -> TraceRuntimeProbeSnapshot {
      TraceRuntimeProbeSnapshot(
        targetID: targetID,
        bindingRevision: 7,
        adapterDisposition: "captureEligible",
        tool: "hitrace",
        family: "hitrace-openharmony",
        supportedTags: ["ohos"],
        rawHelp: nil,
        rawHelpSHA256: nil,
        tools: [],
        parameters: TraceDebugParameterCatalog.definitions.map {
          TraceRuntimeParameterObservation(
            name: $0.name, state: .value, value: "false")
        })
    }
  }

  private actor TraceRouteRunner: RockchipRuntimeCommandRunning {
    private var seenArguments: [[String]] = []

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      seenArguments.append(arguments)
      return ProviderSubprocessReceipt(
        exitStatus: 0,
        stdout: Data("[Fail] fixture remains unsupported\n".utf8),
        stderr: Data(), stdoutTruncated: false, durationSeconds: 0.001)
    }

    func arguments() -> [[String]] { seenArguments }
  }

  private actor DebugRouteRunner: RockchipRuntimeCommandRunning {
    private let connectKey: String
    private var seenArguments: [[String]] = []

    init(connectKey: String) {
      self.connectKey = connectKey
    }

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      seenArguments.append(arguments)
      guard Array(arguments.prefix(2)) == ["-t", connectKey] else {
        return receipt("[Fail] target not found\n")
      }
      switch Array(arguments.dropFirst(2)) {
      case ["shell", "bm", "dump", "-a"]:
        return receipt("com.example.alpha\ncom.example.beta\n")
      case ["fport", "ls"]:
        return receipt("tcp:9000 tcp:9001\n")
      case ["rport", "ls"]:
        return receipt("tcp:9100 tcp:9101\n")
      case ["shell", "uptime"]:
        return receipt("up 1 day\n")
      default:
        return receipt("[Fail] unsupported fixture command\n")
      }
    }

    func arguments() -> [[String]] { seenArguments }

    private func receipt(_ stdout: String) -> ProviderSubprocessReceipt {
      ProviderSubprocessReceipt(
        exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.001)
    }
  }

  private actor TraceParameterRunner: RockchipRuntimeCommandRunning {
    private let parameterReceipts: [String: ProviderSubprocessReceipt]

    init(parameterReceipts: [String: ProviderSubprocessReceipt]) {
      self.parameterReceipts = parameterReceipts
    }

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      let command = Array(arguments.suffix(4))
      if command.count == 4, Array(command.prefix(3)) == ["shell", "param", "get"],
        let receipt = parameterReceipts[command[3]]
      {
        return receipt
      }
      return ProviderSubprocessReceipt(
        exitStatus: 0,
        stdout: Data("[Fail] fixture remains unsupported\n".utf8),
        stderr: Data(), stdoutTruncated: false, durationSeconds: 0.001)
    }
  }

  /// A re-entrant fake HDC runner. Sleeping after admission leaves the actor
  /// available to record another call, so `maximumActiveCount` proves whether
  /// the production probe submitted independent reads concurrently without
  /// relying on wall-clock assertions.
  private actor ConcurrentReadRunner: RockchipRuntimeCommandRunning {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var seenArguments: [[String]] = []

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      activeCount += 1
      maximumActiveCount = max(maximumActiveCount, activeCount)
      seenArguments.append(arguments)
      try await Task.sleep(for: .milliseconds(40))
      activeCount -= 1

      let command = Array(arguments.dropFirst(2))
      let stdout: String
      if command.count == 4, Array(command.prefix(3)) == ["shell", "param", "get"] {
        stdout = "Get parameter \"\(command[3])\" fail! errNum is:106!\n"
      } else if command == ["shell", "bm", "dump", "-a"] {
        stdout = "com.example.alpha\ncom.example.beta\n"
      } else if command == ["fport", "ls"] {
        stdout = "tcp:9000 tcp:9001\n"
      } else if command == ["rport", "ls"] {
        stdout = "tcp:9100 tcp:9101\n"
      } else {
        stdout = "[Fail] fixture remains unsupported\n"
      }
      return ProviderSubprocessReceipt(
        exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.04)
    }

    func maximumConcurrency() -> Int { maximumActiveCount }
    func arguments() -> [[String]] { seenArguments }
  }

  private func makeTraceProbe(
    runner: any RockchipRuntimeCommandRunning
  ) throws -> (probe: FoundationTraceRuntimeProbe, targetID: String) {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600", toolVersion: "3.2.0f",
      nowUTC: "2026-08-11T00:00:00Z"
    ).record
    return (
      FoundationTraceRuntimeProbe(
        targetStore: targetStore,
        hdcResolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc"),
        runner: runner),
      adopted.targetID
    )
  }

  func testTraceProbeUsesTheProvenAliasExecutionRoute() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let originalIdentity = String(repeating: "a", count: 64)
    let loaderIdentity = String(repeating: "b", count: 64)
    let aliasConnectKey = "post-flash-hdc-address"
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(serial: aliasConnectKey)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: originalIdentity, connectKey: "stale-canonical-address",
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let canonical = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: originalIdentity, previousRevision: 1,
        currentStableIdentitySHA256: loaderIdentity, currentRevision: 2)
    ).record
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:01:00Z"
    ).record
    XCTAssertNotEqual(alias.targetID, adopted.targetID)
    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: canonical.targetID,
        canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: canonical.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity,
        routedUSBTopology: "18874368",
        establishingFlashJobID: "job-0123456789abcdef0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "c", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [
          RuntimeTargetAliasCoveredIntent(
            jobID: "job-unknown", intentEventID: "intent-enter-loader",
            stepID: "enter-loader-mode", effect: "deviceMutation")
        ],
        establishedAtUTC: "2026-08-08T00:10:00Z"))

    let runner = TraceRouteRunner()
    let probe = FoundationTraceRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc"),
      runner: runner)
    let snapshot = try await probe.probeTraceRuntime(targetID: canonical.targetID)

    XCTAssertEqual(snapshot.targetID, canonical.targetID)
    XCTAssertEqual(snapshot.bindingRevision, canonical.bindingRevision)
    XCTAssertEqual(snapshot.adapterDisposition, "unsupported")
    let calls = await runner.arguments()
    XCTAssertEqual(calls.count, 2 + TraceDebugParameterCatalog.definitions.count)
    XCTAssertTrue(calls.allSatisfy { Array($0.prefix(2)) == ["-t", aliasConnectKey] })
    XCTAssertFalse(calls.joined().contains("stale-canonical-address"))
  }

  func testDebugProbeAndTemplatesUseTheProvenAliasExecutionRoute() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let originalIdentity = String(repeating: "a", count: 64)
    let loaderIdentity = String(repeating: "b", count: 64)
    let aliasConnectKey = "post-flash-hdc-address"
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(serial: aliasConnectKey)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: originalIdentity, connectKey: "stale-canonical-address",
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let canonical = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: originalIdentity, previousRevision: 1,
        currentStableIdentitySHA256: loaderIdentity, currentRevision: 2)
    ).record
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:01:00Z"
    ).record
    XCTAssertEqual(adopted.targetID, canonical.targetID)
    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: canonical.targetID,
        canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: canonical.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity,
        routedUSBTopology: "18874368",
        establishingFlashJobID: "job-0123456789abcdef0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "c", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [], establishedAtUTC: "2026-08-08T00:10:00Z"))

    let runner = DebugRouteRunner(connectKey: aliasConnectKey)
    let probe = FoundationDebugRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc"),
      runner: runner)

    let snapshot = try await probe.probeDebugRuntime(targetID: canonical.targetID)
    XCTAssertEqual(snapshot.targetID, canonical.targetID)
    XCTAssertEqual(snapshot.bindingRevision, canonical.bindingRevision)
    XCTAssertEqual(snapshot.packages, ["com.example.alpha", "com.example.beta"])
    XCTAssertEqual(snapshot.portRules.count, 2)
    XCTAssertEqual(snapshot.warnings, [])

    let template = try await probe.runDebugTemplate(
      targetID: canonical.targetID, template: .uptime)
    XCTAssertEqual(template.targetID, canonical.targetID)
    XCTAssertEqual(template.bindingRevision, canonical.bindingRevision)
    XCTAssertEqual(template.stdout, "up 1 day\n")
    XCTAssertEqual(
      template.argumentDisclosure,
      ["-t", "<redacted-connect-key>", "shell", "uptime"])

    let calls = await runner.arguments()
    XCTAssertEqual(calls.count, 4)
    XCTAssertTrue(calls.allSatisfy { Array($0.prefix(2)) == ["-t", aliasConnectKey] })
    XCTAssertFalse(calls.joined().contains("stale-canonical-address"))
  }

  func testTraceProbeClassifiesExactOpenHarmonyMissingParameterReceipts() async throws {
    let receipts = Dictionary(
      uniqueKeysWithValues: TraceDebugParameterCatalog.definitions.map { definition in
        (
          definition.name,
          ProviderSubprocessReceipt(
            exitStatus: 0,
            stdout: Data(
              "Get parameter \"\(definition.name)\" fail! errNum is:106!\n".utf8),
            stderr: Data(), stdoutTruncated: false, durationSeconds: 0.001)
        )
      })
    let runner = TraceParameterRunner(parameterReceipts: receipts)
    let fixture = try makeTraceProbe(runner: runner)

    let snapshot = try await fixture.probe.probeTraceRuntime(targetID: fixture.targetID)

    XCTAssertEqual(
      snapshot.parameters.map(\.name), TraceDebugParameterCatalog.definitions.map(\.name))
    XCTAssertTrue(snapshot.parameters.allSatisfy { $0.state == .missing })
    XCTAssertTrue(snapshot.parameters.allSatisfy { $0.value == nil && $0.detail == nil })
  }

  func testTraceProbeOverlapsIndependentReadsAndPreservesCatalogOrder() async throws {
    let runner = ConcurrentReadRunner()
    let fixture = try makeTraceProbe(runner: runner)

    let snapshot = try await fixture.probe.probeTraceRuntime(targetID: fixture.targetID)
    let maximumConcurrency = await runner.maximumConcurrency()
    let callCount = await runner.arguments().count

    XCTAssertGreaterThan(
      maximumConcurrency, 1,
      "independent read-only HDC probes must overlap instead of forming a serial chain")
    XCTAssertEqual(
      snapshot.tools.map(\.tool),
      [TraceProbeTool.hitrace.rawValue, TraceProbeTool.bytrace.rawValue])
    XCTAssertEqual(
      snapshot.parameters.map(\.name), TraceDebugParameterCatalog.definitions.map(\.name),
      "concurrent completion must not reorder the catalog projection")
    XCTAssertTrue(snapshot.parameters.allSatisfy { $0.state == .missing })
    XCTAssertEqual(
      callCount,
      2 + TraceDebugParameterCatalog.definitions.count)
  }

  func testDebugProbeOverlapsIndependentReadsAndPreservesPresentationOrder() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "debug-concurrency", directoryHint: .isDirectory)
    )
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600", toolVersion: "3.2.0f",
      nowUTC: "2026-08-12T00:00:00Z"
    ).record
    let runner = ConcurrentReadRunner()
    let probe = FoundationDebugRuntimeProbe(
      targetStore: targetStore,
      hdcResolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc"),
      runner: runner)

    let snapshot = try await probe.probeDebugRuntime(targetID: adopted.targetID)
    let maximumConcurrency = await runner.maximumConcurrency()
    let callCount = await runner.arguments().count

    XCTAssertEqual(
      maximumConcurrency, 3,
      "package, forward and reverse inventories must run concurrently")
    XCTAssertEqual(snapshot.packages, ["com.example.alpha", "com.example.beta"])
    XCTAssertEqual(snapshot.portRules.map(\.direction), [.forward, .reverse])
    XCTAssertEqual(snapshot.warnings, [])
    XCTAssertEqual(callCount, 3)
  }

  func testTraceProbeKeepsNonExactMissingParameterFailuresUnreadable() async throws {
    let definitions = TraceDebugParameterCatalog.definitions
    func receipt(
      _ stdout: String,
      stderr: String = "",
      exitStatus: Int32? = 0,
      truncated: Bool = false
    ) -> ProviderSubprocessReceipt {
      ProviderSubprocessReceipt(
        exitStatus: exitStatus, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
        stdoutTruncated: truncated, durationSeconds: 0.001)
    }
    let receipts: [String: ProviderSubprocessReceipt] = [
      definitions[0].name: receipt(
        "Get parameter \"\(definitions[0].name)\" fail! errNum is:106!\n"),
      definitions[1].name: receipt(
        "Get parameter \"another.parameter\" fail! errNum is:106!\n"),
      definitions[2].name: receipt(
        "Get parameter \"\(definitions[2].name)\" fail! errNum is:105!\n"),
      definitions[3].name: receipt(
        "Get parameter \"\(definitions[3].name)\" fail! errNum is:106!\n",
        stderr: "unexpected stderr\n"),
      definitions[4].name: receipt(
        "Get parameter \"\(definitions[4].name)\" fail! errNum is:106!\nextra output\n"),
      definitions[5].name: receipt(
        "Get parameter \"\(definitions[5].name)\" fail! errNum is:106!\n",
        truncated: true),
      definitions[6].name: receipt("false\n"),
      definitions[7].name: receipt("\(definitions[7].name) = 1\n"),
      definitions[8].name: receipt("", exitStatus: 1),
    ]
    let runner = TraceParameterRunner(parameterReceipts: receipts)
    let fixture = try makeTraceProbe(runner: runner)

    let snapshot = try await fixture.probe.probeTraceRuntime(targetID: fixture.targetID)
    let byName = Dictionary(uniqueKeysWithValues: snapshot.parameters.map { ($0.name, $0) })

    XCTAssertEqual(byName[definitions[0].name]?.state, .missing)
    for definition in definitions[1...5] {
      XCTAssertEqual(byName[definition.name]?.state, .unreadable)
    }
    XCTAssertEqual(byName[definitions[6].name]?.state, .value)
    XCTAssertEqual(byName[definitions[6].name]?.value, "false")
    XCTAssertEqual(byName[definitions[7].name]?.state, .value)
    XCTAssertEqual(byName[definitions[7].name]?.value, "1")
    XCTAssertEqual(byName[definitions[8].name]?.state, .unreadable)
  }

  /// Scriptable dispatcher: each action family can be told to succeed, to
  /// fail, or - the case that matters most - to exit cleanly while the
  /// readback shows nothing happened.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    struct Script: Sendable {
      var packageInstalled = true
      var processRunning = true
      var hilogEmpty = false
      var sendOutcomeUnknown = false
      var availableStorageKB = 1_047_552
      var installExit: Int32 = 0
      var startExit: Int32 = 0
      var hilogPayloadBytes: Int?
      var hilogPayload: Data?
      var packageReadbackText: String?
      var processReadbackText: String?
      var processReadbackExit: Int32 = 0
      var ownedPathPresent = true
      var portForwardPresent = false
      var cleanupExit: Int32 = 0
      var cleanupOutcomeUnknown = false
      /// Bytes the simulated `file recv` leaves on the host. `nil` models
      /// the version whose transfer lands nowhere the caller named.
      var receivedTracePayload: Data? = Data("trace-bytes".utf8)
      /// The `ls -l` line the device answers for the captured trace. `nil`
      /// uses a written 4096-byte file; the string form models an empty
      /// capture or an absent path.
      var traceListing: String?
      /// hitrace's own exit status, which the verdict must ignore.
      var traceExit: Int32 = 0
      /// Whether the staged package directory survives its cleanup.
      var stagedDirectoryRemains = false
      /// What the Faultlogger index answers. `nil` = the measured empty form.
      var crashIndexText: String?
      /// What a single-entry fetch answers. `nil` = a well-formed entry.
      var crashLogText: String?
      /// The `ls -l` line the device answers for the component tree file.
      var uiTreeListing: String?
      /// The `ls -l` line for the screenshot file.
      var screenshotListing: String?
      /// Bytes the simulated `file recv` leaves for the screenshot leg.
      /// Defaults to a real PNG header so the magic gate sees a valid file.
      var screenshotPayload: Data? =
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + Data("fake-png-body".utf8)
      /// Bytes the simulated `file recv` leaves for the component tree leg.
      var uiTreePayload: Data? = Data(
        #"{"attributes":{"text":"hello"},"children":[]}"#.utf8)
      /// Stop/uninstall are judged by their readback, so the fixture models
      /// the device state after the mutation rather than its exit status.
      var processRunningAfterStop = false
      var packageInstalledAfterUninstall = false
      var stopProbeText: String?
      var uninstallProbeText: String?
      /// `aa force-stop`'s own exit status, which the verdict must ignore.
      var stopExit: Int32 = 0
      var targetRows = "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
      var modelValue = "DAYU200\n"
      var firmwareValue = "OpenHarmony-4.1-release\n"
    }

    let script: Script
    private let lock = NSLock()
    private(set) var dispatchedActions: [String] = []

    init(script: Script = Script()) {
      self.script = script
    }

    private func note(_ label: String) {
      lock.withLock { dispatchedActions.append(label) }
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      func receipt(_ stdout: String, exit: Int32 = 0) -> ProviderProcessReceipt {
        ProviderProcessReceipt(
          exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
      guard case .hdc(let action) = plan.action else {
        throw RuntimeDispatchFailure.failed("unexpected provider")
      }
      switch action {
      case .observeTool:
        note("observeTool")
        return receipt("Ver: 3.2.0f\n")
      case .observeServer:
        note("observeServer")
        return receipt("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n")
      case .observeDevice, .listDeviceCandidates:
        note("observeDevice")
        return receipt(script.targetRows)
      case .observeStorage:
        note("observeStorage")
        return receipt(
          "Filesystem 1K-blocks Used Available Use% Mounted on\n"
            + "/dev/block/data 1048576 1024 \(script.availableStorageKB) 1% /data\n")
      case .captureHilog:
        note("captureHilog")
        if let payload = script.hilogPayload {
          return ProviderProcessReceipt(
            exitStatus: 0, stdout: payload, stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        if let bytes = script.hilogPayloadBytes {
          return receipt(String(repeating: "I", count: bytes))
        }
        return receipt(script.hilogEmpty ? "" : "01-01 00:00:00 I app: hello\n")
      case .captureCrashIndex:
        note("captureCrashIndex")
        // The device's own words, both shapes measured 2026-07-31.
        return receipt(
          script.crashIndexText
            ?? "\nFault log list:\n******\n******\nNo fault log exist.\n")
      case .captureCrashLog(let name, _):
        note("captureCrashLog")
        return receipt(
          script.crashLogText
            ?? """
            Generated by HiviewDFX@OpenHarmony
            ================================================================
            Device info:OpenHarmony 3.2
            Module name:com.example.demo
            Process name:\(name.value)

            """)
      case .captureUIDump:
        note("captureUIDump")
        return receipt("{\"windows\":[]}\n")
      case .captureScreenshot:
        note("captureScreenshot")
        func shotSub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        let shotListing =
          script.screenshotListing
          ?? "-rw-r--r-- 1 root root 449830 2026-07-31 00:00 /data/local/tmp/shot.png\n"
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("process: display 0, file type: png, width: 720, height: 1280\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.02,
          subprocesses: [shotSub(""), shotSub(shotListing)])
      case .captureComponentTree:
        note("captureComponentTree")
        // Same shape as the trace leg: a status line plus the `ls -l`
        // readback that actually decides the verdict.
        func treeSub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        let treeListing =
          script.uiTreeListing
          ?? "-rw-r--r-- 1 root root 26143 2026-07-31 00:00 /data/local/tmp/tree.json\n"
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("DumpLayout saved to:/data/local/tmp/tree.json\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.02,
          subprocesses: [treeSub(""), treeSub(treeListing)])
      case .captureTrace:
        note("captureTrace")
        // hitrace, then the `ls -l` readback that actually decides the
        // verdict. The listing is what a device answers for a written
        // trace; the capture's own exit status is deliberately useless.
        func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        let listing =
          script.traceListing
          ?? "-rw-r--r-- 1 root root 4096 2026-07-31 00:00 /data/local/tmp/trace.htrace\n"
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.02,
          subprocesses: [sub("", exit: script.traceExit), sub(listing)])
      case .receiveOwnedArtifact:
        note("receiveArtifact")
        // Simulates the real leg rather than its verdict: hdc writes the
        // file and prints a progress line, so the fixture writes bytes and
        // lets the same `inspectLanded()` the production dispatcher calls
        // measure them. A test cannot assert a size or hash the bytes on
        // disk do not have.
        guard let landing = plan.hostLanding else {
          throw RuntimeDispatchFailure.failed(
            "receive plan carried no host landing declaration")
        }
        try? landing.prepareDestination()
        let payload: Data?
        switch landing.destination.pathExtension {
        case "json": payload = script.uiTreePayload
        case "png": payload = script.screenshotPayload
        default: payload = script.receivedTracePayload
        }
        if let payload {
          try? payload.write(to: landing.destination)
        }
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("FileTransfer finish\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01,
          landedArtifact: landing.inspectLanded())
      case .cleanupOwnedRemotePath:
        note("cleanup")
        if script.cleanupOutcomeUnknown {
          throw RuntimeDispatchFailure.outcomeUnknown("cleanup completion is unobservable")
        }
        return receipt("", exit: script.cleanupExit)
      case .sendPackageSetToStaging(let set):
        note("sendPackageSet")
        func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.05,
          subprocesses: [sub("")] + set.packages.map { _ in sub("FileTransfer finish") })
      case .installPackageSet:
        note("installPackageSet")
        return receipt("install bundle successfully.", exit: script.installExit)
      case .cleanupStagedPackageSet(let set):
        note("cleanupPackageSet")
        func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        // Exactly the two shapes `pathPresence` reads: an `ls -ld` line, or
        // the single-line absence message. `hdc shell` returns exit 0 either
        // way, which is why neither shape may depend on the status.
        let listing =
          script.stagedDirectoryRemains
          ? sub("drwxr-xr-x 2 shell shell 3452 2026-07-31 00:00 \(set.directory.remotePath)\n")
          : sub("ls: \(set.directory.remotePath): No such file or directory\n")
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.05,
          subprocesses: set.packages.map { _ in sub("") } + [sub(""), listing])
      case .readOwnedDirectoryPresence(let directory):
        note("reconcileDirectoryPresence")
        return script.stagedDirectoryRemains
          ? receipt("drwxr-xr-x 2 shell shell 3452 2026-07-31 00:00 \(directory.remotePath)\n")
          : receipt("ls: \(directory.remotePath): No such file or directory\n")
      case .sendArtifactToStaging:
        note("sendArtifact")
        if script.sendOutcomeUnknown {
          throw RuntimeDispatchFailure.outcomeUnknown("send completion is unobservable")
        }
        return receipt("FileTransfer finish")
      case .installPackage:
        note("installPackage")
        // Clean exit either way: the readback is what decides.
        return receipt("install bundle successfully.", exit: script.installExit)
      case .queryPackageReadback(let bundle):
        note("packageReadback")
        return receipt(
          script.packageReadbackText
            ?? (script.packageInstalled ? "bundleName: \(bundle.bundleName)\n" : ""))
      case .startAbility:
        note("startAbility")
        return receipt("start ability successfully", exit: script.startExit)
      case .verifyProcessState:
        note("processReadback")
        return receipt(
          script.processReadbackText ?? (script.processRunning ? "3421\n" : ""))
      case .observeApplicationLiveness:
        note("applicationLivenessReadback")
        return receipt(
          script.processReadbackText ?? (script.processRunning ? "3421\n" : ""),
          exit: script.processReadbackExit)
      case .stopAbility(let ability):
        note("stopAbility")
        // force-stop, then the `pidof` readback that decides the verdict.
        // `pidof` answers exit 1 with no output for a name it cannot find.
        func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        let stopProbe =
          script.stopProbeText.map { sub($0) }
          ?? (script.processRunningAfterStop
            ? sub("3421\n") : sub("", exit: 1))
        return ProviderProcessReceipt(
          exitStatus: stopProbe.exitStatus, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.02,
          subprocesses: [
            sub("force-stop \(ability.bundle.bundleName)", exit: script.stopExit), stopProbe,
          ])
      case .uninstallPackage(let bundle):
        note("uninstallPackage")
        func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
          ProviderSubprocessReceipt(
            exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        let dump =
          script.uninstallProbeText
          ?? (script.packageInstalledAfterUninstall
            ? "bundleName: \(bundle.bundleName)\n" : "")
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.02,
          subprocesses: [sub("uninstall bundle successfully"), sub(dump)])
      case .queryProperty(.productName):
        note("evidenceModel")
        return receipt(script.modelValue)
      case .queryProperty(.fullBuildVersion):
        note("evidenceFirmware")
        return receipt(script.firmwareValue)
      case .queryProperty:
        note("queryProperty")
        return receipt("provider-property\n")
      case .createPortForward, .removePortForward:
        note("portForward")
        return receipt("")
      case .readPackagePresence(let bundle):
        note("reconcilePackagePresence")
        return receipt(
          script.packageReadbackText
            ?? (script.packageInstalled ? "bundleName: \(bundle.bundleName)\n" : ""))
      case .readProcessPresence:
        note("reconcileProcessPresence")
        return receipt(
          script.processReadbackText ?? (script.processRunning ? "3421\n" : ""),
          exit: script.processRunning ? 0 : 1)
      case .readOwnedPathPresence:
        note("reconcileOwnedPathPresence")
        return receipt(
          script.ownedPathPresent
            ? "-rw------- owned\n"
            : "ls: owned: No such file or directory\n")
      case .readPortForwardPresence(let spec):
        note("reconcilePortForwardPresence")
        return receipt(
          script.portForwardPresent
            ? "tcp:\(spec.localPort) tcp:\(spec.remotePort)\n" : "")
      case .sendNativeLibraryToStaging, .backupNativeLibrary,
        .publishNativeLibrary, .stopNativeTarget, .startNativeTarget,
        .cleanupNativeLibrary, .rollbackNativeLibrary, .inspectNativeLibrary:
        throw RuntimeDispatchFailure.failed(
          "native deployment is outside the diagnostics/HAP fixture")
      }
    }
  }

  private func makeEngine(
    dispatcher: ScriptedDispatcher,
    artifactQuota: ArtifactQuota = ArtifactQuota()
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore, RuntimeArtifactStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      quota: artifactQuota,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      traceRuntimeProbe: TraceProbe(),
      nowUTC: { "2026-07-29T00:00:00Z" })
    return (engine, capabilityStore, artifactStore)
  }

  private func captureRequest(
    withTrace: Bool,
    key: String = "idem-capture-01",
    capability: String? = nil,
    totalArtifactByteBudget: Int? = nil,
    redactionProfile: String? = nil,
    withComponentTree: Bool = false,
    withScreenshot: Bool = false,
    withCrashLogs: Bool = false,
    crashLogName: String? = nil,
    bundleName: String? = nil,
    abilityName: String? = nil,
    processName: String? = nil,
    expectedDeployedArtifactDigest: String? = nil
  ) -> Data {
    let trace = withTrace ? "\"traceCategories\": [\"ohos\"]," : ""
    let tree = withComponentTree ? "\"uiComponentTree\": true," : ""
    let shot = withScreenshot ? "\"uiScreenshot\": true," : ""
    let crash = withCrashLogs ? "\"crashLogs\": true," : ""
    let crashName = crashLogName.map { "\"crashLogName\": \"\($0)\"," } ?? ""
    let auth = capability.map { "\"authorization\": { \"capabilityId\": \"\($0)\" }," } ?? ""
    let budget =
      totalArtifactByteBudget.map { "\"totalArtifactByteBudget\": \($0)," } ?? ""
    let redaction =
      redactionProfile.map { "\"redactionProfile\": \"\($0)\"," } ?? ""
    let bundle = bundleName.map { "\"bundleName\": \"\($0)\"," } ?? ""
    let ability = abilityName.map { "\"abilityName\": \"\($0)\"," } ?? ""
    let process = processName.map { "\"processName\": \"\($0)\"," } ?? ""
    let digest =
      expectedDeployedArtifactDigest.map {
        "\"expectedDeployedArtifactDigest\": \"\($0)\","
      } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-capture",
        "idempotencyKey": "\(key)",
        "target": { "targetId": "TGT-1", "expectedBindingRevision": 7 },
        "operation": { "id": "capture.diagnostics", "version": 1 },
        \(auth)
        "inputs": { \(trace) \(tree) \(shot) \(crash) \(crashName) \(budget) \(redaction) \(bundle) \(ability) \(process) \(digest) "durationSeconds": 5 }
      }
      """.utf8)
  }

  private func publishedJSON(
    named name: String,
    jobID: String,
    artifacts: RuntimeArtifactStore
  ) async throws -> [String: Any] {
    let inventory = try await artifacts.list(jobID: jobID)
    let record = try XCTUnwrap(inventory.first { $0.name == name })
    XCTAssertEqual(record.status, .published)
    let data = try await artifacts.read(jobID: jobID, artifactID: record.artifactID)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func hapRequest(
    lease: String,
    key: String = "idem-hap-01",
    capability: String? = "CAP-RT-HAP-001",
    bundleName: String = "com.example.demo",
    extraInputs: String = ""
  )
    -> Data
  {
    let auth = capability.map { "\"authorization\": { \"capabilityId\": \"\($0)\" }," } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-hap",
        "idempotencyKey": "\(key)",
        "target": { "targetId": "TGT-1", "expectedBindingRevision": 7 },
        "operation": { "id": "debug.hap", "version": 1 },
        \(auth)
        "inputs": {
          "hapArtifactLease": "\(lease)",
          "bundleName": "\(bundleName)",
          "abilityName": "EntryAbility"
          \(extraInputs)
        }
      }
      """.utf8)
  }

  private func publishHAPLease(_ store: RuntimeArtifactStore) async throws -> String {
    let metadata = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap",
        stepID: "publish-hap", name: "demo.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 7,
          stableIdentitySHA256:
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"),
        contents: Data("signed-hap-fixture".utf8)))
    return try await store.leaseReference(
      jobID: metadata.jobID, artifactID: metadata.artifactID)
  }

  private func installE1Capability(_ store: RuntimeCapabilityStore) async throws {
    try await store.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
  }

  // MARK: - DHA-CAP-001

  func testApplicationLivenessUsesAnExactTypedPidofPlan() throws {
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort())
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let step = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "observe-application-liveness" })
    let digest = String(repeating: "d", count: 64)
    let context = ProviderExecutionContext(
      jobID: "JOB-LIVE-1", stepID: step.stepID, targetID: "TGT-1",
      bindingRevision: 7, connectKey: "150100424a544e4600",
      expectedIdentitySHA256:
        "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z")
    let action = try provider.action(
      for: step, operation: descriptor,
      inputs: [
        "bundleName": .string("com.example.demo"),
        "abilityName": .string("EntryAbility"),
        "processName": .string("com.example.demo:worker"),
        "expectedDeployedArtifactDigest": .string(digest),
      ],
      context: context)
    guard case .hdc(.observeApplicationLiveness(let request)) = action else {
      return XCTFail("the catalog step must materialize a typed app-liveness action")
    }
    XCTAssertEqual(request.bundle.bundleName, "com.example.demo")
    XCTAssertEqual(request.abilityName, "EntryAbility")
    XCTAssertEqual(request.processName, "com.example.demo:worker")
    XCTAssertEqual(request.expectedDeployedArtifactDigest, digest)
    XCTAssertEqual(try PersistedTypedProviderAction(action).materialize(), action)

    let plan = try provider.lower(action: action, context: context)
    guard case .process(_, let argv, let timeout) = plan.kind else {
      return XCTFail("app liveness must lower to one bounded process readback")
    }
    XCTAssertEqual(
      argv,
      ["-t", "150100424a544e4600", "shell", "pidof", "com.example.demo:worker"])
    XCTAssertEqual(timeout, 30)

    let artifact = try XCTUnwrap(
      descriptor.artifacts.first { $0.name == "application-liveness.json" })
    XCTAssertEqual(artifact.mediaType, "application/json")
    XCTAssertEqual(artifact.privacy, .standard)
    XCTAssertFalse(artifact.isRequired)
  }

  func testApplicationLivenessPublishesHealthyRevisionBoundEvidence() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processReadbackText: "3421 3422\n"))
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let digest = String(repeating: "d", count: 64)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-app-live-healthy",
        bundleName: "com.example.demo", abilityName: "EntryAbility",
        expectedDeployedArtifactDigest: digest))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("applicationLivenessReadback"))
    let payload = try await publishedJSON(
      named: "application-liveness.json", jobID: acceptance.jobID, artifacts: artifacts)
    XCTAssertEqual(payload["documentType"] as? String, "arkdeck-application-liveness")
    XCTAssertEqual(payload["state"] as? String, "HEALTHY")
    XCTAssertEqual(payload["processState"] as? String, "RUNNING")
    XCTAssertEqual(payload["pidObserved"] as? Bool, true)
    XCTAssertEqual(payload["sourceRuntimeJobId"] as? String, acceptance.jobID)
    XCTAssertEqual(payload["sourceOperationRef"] as? String, "capture.diagnostics@1")
    XCTAssertEqual(payload["targetBindingRevision"] as? Int, 7)
    XCTAssertEqual(payload["deployedArtifactDigest"] as? String, digest)
    let applicationRef = try XCTUnwrap(payload["applicationRef"] as? String)
    XCTAssertEqual(applicationRef.count, 64)
    XCTAssertFalse(
      String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        .contains("com.example.demo"),
      "the derived Artifact must carry only the pseudonymous application reference")
  }

  func testStoppedTargetStaysUnhealthyDespiteUnrelatedSystemHilog() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(
        processRunning: false,
        hilogPayload: Data("01-01 00:00:00 I system_server: still busy\n".utf8)))
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-app-live-stopped",
        bundleName: "com.example.demo"))

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let payload = try await publishedJSON(
      named: "application-liveness.json", jobID: acceptance.jobID, artifacts: artifacts)
    XCTAssertEqual(payload["state"] as? String, "UNHEALTHY")
    XCTAssertEqual(payload["processState"] as? String, "STOPPED")
    XCTAssertEqual(payload["pidObserved"] as? Bool, false)
  }

  func testUnavailableOrAmbiguousAppReadbackPublishesUnknownWithoutBlessingIt() async throws {
    let scripts: [(String, ScriptedDispatcher.Script, String)] = [
      (
        "unavailable",
        .init(processReadbackText: "", processReadbackExit: 1),
        "processReadbackUnavailable"
      ),
      (
        "ambiguous",
        .init(processReadbackText: "some-other-process\n"),
        "processReadbackAmbiguous"
      ),
    ]
    for (suffix, script, reason) in scripts {
      let dispatcher = ScriptedDispatcher(script: script)
      let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
      let acceptance = try await engine.submit(
        captureRequest(
          withTrace: false, key: "idem-app-live-\(suffix)",
          bundleName: "com.example.demo"))
      let status = try await engine.run(jobID: acceptance.jobID)
      XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
      let payload = try await publishedJSON(
        named: "application-liveness.json", jobID: acceptance.jobID, artifacts: artifacts)
      XCTAssertEqual(payload["state"] as? String, "UNKNOWN")
      XCTAssertEqual(payload["reasonCode"] as? String, reason)
    }
  }

  func testInvalidApplicationIdentityIsRejectedBeforeProviderDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(
        captureRequest(
          withTrace: false, key: "idem-app-live-invalid",
          bundleName: "com.example.demo;pidof.other"))
      XCTFail("a command-shaped application identity must not be admitted")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, _) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertEqual(code, .invalidInput)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  func testPartialApplicationIdentityIsRejectedBeforeProviderDispatch() async throws {
    let requests = [
      captureRequest(
        withTrace: false, key: "idem-app-live-ability-only",
        abilityName: "EntryAbility"),
      captureRequest(
        withTrace: false, key: "idem-app-live-process-only",
        processName: "com.example.demo"),
      captureRequest(
        withTrace: false, key: "idem-app-live-digest-only",
        expectedDeployedArtifactDigest: String(repeating: "d", count: 64)),
    ]
    for request in requests {
      let dispatcher = ScriptedDispatcher()
      let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
      do {
        _ = try await engine.submit(request)
        XCTFail("a partial application identity must not be admitted")
      } catch let error as RuntimeJobEngineError {
        guard case .rejected(let code, _) = error else {
          return XCTFail("expected invalidInput, got \(error)")
        }
        XCTAssertEqual(code, .invalidInput)
      }
      XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
    }
  }

  func testCaptureWithoutApplicationIdentityDoesNotDispatchTheOptionalReadback() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-app-live-absent"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("applicationLivenessReadback"))
    let inventory = try await artifacts.list(jobID: acceptance.jobID)
    let record = try XCTUnwrap(
      inventory.first { $0.name == "application-liveness.json" })
    guard case .missing = record.status else {
      return XCTFail("an unselected optional observation must be recorded as missing")
    }
  }

  func testPublishedApplicationLivenessSurvivesRuntimeRestart() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-app-live-restart",
        bundleName: "com.example.demo"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let before = try await publishedJSON(
      named: "application-liveness.json", jobID: acceptance.jobID, artifacts: artifacts)

    let (recoveredEngine, _, recoveredArtifacts) = try makeEngine(
      dispatcher: ScriptedDispatcher())
    _ = try await recoveredEngine.recoverPersistedJobs()
    let after = try await publishedJSON(
      named: "application-liveness.json", jobID: acceptance.jobID,
      artifacts: recoveredArtifacts)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]),
      try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys]))
  }

  func testCaptureWithoutTraceRecordsTheTraceAsMissingNotAsSuccess() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(captureRequest(withTrace: false))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureTrace"))

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let byName = Dictionary(uniqueKeysWithValues: recorded.map { ($0.name, $0) })
    XCTAssertEqual(byName["hilog.txt"]?.status, .published)
    let hilogID = try XCTUnwrap(byName["hilog.txt"]?.artifactID)
    let hilog = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: hilogID, allowSensitive: true)
    XCTAssertEqual(
      String(data: hilog, encoding: .utf8),
      "01-01 00:00:00 I app: hello\n",
      "the Artifact must contain the captured log, not a byte-count summary")
    // The absent trace is present in the index WITH a reason: this is the
    // whole point - a partial capture cannot look complete.
    guard case .missing(let reason)? = byName["trace.htrace"]?.status else {
      return XCTFail(
        "the trace must be recorded as missing, got \(String(describing: byName["trace.htrace"]))")
    }
    XCTAssertFalse(reason.isEmpty)

    // And the summary says so in one place a caller can read.
    let summaryID = try XCTUnwrap(byName["capture-summary.json"]?.artifactID)
    let summaryText =
      String(
        data: try await artifacts.read(jobID: acceptance.jobID, artifactID: summaryID),
        encoding: .utf8) ?? ""
    XCTAssertTrue(summaryText.contains("trace.htrace"), summaryText)
    XCTAssertTrue(summaryText.contains("missing"), summaryText)
    // trace.htrace is an optional product, so overall completeness holds.
    XCTAssertTrue(summaryText.contains("\"completeness\" : \"complete\""), summaryText)
  }

  func testRequiredCaptureFailureFailsTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(hilogEmpty: true))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(captureRequest(withTrace: false))
    let status = try await engine.run(jobID: acceptance.jobID)
    // hilog is required; an empty capture is unknown, which halts.
    XCTAssertNotEqual(status.state, "succeeded")
    XCTAssertTrue(status.outcomeUnknown || status.state == "failed", status.state)
  }

  func testTraceAfterSnapshotDoesNotDisappearBehindAnEarlierKnownFailure() async throws {
    var script = ScriptedDispatcher.Script()
    script.hilogEmpty = true
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await installCaptureCapability(capabilities)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: true, key: "idem-trace-failed-with-after",
        capability: "CAP-RT-CAPTURE-001"))

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded")
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertNotNil(evidence.traceProbeBefore)
    XCTAssertNotNil(evidence.traceProbeAfter)
  }

  /// The trace leg used to be refused at admission because neither half of
  /// its verification existed. Both halves are published now, so the leg is
  /// governed by the same authorization path as every other E1 step —
  /// including this engine's automatic issuance, which is what a trace
  /// request without an explicit capability actually gets. Pinned because
  /// lifting the refusal is what makes it reachable for `traceCategories`.
  func testTraceEscalatesToE1AndUsesTheAutomaticPolicyWhenUncapped() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: true, key: "idem-trace-uncapped"))
    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "issuance happens after materialization but before any dispatch")

    let issued = try await capabilities.list()
    let automatic = try XCTUnwrap(issued.first)
    XCTAssertEqual(automatic.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(automatic.capability.effectCeiling, .deviceMutation)

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.authority?.kind, .runtimeCapability)
    let consumed = try await capabilities.inspect(
      capabilityID: automatic.capability.capabilityID)
    XCTAssertEqual(consumed?.consumptionCount, 1)
  }

  /// DHA-CAP-001's orchestration, end to end over the fake device: the trace
  /// is captured, read back, received, published from the received bytes and
  /// cleaned up. The published artifact must be the transferred file — the
  /// receive step's stdout is hdc's progress banner.
  func testTraceRunPublishesTheReceivedBytesAndCleansUp() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    try await installCaptureCapability(capabilities)

    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: true, key: "idem-trace-ok", capability: "CAP-RT-CAPTURE-001"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    for leg in ["captureTrace", "receiveArtifact", "cleanup"] {
      XCTAssertTrue(dispatcher.dispatchedActions.contains(leg), "missing \(leg)")
    }

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let trace = try XCTUnwrap(recorded.first { $0.name == "trace.htrace" })
    XCTAssertEqual(trace.status, .published)
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: trace.artifactID, allowSensitive: true)
    XCTAssertEqual(bytes, Data("trace-bytes".utf8))
    XCTAssertFalse(
      String(data: bytes, encoding: .utf8)!.contains("FileTransfer"),
      "the trace artifact must be the received file, never the transfer banner")

    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-CAPTURE-001")
    XCTAssertEqual(capability?.consumptionCount, 1)
  }

  /// A transfer that lands nowhere the caller named cannot be laundered into
  /// a published trace: the job stops with its intent outstanding.
  func testTraceThatNeverLandsStopsInsteadOfPublishing() async throws {
    var script = ScriptedDispatcher.Script()
    script.receivedTracePayload = nil
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    try await installCaptureCapability(capabilities)

    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: true, key: "idem-trace-nowhere", capability: "CAP-RT-CAPTURE-001"))
    let status = try? await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status?.state, "succeeded")
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let trace = recorded.first { $0.name == "trace.htrace" }
    if case .published? = trace?.status {
      XCTFail("nothing landed, so no trace artifact may be published")
    }
  }

  /// hitrace can exit cleanly and write nothing. The readback, not the exit
  /// status, is what says so — and the trace is an optional product, so the
  /// job keeps its partial-success semantics while recording the absence.
  func testZeroByteTraceFailsOnTheDeviceSideReadback() async throws {
    var script = ScriptedDispatcher.Script()
    script.traceListing =
      "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/trace.htrace\n"
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    try await installCaptureCapability(capabilities)

    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: true, key: "idem-trace-empty", capability: "CAP-RT-CAPTURE-001"))
    _ = try await engine.run(jobID: acceptance.jobID)
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("receiveArtifact"),
      "an empty capture must not proceed to the receive leg")

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    guard
      case .missing(let reason)? = recorded.first(where: { $0.name == "trace.htrace" })?
        .status
    else {
      return XCTFail("a zero-byte capture must record the trace as missing")
    }
    XCTAssertFalse(reason.isEmpty)
  }

  /// D4: the trace product comes off the host file the receive leg measured,
  /// never off a receipt. Publishing it from stdout would store hdc's
  /// "FileTransfer finish" banner under the name `trace.htrace` — a binary
  /// evidence artifact whose bytes are a progress message.
  ///
  /// This declaration is what the receive-step publication reads; the
  /// publication itself stays unreachable while trace requests are refused
  /// at admission above (the device-side existence/size readback for
  /// `hitrace -o` is still unimplemented).
  func testTraceIsDeclaredFileBackedSoItCannotBePublishedFromStdout() throws {
    XCTAssertTrue(RuntimeArtifactService.fileBackedArtifacts.contains("trace.htrace"))
    XCTAssertEqual(
      RuntimeArtifactService.artifactMapping["capture.diagnostics@1"]?["receive-trace-artifact"],
      ["trace.htrace"])
    for streamed in ["hilog.txt", "ui-dump.json", "debug-hilog.txt"] {
      XCTAssertFalse(
        RuntimeArtifactService.fileBackedArtifacts.contains(streamed),
        "\(streamed) is a captured stream and must keep publishing from the receipt")
    }
  }

  func testRemovedStrictRedactionValueFailsAtSchemaBeforeDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(
        captureRequest(
          withTrace: false, key: "idem-strict-redaction",
          redactionProfile: "strict"))
      XCTFail("strict cannot be silently treated as standard redaction")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertEqual(message, "input redactionProfile value is outside its enum")
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  /// ...while the same operation without the trace stays E0 and needs no
  /// capability at all. The pair is what makes the rule meaningful.
  func testCaptureWithoutTraceStaysE0AndNeedsNoCapability() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-trace-e0"))
    XCTAssertFalse(acceptance.deduplicated)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
  }

  func testDeviceStoragePreflightIsRealAndBlocksCaptureWhenInsufficient() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(availableStorageKB: 512))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-storage-preflight"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertEqual(
      dispatcher.dispatchedActions,
      ["observeDevice", "evidenceModel", "evidenceFirmware", "observeStorage"])
  }

  func testJobArtifactBudgetStopsPublicationWithoutFillingTheStore() async throws {
    let budget = 1_048_576
    let dispatcher = ScriptedDispatcher(
      script: .init(hilogPayloadBytes: budget + 1))
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-artifact-budget",
        totalArtifactByteBudget: budget))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    XCTAssertFalse(recorded.contains { $0.name == "hilog.txt" && $0.status.isPublished })
    XCTAssertLessThanOrEqual(
      recorded.filter { $0.status.isPublished }.reduce(0) { $0 + $1.byteCount },
      budget)
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureUIDump"))
  }

  func testHostStoragePreflightRefusesCollectionBeforeDeviceDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(
      dispatcher: dispatcher,
      artifactQuota: ArtifactQuota(totalBytes: 512 * 1024))
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-capture-host-preflight",
        totalArtifactByteBudget: 1_048_576))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed")
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
    XCTAssertTrue(
      status.timeline.contains { $0.contains("host storage preflight refused") },
      status.timeline.joined(separator: " | "))
  }

  private func installCaptureCapability(_ store: RuntimeCapabilityStore) async throws {
    try await store.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-CAPTURE-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "capture.diagnostics", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
  }

  /// Regression for the blocker maintainer review raised: an earlier
  /// version of the journal argument table labelled the HiLog step with a
  /// UI-dump action because that was the only thing the old schema
  /// allowed. The durable intent would then have recorded an action the
  /// step never performed - fabricated evidence, not a naming slip. The
  /// identity must come from the catalog's own actionRef.
  func testJournalIntentRecordsTheCatalogsOwnActionIdentity() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-identity-01"))
    _ = try await engine.run(jobID: acceptance.jobID)

    let journalURL =
      stateDirectory
      .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl")
    let journal = try String(contentsOf: journalURL, encoding: .utf8)

    // The HiLog step must carry the diagnostics action, and no step may
    // carry a UI-dump action it does not have.
    XCTAssertTrue(journal.contains("\"boundedHilog\""), "HiLog intent must name its own action")
    XCTAssertTrue(journal.contains("\"arkdeck-diagnostics\""))
    XCTAssertTrue(journal.contains("\"deviceModel\""))
    XCTAssertTrue(journal.contains("\"firmwareBuild\""))
    XCTAssertFalse(
      journal.contains("\"nodeSummary\""),
      "no step may borrow a UI-dump action id: \(journal.prefix(400))")

    // And the catalog is where that identity comes from.
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let hilog = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-hilog" })
    XCTAssertEqual(hilog.actionReference?.actionID, "boundedHilog")
    XCTAssertEqual(hilog.actionReference?.catalogID, "arkdeck-diagnostics")
  }

  func testIncompleteEvidencePreflightDispatchesNoHAPMutation() async throws {
    let vectors: [ScriptedDispatcher.Script] = [
      .init(targetRows: "different\t\tUSB\tConnected\tlocalhost\n"),
      .init(
        targetRows:
          "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
          + "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"),
      .init(targetRows: "150100424a544e4600\t\tBLUETOOTH\tConnected\tlocalhost\n"),
      .init(modelValue: "\n"),
      .init(firmwareValue: "\n"),
    ]
    for (index, script) in vectors.enumerated() {
      let dispatcher = ScriptedDispatcher(script: script)
      let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
      try await installE1Capability(capabilities)
      let lease = try await publishHAPLease(artifacts)
      let acceptance = try await engine.submit(
        hapRequest(lease: lease, key: "idem-hap-preflight-\(index)"))
      let status = try await engine.run(jobID: acceptance.jobID)
      XCTAssertNotEqual(status.state, "succeeded", "vector \(index)")
      XCTAssertFalse(
        dispatcher.dispatchedActions.contains("sendArtifact"),
        "no E1 dispatch is allowed before complete preflight: vector \(index)")
      XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"), "vector \(index)")
      let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
      XCTAssertEqual(
        capability?.consumptionCount, 0,
        "incomplete target/model/firmware preflight must not consume E1: vector \(index)")
    }
  }

  /// The readiness requires the constructed WorkflowStep to carry the
  /// diagnostics contract's exact typed parameters and bounds - not merely
  /// the right action name. These drive the real validator, so a parameter
  /// the contract rejects cannot reach a durable intent.
  func testConstructedIntentCarriesContractExactParameters() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let hilog = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-hilog" })

    // Out-of-range inputs are clamped into the declared bounds rather than
    // passed through: the step still validates.
    let clamped = try RuntimeJobEngine.journalStep(
      for: hilog, jobID: "job-1",
      inputs: [
        "durationSeconds": .integer(99_999),
        "hilogFilters": .array((0..<40).map { .string("tag\($0):E") }),
        "totalArtifactByteBudget": .integer(1),
      ])
    guard case .object(let parameters)? = clamped.arguments["parameters"] else {
      return XCTFail("the intent must carry typed parameters")
    }
    XCTAssertEqual(parameters["durationSeconds"], .integer(600), "clamped to the contract maximum")
    XCTAssertEqual(parameters["byteBudget"], .integer(1024), "clamped to the contract minimum")
    guard case .array(let filters)? = parameters["filters"] else {
      return XCTFail("filters must be present")
    }
    XCTAssertEqual(filters.count, 16, "trimmed to the contract's 16-filter ceiling")
    XCTAssertEqual(clamped.arguments["catalogId"], .string("arkdeck-diagnostics"))
    XCTAssertEqual(clamped.arguments["actionId"], .string("boundedHilog"))

    // The UI-dump step carries its own action's parameter set, not HiLog's.
    let uiDump = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-ui-dump" })
    let uiStep = try RuntimeJobEngine.journalStep(for: uiDump, jobID: "job-1", inputs: [:])
    XCTAssertEqual(uiStep.arguments["actionId"], .string("windowInventory"))
    guard case .object(let uiParameters)? = uiStep.arguments["parameters"] else {
      return XCTFail("the ui-dump intent must carry typed parameters")
    }
    XCTAssertEqual(Set(uiParameters.keys), ["byteBudget"], "windowInventory declares only a budget")
  }

  func testPairedRemoteActionsShareTheRealJobBoundProviderPath() throws {
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort())
    let context = ProviderExecutionContext(
      jobID: "job-runtime-123", stepID: "test", targetID: "TGT-1",
      bindingRevision: 7, connectKey: "150100424a544e4600",
      nowUTC: "2026-07-29T00:00:00Z")

    let capture = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    // Categories are the caller's; the lowering invents none. `ability` is a
    // tag the 2026-07-31 device window confirmed exists on OH 3.2.
    let traceInputs: [String: JSONValue] = ["traceCategories": .array([.string("ability")])]
    let trace = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "capture-trace" }),
      operation: capture, inputs: traceInputs, context: context)
    let receive = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "receive-trace-artifact" }),
      operation: capture, inputs: [:], context: context)
    let captureCleanup = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "cleanup-remote-temp" }),
      operation: capture, inputs: [:], context: context)

    guard case .hdc(.captureTrace(_, let tracePath)) = trace,
      case .hdc(.receiveOwnedArtifact(let remoteArtifact)) = receive,
      case .hdc(.cleanupOwnedRemotePath(let cleanupPath)) = captureCleanup
    else {
      return XCTFail("capture actions must retain their typed path payloads")
    }
    XCTAssertEqual(tracePath, remoteArtifact.path)
    XCTAssertEqual(tracePath, cleanupPath)
    XCTAssertEqual(tracePath.jobID, "job-runtime-123")

    let debug = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let inputs: [String: JSONValue] = [
      "hapArtifactLease": .string("lease-v1:job-input:ART-0123456789abcdef0123456789abcdef"),
      "bundleName": .string("com.example.demo"),
      "abilityName": .string("EntryAbility"),
    ]
    let send = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "send-hap" }),
      operation: debug, inputs: inputs, context: context)
    let install = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "install-hap" }),
      operation: debug, inputs: inputs, context: context)
    let stagingCleanup = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "cleanup-remote-staging" }),
      operation: debug, inputs: inputs, context: context)

    guard case .hdc(.sendArtifactToStaging(let staged)) = send,
      case .hdc(.installPackage(let installed, _)) = install,
      case .hdc(.cleanupOwnedRemotePath(let stagingPath)) = stagingCleanup
    else {
      return XCTFail("debug actions must retain their typed staging payloads")
    }
    XCTAssertEqual(staged.path, installed.path)
    XCTAssertEqual(staged.path, stagingPath)
    XCTAssertEqual(staged.path.jobID, "job-runtime-123")
    let installPlan = try provider.lower(action: install, context: context)
    guard case .process(_, let installArguments, _) = installPlan.kind else {
      return XCTFail("install must lower to a process plan")
    }
    XCTAssertEqual(
      installArguments,
      [
        "-t", "150100424a544e4600", "shell", "bm", "install", "-p",
        staged.path.remotePath, "-r",
      ],
      "installOrReplace must use the staged remote path and replacement mode")
  }

  /// A stdout-capturing step with no declared action must stop the run
  /// rather than have one invented for its durable intent.
  func testStdoutStepWithoutADeclaredActionIsRefused() throws {
    let undeclared = CatalogStepDescriptor(
      stepID: "capture-mystery", kind: .captureRemoteStdout, effect: .readOnly,
      cancellation: .immediate, binding: .confirmedDevice, isOptional: false,
      compensation: .none, actionReference: nil)
    XCTAssertThrowsError(
      try RuntimeJobEngine.journalStep(for: undeclared, jobID: "job-1", inputs: [:])
    ) { error in
      guard case RuntimeJobEngineError.internalFailure(let detail) = error else {
        return XCTFail("expected internalFailure, got \(error)")
      }
      XCTAssertTrue(detail.contains("refusing to invent"), detail)
    }
  }

  // MARK: - DHA-HAP-001

  func testHAPSuccessRequiresBothReadbacks() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    let resolved = try await artifacts.resolveLease(lease)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest(lease: lease))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("packageReadback"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("processReadback"))
    // The mutating steps are recorded as dispatched-awaiting-readback,
    // never as verified on their own.
    XCTAssertTrue(status.timeline.contains { $0.contains("awaiting readback") })
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let installReadback = try XCTUnwrap(
      recorded.first { $0.name == "install-readback.json" && $0.status.isPublished })
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: installReadback.artifactID,
      maximumBytes: installReadback.byteCount)
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: bytes) else {
      return XCTFail("install readback must be a JSON object")
    }
    XCTAssertEqual(
      fields["deployedArtifactSha256"], .string(resolved.sha256),
      "package readback must bind the installed bundle to the exact immutable HAP")
  }

  func testHAPPreservesNonUTF8HilogAsSensitiveRawArtifact() async throws {
    let raw = Data([0x49, 0x20, 0xff, 0xfe, 0x0a])
    let dispatcher = ScriptedDispatcher(script: .init(hilogPayload: raw))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-non-utf8-hilog"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let hilog = try XCTUnwrap(recorded.first { $0.name == "debug-hilog.txt" })
    XCTAssertEqual(hilog.status, .published)
    XCTAssertEqual(hilog.privacy, .sensitive)
    XCTAssertFalse(hilog.redactionApplied)
    let stored = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: hilog.artifactID,
      allowSensitive: true)
    XCTAssertEqual(stored, raw)
  }

  func testHAPDurableIntentUsesTheResolvedArtifactAndExactOwnedPath() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    let resolved = try await artifacts.resolveLease(lease)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-exact-intent"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")

    let journal = try String(
      contentsOf: stateDirectory.appending(
        path:
          "jobs/\(acceptance.jobID)/journal.jsonl"),
      encoding: .utf8)
    let ownedPath =
      "/data/local/tmp/arkdeck-\(acceptance.jobID)-send-hap-owned.hap"
    XCTAssertTrue(journal.contains(resolved.artifactID), journal)
    XCTAssertTrue(journal.contains(resolved.sha256), journal)
    XCTAssertTrue(journal.contains(ownedPath), journal)
    XCTAssertFalse(journal.contains("<artifact-lease>"), journal)
  }

  func testCleanInstallExitWithEmptyReadbackFailsTheJob() async throws {
    // The exact hardware-observed hazard: `hdc install` exits zero without
    // having installed. Success must not follow from the exit code.
    let dispatcher = ScriptedDispatcher(script: .init(packageInstalled: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-noinstall"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("packageReadback"))
    // Having failed the readback, the run must not have started anything.
    XCTAssertFalse(dispatcher.dispatchedActions.contains("startAbility"))
  }

  func testNonzeroInstallFailsBeforeAnExistingPackageCanFakeTheReadback() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(installExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-install-failed"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("packageReadback"),
      "an already-installed old package must not turn a failed install into success")
  }

  func testNonzeroStartFailsBeforeAnExistingProcessCanFakeTheReadback() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: true, startExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-start-failed"))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("processReadback"),
      "an old live process must not turn a failed start into success")
    XCTAssertTrue(dispatcher.dispatchedActions.contains("uninstallPackage"))
  }

  func testCleanStartExitWithNoProcessFailsTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-nostart"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("processReadback"))
  }

  func testPackageReadbackRejectsBundleNameSubstrings() async throws {
    let packageDispatcher = ScriptedDispatcher(
      script: .init(packageReadbackText: "bundleName: com.example.demo.other\n"))
    let (packageEngine, packageCapabilities, packageArtifacts) =
      try makeEngine(dispatcher: packageDispatcher)
    let packageLease = try await publishHAPLease(packageArtifacts)
    try await installE1Capability(packageCapabilities)
    let packageJob = try await packageEngine.submit(
      hapRequest(lease: packageLease, key: "idem-hap-package-substring"))
    let packageStatus = try await packageEngine.run(jobID: packageJob.jobID)
    XCTAssertEqual(packageStatus.state, "failed")
    XCTAssertFalse(packageDispatcher.dispatchedActions.contains("startAbility"))
  }

  func testProcessReadbackRejectsNonnumericPidNoise() async throws {
    let processDispatcher = ScriptedDispatcher(
      script: .init(processReadbackText: "error 404\n"))
    let (processEngine, processCapabilities, processArtifacts) =
      try makeEngine(dispatcher: processDispatcher)
    let processLease = try await publishHAPLease(processArtifacts)
    try await installE1Capability(processCapabilities)
    let processJob = try await processEngine.submit(
      hapRequest(lease: processLease, key: "idem-hap-pid-noise"))
    let processStatus = try await processEngine.run(jobID: processJob.jobID)
    XCTAssertEqual(processStatus.state, "failed")
  }

  /// D2 end to end: `aa force-stop` exits 0, the process is still there, and
  /// the job must not report success. Before the readback this run was
  /// indistinguishable from a clean stop.
  func testHAPStopThatLeavesTheProcessRunningFailsTheJob() async throws {
    var script = ScriptedDispatcher.Script()
    script.processRunningAfterStop = true
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let job = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-stop-ineffective"))
    let status = try await engine.run(jobID: job.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      status.timeline.contains { $0.contains("stopIneffective") },
      status.timeline.joined(separator: " | "))
  }

  /// The same evidence for the optional uninstall leg. `cleanup-uninstall`
  /// is optional, so the job still completes — but the ineffective uninstall
  /// is now recorded as a failed step instead of passing for a clean one,
  /// which is what a later run (or a reader) needs in order to know the
  /// bundle is still on the device.
  func testHAPUninstallThatLeavesThePackageInstalledIsRecordedAsFailed() async throws {
    var script = ScriptedDispatcher.Script()
    script.packageInstalledAfterUninstall = true
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let job = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-uninstall-ineffective"))
    let status = try await engine.run(jobID: job.jobID)
    let timeline = status.timeline.joined(separator: " | ")
    XCTAssertTrue(
      status.timeline.contains {
        $0.hasPrefix("failed cleanup-uninstall") && $0.contains("uninstallIneffective")
      }, timeline)
    XCTAssertEqual(status.state, "succeeded", "the uninstall leg is optional by catalog")
  }

  func testHAPWithoutCapabilityUsesAutomaticE1Policy() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-auto-policy", capability: nil))
    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "automatic issuance happens after materialization but before any dispatch")

    let automaticStatuses = try await capabilities.list()
    let automatic = try XCTUnwrap(automaticStatuses.first)
    XCTAssertEqual(automatic.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(automatic.consumptionCount, 0)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("sendArtifact"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("installPackage"))

    let consumed = try await capabilities.inspect(
      capabilityID: automatic.capability.capabilityID)
    XCTAssertEqual(consumed?.consumptionCount, 1)
    XCTAssertEqual(consumed?.remainingUses, 9_999)
    XCTAssertEqual(consumed?.lineage.first?.outcome, .confirmed)
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.authority?.kind, .runtimeCapability)
    XCTAssertEqual(evidence.authority?.reference, automatic.capability.capabilityID)
  }

  /// The GJ-5 window's revoked-envelope repro, driven through the real engine
  /// (CHG-2026-025, TASK-AIN-019). What matters here is not that the refusal
  /// happens — the store already guaranteed that — but that the *reason*
  /// leaves the engine as a machine token. Without it a caller — today an
  /// external agent reading the refusal — can only see that authorization was
  /// involved, and reports a withdrawn grant as a missing one.
  func testARevokedCapabilityRejectionNamesItsReasonAsAMachineToken() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    try await capabilities.revoke(
      capabilityID: "CAP-RT-HAP-001", atUTC: "2026-07-29T00:00:00Z",
      reason: "maintainer withdrew the debug envelope")

    do {
      let acceptance = try await engine.submit(
        hapRequest(lease: lease, key: "idem-hap-revoked"))
      _ = try await engine.run(jobID: acceptance.jobID)
      XCTFail("a revoked capability must never admit a mutation")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection shape: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired, detail)
      XCTAssertTrue(
        detail.contains("\(RuntimeJobEngine.capabilityDenialMarker)revoked]"),
        "the denial reason must survive as a token, not only as reflected prose: \(detail)")
    }

    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "refusal precedes every dispatch: \(dispatcher.dispatchedActions)")
    let untouched = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(untouched?.consumptionCount, 0)
    XCTAssertEqual(untouched?.remainingUses, 5)
  }

  func testOfflineTargetFailsDurablyBeforeCapabilityConsumptionOrMutation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(
        targetRows: "150100424a544e4600\t\tUSB\tOffline\tlocalhost\n"))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)

    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-offline-before-consume"))

    let beforeRun = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(beforeRun?.consumptionCount, 0)
    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "submit may materialize and preauthorize, but every external probe needs a durable job intent"
    )
    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      status.timeline.contains { $0.contains("targetNotConnected") },
      status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      status.timeline.contains { $0.contains("three-step typed preflight is incomplete") },
      "a no-mutation target failure must not be overwritten by compensation preflight")
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertEqual(capability?.remainingUses, 5)
    XCTAssertEqual(
      dispatcher.dispatchedActions, ["observeDevice"],
      "only the journaled descriptor-bound target confirmation may dispatch")
    let jobs = try await engine.listJobs()
    XCTAssertEqual(jobs.map(\.jobID), [acceptance.jobID])
  }

  func testRuntimeTargetFailurePreservesPrimaryReasonWithoutFalseCompensation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(targetRows: "different\t\tUSB\tConnected\tlocalhost\n"))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-offline-after-consume"))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      status.timeline.contains { $0.contains("targetConfirmationMismatch") },
      status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      status.timeline.contains { $0.contains("three-step typed preflight is incomplete") },
      "a no-mutation target failure must not be overwritten by compensation preflight")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("sendArtifact"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("uninstallPackage"))
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
  }

  func testHAPLeaseDriftBeforeSendFailsWithoutDispatchOrStuckRunningState() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-lease-drift"))
    let resolved = try await artifacts.resolveLease(lease)
    try FileManager.default.removeItem(at: resolved.fileURL)

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("sendArtifact"),
      "no mutation may use drifted Artifact bytes")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"))
  }

  func testCapabilityScopedToAnotherOperationIsRejected() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await capabilities.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-001",
        targetScope: .anyTarget,
        // Scoped to a different operation than the one being run.
        operationScope: [.init(operationID: "deploy.native-library.app-owned", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
    do {
      _ = try await engine.submit(hapRequest(lease: lease, key: "idem-hap-scope"))
      XCTFail("an out-of-scope capability must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, let message) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
      XCTAssertTrue(message.contains("operationScopeMismatch"), message)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  func testCapabilityIsConsumedOncePerRecipeNotPerStep() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-once"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let status = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(
      status?.remainingUses, 4,
      "one recipe consumes exactly one use, however many mutating steps it has")
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testDeferredCapabilityConsumptionSurvivesRestartBeforeRun() async throws {
    let submitDispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: submitDispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-deferred-restart"))
    let beforeRestart = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(beforeRestart?.consumptionCount, 0)
    XCTAssertTrue(submitDispatcher.dispatchedActions.isEmpty)

    let recoveredDispatcher = ScriptedDispatcher()
    let (recovered, recoveredCapabilities, _) = try makeEngine(
      dispatcher: recoveredDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let status = try await recovered.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let afterRun = try await recoveredCapabilities.inspect(
      capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(afterRun?.consumptionCount, 1)
    XCTAssertTrue(
      status.timeline.contains { $0 == "capability consumed before first mutation" })
    XCTAssertTrue(recoveredDispatcher.dispatchedActions.contains("sendArtifact"))
  }

  func testIdempotencyConflictCannotConsumeASecondCapability() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    try await capabilities.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-002",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))

    let firstAcceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-conflict"))
    do {
      _ = try await engine.submit(
        hapRequest(
          lease: lease, key: "idem-hap-conflict",
          capability: "CAP-RT-HAP-002", bundleName: "com.example.other"))
      XCTFail("drifted request must conflict")
    } catch let error as RuntimeJobEngineError {
      guard case .idempotencyConflict = error else {
        return XCTFail("expected idempotencyConflict, got \(error)")
      }
    }
    let firstCapability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    let secondCapability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-002")
    XCTAssertEqual(
      firstCapability?.consumptionCount, 0,
      "submit preauthorizes but does not consume before journaled target preflight")
    XCTAssertEqual(secondCapability?.consumptionCount, 0)
    _ = try await engine.run(jobID: firstAcceptance.jobID)
    let consumedFirst = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(consumedFirst?.consumptionCount, 1)
  }

  func testRetainAndDisabledDiagnosticsDoNotDispatchThoseOptionalSteps() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease, key: "idem-hap-retain",
        extraInputs: """
          ,
          "cleanupPolicy": "retain",
          "captureDiagnostics": false
          """))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureHilog"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("uninstallPackage"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))
  }

  /// CHG-2026-054 TASK-HTP-006: GJ-5 needs the application under debug to be
  /// alive while something else observes it, and until now no request could
  /// leave it that way - `stop-ability` ran unconditionally, so every
  /// successful run ended with the ability stopped. Measured on the
  /// 2026-07-31 device window, where the harness then measured "liveness" on a
  /// device whose application was not running.
  func testPostRunAbilityStateRunningSkipsOnlyTheStopStep() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease, key: "idem-hap-keep-running",
        extraInputs: """
          ,
          "cleanupPolicy": "retain",
          "postRunAbilityState": "running"
          """))
    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      dispatcher.dispatchedActions.contains("startAbility"),
      "the ability still has to be started and read back")
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("stopAbility"),
      "the request asked for it to stay running")
    XCTAssertTrue(
      status.timeline.contains { $0.contains("skipped stop-ability") },
      "the skip is journalled, not silent: \(status.timeline.joined(separator: " | "))")
    XCTAssertTrue(
      dispatcher.dispatchedActions.contains("cleanup"),
      "remote staging is still cleaned up")
  }

  func testTheDefaultStillStopsTheAbility() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-default-stop"))
    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      dispatcher.dispatchedActions.contains("stopAbility"),
      "a request that says nothing gets the catalog default, which stops it")
  }

  func testUnsupportedHAPModesFailBeforeCapabilityConsumption() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)

    let unsupported: [(String, String, String)] = [
      (
        "restore", "\"cleanupPolicy\": \"restorePrevious\"",
        "cleanupPolicy"
      ),
      (
        "forward", "\"portForwardProfile\": \"debugger-default\"",
        "portForwardProfile"
      ),
      (
        "fresh", "\"installPolicy\": \"installFresh\"",
        "installPolicy"
      ),
    ]
    for (suffix, input, field) in unsupported {
      do {
        _ = try await engine.submit(
          hapRequest(
            lease: lease, key: "idem-hap-\(suffix)",
            extraInputs: ",\n\(input)"))
        XCTFail("\(suffix) cannot be silently downgraded")
      } catch let error as RuntimeJobEngineError {
        guard case .rejected(.invalidInput, let detail) = error else {
          return XCTFail("expected invalidInput, got \(error)")
        }
        XCTAssertEqual(detail, "input \(field) value is outside its enum")
      }
    }
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  func testRemovedEnumValuesHaveNoManualAdmissionBranches() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift"),
      encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "  private func validateSupportedPlanInputs("))
    let tail = source[start.lowerBound...]
    let end = try XCTUnwrap(tail.range(of: "\n  /// Builds the single authorization subject"))
    let validator = String(tail[..<end.lowerBound])

    for deadBranch in [
      #"inputs["redactionProfile"] == .string("strict")"#,
      #"profile != HDCNativeRestartProfile.restartAbility.rawValue"#,
      #"inputs["installPolicy"] == .string("installFresh")"#,
      #"inputs["cleanupPolicy"] == .string("restorePrevious")"#,
      #"inputs["portForwardProfile"] == .string("debugger-default")"#,
    ] {
      XCTAssertFalse(
        validator.contains(deadBranch),
        "schema-rejected enum values must not retain a second manual admission branch: \(deadBranch)")
    }
    XCTAssertFalse(validator.contains("deploy.native-library.app-owned@1"))
    XCTAssertFalse(validator.contains("debug.hap@1"))
  }

  func testInvalidCatalogBoundFailsBeforeCapabilityConsumption() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    do {
      _ = try await engine.submit(
        hapRequest(
          lease: lease, key: "idem-hap-duration",
          extraInputs: """
            ,
            "diagnosticsDurationSeconds": 999
            """))
      XCTFail("out-of-range catalog input must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, _) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
  }

  func testReadbackFailureRunsTypedCompensation() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-compensate"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("stopAbility"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("uninstallPackage"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))
    XCTAssertTrue(status.timeline.contains { $0.contains("compensated cleanup-uninstall") })
  }

  func testReconcileUsesTheOriginalUnknownMutationAction() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(sendOutcomeUnknown: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-reconcile"))
    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    XCTAssertTrue(parked.outcomeUnknown)
    let parkedReplay = try DurableJournalRecovery.inspect(
      url:
        stateDirectory
        .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl"))
    XCTAssertEqual(
      parkedReplay.outstandingIntents.map(\.stepID), ["send-hap"],
      "an unknown dispatch must retain the original durable intent")
    XCTAssertTrue(
      parkedReplay.unknownOutcomes.isEmpty,
      "recovery must not manufacture an outcomeUnknown step outcome")

    let recoveryDispatcher = ScriptedDispatcher()
    let (recoveredEngine, _, _) = try makeEngine(dispatcher: recoveryDispatcher)
    _ = try await recoveredEngine.recoverPersistedJobs()
    let reconciled = try await recoveredEngine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(
      reconciled.outcomeUnknown,
      "the persisted send action must reconcile through its job-owned path readback")
    XCTAssertTrue(
      reconciled.timeline.contains { $0.contains("reconciled") },
      reconciled.timeline.joined(separator: " | "))
    XCTAssertEqual(
      recoveryDispatcher.dispatchedActions, ["reconcileOwnedPathPresence"],
      "restart recovery must dispatch only the dedicated readback, never resend the mutation")
    let resumed = try await recoveredEngine.run(jobID: acceptance.jobID)
    XCTAssertEqual(resumed.state, "succeeded", resumed.timeline.joined(separator: " | "))
    XCTAssertFalse(
      recoveryDispatcher.dispatchedActions.contains("sendArtifact"),
      "the reconciled mutation must be skipped from durable journal progress")
    let completedReplay = try DurableJournalRecovery.inspect(
      url:
        stateDirectory
        .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl"))
    XCTAssertTrue(completedReplay.outstandingIntents.isEmpty)
    XCTAssertTrue(completedReplay.unknownOutcomes.isEmpty)

    // Settling the authorization lineage is what the resume is *for*: a
    // `confirmedCompleted` reconcile deliberately keeps the reservation
    // (the job still owns it), so only finishing the plan may record the
    // confirmed use. Until the 2026-07-31 device window the CLI had no way
    // to run this resume, and a reconciled target stayed blocked for every
    // later automatic E1.
    let settled = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertTrue(try XCTUnwrap(settled).lineageAllowsNewExecution)
    let outcomes = try XCTUnwrap(settled).lineage.flatMap(\.outcomeHistory).map(\.outcome)
    XCTAssertEqual(
      outcomes, [.outcomeUnknown, .confirmed],
      "the ledger keeps the unknown and appends its resolution; it never rewrites it")
  }

  func testSemanticUnknownPersistsItsOriginalStepForReconcile() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(hilogEmpty: true))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-capture-semantic-unknown"))
    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    XCTAssertTrue(parked.outcomeUnknown)

    let reconciled = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(
      reconciled.state, "failed",
      "confirmed non-execution is terminal and must not auto-resend even a read-only action")
    XCTAssertTrue(
      reconciled.timeline.contains { $0.contains("reconciled") },
      reconciled.timeline.joined(separator: " | "))
  }

  func testCleanupDebtCanBeQueriedAndExplicitlyContinued() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(processRunning: false, cleanupExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-cleanup-debt-continue"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let debts = try await engine.listCleanupDebt()
    let debt = try XCTUnwrap(debts.first)
    XCTAssertEqual(debt.jobID, acceptance.jobID)

    let continuationDispatcher = ScriptedDispatcher()
    let (recovered, _, _) = try makeEngine(dispatcher: continuationDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let result = try await recovered.continueCleanupDebt(
      jobID: debt.jobID, identity: debt.identity)
    XCTAssertEqual(result.state, .settled)
    XCTAssertEqual(
      continuationDispatcher.dispatchedActions,
      ["reconcileOwnedPathPresence", "cleanup"])
    let remainingDebt = try await recovered.listCleanupDebt()
    XCTAssertTrue(remainingDebt.isEmpty)
  }

  func testUnknownCleanupContinuationNeverResendsMutation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(processRunning: false, cleanupExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-cleanup-debt-unknown"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let recordedDebt = try await engine.listCleanupDebt()
    let debt = try XCTUnwrap(recordedDebt.first)

    let unknownDispatcher = ScriptedDispatcher(script: .init(cleanupOutcomeUnknown: true))
    let (firstRecovery, _, _) = try makeEngine(dispatcher: unknownDispatcher)
    _ = try await firstRecovery.recoverPersistedJobs()
    let unknown = try await firstRecovery.continueCleanupDebt(
      jobID: debt.jobID, identity: debt.identity)
    XCTAssertEqual(unknown.state, .outcomeUnknown)
    XCTAssertEqual(
      unknownDispatcher.dispatchedActions,
      ["reconcileOwnedPathPresence", "cleanup"])

    let noResendDispatcher = ScriptedDispatcher()
    let (secondRecovery, _, _) = try makeEngine(dispatcher: noResendDispatcher)
    _ = try await secondRecovery.recoverPersistedJobs()
    let refused = try await secondRecovery.continueCleanupDebt(
      jobID: debt.jobID, identity: debt.identity)
    XCTAssertEqual(refused.state, .outcomeUnknown)
    XCTAssertEqual(
      noResendDispatcher.dispatchedActions, ["reconcileOwnedPathPresence"],
      "an outcomeUnknown cleanup retry may only be read back, never resent")
  }
}

// MARK: - CHG-2026-053 r2: the component tree as a file product

extension DiagnosticsAndHAPContractTests {
  /// UDR-AC-6: the input is the only thing that raises the plan. Without it
  /// the operation stays exactly what it was — E0, default read-only policy,
  /// no tree steps — and with it the file steps run under the same E1 path
  /// the trace leg already uses.
  func testComponentTreeInputIsWhatRaisesTheEffect() async throws {
    let quiet = ScriptedDispatcher()
    let (engineWithout, capabilitiesWithout, artifactsWithout) = try makeEngine(
      dispatcher: quiet)
    let plain = try await engineWithout.submit(
      captureRequest(withTrace: false, key: "idem-tree-absent"))
    let plainStatus = try await engineWithout.run(jobID: plain.jobID)
    XCTAssertEqual(plainStatus.state, "succeeded")
    XCTAssertFalse(
      quiet.dispatchedActions.contains("captureComponentTree"),
      "the tree leg must not run for a request that did not ask for it")
    let plainEvidence = try await engineWithout.evidenceSnapshot(jobID: plain.jobID)
    XCTAssertEqual(plainEvidence.authority?.kind, .defaultReadOnlyPolicy)
    let issuedForPlain = try await capabilitiesWithout.list()
    XCTAssertTrue(issuedForPlain.isEmpty, "an E0 plan issues no capability")
    // The declared product is still indexed, with a reason — a partial
    // capture may never look complete — but it is not published.
    let plainTree = try await artifactsWithout.list(jobID: plain.jobID)
      .first { $0.name == "ui-tree.json" }
    if let plainTree, case .published = plainTree.status {
      XCTFail("a request that did not ask for the tree cannot publish one")
    }

    let loud = ScriptedDispatcher()
    let (engineWith, capabilitiesWith, _) = try makeEngine(dispatcher: loud)
    let asked = try await engineWith.submit(
      captureRequest(withTrace: false, key: "idem-tree-present", withComponentTree: true))
    let askedStatus = try await engineWith.run(jobID: asked.jobID)
    XCTAssertEqual(
      askedStatus.state, "succeeded", askedStatus.timeline.joined(separator: " | "))
    XCTAssertTrue(loud.dispatchedActions.contains("captureComponentTree"))
    let askedEvidence = try await engineWith.evidenceSnapshot(jobID: asked.jobID)
    XCTAssertEqual(askedEvidence.authority?.kind, .runtimeCapability)
    let issued = try await capabilitiesWith.list()
    XCTAssertEqual(issued.first?.capability.effectCeiling, .deviceMutation)
  }

  /// UDR-AC-7: the tree is the received bytes, published through the path
  /// that redacts — never through `publishFile`, which refuses JSON exactly
  /// because it would skip redaction.
  func testComponentTreePublishesReceivedBytesThroughTheRedactingPath() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-tree-publish", withComponentTree: true))
    _ = try await engine.run(jobID: acceptance.jobID)

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let tree = try XCTUnwrap(recorded.first { $0.name == "ui-tree.json" })
    XCTAssertEqual(tree.status, .published)
    XCTAssertEqual(tree.mediaType, "application/json")
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: tree.artifactID, allowSensitive: true)
    let decoded = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertNotNil(decoded["children"], "the artifact must be the received tree")
    XCTAssertNotNil(decoded["attributes"])
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))

    // And the file-backed route stays closed to this media type: it skips
    // redaction, which is why the tree may not take it.
    do {
      _ = try await artifacts.publishFile(
        RuntimeArtifactFilePublicationRequest(
          jobID: acceptance.jobID, sessionID: "s", stepID: "receive-ui-tree",
          name: "ui-tree-direct.json", mediaType: "application/json", privacy: .sensitive,
          retentionClass: .default, sourceOperation: "capture.diagnostics@1",
          providerID: "hdc",
          bindingSnapshot: ArtifactBindingSnapshot(
            targetID: "TGT-1", bindingRevision: 7, stableIdentitySHA256: nil),
          sourceFileURL: URL(filePath: "/private/tmp/whatever.json"),
          expectedByteCount: 10, expectedSHA256: String(repeating: "a", count: 64)))
      XCTFail("publishFile must keep refusing application/json")
    } catch {}
  }

  /// A transfer that lands nothing may not become a published tree.
  func testComponentTreeThatNeverLandsIsRecordedMissing() async throws {
    var script = ScriptedDispatcher.Script()
    script.uiTreePayload = nil
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-tree-nowhere", withComponentTree: true))
    _ = try? await engine.run(jobID: acceptance.jobID)
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    if case .published? = recorded.first(where: { $0.name == "ui-tree.json" })?.status {
      XCTFail("nothing landed, so no tree artifact may be published")
    }
  }
}

// MARK: - CHG-2026-049 r3: cleanup residue is a first-class record

extension DiagnosticsAndHAPContractTests {
  /// DHA-RES-001: an uninstall that ran and did not take effect is recorded
  /// as residue, on the forward path and on the compensation path alike.
  /// Before r3 the ledger was keyed by remote path, so a left-behind bundle
  /// had nowhere to be written and the job simply reported success.
  func testIneffectiveUninstallIsRecordedAsResidueOnTheForwardPath() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(packageInstalledAfterUninstall: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-residue-forward"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")

    let debts = try await engine.listCleanupDebt()
    let residue = try XCTUnwrap(debts.first { $0.bundleName != nil })
    XCTAssertEqual(residue.jobID, acceptance.jobID)
    XCTAssertEqual(residue.stepID, "cleanup-uninstall")
    XCTAssertEqual(residue.bundleName, "com.example.demo")
    XCTAssertEqual(residue.identity, "bundle:com.example.demo")
    XCTAssertEqual(residue.remotePath, "", "a bundle residue names no path")
    XCTAssertFalse(residue.reason.isEmpty)
  }

  func testIneffectiveUninstallIsRecordedAsResidueOnTheCompensationPath() async throws {
    // start-ability fails, so compensation runs the cleanup legs; the
    // uninstall among them does not take effect.
    let dispatcher = ScriptedDispatcher(
      script: .init(startExit: 1, packageInstalledAfterUninstall: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-residue-compensation"))
    _ = try? await engine.run(jobID: acceptance.jobID)

    let debts = try await engine.listCleanupDebt()
    let residue = try XCTUnwrap(debts.first { $0.bundleName == "com.example.demo" })
    XCTAssertEqual(residue.jobID, acceptance.jobID)
    XCTAssertFalse(residue.reason.isEmpty)
  }

  /// DHA-RES-002: `succeeded` keeps its meaning and stops reading as a
  /// clean device. No terminal state is added to say so.
  func testSucceededCarriesItsOutstandingResidueCount() async throws {
    let dirty = ScriptedDispatcher(script: .init(packageInstalledAfterUninstall: true))
    let (dirtyEngine, dirtyCapabilities, dirtyArtifacts) = try makeEngine(dispatcher: dirty)
    let dirtyLease = try await publishHAPLease(dirtyArtifacts)
    try await installE1Capability(dirtyCapabilities)
    let dirtyJob = try await dirtyEngine.submit(
      hapRequest(lease: dirtyLease, key: "idem-residue-count"))
    let dirtyStatus = try await dirtyEngine.run(jobID: dirtyJob.jobID)
    XCTAssertEqual(dirtyStatus.state, "succeeded")
    XCTAssertEqual(dirtyStatus.outstandingResidueCount, 1)

    let clean = ScriptedDispatcher()
    let (cleanEngine, cleanCapabilities, cleanArtifacts) = try makeEngine(dispatcher: clean)
    let cleanLease = try await publishHAPLease(cleanArtifacts)
    try await installE1Capability(cleanCapabilities)
    let cleanJob = try await cleanEngine.submit(
      hapRequest(lease: cleanLease, key: "idem-residue-none"))
    let cleanStatus = try await cleanEngine.run(jobID: cleanJob.jobID)
    XCTAssertEqual(cleanStatus.state, "succeeded")
    XCTAssertEqual(cleanStatus.outstandingResidueCount ?? 0, 0)

    // The promise made in r3: visibility comes from the count, not from a
    // new terminal state.
    XCTAssertNil(JobState(rawValue: "succeededWithResidue"))
  }

  /// DHA-RES-003: settling is decided by the readback, and the continue
  /// surface is a ledger lookup — not a way to name an uninstall target.
  func testBundleResidueSettlesOnlyWhenTheReadbackSaysItIsGone() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(packageInstalledAfterUninstall: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-residue-settle"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let recorded = try await engine.listCleanupDebt()
    let residue = try XCTUnwrap(recorded.first { $0.bundleName != nil })

    // Still installed: the record survives.
    let stubborn = ScriptedDispatcher(
      script: .init(packageInstalled: true, packageInstalledAfterUninstall: true))
    let (stubbornEngine, _, _) = try makeEngine(dispatcher: stubborn)
    _ = try await stubbornEngine.recoverPersistedJobs()
    let unsettled = try await stubbornEngine.continueCleanupDebt(
      jobID: residue.jobID, identity: residue.identity)
    XCTAssertNotEqual(unsettled.state, .settled)
    let stillRecorded = try await stubbornEngine.listCleanupDebt()
    XCTAssertFalse(stillRecorded.isEmpty)

    // Gone: the readback settles it without resending anything.
    let gone = ScriptedDispatcher(script: .init(packageInstalled: false))
    let (goneEngine, _, _) = try makeEngine(dispatcher: gone)
    _ = try await goneEngine.recoverPersistedJobs()
    let settled = try await goneEngine.continueCleanupDebt(
      jobID: residue.jobID, identity: residue.identity)
    XCTAssertEqual(settled.state, .settled)
    XCTAssertEqual(settled.identity, "bundle:com.example.demo")
    let remaining = try await goneEngine.listCleanupDebt()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testContinueRefusesAnIdentityThatIsNotInTheLedger() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(packageInstalledAfterUninstall: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-residue-unknown-identity"))
    _ = try await engine.run(jobID: acceptance.jobID)

    do {
      _ = try await engine.continueCleanupDebt(
        jobID: acceptance.jobID, identity: "bundle:com.example.somethingelse")
      XCTFail("an unrecorded residue must not be actionable")
    } catch {}
    XCTAssertTrue(
      dispatcher.dispatchedActions.filter { $0 == "uninstallPackage" }.count == 1,
      "the refusal must not dispatch a second uninstall")
  }
}

// MARK: - CHG-2026-049 r4: multi-package leases

extension DiagnosticsAndHAPContractTests {
  /// DHA-MULTI-002: a set is not a weaker check. Every additional lease goes
  /// through the same binding validation as the entry package, and one that
  /// belongs to another target stops the job before anything is dispatched.
  func testAdditionalLeaseBoundToAnotherTargetStopsBeforeDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let entryLease = try await publishHAPLease(artifacts)
    let foreign = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-foreign", sessionID: "session-input-foreign",
        stepID: "publish-hap", name: "feature.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-OTHER", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "e", count: 64)),
        contents: Data("foreign-feature".utf8)))
    let foreignLease = try await artifacts.leaseReference(
      jobID: foreign.jobID, artifactID: foreign.artifactID)
    try await installE1Capability(capabilities)

    do {
      _ = try await engine.submit(
        hapRequest(
          lease: entryLease, key: "idem-multi-foreign",
          extraInputs: ",\n          \"additionalHapArtifactLeases\": [\"\(foreignLease)\"]"))
      XCTFail("a lease bound to another target must not be admitted")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, _) = error else {
        return XCTFail("expected a rejection, got \(error)")
      }
      XCTAssertEqual(code, .invalidInput)
    }
    // Refused before authorization: nothing dispatched, nothing consumed.
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
    let issued = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(issued?.consumptionCount, 0)
  }

  /// The positive shape: two matching leases send in order into one
  /// directory, install once, and clean up to nothing.
  func testMatchingLeasesSendInOrderAndInstallOnce() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let entryLease = try await publishHAPLease(artifacts)
    let feature = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap",
        stepID: "publish-hap", name: "feature1.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 7,
          stableIdentitySHA256:
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"),
        contents: Data("feature-module".utf8)))
    let featureLease = try await artifacts.leaseReference(
      jobID: feature.jobID, artifactID: feature.artifactID)
    try await installE1Capability(capabilities)

    let acceptance = try await engine.submit(
      hapRequest(
        lease: entryLease, key: "idem-multi-ok",
        extraInputs: ",\n          \"additionalHapArtifactLeases\": [\"\(featureLease)\"]"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("sendPackageSet"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("installPackageSet"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanupPackageSet"))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("sendArtifact"),
      "the single-package leg must not also run")
  }
}

// MARK: - CHG-2026-049 r5: screenshot

extension DiagnosticsAndHAPContractTests {
  /// DHA-SHOT-002: opt-in, like every capture leg added since r2.
  func testScreenshotInputIsWhatRaisesTheEffect() async throws {
    let quiet = ScriptedDispatcher()
    let (plainEngine, plainCapabilities, plainArtifacts) = try makeEngine(dispatcher: quiet)
    let plain = try await plainEngine.submit(
      captureRequest(withTrace: false, key: "idem-shot-absent"))
    let plainStatus = try await plainEngine.run(jobID: plain.jobID)
    XCTAssertEqual(plainStatus.state, "succeeded")
    XCTAssertFalse(quiet.dispatchedActions.contains("captureScreenshot"))
    let plainEvidence = try await plainEngine.evidenceSnapshot(jobID: plain.jobID)
    XCTAssertEqual(plainEvidence.authority?.kind, .defaultReadOnlyPolicy)
    let issuedForPlain = try await plainCapabilities.list()
    XCTAssertTrue(issuedForPlain.isEmpty)
    let plainShot = try await plainArtifacts.list(jobID: plain.jobID)
      .first { $0.name == "screenshot.png" }
    if let plainShot, case .published = plainShot.status {
      XCTFail("a request that did not ask for a screenshot cannot publish one")
    }

    let loud = ScriptedDispatcher()
    let (engine, capabilities, _) = try makeEngine(dispatcher: loud)
    let asked = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-shot-present", withScreenshot: true))
    let status = try await engine.run(jobID: asked.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(loud.dispatchedActions.contains("captureScreenshot"))
    let evidence = try await engine.evidenceSnapshot(jobID: asked.jobID)
    XCTAssertEqual(evidence.authority?.kind, .runtimeCapability)
    let issued = try await capabilities.list()
    XCTAssertEqual(issued.first?.capability.effectCeiling, .deviceMutation)
  }

  /// DHA-SHOT-003 (engine half): published bytes are the received bytes and
  /// they begin with the PNG magic; a non-PNG never becomes an artifact.
  func testScreenshotPublishesTheReceivedPNG() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-shot-publish", withScreenshot: true))
    _ = try await engine.run(jobID: acceptance.jobID)

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let shot = try XCTUnwrap(recorded.first { $0.name == "screenshot.png" })
    XCTAssertEqual(shot.status, .published)
    XCTAssertEqual(shot.mediaType, "image/png")
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: shot.artifactID, allowSensitive: true)
    XCTAssertEqual(
      Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))
  }

  func testNonPNGScreenshotIsNotPublished() async throws {
    var script = ScriptedDispatcher.Script()
    script.screenshotPayload = Data("<html>error</html>".utf8)
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-shot-badmagic", withScreenshot: true))
    _ = try? await engine.run(jobID: acceptance.jobID)
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    if case .published? = recorded.first(where: { $0.name == "screenshot.png" })?.status {
      XCTFail("bytes that are not a PNG must not be published as a screenshot")
    }
  }

  /// A device that wrote nothing fails on its own readback, before the
  /// receive leg ever runs.
  func testZeroByteScreenshotFailsOnTheDeviceReadback() async throws {
    var script = ScriptedDispatcher.Script()
    script.screenshotListing =
      "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/shot.png\n"
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-shot-empty", withScreenshot: true))
    _ = try? await engine.run(jobID: acceptance.jobID)
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("receiveArtifact"),
      "an empty capture must not proceed to the receive leg")
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    if case .published? = recorded.first(where: { $0.name == "screenshot.png" })?.status {
      XCTFail("a zero-byte capture must not publish")
    }
  }
}

extension DiagnosticsAndHAPContractTests {
  /// The same hole the screenshot leg exposed, on the leg r2 added: a
  /// capture that failed must not be followed by its receive.
  func testFailedComponentTreeCaptureSkipsItsReceive() async throws {
    var script = ScriptedDispatcher.Script()
    script.uiTreeListing =
      "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/tree.json\n"
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-tree-empty", withComponentTree: true))
    _ = try? await engine.run(jobID: acceptance.jobID)
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("receiveArtifact"),
      "a tree capture that failed must not be followed by its receive")
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    if case .published? = recorded.first(where: { $0.name == "ui-tree.json" })?.status {
      XCTFail("a zero-byte tree capture must not publish")
    }
  }
}

// MARK: - CHG-2026-049 r6: crash ledger

extension DiagnosticsAndHAPContractTests {
  /// DHA-CRASH-001 (engine half): the crash legs read, so unlike every
  /// other collection leg added since r2 they leave the plan at E0.
  func testCrashLedgerCaptureStaysE0() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-crash-index", withCrashLogs: true))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("captureCrashIndex"))

    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(
      evidence.authority?.kind, .defaultReadOnlyPolicy,
      "reading the crash ledger must not require a capability")
    let issued = try await capabilities.list()
    XCTAssertTrue(issued.isEmpty)

    // An empty ledger is a truthful artifact, not a missing one.
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let index = try XCTUnwrap(recorded.first { $0.name == "crash-index.txt" })
    XCTAssertEqual(index.status, .published)
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: index.artifactID, allowSensitive: true)
    XCTAssertTrue(String(data: bytes, encoding: .utf8)!.contains("No fault log exist."))
  }

  /// DHA-CRASH-003: a name the device does not have fails, and publishes
  /// nothing under the artifact's name.
  func testMissingCrashLogFailsWithoutPublishing() async throws {
    var script = ScriptedDispatcher.Script()
    script.crashLogText = "\ninvalid parameters.\n"
    let dispatcher = ScriptedDispatcher(script: script)
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-crash-missing",
        crashLogName: "jscrash-com.example.demo-20010056-20260731161809"))
    _ = try? await engine.run(jobID: acceptance.jobID)
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    if case .published? = recorded.first(where: { $0.name == "crash-log.txt" })?.status {
      XCTFail("a refused fetch must not publish a crash log")
    }
  }

  /// The healthy fetch publishes exactly the bytes the device returned.
  func testCrashLogPublishesTheDeviceBytes() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let name = "jscrash-com.example.demo-20010056-20260731161809"
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-crash-fetch", crashLogName: name))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let log = try XCTUnwrap(recorded.first { $0.name == "crash-log.txt" })
    XCTAssertEqual(log.status, .published)
    let bytes = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: log.artifactID, allowSensitive: true)
    let text = String(data: bytes, encoding: .utf8)!
    XCTAssertTrue(text.contains("Generated by HiviewDFX"))
    XCTAssertTrue(text.contains(name))
  }

  /// DHA-CRASH-002: a path-shaped name is refused before anything runs.
  func testPathShapedCrashLogNameIsRefusedAtAdmission() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(
        captureRequest(
          withTrace: false, key: "idem-crash-path",
          crashLogName: "../../data/log/faultlog/x"))
      XCTFail("a path-shaped fault log name must not be admitted")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, _) = error else {
        return XCTFail("expected a rejection, got \(error)")
      }
      XCTAssertEqual(code, .invalidInput)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }
}
