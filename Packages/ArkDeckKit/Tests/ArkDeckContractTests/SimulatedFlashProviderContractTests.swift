import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class SimulatedFlashProviderContractTests: XCTestCase {
  private let timestamp = "2026-07-20T02:00:00Z"

  // TEST-AC-FLASH-006-01 / simulationIsolationContract
  func testTEST_AC_FLASH_006_01_SuccessPersistsOnlySimulatedEvidence() async throws {
    let fixture = try makeFixture(label: "success")
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let monitor = SimulatedFlashIsolationMonitor()
    let provider = SimulatedFlashProvider(monitor: monitor)

    let receipt = try await provider.run(
      request(layout: fixture.layout, scenario: .success()))

    XCTAssertEqual(receipt.evidence.evidenceClass, .simulated)
    XCTAssertEqual(receipt.evidence.executionMode, "simulated")
    XCTAssertEqual(receipt.evidence.targetKind, .synthetic)
    XCTAssertNil(receipt.evidence.connectKey)
    XCTAssertEqual(receipt.evidence.toolchainKind, .none)
    XCTAssertFalse(receipt.evidence.hardwareSupportEligible)
    XCTAssertEqual(receipt.evidence.terminalState, .succeeded)
    XCTAssertEqual(
      receipt.plannedSteps.map(\.kind), [.enterUpdater, .flashPartition, .verifyRemoteState])
    XCTAssertEqual(receipt.phaseOutcomes.map(\.result), [.succeeded, .succeeded, .succeeded])
    assertIsolation(receipt.isolation)
    XCTAssertEqual(receipt.isolation.simulatedPhaseCount, 3)
    XCTAssertNotNil(receipt.manifest)

    let reopened = try SimulatedFlashProvider.reopen(fixture.layout)
    XCTAssertEqual(reopened.replay.executionMode, "simulated")
    XCTAssertEqual(reopened.replay.currentState, .succeeded)
    XCTAssertTrue(reopened.replay.finalized)
    XCTAssertEqual(reopened.manifest?.executionMode, "simulated")
    XCTAssertEqual(reopened.manifest?.sha256, receipt.evidence.manifestSHA256)
    XCTAssertEqual(reopened.durableReceipts.map(\.category), [.intent, .outcome])
    XCTAssertEqual(reopened.durableReceipts.last?.details["evidenceClass"], .string("simulated"))
    XCTAssertEqual(
      reopened.durableReceipts.last?.details["hardwareSupportEligible"], .bool(false))

    let manifest = try XCTUnwrap(reopened.manifest)
    let object = try jsonObject(manifest.canonicalData)
    XCTAssertEqual(object["executionMode"] as? String, "simulated")
    XCTAssertEqual((object["originalTarget"] as? [String: Any])?["kind"] as? String, "synthetic")
    XCTAssertTrue((object["originalTarget"] as? [String: Any])?["connectKey"] is NSNull)
    XCTAssertEqual((object["toolchain"] as? [String: Any])?["kind"] as? String, "none")
    let workflow = try XCTUnwrap(object["workflow"] as? [String: Any])
    XCTAssertEqual(workflow["fixtureIdentity"] as? String, "m1-008-fixture")
    XCTAssertFalse((workflow["scenarioIdentity"] as? String ?? "").isEmpty)

    let journalData = try Data(contentsOf: fixture.layout.journalURL)
    let journalText = String(decoding: journalData, as: UTF8.self)
    XCTAssertFalse(journalText.contains(#""connectKey":"usb"#))
    XCTAssertFalse(journalText.contains(#""executionMode":"execute"#))
    XCTAssertFalse(journalText.contains("ProcessExecutor"))
    print(
      "TEST-AC-FLASH-006-01 PASS evidence=simulated hardware_writer=0 real_connect_key=0 external_process=0 network=0 hdc=0 device=0 destructive_dispatch=0"
    )
  }

  // TEST-AC-FLASH-006-01 / receipt + locked Manifest tamper matrix
  func testTEST_AC_FLASH_006_01_ReceiptAndManifestTamperFailClosed() async throws {
    let fixture = try makeFixture(label: "tamper")
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let receipt = try await SimulatedFlashProvider().run(
      request(layout: fixture.layout, scenario: .success()))
    let receiptData = try JSONEncoder().encode(receipt.evidence)

    try assertReceiptTamperRejected(receiptData) { $0["executionMode"] = "execute" }
    try assertReceiptTamperRejected(receiptData) { $0["targetKind"] = "real" }
    try assertReceiptTamperRejected(receiptData) { $0["connectKey"] = "usb-real-device" }
    try assertReceiptTamperRejected(receiptData) { $0["toolchainKind"] = "hdc" }
    try assertReceiptTamperRejected(receiptData) { $0["hardwareSupportEligible"] = true }
    try assertReceiptTamperRejected(receiptData) { $0["fixtureIdentity"] = "" }
    try assertReceiptTamperRejected(receiptData) { $0["terminalState"] = "running" }
    try assertReceiptTamperRejected(receiptData) { $0["manifestSha256"] = NSNull() }
    try assertReceiptTamperRejected(receiptData) { $0["futureAuthority"] = true }

    let manifestData = try XCTUnwrap(try SimulatedFlashProvider.reopen(fixture.layout).manifest)
      .canonicalData
    try assertManifestTamperRejected(manifestData) { $0["executionMode"] = "execute" }
    try assertManifestTamperRejected(manifestData) { object in
      var target = object["originalTarget"] as! [String: Any]
      target["kind"] = "real"
      object["originalTarget"] = target
    }
    try assertManifestTamperRejected(manifestData) { object in
      var target = object["originalTarget"] as! [String: Any]
      target["connectKey"] = "usb-real-device"
      object["originalTarget"] = target
    }
    try assertManifestTamperRejected(manifestData) { object in
      object["toolchain"] = [
        "kind": "hdc", "source": "tamper", "path": "/tmp/hdc",
        "sha256": String(repeating: "a", count: 64), "clientVersion": "1",
        "serverVersion": "1", "endpoint": "127.0.0.1:8710",
        "serverGeneration": 1, "serverOwnership": "external",
      ]
    }
  }

  func testStrictJSONEntryPointsRejectDuplicateMemberNames() throws {
    let identity = try SimulatedFlashFixtureIdentity(
      fixtureIdentity: "fixture", syntheticDeviceIdentity: "device")
    XCTAssertEqual(
      try SimulatedFlashFixtureIdentity(data: JSONEncoder().encode(identity)), identity)
    let duplicateFixture = Data(
      #"{"fixtureIdentity":"fixture","fixtureIdentity":"other","syntheticDeviceIdentity":"device"}"#
        .utf8)
    XCTAssertThrowsError(try SimulatedFlashFixtureIdentity(data: duplicateFixture))

    let validReceipt = Data(
      #"{"schemaVersion":"1.0.0","evidenceClass":"simulated","executionMode":"simulated","targetKind":"synthetic","connectKey":null,"toolchainKind":"none","fixtureIdentity":"fixture","scenarioIdentity":"success-delay-0","hardwareSupportEligible":false,"terminalState":"waitingForRecovery","manifestSha256":null}"#
        .utf8)
    XCTAssertEqual(try SimulatedFlashEvidenceReceipt(data: validReceipt).executionMode, "simulated")
    let duplicateReceipt = Data(
      #"{"schemaVersion":"1.0.0","evidenceClass":"simulated","executionMode":"simulated","executionMode":"execute","targetKind":"synthetic","connectKey":null,"toolchainKind":"none","fixtureIdentity":"fixture","scenarioIdentity":"success-delay-0","hardwareSupportEligible":false,"terminalState":"waitingForRecovery","manifestSha256":null}"#
        .utf8)
    XCTAssertThrowsError(try SimulatedFlashEvidenceReceipt(data: duplicateReceipt))
  }

  // TEST-MAC-M1-SIM-001 / configured failure matrix
  func testTEST_MAC_M1_SIM_001_EveryFailurePointFinalizesAsSimulated() async throws {
    for phase in SimulatedFlashPhase.allCases {
      let fixture = try makeFixture(label: "failure-\(phase.rawValue)")
      defer { try? FileManager.default.removeItem(at: fixture.container) }
      let receipt = try await SimulatedFlashProvider().run(
        request(layout: fixture.layout, scenario: .failure(phase: phase)))

      XCTAssertEqual(receipt.evidence.terminalState, .failed, phase.rawValue)
      XCTAssertEqual(receipt.evidence.evidenceClass, .simulated)
      XCTAssertEqual(receipt.phaseOutcomes[phase.index].result, .failed)
      XCTAssertTrue(
        receipt.phaseOutcomes.dropFirst(phase.index + 1).allSatisfy {
          $0.result == .notRun
        })
      assertIsolation(receipt.isolation)
      let reopened = try SimulatedFlashProvider.reopen(fixture.layout)
      XCTAssertEqual(reopened.replay.currentState, .failed)
      XCTAssertEqual(reopened.manifest?.status, "failed")
      XCTAssertEqual(reopened.manifest?.executionMode, "simulated")
    }
  }

  // TEST-MAC-M1-SIM-001 / configured disconnect matrix
  func testTEST_MAC_M1_SIM_001_DisconnectBeforeAndAfterEveryPhaseUsesNoDispatch() async throws {
    for phase in SimulatedFlashPhase.allCases {
      for timing in [SimulatedFlashDisconnectTiming.beforeStep, .afterStep] {
        let fixture = try makeFixture(label: "disconnect-\(phase.rawValue)-\(timing.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let receipt = try await SimulatedFlashProvider().run(
          request(
            layout: fixture.layout,
            scenario: .disconnect(phase: phase, timing: timing)))

        XCTAssertEqual(receipt.evidence.terminalState, .succeeded)
        XCTAssertEqual(receipt.isolation.simulatedDisconnectCount, 1)
        XCTAssertEqual(receipt.phaseOutcomes.map(\.result), [.succeeded, .succeeded, .succeeded])
        assertIsolation(receipt.isolation)
        let reopened = try SimulatedFlashProvider.reopen(fixture.layout)
        XCTAssertEqual(
          reopened.replay.events.filter {
            $0.kind == .stateTransition && $0.stateTransition?.to == .waitingForDevice
          }.count,
          1)
        XCTAssertEqual(reopened.replay.currentState, .succeeded)
      }
    }
  }

  // TEST-MAC-M1-SIM-001 / outcomeUnknown + reconcile + reopen
  func testTEST_MAC_M1_SIM_001_OutcomeUnknownNeverReplaysAndRemainsRecoverable() async throws {
    for phase in SimulatedFlashPhase.allCases {
      let fixture = try makeFixture(label: "unknown-\(phase.rawValue)")
      defer { try? FileManager.default.removeItem(at: fixture.container) }
      let receipt = try await SimulatedFlashProvider().run(
        request(layout: fixture.layout, scenario: .outcomeUnknown(phase: phase)))

      XCTAssertEqual(receipt.evidence.terminalState, .waitingForRecovery)
      XCTAssertNil(receipt.manifest)
      XCTAssertEqual(receipt.phaseOutcomes[phase.index].result, .outcomeUnknown)
      XCTAssertEqual(receipt.reconciliation?.state, .waitingForRecovery)
      XCTAssertEqual(receipt.reconciliation?.outcomeCertainty, .outcomeUnknown)
      XCTAssertEqual(receipt.reconciliation?.destructiveDispatchCount, 0)
      XCTAssertEqual(receipt.reconciliation?.destructiveReplayCount, 0)
      XCTAssertEqual(receipt.reconciliation?.guessCompensationCount, 0)
      assertIsolation(receipt.isolation)

      let reopened = try SimulatedFlashProvider.reopen(fixture.layout)
      XCTAssertNil(reopened.manifest)
      XCTAssertEqual(reopened.replay.executionMode, "simulated")
      XCTAssertEqual(reopened.replay.currentState, .waitingForRecovery)
      XCTAssertFalse(reopened.replay.unknownOutcomes.isEmpty)
      XCTAssertTrue(reopened.replay.requiresRecovery)
      XCTAssertEqual(reopened.replay.destructiveReplayCount, 0)
      XCTAssertEqual(reopened.replay.guessCompensationCount, 0)
      XCTAssertEqual(reopened.durableReceipts.last?.details["manifestSha256"], .null)
    }
  }

  func testReopenRejectsIncompleteOrCrossRecordOutcomeReceiptTampering() async throws {
    let mutations: [(String, (inout [String: JSONValue]) -> Void)] = [
      ("schema", { $0["schemaVersion"] = .string("2.0.0") }),
      ("fixture", { $0["fixtureIdentity"] = .string("different-fixture") }),
      ("scenario", { $0["scenarioIdentity"] = .string("different-scenario") }),
      ("terminal", { $0["terminalState"] = .string(JobState.succeeded.rawValue) }),
      (
        "isolation-nonzero",
        {
          guard case .object(var isolation)? = $0["isolation"] else { return }
          isolation["destructiveDispatchCount"] = .integer(1)
          $0["isolation"] = .object(isolation)
        }
      ),
      (
        "isolation-incomplete",
        {
          guard case .object(var isolation)? = $0["isolation"] else { return }
          isolation.removeValue(forKey: "networkDispatchCount")
          $0["isolation"] = .object(isolation)
        }
      ),
    ]

    for (label, mutate) in mutations {
      let fixture = try makeFixture(label: "reopen-tamper-\(label)")
      defer { try? FileManager.default.removeItem(at: fixture.container) }
      _ = try await SimulatedFlashProvider().run(
        request(
          layout: fixture.layout,
          scenario: .outcomeUnknown(phase: .writeSystemPartition)))
      try rewriteOutcomeAudit(layout: fixture.layout, mutate: mutate)
      XCTAssertThrowsError(try SimulatedFlashProvider.reopen(fixture.layout), label)
    }

    let reportedFixture = try makeFixture(label: "reopen-reported-repro")
    defer { try? FileManager.default.removeItem(at: reportedFixture.container) }
    _ = try await SimulatedFlashProvider().run(
      request(
        layout: reportedFixture.layout,
        scenario: .outcomeUnknown(phase: .writeSystemPartition)))
    try rewriteOutcomeAudit(layout: reportedFixture.layout) {
      $0["fixtureIdentity"] = .string("")
      $0["scenarioIdentity"] = .string("")
      $0["terminalState"] = .string(JobState.succeeded.rawValue)
    }
    XCTAssertThrowsError(try SimulatedFlashProvider.reopen(reportedFixture.layout))
  }

  // TEST-MAC-M1-SIM-001 / deterministic virtual delay
  func testTEST_MAC_M1_SIM_001_VirtualDelayIsInjectedAndDeterministic() async throws {
    let fixture = try makeFixture(label: "delay")
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let delayer = RecordingVirtualDelayer()
    let receipt = try await SimulatedFlashProvider(delayer: delayer).run(
      request(layout: fixture.layout, scenario: .success(delayNanoseconds: 37)))

    let recordedDelays = await delayer.recorded()
    XCTAssertEqual(recordedDelays, [37, 37, 37])
    XCTAssertEqual(receipt.isolation.virtualDelayCount, 3)
    XCTAssertEqual(receipt.evidence.terminalState, .succeeded)
    assertIsolation(receipt.isolation)
  }

  // TEST-MAC-M1-SIM-001 / cancellation before the first simulated phase
  func testTEST_MAC_M1_SIM_001_PreCancelledRunFinalizesAndReleasesAllWork() async throws {
    let fixture = try makeFixture(label: "pre-cancel")
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let provider = SimulatedFlashProvider()
    let runRequest = try request(layout: fixture.layout, scenario: .success())
    let task = Task {
      try await provider.run(runRequest)
    }
    task.cancel()
    let receipt = try await task.value

    XCTAssertEqual(receipt.evidence.terminalState, .cancelled)
    XCTAssertEqual(receipt.phaseOutcomes.first?.result, .cancelled)
    XCTAssertTrue(receipt.phaseOutcomes.dropFirst().allSatisfy { $0.result == .notRun })
    assertIsolation(receipt.isolation)
    let reopened = try SimulatedFlashProvider.reopen(fixture.layout)
    XCTAssertEqual(reopened.replay.currentState, .cancelled)
    XCTAssertEqual(reopened.manifest?.status, "cancelled")
  }

  // TEST-MAC-M1-SIM-001 / cancellation while virtual delay is suspended
  func testTEST_MAC_M1_SIM_001_CancellationReleasesVirtualDelayContinuation() async throws {
    let fixture = try makeFixture(label: "cancel-delay")
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let delayer = BlockingVirtualDelayer()
    let provider = SimulatedFlashProvider(delayer: delayer)
    let runRequest = try request(
      layout: fixture.layout, scenario: .success(delayNanoseconds: 1))
    let task = Task {
      try await provider.run(runRequest)
    }
    await delayer.waitUntilStarted()
    task.cancel()
    let receipt = try await task.value

    XCTAssertEqual(receipt.evidence.terminalState, .cancelled)
    XCTAssertEqual(receipt.phaseOutcomes.first?.result, .cancelled)
    let pendingContinuationCount = await delayer.pendingContinuationCount()
    XCTAssertEqual(pendingContinuationCount, 0)
    assertIsolation(receipt.isolation)
  }

  // TEST-MAC-M1-SIM-001 / repeated-run determinism
  func testTEST_MAC_M1_SIM_001_RepeatedRunProducesIdenticalJournalAuditAndManifest() async throws {
    let first = try makeFixture(
      label: "determinism-a", sessionID: "same-session", jobID: "same-job")
    let second = try makeFixture(
      label: "determinism-b", sessionID: "same-session", jobID: "same-job")
    defer {
      try? FileManager.default.removeItem(at: first.container)
      try? FileManager.default.removeItem(at: second.container)
    }
    let scenario = SimulatedFlashScenario.disconnect(
      phase: .writeSystemPartition, timing: .afterStep, delayNanoseconds: 11)
    let firstReceipt = try await SimulatedFlashProvider(delayer: RecordingVirtualDelayer()).run(
      request(layout: first.layout, scenario: scenario))
    let secondReceipt = try await SimulatedFlashProvider(delayer: RecordingVirtualDelayer()).run(
      request(layout: second.layout, scenario: scenario))

    XCTAssertEqual(
      try Data(contentsOf: first.layout.journalURL),
      try Data(contentsOf: second.layout.journalURL))
    XCTAssertEqual(
      try Data(contentsOf: first.layout.sessionAuditURL),
      try Data(contentsOf: second.layout.sessionAuditURL))
    XCTAssertEqual(
      try Data(contentsOf: first.layout.manifestURL),
      try Data(contentsOf: second.layout.manifestURL))
    XCTAssertEqual(firstReceipt.evidence, secondReceipt.evidence)
    XCTAssertEqual(firstReceipt.phaseOutcomes, secondReceipt.phaseOutcomes)
    XCTAssertEqual(firstReceipt.isolation, secondReceipt.isolation)
    assertIsolation(firstReceipt.isolation)
  }

  func testInvalidIdentityDelayAndSessionReuseFailClosed() async throws {
    XCTAssertThrowsError(
      try SimulatedFlashFixtureIdentity(
        fixtureIdentity: "", syntheticDeviceIdentity: "synthetic-device"))
    XCTAssertThrowsError(
      try SimulatedFlashFixtureIdentity(
        fixtureIdentity: "fixture", syntheticDeviceIdentity: "bad\nidentity"))
    XCTAssertThrowsError(
      try SimulatedFlashFixtureIdentity(
        data: Data(#"{"fixtureIdentity":"","syntheticDeviceIdentity":"device"}"#.utf8)))
    XCTAssertThrowsError(
      try SimulatedFlashFixtureIdentity(
        data: Data(
          #"{"fixtureIdentity":"fixture","syntheticDeviceIdentity":"device","connectKey":"usb"}"#
            .utf8)))

    let invalidTimestamp = try makeFixture(label: "invalid-timestamp")
    defer { try? FileManager.default.removeItem(at: invalidTimestamp.container) }
    let invalidTimestampRequest = SimulatedFlashRunRequest(
      layout: invalidTimestamp.layout,
      fixture: try SimulatedFlashFixtureIdentity(
        fixtureIdentity: "fixture", syntheticDeviceIdentity: "device"),
      scenario: .success(), timestamp: "not-a-timestamp")
    do {
      _ = try await SimulatedFlashProvider().run(invalidTimestampRequest)
      XCTFail("invalid audit timestamp unexpectedly accepted")
    } catch {
      XCTAssertEqual(error as? SimulatedFlashProviderError, .invalidTimestamp)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: invalidTimestamp.layout.journalURL.path))

    let hugeDelay = try makeFixture(label: "huge-delay")
    defer { try? FileManager.default.removeItem(at: hugeDelay.container) }
    do {
      _ = try await SimulatedFlashProvider().run(
        request(
          layout: hugeDelay.layout,
          scenario: .success(delayNanoseconds: UInt64(Int64.max) + 1)))
      XCTFail("out-of-range virtual delay unexpectedly accepted")
    } catch {
      XCTAssertEqual(error as? SimulatedFlashProviderError, .delayOutOfRange)
    }

    let reused = try makeFixture(label: "reuse")
    defer { try? FileManager.default.removeItem(at: reused.container) }
    let provider = SimulatedFlashProvider()
    _ = try await provider.run(request(layout: reused.layout, scenario: .success()))
    do {
      _ = try await provider.run(request(layout: reused.layout, scenario: .success()))
      XCTFail("completed Session unexpectedly reused")
    } catch {
      XCTAssertEqual(error as? SimulatedFlashProviderError, .sessionAlreadyStarted)
    }
  }

  private func request(
    layout: SessionLayout,
    scenario: SimulatedFlashScenario
  ) throws -> SimulatedFlashRunRequest {
    SimulatedFlashRunRequest(
      layout: layout,
      fixture: try SimulatedFlashFixtureIdentity(
        fixtureIdentity: "m1-008-fixture",
        syntheticDeviceIdentity: "synthetic-device-alpha"),
      scenario: scenario,
      timestamp: timestamp)
  }

  private func makeFixture(
    label: String,
    sessionID: String? = nil,
    jobID: String? = nil
  ) throws -> (container: URL, layout: SessionLayout) {
    let container = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-008-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    let root = container.appending(path: "session", directoryHint: .isDirectory)
    for directory in [
      container,
      root,
      root.appending(path: "audit", directoryHint: .isDirectory),
      root.appending(path: "artifacts/raw", directoryHint: .isDirectory),
      root.appending(path: "artifacts/derived", directoryHint: .isDirectory),
      root.appending(path: "artifacts/partial", directoryHint: .isDirectory),
    ] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    }
    return (
      container,
      try SessionLayout(
        sessionID: sessionID ?? "session-\(label)",
        jobID: jobID ?? "job-\(label)",
        root: root)
    )
  }

  private func assertIsolation(
    _ snapshot: SimulatedFlashIsolationSnapshot,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(snapshot.forbiddenOperationCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.hardwareSupportVerifiedWriteCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.realConnectKeyAcceptedCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.externalProcessDispatchCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.networkDispatchCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.hdcDispatchCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.deviceDispatchCount, 0, file: file, line: line)
    XCTAssertEqual(snapshot.destructiveDispatchCount, 0, file: file, line: line)
  }

  private func assertReceiptTamperRejected(
    _ data: Data,
    mutate: (inout [String: Any]) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    var object = try jsonObject(data)
    mutate(&object)
    let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(
      try SimulatedFlashEvidenceReceipt(data: tampered),
      file: file, line: line)
  }

  private func rewriteOutcomeAudit(
    layout: SessionLayout,
    mutate: (inout [String: JSONValue]) -> Void
  ) throws {
    let lines = try Data(contentsOf: layout.sessionAuditURL)
      .split(separator: 0x0A, omittingEmptySubsequences: true)
    let records = try lines.map { try SessionAuditCodec.decode(Data($0)) }
    var rewritten = Data()
    for record in records {
      let replacement: SessionAuditRecord
      if record.category == .outcome {
        var details = record.details
        mutate(&details)
        replacement = try SessionAuditRecord(
          recordID: record.recordID,
          auditID: record.auditID,
          correlationID: record.correlationID,
          sessionID: record.sessionID,
          jobID: record.jobID,
          category: record.category,
          timestamp: record.timestamp,
          details: details)
      } else {
        replacement = record
      }
      rewritten.append(try SessionAuditCodec.encode(replacement))
      rewritten.append(0x0A)
    }
    try rewritten.write(to: layout.sessionAuditURL, options: .atomic)
  }

  private func assertManifestTamperRejected(
    _ data: Data,
    mutate: (inout [String: Any]) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    var object = try jsonObject(data)
    mutate(&object)
    let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(try SessionManifestDocument(data: tampered), file: file, line: line)
  }

  private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
  }
}

extension SimulatedFlashPhase {
  fileprivate var index: Int { SimulatedFlashPhase.allCases.firstIndex(of: self)! }
}

private actor RecordingVirtualDelayer: SimulatedFlashVirtualDelaying {
  private var values: [UInt64] = []

  func delay(nanoseconds: UInt64) async throws {
    try Task.checkCancellation()
    values.append(nanoseconds)
  }

  func recorded() -> [UInt64] { values }
}

private actor BlockingVirtualDelayer: SimulatedFlashVirtualDelaying {
  private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var startCount = 0

  func delay(nanoseconds _: UInt64) async throws {
    startCount += 1
    let waiters = startedWaiters
    startedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    let token = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[token] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(token) }
    }
  }

  func waitUntilStarted() async {
    if startCount > 0 { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func pendingContinuationCount() -> Int { pending.count }

  private func cancel(_ token: UUID) {
    pending.removeValue(forKey: token)?.resume(throwing: CancellationError())
  }
}
