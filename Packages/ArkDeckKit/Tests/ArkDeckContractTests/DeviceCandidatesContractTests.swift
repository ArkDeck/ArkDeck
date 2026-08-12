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
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-device-candidates-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
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
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let resolver = try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
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
      nowUTC: "2026-08-07T00:00:00Z").record
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(serial: aliasKey)
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-07T00:01:00Z").record
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
    XCTAssertEqual(targets.count, 1, "the alias remains durable but is not independently selectable")

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

  // Observed facts join only via a succeeded observe.device@1 job whose
  // evidence names the same target: identity mismatch, wrong operation and
  // non-terminal states all decorate nothing.
  func testObservedFactsJoinRequiresMatchingSucceededObservation() throws {
    let jobList = Data(
      #"""
      {"id":"t","ok":true,"result":[
        {"jobId":"job-old","operation":"observe.device@1","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-01T00:00:00Z"},
        {"jobId":"job-new","operation":"observe.device@1","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-06T00:00:00Z"},
        {"jobId":"job-running","operation":"observe.device@1","targetId":"t-1",
         "state":"running","finishedAtUtc":"2026-08-07T00:00:00Z"},
        {"jobId":"job-flash","operation":"flash.dayu200","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-07T00:00:00Z"},
        {"jobId":"job-other","operation":"observe.device@1","targetId":"t-2",
         "state":"succeeded","finishedAtUtc":"2026-08-05T00:00:00Z"}
      ]}
      """#.utf8)
    let latest = DeviceCandidatesResponseDecoding.latestSucceededObservationJobIDs(
      jobList, adoptedTargetIDs: ["t-1"])
    XCTAssertEqual(latest, ["t-1": "job-new"], "newest succeeded observation wins; t-2 is not adopted")

    let evidence = Data(
      #"""
      {"id":"t","ok":true,"result":{"jobId":"job-new","observation":{
        "targetId":"t-1","model":"DAYU200","firmware":"OpenHarmony 5.0.0.71",
        "transport":"USB","confirmedAtUtc":"2026-08-06T00:00:00Z"}}}
      """#.utf8)
    let facts = try XCTUnwrap(
      DeviceCandidatesResponseDecoding.observedFacts(evidence, targetID: "t-1"))
    XCTAssertEqual(facts.model, "DAYU200")
    XCTAssertEqual(facts.firmware, "OpenHarmony 5.0.0.71")
    XCTAssertEqual(facts.transport, "USB")

    XCTAssertNil(
      DeviceCandidatesResponseDecoding.observedFacts(evidence, targetID: "t-2"),
      "evidence observed on one device must never decorate another")

    let base = DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "abc", state: "Connected", adoptedTargetID: "t-1", bindingRevision: 1),
        DeviceCandidatePresentation(
          connectKey: "def", state: "Unauthorized", adoptedTargetID: nil, bindingRevision: nil),
      ])
    let decorated = DeviceCandidatesResponseDecoding.decorated(
      base, observedFactsByTargetID: ["t-1": facts])
    XCTAssertEqual(decorated.candidates[0].observedFacts, facts)
    XCTAssertNil(
      decorated.candidates[1].observedFacts,
      "an unadopted candidate carries no observation")
  }

  func testApplicationFacadeOwnsTheBoundedAuthorizationTimeoutAndReadyVerdict() async throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let state = stateDirectory.appendingPathComponent("device-authorization-state.txt")
    try Data().write(to: state)
    let provider = DeviceListApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-devices", "--ui-test-device-poll-fast",
      "--ui-test-fixture-state", state.path,
    ])

    let timedOut = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(timedOut.authorization, .timedOut)
    XCTAssertEqual(timedOut.presentation.candidates.first(where: {
      $0.connectKey == "7f2c091a445e21"
    })?.state, "Unauthorized")

    try Data("--ui-test-device-authorized".utf8).write(to: state)
    let ready = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(ready.authorization, .ready)
    XCTAssertTrue(ready.presentation.candidates.first(where: {
      $0.connectKey == "7f2c091a445e21"
    })?.isAuthorized == true)
  }

  // The facade's provider protocol carries candidate, historical decoration
  // and authorization reads only; no method can name a Runtime write.
  func testApplicationSurfaceCannotNameAWriteMethod() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    let protocolStart = try XCTUnwrap(
      source.range(of: "public protocol DeviceListApplicationProviding: Sendable {")?.upperBound)
    let protocolEnd = try XCTUnwrap(
      source.range(of: "public enum DeviceListApplicationFacade", range: protocolStart..<source.endIndex)?
        .lowerBound)
    let protocolBody = String(source[protocolStart..<protocolEnd])
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 3)
    XCTAssertTrue(protocolBody.contains("func refreshCandidates()"))
    XCTAssertTrue(protocolBody.contains("func enrichCandidates("))
    XCTAssertTrue(protocolBody.contains("func waitForAuthorization(connectKey: String)"))
    XCTAssertTrue(source.contains("method: \"device.candidates\""))
    for forbidden in [
      "method: \"target.adopt\"", "method: \"job.submit\"", "method: \"job.cancel\"",
    ] {
      XCTAssertFalse(source.contains(forbidden), forbidden)
    }
  }

  func testAppColdStartRefreshesVisibleShellFactsAndDefersHiddenWorkspaces() throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let source = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    let taskStart = try XCTUnwrap(source.range(of: ".task {")?.upperBound)
    let taskEnd = try XCTUnwrap(
      source.range(of: ".defaultSize", range: taskStart..<source.endIndex)?.lowerBound)
    let startup = String(source[taskStart..<taskEnd])

    let deviceStart = try XCTUnwrap(
      startup.range(of: "deviceList.refreshForStartup()")?.lowerBound)
    let historyStart = try XCTUnwrap(
      startup.range(of: "runtimeHistory.refresh()")?.lowerBound)
    let devicePublished = try XCTUnwrap(
      startup.range(of: "await initialDeviceRefresh")?.lowerBound)
    let updateStart = try XCTUnwrap(
      startup.range(of: "autoUpdate.startup()")?.lowerBound)

    XCTAssertLessThan(deviceStart, historyStart)
    XCTAssertLessThan(historyStart, devicePublished)
    XCTAssertLessThan(devicePublished, updateStart)
    XCTAssertFalse(
      startup.contains("deviceList.refresh()"),
      "startup must not enqueue the sidebar read behind unrelated workspaces")
    for deferred in [
      "hdcDiagnostics.refresh()",
      "overviewCapabilities.refresh()",
      "flashWorkspace.refresh()",
      "uiDumpWorkspace.refresh()",
      "debugWorkspace.refresh()",
      "traceWorkspace.refresh()",
      "automationWorkspace.refresh()",
    ] {
      XCTAssertFalse(
        startup.contains(deferred),
        "cold start must defer selection-owned projection: \(deferred)")
    }

    XCTAssertTrue(source.contains(".onChange(of: storedSelection, initial: true)"))
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

  func testAppPublishesCandidateIdentityBeforeHistoricalDecoration() throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let source = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Devices/DeviceWorkspace.swift"),
      encoding: .utf8)
    let finishStart = try XCTUnwrap(
      source.range(of: "private func finishRefresh(generation:")?.lowerBound)
    let candidateRead = try XCTUnwrap(
      source.range(of: "provider.refreshCandidates()", range: finishStart..<source.endIndex)?
        .lowerBound)
    let candidatePublish = try XCTUnwrap(
      source.range(of: "presentation = base", range: candidateRead..<source.endIndex)?.lowerBound)
    let enrichment = try XCTUnwrap(
      source.range(of: "provider.enrichCandidates(base)", range: candidatePublish..<source.endIndex)?
        .lowerBound)

    XCTAssertLessThan(candidateRead, candidatePublish)
    XCTAssertLessThan(candidatePublish, enrichment)
    XCTAssertTrue(
      String(source[candidatePublish..<enrichment]).contains("Task {"),
      "historical decoration must run after the startup-critical candidate publication")
  }
}
