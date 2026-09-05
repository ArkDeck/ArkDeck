import Darwin
import Foundation
import XCTest
@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckOpenHarmony
@testable import ArkDeckProcess
@testable import ArkDeckRuntime
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class HDCControlActionContractTests: XCTestCase {
  private var root: URL!
  private let catalog = String(repeating: "a", count: 64)
  private let now = Date(timeIntervalSince1970: 1_788_220_800)
  private var reference: String { "hdc-endpoint:" + SHA256Hex.string(of: Data("127.0.0.1:8710".utf8)) }
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/hdcc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func intent(_ id: String = "request-one", generation: String = "100000023") throws -> HDCControlActionIntent {
    try .init(["actionRequestId": .string(id), "action": .string("restart"),
      "serverEndpointRef": .string(reference), "expectedServerGeneration": .string(generation)])
  }
  private func impact(_ changes: [String: JSONValue] = [:]) throws -> HDCControlImpact {
    var fields: [String: JSONValue] = ["serverEndpointRef": .string(reference), "endpoint": .string("127.0.0.1:8710"),
      "serverOwnership": .string("unknown"), "serverGeneration": .string("100000023"), "serverHealth": .string("healthy"), "serverVersion": .string("3.2.0d"),
      "tool": .object(["reference": .null, "executablePath": .string("/fixture/hdc"), "source": .string("runtimeConfiguration"),
        "sha256": .string(String(repeating: "b", count: 64)), "signature": .null, "version": .string("3.2.0d"), "trust": .string("unknown")]),
      "affectedTargetIds": .array([]), "affectedJobIds": .array([]), "detectedOtherClientIds": .array([]),
      "otherClientsMayExist": .bool(true), "affectedDeviceObservations": .array([]),
      "criticalJobGate": .object(["state": .string("clear"), "blocking": .array([]), "reasonCode": .null]),
      "interruption": .object(["kind": .string("hdcEndpointUnavailable"), "affectsAllParticipants": .bool(true)]),
      "recovery": .object(["kind": .string("statusThenReconcile"), "replayAllowed": .bool(false)])]
    fields.merge(changes, uniquingKeysWith: { _, new in new })
    return try HDCControlImpact(fields)
  }
  private func error(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) { failure in
      XCTAssertEqual((failure as? AgentExecutionControlFailure)?.code, code, "\(failure)", file: file, line: line)
    }
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let result) = value else { throw NSError(domain: "fixture", code: 1) }; return result
  }

  func testIntentFingerprintExcludesRequestIdentityAndRejectsResolvedFacts() throws {
    let a = try intent(), b = try intent("lost-receipt-retry")
    XCTAssertEqual(try a.fingerprint, try b.fingerprint)
    XCTAssertEqual(try a.fingerprint, "32df6c7f4db9ccefb1eba90a7cc9154e7dca50e737022bc5d0b2cda14ddd17bb")
    XCTAssertNotEqual(try a.fingerprint, try intent(generation: "100000024").fingerprint)
    let canonical = String(decoding: try PortableCanonicalJSON.canonicalBytes(a.canonicalIntent), as: UTF8.self)
    XCTAssertFalse(canonical.contains("request-one")); XCTAssertFalse(canonical.contains("previewId"))
    for (key, value) in ["generation": JSONValue.string("7"), "executablePath": .string("/usr/bin/false"), "confirmation": .bool(true)] {
      var fields = a.request; fields[key] = value
      error("invalidInput") { _ = try HDCControlActionIntent(fields) }
    }
    for text in ["0", "01", "+1", "-1", "18446744073709551615"] {
      error("invalidInput") { _ = try intent(generation: text) }
    }
  }

  func testCanonicalCollectionsCollapseOnlyEqualValuesAndSortByASCII() throws {
    let row: JSONValue = .object(["observationId": .string("obs-1"), "generation": .string("2"), "authorization": .string("authorized"), "health": .string("connected")])
    let a = try impact(["affectedTargetIds": .array([.string("z"), .string("A"), .string("z")]), "affectedDeviceObservations": .array([row, row])])
    XCTAssertEqual(a.value["affectedTargetIds"], .array([.string("A"), .string("z")]))
    XCTAssertEqual(a.value["affectedDeviceObservations"], .array([row]))
    var drifted = try object(row); drifted["generation"] = .string("3")
    error("factsDrifted") { _ = try impact(["affectedDeviceObservations": .array([row, .object(drifted)])]) }
    let blocker: [String: JSONValue] = ["jobId": .string("job-1"), "stepId": .string("step-2"), "state": .string("running"), "safeBoundary": .string("blocked"), "recovery": .string("waitForJob")]
    var changed = blocker; changed["recovery"] = .string("reconcileJob")
    error("factsDrifted") {
      _ = try impact(["affectedJobIds": .array([.string("job-1")]), "criticalJobGate": .object([
        "state": .string("blocked"), "reasonCode": .string("job.running"), "blocking": .array([.object(blocker), .object(changed)])])])
    }
    error("factsDrifted") { _ = try impact(["otherClientsMayExist": .bool(false)]) }
  }

  func testPreviewDigestCoversAllValuesAndRejectsTamperedOrUnsortedRecords() throws {
    let preview = try HDCControlActionPreview(actionID: "action-1", previewID: "preview-1", createdAt: HDCControlActionRecord.timestamp(now),
      expiresAt: HDCControlActionRecord.timestamp(now.addingTimeInterval(300)), impact: impact())
    let digest = try XCTUnwrap(preview.value["previewDigest"])
    for (key, value) in ["serverOwnership": JSONValue.string("arkDeckManaged"), "serverGeneration": .string("100000024"),
      "affectedJobIds": .array([.string("new-job")]), "otherClientsMayExist": .bool(false)] {
      var changed = preview.value; changed[key] = value
      error("recordUnreadable") { _ = try HDCControlActionPreview(value: changed) }
    }
    XCTAssertEqual(preview.value["previewDigest"], digest)
    var unsorted = preview.value; unsorted["affectedTargetIds"] = .array([.string("z"), .string("a")])
    unsorted["previewDigest"] = .string(try HDCControlValue.hash(.object(unsorted.filter { $0.key != "previewDigest" })))
    error("recordUnreadable") { _ = try HDCControlActionPreview(value: unsorted) }
    XCTAssertNotEqual(digest, .string(try intent().fingerprint))
  }

  func testDurableLostReceiptAndCASNeverReplacePublishedPreview() throws {
    let a = try RuntimeHDCControlActionStore(directory: root), b = try RuntimeHDCControlActionStore(directory: root)
    let initial = try a.begin(intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch-1", now: now)
    XCTAssertEqual(try b.begin(intent: intent(), catalogDigest: String(repeating: "c", count: 64), runtimeEpoch: "epoch-2", now: now.addingTimeInterval(20)), initial)
    error("idempotencyConflict") { _ = try b.begin(intent: intent(generation: "2"), catalogDigest: catalog, runtimeEpoch: "epoch-1", now: now) }
    let preview = try initial.publishing(impact: impact(), relations: [], blocker: nil, now: now.addingTimeInterval(1))
    try a.replace(preview, expectedGeneration: 1)
    error("resourceConflict") { try b.replace(preview, expectedGeneration: 1) }
    XCTAssertEqual(try b.load(actionID: initial.actionID), preview)
    XCTAssertEqual(try b.list(), [preview]); XCTAssertEqual(try b.list(), [preview], "enumeration must not reuse a drained directory offset")
    let other = try initial.publishing(impact: impact(["serverOwnership": .string("external")]), relations: [], blocker: nil, now: now.addingTimeInterval(2))
    var replaced = other.value; replaced["generation"] = .string("3")
    error("resourceConflict") { try b.replace(HDCControlActionRecord(value: replaced), expectedGeneration: 2) }
    let stopped = try preview.invalidated(reason: "hdc.previewDrifted", expired: false, now: now.addingTimeInterval(3))
    try b.replace(stopped, expectedGeneration: 2)
    XCTAssertEqual(try RuntimeHDCControlActionStore(directory: root).load(requestID: "request-one"), stopped)
    XCTAssertEqual(stopped.preview, preview.preview)
  }

  func testDirectoryAndRecordIdentityCannotBecomeAbsenceOrAnotherOwner() throws {
    let store = try RuntimeHDCControlActionStore(directory: root)
    _ = try store.begin(intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch", now: now)
    let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
    let bytes = try Data(contentsOf: file)
    try Data("{\"duplicate\":1,\"duplicate\":2}".utf8).write(to: file)
    XCTAssertThrowsError(try store.load(requestID: "request-one"))
    try bytes.write(to: file)
    let linked = root.appending(path: "outside-copy")
    try FileManager.default.linkItem(at: file, to: linked)
    XCTAssertThrowsError(try store.list())
    try FileManager.default.removeItem(at: linked)
    let moved = root.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: root, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    error("recordUnreadable") { _ = try store.begin(intent: intent("second"), catalogDigest: catalog, runtimeEpoch: "epoch", now: now) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testAnotherProcessLockBlocksBeforeCreatingARecord() throws {
    let store = try RuntimeHDCControlActionStore(directory: root)
    let lockPath = root.appending(path: ".lock").path
    let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0); defer { flock(fd, LOCK_UN); close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    error("resourceConflict") { _ = try store.begin(intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch", now: now) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".lock"])
    XCTAssertEqual(flock(fd, LOCK_UN), 0)
    XCTAssertEqual(try store.begin(intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch", now: now).generation, 1)
  }

  private actor Source: HDCControlImpactObserving {
    nonisolated let endpointReference: String
    private var value: HDCControlImpactReading
    private(set) var reads = 0
    init(reference: String, value: HDCControlImpactReading) { endpointReference = reference; self.value = value }
    func readImpact() async throws -> HDCControlImpactReading { reads += 1; return value }
    func change(_ value: HDCControlImpactReading) { self.value = value }
  }

  func testCoordinatorRediscoversOnePreviewAndReconcilesDriftWithoutDispatch() async throws {
    let source = Source(reference: reference, value: .init(impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let coordinator = try RuntimeHDCControlActionCoordinator(directory: root, source: source, catalogDigest: catalog, epoch: "epoch", now: { date })
    let first = try object(await coordinator.preview(intent().request))
    let second = try await coordinator.preview(intent().request)
    XCTAssertEqual(second, .object(first))
    let count = await source.reads; XCTAssertEqual(count, 1)
    guard case .string(let id)? = first["controlActionId"] else { return XCTFail("missing identity") }
    XCTAssertEqual(first["state"], .string("previewReady")); XCTAssertEqual(first["dispatchCount"], .integer(0))
    let page = try object(await coordinator.list(filters: [:], pageSize: 1, cursor: nil))
    XCTAssertEqual(page["items"], .array([.object(first)]))
    await source.change(.init(impact: try impact(["detectedOtherClientIds": .array([.string("another-client")])]), observationRelations: [], blockerReasonCode: nil))
    let changed = try object(await coordinator.reconcile(id))
    XCTAssertEqual(changed["state"], .string("previewDrifted")); XCTAssertEqual(changed["preview"], first["preview"])
    XCTAssertEqual(changed["dispatchCount"], .integer(0))
    let replay = try await coordinator.preview(intent().request)
    XCTAssertEqual(replay, .object(changed))
  }

  func testCriticalUnknownAndServerUnknownNeverProduceAReadyPreview() async throws {
    let gate: JSONValue = .object(["state": .string("unknown"), "blocking": .array([]), "reasonCode": .string("job.inventoryUnreadable")])
    let source = Source(reference: reference, value: .init(impact: try impact(["criticalJobGate": gate]), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let coordinator = try RuntimeHDCControlActionCoordinator(directory: root, source: source, catalogDigest: catalog, epoch: "epoch", now: { date })
    let a = try object(await coordinator.preview(intent().request))
    XCTAssertEqual(a["state"], .string("blocked")); XCTAssertEqual(a["blockerReasonCode"], .string("hdc.criticalJobsUnresolved"))
    await source.change(.init(impact: try impact(["serverHealth": .string("unknown"), "serverVersion": .null]), observationRelations: [], blockerReasonCode: nil))
    let b = try object(await coordinator.preview(intent("second").request))
    XCTAssertEqual(b["state"], .string("blocked")); XCTAssertEqual(b["blockerReasonCode"], .string("hdc.serverHealthUnproven"))
    XCTAssertEqual(b["humanAction"], .null); XCTAssertEqual(b["dispatchCount"], .integer(0))
  }

  func testRestartAndExpiryInvalidateOldPreviewWithoutReobservation() async throws {
    let source = Source(reference: reference, value: .init(impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let a = try RuntimeHDCControlActionCoordinator(directory: root, source: source, catalogDigest: catalog, epoch: "epoch-a", now: { date })
    let first = try object(await a.preview(intent().request))
    let b = try RuntimeHDCControlActionCoordinator(directory: root, source: source, catalogDigest: catalog, epoch: "epoch-b", now: { date })
    let restarted = try object(await b.preview(intent().request))
    XCTAssertEqual(restarted["state"], .string("previewDrifted")); XCTAssertEqual(restarted["preview"], first["preview"])
    _ = try await a.preview(intent("second").request)
    let expiredOwner = try RuntimeHDCControlActionCoordinator(directory: root, source: source, catalogDigest: catalog, epoch: "epoch-a", now: { date.addingTimeInterval(300) })
    let expired = try object(await expiredOwner.preview(intent("second").request))
    XCTAssertEqual(expired["state"], .string("expired")); XCTAssertEqual(expired["dispatchCount"], .integer(0))
    let reads = await source.reads; XCTAssertEqual(reads, 2)
  }

  func testExactRestartMintsOneDurableControlActionHARAfterFreshEquality() async throws {
    let source = Source(reference: reference, value: .init(impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let coordinator = try RuntimeHDCControlActionCoordinator(
      directory: root, source: source, catalogDigest: catalog, epoch: "epoch", now: { date })
    let previewOwner = try object(await coordinator.preview(intent().request))
    guard case .string(let actionID)? = previewOwner["controlActionId"],
      case .object(let preview)? = previewOwner["preview"],
      case .string(let previewID)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"] else { return XCTFail("missing preview tuple") }
    let awaiting = try object(await coordinator.requestRestart(
      actionID: actionID, previewID: previewID, previewDigest: digest))
    XCTAssertEqual(awaiting["state"], .string("awaitingImpactApproval"))
    XCTAssertEqual(awaiting["generation"], .string("3"))
    XCTAssertEqual(awaiting["dispatchCount"], .integer(0))
    guard case .object(let action)? = awaiting["humanAction"],
      case .string(let humanActionID)? = action["actionId"] else { return XCTFail("missing impact approval") }
    XCTAssertEqual(action["owner"], .object(["kind": .string("controlAction"), "id": .string(actionID)]))
    XCTAssertEqual(action["category"], .string("impactApproval"))
    XCTAssertEqual(action["reasonCode"], .string("policy.impactApprovalRequired"))
    XCTAssertEqual(action["prohibitedAutomation"], .array([.string("selfApproval")]))
    XCTAssertEqual(action["newDispatchCount"], .integer(0))
    let replay = try await coordinator.requestRestart(
      actionID: actionID, previewID: previewID, previewDigest: digest)
    XCTAssertEqual(replay, .object(awaiting))
    let readCount = await source.reads
    XCTAssertEqual(readCount, 2, "lost restart receipt must not mint or reobserve a second HAR")
    let discoveredAction = try await coordinator.humanAction(humanActionID)
    XCTAssertEqual(discoveredAction, .object(action))
    let reopened = try RuntimeHDCControlActionCoordinator(
      directory: root, source: source, catalogDigest: catalog, epoch: "epoch", now: { date })
    let reopenedOwner = try await reopened.show(actionID)
    XCTAssertEqual(reopenedOwner, .object(awaiting))
    do {
      _ = try await reopened.requestRestart(
        actionID: actionID, previewID: previewID,
        previewDigest: String(repeating: "0", count: 64))
      XCTFail("mismatched preview digest was accepted")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "reviewedPlanMismatch")
    }
  }

  func testRestartFreshDriftInvalidatesPreviewBeforeHARAndDispatch() async throws {
    let source = Source(reference: reference, value: .init(impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let coordinator = try RuntimeHDCControlActionCoordinator(
      directory: root, source: source, catalogDigest: catalog, epoch: "epoch", now: { date })
    let owner = try object(await coordinator.preview(intent().request))
    guard case .string(let actionID)? = owner["controlActionId"], case .object(let preview)? = owner["preview"],
      case .string(let previewID)? = preview["previewId"], case .string(let digest)? = preview["previewDigest"]
    else { return XCTFail("missing preview tuple") }
    await source.change(.init(
      impact: try impact(["detectedOtherClientIds": .array([.string("late-client")])]),
      observationRelations: [], blockerReasonCode: nil))
    do {
      _ = try await coordinator.requestRestart(actionID: actionID, previewID: previewID, previewDigest: digest)
      XCTFail("drifted impact was accepted")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "factsDrifted")
      if case .object(let details)? = failure.details["controlAction"] {
        XCTAssertEqual(details["state"], .string("previewDrifted"))
      } else { XCTFail("drift refusal omitted the durable owner") }
    }
    let invalid = try object(await coordinator.show(actionID))
    XCTAssertEqual(invalid["state"], .string("previewDrifted"))
    XCTAssertEqual(invalid["humanAction"], .null)
    XCTAssertEqual(invalid["dispatchCount"], .integer(0))
  }
  func testRealCLIAndUDSDiscoverTheDurablePreviewAndRejectCallerFacts() async throws {
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher, capabilityStore: capabilities,
      nowUTC: { "2026-09-01T00:00:00Z" })
    let source = Source(reference: reference, value: .init(impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let owner = try RuntimeHDCControlActionCoordinator(directory: root.appending(path: "actions"), source: source,
      catalogDigest: catalog, epoch: "epoch", now: { date })
    let humanActions = try RuntimeHumanActionResourceCoordinator(
      directory: root.appending(path: "human-pages"), agents: nil, controls: owner)
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, humanActionResources: humanActions,
      hdcControlActions: owner)
    let server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server.start(); defer { server.stop() }
    func cli(_ arguments: [String]) throws -> [String: JSONValue] {
      let output = root.appending(path: "stdout-\(UUID()).json")
      FileManager.default.createFile(atPath: output.path, contents: nil)
      let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
      let child = Process()
      child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
      child.arguments = arguments + ["--socket", server.socketURL.path, "--output", "json", "--timeout", "5s"]
      child.standardOutput = handle; child.standardError = FileHandle.nullDevice
      try child.run()
      let limit = Date().addingTimeInterval(10)
      while child.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
      if child.isRunning { child.terminate(); throw NSError(domain: "CLI timed out", code: 1) }
      child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
      let envelope = try object(CLIStrictJSON.decode(Data(contentsOf: output)))
      XCTAssertEqual(envelope["ok"], .bool(true))
      return try object(XCTUnwrap(envelope["result"]))
    }
    let request = ["runtime", "hdc", "impact-preview", "--action", "restart", "--server-endpoint-ref", reference,
      "--expected-server-generation", "100000023", "--action-request-id", "cli-action"]
    let preview = try cli(request)
    guard case .string(let id)? = preview["controlActionId"],
      case .object(let previewDocument)? = preview["preview"],
      case .string(let previewID)? = previewDocument["previewId"],
      case .string(let previewDigest)? = previewDocument["previewDigest"]
    else { return XCTFail("missing control-action receipt") }
    XCTAssertEqual(try cli(request), preview)
    XCTAssertEqual(try cli(["control-action", "show", "--control-action", id]), preview)
    XCTAssertEqual(try cli(["control-action", "list", "--page-size", "1"])["items"], .array([.object(preview)]))
    XCTAssertEqual(try cli(["control-action", "reconcile", "--control-action", id]), preview)
    let restart = try cli(["runtime", "hdc", "restart", "--control-action", id,
      "--preview-id", previewID, "--preview-digest", previewDigest])
    XCTAssertEqual(restart["state"], .string("awaitingImpactApproval"))
    XCTAssertEqual(restart["dispatchCount"], .integer(0))
    guard case .object(let action)? = restart["humanAction"],
      case .string(let actionID)? = action["actionId"],
      case .string(let resume)? = action["resumeReference"]
    else { return XCTFail("missing impact approval HAR") }
    XCTAssertEqual(try cli(["runtime", "hdc", "restart", "--control-action", id,
      "--preview-id", previewID, "--preview-digest", previewDigest]), restart)
    XCTAssertEqual(try cli(["human-action", "show", "--human-action", actionID]), action)
    let humanPage = try cli(["human-action", "list", "--owner-kind", "controlAction", "--owner", id])
    XCTAssertEqual(humanPage["items"], .array([.object(action)]))
    func wire(_ method: String, _ fields: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      let request = try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity), "id": .string("wire-" + UUID().uuidString.lowercased()),
        "method": .string(method), "params": .object(fields),
      ]))
      return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(request))
    }
    let agentResume = try await wire("agent.resume", ["resumeReference": .string(resume)])
    XCTAssertEqual(agentResume.error?.code, "admissionDenied")
    XCTAssertEqual(agentResume.error?.details?["newDispatchCount"], .integer(0))
    let rawHumanResume = try await wire("human-action.resume", [
      "humanAction": .string(actionID), "resumeReference": .string(resume),
    ])
    XCTAssertTrue(rawHumanResume.ok)
    XCTAssertEqual(rawHumanResume.result, .object(action), "transport-free RPC must return the same HAR")
    let challengeFrame = try PortableCanonicalJSON.canonicalBytes(.object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity), "id": .string("interactive-challenge"),
      "method": .string("human-action.resume"), "params": .object([
        "humanAction": .string(actionID), "resumeReference": .string(resume),
      ]),
    ]))
    let challengeResponse = try JSONDecoder().decode(
      AgentWireProtocol.Response.self,
      from: await handler.handleLine(
        challengeFrame, context: .unixSocket(foregroundConsole: true)))
    XCTAssertTrue(challengeResponse.ok)
    guard case .object(let challenge)? = challengeResponse.result,
      case .string(let challengeText)? = challenge["challenge"]
    else { return XCTFail("foreground console did not receive a challenge") }
    XCTAssertEqual(challenge["schemaVersion"], .string("arkdeck.impact-approval-challenge/1"))
    XCTAssertEqual(challenge["interactionOrigin"], .string("interactiveConsole"))
    XCTAssertEqual(challenge["newDispatchCount"], .integer(0))
    XCTAssertTrue(challengeText.hasPrefix("ARKDECK-"))
    XCTAssertEqual(challengeText.utf8.count, 17)
    let afterChallenge = try object(await owner.show(id))
    XCTAssertFalse(String(decoding: try PortableCanonicalJSON.canonicalBytes(.object(afterChallenge)), as: UTF8.self).contains(challengeText))
    let xpcResponse = try JSONDecoder().decode(
      AgentWireProtocol.Response.self,
      from: await handler.handleLine(challengeFrame, context: .appXPC))
    XCTAssertEqual(xpcResponse.result, .object(action), "XPC caller presence is not explicit UI confirmation")
    let preseededFrame = try PortableCanonicalJSON.canonicalBytes(.object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity), "id": .string("preseeded-response"),
      "method": .string("human-action.resume"), "params": .object([
        "humanAction": .string(actionID), "resumeReference": .string(resume),
        "challengeResponse": .string(challengeText),
      ]),
    ]))
    let untrustedContexts: [RuntimeControlRequestContext] = [
      .direct, .appXPC, .unixSocket(foregroundConsole: false),
    ]
    for context in untrustedContexts {
      let response = try JSONDecoder().decode(
        AgentWireProtocol.Response.self,
        from: await handler.handleLine(preseededFrame, context: context))
      XCTAssertEqual(
        response.result, .object(action),
        "a preseeded response outside the foreground UDS console must not advance approval")
    }
    let afterPreseededResponses = try object(await owner.show(id))
    XCTAssertEqual(
      afterPreseededResponses["state"], .string("awaitingImpactApproval"))
    for (version, fields, code) in [(ArkDeckControlProtocol.currentVersion, ["controlAction": JSONValue.string(id), "executable": .string("/usr/bin/false")], "invalidInput"),
      ("2.0.0", ["controlAction": JSONValue.string(id)], "unsupportedProtocolVersion")] {
      let request = try PortableCanonicalJSON.canonicalBytes(.object(["protocolVersion": .string(version), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity), "id": .string("read-control"),
        "method": .string("control-action.show"), "params": .object(fields)]))
      let response = try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(request))
      XCTAssertEqual(response.error?.code, code)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let jobs = try await engine.listJobs(); XCTAssertTrue(jobs.isEmpty)
  }

  func testUDSPeerClassifierRequiresForegroundControllingTTYForChallenge() async throws {
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-01T00:00:00Z" })
    let source = Source(reference: reference, value: .init(
      impact: try impact(), observationRelations: [], blockerReasonCode: nil))
    let date = now
    let owner = try RuntimeHDCControlActionCoordinator(
      directory: root.appending(path: "actions"), source: source,
      catalogDigest: catalog, epoch: "epoch", now: { date })
    let previewOwner = try object(await owner.preview(intent().request))
    guard case .string(let controlActionID)? = previewOwner["controlActionId"],
      case .object(let preview)? = previewOwner["preview"],
      case .string(let previewID)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"] else { return XCTFail("missing preview") }
    let awaiting = try object(await owner.requestRestart(
      actionID: controlActionID, previewID: previewID, previewDigest: digest))
    guard case .object(let action)? = awaiting["humanAction"],
      case .string(let actionID)? = action["actionId"],
      case .string(let resume)? = action["resumeReference"] else { return XCTFail("missing HAR") }
    let resources = try RuntimeHumanActionResourceCoordinator(
      directory: root.appending(path: "human-pages"), agents: nil, controls: owner)
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, humanActionResources: resources,
      hdcControlActions: owner)
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "control"), handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server.start(); defer { server.stop() }

    let scriptURL = root.appending(path: "peer.py")
    try Data("""
      import json, socket, sys
      s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      s.connect(sys.argv[1])
      request = {"protocolVersion":"1.0.0","contractIdentity":"\(ArkDeckControlProtocol.contractIdentity)","id":"peer-check","method":"human-action.resume","params":{"humanAction":sys.argv[2],"resumeReference":sys.argv[3]}}
      s.sendall((json.dumps(request, separators=(',', ':')) + '\\n').encode())
      data = b''
      while not data.endswith(b'\\n'):
          chunk = s.recv(65536)
          if not chunk: break
          data += chunk
      open(sys.argv[4], 'wb').write(data)
      """.utf8).write(to: scriptURL)

    func invoke(insidePTY: Bool) throws -> [String: JSONValue] {
      let resultURL = root.appending(path: "peer-result-\(UUID().uuidString).json")
      let process = Process()
      let arguments = [scriptURL.path, server.socketURL.path, actionID, resume, resultURL.path]
      if insidePTY {
        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = ["-q", root.appending(path: "typescript-\(UUID().uuidString)").path,
          "/usr/bin/python3"] + arguments
        process.standardInput = Pipe()
      } else {
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
      }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = Date().addingTimeInterval(10)
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if process.isRunning { process.terminate(); throw NSError(domain: "peer timed out", code: 1) }
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
      let response = try object(CLIStrictJSON.decode(Data(contentsOf: resultURL)))
      XCTAssertEqual(response["ok"], .bool(true))
      return try object(XCTUnwrap(response["result"]))
    }

    let redirected = try invoke(insidePTY: false)
    XCTAssertEqual(redirected["schemaVersion"], .string("arkdeck.human-action/1"))
    XCTAssertNil(redirected["challenge"])
    let foreground = try invoke(insidePTY: true)
    XCTAssertEqual(foreground["schemaVersion"], .string("arkdeck.impact-approval-challenge/1"))
    XCTAssertEqual(foreground["interactionOrigin"], .string("interactiveConsole"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testRealCLIUsesTwoForegroundPTYRequestsAndEmitsOneMachineDocument()
    async throws
  {
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "pty-caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "pty-engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-01T00:00:00Z" })
    let source = Source(
      reference: reference,
      value: .init(impact: try impact([
        "serverOwnership": .string("external"),
        "serverGeneration": .string("7"),
      ]), observationRelations: [], blockerReasonCode: nil))
    let driver = RecordingLifecycleDriver()
    let date = now
    let owner = try RuntimeHDCControlActionCoordinator(
      directory: root.appending(path: "pty-actions"), source: source,
      lifecycleDriver: driver, catalogDigest: catalog, epoch: "epoch",
      now: { date })
    let previewOwner = try object(await owner.preview(
      intent("pty-two-rpc", generation: "7").request))
    guard case .string(let ownerID)? = previewOwner["controlActionId"],
      case .object(let preview)? = previewOwner["preview"],
      case .string(let previewID)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { return XCTFail("missing PTY control preview") }
    let awaiting = try object(await owner.requestRestart(
      actionID: ownerID, previewID: previewID, previewDigest: digest))
    guard case .object(let action)? = awaiting["humanAction"],
      case .string(let actionID)? = action["actionId"],
      case .string(let resume)? = action["resumeReference"]
    else { return XCTFail("missing PTY human action") }
    let resources = try RuntimeHumanActionResourceCoordinator(
      directory: root.appending(path: "pty-human-pages"), agents: nil,
      controls: owner)
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, humanActionResources: resources,
      hdcControlActions: owner)
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "pty-control"), handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }

    let wrapper = root.appending(path: "pty-exec.py")
    try Data("""
      import os, sys
      output = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
      os.dup2(output, 1)
      os.close(output)
      os.execv(sys.argv[2], sys.argv[2:])
      """.utf8).write(to: wrapper)
    let stdout = root.appending(path: "pty-stdout.json")
    let transcript = root.appending(path: "pty-transcript.txt")
    let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appending(path: "arkdeck")
    let input = Pipe()
    let terminal = Pipe()
    let terminalCapture = LockedDataCapture()
    terminal.fileHandleForReading.readabilityHandler = { handle in
      let bytes = handle.availableData
      if !bytes.isEmpty { terminalCapture.append(bytes) }
    }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/script")
    process.arguments = [
      "-q", transcript.path, "/usr/bin/python3", wrapper.path, stdout.path,
      cli.path, "human-action", "resume", "--human-action", actionID,
      "--resume-reference", resume, "--socket", server.socketURL.path,
      "--output", "json", "--timeout", "5s",
    ]
    process.standardInput = input
    process.standardOutput = terminal
    process.standardError = FileHandle.nullDevice
    try process.run()

    let challengePattern = try NSRegularExpression(
      pattern: "ARKDECK-[A-Z0-9]{9}")
    let promptDeadline = Date().addingTimeInterval(10)
    var typedChallenge: String?
    while process.isRunning, Date() < promptDeadline, typedChallenge == nil {
      let text = terminalCapture.text
      if !text.isEmpty {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = challengePattern.firstMatch(in: text, range: range),
          let matchRange = Range(match.range, in: text)
        { typedChallenge = String(text[matchRange]) }
      }
      if typedChallenge == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    guard let typedChallenge else {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      terminal.fileHandleForReading.readabilityHandler = nil
      let transcriptText = terminalCapture.text
      let stdoutText = (try? String(contentsOf: stdout, encoding: .utf8)) ?? "<missing>"
      return XCTFail(
        "real CLI never rendered its Runtime challenge; status=\(process.terminationStatus) transcript=\(transcriptText) stdout=\(stdoutText)")
    }
    // `script` presents a terminal in canonical mode; carriage return is the
    // physical Enter key and is translated by the PTY before the CLI reads it.
    input.fileHandleForWriting.write(Data((typedChallenge + "\r").utf8))
    let exitDeadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < exitDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
      process.terminate()
      return XCTFail("real CLI did not finish its second foreground request")
    }
    process.waitUntilExit()
    try input.fileHandleForWriting.close()
    terminal.fileHandleForReading.readabilityHandler = nil

    let stdoutBytes = try Data(contentsOf: stdout)
    let envelope = try object(CLIStrictJSON.decode(stdoutBytes))
    let stdoutText = String(decoding: stdoutBytes, as: UTF8.self)
    XCTAssertEqual(envelope["ok"], .bool(true), stdoutText)
    guard case .object(let result)? = envelope["result"] else {
      return XCTFail("CLI result envelope omitted the control action: \(stdoutText)")
    }
    XCTAssertEqual(result["controlActionId"], .string(ownerID))
    XCTAssertEqual(result["state"], .string("failed"))
    XCTAssertEqual(result["dispatchCount"], .integer(0))
    XCTAssertEqual(driver.restartCount, 1)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    XCTAssertFalse(stdoutText.contains(typedChallenge))
    XCTAssertEqual(
      stdoutText.split(separator: "\n", omittingEmptySubsequences: true).count,
      1, "machine stdout must contain exactly one final document")
  }

  func testProductionImpactSourceKeepsUnknownExecutableUnreadyAndPersistsIndependentRelations() async throws {
    let path = root.appending(path: "hdc")
    try FileManager.default.copyItem(at: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckFakeHDCFixture"), to: path)
    let executable = ResolvedExecutable(path: path.path, sha256: SHA256Hex.string(of: try Data(contentsOf: path)))
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher, capabilityStore: capabilities,
      nowUTC: { "2026-09-01T00:00:00Z" })
    let targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let port = TargetObservationCoordinatorContractTests.Port()
    let observations = TargetObservationCoordinator(observation: port, targetStore: targets, usbRelations: { try port.relations() }, nowUTC: { "2026-09-01T00:00:00Z" })
    let source = HeadlessHDCControlImpactSource(executable: executable, endpoint: try HDCServerEndpointSelector.select(inheritedEnvironment: [:]),
      managedLaunch: { nil }, engine: engine, targets: targets, observations: observations)
    let reading = try await source.readImpact()
    XCTAssertEqual(reading.impact.value["serverGeneration"], .null)
    XCTAssertEqual(reading.impact.value["serverHealth"], .string("unknown"))
    XCTAssertEqual(reading.observationRelations.count, 1)
    let tool = try object(XCTUnwrap(reading.impact.value["tool"]))
    XCTAssertEqual(tool["sha256"], .string(executable.sha256))
    let action = try HDCControlActionRecord(intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch", now: now)
    let published = try action.publishing(impact: reading.impact, relations: reading.observationRelations, blocker: reading.blockerReasonCode, now: now)
    let projection = String(decoding: try PortableCanonicalJSON.canonicalBytes(published.projection), as: UTF8.self)
    XCTAssertFalse(projection.contains("150100424a544e4600"), "private relation proof must not leak a transport address")
    XCTAssertFalse(projection.contains("attachmentId"))
    port.setRelations([])
    let unproved = try await source.readImpact()
    XCTAssertFalse(unproved.impact.criticalGateIsClear)
    XCTAssertTrue(unproved.observationRelations.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0, "static fixture inspection must not run the candidate HDC")
    XCTAssertTrue(try targets.list().isEmpty, "impact preview must not adopt a target")
  }

  func testApprovedControlActionUsesAcceptedLifecycleAuditAndOneLaunchWindow() async throws {
    let store = try RuntimeHDCControlActionStore(directory: root.appending(path: "records"))
    let initial = try store.begin(
      intent: intent("lifecycle-request", generation: "7"), catalogDigest: catalog,
      runtimeEpoch: "epoch", now: now)
    let approvedImpact = try impact([
      "serverOwnership": .string("external"), "serverGeneration": .string("7"),
    ])
    let published = try initial.publishing(
      impact: approvedImpact, relations: [], blocker: nil,
      now: now.addingTimeInterval(1))
    try store.replace(published, expectedGeneration: initial.generation)
    guard case .string(let previewID)? = published.preview?.value["previewId"],
      case .string(let previewDigest)? = published.preview?.value["previewDigest"]
    else { return XCTFail("published preview tuple missing") }
    let awaiting = try published.requestingImpactApproval(
      previewID: previewID, previewDigest: previewDigest,
      now: now.addingTimeInterval(2))
    try store.replace(awaiting, expectedGeneration: published.generation)
    let challengeText = "ARKDECK-A1B2C3D4E"
    let challenged = try awaiting.issuingInteractiveChallenge(
      challenge: challengeText, now: now.addingTimeInterval(3))
    try store.replace(challenged, expectedGeneration: awaiting.generation)
    let approved = try challenged.recordingInteractiveApproval(
      response: challengeText, now: now.addingTimeInterval(4))
    try store.replace(approved, expectedGeneration: challenged.generation)

    let launchCount = LockedCounter()
    let auditNow = now.addingTimeInterval(5)
    let audit = RuntimeHDCControlLifecycleAuditStore(
      store: store, actionID: initial.actionID,
      now: { auditNow },
      onLaunchWindowEntered: { launchCount.increment() })
    let router = RuntimeHDCControlLifecycleAuditRouter()
    let binding = try router.bind(audit)
    defer { try? router.unbind(binding) }
    let supervisor = HDCServerSupervisor(auditStore: router)
    let endpoint = HDCServerEndpoint("127.0.0.1:8710")
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"),
          generation: 7, ownership: .external)),
      reason: "control-action fixture identity")
    await supervisor.setOtherClientDetection(
      .unavailableExternalClientsMayStillExist, for: endpoint)
    guard case .ready(let lifecyclePreview) = await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(lifecyclePreview.id)
    else { return XCTFail("fixture must establish the accepted lifecycle chain") }

    let executable = root.appending(path: "lifecycle-hdc")
    try FileManager.default.copyItem(
      at: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appending(path: "ArkDeckFakeHDCFixture"),
      to: executable)
    let candidate = HDCCandidate(
      path: executable, source: .userConfigured,
      sha256: SHA256Hex.string(of: try Data(contentsOf: executable)))
    let semantic = HDCRegisteredSemanticProfile.testOnlyFake(
      executableSHA256: candidate.sha256,
      selectedDeviceAuthorizationSHA256: String(repeating: "c", count: 64))
    let invocationLog = root.appending(path: "lifecycle-invocations.log")
    let executor = HDCProcessLifecycleExecutor(
      toolchain: candidate, semanticProfile: semantic,
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
      ], durableAuthorization: router, supervisor: supervisor,
      postDispatchProbe: { _ in .generation(8) })
    let coreStep = try HDCServerLifecycleStep.coreWorkflowStep(
      confirmation: confirmation)
    let dispatch = await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: coreStep, using: executor)
    XCTAssertEqual(
      dispatch,
      .completed(.succeeded(resultingGeneration: 8)))

    let terminal = try audit.record()
    XCTAssertEqual(terminal.state, "succeeded")
    XCTAssertEqual(
      terminal.lifecycleAudit.map(\.kind),
      ["impactPreview", "confirmation", "intent", "actualCommand",
        "launchWindowEntered", "outcome", "reconciliation"])
    XCTAssertEqual(launchCount.value, 1)
    XCTAssertEqual(
      terminal.lifecycleAudit.first(where: { $0.kind == "actualCommand" })?.payload["argv"],
      .array([.string("-s"), .string(endpoint.rawValue), .string("kill"), .string("-r")]))
    let projection = try object(terminal.projection)
    XCTAssertEqual(projection["dispatchCount"], .integer(1))
    let durableBytes = try Data(contentsOf: try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: root.appending(path: "records"), includingPropertiesForKeys: nil)
        .first(where: { $0.pathExtension == "json" })))
    XCTAssertFalse(String(decoding: durableBytes, as: UTF8.self).contains(challengeText))
  }

  func testChallengeMismatchAndExpiryNeverResolveOrDispatch() throws {
    let initial = try HDCControlActionRecord(
      intent: intent(), catalogDigest: catalog, runtimeEpoch: "epoch", now: now)
    let published = try initial.publishing(
      impact: impact(), relations: [], blocker: nil, now: now.addingTimeInterval(1))
    guard case .string(let previewID)? = published.preview?.value["previewId"],
      case .string(let previewDigest)? = published.preview?.value["previewDigest"]
    else { return XCTFail("published preview tuple missing") }
    let awaiting = try published.requestingImpactApproval(
      previewID: previewID, previewDigest: previewDigest,
      now: now.addingTimeInterval(2))
    let challenged = try awaiting.issuingInteractiveChallenge(
      challenge: "ARKDECK-123456789", now: now.addingTimeInterval(3))
    error("impactApprovalChallengeMismatch") {
      _ = try challenged.recordingInteractiveApproval(
        response: "ARKDECK-987654321", now: now.addingTimeInterval(4))
    }
    error("impactApprovalChallengeExpired") {
      _ = try challenged.recordingInteractiveApproval(
        response: "ARKDECK-123456789", now: now.addingTimeInterval(124))
    }
    XCTAssertEqual(challenged.state, "awaitingImpactApproval")
    XCTAssertNil(challenged.interactionReceipt)
    XCTAssertTrue(challenged.lifecycleAudit.isEmpty)
  }

  func testInteractiveChallengeIsConsumedOnceUnderTheFinalInterlock() async throws {
    let source = Source(
      reference: reference,
      value: .init(impact: try impact([
        "serverOwnership": .string("external"),
        "serverGeneration": .string("7"),
      ]), observationRelations: [], blockerReasonCode: nil))
    let driver = RecordingLifecycleDriver()
    let date = now
    let directory = root.appending(path: "single-consumption")
    let coordinator = try RuntimeHDCControlActionCoordinator(
      directory: directory, source: source, lifecycleDriver: driver,
      catalogDigest: catalog, epoch: "epoch", now: { date })
    let owner = try object(await coordinator.preview(
      intent("single-consumption", generation: "7").request))
    guard case .string(let ownerID)? = owner["controlActionId"],
      case .object(let preview)? = owner["preview"],
      case .string(let previewID)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { return XCTFail("missing control action preview") }
    let awaiting = try object(await coordinator.requestRestart(
      actionID: ownerID, previewID: previewID, previewDigest: digest))
    guard case .object(let humanAction)? = awaiting["humanAction"],
      case .string(let actionID)? = humanAction["actionId"],
      case .string(let resume)? = humanAction["resumeReference"]
    else { return XCTFail("missing impact approval") }
    let challenge = try object(await coordinator.issueInteractiveChallenge(
      actionID: actionID, resumeReference: resume))
    guard case .string(let response)? = challenge["challenge"]
    else { return XCTFail("missing one-time challenge") }

    do {
      _ = try await coordinator.consumeInteractiveChallenge(
        actionID: ownerID, resumeReference: resume,
        response: "ARKDECK-987654321")
      XCTFail("mismatched challenge was consumed")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "impactApprovalChallengeMismatch")
    }
    XCTAssertEqual(driver.restartCount, 0)
    let afterMismatch = try object(await coordinator.show(ownerID))
    XCTAssertEqual(afterMismatch["state"], .string("awaitingImpactApproval"))

    let first = Task {
      try await coordinator.consumeInteractiveChallenge(
        actionID: ownerID, resumeReference: resume, response: response)
    }
    let second = Task {
      try await coordinator.consumeInteractiveChallenge(
        actionID: ownerID, resumeReference: resume, response: response)
    }
    var successes: [JSONValue] = []
    var failureCodes: [String] = []
    for task in [first, second] {
      do { successes.append(try await task.value) }
      catch let failure as AgentExecutionControlFailure { failureCodes.append(failure.code) }
    }
    XCTAssertEqual(successes.count, 1)
    XCTAssertEqual(failureCodes.count, 1)
    XCTAssertTrue(
      Set(["resourceConflict", "humanActionExpired"]).isSuperset(of: failureCodes))
    XCTAssertEqual(driver.restartCount, 1)
    XCTAssertEqual(driver.successfulAcquireCount, 2,
      "one mismatch and one matching response may own the interlock")
    XCTAssertEqual(driver.releaseCount, 2)
    XCTAssertFalse(driver.isHeld)

    let terminal = try object(await coordinator.show(ownerID))
    XCTAssertEqual(terminal["state"], .string("failed"))
    XCTAssertEqual(terminal["dispatchCount"], .integer(0))
    do {
      _ = try await coordinator.consumeInteractiveChallenge(
        actionID: ownerID, resumeReference: resume, response: response)
      XCTFail("one-time challenge was reusable")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "humanActionExpired")
    }
    let recordURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: directory.appending(path: "records"), includingPropertiesForKeys: nil)
      .first(where: { $0.pathExtension == "json" }))
    XCTAssertFalse(String(decoding: try Data(contentsOf: recordURL), as: UTF8.self)
      .contains(response))
  }

  func testRuntimeReopenClosesEveryLifecycleCrashBoundaryWithoutReplay() async throws {
    for boundary in LifecycleBoundary.allCases {
      let directory = root.appending(path: boundary.rawValue)
      let records = directory.appending(path: "records")
      let store = try RuntimeHDCControlActionStore(directory: records)
      let approved = try approvedLifecycleRecord(
        store: store, requestID: "reopen-\(boundary.rawValue)")
      let interrupted = try await appendLifecycleBoundary(
        boundary, to: approved, store: store)
      let generationBeforeReopen = interrupted.generation
      let source = Source(
        reference: reference,
        value: .init(impact: try impact([
          "serverOwnership": .string("external"),
          "serverGeneration": .string("7"),
        ]), observationRelations: [], blockerReasonCode: nil))
      let reopenDate = now.addingTimeInterval(
        boundary == .approval ? 30 : 600)
      let reopened = try RuntimeHDCControlActionCoordinator(
        directory: directory, source: source, catalogDigest: catalog,
        epoch: "replacement-epoch", now: { reopenDate })
      let first = try object(await reopened.show(interrupted.actionID))
      let durable = try XCTUnwrap(store.load(actionID: interrupted.actionID))

      switch boundary {
      case .approval:
        XCTAssertEqual(first["state"], .string("previewDrifted"))
        XCTAssertEqual(first["dispatchCount"], .integer(0))
        XCTAssertEqual(
          durable.lifecycleAudit.map(\.kind), ["impactPreview", "confirmation"],
          "pre-intent evidence must be retained rather than rewritten")
        XCTAssertEqual(
          durable.value["blockerReasonCode"],
          .string("hdc.lifecycleInterruptedBeforeIntent"))
      case .intent, .actualCommand:
        XCTAssertEqual(first["state"], .string("failed"))
        XCTAssertEqual(first["dispatchCount"], .integer(0))
        XCTAssertEqual(durable.lifecycleAudit.last?.kind, "outcome")
        XCTAssertEqual(
          durable.lifecycleAudit.last?.payload["outcome"],
          .object([
            "result": .string("failed"), "resultingGeneration": .null,
            "reason": .string(
              "Runtime restarted before the durable HDC launch-window entry"),
          ]))
      case .launchWindow:
        XCTAssertEqual(first["state"], .string("outcomeUnknown"))
        XCTAssertEqual(first["dispatchCount"], .integer(1))
        XCTAssertEqual(
          durable.lifecycleAudit.suffix(2).map(\.kind),
          ["outcome", "reconciliation"])
        XCTAssertEqual(
          durable.lifecycleAudit.last?.payload["requiresReconcile"], .bool(true))
      }

      let firstGeneration = durable.generation
      let second = try object(await reopened.show(interrupted.actionID))
      XCTAssertEqual(second, first, "reopen recovery must be idempotent")
      XCTAssertEqual(
        try store.load(actionID: interrupted.actionID)?.generation,
        firstGeneration)
      XCTAssertGreaterThan(firstGeneration, generationBeforeReopen)
    }
  }

  private enum LifecycleBoundary: String, CaseIterable {
    case approval, intent, actualCommand, launchWindow
  }

  private func approvedLifecycleRecord(
    store: RuntimeHDCControlActionStore, requestID: String
  ) throws -> HDCControlActionRecord {
    let initial = try store.begin(
      intent: intent(requestID, generation: "7"), catalogDigest: catalog,
      runtimeEpoch: "original-epoch", now: now)
    let published = try initial.publishing(
      impact: impact([
        "serverOwnership": .string("external"),
        "serverGeneration": .string("7"),
      ]), relations: [], blocker: nil, now: now.addingTimeInterval(1))
    try store.replace(published, expectedGeneration: initial.generation)
    let preview = try XCTUnwrap(published.preview)
    guard case .string(let previewID)? = preview.value["previewId"],
      case .string(let digest)? = preview.value["previewDigest"]
    else { throw NSError(domain: "fixture", code: 2) }
    let awaiting = try published.requestingImpactApproval(
      previewID: previewID, previewDigest: digest,
      now: now.addingTimeInterval(2))
    try store.replace(awaiting, expectedGeneration: published.generation)
    let challenge = "ARKDECK-123456789"
    let challenged = try awaiting.issuingInteractiveChallenge(
      challenge: challenge, now: now.addingTimeInterval(3))
    try store.replace(challenged, expectedGeneration: awaiting.generation)
    let approved = try challenged.recordingInteractiveApproval(
      response: challenge, now: now.addingTimeInterval(4))
    try store.replace(approved, expectedGeneration: challenged.generation)
    return approved
  }

  private func appendLifecycleBoundary(
    _ boundary: LifecycleBoundary,
    to approved: HDCControlActionRecord,
    store: RuntimeHDCControlActionStore
  ) async throws -> HDCControlActionRecord {
    let endpoint = HDCServerEndpoint("127.0.0.1:8710")
    let snapshot = HDCServerImpactSnapshot(
      action: .restartConfirmedGeneration, endpoint: endpoint,
      generation: 7, ownership: .external,
      affectedDeviceCoordinators: [], affectedJobs: [],
      otherClientDetection: .unavailableExternalClientsMayStillExist,
      expectedInterruption: "HDC requests using this endpoint will be interrupted.",
      recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job.")
    let preview = HDCServerLifecycleImpactPreview(
      id: UUID(), auditID: UUID(), snapshot: snapshot)
    let confirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: preview.auditID,
      action: .restartConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 7, expectedOwnership: .external,
      impactSnapshotHash: snapshot.scopeHash, confirmationID: confirmation.id)
    let auditDate = now.addingTimeInterval(5)
    let audit = RuntimeHDCControlLifecycleAuditStore(
      store: store, actionID: approved.actionID,
      now: { auditDate })
    try await audit.append(.impactPreview(preview))
    try await audit.append(.confirmation(confirmation))
    if boundary.rawValue == "approval" { return try audit.record() }
    try await audit.append(.intent(step))
    if boundary.rawValue == "intent" { return try audit.record() }
    let command = HDCServerLifecycleActualCommand(
      stepID: step.id, auditID: step.auditID,
      executable: URL(filePath: "/fixture/hdc"),
      arguments: ["-s", endpoint.rawValue, "kill", "-r"], endpoint: endpoint)
    let consumed = try await audit.consumeDispatchAuthorization(
      of: step, actualCommand: command)
    XCTAssertTrue(consumed)
    if boundary.rawValue == "actualCommand" { return try audit.record() }
    let beforeLaunch = try audit.record()
    let launched = try beforeLaunch.appendingLifecycleAudit(
      kind: "launchWindowEntered", auditID: preview.auditID,
      payload: [
        "stepId": .string(step.id.uuidString.lowercased()),
        "executable": .string("/fixture/hdc"),
        "argv": .array([
          .string("-s"), .string(endpoint.rawValue), .string("kill"), .string("-r"),
        ]),
        "endpoint": .string(endpoint.rawValue),
        "authorizedExecutable": .string("/fixture/hdc"),
        "inodeLaunchPath": .string("/.vol/1/2"),
        "executableDevice": .string("1"), "executableInode": .string("2"),
        "executableFileSize": .integer(1), "executableMode": .string("33261"),
        "executableSha256": .string(String(repeating: "b", count: 64)),
      ], now: now.addingTimeInterval(6))
    try store.replace(launched, expectedGeneration: beforeLaunch.generation)
    return launched
  }

  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  private final class LockedDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    var text: String {
      lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }

    func append(_ value: Data) { lock.withLock { bytes.append(value) } }
  }

  private final class RecordingLifecycleDriver:
    HDCControlLifecycleDriving, @unchecked Sendable
  {
    private final class Lease: HDCControlLifecycleInterlock, @unchecked Sendable {
      private let owner: RecordingLifecycleDriver
      private let lock = NSLock()
      private var released = false

      init(owner: RecordingLifecycleDriver) { self.owner = owner }

      func release() async throws {
        let shouldRelease = lock.withLock { () -> Bool in
          guard !released else { return false }
          released = true
          return true
        }
        guard shouldRelease else {
          throw AgentExecutionControlFailure(
            "resourceConflict", "fixture interlock was already released")
        }
        try owner.releaseLease()
      }
    }

    private let lock = NSLock()
    private var held = false
    private var acquires = 0
    private var releases = 0
    private var restarts = 0

    var successfulAcquireCount: Int { lock.withLock { acquires } }
    var releaseCount: Int { lock.withLock { releases } }
    var restartCount: Int { lock.withLock { restarts } }
    var isHeld: Bool { lock.withLock { held } }

    func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock {
      let acquired = lock.withLock { () -> Bool in
        guard !held else { return false }
        held = true
        acquires += 1
        return true
      }
      guard acquired else {
        throw AgentExecutionControlFailure(
          "resourceConflict", "fixture HDC lifecycle interlock is already held")
      }
      return Lease(owner: self)
    }

    func noteLaunchWindowEntered() {}

    func restart(
      approved: HDCControlActionRecord,
      reading: HDCControlImpactReading,
      audit: RuntimeHDCControlLifecycleAuditStore
    ) async throws -> HDCControlActionRecord {
      lock.withLock { restarts += 1 }
      guard case .string(let endpointText)? = reading.impact.value["endpoint"] else {
        throw AgentExecutionControlFailure("factsDrifted", "fixture endpoint missing")
      }
      guard let generation = Int(exactly: approved.intent.expectedGeneration) else {
        throw AgentExecutionControlFailure("factsDrifted", "fixture generation is too large")
      }
      let endpoint = HDCServerEndpoint(endpointText)
      let snapshot = HDCServerImpactSnapshot(
        action: .restartConfirmedGeneration, endpoint: endpoint,
        generation: generation, ownership: .external,
        affectedDeviceCoordinators: [], affectedJobs: [],
        otherClientDetection: .unavailableExternalClientsMayStillExist,
        expectedInterruption: "HDC requests using this endpoint will be interrupted.",
        recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job.")
      let preview = HDCServerLifecycleImpactPreview(
        id: UUID(), auditID: UUID(), snapshot: snapshot)
      let confirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
      let step = HDCServerLifecycleStep(
        id: UUID(), auditID: preview.auditID,
        action: .restartConfirmedGeneration, endpoint: endpoint,
        expectedGeneration: generation,
        expectedOwnership: .external, impactSnapshotHash: snapshot.scopeHash,
        confirmationID: confirmation.id)
      try await audit.append(.impactPreview(preview))
      try await audit.append(.confirmation(confirmation))
      try await audit.append(.intent(step))
      try await audit.append(.outcome(
        stepID: step.id, auditID: step.auditID,
        outcome: .failed(reason: "fixture definite prelaunch failure")))
      return try audit.record()
    }

    private func releaseLease() throws {
      let released = lock.withLock { () -> Bool in
        guard held else { return false }
        held = false
        releases += 1
        return true
      }
      guard released else {
        throw AgentExecutionControlFailure(
          "resourceConflict", "fixture HDC lifecycle interlock is not held")
      }
    }
  }

}
