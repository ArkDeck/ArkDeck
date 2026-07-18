import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import CryptoKit
import Foundation

final class CapturedUnifiedDiagnosticLogger: UnifiedDiagnosticLogging, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RedactedDiagnosticRecord] = []

  func log(_ record: RedactedDiagnosticRecord) {
    lock.lock()
    storage.append(record)
    lock.unlock()
  }

  var records: [RedactedDiagnosticRecord] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

struct FixedDiagnosticAuditClock: AuditClock {
  let nowUTC = Date(timeIntervalSince1970: 1_752_739_200)
}

struct DecodedDiagnosticRecord: Decodable, Equatable {
  let timestamp: String
  let level: SystemLogLevel
  let category: SystemLogCategory
  let eventName: String
  let correlationID: String
  let fields: [String: String]

  private enum CodingKeys: String, CodingKey {
    case timestamp
    case level
    case category
    case eventName
    case correlationID = "correlationId"
    case fields
  }

  init(_ record: RedactedDiagnosticRecord) {
    timestamp = record.timestamp
    level = record.level
    category = record.category
    eventName = record.eventName
    correlationID = record.correlationID
    fields = record.fields
  }
}

enum DiagnosticsFixtures {
  static let deviceIdentifier = "fixture-device-serial-009"
  static let userPath = "/Users/fixture/Secret Workspace/capture.trace"
  static let businessString = "customer-visible secret payload"

  struct SessionExportFixture {
    let materialized: MaterializedSessionExport
    let journalReplay: JournalReplay
    let rawBytes: Data
  }

  static func temporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return directory
  }

  static func decodedRecords(_ snapshot: StructuredDiagnosticLogSnapshot) throws
    -> [DecodedDiagnosticRecord]
  {
    try snapshot.files.flatMap { file in
      try file.data.split(separator: 0x0A).map {
        try JSONDecoder().decode(DecodedDiagnosticRecord.self, from: Data($0))
      }
    }
  }

  static func redactedLogFiles(_ snapshot: StructuredDiagnosticLogSnapshot) throws
    -> [RedactedDiagnosticLogFile]
  {
    try snapshot.files.map { try RedactedDiagnosticLogFile(name: $0.name, data: $0.data) }
  }

  static func makeSessionExport(base: URL) async throws -> SessionExportFixture {
    let sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    let store = try SessionStore(sessionsRoot: sessionsRoot)
    let identity = try SystemVolumeIdentityResolver().resolve(sessionsRoot)
    let createCoordinator = HostStorageCoordinator()
    let createRequest = try claimRequest(
      id: "diagnostics-create", jobID: "job-diagnostics", volume: identity, writer: .light)
    guard
      case .admitted(let createClaim) = await createCoordinator.admit(
        createRequest, snapshot: storageSnapshot(identity))
    else { throw LocalDiagnosticBundleError.invalidInput("fixture Session admission failed") }
    let layout = try store.createSession(
      sessionID: "session-diagnostics", jobID: "job-diagnostics",
      createdAt: Date(timeIntervalSince1970: 1_752_739_200), claim: createClaim)

    let rawBytes = Data("device raw must stay outside bundle \(deviceIdentifier)".utf8)
    let raw = try ArtifactRecord(
      id: "raw-diagnostics", role: .raw, origin: "diagnostics fixture",
      relativePath: "artifacts/raw/device.trace", size: UInt64(rawBytes.count),
      sha256: sha256(rawBytes))
    try rawBytes.write(to: layout.root.appending(path: raw.relativePath))
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: layout.sessionID, jobID: layout.jobID, artifacts: [raw]))
    _ = try AtomicSessionManifestPublisher(layout: layout).publish(manifest)

    let exportCoordinator = HostStorageCoordinator()
    let exportRequest = try claimRequest(
      id: "diagnostics-export", jobID: layout.jobID, volume: identity, writer: .heavy)
    guard
      case .admitted(let exportClaim) = await exportCoordinator.admit(
        exportRequest, snapshot: storageSnapshot(identity))
    else { throw LocalDiagnosticBundleError.invalidInput("fixture export admission failed") }
    let redactedRoot = base.appending(path: "redacted-session-export")
    let materialized = try SessionDiagnosticExporter().export(
      layout: layout, artifacts: [raw], claim: exportClaim, to: redactedRoot)

    let journalURL = base.appending(path: "journal-summary-source.jsonl")
    do {
      let journal = try FileDurableJournal(url: journalURL)
      try journal.appendAndSynchronize(
        JournalEvent.jobCreated(
          eventID: "diagnostics-created", sequence: 0,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated",
          executionAuthority: "standardAgent", coreBaseline: "CORE-2.0.0"))
      try journal.appendAndSynchronize(
        JournalEvent(
          eventID: "diagnostics-warning", sequence: 1,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, kind: .warning,
          payload: [
            "code": .string("fixture.warning"),
            "message": .string("device-1 journal payload must not be copied"),
            "details": .object([:]),
          ]))
    }
    let journalReplay = try DurableJournalRecovery.inspect(url: journalURL)
    return SessionExportFixture(
      materialized: materialized, journalReplay: journalReplay, rawBytes: rawBytes)
  }

  static func bundleRequest(
    destination: URL,
    logs: [RedactedDiagnosticLogFile],
    session: SessionExportFixture
  ) throws -> LocalDiagnosticBundleRequest {
    LocalDiagnosticBundleRequest(
      destination: destination,
      metadata: try DiagnosticBundleMetadata(
        appName: "ArkDeck", appVersion: "1.0.0-test", buildVersion: "M1-009",
        platform: "macOS-test", architecture: "arm64"),
      logs: logs,
      recentSessions: [
        RecentSessionDiagnosticSource(
          export: session.materialized, journalReplay: session.journalReplay)
      ])
  }

  private static func claimRequest(
    id: String,
    jobID: String,
    volume: VolumeIdentity,
    writer: StorageWriterClass
  ) throws -> StorageClaimRequest {
    try StorageClaimRequest(
      claimID: id, jobID: jobID, volumeIdentity: volume,
      budget: StorageBudget(
        metadataHeadroomBytes: 1_024, finalizationHeadroomBytes: 1_024,
        remainingGrowthBytes: 16 * 1_024 * 1_024, writerClass: writer))
  }

  private static func storageSnapshot(_ identity: VolumeIdentity) -> HostStorageSnapshot {
    HostStorageSnapshot(
      volumeIdentity: identity, totalBytes: UInt64.max, availableBytes: UInt64.max,
      isReadOnly: false)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
