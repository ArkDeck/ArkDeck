@testable import ArkDeckClientKit
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The read-only device discovery plane behind the App's device list.
///
/// The load-bearing fact on both sides: listing candidates can never adopt.
/// The Runtime observation owner lists without adopting, and the App-facing decode
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
    var deviceInformationByConnectKey: [String: BootstrapDeviceInformation] = [:]
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceInformation(connectKey: String) async throws
      -> BootstrapDeviceInformation?
    {
      deviceInformationByConnectKey[connectKey]
    }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func makeHandler(
    candidates: [BootstrapCandidate],
    deviceInformationByConnectKey: [String: BootstrapDeviceInformation] = [:],
    bootstrapConfigured: Bool = true, physicalRelations: Bool = true
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
    let observation = ScriptedCandidates(candidates: candidates, deviceInformationByConnectKey: deviceInformationByConnectKey)
    let relations = physicalRelations ? candidates.enumerated().map { index, candidate in
      TargetUSBRelation(serial: candidate.connectKey, location: String(index + 1), attachmentID: UInt64(index + 1),
        vendorID: RockchipProbeEvidence.rockUSBVendorID, productID: RockchipHDCIntegrationProfile.dayu200NormalProductID)
    } : []
    let owner = bootstrapConfigured ? TargetObservationCoordinator(observation: observation, targetStore: targetStore,
      usbRelations: { relations }, nowUTC: { "2026-08-07T00:00:00Z" }) : nil
    let bootstrap =
      bootstrapConfigured
      ? DeviceBootstrapMachine(
        observation: ScriptedCandidates(
          candidates: candidates,
          deviceInformationByConnectKey: deviceInformationByConnectKey),
        targetStore: targetStore,
        nowUTC: { "2026-08-07T00:00:00Z" })
      : nil
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: [], nowUTC: { "2026-08-07T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap, targetObservations: owner)
    return (handler, targetStore)
  }

  private func frame(_ method: String, params: [String: JSONValue] = [:]) -> Data {
    try! CanonicalJSONEncoders.canonical().encode(JSONValue.object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("t"), "method": .string(method), "params": .object(params),
    ]))
  }

  private func adopt(_ handler: RuntimeControlPlaneHandler, candidate: String) async throws -> AgentWireProtocol.Response {
    let snapshot = await handler.handleFrame(frame("device.observations"))
    guard case .object(let fields)? = snapshot.result, case .array(let rows)? = fields["observations"],
      let row = rows.compactMap({ value -> [String: JSONValue]? in
        guard case .object(let row) = value, row["candidateKey"] == .string(candidate) else { return nil }
        return row
      }).first else { throw BootstrapError.observationFailed("fixture snapshot missing") }
    return await handler.handleFrame(frame("target.adopt", params: [
      "candidate": .string(candidate), "observationId": try XCTUnwrap(row["observationId"]),
      "observationGeneration": try XCTUnwrap(fields["snapshotGeneration"]),
    ]))
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
      presentation.candidates.contains { $0.deviceInformation != nil },
      "The connected-device row did not receive direct HDC device information")
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

    let response = await handler.handleFrame(frame("device.observations"))
    XCTAssertTrue(response.ok, String(describing: response.error))
    guard case .object(let snapshot)? = response.result, case .array(let rows)? = snapshot["observations"] else {
      return XCTFail("device.observations must return snapshot rows")
    }
    XCTAssertEqual(rows.count, 1)
    guard case .object(let row) = rows[0] else { return XCTFail("row must be an object") }
    XCTAssertEqual(row["authorizationState"], .string("Connected"))
    XCTAssertEqual(snapshot["observedAtUtc"], .string("2026-08-07T00:00:00Z"))
    XCTAssertEqual(snapshot["health"], .string("current"))
    XCTAssertEqual(row["adoptedTargetId"], .null)
    XCTAssertEqual(row["bindingRevision"], .null)

    XCTAssertEqual(
      try targetStore.list().count, 0,
      "the discovery read must not create a binding")
  }

  func testUnprovedObservationSnapshotsMintFreshIdentityAndRetiredMethodIsRefused() async throws {
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: "candidate-route", state: "Connected")
    ], physicalRelations: false)
    let first = await handler.handleFrame(frame("device.observations"))
    let second = await handler.handleFrame(frame("device.observations"))
    XCTAssertTrue(first.ok)
    XCTAssertTrue(second.ok)
    guard case .object(let firstSnapshot)? = first.result,
      case .object(let secondSnapshot)? = second.result,
      case .array(let firstRows)? = firstSnapshot["observations"],
      case .array(let secondRows)? = secondSnapshot["observations"],
      case .object(let firstRow)? = firstRows.first,
      case .object(let secondRow)? = secondRows.first
    else { return XCTFail("observation responses must carry snapshot rows") }
    XCTAssertEqual(firstSnapshot["snapshotGeneration"], .string("1"))
    XCTAssertEqual(secondSnapshot["snapshotGeneration"], .string("2"))
    XCTAssertEqual(firstSnapshot["health"], .string("current"))
    XCTAssertEqual(firstSnapshot["observedAtUtc"], .string("2026-08-07T00:00:00Z"))
    XCTAssertEqual(firstRow["observationContinuity"], .string("generationScoped"))
    guard case .string(let firstID)? = firstRow["observationId"] else {
      return XCTFail("the handler must publish a minted observation ID")
    }
    XCTAssertTrue(firstID.hasPrefix("obs-"))
    XCTAssertNotEqual(firstRow["observationId"], secondRow["observationId"])
    XCTAssertEqual(firstRow["candidateKey"], .string("candidate-route"))
    XCTAssertEqual(firstRow["adoptedTargetId"], .null)
    XCTAssertEqual(firstRow["bindingRevision"], .null)
    XCTAssertTrue(try targetStore.list().isEmpty, "snapshot reads must never adopt")

    let retired = await handler.handleFrame(frame("device.candidates"))
    XCTAssertFalse(retired.ok)
    XCTAssertEqual(retired.error?.code, "unknownMethod")
    XCTAssertTrue(try targetStore.list().isEmpty)

  }

  func testObservationMethodRejectsCallerFactsAndMissingBootstrap() async throws {
    let (handler, targetStore) = try makeHandler(candidates: [])
    for params in [
      "{\"useWarmSnapshot\":false}", "{\"observationId\":\"caller-issued\"}",
      "{\"snapshotGeneration\":1}", "{\"candidateKey\":\"caller-route\"}",
    ] {
      let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(params.utf8))
      let response = await handler.handleFrame(frame("device.observations", params: fields))
      XCTAssertFalse(response.ok)
      XCTAssertEqual(response.error?.code, "invalidInput")
    }
    XCTAssertTrue(try targetStore.list().isEmpty)
    let (unconfigured, _) = try makeHandler(candidates: [], bootstrapConfigured: false)
    let response = await unconfigured.handleFrame(frame("device.observations"))
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.error?.code, "unknownMethod")
  }

  // An adopted device joins its durable record; an unauthorized one carries
  // its raw reported state with no invented identity.
  func testAdoptedCandidateJoinsItsTargetRecord() async throws {
    let connected = String(repeating: "b", count: 32)
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: connected, state: "Connected"),
      BootstrapCandidate(connectKey: "7f2c091a445e21", state: "Unauthorized"),
    ])

    // Adopt only the exact Runtime observation with independent fixture USB proof.
    let adopt = try await adopt(handler, candidate: connected)
    XCTAssertTrue(adopt.ok, String(describing: adopt.error))
    let adoptedID = try XCTUnwrap(try targetStore.list().first?.targetID)

    let response = await handler.handleFrame(frame("device.observations"))
    guard case .object(let snapshot)? = response.result, case .array(let rows)? = snapshot["observations"] else {
      return XCTFail("device.observations must return snapshot rows")
    }
    XCTAssertEqual(rows.count, 2)
    var adoptedRow: [String: JSONValue]?
    var unauthorizedRow: [String: JSONValue]?
    for case .object(let row) in rows {
      if row["candidateKey"] == .string(connected) { adoptedRow = row }
      if row["authorizationState"] == .string("Unauthorized") { unauthorizedRow = row }
    }
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["adoptedTargetId"], .string(adoptedID))
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["bindingRevision"], .integer(1))
    XCTAssertEqual(try XCTUnwrap(unauthorizedRow)["adoptedTargetId"], .null)
  }

  func testConnectedCandidatesPublishDirectDeviceInformationWithoutAdoption() async throws {
    let connected = "5SM0125725000252"
    let unauthorized = "7f2c091a445e21"
    let (handler, targetStore) = try makeHandler(
      candidates: [
        BootstrapCandidate(connectKey: connected, state: "Connected"),
        BootstrapCandidate(connectKey: unauthorized, state: "Unauthorized"),
      ],
      deviceInformationByConnectKey: [
        connected: BootstrapDeviceInformation(
          name: "OpenHarmony Reference Device",
          systemVersion: "OpenHarmony-7.0.0.39",
          transport: "USB"),
        unauthorized: BootstrapDeviceInformation(
          name: "must-not-be-read", systemVersion: nil, transport: "USB"),
      ])

    let response = await handler.handleFrame(frame("device.observations"))
    guard case .object(let snapshot)? = response.result, case .array(let rows)? = snapshot["observations"] else {
      return XCTFail("device.observations must return snapshot rows")
    }
    let connectedRow = try XCTUnwrap(rows.compactMap { value -> [String: JSONValue]? in
      guard case .object(let row) = value, row["candidateKey"] == .string(connected) else {
        return nil
      }
      return row
    }.first)
    guard case .object(let information)? = connectedRow["deviceInformation"] else {
      return XCTFail("Connected candidates must carry direct device information")
    }
    XCTAssertEqual(information["name"], .string("OpenHarmony Reference Device"))
    XCTAssertEqual(information["systemVersion"], .string("OpenHarmony-7.0.0.39"))
    XCTAssertEqual(information["transport"], .string("USB"))
    XCTAssertEqual(connectedRow["adoptedTargetId"], .null)

    let unauthorizedRow = try XCTUnwrap(rows.compactMap { value -> [String: JSONValue]? in
      guard case .object(let row) = value, row["candidateKey"] == .string(unauthorized) else {
        return nil
      }
      return row
    }.first)
    XCTAssertEqual(
      unauthorizedRow["deviceInformation"], .null,
      "Unauthorized candidates must not receive device-scoped property commands")
    XCTAssertEqual(try targetStore.list().count, 0, "device information reads never adopt")
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

    let response = await handler.handleFrame(frame("device.observations"))
    XCTAssertTrue(response.ok)
    let data = try CanonicalJSONEncoders.canonical().encode(response)
    let presentation = DeviceCandidatesResponseDecoding.presentation(data)
    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.candidates.count, 1, "the App collapses transport faces for one target")
    let row = try XCTUnwrap(presentation.candidates.first)
    XCTAssertEqual(row.connectKey, aliasKey)
    XCTAssertEqual(row.state, "Connected")
    XCTAssertEqual(row.adoptedTargetID, canonical.targetID)
    XCTAssertEqual(row.bindingRevision, canonical.bindingRevision)

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
    guard case .object(let checks)? = report["checks"], case .object(let targetCheck)? = checks["target"] else { return XCTFail("doctor target check missing") }
    XCTAssertEqual(
      targetCheck["adoptedTargetCount"], .integer(1),
      "doctor must count selectable targets rather than retained alias history")
  }

  func testMissingBootstrapFailsLoudInsteadOfReturningAnEmptyList() async throws {
    let (handler, _) = try makeHandler(candidates: [], bootstrapConfigured: false)
    let response = await handler.handleFrame(frame("device.observations"))
    XCTAssertFalse(response.ok, "an unconfigured bootstrap must be an error, not an empty list")
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

    XCTAssertTrue(startup.contains("deviceList.refreshForStartup()"))
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
    ] {
      XCTAssertFalse(
        startup.contains(nonCritical),
        "device.observations must own the cold-start I/O lane: \(nonCritical)")
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
    XCTAssertTrue(deviceSource.contains("Task.detached(priority: .userInitiated)"))
    XCTAssertTrue(
      deviceSource.contains(
        "finishRefresh(current, generation: generation, isStartup: true)"))
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
    XCTAssertTrue(deviceSource.contains("candidate.deviceInformation?.name"))

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
    let start = try XCTUnwrap(daemon.range(of: "private func targetObservationRequest("))
    let end = try XCTUnwrap(daemon.range(of: "private static func targetObservationReference", range: start.lowerBound..<daemon.endIndex))
    let projection = String(daemon[start.lowerBound..<end.lowerBound])
    XCTAssertTrue(projection.contains("async let observationRead"))
    XCTAssertTrue(projection.contains("async let informationRead"))
    XCTAssertTrue(projection.contains("latestSucceededDeviceObservations()"))
    XCTAssertTrue(projection.contains("deviceInformationSnapshotForPresentation"))
    XCTAssertTrue(projection.contains("\"deviceInformation\""))
    XCTAssertTrue(projection.contains("\"observedFacts\""))

    let composition = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift"),
      encoding: .utf8)
    XCTAssertTrue(composition.contains("bootstrapObservation = ProviderBootstrapObservation("))
    let observation = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/ProviderBootstrapObservation.swift"),
      encoding: .utf8)
    XCTAssertTrue(observation.contains("property(.productName, connectKey: connectKey)"))
    XCTAssertTrue(observation.contains("property(.fullBuildVersion, connectKey: connectKey)"))
    XCTAssertTrue(observation.contains("connectKey: connectKey"))
    XCTAssertTrue(observation.contains("async let name = property("))
    XCTAssertTrue(observation.contains("async let systemVersion = property("))
  }
}
