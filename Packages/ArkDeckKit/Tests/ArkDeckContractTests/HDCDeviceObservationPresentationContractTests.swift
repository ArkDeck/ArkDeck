import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

/// CHG-2026-022 / TASK-OBS-001R and CHG-2026-043 / TASK-HSO-002
/// TEST-OBS-DEVICE-PRESENTATION-001, DP1-DP19, and CHG-2026-045 HOR1-HOR3.
///
/// All executable observations use the repository fake with a contract-only
/// source seam. Production-factory negative tests stop before runner entry.
/// These host-only tests do not contact a device or an HDC server and do not
/// exercise lifecycle, subserver, device-mutation, or destructive capabilities.
final class HDCDeviceObservationPresentationContractTests: XCTestCase {

  func testDP1_PublicProjectionHasExactClosedReadableShapeAndRawTypesStayInternal() async throws {
    XCTAssertEqual(
      HDCDeviceObservationPresentationKind.allContractCases.map(\.rawValue),
      ["appeared", "disappeared", "observationUnknown", "observationUnavailable"])
    let bridge = HDCDeviceObservationPresentationBridge(
      clock: { Date(timeIntervalSince1970: 1_785_196_800) })
    await bridge.ingest([
      .appeared(
        HDCObservedDeviceIdentifier(
          redactedKey: "redacted-device-0123456789abcdef01234567"))
    ])
    let bridgedEvents = await bridge.events()
    let event = try XCTUnwrap(bridgedEvents.first)
    XCTAssertEqual(event.timestamp, "2026-07-28T00:00:00.000Z")
    XCTAssertEqual(event.kind, .appeared)
    XCTAssertEqual(
      event.redactedDeviceIdentifier,
      "redacted-device-0123456789abcdef01234567")
    XCTAssertEqual(
      Set(Mirror(reflecting: event).children.compactMap(\.label)),
      ["timestamp", "kind", "redactedDeviceIdentifier"])

    let openHarmony = try sourceText("Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift")
    XCTAssertFalse(openHarmony.contains("public enum HDCDeviceObservationSnapshot"))
    XCTAssertFalse(openHarmony.contains("public protocol HDCDeviceObservationSnapshotProviding"))
    XCTAssertFalse(openHarmony.contains("public struct HDCDeviceObservationComposition"))
    XCTAssertFalse(openHarmony.contains("public actor HDCDeviceObservationFanOut"))
    let production = try sourceText("Sources/ArkDeckOpenHarmony/HDCProduction.swift")
    XCTAssertFalse(production.contains("public let pseudonymKey"))
    XCTAssertTrue(production.contains("package init(\n    acceptedAt: Date"))
  }

  func testDP2_PresentationDefaultsToEmptyEventsWithoutChangingLegacySentinels() {
    let presentation = basePresentation()
    XCTAssertEqual(presentation.deviceEvents, [])
    XCTAssertEqual(HDCDiagnosticsPresentation.unprobed.deviceEvents, [])
    XCTAssertEqual(HDCDiagnosticsPresentation.loading.deviceEvents, [])
    XCTAssertEqual(presentation.absolutePath, "/fixture/hdc")
    XCTAssertEqual(presentation.endpoint, "127.0.0.1:8710")
  }

  func testDP3_AppearedAndDisappearedUseInjectedUTCFractionalRFC3339Clock() async throws {
    let identifier = validIdentifier()
    let clock = ObservationClock([
      Date(timeIntervalSince1970: 1_785_196_800),
      Date(timeIntervalSince1970: 1_785_196_801),
    ])
    let source = SequenceObservationSource([
      .observedConnectedSet([identifier]),
      .observedEmpty,
    ])
    let session = try contractSession(source: source, clock: clock)

    _ = await session.refresh()
    let events = await session.refresh()

    XCTAssertEqual(
      events.map(\.timestamp),
      [
        "2026-07-28T00:00:00.000Z",
        "2026-07-28T00:00:01.000Z",
      ])
    XCTAssertEqual(events.map(\.kind), [.appeared, .disappeared])
    XCTAssertTrue(
      events.compactMap(\.redactedDeviceIdentifier).allSatisfy {
        $0.range(
          of: #"^redacted-device-[0-9a-f]{24}$"#,
          options: .regularExpression) != nil
      })
    XCTAssertEqual(clock.callCount, 2)
  }

  func testDP4_UnchangedUpdatesObservationWithoutClockOrPublicHistoryGrowth() async throws {
    let identifier = validIdentifier()
    let clock = ObservationClock([
      Date(timeIntervalSince1970: 1_785_196_800),
      Date(timeIntervalSince1970: 1_785_196_801),
    ])
    let source = SequenceObservationSource([
      .observedConnectedSet([identifier]),
      .observedConnectedSet([identifier]),
    ])
    let session = try contractSession(source: source, clock: clock)

    let first = await session.refresh()
    let second = await session.refresh()

    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(second, first)
    XCTAssertEqual(second.map(\.kind), [.appeared])
    XCTAssertEqual(clock.callCount, 1)
    let observeCount = await source.observeCount
    XCTAssertEqual(observeCount, 2)
  }

