import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeToolSelectionControlActionContractTests: XCTestCase {
  private let catalog = String(repeating: "c", count: 64)
  private let oldDigest = String(repeating: "a", count: 64)
  private let newDigest = String(repeating: "b", count: 64)
  private let now = Date(timeIntervalSince1970: 1_788_220_800)
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-selection-actions-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func tool(
    _ digest: String, executableDigest: String? = nil
  ) throws -> RuntimeToolSelectionToolFacts {
    try RuntimeToolSelectionToolFacts(value: [
      "toolRef": .string("tool:sha256:\(digest)"),
      "recordGeneration": .string("1"),
      "contentSHA256": .string(digest),
      "executableSHA256": .string(executableDigest ?? digest),
      "signature": .object([
        "state": .string("adHoc"), "identifier": .null,
        "teamIdentifier": .null, "codeDirectoryIdentitySHA256": .null,
      ]),
      "version": .string("3.2.0-test"),
      "trust": .object([
        "policy": .string("arkdeck.host-tool-inspection/1"),
        "registeredIdentity": .bool(true),
        "platformTrust": .string("unverified"),
        "executionAssessment": .string("notPerformed"),
        "profileReferences": .array([.string("fixture-profile")]),
      ]),
    ])
  }

  private func impact(
    _ changes: [String: JSONValue] = [:]
  ) throws -> HDCControlImpact {
    let endpoint = "127.0.0.1:8710"
    var fields: [String: JSONValue] = [
      "serverEndpointRef": .string(
        "hdc-endpoint:" + SHA256Hex.string(of: Data(endpoint.utf8))),
      "endpoint": .string(endpoint), "serverOwnership": .string("arkDeckManaged"),
      "serverGeneration": .string("100000023"), "serverHealth": .string("healthy"),
      "serverVersion": .string("3.2.0-test"),
      "tool": .object([
        "reference": .null, "executablePath": .string("/retained/hdc"),
        "source": .string("runtimeConfiguration"),
        "sha256": .string(oldDigest), "signature": .null,
        "version": .string("3.2.0-test"), "trust": .string("verified"),
      ]),
      "affectedTargetIds": .array([]), "affectedJobIds": .array([]),
      "detectedOtherClientIds": .array([]), "otherClientsMayExist": .bool(true),
      "affectedDeviceObservations": .array([]),
      "criticalJobGate": .object([
        "state": .string("clear"), "blocking": .array([]), "reasonCode": .null,
      ]),
      "interruption": .object([
        "kind": .string("hdcEndpointUnavailable"),
        "affectsAllParticipants": .bool(true),
      ]),
      "recovery": .object([
        "kind": .string("statusThenReconcile"), "replayAllowed": .bool(false),
      ]),
    ]
    fields.merge(changes, uniquingKeysWith: { _, new in new })
    return try HDCControlImpact(fields)
  }

  private func intent(_ request: String = "tool-selection-request") -> [String: JSONValue] {
    [
      "actionRequestId": .string(request),
      "tool": .string("tool:sha256:\(newDigest)"),
      "expectedActiveGeneration": .string("1"),
    ]
  }

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else {
      throw NSError(domain: "fixture", code: 1)
    }
    return fields
  }

  private struct TargetRequest: Encodable {
    let contractIdentity = ArkDeckControlProtocol.contractIdentity
    let protocolVersion: String
    let id: String
    let method: String
    let params: [String: JSONValue]?
  }

  private actor Source: HDCControlImpactObserving {
    nonisolated let endpointReference = "hdc-endpoint:fixture"
    private var reading: HDCControlImpactReading
    private(set) var reads = 0

    init(_ impact: HDCControlImpact) {
      reading = HDCControlImpactReading(
        impact: impact, observationRelations: [], blockerReasonCode: nil)
    }

    func readImpact() async throws -> HDCControlImpactReading {
      reads += 1
      return reading
    }

    func replace(_ impact: HDCControlImpact) {
      reading = HDCControlImpactReading(
        impact: impact, observationRelations: [], blockerReasonCode: nil)
    }
  }

  private final class Registry:
    RuntimeToolSelectionRegistryControlling, @unchecked Sendable
  {
    let active: RuntimeToolSelectionToolFacts
    let candidateTool: RuntimeToolSelectionToolFacts
    private let lock = NSLock()
    private(set) var candidateReads = 0

    init(active: RuntimeToolSelectionToolFacts, candidate: RuntimeToolSelectionToolFacts) {
      self.active = active
      candidateTool = candidate
    }

    func candidate(
      newToolRef: String, expectedActiveGeneration: UInt64,
      pendingActionID: String?
    ) throws -> RuntimeToolSelectionRegistryCandidate {
      lock.withLock { candidateReads += 1 }
      guard newToolRef == candidateTool.toolRef, expectedActiveGeneration == 1 else {
        throw HDCControlValue.failure("resourceConflict", "fixture selection changed")
      }
      return RuntimeToolSelectionRegistryCandidate(
        activeTool: active, newTool: candidateTool, activeGeneration: 1)
    }

    func prepare(
      actionID: String, newToolRef: String, expectedActiveGeneration: UInt64
    ) throws -> ResolvedExecutable {
      throw HDCControlValue.failure("operationUnavailable", "fixture has no lifecycle")
    }
    func failPending(actionID: String, reasonCode: String) throws {}
    func outcome(actionID: String) throws -> RuntimeToolSelectionDurableOutcome { .absent }
    func acknowledge(actionID: String) throws {}
  }

  private final class Interlock: HDCControlLifecycleInterlock, @unchecked Sendable {
    func release() async throws {}
  }

  private final class Lifecycle:
    RuntimeToolSelectionLifecycleDriving, @unchecked Sendable
  {
    func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock {
      Interlock()
    }
    func noteLaunchWindowEntered() {}
    func restartWithSelectedTool(
      approved: RuntimeToolSelectionControlActionRecord,
      reading: RuntimeToolSelectionImpactReading,
      audit: RuntimeToolSelectionLifecycleAuditStore
    ) async throws {
      XCTFail("drifted facts reached the lifecycle driver")
    }
  }

  func testIntentFingerprintAndPreviewCoverExactToolTransitionFacts() throws {
    let first = try RuntimeToolSelectionIntent(intent())
    let retry = try RuntimeToolSelectionIntent(intent("lost-receipt-retry"))
    XCTAssertEqual(try first.fingerprint, try retry.fingerprint)
    XCTAssertFalse(
      String(
        decoding: try PortableCanonicalJSON.canonicalBytes(first.canonicalIntent), as: UTF8.self
      )
      .contains("lost-receipt-retry"))
    let value = try RuntimeToolSelectionImpact(
      hdc: impact(), oldTool: tool(oldDigest),
      newTool: tool(newDigest), activeGeneration: 1)
    let preview = try RuntimeToolSelectionPreview(
      actionID: "control-action-fixture", previewID: "preview-fixture",
      createdAt: HDCControlActionRecord.timestamp(now),
      expiresAt: HDCControlActionRecord.timestamp(now.addingTimeInterval(300)),
      impact: value)
    XCTAssertNoThrow(try RuntimeToolSelectionPreview(value: preview.value))
    for (key, replacement) in [
      ("expectedActiveGeneration", JSONValue.string("2")),
      ("newTool", JSONValue.object(try tool(oldDigest).value)),
      ("affectedTargetIds", JSONValue.array([.string("target-late")])),
    ] {
      var changed = preview.value
      changed[key] = replacement
      XCTAssertThrowsError(try RuntimeToolSelectionPreview(value: changed))
    }
  }

  func testSelectCreatesOneDurableHARAndUnionDiscoveryWithoutMutation() async throws {
    let source = Source(try impact())
    let registry = Registry(active: try tool(oldDigest), candidate: try tool(newDigest))
    let date = now
    let coordinator = try RuntimeToolSelectionControlActionCoordinator(
      directory: root.appending(path: "owner"), hdcSource: source,
      registry: registry, catalogDigest: catalog, epoch: "epoch", now: { date })
    let first = try object(await coordinator.select(intent()))
    XCTAssertEqual(first["kind"], .string("runtimeToolSelection"))
    XCTAssertEqual(first["state"], .string("awaitingImpactApproval"))
    XCTAssertEqual(first["dispatchCount"], .integer(0))
    guard case .object(let preview)? = first["preview"],
      case .object(let action)? = first["humanAction"],
      case .string(let actionID)? = first["controlActionId"]
    else { return XCTFail("tool selection did not publish its preview and HAR") }
    XCTAssertEqual(preview["schemaVersion"], .string("arkdeck.tool-selection-preview/1"))
    XCTAssertEqual(preview["oldTool"], .object(try tool(oldDigest).value))
    XCTAssertEqual(preview["newTool"], .object(try tool(newDigest).value))
    XCTAssertEqual(
      action["owner"],
      .object([
        "kind": .string("controlAction"), "id": .string(actionID),
      ]))
    let replay = try await coordinator.select(intent())
    XCTAssertEqual(replay, .object(first))
    let sourceReads = await source.reads
    XCTAssertEqual(sourceReads, 2)
    XCTAssertEqual(registry.candidateReads, 2)

    let aggregate = try RuntimeControlActionResourceCoordinator(
      directory: root.appending(path: "union"), hdc: nil, tools: coordinator)
    let discovered = try await aggregate.show(actionID)
    XCTAssertEqual(discovered, .object(first))
    let page = try object(
      await aggregate.list(
        filters: ["kind": .string("runtimeToolSelection")],
        pageSize: 10, cursor: nil))
    XCTAssertEqual(page["items"], .array([.object(first)]))
    let rows = try await aggregate.humanActionResourceRows(ownerID: actionID)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.value, .object(action))
  }

  func testFreshImpactDriftInvalidatesBeforeInteractiveApproval() async throws {
    let source = Source(try impact())
    let registry = Registry(active: try tool(oldDigest), candidate: try tool(newDigest))
    let date = now
    let coordinator = try RuntimeToolSelectionControlActionCoordinator(
      directory: root.appending(path: "drift"), hdcSource: source,
      registry: registry, lifecycle: Lifecycle(),
      catalogDigest: catalog, epoch: "epoch", now: { date })
    let first = try object(await coordinator.select(intent()))
    guard case .string(let actionID)? = first["controlActionId"],
      case .object(let human)? = first["humanAction"],
      case .string(let humanActionID)? = human["actionId"],
      case .string(let resume)? = human["resumeReference"]
    else { return XCTFail("missing approval identity") }
    let challenge = try object(
      await coordinator.issueInteractiveChallenge(
        actionID: humanActionID, resumeReference: resume))
    guard case .string(let response)? = challenge["challenge"] else {
      return XCTFail("missing challenge")
    }
    await source.replace(
      try impact([
        "detectedOtherClientIds": .array([.string("late-client")])
      ]))
    do {
      _ = try await coordinator.consumeInteractiveChallenge(
        actionID: actionID, resumeReference: resume, response: response)
      XCTFail("fresh impact drift was accepted")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "factsDrifted")
    }
    let current = try object(await coordinator.show(actionID))
    XCTAssertEqual(current["state"], .string("previewDrifted"))
    XCTAssertEqual(current["dispatchCount"], .integer(0))
  }

  func testProtocolTwoHandlerPublishesToolSelectionAndRejectsCallerExecutionFacts()
    async throws
  {
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "caps"))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(),
      capabilityStore: capabilities,
      nowUTC: { "2026-09-02T00:00:00Z" })
    let source = Source(try impact())
    let registry = Registry(active: try tool(oldDigest), candidate: try tool(newDigest))
    let date = now
    let tools = try RuntimeToolSelectionControlActionCoordinator(
      directory: root.appending(path: "wire-owner"), hdcSource: source,
      registry: registry, catalogDigest: catalog, epoch: "epoch", now: { date })
    let controls = try RuntimeControlActionResourceCoordinator(
      directory: root.appending(path: "wire-pages"), hdc: nil, tools: tools)
    let humans = try RuntimeHumanActionResourceCoordinator(
      directory: root.appending(path: "wire-human-pages"), agents: nil,
      controlResources: controls)
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-02T00:00:00Z" }, humanActionResources: humans,
      toolSelectionActions: tools, controlActions: controls)

    func request(_ params: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      let frame = try JSONEncoder().encode(
        TargetRequest(
          protocolVersion: ArkDeckControlProtocol.currentVersion,
          id: UUID().uuidString.lowercased(), method: "runtime.tool.select",
          params: params))
      return await handler.handleFrame(frame)
    }
    let accepted = try await request(intent())
    XCTAssertTrue(accepted.ok)
    let result = try object(XCTUnwrap(accepted.result))
    XCTAssertEqual(result["kind"], .string("runtimeToolSelection"))
    XCTAssertEqual(result["state"], .string("awaitingImpactApproval"))
    XCTAssertEqual(result["dispatchCount"], .integer(0))

    var injected = intent("caller-facts")
    injected["executablePath"] = .string("/tmp/caller-hdc")
    let rejected = try await request(injected)
    XCTAssertFalse(rejected.ok)
    XCTAssertEqual(rejected.error?.code, "invalidInput")
    XCTAssertEqual(rejected.error?.details?["newDispatchCount"], .integer(0))
  }

  func testAcceptedSupervisorExecutorPersistsNewToolCommandAndLeavesStartupReconciliation()
    async throws
  {
    let records = root.appending(path: "lifecycle-records")
    let store = try RuntimeToolSelectionControlActionStore(directory: records)
    let fixtureExecutable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appending(path: "ArkDeckFakeHDCFixture")
    let selectedExecutableDigest = SHA256Hex.string(
      of: try Data(contentsOf: fixtureExecutable))
    let selectionIntent = try RuntimeToolSelectionIntent(intent("lifecycle-request"))
    let initial = try store.begin(
      intent: selectionIntent, catalogDigest: catalog,
      runtimeEpoch: "epoch", now: now)
    let selectedImpact = try RuntimeToolSelectionImpact(
      hdc: impact([
        "serverOwnership": .string("external"),
        "serverGeneration": .string("7"),
      ]),
      oldTool: tool(oldDigest),
      newTool: tool(newDigest, executableDigest: selectedExecutableDigest),
      activeGeneration: 1)
    let published = try initial.publishing(
      impact: selectedImpact, relations: [], blocker: nil,
      now: now.addingTimeInterval(1))
    try store.replace(published, expectedGeneration: initial.generation)
    let awaiting = try published.requestingImpactApproval(
      now: now.addingTimeInterval(2))
    try store.replace(awaiting, expectedGeneration: published.generation)
    let challenged = try awaiting.issuingInteractiveChallenge(
      challenge: "ARKDECK-A1B2C3D4E", now: now.addingTimeInterval(3))
    try store.replace(challenged, expectedGeneration: awaiting.generation)
    let approved = try challenged.recordingInteractiveApproval(
      response: "ARKDECK-A1B2C3D4E", now: now.addingTimeInterval(4))
    try store.replace(approved, expectedGeneration: challenged.generation)

    let auditDate = now.addingTimeInterval(5)
    let audit = RuntimeToolSelectionLifecycleAuditStore(
      store: store, actionID: initial.actionID, now: { auditDate },
      finalImpactValidator: { true }, onLaunchWindowEntered: {})
    _ = try audit.markSelectionPrepared()
    let router = RuntimeHDCControlLifecycleAuditRouter()
    let binding = try router.bind(audit)
    defer { try? router.unbind(binding) }
    let supervisor = HDCServerSupervisor(auditStore: router)
    let endpoint = HDCServerEndpoint("127.0.0.1:8710")
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy,
          version: .known("3.2.0-test"), generation: 7,
          ownership: .external)),
      reason: "tool-selection fixture identity")
    await supervisor.setOtherClientDetection(
      .unavailableExternalClientsMayStillExist, for: endpoint)
    guard
      case .ready(let lifecyclePreview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(lifecyclePreview.id)
    else { return XCTFail("fixture did not establish the accepted lifecycle") }

    let executable = root.appending(path: "selected-hdc")
    try FileManager.default.copyItem(
      at: fixtureExecutable,
      to: executable)
    let digest = selectedExecutableDigest
    let candidate = HDCCandidate(
      path: executable, source: .userConfigured, sha256: digest)
    let semantic = HDCRegisteredSemanticProfile.testOnlyFake(
      executableSHA256: digest,
      selectedDeviceAuthorizationSHA256: String(repeating: "c", count: 64))
    let executor = HDCProcessLifecycleExecutor(
      toolchain: candidate, semanticProfile: semantic,
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": root.appending(path: "selected.log").path
      ],
      durableAuthorization: router, supervisor: supervisor,
      postDispatchProbe: { _ in .generation(8) })
    let step = try HDCServerLifecycleStep.coreWorkflowStep(
      confirmation: confirmation)
    let dispatch = await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: step, using: executor)
    XCTAssertEqual(dispatch, .completed(.succeeded(resultingGeneration: 8)))
    XCTAssertTrue(audit.launchWindowWasEntered())
    let durable = try audit.record()
    XCTAssertEqual(durable.state, "outcomeUnknown")
    XCTAssertEqual(durable.value["dispatchCount"], .integer(1))
    guard case .array(let rows)? = durable.value["selectionAudit"] else {
      return XCTFail("tool selection omitted lifecycle audit")
    }
    let kinds = rows.compactMap { row -> String? in
      guard case .object(let fields) = row,
        case .string(let kind)? = fields["kind"]
      else { return nil }
      return kind
    }
    XCTAssertEqual(
      kinds,
      [
        "selectionPrepared", "impactPreview", "confirmation", "intent",
        "actualCommand", "launchWindowEntered", "outcome", "reconciliation",
      ])
    let actual = rows.compactMap { row -> [String: JSONValue]? in
      guard case .object(let fields) = row,
        fields["kind"] == .string("actualCommand"),
        case .object(let payload)? = fields["payload"]
      else { return nil }
      return payload
    }.first
    XCTAssertEqual(actual?["executable"], .string(executable.path))
    XCTAssertEqual(
      actual?["argv"],
      .array([
        .string("-s"), .string(endpoint.rawValue), .string("kill"), .string("-r"),
      ]))
  }
}
