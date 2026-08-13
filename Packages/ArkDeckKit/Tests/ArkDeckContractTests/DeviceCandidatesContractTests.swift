import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The read-only device discovery plane behind the App's device list.
///
/// The load-bearing fact on both sides: listing candidates can never adopt.
/// The daemon method calls the bootstrap's enumeration only (`advance` is the
/// path that adopts a single Connected candidate), and the App-facing decode
/// reports incomplete facts as a failure instead of a silently empty list.
final class DeviceCandidatesContractTests: XCTestCase {
  private static let realDeviceLatencyEnvironmentKey =
    "ARKDECK_REAL_DEVICE_CANDIDATE_LATENCY_ACCEPTANCE"
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-device-candidates-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct ScriptedCandidates: BootstrapObservationPort {
    let candidates: [BootstrapCandidate]
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func makeHandler(
    candidates: [BootstrapCandidate],
    bootstrapConfigured: Bool = true
  ) throws -> (RuntimeControlPlaneHandler, RuntimeTargetStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let resolver = try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(resolver: resolver),
      capabilityStore: capabilityStore,
      nowUTC: { "2026-08-07T00:00:00Z" })
    let bootstrap =
      bootstrapConfigured
      ? DeviceBootstrapMachine(
        observation: ScriptedCandidates(candidates: candidates),
        targetStore: targetStore,
        nowUTC: { "2026-08-07T00:00:00Z" })
      : nil
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: [], nowUTC: { "2026-08-07T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap)
    return (handler, targetStore)
  }

  private func frame(_ method: String) -> Data {
    Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"t\",\"method\":\"\(method)\"}".utf8)
  }

  /// Opt-in real Runtime acceptance. The App begins this exact read while its
  /// first window is being built, so the request must stay below the launch
  /// budget without embedding or printing a hardware identifier.
  func testRealRuntimePublishesConnectedDeviceInformationWithinStartupBudget() async throws {
    guard
      ProcessInfo.processInfo.environment[
        Self.realDeviceLatencyEnvironmentKey
      ] == "1"
    else {
      throw XCTSkip(
        "Set \(Self.realDeviceLatencyEnvironmentKey)=1 for real-device latency acceptance")
    }

    let provider = DeviceListApplicationFacade.make(arguments: [])
    let clock = ContinuousClock()
    let startedAt = clock.now
    let presentation = await provider.startupCandidates()
    let elapsed = startedAt.duration(to: clock.now)

    guard case .available = presentation.availability else {
      return XCTFail("The production Runtime did not publish an available candidate list")
    }
    XCTAssertFalse(presentation.candidates.isEmpty, "No connected device candidate was published")
    XCTAssertTrue(
      presentation.candidates.contains { $0.observedFacts != nil },
      "The connected-device row did not receive its historical model / firmware / transport")
    XCTAssertLessThanOrEqual(
      elapsed, .milliseconds(1_250),
      "complete device information exceeded its 1.25-second share of the cold-start budget")
  }