  func testDP5_UnknownAndUnavailableExposeNoIdentifierOrInternalReason() async throws {
    let clock = ObservationClock([
      Date(timeIntervalSince1970: 1_785_196_800),
      Date(timeIntervalSince1970: 1_785_196_801),
    ])
    let source = SequenceObservationSource([
      .unknown(reason: "raw-connect-key-must-not-escape"),
      .unavailable(reason: "server process detail must stay internal"),
    ])
    let session = try contractSession(source: source, clock: clock)

    _ = await session.refresh()
    let events = await session.refresh()

    XCTAssertEqual(events.map(\.kind), [.observationUnknown, .observationUnavailable])
    XCTAssertEqual(events.compactMap(\.redactedDeviceIdentifier), [])
    XCTAssertFalse(String(describing: events).contains("raw-connect-key-must-not-escape"))
    XCTAssertFalse(String(describing: events).contains("server process detail"))
    XCTAssertFalse(
      Set(Mirror(reflecting: events[0]).children.compactMap(\.label)).contains("reason"))
  }

  func testDP6_MalformedIdentifierFailsClosedToUnknownWithoutLeakage() async throws {
    let rawLikeValue = "raw-connect-key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let source = SequenceObservationSource([
      .observedConnectedSet([HDCObservedDeviceIdentifier(redactedKey: rawLikeValue)])
    ])
    let session = try contractSession(
      source: source,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))

    let events = await session.refresh()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].kind, .observationUnknown)
    XCTAssertNil(events[0].redactedDeviceIdentifier)
    XCTAssertFalse(String(describing: events[0]).contains(rawLikeValue))
  }

  func testDP7_PublicBufferKeepsExactlyLatest64InStableOrder() async {
    let start = Date(timeIntervalSince1970: 1_785_196_800)
    let clock = ObservationClock((0..<70).map { start.addingTimeInterval(Double($0)) })
    let bridge = HDCDeviceObservationPresentationBridge(
      capacity: 64, clock: { clock.next() })

    for index in 0..<70 {
      await bridge.ingest([.observationUnknown(reason: "internal-\(index)")])
    }
    let events = await bridge.events()

    XCTAssertEqual(events.count, 64)
    XCTAssertEqual(events.first?.timestamp, "2026-07-28T00:00:06.000Z")
    XCTAssertEqual(events.last?.timestamp, "2026-07-28T00:01:09.000Z")
    XCTAssertEqual(events.map(\.kind), Array(repeating: .observationUnknown, count: 64))
  }

  func testDP8_WrongCandidateSHAAppendsUnavailableWithZeroRunnerInvocation() async throws {
    let session = HDCDeviceObservationApplicationSession.makeProduction(
      toolchain: HDCCandidate(
        path: URL(filePath: "/private/tmp/arkdeck-obs-dp8-missing"),
        source: .userConfigured,
        sha256: "wrong-sha256"),
      endpointSelection: try exactEndpointSelection())

    let events = await session.refresh()
    let invocationCount = await session.observedRunnerInvocationCount()

    XCTAssertEqual(events.map(\.kind), [.observationUnavailable])
    XCTAssertEqual(invocationCount, 0)
  }

  func testDP9_WrongEndpointAppendsUnavailableWithZeroRunnerInvocation() async throws {
    let session = HDCDeviceObservationApplicationSession.makeProduction(
      toolchain: exactDeclaredMissingCandidate(label: "dp9"),
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: "127.0.0.1:18710"))

    let events = await session.refresh()
    let invocationCount = await session.observedRunnerInvocationCount()

    XCTAssertEqual(events.map(\.kind), [.observationUnavailable])
    XCTAssertEqual(invocationCount, 0)
  }

  func testDP10_IdentityUnavailableStopsBeforeRunnerInvocation() async throws {
    let session = HDCDeviceObservationApplicationSession.makeProduction(
      toolchain: exactDeclaredMissingCandidate(label: "dp10"),
      endpointSelection: try exactEndpointSelection())

    let events = await session.refresh()
    let invocationCount = await session.observedRunnerInvocationCount()

    XCTAssertEqual(events.map(\.kind), [.observationUnavailable])
    XCTAssertEqual(invocationCount, 0)
  }

  func testDP11_StableBracketUsesExactRegisteredArgvOnceAndRedactsRawKey() async throws {
    let root = try temporaryRoot("dp11")
    defer { try? FileManager.default.removeItem(at: root) }
    let invocationLog = root.appending(path: "invocations.log")
    let rawConnectKey = String(repeating: "c", count: 32)
    let row = "\(rawConnectKey)\t\tUSB\tConnected\tlocalhost\n"
    let candidate = fixtureCandidate()
    let endpoint = HDCServerEndpoint(HDCDeviceObservationProbeCatalog.exactEndpoint)
    let receipt = identityReceipt(candidate: candidate, endpoint: endpoint)
    let source = HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(
        semanticProfile: fixtureSemanticProfile(candidate: candidate, stdout: row)),
      toolchain: candidate,
      endpointSelection: try exactEndpointSelection(),
      identityObserver: SequenceIdentityObserver([
        .observed(receipt),
        .observed(receipt),
      ]),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
        "ARKDECK_FAKE_HDC_SELECTED_DEVICE_ROW": row,
      ],
      pseudonymKey: SymmetricKey(data: Data(repeating: 0x11, count: 32)))
    let session = try contractSession(
      source: source,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))

    let events = await session.refresh()
    let invocationCount = await source.observedRunnerInvocationCount()

    XCTAssertEqual(try invocationLines(invocationLog), ["list\u{1F}targets\u{1F}-v"])
    XCTAssertEqual(invocationCount, 1)
    XCTAssertEqual(events.map(\.kind), [.appeared])
    XCTAssertEqual(events.first?.redactedDeviceIdentifier?.count, 40)
    XCTAssertFalse(String(describing: events).contains(rawConnectKey))
  }

  func testDP12_PostIdentityDriftDropsPayloadAndPublishesOnlyUnavailable() async throws {
    let root = try temporaryRoot("dp12")
    defer { try? FileManager.default.removeItem(at: root) }
    let invocationLog = root.appending(path: "invocations.log")
    let rawConnectKey = String(repeating: "d", count: 32)
    let row = "\(rawConnectKey)\t\tUSB\tConnected\tlocalhost\n"
    let candidate = fixtureCandidate()
    let endpoint = HDCServerEndpoint(HDCDeviceObservationProbeCatalog.exactEndpoint)
    let before = identityReceipt(candidate: candidate, endpoint: endpoint, pid: 4_321)
    let after = identityReceipt(candidate: candidate, endpoint: endpoint, pid: 4_322)
    let source = HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(
        semanticProfile: fixtureSemanticProfile(candidate: candidate, stdout: row)),
      toolchain: candidate,
      endpointSelection: try exactEndpointSelection(),
      identityObserver: SequenceIdentityObserver([
        .observed(before),
        .observed(after),
      ]),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
        "ARKDECK_FAKE_HDC_SELECTED_DEVICE_ROW": row,
      ])
    let session = try contractSession(
      source: source,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))

    let events = await session.refresh()
    let invocationCount = await source.observedRunnerInvocationCount()

    XCTAssertEqual(try invocationLines(invocationLog), ["list\u{1F}targets\u{1F}-v"])
    XCTAssertEqual(invocationCount, 1)
    XCTAssertEqual(events.map(\.kind), [.observationUnavailable])
    XCTAssertEqual(events.compactMap(\.redactedDeviceIdentifier), [])
    XCTAssertFalse(String(describing: events).contains(rawConnectKey))
  }

  func testDP13_ProductionFactoryHasNoSourceRunnerArgvOrTestSeam() throws {
    let production = try sourceText("Sources/ArkDeckOpenHarmony/HDCProduction.swift")
    let sessionSection = try XCTUnwrap(
      production.range(of: "package actor HDCDeviceObservationApplicationSession"))
    let tail = production[sessionSection.lowerBound...]
    let factoryStart = try XCTUnwrap(tail.range(of: "package static func makeProduction("))
    let factoryEnd = try XCTUnwrap(tail.range(of: "  static func makeContract("))
    let productionFactory = String(tail[factoryStart.lowerBound..<factoryEnd.lowerBound])
    let declaration = String(
      productionFactory.prefix {
        !$0.isASCII || $0 != "{"
      })

    XCTAssertTrue(declaration.contains("toolchain: HDCCandidate"))
    XCTAssertTrue(declaration.contains("endpointSelection: HDCServerEndpointSelection"))
    XCTAssertFalse(declaration.contains("source:"))
    XCTAssertFalse(declaration.contains("runner:"))
    XCTAssertFalse(declaration.contains("arguments:"))
    XCTAssertFalse(declaration.contains("argv"))
    XCTAssertFalse(declaration.contains("clock:"))

    let workflows = try sourceText(
      "Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    XCTAssertTrue(workflows.contains("HDCDeviceObservationApplicationSession.makeProduction("))
    XCTAssertFalse(workflows.contains("HDCDeviceObservationApplicationSession.makeContract("))
    XCTAssertFalse(workflows.contains("HDCDeviceObservationSnapshotProviding"))
    XCTAssertFalse(workflows.contains("HDCProcessCommandRunner"))
  }

  func testDP14_SequentialExplicitRefreshPollsOnceAndOverlaysSamePresentation() async throws {
    let identifier = validIdentifier()
    let source = SequenceObservationSource([
      .observedConnectedSet([identifier]),
      .observedEmpty,
    ])
    let clock = ObservationClock([
      Date(timeIntervalSince1970: 1_785_196_800),
      Date(timeIntervalSince1970: 1_785_196_801),
    ])
    let session = try contractSession(source: source, clock: clock)
    let base = basePresentation()

    let first = base.overlayingDeviceEvents(await session.refresh())
    let second = base.overlayingDeviceEvents(await session.refresh())
    let observeCount = await source.observeCount

    XCTAssertEqual(observeCount, 2)
    XCTAssertEqual(first.deviceEvents.map(\.kind), [.appeared])
    XCTAssertEqual(second.deviceEvents.map(\.kind), [.appeared, .disappeared])
    XCTAssertEqual(second.absolutePath, base.absolutePath)
    XCTAssertEqual(second.lifecycleRecovery, base.lifecycleRecovery)
    XCTAssertEqual(second.endpointSource, base.endpointSource)
  }

  func testDP15_ConcurrentRefreshesCoalesceWithoutSecondPollOrQueuedRetry() async throws {
    let gate = ObservationGate()
    let spy = ObservationEffectSpy()
    let source = BlockingObservationSource(
      snapshot: .observedConnectedSet([validIdentifier()]),
      gate: gate,
      spy: spy)
    let session = try contractSession(
      source: source,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))

    let first = Task { await session.refresh() }
    try await waitUntil { spy.observeCount == 1 }
    let second = Task { await session.refresh() }
    try await Task.sleep(for: .milliseconds(75))

    XCTAssertEqual(spy.observeCount, 1)
    XCTAssertEqual(spy.maximumInFlight, 1)
    await gate.releaseAll()
    let firstEvents = await first.value
    let secondEvents = await second.value

    XCTAssertEqual(spy.observeCount, 1)
    XCTAssertEqual(spy.maximumInFlight, 1)
    XCTAssertTrue(
      [firstEvents, secondEvents].contains { $0.map(\.kind) == [.appeared] })
  }

  func testDP16_CancellationPublishesUnavailableAndTerminatesOnlyOwnedObservation() async throws {
    let spy = ObservationEffectSpy()
    let source = CancellableObservationSource(spy: spy)
    let session = try contractSession(
      source: source,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))
    let refresh = Task { await session.refresh() }
    try await waitUntil { spy.observeCount == 1 }

    refresh.cancel()
    let events = await refresh.value

    XCTAssertEqual(events.map(\.kind), [.observationUnavailable])
    XCTAssertEqual(spy.ownedObservationTerminationCount, 1)
    XCTAssertEqual(spy.serverLifecycleEffectCount, 0)
    XCTAssertEqual(spy.subserverEffectCount, 0)
    XCTAssertEqual(spy.deviceMutationEffectCount, 0)
  }

  func testDP17_NewSessionClearsBufferAndChangesPseudonymForSameRawKey() async throws {
    let root = try temporaryRoot("dp17")
    defer { try? FileManager.default.removeItem(at: root) }
    let candidate = fixtureCandidate()
    let endpoint = HDCServerEndpoint(HDCDeviceObservationProbeCatalog.exactEndpoint)
    let receipt = identityReceipt(candidate: candidate, endpoint: endpoint)
    let rawConnectKey = String(repeating: "e", count: 32)
    let row = "\(rawConnectKey)\t\tUSB\tConnected\tlocalhost\n"

    let sourceA = registeredFixtureSource(
      candidate: candidate,
      receipt: receipt,
      row: row,
      invocationLog: root.appending(path: "a.log"),
      keyByte: 0x21)
    let sourceB = registeredFixtureSource(
      candidate: candidate,
      receipt: receipt,
      row: row,
      invocationLog: root.appending(path: "b.log"),
      keyByte: 0x22)
    let sessionA = try contractSession(
      source: sourceA,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_800)]))
    let sessionB = try contractSession(
      source: sourceB,
      clock: ObservationClock([Date(timeIntervalSince1970: 1_785_196_801)]))

    let eventsA = await sessionA.refresh()
    let eventsB = await sessionB.refresh()

    XCTAssertEqual(eventsA.count, 1)
    XCTAssertEqual(eventsB.count, 1, "a replacement session starts with an empty buffer")
    XCTAssertNotEqual(
      eventsA[0].redactedDeviceIdentifier,
      eventsB[0].redactedDeviceIdentifier,
      "the same raw key is not linkable across session-scoped HMAC keys")
    XCTAssertFalse(String(describing: eventsA + eventsB).contains(rawConnectKey))
    let workflows = try sourceText(
      "Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    XCTAssertTrue(workflows.contains("executionSessionIdentity: executionIdentity.sessionID"))
    XCTAssertTrue(workflows.contains("clearDeviceObservationSession()"))
  }

  func testDP18_ExactUITestFlagProvidesPinnedEventsAndProductionHasNoFixturePoller() async throws {
    let fixture = HDCApplicationDiagnosticsFacade.make(arguments: [
      "ArkDeck", "--ui-test-hdc-diagnostics",
    ])
    let firstFixturePresentation = await fixture.refresh(deviceObservation: .loading)
    let secondFixturePresentation = await fixture.refresh(deviceObservation: .loading)

    XCTAssertFalse(fixture.lifecycleDispatchIsProductionComposed)
    XCTAssertEqual(
      firstFixturePresentation.deviceEvents.map(\.timestamp),
      [
        "2026-07-28T00:00:00.000Z"
      ])
    XCTAssertEqual(firstFixturePresentation.deviceEvents.map(\.kind), [.appeared])
    XCTAssertEqual(
      secondFixturePresentation.deviceEvents.map(\.timestamp),
      [
        "2026-07-28T00:00:00.000Z",
        "2026-07-28T00:00:01.000Z",
      ])
    XCTAssertEqual(secondFixturePresentation.deviceEvents.map(\.kind), [.appeared, .disappeared])
    XCTAssertEqual(
      secondFixturePresentation.deviceEvents.compactMap(\.redactedDeviceIdentifier),
      Array(
        repeating: "redacted-device-0123456789abcdef01234567",
        count: 2))

    let production = HDCApplicationDiagnosticsFacade.make(arguments: ["ArkDeck"])
    let nearMiss = HDCApplicationDiagnosticsFacade.make(arguments: [
      "ArkDeck", "--ui-test-hdc-diagnostic",
    ])
    XCTAssertTrue(production.lifecycleDispatchIsProductionComposed)
    XCTAssertTrue(nearMiss.lifecycleDispatchIsProductionComposed)

    let workflows = try sourceText(
      "Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    let fixtureBoundary = try XCTUnwrap(
      workflows.range(of: "private actor HDCFixtureApplicationDiagnostics"))
    let productionSection = String(workflows[..<fixtureBoundary.lowerBound])
    XCTAssertFalse(
      productionSection.contains("redacted-device-0123456789abcdef01234567"))
    XCTAssertFalse(productionSection.contains("2026-07-28T00:00:00"))
    XCTAssertFalse(productionSection.contains("Timer"))
    XCTAssertFalse(productionSection.contains("Task.sleep"))
    XCTAssertFalse(productionSection.localizedCaseInsensitiveContains("automatic retry"))
    XCTAssertEqual(
      occurrences(of: "deviceObservationSession.refresh()", in: productionSection),
      1,
      "only the explicit facade refresh drives one observation")
  }

  func testDP19_ProductionRootSharesOneCandidateEndpointAndOneExact320FObserver()
    throws
  {
    let production = try sourceText("Sources/ArkDeckOpenHarmony/HDCProduction.swift")
    let supervisorObservation = try sourceText(
      "Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift")
    let workflows = try sourceText(
      "Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    let fixtureBoundary = try XCTUnwrap(
      workflows.range(of: "private actor HDCFixtureApplicationDiagnostics"))
    let productionWorkflows = String(workflows[..<fixtureBoundary.lowerBound])

    XCTAssertEqual(
      occurrences(
        of: "HDCExternalFirstDiscovery.discover(request)",
        in: productionWorkflows),
      1,
      "one bootstrap must discover exactly once")
    XCTAssertEqual(
      occurrences(
        of: "HDCSupervisorObservationApplicationSession.makeProduction(",
        in: productionWorkflows),
      1)
    XCTAssertEqual(
      occurrences(
        of: "HDCDeviceObservationApplicationSession.makeProduction(",
        in: productionWorkflows),
      1)
    XCTAssertTrue(
      productionWorkflows.contains(
        """
        let session = HDCSupervisorObservationApplicationSession.makeProduction(
                supervisor: supervisor,
                toolchain: candidate,
                endpointSelection: endpoint)
        """))
    XCTAssertTrue(
      productionWorkflows.contains(
        """
        deviceObservationSession = HDCDeviceObservationApplicationSession.makeProduction(
              toolchain: candidate, endpointSelection: endpoint)
        """))
    XCTAssertFalse(
      productionWorkflows.contains(
        "HDCSupervisorObservationApplicationSession.makeContract("))
    XCTAssertFalse(productionWorkflows.contains("HDCServerProcessIdentityObserving"))
    XCTAssertFalse(productionWorkflows.contains("HDCProcessCommandRunner"))
    XCTAssertTrue(
      productionWorkflows.contains(
        "let processSupervisor = HDCServerProcessSupervisor(supervisor: supervisor)"),
      "the exact 3.2.0d route remains the separate fallback arm for non-3.2.0f candidates")

    XCTAssertFalse(production.contains("HDCDeviceObservationSystemIdentityObserver"))
    XCTAssertEqual(
      occurrences(
        of:
          "HDCExact320FSystemIdentityObserver.deviceObservationProduction",
        in: production),
      1,
      "device observation must use the shared exact-3.2.0f system observer")
    XCTAssertEqual(
      occurrences(
        of: "struct HDCExact320FSystemIdentityObserver:",
        in: supervisorObservation),
      1)
    XCTAssertEqual(
      occurrences(
        of:
          "HDCExact320FSystemIdentityObserver.supervisorObservationProduction",
        in: supervisorObservation),
      1,
      "supervisor production construction must use the same observer implementation")
    XCTAssertEqual(
      occurrences(
        of: "static let deviceObservationProduction =",
        in: supervisorObservation),
      1,
      "the device factory keeps its independent registry tuple")
    XCTAssertEqual(
      occurrences(
        of: "static let supervisorObservationProduction =",
        in: supervisorObservation),
      1,
      "the supervisor factory keeps its independent registry tuple")
  }

  func testHOR1_DelayedFixtureMakesEveryAcceptedRefreshObservable() async {
    let delay = FixtureDelaySpy()
    let fixture = HDCApplicationDiagnosticsFacade.makeFixtureForTesting(
      arguments: [
        "ArkDeck", "--ui-test-hdc-diagnostics", "--ui-test-hdc-refresh-delay",
      ],
      delayedRefreshWait: { await delay.wait() })
    let first = await fixture.refresh(deviceObservation: .loading)
    let second = await fixture.refresh(deviceObservation: .loading)
    let third = await fixture.refresh(deviceObservation: .loading)

    XCTAssertEqual(first.deviceEvents.map(\.kind), [.appeared])
    XCTAssertEqual(second.deviceEvents.map(\.kind), [.appeared, .disappeared])
    XCTAssertEqual(
      third.deviceEvents.map(\.kind),
      [.appeared, .disappeared, .observationUnknown],
      "a duplicate that reaches the fixture is a visible third transition")
    XCTAssertEqual(second.automaticLifecycleDispatchCount, 0)
    XCTAssertEqual(second.automaticSubserverDispatchCount, 0)
    let delayInvocationCount = await delay.invocationCount
    XCTAssertEqual(delayInvocationCount, 1)
  }

  func testHOR2_AppWiringHasSynchronousSingleCallAdmissionAndNoQueue() throws {
    let app = try repositorySourceText("ArkDeckApp/App/ArkDeckApp.swift")
    let view = try repositorySourceText("ArkDeckApp/Features/HDC/HDCStatusView.swift")
    let modelStart = try XCTUnwrap(app.range(of: "private final class HDCStatusViewModel"))
    let modelEnd = try XCTUnwrap(
      app.range(
        of: "private final class OverviewCapabilityViewModel",
        range: modelStart.upperBound..<app.endIndex))
    let model = String(app[modelStart.lowerBound..<modelEnd.lowerBound])

    let overviewStart = try XCTUnwrap(app.range(of: "private struct OverviewWorkspaceView"))
    let overviewEnd = try XCTUnwrap(
      app.range(of: "private struct AppShellView", range: overviewStart.upperBound..<app.endIndex))
    let overviewWiring = String(app[overviewStart.lowerBound..<overviewEnd.lowerBound])

    XCTAssertEqual(occurrences(of: "hdcDiagnostics.refresh()", in: overviewWiring), 1)
    XCTAssertEqual(occurrences(of: "overviewCapabilities.refresh()", in: overviewWiring), 1)
    XCTAssertEqual(
      occurrences(of: "hdcDiagnostics.isRefreshInFlight", in: overviewWiring),
      1)
    XCTAssertEqual(occurrences(of: "let next = await provider.refresh(deviceObservation: observation)", in: model), 1)

    let guardIndex = try XCTUnwrap(
      model.range(of: "guard !isRefreshInFlight else { return }")?.lowerBound)
    let admitIndex = try XCTUnwrap(model.range(of: "isRefreshInFlight = true")?.lowerBound)
    let taskIndex = try XCTUnwrap(model.range(of: "Task { [weak self] in")?.lowerBound)
    let providerIndex = try XCTUnwrap(
      model.range(of: "let next = await provider.refresh(deviceObservation: observation)")?.lowerBound)
    let releaseIndex = try XCTUnwrap(
      model.range(of: "defer { self.isRefreshInFlight = false }")?.lowerBound)
    XCTAssertLessThan(guardIndex, admitIndex)
    XCTAssertLessThan(admitIndex, taskIndex)
    XCTAssertLessThan(taskIndex, providerIndex)
    XCTAssertLessThan(providerIndex, releaseIndex)
    XCTAssertFalse(model.contains("Timer"))
    XCTAssertFalse(model.contains("Task.sleep"))
    XCTAssertFalse(model.localizedCaseInsensitiveContains("automatic retry"))
    XCTAssertEqual(occurrences(of: "Button(\"hdc.devices.refresh\"", in: view), 1)
    XCTAssertEqual(
      occurrences(of: ".accessibilityIdentifier(\"hdc.devices.refresh\")", in: view),
      1)
    XCTAssertEqual(
      occurrences(of: ".keyboardShortcut(\"r\", modifiers: [.command])", in: view),
      1)
    XCTAssertEqual(occurrences(of: ".disabled(isRefreshInFlight)", in: view), 2)
  }

  func testHOR3_RefreshLocalizationIsCompleteAndFixtureStaysBelowBoundary() throws {
    let data = try Data(
      contentsOf: repositoryRoot()
        .appending(path: "ArkDeckApp/Resources/Localizable.xcstrings"))
    let catalog = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
    let refresh = try XCTUnwrap(strings["hdc.devices.refresh"] as? [String: Any])
    let localizations = try XCTUnwrap(refresh["localizations"] as? [String: Any])

    func localizedValue(_ locale: String) throws -> String {
      let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
      let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
      return try XCTUnwrap(unit["value"] as? String)
    }

    XCTAssertEqual(try localizedValue("en"), "Refresh Devices")
    XCTAssertEqual(try localizedValue("zh-Hans"), "刷新设备")
    XCTAssertEqual(Set(localizations.keys), ["en", "zh-Hans"])

    let workflows = try sourceText(
      "Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    let boundary = try XCTUnwrap(
      workflows.range(of: "private actor HDCFixtureApplicationDiagnostics"))
    let production = String(workflows[..<boundary.lowerBound])
    let fixture = String(workflows[boundary.lowerBound...])
    for fixtureOnly in [
      "--ui-test-hdc-refresh-delay",
      "refreshCallCount",
      "latestCompletedRefreshCallCount",
      "fixtureDeviceEvents",
      "Task.sleep",
      "1_785_196_802",
    ] {
      XCTAssertFalse(production.contains(fixtureOnly))
      XCTAssertTrue(fixture.contains(fixtureOnly))
    }
    XCTAssertEqual(
      occurrences(of: "deviceObservationSession.refresh()", in: production),
      1)
    XCTAssertEqual(
      occurrences(of: "HDCExternalFirstDiscovery.discover(request)", in: production),
      1)
  }

  private func contractSession(
    source: any HDCDeviceObservationSnapshotProviding,
    clock: ObservationClock,
    capacity: Int = 64
  ) throws -> HDCDeviceObservationApplicationSession {
    try HDCDeviceObservationApplicationSession.makeContract(
      source: source,
      capacity: capacity,
      clock: { clock.next() })
  }

  private func basePresentation() -> HDCDiagnosticsPresentation {
    HDCDiagnosticsPresentation(
      absolutePath: "/fixture/hdc",
      source: "fixture",
      hash: "fixture-hash",
      platformTrust: "unverified",
      clientVersion: "3.2.0f",
      serverVersion: "3.2.0f",
      daemonVersion: "unknown",
      endpoint: HDCDeviceObservationProbeCatalog.exactEndpoint,
      generation: "7",
      ownership: .external,
      authorization: .unavailable(reason: "not part of this contract"),
      channelProtection: .unverifiedAssumeUnprotected,
      subserverCapability: .unsupported,
      lifecycleRecovery: .unavailable(reason: "not part of this contract"),
      endpointSource: .explicit)
  }

  private func validIdentifier() -> HDCObservedDeviceIdentifier {
    HDCObservedDeviceIdentifier(
      redactedKey: "redacted-device-0123456789abcdef01234567")
  }

  private func exactEndpointSelection() throws -> HDCServerEndpointSelection {
    try HDCServerEndpointSelector.select(
      explicitEndpoint: HDCDeviceObservationProbeCatalog.exactEndpoint)
  }

  private func exactDeclaredMissingCandidate(label: String) -> HDCCandidate {
    HDCCandidate(
      path: URL(filePath: "/private/tmp/arkdeck-obs-\(label)-missing"),
      source: .userConfigured,
      sha256: HDCDeviceObservationProbeCatalog.targetExecutableSHA256)
  }

  private func fixtureExecutable() -> URL {
    packageRoot().appending(path: ".build/debug/ArkDeckFakeHDCFixture")
  }

  private func fixtureCandidate() -> HDCCandidate {
    let executable = fixtureExecutable()
    let data = (try? Data(contentsOf: executable)) ?? Data()
    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return HDCCandidate(path: executable, source: .userConfigured, sha256: sha256)
  }

  private func fixtureSemanticProfile(
    candidate: HDCCandidate,
    stdout: String
  ) -> HDCRegisteredSemanticProfile {
    let hash = SHA256.hash(data: Data(stdout.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return .testOnlyFake(
      executableSHA256: candidate.sha256,
      selectedDeviceAuthorizationSHA256: hash)
  }

  private func identityReceipt(
    candidate: HDCCandidate,
    endpoint: HDCServerEndpoint,
    pid: Int32 = 4_321
  ) -> HDCServerProcessIdentityReceipt {
    HDCServerProcessIdentityReceipt(
      pid: pid,
      startSeconds: 1_785_196_800,
      startMicroseconds: 123_456,
      executablePath: candidate.path.resolvingSymlinksInPath().standardizedFileURL,
      executableSHA256: candidate.sha256,
      endpoint: endpoint)
  }

  private func registeredFixtureSource(
    candidate: HDCCandidate,
    receipt: HDCServerProcessIdentityReceipt,
    row: String,
    invocationLog: URL,
    keyByte: UInt8
  ) -> HDCRegisteredDeviceObservationSource {
    HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(
        semanticProfile: fixtureSemanticProfile(candidate: candidate, stdout: row)),
      toolchain: candidate,
      endpointSelection: try! exactEndpointSelection(),
      identityObserver: SequenceIdentityObserver([
        .observed(receipt),
        .observed(receipt),
      ]),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
        "ARKDECK_FAKE_HDC_SELECTED_DEVICE_ROW": row,
      ],
      pseudonymKey: SymmetricKey(data: Data(repeating: keyByte, count: 32)))
  }

  private func packageRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func sourceText(_ packageRelativePath: String) throws -> String {
    try String(
      contentsOf: packageRoot().appending(path: packageRelativePath),
      encoding: .utf8)
  }

  private func repositoryRoot() -> URL {
    packageRoot()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func repositorySourceText(_ repositoryRelativePath: String) throws -> String {
    try String(
      contentsOf: repositoryRoot().appending(path: repositoryRelativePath),
      encoding: .utf8)
  }

  private func temporaryRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-obs-presentation-\(label)-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func invocationLines(_ url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "condition did not become true before timeout")
  }

  private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
  }
}

