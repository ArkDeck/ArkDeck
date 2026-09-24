import ArkDeckClientKit
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

struct FixedDiagnosticAuditClock: DiagnosticAuditClock {
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

  /// A request holds App values and App log snapshots only; the writer has no
  /// Session, journal or Artifact input to fill.
  static func bundleRequest(
    destination: URL,
    logs: [RedactedDiagnosticLogFile]
  ) throws -> LocalDiagnosticBundleRequest {
    LocalDiagnosticBundleRequest(
      destination: destination,
      metadata: try DiagnosticBundleMetadata(
        appName: "ArkDeck", appVersion: "1.0.0-test", buildVersion: "M1-009",
        platform: "macOS-test", architecture: "arm64"),
      logs: logs)
  }
}
