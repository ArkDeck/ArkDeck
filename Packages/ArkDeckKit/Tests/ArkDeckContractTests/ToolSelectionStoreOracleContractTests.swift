// Shared Swift oracle for the Rust tool-selection control-action store
// (TASK-XPA-012): the files `RuntimeToolSelectionControlActionStore` keeps in
// `<state>/tool-selection-control-actions/records` for one selection in each
// state a record can hold, the transitions that led there, and each record's
// public projection (`control-action.show`, `.list`).
//
// The records carry random identities (`UUID()` in the control action, its
// preview, its human action, challenge and receipt), and the preview digest
// covers two of them, so a new recording can never repeat the old bytes.
// Checked-in, the oracle is held two ways instead:
// - the production store reads the checked-in directory back, every record
//   is its own canonical bytes, and its projection is the checked-in one;
// - the same timeline, played again through the production store, leaves the
//   same records once their random identities and the preview digest over
//   them are set aside.
// One record (`oracle-lifecycle`) comes from the production lifecycle
// Supervisor and executor launching a fake HDC, as
// `RuntimeToolSelectionControlActionContractTests` drives it; it is recorded
// once and only read back. Every other audit payload is synthetic: the store
// keeps audit payloads as opaque objects, so they carry values that stress
// canonical JSON (UTF-16 key order, escapes, numbers) instead.
//
// Host-local only: no device, no daemon, no HDC server. Record a new oracle
// with `ARKDECK_RUST_TOOL_SELECTION_STORE_RECORD=/private/tmp/<new directory>`.
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class ToolSelectionStoreOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/tool-selection-store", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_TOOL_SELECTION_STORE_RECORD"
  /// A fixed root: the lifecycle record's executable path names it.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-tool-selection-store-oracle", directoryHint: .isDirectory)
  private static let catalog = String(repeating: "c", count: 64)
  private static let oldDigest = String(repeating: "a", count: 64)
  private static let newDigest = String(repeating: "b", count: 64)
  private static let epoch = "epoch-oracle"
  private static let challenge = "ARKDECK-A1B2C3D4E"
  /// 2026-09-01T00:00:00Z; the n-th timeline starts n × 1000 s later.
  private static let start = Date(timeIntervalSince1970: 1_788_220_800)

  override func setUpWithError() throws {
    try? FileManager.default.removeItem(at: Self.root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: Self.root)
  }

  // MARK: Facts

  private static func tool(_ digest: String, signed: Bool) throws -> RuntimeToolSelectionToolFacts {
    try RuntimeToolSelectionToolFacts(value: [
      "toolRef": .string("tool:sha256:\(digest)"),
      "recordGeneration": .string("1"),
      "contentSHA256": .string(digest),
      "executableSHA256": .string(digest),
      "signature": .object(
        signed
          ? [
            "state": .string("verified"), "identifier": .string("com.huawei.hdc"),
            "teamIdentifier": .string("FIXTURETEAM"),
            "codeDirectoryIdentitySHA256": .string(String(repeating: "d", count: 64)),
          ]
          : [
            "state": .string("adHoc"), "identifier": .null,
            "teamIdentifier": .null, "codeDirectoryIdentitySHA256": .null,
          ]),
      "version": .string(signed ? "3.2.0f" : "3.2.0-test"),
      "trust": .object([
        "policy": .string("arkdeck.host-tool-inspection/1"),
        "registeredIdentity": .bool(true),
        "platformTrust": .string("unverified"),
        "executionAssessment": .string("notPerformed"),
        "profileReferences": .array(
          signed ? [.string("fixture-profile"), .string("hdc-3.2")] : []),
      ]),
    ])
  }

  private static func impact(_ changes: [String: JSONValue] = [:]) throws -> HDCControlImpact {
    let endpoint = "127.0.0.1:8710"
    var fields: [String: JSONValue] = [
      "serverEndpointRef": .string("hdc-endpoint:" + SHA256Hex.string(of: Data(endpoint.utf8))),
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
        "kind": .string("hdcEndpointUnavailable"), "affectsAllParticipants": .bool(true),
      ]),
      "recovery": .object([
        "kind": .string("statusThenReconcile"), "replayAllowed": .bool(false),
      ]),
    ]
    fields.merge(changes, uniquingKeysWith: { _, new in new })
    return try HDCControlImpact(fields)
  }

  private static func selection(_ hdc: HDCControlImpact) throws -> RuntimeToolSelectionImpact {
    try RuntimeToolSelectionImpact(
      hdc: hdc, oldTool: tool(oldDigest, signed: false), newTool: tool(newDigest, signed: true),
      activeGeneration: 1)
  }

  /// Unsorted and repeated collections, which the impact makes canonical, and
  /// a critical Job gate that blocks.
  private static func blockedImpact() throws -> HDCControlImpact {
    try impact([
      "affectedTargetIds": .array([.string("target-b"), .string("target-a"), .string("target-b")]),
      "affectedJobIds": .array([.string("job-2"), .string("job-1")]),
      "detectedOtherClientIds": .array([.string("client-9")]),
      "affectedDeviceObservations": .array([
        .object([
          "observationId": .string("observation-2"), "generation": .string("4"),
          "authorization": .string("authorized"), "health": .string("connected"),
        ]),
        .object([
          "observationId": .string("observation-1"), "generation": .string("3"),
          "authorization": .string("unknown"), "health": .string("offline"),
        ]),
      ]),
      "criticalJobGate": .object([
        "state": .string("blocked"), "reasonCode": .string("hdc.criticalJobsUnresolved"),
        "blocking": .array([
          .object([
            "jobId": .string("job-2"), "stepId": .null, "state": .string("running"),
            "safeBoundary": .string("unknown"), "recovery": .string("waitForJob"),
          ]),
          .object([
            "jobId": .string("job-1"), "stepId": .string("capture"),
            "state": .string("running"), "safeBoundary": .string("blocked"),
            "recovery": .string("reconcileJob"),
          ]),
        ]),
      ]),
    ])
  }

  /// One proved USB relation of an observation, as the impact source reads it.
  private static let relation: JSONValue = .object([
    "observationId": .string("observation-1"), "generation": .string("3"),
    "serial": .string("FIXTURE-SERIAL"), "location": .string("4"),
    "attachmentId": .string("12"), "vendorId": .integer(11306), "productId": .integer(24641),
  ])

  /// A synthetic audit payload: the store keeps it as an opaque object.
  private static func payload(_ kind: String) -> [String: JSONValue] {
    [
      "fixture": .string(kind),
      "path": .string("/private/tmp/arkdeck-tool-selection-store-oracle/selected-hdc"),
      "text": .string("é 中 😀 \"quoted\" \\ \t\u{01} </script>"),
      "integer": .integer(8), "negative": .integer(-1), "exact": .integer(9_007_199_254_740_991),
      "fraction": .number(0.25), "tiny": .number(1e-7), "huge": .number(1e21),
      "flag": .bool(true), "absent": .null,
      "list": .array([.string("b"), .string("a"), .integer(2), .array([])]),
      "nested": .object(["z": .integer(1), "a": .object(["m": .null])]),
      // JCS orders keys by UTF-16 code unit: the surrogate pair sorts first.
      "\u{E000}": .string("private use"), "😀": .string("astral"),
    ]
  }

  private static func at(_ timeline: Int, _ seconds: Double) -> Date {
    start.addingTimeInterval(Double(timeline) * 1000 + seconds)
  }

  // MARK: Timelines

  /// One request's record, advanced through the production store.
  private struct Chain {
    let store: RuntimeToolSelectionControlActionStore
    let timeline: Int
    var record: RuntimeToolSelectionControlActionRecord
    var steps: [String]

    init(
      _ store: RuntimeToolSelectionControlActionStore, timeline: Int, request: String
    ) throws {
      self.store = store
      self.timeline = timeline
      record = try store.begin(
        intent: RuntimeToolSelectionIntent([
          "actionRequestId": .string(request),
          "tool": .string("tool:sha256:\(ToolSelectionStoreOracleContractTests.newDigest)"),
          "expectedActiveGeneration": .string("1"),
        ]),
        catalogDigest: ToolSelectionStoreOracleContractTests.catalog,
        runtimeEpoch: ToolSelectionStoreOracleContractTests.epoch,
        now: ToolSelectionStoreOracleContractTests.at(timeline, 0))
      steps = ["begin"]
    }

    mutating func advance(
      _ step: String,
      _ next: (RuntimeToolSelectionControlActionRecord) throws -> RuntimeToolSelectionControlActionRecord
    ) throws {
      let updated = try next(record)
      try store.replace(updated, expectedGeneration: record.generation)
      record = updated
      steps.append(step)
    }

    func now(_ seconds: Double) -> Date {
      ToolSelectionStoreOracleContractTests.at(timeline, seconds)
    }

    mutating func publish(blocked: Bool = false) throws {
      let hdc = blocked ? try ToolSelectionStoreOracleContractTests.blockedImpact()
        : try ToolSelectionStoreOracleContractTests.impact()
      let impact = try ToolSelectionStoreOracleContractTests.selection(hdc)
      let relations = blocked ? [] : [ToolSelectionStoreOracleContractTests.relation]
      let time = now(1)
      try advance(blocked ? "publishing(blocked)" : "publishing") {
        try $0.publishing(
          impact: impact, relations: relations,
          blocker: blocked ? "hdc.criticalJobsUnresolved" : nil, now: time)
      }
    }

    mutating func approve() throws {
      try publish()
      let request = now(2)
      try advance("requestingImpactApproval") { try $0.requestingImpactApproval(now: request) }
      let issued = now(3)
      try advance("issuingInteractiveChallenge") {
        try $0.issuingInteractiveChallenge(
          challenge: ToolSelectionStoreOracleContractTests.challenge, now: issued)
      }
      let confirmed = now(4)
      try advance("recordingInteractiveApproval") {
        try $0.recordingInteractiveApproval(
          response: ToolSelectionStoreOracleContractTests.challenge, now: confirmed)
      }
    }

    mutating func launch() throws {
      try approve()
      let prepared = now(5)
      try advance("prepared") { try $0.prepared(now: prepared) }
      for (offset, kind) in ["impactPreview", "confirmation", "intent", "actualCommand", "launchWindowEntered"]
        .enumerated()
      {
        let time = now(6 + Double(offset))
        let audit = ToolSelectionStoreOracleContractTests.auditID(timeline, offset)
        try advance("appendingLifecycleAudit(\(kind))") {
          try $0.appendingLifecycleAudit(
            kind: kind, auditID: audit,
            payload: ToolSelectionStoreOracleContractTests.payload(kind), now: time)
        }
      }
    }
  }

  private static func auditID(_ timeline: Int, _ offset: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%06d%06d", timeline, offset))!
  }

  /// Every timeline but the lifecycle's: the request identity, and how its
  /// record got to its state.
  private static func produce(
    into store: RuntimeToolSelectionControlActionStore
  ) throws -> [String: [String]] {
    var cases: [String: [String]] = [:]
    func keep(_ chain: Chain) { cases[chain.record.intent.actionRequestID] = chain.steps }

    keep(try Chain(store, timeline: 1, request: "oracle-observing"))

    var chain = try Chain(store, timeline: 2, request: "oracle-facts-unavailable")
    let factsTime = chain.now(1)
    try chain.advance("invalidated(tool.selectionFactsUnavailable)") {
      try $0.invalidated(reason: "tool.selectionFactsUnavailable", expired: false, now: factsTime)
    }
    keep(chain)

    chain = try Chain(store, timeline: 3, request: "oracle-preview-ready")
    try chain.publish()
    keep(chain)

    chain = try Chain(store, timeline: 4, request: "oracle-blocked")
    try chain.publish(blocked: true)
    keep(chain)

    chain = try Chain(store, timeline: 5, request: "oracle-blocked-expired")
    try chain.publish(blocked: true)
    let blockedExpiry = chain.now(301)
    try chain.advance("invalidated(controlAction.expired)") {
      try $0.invalidated(reason: "controlAction.expired", expired: true, now: blockedExpiry)
    }
    keep(chain)

    chain = try Chain(store, timeline: 6, request: "oracle-preview-drifted")
    try chain.publish()
    let driftTime = chain.now(2)
    try chain.advance("invalidated(tool.selectionPreviewDrifted)") {
      try $0.invalidated(reason: "tool.selectionPreviewDrifted", expired: false, now: driftTime)
    }
    keep(chain)

    chain = try Chain(store, timeline: 7, request: "oracle-awaiting")
    try chain.publish()
    let awaitTime = chain.now(2)
    try chain.advance("requestingImpactApproval") { try $0.requestingImpactApproval(now: awaitTime) }
    keep(chain)

    chain = try Chain(store, timeline: 8, request: "oracle-expired")
    try chain.publish()
    let expiringTime = chain.now(2)
    try chain.advance("requestingImpactApproval") {
      try $0.requestingImpactApproval(now: expiringTime)
    }
    let expiry = chain.now(301)
    try chain.advance("invalidated(controlAction.expired)") {
      try $0.invalidated(reason: "controlAction.expired", expired: true, now: expiry)
    }
    keep(chain)

    chain = try Chain(store, timeline: 9, request: "oracle-challenged")
    try chain.publish()
    let challengedRequest = chain.now(2)
    try chain.advance("requestingImpactApproval") {
      try $0.requestingImpactApproval(now: challengedRequest)
    }
    let challengedIssue = chain.now(3)
    try chain.advance("issuingInteractiveChallenge") {
      try $0.issuingInteractiveChallenge(challenge: Self.challenge, now: challengedIssue)
    }
    keep(chain)

    chain = try Chain(store, timeline: 10, request: "oracle-restarted")
    try chain.publish()
    let restartedRequest = chain.now(2)
    try chain.advance("requestingImpactApproval") {
      try $0.requestingImpactApproval(now: restartedRequest)
    }
    let restartedIssue = chain.now(3)
    try chain.advance("issuingInteractiveChallenge") {
      try $0.issuingInteractiveChallenge(challenge: Self.challenge, now: restartedIssue)
    }
    let restartedTime = chain.now(4)
    try chain.advance("invalidated(controlAction.runtimeRestarted)") {
      try $0.invalidated(reason: "controlAction.runtimeRestarted", expired: false, now: restartedTime)
    }
    keep(chain)

    chain = try Chain(store, timeline: 11, request: "oracle-approved")
    try chain.approve()
    keep(chain)

    // The store admits a failure only once dispatch was prepared, as the
    // selection coordinator's driver fails it.
    chain = try Chain(store, timeline: 12, request: "oracle-failed-before-launch")
    try chain.approve()
    let failPrepared = chain.now(5)
    try chain.advance("prepared") { try $0.prepared(now: failPrepared) }
    let failTime = chain.now(6)
    try chain.advance("failedBeforeLaunch(tool.lifecycleFailedBeforeLaunch)") {
      try $0.failedBeforeLaunch(reasonCode: "tool.lifecycleFailedBeforeLaunch", now: failTime)
    }
    keep(chain)

    chain = try Chain(store, timeline: 13, request: "oracle-prepared")
    try chain.approve()
    let preparedTime = chain.now(5)
    try chain.advance("prepared") { try $0.prepared(now: preparedTime) }
    keep(chain)

    chain = try Chain(store, timeline: 14, request: "oracle-launched")
    try chain.launch()
    keep(chain)

    chain = try Chain(store, timeline: 15, request: "oracle-succeeded")
    try chain.launch()
    for (offset, kind) in ["outcome", "reconciliation"].enumerated() {
      let time = chain.now(11 + Double(offset))
      let audit = Self.auditID(15, 5 + offset)
      try chain.advance("appendingLifecycleAudit(\(kind))") {
        try $0.appendingLifecycleAudit(
          kind: kind, auditID: audit, payload: Self.payload(kind), now: time)
      }
    }
    let settleTime = chain.now(13)
    try chain.advance("settled(succeeded)") {
      try $0.settled(
        result: "succeeded", activeToolRef: "tool:sha256:\(Self.newDigest)", activeGeneration: 2,
        reasonCode: nil, now: settleTime)
    }
    keep(chain)

    chain = try Chain(store, timeline: 16, request: "oracle-failed-after-launch")
    try chain.launch()
    let failedTime = chain.now(11)
    try chain.advance("settled(failed, tool.selectionPublishFailed)") {
      try $0.settled(
        result: "failed", activeToolRef: "tool:sha256:\(Self.oldDigest)", activeGeneration: 1,
        reasonCode: "tool.selectionPublishFailed", now: failedTime)
    }
    keep(chain)

    return cases
  }

  /// The production lifecycle over a fake HDC: the Supervisor's own audit
  /// rows, then the launch window, as the selection coordinator's driver
  /// leaves them before the daemon exits for recomposition.
  private static func produceLifecycle(
    into store: RuntimeToolSelectionControlActionStore, fixture: URL
  ) async throws -> [String] {
    let executableDigest = SHA256Hex.string(of: try Data(contentsOf: fixture))
    var chain = try Chain(store, timeline: 17, request: "oracle-lifecycle")
    let impact = try RuntimeToolSelectionImpact(
      hdc: impact(["serverOwnership": .string("external"), "serverGeneration": .string("7")]),
      oldTool: tool(oldDigest, signed: false),
      newTool: RuntimeToolSelectionToolFacts(
        value: tool(newDigest, signed: true).value.merging(
          ["executableSHA256": .string(executableDigest)], uniquingKeysWith: { _, new in new })),
      activeGeneration: 1)
    let published = chain.now(1)
    try chain.advance("publishing") {
      try $0.publishing(impact: impact, relations: [], blocker: nil, now: published)
    }
    let request = chain.now(2)
    try chain.advance("requestingImpactApproval") { try $0.requestingImpactApproval(now: request) }
    let issued = chain.now(3)
    try chain.advance("issuingInteractiveChallenge") {
      try $0.issuingInteractiveChallenge(challenge: challenge, now: issued)
    }
    let confirmed = chain.now(4)
    try chain.advance("recordingInteractiveApproval") {
      try $0.recordingInteractiveApproval(response: challenge, now: confirmed)
    }

    let auditDate = chain.now(5)
    let audit = RuntimeToolSelectionLifecycleAuditStore(
      store: store, actionID: chain.record.actionID, now: { auditDate },
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
          endpoint: endpoint, health: .healthy, version: .known("3.2.0-test"), generation: 7,
          ownership: .external)),
      reason: "tool-selection oracle identity")
    await supervisor.setOtherClientDetection(
      .unavailableExternalClientsMayStillExist, for: endpoint)
    guard
      case .ready(let lifecyclePreview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(lifecyclePreview.id)
    else { throw CocoaError(.featureUnsupported) }
    let executable = root.appending(path: "selected-hdc")
    try FileManager.default.copyItem(at: fixture, to: executable)
    let candidate = HDCCandidate(path: executable, source: .userConfigured, sha256: executableDigest)
    let semantic = HDCRegisteredSemanticProfile.testOnlyFake(
      executableSHA256: executableDigest,
      selectedDeviceAuthorizationSHA256: String(repeating: "c", count: 64))
    let executor = HDCProcessLifecycleExecutor(
      toolchain: candidate, semanticProfile: semantic,
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": root.appending(path: "selected.log").path
      ],
      durableAuthorization: router, supervisor: supervisor,
      postDispatchProbe: { _ in .generation(8) })
    let step = try HDCServerLifecycleStep.coreWorkflowStep(confirmation: confirmation)
    let dispatch = await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: step, using: executor)
    guard dispatch == .completed(.succeeded(resultingGeneration: 8)), audit.launchWindowWasEntered()
    else { throw CocoaError(.featureUnsupported) }
    return chain.steps + ["markSelectionPrepared", "lifecycle Supervisor and executor"]
  }

  // MARK: Oracle

  /// Random identities and the preview digest over them, set aside.
  private static func withoutIdentities(_ value: JSONValue, key: String? = nil) -> JSONValue {
    switch value {
    case .object(let fields):
      return .object(
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, withoutIdentities($0.value, key: $0.key)) }))
    case .array(let items):
      return .array(items.map { withoutIdentities($0) })
    case .string(let text):
      if key == "previewDigest" { return .string("<previewDigest>") }
      if text.utf8.count >= 36, let uuid = UUID(uuidString: String(text.suffix(36))),
        uuid.uuidString.lowercased() == String(text.suffix(36))
      {
        return .string(String(text.dropLast(36)) + "<uuid>")
      }
      return value
    default:
      return value
    }
  }

  private static func encoded(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  /// A private copy of the checked-in records: the store opens only an
  /// owner-private directory of owner-private files.
  private static func privateCopy(of records: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for name in try FileManager.default.contentsOfDirectory(atPath: records.path) {
      let target = destination.appending(path: name)
      try FileManager.default.copyItem(at: records.appending(path: name), to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
  }

  func testTheProductionStoreHoldsEveryToolSelectionStateAsRecorded() async throws {
    try FileManager.default.createDirectory(
      at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let played = Self.root.appending(path: "played/records", directoryHint: .isDirectory)
    let store = try RuntimeToolSelectionControlActionStore(directory: played)
    var cases = try Self.produce(into: store)

    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let fixture = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appending(path: "ArkDeckFakeHDCFixture")
      cases["oracle-lifecycle"] = try await Self.produceLifecycle(into: store, fixture: fixture)
      try record(store: store, records: played, cases: cases, output: output)
      return
    }

    // 0. The checked-in oracle is exactly the recording: every file, and no
    // other, has the SHA-256 its provenance pinned.
    guard
      case .object(let provenance) = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "provenance.json"))),
      case .object(let pinned)? = provenance["files"]
    else { return XCTFail("provenance.json pins no files") }
    let checkedIn = try FileManager.default.subpathsOfDirectory(atPath: Self.oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: Self.oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue && path != "provenance.json"
      }
    XCTAssertEqual(Set(checkedIn), Set(pinned.keys))
    for (path, digest) in pinned {
      XCTAssertEqual(
        digest,
        .string(SHA256Hex.string(of: try Data(contentsOf: Self.oracle.appending(path: path)))),
        path)
    }

    // 1. The production store reads the checked-in records back.
    let copy = Self.root.appending(path: "checked-in/records", directoryHint: .isDirectory)
    try Self.privateCopy(of: Self.oracle.appending(path: "records"), to: copy)
    let reader = try RuntimeToolSelectionControlActionStore(directory: copy)
    let records = try reader.list()
    guard
      case .object(let recordedCases) = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "cases.json")))
    else { return XCTFail("cases.json is not an object") }
    XCTAssertEqual(Set(records.map(\.intent.actionRequestID)), Set(recordedCases.keys))
    for record in records {
      let name = "action-" + SHA256Hex.string(of: Data(record.intent.actionRequestID.utf8)) + ".json"
      let bytes = try Data(contentsOf: Self.oracle.appending(path: "records/\(name)"))
      XCTAssertEqual(
        try PortableCanonicalJSON.canonicalBytes(.object(record.value)), bytes,
        "\(record.intent.actionRequestID) is not its own canonical bytes")
      guard case .object(let fields)? = recordedCases[record.intent.actionRequestID] else {
        XCTFail("\(record.intent.actionRequestID) has no recorded case")
        continue
      }
      XCTAssertEqual(fields["state"], .string(record.state))
      XCTAssertEqual(fields["generation"], .string(String(record.generation)))
    }
    let projections = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "projections.json")))
    XCTAssertEqual(projections, .array(records.map(\.projection)))

    // 2. The same timelines leave the same records, identities aside.
    let recorded = Dictionary(uniqueKeysWithValues: records.map { ($0.intent.actionRequestID, $0) })
    let replayed = try store.list()
    XCTAssertEqual(
      Set(replayed.map(\.intent.actionRequestID)),
      Set(recordedCases.keys).subtracting(["oracle-lifecycle"]))
    for record in replayed {
      let request = record.intent.actionRequestID
      guard let original = recorded[request],
        case .object(let fields)? = recordedCases[request]
      else {
        XCTFail("\(request) is not in the oracle")
        continue
      }
      XCTAssertEqual(
        Self.withoutIdentities(.object(record.value)), Self.withoutIdentities(.object(original.value)),
        request)
      XCTAssertEqual(fields["steps"], .array((cases[request] ?? []).map(JSONValue.string)), request)
    }
  }

  private func record(
    store: RuntimeToolSelectionControlActionStore, records: URL, cases: [String: [String]],
    output: String
  ) throws {
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    guard destination.path.hasPrefix("/private/tmp/"),
      !FileManager.default.fileExists(atPath: destination.path)
    else { throw CocoaError(.fileWriteFileExists) }
    let all = try store.list()
    var files: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: records.path) {
      files["records/\(name)"] = try Data(contentsOf: records.appending(path: name))
    }
    var recordedCases: [String: JSONValue] = [:]
    for record in all {
      let request = record.intent.actionRequestID
      recordedCases[request] = .object([
        "file": .string(
          "records/action-" + SHA256Hex.string(of: Data(request.utf8)) + ".json"),
        "state": .string(record.state), "generation": .string(String(record.generation)),
        "steps": .array((cases[request] ?? []).map(JSONValue.string)),
      ])
    }
    files["cases.json"] = try Self.encoded(.object(recordedCases))
    files["projections.json"] = try Self.encoded(.array(all.map(\.projection)))
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] = try Self.encoded(
      .object([
        "producer": .string(
          "ToolSelectionStoreOracleContractTests.testTheProductionStoreHoldsEveryToolSelectionStateAsRecorded"
        ),
        "store": .object([
          "type": .string("RuntimeToolSelectionControlActionStore"),
          "productionDirectory": .string("<state>/tool-selection-control-actions/records"),
          "recordSchemaVersion": .string("arkdeck.runtime-tool-selection-control-action/1"),
          "lock": .string(".lock"),
          "encoding": .string(PortableCanonicalJSON.version),
          "maximumRecords": .integer(4096), "maximumRecordBytes": .integer(1_048_576),
          "maximumStoreBytes": .integer(67_108_864),
        ]),
        "clock": .string(HDCControlActionRecord.timestamp(Self.start)),
        "runtimeEpoch": .string(Self.epoch), "catalogDigest": .string(Self.catalog),
        "syntheticAuditPayloads": .bool(true),
        "productionLifecycleRecord": .string("oracle-lifecycle"),
        "files": .object(digests),
      ]))
    for (path, data) in files {
      let url = destination.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: url)
    }
  }
}