extension HDCDeviceObservationPresentationKind {
  fileprivate static let allContractCases: [Self] = [
    .appeared, .disappeared, .observationUnknown, .observationUnavailable,
  ]
}

private final class ObservationClock: @unchecked Sendable {
  private let lock = NSLock()
  private let dates: [Date]
  private var index = 0

  init(_ dates: [Date]) {
    precondition(!dates.isEmpty)
    self.dates = dates
  }

  func next() -> Date {
    lock.withLock {
      let date = dates[min(index, dates.count - 1)]
      index += 1
      return date
    }
  }

  var callCount: Int {
    lock.withLock { index }
  }
}

private actor SequenceObservationSource: HDCDeviceObservationSnapshotProviding {
  nonisolated let authority = HDCDeviceObservationSourceAuthority.integrationRegistered
  private let snapshots: [HDCDeviceObservationSnapshot]
  private var index = 0

  init(_ snapshots: [HDCDeviceObservationSnapshot]) {
    precondition(!snapshots.isEmpty)
    self.snapshots = snapshots
  }

  func observe() async -> HDCDeviceObservationSnapshot {
    let snapshot = snapshots[min(index, snapshots.count - 1)]
    index += 1
    return snapshot
  }

  var observeCount: Int { index }
}

private actor SequenceIdentityObserver: HDCServerProcessIdentityObserving {
  private let observations: [HDCServerProcessIdentityRawObservation]
  private var index = 0

  init(_ observations: [HDCServerProcessIdentityRawObservation]) {
    precondition(!observations.isEmpty)
    self.observations = observations
  }

  func observe(
    endpoint _: HDCServerEndpoint,
    selectedToolchain _: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    let observation = observations[min(index, observations.count - 1)]
    index += 1
    return observation
  }
}

