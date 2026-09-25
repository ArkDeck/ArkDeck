// Shared Swift oracle for the Session storage requests made while a storage
// lock is held (TASK-XPA-012): `runtime.storage.status`, `.policy` and `.root`,
// `session.list` and `session.pin`, and `session.export.preview`, each sent
// through the production control plane while this test holds the Session
// storage owner's `.session-storage.lock`, as a Session publication or another
// request holds it, and a status read sent while the test holds the selected
// root's retention catalog lock, `.arkdeck-retention-catalog.lock`. Swift's
// `RuntimeSessionStorageStore` runs each under `withLockedDocument` and
// `SessionRetentionCatalog` under its catalog lock, both a blocking
// `flock(LOCK_EX)`: no request is answered while either lock is held, and each
// is answered, as if it had never been held, once it is released. A final
// status read, with both free, answers the state the requests left.
//
// A random or host answer (the list's snapshot revision, the export preview's
// identity, digest, devices, inodes and volume) is recorded as a label, which
// the Rust replay applies to its own answer.
//
// The Rust owner replays `frames.jsonl` with the same locks held, over the same
// fixture Session (`manifest.json`, recorded beside the frames).
//
// Host-local only: a fabricated root, no device, no daemon process. Record with
// `ARKDECK_RUST_STORAGE_LOCK_WAIT_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class StorageLockWaitOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/storage-lock-wait-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_STORAGE_LOCK_WAIT_RECORD"
  /// The recording's fixed root: the answers name the Session roots by path.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-storage-lock-wait-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-26T00:00:00Z"
  /// The storage owner's clock: 2026-09-26T00:00:00Z.
  private static let now = Date(timeIntervalSince1970: 1_790_380_800)
  /// The Rust daemon's Artifact quota, so that the Artifact domain of each
  /// answer is the Rust daemon's too.
  private static let artifactQuota = 8 * 1024 * 1024 * 1024
  /// The one retained Session, completed before the clock.
  private static let session = "session-fixture"
  /// The running test's root, emptied first and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  /// The production handler over the Session storage owner and an empty
  /// Artifact store, with a Job engine that has no provider: nothing here
  /// plans or runs a Job.
  private func handler(root: URL) throws -> RuntimeControlPlaneHandler {
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: Self.artifactQuota),
      nowUTC: { Self.timestamp })
    let sessions = try RuntimeSessionStorageStore(
      ownerRoot: root.appending(path: "session-state", directoryHint: .isDirectory),
      defaultSessionsRoot: root.appending(path: "sessions", directoryHint: .isDirectory),
      clock: { Self.now })
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: RefusingStorageLockWaitOracleDispatcher(),
      capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { Self.timestamp })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { Self.timestamp }, artifactStore: artifacts,
      runtimeSessionStorage: sessions)
  }

  /// Every exchange, as the control-frame recorder spells it.
  private final class Frames: @unchecked Sendable {
    var lines: [Data] = []
  }

  /// Set once the handler has answered.
  private final class Answered: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    func set() { lock.withLock { answered = true } }
    var value: Bool { lock.withLock { answered } }
  }

  /// The answer with a random or host value replaced by its label.
  private static func labelled(_ response: AgentWireProtocol.Response)
    -> AgentWireProtocol.Response
  {
    guard case .object(var result)? = response.result else { return response }
    func label(_ object: inout [String: JSONValue], _ key: String) {
      if object[key] != nil { object[key] = .string("<\(key)>") }
    }
    label(&result, "snapshotRevision")
    label(&result, "previewId")
    label(&result, "previewDigest")
    for (name, keys) in [
      ("destination", ["parentDevice", "parentInode", "volumeIdentity"]),
      ("source", ["rootDevice", "rootInode", "sessionDevice", "sessionInode", "volumeIdentity"]),
    ] {
      guard case .object(var nested)? = result[name] else { continue }
      for key in keys { label(&nested, key) }
      result[name] = .object(nested)
    }
    return .init(id: response.id, ok: response.ok, result: .object(result), error: response.error)
  }

  private func request(
    _ method: String, _ params: [String: JSONValue]
  ) -> AgentWireProtocol.Request {
    AgentWireProtocol.Request(id: UUID().uuidString, method: method, params: params)
  }

  @discardableResult
  private func send(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue] = [:]
  ) async throws -> AgentWireProtocol.Response {
    let request = request(method, params)
    let response = await handler.handleFrame(try JSONEncoder().encode(request))
    frames.lines.append(
      try ControlFrameRecord(request: request, response: Self.labelled(response))
        .encodedLine())
    return response
  }

  /// One request sent while this test holds `lock`: it must still be waiting
  /// once the handler has had time to refuse, and it is answered once the
  /// lock is released.
  @discardableResult
  private func sendWhileLocked(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, lock path: URL, _ method: String,
    _ params: [String: JSONValue] = [:]
  ) async throws -> AgentWireProtocol.Response {
    let lock = Darwin.open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    XCTAssertGreaterThanOrEqual(lock, 0, "the lock opens")
    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0, "nothing else holds the lock")
    let request = request(method, params)
    let encoded = try JSONEncoder().encode(request)
    let answered = Answered()
    let pending = Task {
      let response = await handler.handleFrame(encoded)
      answered.set()
      return response
    }
    // A refusal is immediate. The bound only lets one arrive; the answer never
    // depends on it.
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(answered.value, "\(method) answered while \(path.lastPathComponent) was held")
    XCTAssertEqual(flock(lock, LOCK_UN), 0)
    Darwin.close(lock)
    let response = await pending.value
    XCTAssertTrue(answered.value)
    XCTAssertTrue(response.ok, "\(method): \(String(describing: response.error))")
    frames.lines.append(
      try ControlFrameRecord(request: request, response: Self.labelled(response))
        .encodedLine())
    return response
  }

  private func ownerDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(chmod(url.path, 0o700), 0)
  }

  private func ownerFile(_ data: Data, at url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    XCTAssertEqual(chmod(url.path, 0o600), 0)
  }

  func testStorageRequestsWaitForHeldStorageLocks() async throws {
    let root = Self.oracleRoot
    self.root = root
    try? FileManager.default.removeItem(at: root)
    for name in ["", "session-state", "sessions", "custom", "artifacts"] {
      try ownerDirectory(root.appending(path: name, directoryHint: .isDirectory))
    }
    // The one retained Session, in the root the requests select.
    let manifest = try SessionStorageFixtures.manifest(
      sessionID: Self.session, jobID: "job-fixture", timestamp: "2026-09-01T00:00:00Z")
    let session = root.appending(path: "custom/2026/09/\(Self.session)", directoryHint: .isDirectory)
    try ownerDirectory(session)
    try ownerFile(
      try CanonicalJSONEncoders.canonical().encode(
        JSONValue.object([
          "schemaVersion": .string("1.0.0"), "sessionId": .string(Self.session),
          "jobId": .string("job-fixture"),
        ])),
      at: session.appending(path: ".session-identity.json"))
    try ownerFile(manifest, at: session.appending(path: "manifest.json"))
    try ownerFile(Data(repeating: 0x53, count: 48), at: session.appending(path: "payload.bin"))

    let storage = root.appending(path: "session-state/.session-storage.lock")
    let catalog = root.appending(path: "custom/.arkdeck-retention-catalog.lock")
    let daemon = try handler(root: root)
    let frames = Frames()

    try await sendWhileLocked(daemon, frames, lock: storage, "runtime.storage.status")
    try await sendWhileLocked(
      daemon, frames, lock: storage, "runtime.storage.policy",
      [
        "expectedGeneration": .string("1"), "totalQuotaBytes": .string("500000"),
        "safetyMarginBytes": .string("1000"), "retentionDays": .string("30"),
      ])
    try await sendWhileLocked(
      daemon, frames, lock: storage, "runtime.storage.root",
      [
        "expectedGeneration": .string("2"),
        "rootPath": .string(root.appending(path: "custom").path),
      ])
    let listed = try await sendWhileLocked(
      daemon, frames, lock: storage, "session.list", ["pageSize": .integer(10)])
    guard case .object(let page)? = listed.result, case .array(let items)? = page["items"],
      case .object(let item)? = items.first, case .string(let generation)? = item["generation"]
    else { return XCTFail("the list names the retained Session: \(String(describing: listed.result))") }
    try await sendWhileLocked(
      daemon, frames, lock: storage, "session.pin",
      ["sessionId": .string(Self.session), "expectedGeneration": .string(generation)])
    try await sendWhileLocked(daemon, frames, lock: catalog, "runtime.storage.status")
    try await sendWhileLocked(
      daemon, frames, lock: storage, "session.export.preview",
      [
        "sessionId": .string(Self.session),
        "destinationPath": .string(root.appending(path: "export").path),
        "allowSensitive": .bool(false),
      ])
    // The state the requests left, read with both locks free.
    try await send(daemon, frames, "runtime.storage.status")

    let answers = frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try answers.write(to: directory.appending(path: "frames.jsonl"))
      try manifest.write(to: directory.appending(path: "manifest.json"))
      return
    }

    // The checked-in oracle is what this owner answers, frame by frame, over
    // the same fixture Session.
    XCTAssertEqual(try Data(contentsOf: Self.oracle.appending(path: "manifest.json")), manifest)
    let expected = try Data(contentsOf: Self.oracle.appending(path: "frames.jsonl"))
      .split(separator: UInt8(ascii: "\n"))
    let actual = answers.split(separator: UInt8(ascii: "\n"))
    XCTAssertEqual(expected.count, actual.count, "frame count")
    for (index, (lhs, rhs)) in zip(expected, actual).enumerated() {
      XCTAssertEqual(
        String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self),
        "frame \(index)")
    }
  }
}

/// No Job runs here; a dispatch would be a defect of the oracle.
private struct RefusingStorageLockWaitOracleDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID: String) -> String? { "the oracle dispatches nothing" }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed("the oracle dispatches nothing")
  }
}
