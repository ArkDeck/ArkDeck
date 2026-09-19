import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// `TASK-XPA-014`: `runtime.hdc.impact-preview` and `control-action.list`,
/// `.show` and `.reconcile` as the production daemon answers them once its HDC
/// server host has started. `ArkDeckAgentDaemonMain` then composes the HDC
/// control-action owner in `<state>/hdc-control-actions` over the host's impact
/// source, with the operation catalog's digest and a fresh epoch per start, and
/// the union owner over it in `<state>/control-action-snapshots`.
///
/// The impact source here is the production `HeadlessHDCControlImpactSource`
/// over the fixture HDC executable and a fixture observation port, as
/// `HDCControlActionContractTests` reads it. The fixture's digest has no
/// commandless identity family, so no server generation, version or health is
/// proved, and nothing runs the executable. The isolated Rust daemon's managed
/// server is such a fixture too. A run with `ARKDECK_CONTROL_FRAME_LOG` set
/// records these answers for the method schemas.
///
/// Two more previews carry what that one does not. A tool signed with a team
/// identifier: a copy of an executable DevEco signs with its team
/// (`HDCStatusControlFramesContractTests.teamSignedExecutable`, skipped on a
/// host without it; its digest has no identity family either). And a critical
/// Job gate left unknown, with its reason, by a Target inventory that changed
/// while the impact was read: the fixture port removes the durable Target
/// document while the device list is read, so no Job, Target or device row
/// remains to name. An unsigned tool (the HDC oracles' shell driver, which
/// nothing runs) is previewed with no signing identity at all.
///
/// `runtime.hdc.restart` requests the impact approval of a ready preview. No
/// fixture preview is ready: only the registered 3.2.0d server proves its
/// health, by a `checkserver` that would have to run. The restart tests read
/// the impact through `RegisteredHealthyServer`, which answers that server's
/// facts over the production reading of everything else. They request the
/// approval, repeat and refuse the request, read the approval through the
/// control-action routes and the human-action union owner (composed as the
/// daemon composes it), and let it drift and expire. Nothing resumes it: no
/// challenge is issued, no lifecycle driver is composed and nothing is
/// dispatched.
final class ControlActionWithHostContractTests: XCTestCase {
  /// 2026-09-19T00:00:00Z, as the records spell it.
  private static let start = Date(timeIntervalSince1970: 1_789_776_000)
  private static let order = "createdAtThenControlActionId"
  private static let intentRequired = "an exact restart intent and request identity are required"
  private static let endpointMissing = "the exact HDC endpoint reference is not configured"
  private static let otherIntent = "the request identity belongs to a different lifecycle intent"
  private static let tupleRequired = "restart requires one exact control-action preview tuple"
  private static let actionMissing = "control action does not exist"
  private static let otherPreview = "restart does not name the exact immutable preview"
  private static let ineligible = "the control action is not eligible for impact approval"
  private static let unprovenImpact = "fresh HDC impact could not be proven"
  private static let differentImpact = "fresh HDC impact differs from the reviewed preview"
  private static let clockBackwards = "control-action clock moved backwards"
  /// What the production inspection reads from an unsigned executable.
  private static let unsignedSignature: JSONValue = .object([
    "state": .string("unsigned"), "identifier": .null, "teamIdentifier": .null,
    "platformTrust": .string("unverified"), "executionAssessment": .string("notPerformed"),
  ])
  private static let reference =
    "hdc-endpoint:" + SHA256Hex.string(of: Data("127.0.0.1:8710".utf8))
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/control-action-with-host-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The owner's clock, which a test moves forward.
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) {
      lock.withLock { current = current.addingTimeInterval(seconds) }
    }
  }

  /// The development HDC's device list as the Target observation owner reads
  /// it: empty, or unreadable, as `ProviderBootstrapObservation` reports an
  /// HDC whose `list targets -v` printed nothing (the isolated Rust daemon's
  /// managed fake exits 23 with an empty stdout).
  private final class Port: BootstrapObservationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var answers = true
    private var lists = 0
    private var during: (@Sendable () -> Void)?
    func setAnswers(_ value: Bool) { lock.withLock { answers = value } }
    /// Something that happens on the host while each later list is read.
    func setDuringList(_ action: @escaping @Sendable () -> Void) {
      lock.withLock { during = action }
    }
    var listCount: Int { lock.withLock { lists } }
    func observeToolVersion() async throws -> String {
      throw BootstrapError.observationFailed("tool version could not be verified")
    }
    func listCandidates() async throws -> [BootstrapCandidate] {
      if let action = lock.withLock({ during }) { action() }
      return try lock.withLock {
        lists += 1
        guard answers else { throw BootstrapError.observationFailed("empty observation output") }
        return []
      }
    }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      throw BootstrapError.observationFailed("device observation could not be verified")
    }
  }

  /// What survives a daemon restart: the state root, the Job and Target owners
  /// and the host's impact source over the fixture HDC.
  private struct Host {
    let state: URL
    let engine: RuntimeJobEngine
    let capabilities: RuntimeCapabilityStore
    let dispatcher: RuntimeAgentExecutionContractTests.Dispatcher
    let targets: RuntimeTargetStore
    let observations: TargetObservationCoordinator
    let port: Port
    let executable: ResolvedExecutable
    let source: HeadlessHDCControlImpactSource

    var records: URL { state.appending(path: "hdc-control-actions/records") }
    var ownerSnapshots: URL { state.appending(path: "hdc-control-actions/snapshots") }
    var unionSnapshots: URL { state.appending(path: "control-action-snapshots") }
  }

  /// What only a registered 3.2.0d server proves, which no fixture can.
  /// `HDCControlServerObserver` proves a server's health only for the
  /// registered 3.2.0d executable: its commandless identity, a `checkserver`
  /// in the healthy family, the same identity again. Every other digest,
  /// the fixture's among them, proves no health, so its previews are never
  /// ready. This source reads through the production source (the executable's
  /// path, digest and signature, the Jobs, the Targets and the devices) and
  /// then answers what that observation gives such a server: generation
  /// 100000023, health healthy, version 3.2.0d, no blocker. The tool's client
  /// version is the one the registered digest names, 3.2.0d: only that
  /// executable proves health, so every ready preview carries it. With no
  /// launch record the ownership stays unknown, as the production source
  /// derives it.
  private struct RegisteredHealthyServer: HDCControlImpactObserving {
    let source: HeadlessHDCControlImpactSource
    var endpointReference: String { source.endpointReference }

    func readImpact() async throws -> HDCControlImpactReading {
      let reading = try await source.readImpact()
      var facts = reading.impact.value
      facts["serverGeneration"] = .string("100000023")
      facts["serverHealth"] = .string("healthy")
      facts["serverVersion"] = .string("3.2.0d")
      if case .object(var tool)? = facts["tool"] {
        tool["version"] = .string("3.2.0d")
        facts["tool"] = .object(tool)
      }
      return .init(
        impact: try HDCControlImpact(facts), observationRelations: reading.observationRelations,
        blockerReasonCode: nil)
    }
  }

  /// One daemon start over the host: the HDC control-action owner with a fresh
  /// epoch, the union owner over it (no tool-selection owner), the
  /// human-action union owner over the AgentExecution owner and that union
  /// owner, and the handler.
  private struct Daemon {
    let handler: RuntimeControlPlaneHandler
    let owner: RuntimeHDCControlActionCoordinator

    /// One request frame through the handler's line entry, as a socket
    /// client's frame reaches it.
    func send(
      _ method: String, _ params: [String: JSONValue]
    ) async throws -> AgentWireProtocol.Response {
      let frame = try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("with-host-" + UUID().uuidString.lowercased()),
        "method": .string(method), "params": .object(params),
      ]))
      return try JSONDecoder().decode(
        AgentWireProtocol.Response.self, from: await handler.handleLine(frame))
    }

    /// An answered record, as an object.
    func answer(
      _ method: String, _ params: [String: JSONValue],
      file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String: JSONValue] {
      let response = try await send(method, params)
      XCTAssertTrue(response.ok, "\(method) \(params): \(String(describing: response.error))",
        file: file, line: line)
      guard case .object(let result)? = response.result else {
        XCTFail("\(method) answered no object", file: file, line: line)
        return [:]
      }
      return result
    }
  }

  /// The host over a copy of `tool`, by default the fixture HDC executable.
  private func makeHost(tool: URL? = nil) throws -> Host {
    let state = root.appending(path: "state")
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-19T00:00:00Z" })
    let targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let port = Port()
    let observations = TargetObservationCoordinator(
      observation: port, targetStore: targets, usbRelations: { [] },
      nowUTC: { "2026-09-19T00:00:00Z" })
    let path = root.appending(path: "hdc")
    try FileManager.default.copyItem(
      at: tool ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(
        path: "ArkDeckFakeHDCFixture"),
      to: path)
    let executable = ResolvedExecutable(
      path: path.path, sha256: SHA256Hex.string(of: try Data(contentsOf: path)))
    let source = HeadlessHDCControlImpactSource(
      executable: executable,
      endpoint: try HDCServerEndpointSelector.select(inheritedEnvironment: [:]),
      managedLaunch: { nil }, engine: engine, targets: targets, observations: observations)
    return Host(
      state: state, engine: engine, capabilities: capabilities, dispatcher: dispatcher,
      targets: targets, observations: observations, port: port, executable: executable,
      source: source)
  }

  /// A daemon start, as `ArkDeckAgentDaemonMain` composes it once its HDC
  /// server host started (without the tool-selection owner, which holds no
  /// action here, and without the lifecycle driver, which only an approved
  /// restart reaches). With `healthy`, the owner reads the impact through
  /// `RegisteredHealthyServer`.
  private func start(_ host: Host, clock: Clock, healthy: Bool = false) throws -> Daemon {
    let source: any HDCControlImpactObserving =
      healthy ? RegisteredHealthyServer(source: host.source) : host.source
    let owner = try RuntimeHDCControlActionCoordinator(
      directory: host.state.appending(path: "hdc-control-actions"), source: source,
      catalogDigest: RuntimeOperationCatalog.catalogDigest, now: { clock.now() })
    let controls = try RuntimeControlActionResourceCoordinator(
      directory: host.unionSnapshots, hdc: owner, tools: nil)
    let agents = try RuntimeAgentExecutionCoordinator(
      directory: host.state.appending(path: "agent-executions"), engine: host.engine,
      targets: host.targets, observations: host.observations)
    let humanActions = try RuntimeHumanActionResourceCoordinator(
      directory: host.state.appending(path: "human-action-snapshots"), agents: agents,
      controlResources: controls)
    let handler = RuntimeControlPlaneHandler(
      engine: host.engine, capabilityStore: host.capabilities, providerIDs: [],
      nowUTC: { "2026-09-19T00:00:00Z" }, targetStore: host.targets,
      targetObservations: host.observations, agentExecutions: agents,
      humanActionResources: humanActions, hdcControlActions: owner,
      toolSelectionActions: nil, controlActions: controls)
    return Daemon(handler: handler, owner: owner)
  }

  private func intent(
    _ request: String, reference: String = ControlActionWithHostContractTests.reference,
    generation: String = "100000023"
  ) -> [String: JSONValue] {
    [
      "action": .string("restart"), "actionRequestId": .string(request),
      "serverEndpointRef": .string(reference), "expectedServerGeneration": .string(generation),
    ]
  }

  /// Every refusal of these routes carries exactly `newDispatchCount: 0`.
  private func assertRefused(
    _ response: AgentWireProtocol.Response, _ code: String, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(response.ok, file: file, line: line)
    XCTAssertNil(response.result, file: file, line: line)
    XCTAssertEqual(response.error?.code, code, file: file, line: line)
    XCTAssertEqual(response.error?.message, message, file: file, line: line)
    XCTAssertEqual(
      response.error?.details, ["newDispatchCount": .integer(0)], file: file, line: line)
  }

  private static func timestamp(_ date: Date) -> String {
    HDCControlActionRecord.timestamp(date)
  }

  private static func string(_ value: JSONValue?) -> String? {
    if case .string(let text)? = value { return text }
    return nil
  }

  private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
    if case .object(let fields)? = value { return fields }
    return nil
  }

  /// The record's projection: its identity, the request it answers, and the
  /// facts a state change moves. What to do next follows the state: inspect a
  /// ready preview, answer the approval an awaiting action names, reconcile
  /// anything else.
  private func assertRecord(
    _ record: [String: JSONValue], request: String, state: String, generation: String,
    blocker: String?, created: Date, observed: Date, humanAction: JSONValue = .null,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let id = try XCTUnwrap(Self.string(record["controlActionId"]), file: file, line: line)
    XCTAssertTrue(id.hasPrefix("control-action-"), id, file: file, line: line)
    let canonical = try PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.hdc-control-intent/1"), "kind": .string("hdcLifecycle"),
      "action": .string("restart"), "serverEndpointRef": .string(Self.reference),
      "expectedServerGeneration": .string("100000023"),
    ]))
    XCTAssertEqual(
      Set(record.keys),
      [
        "schemaVersion", "controlActionId", "actionRequestId", "requestFingerprint",
        "fingerprintAlgorithm", "kind", "action", "owner", "generation", "state",
        "catalogDigest", "createdAt", "expiresAt", "lastObservedAt", "preview",
        "blockerReasonCode", "humanAction", "dispatchCount", "nextAction",
      ], file: file, line: line)
    let owner: JSONValue = .object(["kind": .string("controlAction"), "id": .string(id)])
    XCTAssertEqual(record["schemaVersion"], .string("arkdeck.control-action/1"), file: file, line: line)
    XCTAssertEqual(record["actionRequestId"], .string(request), file: file, line: line)
    XCTAssertEqual(
      record["requestFingerprint"], .string(SHA256Hex.string(of: canonical)), file: file, line: line)
    XCTAssertEqual(record["fingerprintAlgorithm"], .string("sha256-jcs"), file: file, line: line)
    XCTAssertEqual(record["kind"], .string("hdcLifecycle"), file: file, line: line)
    XCTAssertEqual(record["action"], .string("restart"), file: file, line: line)
    XCTAssertEqual(record["owner"], owner, file: file, line: line)
    XCTAssertEqual(record["generation"], .string(generation), file: file, line: line)
    XCTAssertEqual(record["state"], .string(state), file: file, line: line)
    XCTAssertEqual(
      record["catalogDigest"], .string(RuntimeOperationCatalog.catalogDigest), file: file, line: line)
    XCTAssertEqual(record["createdAt"], .string(Self.timestamp(created)), file: file, line: line)
    XCTAssertEqual(
      record["expiresAt"], .string(Self.timestamp(created.addingTimeInterval(300))),
      file: file, line: line)
    XCTAssertEqual(record["lastObservedAt"], .string(Self.timestamp(observed)), file: file, line: line)
    let reason: JSONValue = blocker.map(JSONValue.string) ?? .null
    XCTAssertEqual(record["blockerReasonCode"], reason, file: file, line: line)
    XCTAssertEqual(record["humanAction"], humanAction, file: file, line: line)
    XCTAssertEqual(record["dispatchCount"], .integer(0), file: file, line: line)
    let next: [String: JSONValue]
    let approvalID: JSONValue = Self.object(humanAction)?["actionId"] ?? .null
    switch state {
    case "previewReady":
      next = [
        "kind": .string("inspectControlAction"), "owner": owner, "resource": owner,
        "reasonCode": .string("controlAction.previewAvailable"),
      ]
    case "awaitingImpactApproval":
      next = [
        "kind": .string("humanAction"), "owner": owner,
        "resource": .object(["kind": .string("humanAction"), "id": approvalID]),
        "reasonCode": .string("policy.impactApprovalRequired"),
      ]
    default:
      next = ["kind": .string("reconcile"), "owner": owner, "resource": owner, "reasonCode": reason]
    }
    XCTAssertEqual(record["nextAction"], .object(next), file: file, line: line)
  }

  /// The preview a fixture HDC yields: no generation, version or health, and
  /// no client version (or, when `proved`, those `RegisteredHealthyServer`
  /// answers), the tool's digest and native signature, an empty participant
  /// set, and the critical Job gate, clear unless the inventory changed during
  /// the read.
  private func assertPreview(
    _ record: [String: JSONValue], host: Host, created: Date, proved: Bool = false,
    gate: JSONValue = .object([
      "state": .string("clear"), "blocking": .array([]), "reasonCode": .null,
    ]),
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let preview = try XCTUnwrap(Self.object(record["preview"]), file: file, line: line)
    let id = try XCTUnwrap(Self.string(record["controlActionId"]), file: file, line: line)
    let previewID = try XCTUnwrap(Self.string(preview["previewId"]), file: file, line: line)
    XCTAssertTrue(previewID.hasPrefix("preview-"), previewID, file: file, line: line)
    let owner: JSONValue = .object(["kind": .string("controlAction"), "id": .string(id)])
    let tool = try XCTUnwrap(Self.object(preview["tool"]), file: file, line: line)
    let signature = try XCTUnwrap(Self.object(tool["signature"]), file: file, line: line)
    XCTAssertEqual(
      Set(signature.keys),
      ["state", "identifier", "teamIdentifier", "platformTrust", "executionAssessment"],
      file: file, line: line)
    XCTAssertTrue(
      ["unsigned", "adHoc", "verified"].contains(Self.string(signature["state"]) ?? ""),
      "\(signature)", file: file, line: line)
    XCTAssertEqual(signature["platformTrust"], .string("unverified"), file: file, line: line)
    XCTAssertEqual(signature["executionAssessment"], .string("notPerformed"), file: file, line: line)
    var digested = preview
    let digest = try XCTUnwrap(digested.removeValue(forKey: "previewDigest"), file: file, line: line)
    XCTAssertEqual(
      digest,
      .string(SHA256Hex.string(of: try PortableCanonicalJSON.canonicalBytes(.object(digested)))),
      file: file, line: line)
    let generation: JSONValue = proved ? .string("100000023") : .null
    let health: JSONValue = .string(proved ? "healthy" : "unknown")
    let version: JSONValue = proved ? .string("3.2.0d") : .null
    XCTAssertEqual(
      preview,
      [
        "schemaVersion": .string("arkdeck.hdc-control-preview/1"), "controlActionId": .string(id),
        "previewId": .string(previewID), "kind": .string("hdcLifecycle"),
        "action": .string("restart"), "createdAt": .string(Self.timestamp(created)),
        "expiresAt": .string(Self.timestamp(created.addingTimeInterval(300))), "owner": owner,
        "confirmationRequired": .bool(true), "dispatchCount": .integer(0),
        "digestAlgorithm": .string("sha256-jcs"), "previewDigest": digest,
        "serverEndpointRef": .string(Self.reference), "endpoint": .string("127.0.0.1:8710"),
        "serverOwnership": .string("unknown"), "serverGeneration": generation,
        "serverHealth": health, "serverVersion": version,
        "tool": .object([
          "reference": .null, "executablePath": .string(host.executable.path),
          "source": .string("runtimeConfiguration"), "sha256": .string(host.executable.sha256),
          "signature": .object(signature), "version": version, "trust": .string("unverified"),
        ]),
        "affectedTargetIds": .array([]), "affectedJobIds": .array([]),
        "detectedOtherClientIds": .array([]), "otherClientsMayExist": .bool(true),
        "affectedDeviceObservations": .array([]),
        "criticalJobGate": gate,
        "interruption": .object([
          "kind": .string("hdcEndpointUnavailable"), "affectsAllParticipants": .bool(true),
        ]),
        "recovery": .object([
          "kind": .string("statusThenReconcile"), "replayAllowed": .bool(false),
        ]),
      ], file: file, line: line)
  }

  private func names(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private func mode(_ url: URL) -> mode_t {
    var status = stat()
    XCTAssertEqual(lstat(url.path, &status), 0, url.path)
    return status.st_mode
  }

  func testImpactPreviewRecordsEveryIntentAndTheReadsPageTheRecords() async throws {
    let host = try makeHost()
    let clock = Clock(Self.start)
    let daemon = try start(host, clock: clock)
    // Composing the owner makes its private records and snapshot directories.
    XCTAssertEqual(mode(host.records) & 0o777, 0o700)
    XCTAssertEqual(mode(host.ownerSnapshots) & 0o777, 0o700)
    XCTAssertEqual(mode(host.unionSnapshots) & 0o777, 0o700)

    // The intent is exactly four fields: action restart, an exact request
    // identity, an endpoint reference and a canonical generation.
    let preview = "runtime.hdc.impact-preview"
    assertRefused(try await daemon.send(preview, [:]), "invalidInput", Self.intentRequired)
    assertRefused(
      try await daemon.send(preview, intent("host-generation", generation: "0100000023")),
      "invalidInput", Self.intentRequired)
    // An unknown field is refused the same way. It is asked of the owner
    // directly: a recorded frame would publish the invented name in the
    // method's request schema.
    do {
      var fields = intent("host-extra")
      fields["executablePath"] = .string("/usr/bin/false")
      _ = try await daemon.owner.preview(fields)
      XCTFail("an intent with an unknown field was accepted")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "invalidInput")
      XCTAssertEqual(failure.message, Self.intentRequired)
    }
    // Another endpoint than the host's.
    assertRefused(
      try await daemon.send(
        preview,
        intent(
          "host-elsewhere",
          reference: "hdc-endpoint:" + SHA256Hex.string(of: Data("127.0.0.1:8711".utf8)))),
      "resourceNotFound", Self.endpointMissing)
    // No refusal persists a control action. Looking up the request identity
    // before the endpoint check opened the store's transaction lock.
    XCTAssertEqual(try names(host.records), [".lock"])
    XCTAssertEqual(host.port.listCount, 0, "no refusal observes")

    // The device observation fails: the durable action is invalidated with no
    // preview.
    host.port.setAnswers(false)
    let unobserved = try await daemon.answer(preview, intent("host-unobserved"))
    try assertRecord(
      unobserved, request: "host-unobserved", state: "previewDrifted", generation: "2",
      blocker: "hdc.impactObservationUnavailable", created: Self.start, observed: Self.start)
    XCTAssertEqual(unobserved["preview"], .null)

    // The observation succeeds but proves no server identity: an immutable
    // preview, blocked.
    host.port.setAnswers(true)
    let blocked = try await daemon.answer(preview, intent("host-blocked"))
    try assertRecord(
      blocked, request: "host-blocked", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: Self.start, observed: Self.start)
    try assertPreview(blocked, host: host, created: Self.start)
    XCTAssertEqual(host.port.listCount, 2)

    // A lost receipt returns the same action without observing again; the
    // same request identity cannot name another intent.
    let replayed = try await daemon.answer(preview, intent("host-blocked"))
    XCTAssertEqual(replayed, blocked)
    XCTAssertEqual(host.port.listCount, 2)
    assertRefused(
      try await daemon.send(preview, intent("host-blocked", generation: "100000024")),
      "idempotencyConflict", Self.otherIntent)

    // Each action is one owner-only record named by its request identity,
    // beside the transaction lock; no preview wrote a snapshot.
    let files = ["host-blocked", "host-unobserved"].map {
      "action-" + SHA256Hex.string(of: Data($0.utf8)) + ".json"
    }
    XCTAssertEqual(try names(host.records), ([".lock"] + files).sorted())
    for name in files {
      XCTAssertEqual(mode(host.records.appending(path: name)) & 0o777, 0o600, name)
    }
    XCTAssertEqual(try names(host.ownerSnapshots), [])
    XCTAssertEqual(try names(host.unionSnapshots), [])

    // show and reconcile read the same records. Reconciling the blocked
    // action observes again, finds the same impact and changes nothing.
    let blockedID = try XCTUnwrap(Self.string(blocked["controlActionId"]))
    let unobservedID = try XCTUnwrap(Self.string(unobserved["controlActionId"]))
    for method in ["control-action.show", "control-action.reconcile"] {
      let readBlocked = try await daemon.answer(method, ["controlAction": .string(blockedID)])
      XCTAssertEqual(readBlocked, blocked, method)
      let readUnobserved = try await daemon.answer(
        method, ["controlAction": .string(unobservedID)])
      XCTAssertEqual(readUnobserved, unobserved, method)
    }
    XCTAssertEqual(host.port.listCount, 3)

    // The union owner pages both records, in creation then identity order.
    let ordered = [blocked, unobserved].sorted {
      (Self.string($0["controlActionId"]) ?? "").utf8.lexicographicallyPrecedes(
        (Self.string($1["controlActionId"]) ?? "").utf8)
    }.map { JSONValue.object($0) }
    let all = try await daemon.answer("control-action.list", [:])
    XCTAssertEqual(all["items"], .array(ordered))
    XCTAssertEqual(all["hasMore"], .bool(false))
    XCTAssertEqual(all["nextCursor"], .null)
    // One record per page: the first page names the second.
    let first = try await daemon.answer("control-action.list", ["pageSize": .integer(1)])
    XCTAssertEqual(first["items"], .array([ordered[0]]))
    XCTAssertEqual(first["hasMore"], .bool(true))
    let revision = try XCTUnwrap(Self.string(first["snapshotRevision"]))
    let cursor = try XCTUnwrap(Self.string(first["nextCursor"]))
    XCTAssertTrue(cursor.hasPrefix(revision + "."), cursor)
    let second = try await daemon.answer(
      "control-action.list", ["pageSize": .integer(1), "cursor": .string(cursor)])
    XCTAssertEqual(
      second,
      [
        "schemaVersion": .string("arkdeck.cli.page/1"), "pageKind": .string("snapshot"),
        "items": .array([ordered[1]]), "order": .string(Self.order),
        "snapshotRevision": .string(revision), "hasMore": .bool(false), "nextCursor": .null,
      ])
    // A state filter pages only the matching records.
    let onlyBlocked = try await daemon.answer(
      "control-action.list", ["state": .string("blocked")])
    XCTAssertEqual(onlyBlocked["items"], .array([.object(blocked)]))
    XCTAssertEqual(try names(host.unionSnapshots).count, 3, "one snapshot per first page")
    XCTAssertEqual(try names(host.ownerSnapshots), [], "the union owner pages, not the HDC owner")

    XCTAssertEqual(host.dispatcher.dispatchCount, 0)
    let jobs = try await host.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertTrue(try host.targets.list().isEmpty, "an impact preview adopts no target")
  }

  func testARestartedOrExpiredPreviewIsInvalidatedWhenRead() async throws {
    let host = try makeHost()
    let clock = Clock(Self.start)
    let preview = "runtime.hdc.impact-preview"
    let before = try await start(host, clock: clock).answer(preview, intent("host-restarted"))
    try assertRecord(
      before, request: "host-restarted", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: Self.start, observed: Self.start)
    let restartedID = try XCTUnwrap(Self.string(before["controlActionId"]))

    // The daemon starts again: a new epoch over the same state. Reading the
    // earlier preview invalidates it without observing again; the immutable
    // preview stays.
    clock.advance(60)
    let restartedAt = clock.now()
    let daemon = try start(host, clock: clock)
    let observed = host.port.listCount
    let restarted = try await daemon.answer(
      "control-action.show", ["controlAction": .string(restartedID)])
    try assertRecord(
      restarted, request: "host-restarted", state: "previewDrifted", generation: "3",
      blocker: "controlAction.runtimeRestarted", created: Self.start, observed: restartedAt)
    XCTAssertEqual(restarted["preview"], before["preview"])
    XCTAssertEqual(host.port.listCount, observed)

    // A preview of this daemon expires 300 seconds after its creation.
    let expiring = try await daemon.answer(preview, intent("host-expiring"))
    try assertRecord(
      expiring, request: "host-expiring", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: restartedAt, observed: restartedAt)
    let expiringID = try XCTUnwrap(Self.string(expiring["controlActionId"]))
    clock.advance(300)
    let expiredAt = clock.now()
    let expired = try await daemon.answer(
      "control-action.show", ["controlAction": .string(expiringID)])
    try assertRecord(
      expired, request: "host-expiring", state: "expired", generation: "3",
      blocker: "controlAction.expired", created: restartedAt, observed: expiredAt)
    XCTAssertEqual(expired["preview"], expiring["preview"])
    // Reconciling an invalidated action changes nothing, and the listing
    // holds both, the older first.
    let reconciledExpired = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(expiringID)])
    XCTAssertEqual(reconciledExpired, expired)
    let reconciledRestarted = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(restartedID)])
    XCTAssertEqual(reconciledRestarted, restarted)
    let listed = try await daemon.answer("control-action.list", [:])
    XCTAssertEqual(listed["items"], .array([.object(restarted), .object(expired)]))
    XCTAssertEqual(host.dispatcher.dispatchCount, 0)
  }

  /// A blocked preview is read, reconciled over the same impact without any
  /// change, and listed alone, as the fixture's blocked one is.
  private func assertReadReconciledAndListed(
    _ preview: [String: JSONValue], daemon: Daemon, host: Host,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let id = try XCTUnwrap(Self.string(preview["controlActionId"]), file: file, line: line)
    let shown = try await daemon.answer("control-action.show", ["controlAction": .string(id)])
    XCTAssertEqual(shown, preview, file: file, line: line)
    let reconciled = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(id)])
    XCTAssertEqual(reconciled, preview, file: file, line: line)
    XCTAssertEqual(host.port.listCount, 2, "reconciling observed again", file: file, line: line)
    let listed = try await daemon.answer("control-action.list", [:])
    XCTAssertEqual(listed["items"], .array([.object(preview)]), file: file, line: line)
    XCTAssertEqual(listed["hasMore"], .bool(false), file: file, line: line)
    XCTAssertEqual(host.dispatcher.dispatchCount, 0, file: file, line: line)
    let jobs = try await host.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty, file: file, line: line)
  }

  func testATeamSignedToolIsPreviewedWithItsTeamIdentifier() async throws {
    let published = HDCStatusControlFramesContractTests.teamSignedExecutable
    guard FileManager.default.fileExists(atPath: published.path) else {
      throw XCTSkip("DevEco is not installed; no team-signed executable to preview")
    }
    let host = try makeHost(tool: published)
    guard
      case .object(let signature) = try HeadlessHDCStatusObserver.signature(
        URL(filePath: host.executable.path)),
      case .string(_)? = signature["teamIdentifier"]
    else { throw XCTSkip("the DevEco executable carries no team identifier") }
    let daemon = try start(host, clock: Clock(Self.start))

    let preview = try await daemon.answer(
      "runtime.hdc.impact-preview", intent("host-team-signed"))
    try assertRecord(
      preview, request: "host-team-signed", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: Self.start, observed: Self.start)
    try assertPreview(preview, host: host, created: Self.start)
    // The tool's signature is its static signing facts as read: verified,
    // with the team that signed it.
    let tool = try XCTUnwrap(Self.object(Self.object(preview["preview"])?["tool"]))
    XCTAssertEqual(tool["signature"], .object(signature))
    XCTAssertEqual(signature["state"], .string("verified"))
    try await assertReadReconciledAndListed(preview, daemon: daemon, host: host)
  }

  func testAnInventoryChangedWhileTheImpactIsReadLeavesTheCriticalJobGateUnknown() async throws {
    let host = try makeHost()
    _ = try host.targets.adopt(
      stableIdentitySHA256: String(repeating: "c", count: 64), connectKey: "synthetic-participant",
      toolVersion: "fixture", nowUTC: "2026-09-19T00:00:00Z")
    let document = root.appending(path: "targets/targets.json")
    let adopted = try Data(contentsOf: document)
    XCTAssertEqual(try host.targets.list().count, 1)
    // The durable Target document is removed while each device list is read:
    // the inventory read after the devices is not the one read before them.
    host.port.setDuringList { try? FileManager.default.removeItem(at: document) }
    let daemon = try start(host, clock: Clock(Self.start))

    let preview = try await daemon.answer(
      "runtime.hdc.impact-preview", intent("host-inventory-changed"))
    try assertRecord(
      preview, request: "host-inventory-changed", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: Self.start, observed: Self.start)
    // The gate is unknown, with its reason, although no Job, Target or device
    // remains to name: every Target the preview names is one read after the
    // devices, and none is left.
    try assertPreview(
      preview, host: host, created: Self.start,
      gate: .object([
        "state": .string("unknown"), "blocking": .array([]),
        "reasonCode": .string("hdc.participantInventoryUnproven"),
      ]))
    XCTAssertTrue(try host.targets.list().isEmpty)
    // Reconciling reads the inventory again, restored first, and it changes
    // the same way: the same impact.
    try adopted.write(to: document)
    try await assertReadReconciledAndListed(preview, daemon: daemon, host: host)
    XCTAssertTrue(try host.targets.list().isEmpty)
  }

  /// The HDC oracles' unsigned shell driver, which nothing here runs.
  private func unsignedTool() throws -> URL {
    let driver = root.appending(path: "unsigned-hdc")
    try HDCOracleFake.driver.write(to: driver)
    XCTAssertEqual(chmod(driver.path, 0o700), 0)
    return driver
  }

  func testAnUnsignedToolIsPreviewedWithoutASigningIdentity() async throws {
    let host = try makeHost(tool: try unsignedTool())
    XCTAssertEqual(
      try HeadlessHDCStatusObserver.signature(URL(filePath: host.executable.path)),
      Self.unsignedSignature)
    let daemon = try start(host, clock: Clock(Self.start))

    let preview = try await daemon.answer(
      "runtime.hdc.impact-preview", intent("host-unsigned"))
    try assertRecord(
      preview, request: "host-unsigned", state: "blocked", generation: "2",
      blocker: "hdc.serverIdentityUnproven", created: Self.start, observed: Self.start)
    try assertPreview(preview, host: host, created: Self.start)
    // The tool's signature names no signing identity and no team.
    let tool = try XCTUnwrap(Self.object(Self.object(preview["preview"])?["tool"]))
    XCTAssertEqual(tool["signature"], Self.unsignedSignature)
    try await assertReadReconciledAndListed(preview, daemon: daemon, host: host)
    // Its exact tuple names a blocked preview, which is not eligible for an
    // impact approval.
    assertRefused(
      try await daemon.send("runtime.hdc.restart", tuple(preview)), "admissionDenied",
      Self.ineligible)
    XCTAssertEqual(host.port.listCount, 2, "a refused restart observes nothing")
  }

  // MARK: restart

  /// The restart tuple naming a record's exact preview.
  private func tuple(_ record: [String: JSONValue]) throws -> [String: JSONValue] {
    let preview = try XCTUnwrap(Self.object(record["preview"]))
    return [
      "controlAction": try XCTUnwrap(record["controlActionId"]),
      "previewId": try XCTUnwrap(preview["previewId"]),
      "previewDigest": try XCTUnwrap(preview["previewDigest"]),
    ]
  }

  /// A preview `RegisteredHealthyServer` proves: ready at generation 2.
  private func readyPreview(
    _ daemon: Daemon, host: Host, request: String, at created: Date,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws -> [String: JSONValue] {
    let ready = try await daemon.answer(
      "runtime.hdc.impact-preview", intent(request), file: file, line: line)
    try assertRecord(
      ready, request: request, state: "previewReady", generation: "2", blocker: nil,
      created: created, observed: created, file: file, line: line)
    try assertPreview(ready, host: host, created: created, proved: true, file: file, line: line)
    return ready
  }

  /// The impact approval a restart requests: owned by the control action,
  /// bound to its exact preview and to the generation that awaits it, and
  /// closing with the preview. Returns its identity.
  @discardableResult
  private func assertApproval(
    _ value: JSONValue?, of record: [String: JSONValue], generation: String, created: Date,
    status: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> String {
    let approval = try XCTUnwrap(Self.object(value), file: file, line: line)
    let id = try XCTUnwrap(Self.string(approval["actionId"]), file: file, line: line)
    XCTAssertTrue(id.hasPrefix("har-"), id, file: file, line: line)
    let resume = try XCTUnwrap(Self.string(approval["resumeReference"]), file: file, line: line)
    XCTAssertTrue(resume.hasPrefix("resume-"), resume, file: file, line: line)
    let preview = try XCTUnwrap(Self.object(record["preview"]), file: file, line: line)
    let action: JSONValue = record["controlActionId"] ?? .null
    let expires: JSONValue = record["expiresAt"] ?? .null
    let previewID: JSONValue = preview["previewId"] ?? .null
    let digest: JSONValue = preview["previewDigest"] ?? .null
    let binding: JSONValue = .object([
      "controlActionId": action, "previewId": previewID, "previewDigest": digest,
      "generation": .string(generation),
    ])
    XCTAssertEqual(
      approval,
      [
        "schemaVersion": .string("arkdeck.human-action/1"), "actionId": .string(id),
        "owner": .object(["kind": .string("controlAction"), "id": action]),
        "resumeReference": .string(resume), "category": .string("impactApproval"),
        "reasonCode": .string("policy.impactApprovalRequired"),
        "minimumAction": .string("human.reviewImpact"),
        "prohibitedAutomation": .array([.string("selfApproval")]),
        "createdAt": .string(Self.timestamp(created)), "expiresAt": expires,
        "status": .string(status), "newDispatchCount": .integer(0), "selectionSchema": .null,
        "choices": .array([]), "binding": binding,
      ], file: file, line: line)
    return id
  }

  /// A restart refused because the fresh impact is not the reviewed one: no
  /// approval, and the action it invalidated in the refusal's details, which
  /// this returns.
  private func assertDrifted(
    _ response: AgentWireProtocol.Response, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> [String: JSONValue] {
    XCTAssertFalse(response.ok, file: file, line: line)
    XCTAssertNil(response.result, file: file, line: line)
    XCTAssertEqual(response.error?.code, "factsDrifted", file: file, line: line)
    XCTAssertEqual(response.error?.message, message, file: file, line: line)
    let details = try XCTUnwrap(response.error?.details, file: file, line: line)
    XCTAssertEqual(Set(details.keys), ["controlAction", "newDispatchCount"], file: file, line: line)
    XCTAssertEqual(details["newDispatchCount"], .integer(0), file: file, line: line)
    return try XCTUnwrap(Self.object(details["controlAction"]), file: file, line: line)
  }

  func testRestartOfAReadyPreviewRequestsItsImpactApprovalOnce() async throws {
    let host = try makeHost()
    let clock = Clock(Self.start)
    let daemon = try start(host, clock: clock, healthy: true)
    let ready = try await readyPreview(daemon, host: host, request: "host-restart", at: Self.start)
    XCTAssertEqual(host.port.listCount, 1)
    let id = try XCTUnwrap(Self.string(ready["controlActionId"]))
    let exact = try tuple(ready)
    let restart = "runtime.hdc.restart"

    // The request is exactly the tuple, each member an exact identity or a
    // lowercase digest.
    assertRefused(try await daemon.send(restart, [:]), "invalidInput", Self.tupleRequired)
    var uppercase = exact
    uppercase["previewDigest"] = .string((Self.string(exact["previewDigest"]) ?? "").uppercased())
    assertRefused(try await daemon.send(restart, uppercase), "invalidInput", Self.tupleRequired)
    // An action no record holds; this action with another digest or preview.
    var unknown = exact
    unknown["controlAction"] = .string("control-action-" + UUID().uuidString.lowercased())
    assertRefused(try await daemon.send(restart, unknown), "resourceNotFound", Self.actionMissing)
    var otherDigest = exact
    otherDigest["previewDigest"] = .string(String(repeating: "0", count: 64))
    assertRefused(
      try await daemon.send(restart, otherDigest), "reviewedPlanMismatch", Self.otherPreview)
    var otherPreviewID = exact
    otherPreviewID["previewId"] = .string("preview-" + UUID().uuidString.lowercased())
    assertRefused(
      try await daemon.send(restart, otherPreviewID), "reviewedPlanMismatch", Self.otherPreview)
    // No refusal observes or changes the action (asked of the owner, so
    // nothing is recorded).
    XCTAssertEqual(host.port.listCount, 1, "no refusal observes")
    let unchanged = try await daemon.owner.show(id)
    XCTAssertEqual(unchanged, .object(ready))

    // The exact tuple, half a minute after the preview: the fresh impact is
    // the reviewed one, so the action awaits its impact approval.
    clock.advance(30)
    let requested = clock.now()
    let awaiting = try await daemon.answer(restart, exact)
    XCTAssertEqual(host.port.listCount, 2, "the restart observed the impact again")
    let approval = try assertApproval(
      awaiting["humanAction"], of: awaiting, generation: "3", created: requested,
      status: "waiting")
    try assertRecord(
      awaiting, request: "host-restart", state: "awaitingImpactApproval", generation: "3",
      blocker: nil, created: Self.start, observed: requested,
      humanAction: awaiting["humanAction"] ?? .null)
    XCTAssertEqual(awaiting["preview"], ready["preview"])

    // A lost receipt answers the same approval without observing again;
    // another digest still names no preview of this action.
    let repeated = try await daemon.answer(restart, exact)
    XCTAssertEqual(repeated, awaiting)
    XCTAssertEqual(host.port.listCount, 2)
    assertRefused(
      try await daemon.send(restart, otherDigest), "reviewedPlanMismatch", Self.otherPreview)
    // The preview's request identity, sent again, answers the action as it
    // now is, observed no more.
    let previewedAgain = try await daemon.answer(
      "runtime.hdc.impact-preview", intent("host-restart"))
    XCTAssertEqual(previewedAgain, awaiting)
    XCTAssertEqual(host.port.listCount, 2)

    // Read, reconciled over the same impact without a change, and listed,
    // whole and by its state.
    let shown = try await daemon.answer("control-action.show", ["controlAction": .string(id)])
    XCTAssertEqual(shown, awaiting)
    let reconciled = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(id)])
    XCTAssertEqual(reconciled, awaiting)
    XCTAssertEqual(host.port.listCount, 3, "reconciling observed again")
    let filterSets: [[String: JSONValue]] = [[:], ["state": .string("awaitingImpactApproval")]]
    for filters in filterSets {
      let page = try await daemon.answer("control-action.list", filters)
      XCTAssertEqual(page["items"], .array([.object(awaiting)]), "\(filters)")
      XCTAssertEqual(page["hasMore"], .bool(false), "\(filters)")
    }

    // The human-action union owner serves the approval as the control action
    // projects it.
    let projected: JSONValue = awaiting["humanAction"] ?? .null
    let shownApproval = try await daemon.answer(
      "human-action.show", ["humanAction": .string(approval)])
    XCTAssertEqual(JSONValue.object(shownApproval), projected)
    let approvals = try await daemon.answer(
      "human-action.list", ["ownerKind": .string("controlAction"), "owner": .string(id)])
    XCTAssertEqual(approvals["items"], JSONValue.array([projected]))

    // A clock behind the action's last observation is refused before any read.
    clock.advance(-1)
    assertRefused(
      try await daemon.send(restart, exact), "orchestrationClockUntrusted", Self.clockBackwards)
    XCTAssertEqual(host.port.listCount, 3)

    // One owner-only record; nothing dispatched, no Job and no Target.
    let recordFile = "action-" + SHA256Hex.string(of: Data("host-restart".utf8)) + ".json"
    XCTAssertEqual(try names(host.records), [".lock", recordFile])
    XCTAssertEqual(host.dispatcher.dispatchCount, 0)
    let jobs = try await host.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertTrue(try host.targets.list().isEmpty)
  }

  func testRestartIsRefusedWhenTheFreshImpactIsUnprovenOrNotTheReviewedOne() async throws {
    let host = try makeHost()
    let clock = Clock(Self.start)
    let daemon = try start(host, clock: clock, healthy: true)
    let restart = "runtime.hdc.restart"
    let unproven = try await readyPreview(
      daemon, host: host, request: "host-restart-unproven", at: Self.start)
    let drifted = try await readyPreview(
      daemon, host: host, request: "host-restart-drifted", at: Self.start)
    clock.advance(30)
    let refusedAt = clock.now()

    // The fresh observation fails: no approval is requested, and the action is
    // invalidated with that reason, its reviewed preview kept.
    host.port.setAnswers(false)
    let failed = try assertDrifted(
      try await daemon.send(restart, tuple(unproven)), Self.unprovenImpact)
    try assertRecord(
      failed, request: "host-restart-unproven", state: "previewDrifted", generation: "3",
      blocker: "hdc.impactObservationUnavailable", created: Self.start, observed: refusedAt)
    XCTAssertEqual(failed["preview"], unproven["preview"])
    let durable = try await daemon.owner.show(try XCTUnwrap(Self.string(failed["controlActionId"])))
    XCTAssertEqual(durable, .object(failed))
    // An invalidated action is not eligible for an impact approval.
    assertRefused(
      try await daemon.send(restart, tuple(unproven)), "admissionDenied", Self.ineligible)
    host.port.setAnswers(true)

    // A Target adopted after the review: the fresh impact names it, the
    // reviewed preview does not.
    _ = try host.targets.adopt(
      stableIdentitySHA256: String(repeating: "d", count: 64), connectKey: "synthetic-adopted",
      toolVersion: "fixture", nowUTC: "2026-09-19T00:00:30Z")
    let changed = try assertDrifted(
      try await daemon.send(restart, tuple(drifted)), Self.differentImpact)
    try assertRecord(
      changed, request: "host-restart-drifted", state: "previewDrifted", generation: "3",
      blocker: "hdc.previewDrifted", created: Self.start, observed: refusedAt)
    XCTAssertEqual(changed["preview"], drifted["preview"])
    XCTAssertEqual(host.port.listCount, 4, "each restart observed once")
    XCTAssertEqual(host.dispatcher.dispatchCount, 0)
    let jobs = try await host.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testAnAwaitedImpactApprovalDriftsOrExpiresWithoutDispatch() async throws {
    let host = try makeHost()
    let clock = Clock(Self.start)
    let daemon = try start(host, clock: clock, healthy: true)
    let restart = "runtime.hdc.restart"
    let expiring = try await readyPreview(
      daemon, host: host, request: "host-approval-expiring", at: Self.start)
    clock.advance(1)
    let driftingAt = clock.now()
    let drifting = try await readyPreview(
      daemon, host: host, request: "host-approval-drifting", at: driftingAt)
    clock.advance(29)
    let requested = clock.now()
    let expiringID = try XCTUnwrap(Self.string(expiring["controlActionId"]))
    let driftingID = try XCTUnwrap(Self.string(drifting["controlActionId"]))
    let awaitingExpiring = try await daemon.answer(restart, tuple(expiring))
    let expiringApproval = try assertApproval(
      awaitingExpiring["humanAction"], of: awaitingExpiring, generation: "3",
      created: requested, status: "waiting")
    let awaitingDrifting = try await daemon.answer(restart, tuple(drifting))
    let driftingApproval = try assertApproval(
      awaitingDrifting["humanAction"], of: awaitingDrifting, generation: "3",
      created: requested, status: "waiting")

    // The impact changes while the approval is awaited: reconciling reads it
    // again, invalidates the action and expires its approval.
    _ = try host.targets.adopt(
      stableIdentitySHA256: String(repeating: "d", count: 64), connectKey: "synthetic-adopted",
      toolVersion: "fixture", nowUTC: "2026-09-19T00:00:30Z")
    clock.advance(30)
    let driftedAt = clock.now()
    let drifted = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(driftingID)])
    try assertApproval(
      drifted["humanAction"], of: drifted, generation: "3", created: requested,
      status: "expired")
    try assertRecord(
      drifted, request: "host-approval-drifting", state: "previewDrifted", generation: "4",
      blocker: "hdc.previewDrifted", created: driftingAt, observed: driftedAt,
      humanAction: drifted["humanAction"] ?? .null)
    XCTAssertEqual(drifted["preview"], drifting["preview"])
    let shownDrifted = try await daemon.answer(
      "control-action.show", ["controlAction": .string(driftingID)])
    XCTAssertEqual(shownDrifted, drifted)
    let expiredDrifting = try await daemon.answer(
      "human-action.show", ["humanAction": .string(driftingApproval)])
    XCTAssertEqual(drifted["humanAction"], JSONValue.object(expiredDrifting))
    assertRefused(
      try await daemon.send(restart, tuple(drifting)), "admissionDenied", Self.ineligible)

    // The approval closes with its preview, 300 seconds after the preview was
    // made; reading the action then expires both.
    clock.advance(240)
    let expiredAt = clock.now()
    XCTAssertEqual(expiredAt, Self.start.addingTimeInterval(300))
    let expired = try await daemon.answer(
      "control-action.show", ["controlAction": .string(expiringID)])
    try assertApproval(
      expired["humanAction"], of: expired, generation: "3", created: requested,
      status: "expired")
    try assertRecord(
      expired, request: "host-approval-expiring", state: "expired", generation: "4",
      blocker: "controlAction.expired", created: Self.start, observed: expiredAt,
      humanAction: expired["humanAction"] ?? .null)
    XCTAssertEqual(expired["preview"], expiring["preview"])
    let reconciledExpired = try await daemon.answer(
      "control-action.reconcile", ["controlAction": .string(expiringID)])
    XCTAssertEqual(reconciledExpired, expired)
    let expiredApproval = try await daemon.answer(
      "human-action.show", ["humanAction": .string(expiringApproval)])
    XCTAssertEqual(expired["humanAction"], JSONValue.object(expiredApproval))
    assertRefused(
      try await daemon.send(restart, tuple(expiring)), "admissionDenied", Self.ineligible)
    let listed = try await daemon.answer("control-action.list", [:])
    XCTAssertEqual(listed["items"], .array([.object(expired), .object(drifted)]))

    // Two previews, two restarts and one reconciliation observed; nothing was
    // dispatched.
    XCTAssertEqual(host.port.listCount, 5)
    XCTAssertEqual(host.dispatcher.dispatchCount, 0)
    let jobs = try await host.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  /// A ready preview of `host`'s tool awaits its approval with the tool's
  /// signature as read, and another's restart, refused once the observation
  /// fails, keeps that signature in the action it invalidated.
  private func assertRestartKeepsTheSignature(
    of host: Host, request: String, signature: JSONValue,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let clock = Clock(Self.start)
    let daemon = try start(host, clock: clock, healthy: true)
    let ready = try await readyPreview(
      daemon, host: host, request: request, at: Self.start, file: file, line: line)
    let other = try await readyPreview(
      daemon, host: host, request: request + "-unproven", at: Self.start, file: file, line: line)
    let tool = try XCTUnwrap(
      Self.object(Self.object(ready["preview"])?["tool"]), file: file, line: line)
    XCTAssertEqual(tool["signature"], signature, file: file, line: line)
    clock.advance(30)
    let requested = clock.now()
    let awaiting = try await daemon.answer(
      "runtime.hdc.restart", tuple(ready), file: file, line: line)
    try assertApproval(
      awaiting["humanAction"], of: awaiting, generation: "3", created: requested,
      status: "waiting", file: file, line: line)
    try assertRecord(
      awaiting, request: request, state: "awaitingImpactApproval", generation: "3",
      blocker: nil, created: Self.start, observed: requested,
      humanAction: awaiting["humanAction"] ?? .null, file: file, line: line)
    XCTAssertEqual(awaiting["preview"], ready["preview"], file: file, line: line)
    host.port.setAnswers(false)
    let invalid = try assertDrifted(
      try await daemon.send("runtime.hdc.restart", tuple(other)), Self.unprovenImpact,
      file: file, line: line)
    try assertRecord(
      invalid, request: request + "-unproven", state: "previewDrifted", generation: "3",
      blocker: "hdc.impactObservationUnavailable", created: Self.start, observed: requested,
      file: file, line: line)
    XCTAssertEqual(invalid["preview"], other["preview"], file: file, line: line)
    XCTAssertEqual(host.dispatcher.dispatchCount, 0, file: file, line: line)
  }

  func testAnUnsignedToolsRestartKeepsItsSignature() async throws {
    try await assertRestartKeepsTheSignature(
      of: try makeHost(tool: try unsignedTool()), request: "host-unsigned-restart",
      signature: Self.unsignedSignature)
  }

  func testATeamSignedToolsRestartKeepsItsTeamIdentifier() async throws {
    let published = HDCStatusControlFramesContractTests.teamSignedExecutable
    guard FileManager.default.fileExists(atPath: published.path) else {
      throw XCTSkip("DevEco is not installed; no team-signed executable to preview")
    }
    let host = try makeHost(tool: published)
    guard
      case .object(let signature) = try HeadlessHDCStatusObserver.signature(
        URL(filePath: host.executable.path)),
      case .string(_)? = signature["teamIdentifier"]
    else { throw XCTSkip("the DevEco executable carries no team identifier") }
    try await assertRestartKeepsTheSignature(
      of: host, request: "host-team-signed-restart", signature: .object(signature))
  }
}