private final class ObservationEffectSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedObserveCount = 0
  private var storedInFlight = 0
  private var storedMaximumInFlight = 0
  private var storedOwnedObservationTerminationCount = 0

  func beginObservation() {
    lock.withLock {
      storedObserveCount += 1
      storedInFlight += 1
      storedMaximumInFlight = max(storedMaximumInFlight, storedInFlight)
    }
  }

  func endObservation() {
    lock.withLock { storedInFlight -= 1 }
  }

  func recordOwnedObservationTermination() {
    lock.withLock { storedOwnedObservationTerminationCount += 1 }
  }

  var observeCount: Int { lock.withLock { storedObserveCount } }
  var maximumInFlight: Int { lock.withLock { storedMaximumInFlight } }
  var ownedObservationTerminationCount: Int {
    lock.withLock { storedOwnedObservationTerminationCount }
  }
  var serverLifecycleEffectCount: Int { 0 }
  var subserverEffectCount: Int { 0 }
  var deviceMutationEffectCount: Int { 0 }
}

private actor ObservationGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func releaseAll() {
    let current = waiters
    waiters.removeAll()
    current.forEach { $0.resume() }
  }
}

private actor FixtureDelaySpy {
  private(set) var invocationCount = 0

  func wait() {
    invocationCount += 1
  }
}