  // Listing candidates adopts nothing — even when exactly one Connected
  // candidate is present, which is precisely the input `advance` would adopt.
  func testEnumerationNeverAdoptsEvenForASingleConnectedCandidate() async throws {
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: String(repeating: "a", count: 32), state: "Connected")
    ])

    let response = await handler.handleFrame(frame("device.candidates"))
    XCTAssertTrue(response.ok, String(describing: response.error))
    guard case .array(let rows)? = response.result else {
      return XCTFail("device.candidates must return an array")
    }
    XCTAssertEqual(rows.count, 1)
    guard case .object(let row) = rows[0] else { return XCTFail("row must be an object") }
    XCTAssertEqual(row["state"], .string("Connected"))
    XCTAssertEqual(row["stateObservedAtUtc"], .string("2026-08-07T00:00:00Z"))
    XCTAssertEqual(row["stateObservationHealth"], .string("current"))
    XCTAssertEqual(row["adoptedTargetId"], .null)
    XCTAssertEqual(row["bindingRevision"], .null)

    XCTAssertEqual(
      try targetStore.list().count, 0,
      "the discovery read must not create a binding")
  }

  // An adopted device joins its durable record; an unauthorized one carries
  // its raw reported state with no invented identity.
  func testAdoptedCandidateJoinsItsTargetRecord() async throws {
    let connected = String(repeating: "b", count: 32)
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: connected, state: "Connected"),
      BootstrapCandidate(connectKey: "7f2c091a445e21", state: "Unauthorized"),
    ])

    // Adopt the connected one through the real bootstrap path.
    let adopt = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"a","method":"target.adopt",\
        "params":{"candidate":"\(connected)"}}
        """.utf8))
    XCTAssertTrue(adopt.ok, String(describing: adopt.error))
    let adoptedID = try XCTUnwrap(try targetStore.list().first?.targetID)

    let response = await handler.handleFrame(frame("device.candidates"))
    guard case .array(let rows)? = response.result else {
      return XCTFail("device.candidates must return an array")
    }
    XCTAssertEqual(rows.count, 2)
    var adoptedRow: [String: JSONValue]?
    var unauthorizedRow: [String: JSONValue]?
    for case .object(let row) in rows {
      if row["connectKey"] == .string(connected) { adoptedRow = row }
      if row["state"] == .string("Unauthorized") { unauthorizedRow = row }
    }
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["adoptedTargetId"], .string(adoptedID))
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["bindingRevision"], .integer(1))
    XCTAssertEqual(try XCTUnwrap(unauthorizedRow)["adoptedTargetId"], .null)
  }

  func testResolvedAliasCandidateCollapsesIntoTheCanonicalTarget() async throws {
    let canonicalKey = "canonical-hdc-address"
    let aliasKey = "post-flash-hdc-address"
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: canonicalKey, state: "Offline"),
      BootstrapCandidate(connectKey: aliasKey, state: "Connected"),
    ])
    let canonical = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: canonicalKey, toolVersion: "3.2.0f",
      nowUTC: "2026-08-07T00:00:00Z"
    ).record
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(serial: aliasKey)
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-07T00:01:00Z"
    ).record
    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: canonical.targetID,
        canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: canonical.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity, routedUSBTopology: "42",
        establishingFlashJobID: "job-0123456789abcdef0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "b", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [], establishedAtUTC: "2026-08-07T00:10:00Z"))

    let candidates = await handler.handleFrame(frame("device.candidates"))
    guard case .array(let rows)? = candidates.result else {
      return XCTFail("device.candidates must return an array")
    }
    XCTAssertEqual(rows.count, 1, "two transport faces must not duplicate the same target")
    guard case .object(let row) = rows[0] else { return XCTFail("row must be an object") }
    XCTAssertEqual(row["connectKey"], .string(aliasKey))
    XCTAssertEqual(row["state"], .string("Connected"))
    XCTAssertEqual(row["adoptedTargetId"], .string(canonical.targetID))
    XCTAssertEqual(row["bindingRevision"], .integer(Int64(canonical.bindingRevision)))

    let targetList = await handler.handleFrame(frame("target.list"))
    guard case .array(let targets)? = targetList.result else {
      return XCTFail("target.list must return an array")
    }
    XCTAssertEqual(
      targets.count, 1, "the alias remains durable but is not independently selectable")

    let doctor = await handler.handleFrame(frame("doctor"))
    guard case .object(let report)? = doctor.result else {
      return XCTFail("doctor must return a report")
    }
    XCTAssertEqual(
      report["adoptedTargetCount"], .integer(1),
      "doctor must count selectable targets rather than retained alias history")
  }

  func testMissingBootstrapFailsLoudInsteadOfReturningAnEmptyList() async throws {
    let (handler, _) = try makeHandler(candidates: [], bootstrapConfigured: false)
    let response = await handler.handleFrame(frame("device.candidates"))
    XCTAssertFalse(response.ok, "an unconfigured bootstrap must be an error, not an empty list")
  }

  // MARK: - App-facing decode

  func testDecodeReportsIncompleteFactsInsteadOfAnEmptyList() throws {
    let unreadable = DeviceCandidatesResponseDecoding.presentation(Data("not json".utf8))
    guard case .unavailable = unreadable.availability else {
      return XCTFail("unreadable bytes must be unavailable, not empty")
    }

    let missingKey = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":true,"result":[{"state":"Connected"}]}"#.utf8))
    guard case .unavailable = missingKey.availability else {
      return XCTFail("a candidate without a connect key must be unavailable, not dropped")
    }

    let error = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":false,"error":{"message":"boom"}}"#.utf8))
    guard case .unavailable(let reason) = error.availability else {
      return XCTFail("a runtime error must surface its message")
    }
    XCTAssertEqual(reason, "boom")

    let empty = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":true,"result":[]}"#.utf8))
    XCTAssertEqual(empty.availability, .available)
    XCTAssertTrue(empty.candidates.isEmpty, "a genuinely empty list stays an empty list")

    let full = DeviceCandidatesResponseDecoding.presentation(
      Data(
        #"""
        {"id":"t","ok":true,"result":[
          {"connectKey":"abc","state":"Connected","adoptedTargetId":"t-1","bindingRevision":3},
          {"connectKey":"def","state":"Unauthorized","adoptedTargetId":null,"bindingRevision":null}
        ]}
        """#.utf8))
    XCTAssertEqual(full.availability, .available)
    XCTAssertEqual(full.candidates.count, 2)
    XCTAssertEqual(full.candidates[0].adoptedTargetID, "t-1")
    XCTAssertEqual(full.candidates[0].bindingRevision, 3)
    XCTAssertTrue(full.candidates[0].isAdopted)
    XCTAssertTrue(full.candidates[1].needsPhysicalTrust)
    XCTAssertNil(full.candidates[1].adoptedTargetID)
  }

  // The one candidate projection carries only observation facts bound to the
  // same target. A mismatched nested target is ignored rather than decorating
  // the wrong physical device.
  func testObservedFactsProjectionRequiresMatchingTarget() throws {
    let response = Data(
      #"""
      {"id":"t","ok":true,"result":[
        {"connectKey":"abc","state":"Connected","adoptedTargetId":"t-1",
         "bindingRevision":3,"observedFacts":{"targetId":"t-1","model":"DAYU200",
         "firmware":"OpenHarmony 5.0.0.71","transport":"USB",
         "confirmedAtUtc":"2026-08-06T00:00:00Z"}},
        {"connectKey":"def","state":"Connected","adoptedTargetId":"t-2",
         "bindingRevision":1,"observedFacts":{"targetId":"t-1","model":"WRONG"}}
      ]}
      """#.utf8)
    let presentation = DeviceCandidatesResponseDecoding.presentation(response)
    let facts = try XCTUnwrap(presentation.candidates[0].observedFacts)
    XCTAssertEqual(facts.model, "DAYU200")
    XCTAssertEqual(facts.firmware, "OpenHarmony 5.0.0.71")
    XCTAssertEqual(facts.transport, "USB")
    XCTAssertNil(
      presentation.candidates[1].observedFacts,
      "facts observed on one target must never decorate another")
  }

  func testStaleCandidateObservationCannotBePresentedAsAuthorized() throws {
    let response = Data(
      #"{"id":"t","ok":true,"result":[{"connectKey":"abc","state":"Connected","stateObservedAtUtc":"2026-08-13T00:00:00Z","stateObservationHealth":"stale","adoptedTargetId":"t-1","bindingRevision":1}]}"#
        .utf8)
    let presentation = DeviceCandidatesResponseDecoding.presentation(response)
    let candidate = try XCTUnwrap(presentation.candidates.first)
    XCTAssertEqual(candidate.state, "Connected", "the raw historical HDC state is preserved")
    XCTAssertEqual(candidate.stateObservedAtUTC, "2026-08-13T00:00:00Z")
    XCTAssertEqual(candidate.stateObservationHealth, .stale)
    XCTAssertFalse(
      candidate.isAuthorized,
      "a failed follow-up probe must not project a cached Connected state as current readiness")
  }

  func testApplicationFacadeOwnsTheBoundedAuthorizationTimeoutAndReadyVerdict() async throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let state = stateDirectory.appending(path: "device-authorization-state.txt")
    try Data().write(to: state)
    let provider = DeviceListApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-devices", "--ui-test-device-poll-fast",
      "--ui-test-fixture-state", state.path,
    ])

    let timedOut = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(timedOut.authorization, .timedOut)
    XCTAssertEqual(
      timedOut.presentation.candidates.first(where: {
        $0.connectKey == "7f2c091a445e21"
      })?.state, "Unauthorized")

    try Data("--ui-test-device-authorized".utf8).write(to: state)
    let ready = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(ready.authorization, .ready)
    XCTAssertTrue(
      ready.presentation.candidates.first(where: {
        $0.connectKey == "7f2c091a445e21"
      })?.isAuthorized == true)
  }

  // The facade's provider protocol carries the joined candidate projection
  // and authorization reads only; no method can name a Runtime write.
  func testApplicationSurfaceCannotNameAWriteMethod() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    let protocolStart = try XCTUnwrap(
      source.range(of: "public protocol DeviceListApplicationProviding: Sendable {")?.upperBound)
    let protocolEnd = try XCTUnwrap(
      source.range(
        of: "public enum DeviceListApplicationFacade", range: protocolStart..<source.endIndex)?
        .lowerBound)
    let protocolBody = String(source[protocolStart..<protocolEnd])
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 3)
    XCTAssertTrue(protocolBody.contains("func startupCandidates()"))
    XCTAssertTrue(protocolBody.contains("func refreshCandidates()"))
    XCTAssertTrue(protocolBody.contains("func waitForAuthorization(connectKey: String)"))
    XCTAssertTrue(source.contains("method: \"device.candidates\""))
    XCTAssertFalse(source.contains("method: \"job.list\""))
    XCTAssertFalse(source.contains("method: \"job.evidence\""))
    for forbidden in [
      "method: \"target.adopt\"", "method: \"job.submit\"", "method: \"job.cancel\"",
    ] {
      XCTAssertFalse(source.contains(forbidden), forbidden)
    }
  }

  func testAppColdStartPublishesDevicesBeforeSecondaryAndHiddenWorkspaces() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let source = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    let deviceSource = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Devices/DeviceWorkspace.swift"),
      encoding: .utf8)
    let storeStart = try XCTUnwrap(
      source.range(of: "private final class ArkDeckAppModelStore")?.lowerBound)
    let storeEnd = try XCTUnwrap(
      source.range(of: "@main", range: storeStart..<source.endIndex)?.lowerBound)
    let startup = String(source[storeStart..<storeEnd])

    XCTAssertTrue(startup.contains("Task { [deviceList] in"))
    XCTAssertTrue(startup.contains("await deviceList.refreshForStartup()"))
    for nonCritical in [
      "runtimeHistory.refresh()",
      "autoUpdate.startup()",
      "ApplicationIconChoice.applyStoredSelection()",
      "hdcDiagnostics.refresh()",
      "overviewCapabilities.refresh()",
      "flashWorkspace.refresh()",
      "uiDumpWorkspace.refresh()",
      "debugWorkspace.refresh()",
      "traceWorkspace.refresh()",
      "automationWorkspace.refresh()",
    ] {
      XCTAssertFalse(
        startup.contains(nonCritical),
        "device.candidates must own the cold-start I/O lane: \(nonCritical)")
    }

    let secondaryStart = try XCTUnwrap(
      source.range(of: ".task(id: deviceList.startupInformationReady) {")?.upperBound)
    let secondaryEnd = try XCTUnwrap(
      source.range(of: ".alert(", range: secondaryStart..<source.endIndex)?.lowerBound)
    let secondary = String(source[secondaryStart..<secondaryEnd])
    XCTAssertTrue(secondary.contains("guard deviceList.startupInformationReady else { return }"))
    XCTAssertTrue(secondary.contains("await Task.yield()"))
    XCTAssertTrue(secondary.contains("runtimeHistory.refresh()"))
    XCTAssertTrue(secondary.contains("autoUpdate.startup()"))
    XCTAssertTrue(secondary.contains("ApplicationIconChoice.applyStoredSelection()"))
    XCTAssertTrue(secondary.contains("refreshVisibleProjection(for: storedSelection)"))
    XCTAssertTrue(
      deviceSource.contains(
        "await finishRefresh(generation: generation, isStartup: true)"))
    XCTAssertTrue(deviceSource.contains("await provider.startupCandidates()"))
    XCTAssertTrue(deviceSource.contains("await provider.refreshCandidates()"))
    XCTAssertTrue(deviceSource.contains("presentation = current"))
    XCTAssertTrue(deviceSource.contains("startupInformationReady = true"))
    XCTAssertFalse(deviceSource.contains("enrichCandidates"))

    XCTAssertFalse(source.contains(".onChange(of: storedSelection, initial: true)"))
    for lazyModel in [
      "lazy var hdcDiagnostics",
      "lazy var overviewCapabilities",
      "lazy var flashWorkspace",
      "lazy var uiDumpWorkspace",
      "lazy var debugWorkspace",
      "lazy var traceWorkspace",
      "lazy var automationWorkspace",
      "lazy var settingsWorkspace",
    ] {
      XCTAssertTrue(
        source.contains(lazyModel),
        "offscreen model must be initialized on first visible use: \(lazyModel)")
    }

    let updaterStart = try XCTUnwrap(
      source.range(of: "private final class AutoUpdateViewModel")?.lowerBound)
    let updaterEnd = try XCTUnwrap(
      source.range(
        of: "private struct FinderUpdateArtifactRevealer", range: updaterStart..<source.endIndex)?
        .lowerBound)
    let updater = String(source[updaterStart..<updaterEnd])
    let updaterInitStart = try XCTUnwrap(updater.range(of: "init() {")?.lowerBound)
    let updaterStartupStart = try XCTUnwrap(
      updater.range(of: "func startup()", range: updaterInitStart..<updater.endIndex)?.lowerBound)
    XCTAssertFalse(
      updater[updaterInitStart..<updaterStartupStart].contains(
        "AutoUpdateApplicationFacade.make()"),
      "the updater must not scan storage and diagnostics while SwiftUI constructs the App")
    XCTAssertTrue(updater[updaterStartupStart...].contains("Task.detached(priority: .utility)"))
    XCTAssertTrue(updater[updaterStartupStart...].contains("AutoUpdateApplicationFacade.make()"))

    // macOS 26 Observation scopes updates to the properties each boundary
    // actually reads. Device discovery remains a Shell dependency because it
    // owns first-screen rows; history, recovery and update changes terminate
    // in smaller child views instead of invalidating the whole split view.
    XCTAssertTrue(source.contains("@Observable\nprivate final class ArkDeckAppModelStore"))
    XCTAssertTrue(source.contains("@State private var models = ArkDeckAppModelStore()"))
    XCTAssertFalse(source.contains("@StateObject private var models"))
    XCTAssertTrue(source.contains("private struct RuntimeHistoryJobInspector: View"))
    XCTAssertTrue(source.contains("private struct RuntimeRecoveryBanner: View"))
    XCTAssertTrue(source.contains("private struct UpdateAttentionToolbarContent: ToolbarContent"))
    let shellStart = try XCTUnwrap(
      source.range(of: "private struct AppShellView: View")?.lowerBound)
    let shellEnd = try XCTUnwrap(
      source.range(of: "private struct SettingsSceneLoader", range: shellStart..<source.endIndex)?
        .lowerBound)
    let shell = String(source[shellStart..<shellEnd])
    for broadObservation in [
      "@ObservedObject private var autoUpdate",
      "@ObservedObject private var runtimeHistory",
      "@ObservedObject private var deviceList",
    ] {
      XCTAssertFalse(shell.contains(broadObservation), broadObservation)
    }
    XCTAssertTrue(deviceSource.contains("@Observable\nfinal class DeviceListViewModel"))

    // Apple's App Launch template supplies process and first-frame timing;
    // these Points of Interest make the product's device milestones visible
    // in the same trace without adding startup I/O.
    XCTAssertTrue(source.contains("OSSignposter("))
    XCTAssertTrue(source.contains("category: .pointsOfInterest"))
    for milestone in [
      "Startup Models Ready",
      "First Window Appeared",
      "Device Candidates Published",
      "Complete Device Information Ready",
      "Complete Device Information Displayed",
    ] {
      XCTAssertTrue(source.contains(milestone), milestone)
    }
    XCTAssertTrue(deviceSource.contains("AppStartupPerformance.beginDeviceDiscovery()"))
    XCTAssertTrue(deviceSource.contains("AppStartupPerformance.deviceCandidatesPublished()"))
    XCTAssertTrue(deviceSource.contains("AppStartupPerformance.deviceInformationReady()"))

    let demandStart = try XCTUnwrap(
      source.range(
        of: "private func refreshVisibleProjection(for storageValue:")?.lowerBound)
    let demandEnd = try XCTUnwrap(
      source.range(of: "private var detailTitle:", range: demandStart..<source.endIndex)?
        .lowerBound)
    let demand = String(source[demandStart..<demandEnd])
    for visibleRefresh in [
      "hdcDiagnostics.refresh()",
      "overviewCapabilities.refresh()",
      "runtimeHistory.refresh()",
      "flashWorkspace.refresh()",
      "uiDumpWorkspace.refresh()",
      "debugWorkspace.refresh()",
      "traceWorkspace.refresh()",
      "automationWorkspace.refresh()",
    ] {
      XCTAssertTrue(
        demand.contains(visibleRefresh),
        "selecting a projection must refresh it: \(visibleRefresh)")
    }
  }

  func testProductTargetsOnlyMacOS26() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let package = try String(
      contentsOf: repository.appending(path: "Packages/ArkDeckKit/Package.swift"),
      encoding: .utf8)
    let baselinePackage = try String(
      contentsOf: repository.appending(path: "Packages/ArkDeckKit/APIBaseline/Package.swift"),
      encoding: .utf8)
    let project = try String(
      contentsOf: repository.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    let processExecutor = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift"),
      encoding: .utf8)
    let ptyExecutor = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckProcess/IdentityBoundPTYExecutor.swift"),
      encoding: .utf8)

    for manifest in [package, baselinePackage] {
      XCTAssertTrue(manifest.hasPrefix("// swift-tools-version: 6.3"))
      XCTAssertTrue(manifest.contains("platforms: [.macOS(.v26)]"))
      XCTAssertFalse(manifest.contains(".macOS(.v14)"))
    }
    XCTAssertEqual(project.components(separatedBy: "MACOSX_DEPLOYMENT_TARGET = 26.0;").count - 1, 4)
    XCTAssertFalse(project.contains("MACOSX_DEPLOYMENT_TARGET = 14.0;"))
    for executor in [processExecutor, ptyExecutor] {
      XCTAssertTrue(executor.contains("posix_spawn_file_actions_addchdir("))
      XCTAssertFalse(executor.contains("posix_spawn_file_actions_addchdir_np("))
    }
  }

  func testAppUsesModernXcode26SafetyAndConcurrencyDefaults() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let project = try String(
      contentsOf: repository.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)

    XCTAssertEqual(
      project.components(separatedBy: "STRING_CATALOG_GENERATE_SYMBOLS = YES;").count - 1,
      2)
    XCTAssertEqual(
      project.components(separatedBy: "SWIFT_STRICT_MEMORY_SAFETY = YES;").count - 1,
      2)
    XCTAssertEqual(
      project.components(separatedBy: "SWIFT_APPROACHABLE_CONCURRENCY = YES;").count - 1,
      2)
    XCTAssertEqual(
      project.components(separatedBy: "SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;").count - 1,
      2)

    let appRoot = repository.appending(path: "ArkDeckApp")
    let swiftSources = try XCTUnwrap(
      FileManager.default.enumerator(
        at: appRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]
    ).filter { $0.pathExtension == "swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")
    let unsafeFormatting = try NSRegularExpression(
      pattern: #"String\s*\(\s*format:|String\s*\.localizedStringWithFormat"#)
    XCTAssertNil(
      unsafeFormatting.firstMatch(
        in: swiftSources, range: NSRange(swiftSources.startIndex..., in: swiftSources)))
  }

  func testDaemonBuildsOneConcurrentDeviceInformationProjection() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let daemon = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift"),
      encoding: .utf8)
    let candidates = try XCTUnwrap(daemon.range(of: "case \"device.candidates\":"))
    let adoption = try XCTUnwrap(
      daemon.range(of: "case \"target.adopt\":", range: candidates.lowerBound..<daemon.endIndex))
    let projection = String(daemon[candidates.lowerBound..<adoption.lowerBound])

    XCTAssertTrue(projection.contains("async let candidateRead"))
    XCTAssertTrue(projection.contains("async let observationRead"))
    XCTAssertTrue(projection.contains("latestSucceededDeviceObservations()"))
    XCTAssertTrue(projection.contains("\"observedFacts\""))
  }
}
