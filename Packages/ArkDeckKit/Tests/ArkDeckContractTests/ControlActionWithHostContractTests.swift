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
/// remains to name.
final class ControlActionWithHostContractTests: XCTestCase {
  /// 2026-09-19T00:00:00Z, as the records spell it.
  private static let start = Date(timeIntervalSince1970: 1_789_776_000)
  private static let order = "createdAtThenControlActionId"
  private static let intentRequired = "an exact restart intent and request identity are required"
  private static let endpointMissing = "the exact HDC endpoint reference is not configured"
  private static let otherIntent = "the request identity belongs to a different lifecycle intent"
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

  /// One daemon start over the host: the HDC control-action owner with a fresh
  /// epoch, the union owner over it (no tool-selection owner), and the handler.
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
  /// restart reaches).
  private func start(_ host: Host, clock: Clock) throws -> Daemon {
    let owner = try RuntimeHDCControlActionCoordinator(
      directory: host.state.appending(path: "hdc-control-actions"), source: host.source,
      catalogDigest: RuntimeOperationCatalog.catalogDigest, now: { clock.now() })
    let controls = try RuntimeControlActionResourceCoordinator(
      directory: host.unionSnapshots, hdc: owner, tools: nil)
    let handler = RuntimeControlPlaneHandler(
      engine: host.engine, capabilityStore: host.capabilities, providerIDs: [],
      nowUTC: { "2026-09-19T00:00:00Z" }, targetStore: host.targets,
      targetObservations: host.observations, hdcControlActions: owner,
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
  /// facts a state change moves.
  private func assertRecord(
    _ record: [String: JSONValue], request: String, state: String, generation: String,
    blocker: String, created: Date, observed: Date,
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
    XCTAssertEqual(record["blockerReasonCode"], .string(blocker), file: file, line: line)
    XCTAssertEqual(record["humanAction"], .null, file: file, line: line)
    XCTAssertEqual(record["dispatchCount"], .integer(0), file: file, line: line)
    XCTAssertEqual(
      record["nextAction"],
      .object([
        "kind": .string("reconcile"), "owner": owner, "resource": owner,
        "reasonCode": .string(blocker),
      ]), file: file, line: line)
  }

  /// The preview a fixture HDC yields: no generation, version or health, the
  /// fixture's digest and native signature, an empty participant set, and
  /// the critical Job gate, clear unless the inventory changed during the read.
  private func assertUnprovedPreview(
    _ record: [String: JSONValue], host: Host, created: Date,
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
        "serverOwnership": .string("unknown"), "serverGeneration": .null,
        "serverHealth": .string("unknown"), "serverVersion": .null,
        "tool": .object([
          "reference": .null, "executablePath": .string(host.executable.path),
          "source": .string("runtimeConfiguration"), "sha256": .string(host.executable.sha256),
          "signature": .object(signature), "version": .null, "trust": .string("unverified"),
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
    try assertUnprovedPreview(blocked, host: host, created: Self.start)
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
    try assertUnprovedPreview(preview, host: host, created: Self.start)
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
    try assertUnprovedPreview(
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
}