private final class BlockingObservationSource:
  HDCDeviceObservationSnapshotProviding, @unchecked Sendable
{
  let authority = HDCDeviceObservationSourceAuthority.integrationRegistered
  private let snapshot: HDCDeviceObservationSnapshot
  private let gate: ObservationGate
  private let spy: ObservationEffectSpy

  init(
    snapshot: HDCDeviceObservationSnapshot,
    gate: ObservationGate,
    spy: ObservationEffectSpy
  ) {
    self.snapshot = snapshot
    self.gate = gate
    self.spy = spy
  }

  func observe() async -> HDCDeviceObservationSnapshot {
    spy.beginObservation()
    defer { spy.endObservation() }
    await gate.wait()
    return snapshot
  }
}

private final class CancellableObservationSource:
  HDCDeviceObservationSnapshotProviding, @unchecked Sendable
{
  let authority = HDCDeviceObservationSourceAuthority.integrationRegistered
  private let spy: ObservationEffectSpy

  init(spy: ObservationEffectSpy) {
    self.spy = spy
  }

  func observe() async -> HDCDeviceObservationSnapshot {
    spy.beginObservation()
    defer { spy.endObservation() }
    return await withTaskCancellationHandler {
      do {
        try await Task.sleep(for: .seconds(60))
        return .observedEmpty
      } catch {
        return .unavailable(reason: "owned observation child was cancelled")
      }
    } onCancel: {
      self.spy.recordOwnedObservationTermination()
    }
  }
}
