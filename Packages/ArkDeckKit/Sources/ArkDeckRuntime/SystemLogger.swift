import Darwin
import Foundation
import OSLog

public enum SystemLogCategory: String, Codable, CaseIterable, Sendable {
  case app
  case hdcServer
  case workflow
  case storage
  case ui
}

public enum SystemLogLevel: String, Codable, CaseIterable, Sendable {
  case debug
  case info
  case notice
  case warning
  case error
}

public enum SystemLogEventName: String, Codable, CaseIterable, Sendable {
  case rotationSample = "rotation.sample"
  case privacyContract = "privacy.contract"
  case jobFailed = "job.failed"
  case platformContract = "platform.contract"
}

public enum SystemLogFieldKey: String, Codable, CaseIterable, Sendable {
  case device
  case path
  case business
  case publicCode
  case code

  fileprivate var requiredPrivacy: DiagnosticFieldPrivacy {
    switch self {
    case .publicCode, .code: .publicValue
    case .device: .deviceIdentifier
    case .path: .userPath
    case .business: .businessString
    }
  }

  fileprivate func validatePublicValue(_ value: String) -> Bool {
    switch self {
    case .publicCode:
      value == DiagnosticPublicCode.diagnosticsTest.rawValue
        || value == DiagnosticPublicCode.rotationSample.rawValue
    case .code:
      value == DiagnosticPublicCode.fixtureFailure.rawValue
    case .device, .path, .business:
      false
    }
  }
}

/// A writer-generated identifier. Callers can retain and reuse the value to correlate events but
/// cannot inject arbitrary source strings into either diagnostic sink.
public struct DiagnosticCorrelationID: Equatable, Hashable, Sendable {
  public let rawValue: String

  public init() {
    rawValue = "corr-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

public enum DiagnosticFieldPrivacy: String, CaseIterable, Sendable {
  case publicValue
  case deviceIdentifier
  case userPath
  case businessString
}

public enum DiagnosticPublicCode: String, Codable, CaseIterable, Sendable {
  case diagnosticsTest = "diagnostics.test"
  case fixtureFailure = "fixture.failure"
  case rotationSample = "diagnostics.rotation"
}

public enum DiagnosticInputField: Equatable, Sendable {
  case publicCode(DiagnosticPublicCode)
  case deviceIdentifier(String)
  case userPath(String)
  case businessString(String)

  fileprivate var value: String {
    switch self {
    case .publicCode(let code): code.rawValue
    case .deviceIdentifier(let value), .userPath(let value), .businessString(let value): value
    }
  }

  fileprivate var privacy: DiagnosticFieldPrivacy {
    switch self {
    case .publicCode: .publicValue
    case .deviceIdentifier: .deviceIdentifier
    case .userPath: .userPath
    case .businessString: .businessString
    }
  }
}

public struct DiagnosticRedactionPolicy: Sendable {
  public init() {}

  public func redact(_ field: DiagnosticInputField) -> String {
    switch field {
    case .publicCode(let code):
      code.rawValue
    case .deviceIdentifier:
      "[REDACTED-DEVICE-ID]"
    case .userPath:
      "[REDACTED-USER-PATH]"
    case .businessString:
      "[REDACTED-BUSINESS-STRING]"
    }
  }
}

public enum SystemLoggerError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidFieldPrivacy
  case invalidPublicFieldValue
  case fieldLimitExceeded
  case recordLimitExceeded
  case unsafeLogDirectory
  case activeWriterExists
  case invalidSegment
  case quotaExceeded
  case writerPoisoned
  case fileOperationFailed(errno: Int32)
}

public struct RedactedDiagnosticRecord: Encodable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"
  public static let maximumFieldCount = 64
  public static let maximumFieldValueBytes = 4 * 1_024

  public let timestamp: String
  public let level: SystemLogLevel
  public let category: SystemLogCategory
  public let eventName: String
  public let correlationID: String
  public let fields: [String: String]

  fileprivate init(
    timestamp: String,
    level: SystemLogLevel,
    category: SystemLogCategory,
    eventName: String,
    correlationID: String,
    fields: [String: String]
  ) {
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.eventName = eventName
    self.correlationID = correlationID
    self.fields = fields
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case timestamp
    case level
    case category
    case eventName
    case correlationID = "correlationId"
    case fields
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encode(level, forKey: .level)
    try container.encode(category, forKey: .category)
    try container.encode(eventName, forKey: .eventName)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(fields, forKey: .fields)
  }
}

public protocol UnifiedDiagnosticLogging: Sendable {
  func log(_ record: RedactedDiagnosticRecord)
}

/// `PORT-LOGGING-001` system-log channel. Values have already been redacted before this sink is
/// called, so Unified Logging receives no raw sensitive field values.
public struct UnifiedSystemDiagnosticLogger: UnifiedDiagnosticLogging, Sendable {
  private let app: Logger
  private let hdcServer: Logger
  private let workflow: Logger
  private let storage: Logger
  private let ui: Logger

  public init(subsystem: String = "com.arkdeck.ArkDeck") {
    app = Logger(subsystem: subsystem, category: SystemLogCategory.app.rawValue)
    hdcServer = Logger(subsystem: subsystem, category: SystemLogCategory.hdcServer.rawValue)
    workflow = Logger(subsystem: subsystem, category: SystemLogCategory.workflow.rawValue)
    storage = Logger(subsystem: subsystem, category: SystemLogCategory.storage.rawValue)
    ui = Logger(subsystem: subsystem, category: SystemLogCategory.ui.rawValue)
  }

  public func log(_ record: RedactedDiagnosticRecord) {
    let logger = logger(for: record.category)
    let fields = record.fields.keys.sorted().map { "\($0)=\(record.fields[$0]!)" }
      .joined(separator: " ")
    logger.log(
      level: osLogType(record.level),
      "\(record.eventName, privacy: .public) correlation=\(record.correlationID, privacy: .public) \(fields, privacy: .public)"
    )
  }

  private func logger(for category: SystemLogCategory) -> Logger {
    switch category {
    case .app: app
    case .hdcServer: hdcServer
    case .workflow: workflow
    case .storage: storage
    case .ui: ui
    }
  }

  private func osLogType(_ level: SystemLogLevel) -> OSLogType {
    switch level {
    case .debug: .debug
    case .info: .info
    case .notice: .default
    case .warning: .default
    case .error: .error
    }
  }
}

public struct StructuredDiagnosticLogConfiguration: Equatable, Sendable {
  public let quotaBytes: Int
  public let segmentBytes: Int
  public let maximumRecordBytes: Int

  public init(
    quotaBytes: Int = 16 * 1_024 * 1_024,
    segmentBytes: Int = 1 * 1_024 * 1_024,
    maximumRecordBytes: Int = 72 * 1_024
  ) throws {
    guard maximumRecordBytes > 1, segmentBytes >= maximumRecordBytes,
      quotaBytes >= segmentBytes
    else { throw SystemLoggerError.invalidConfiguration }
    self.quotaBytes = quotaBytes
    self.segmentBytes = segmentBytes
    self.maximumRecordBytes = maximumRecordBytes
  }
}

public struct StructuredDiagnosticSnapshotFile: Equatable, Sendable {
  public let name: String
  public let data: Data

  public init(name: String, data: Data) {
    self.name = name
    self.data = data
  }
}

public struct StructuredDiagnosticLogSnapshot: Equatable, Sendable {
  public let files: [StructuredDiagnosticSnapshotFile]
  public let totalBytes: Int

  public init(files: [StructuredDiagnosticSnapshotFile], totalBytes: Int) {
    self.files = files
    self.totalBytes = totalBytes
  }
}

public final class StructuredDiagnosticLogStore: @unchecked Sendable {
  private struct Segment {
    let sequence: UInt64
    let name: String
    var size: Int
  }

  public let directory: URL
  public let configuration: StructuredDiagnosticLogConfiguration

  private let lock = NSLock()
  private let directoryDescriptor: Int32
  private let writerLockDescriptor: Int32
  private var currentDescriptor: Int32
  private var segments: [Segment]
  private var poisoned = false

  public init(
    directory: URL,
    configuration: StructuredDiagnosticLogConfiguration? = nil
  ) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/") else {
      throw SystemLoggerError.unsafeLogDirectory
    }
    self.directory = directory.standardizedFileURL
    let resolvedConfiguration = try configuration ?? StructuredDiagnosticLogConfiguration()
    self.configuration = resolvedConfiguration
    try Self.createSecureDirectory(self.directory)

    let openedDirectory = Darwin.open(
      self.directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard openedDirectory >= 0 else {
      throw SystemLoggerError.fileOperationFailed(errno: errno)
    }
    var openedWriterLock: Int32 = -1
    var openedCurrent: Int32 = -1
    var directoryLocked = false
    do {
      try Self.validateOwnedDirectory(
        descriptor: openedDirectory, url: self.directory)
      guard flock(openedDirectory, LOCK_EX | LOCK_NB) == 0 else {
        throw SystemLoggerError.activeWriterExists
      }
      directoryLocked = true
      openedWriterLock = Darwin.openat(
        openedDirectory, ".writer.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard openedWriterLock >= 0 else {
        throw SystemLoggerError.fileOperationFailed(errno: errno)
      }
      guard flock(openedWriterLock, LOCK_EX | LOCK_NB) == 0 else {
        throw SystemLoggerError.activeWriterExists
      }
      try Self.validateWriterLock(
        descriptor: openedWriterLock, directoryDescriptor: openedDirectory)

      var loaded = try Self.scanSegments(directoryDescriptor: openedDirectory)
      guard loaded.allSatisfy({ $0.size <= resolvedConfiguration.segmentBytes }),
        loaded.reduce(0, { $0 + $1.size }) <= resolvedConfiguration.quotaBytes
      else { throw SystemLoggerError.quotaExceeded }
      if loaded.isEmpty {
        let segment = Segment(sequence: 0, name: Self.segmentName(0), size: 0)
        openedCurrent = try Self.createSegment(
          segment, directoryDescriptor: openedDirectory, directoryURL: self.directory)
        loaded = [segment]
      } else {
        let index = loaded.count - 1
        openedCurrent = try Self.openSegment(
          loaded[index], directoryDescriptor: openedDirectory, directoryURL: self.directory)
        loaded[index].size = try Self.repairTornTail(
          descriptor: openedCurrent, segment: loaded[index], directoryDescriptor: openedDirectory,
          directoryURL: self.directory)
      }
      directoryDescriptor = openedDirectory
      writerLockDescriptor = openedWriterLock
      currentDescriptor = openedCurrent
      segments = loaded
    } catch {
      if openedCurrent >= 0 { Darwin.close(openedCurrent) }
      if openedWriterLock >= 0 {
        _ = flock(openedWriterLock, LOCK_UN)
        Darwin.close(openedWriterLock)
      }
      if directoryLocked { _ = flock(openedDirectory, LOCK_UN) }
      Darwin.close(openedDirectory)
      throw error
    }
  }

  deinit {
    Darwin.close(currentDescriptor)
    _ = flock(writerLockDescriptor, LOCK_UN)
    Darwin.close(writerLockDescriptor)
    _ = flock(directoryDescriptor, LOCK_UN)
    Darwin.close(directoryDescriptor)
  }

  fileprivate func appendAndSynchronize(_ record: RedactedDiagnosticRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = try encoder.encode(record)
    bytes.append(0x0A)
    guard bytes.count <= configuration.maximumRecordBytes else {
      throw SystemLoggerError.recordLimitExceeded
    }

    lock.lock()
    defer { lock.unlock() }
    guard !poisoned else { throw SystemLoggerError.writerPoisoned }
    do {
      try validateBindings()
      if segments[segments.count - 1].size > 0,
        segments[segments.count - 1].size + bytes.count > configuration.segmentBytes
      {
        try rotate()
      }
      try pruneForAppend(byteCount: bytes.count)
      try validateBindings()
      try Self.writeAll(bytes, descriptor: currentDescriptor)
      try Self.fullSync(currentDescriptor)
      segments[segments.count - 1].size += bytes.count
    } catch {
      poisoned = true
      throw error
    }
  }

  public func snapshot() throws -> StructuredDiagnosticLogSnapshot {
    lock.lock()
    defer { lock.unlock() }
    guard !poisoned else { throw SystemLoggerError.writerPoisoned }
    try validateBindings()
    try Self.fullSync(currentDescriptor)
    var files: [StructuredDiagnosticSnapshotFile] = []
    var total = 0
    for segment in segments {
      let descriptor = try Self.openSegment(
        segment, directoryDescriptor: directoryDescriptor, directoryURL: directory)
      defer { Darwin.close(descriptor) }
      let data = try Self.readExactly(descriptor: descriptor, byteCount: segment.size)
      files.append(StructuredDiagnosticSnapshotFile(name: segment.name, data: data))
      total += data.count
    }
    guard total <= configuration.quotaBytes else { throw SystemLoggerError.quotaExceeded }
    return StructuredDiagnosticLogSnapshot(files: files, totalBytes: total)
  }

  public var retainedBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return segments.reduce(0) { $0 + $1.size }
  }

  public var segmentCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return segments.count
  }

  private func rotate() throws {
    try Self.fullSync(currentDescriptor)
    Darwin.close(currentDescriptor)
    guard let last = segments.last, last.sequence < UInt64.max else {
      throw SystemLoggerError.invalidSegment
    }
    let next = Segment(
      sequence: last.sequence + 1, name: Self.segmentName(last.sequence + 1), size: 0)
    do {
      currentDescriptor = try Self.createSegment(
        next, directoryDescriptor: directoryDescriptor, directoryURL: directory)
      segments.append(next)
    } catch {
      currentDescriptor = -1
      throw error
    }
  }

  private func pruneForAppend(byteCount: Int) throws {
    while totalBytes + byteCount > configuration.quotaBytes, segments.count > 1 {
      let oldest = segments.removeFirst()
      guard Darwin.unlinkat(directoryDescriptor, oldest.name, 0) == 0 else {
        segments.insert(oldest, at: 0)
        throw SystemLoggerError.fileOperationFailed(errno: errno)
      }
      try Self.fullSync(directoryDescriptor)
    }
    guard totalBytes + byteCount <= configuration.quotaBytes else {
      throw SystemLoggerError.quotaExceeded
    }
  }

  private var totalBytes: Int { segments.reduce(0) { $0 + $1.size } }

  private func validateBindings() throws {
    try Self.validateOwnedDirectory(descriptor: directoryDescriptor, url: directory)
    try Self.validateWriterLock(
      descriptor: writerLockDescriptor, directoryDescriptor: directoryDescriptor)
    guard let current = segments.last else { throw SystemLoggerError.invalidSegment }
    var opened = stat()
    var linked = stat()
    guard fstat(currentDescriptor, &opened) == 0,
      fstatat(directoryDescriptor, current.name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_mode & S_IFMT == S_IFREG, linked.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == geteuid(), linked.st_uid == geteuid(), opened.st_nlink == 1,
      linked.st_nlink == 1, opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
      linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
      opened.st_size >= 0, Int(opened.st_size) == current.size
    else { throw SystemLoggerError.invalidSegment }
  }

  private static func createSecureDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw SystemLoggerError.fileOperationFailed(errno: errno)
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else { throw SystemLoggerError.unsafeLogDirectory }
  }

  private static func validateOwnedDirectory(descriptor: Int32, url: URL) throws {
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0, lstat(url.path, &linked) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), linked.st_uid == geteuid(),
      opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
      linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
    else { throw SystemLoggerError.unsafeLogDirectory }
  }

  private static func validateWriterLock(
    descriptor: Int32, directoryDescriptor: Int32
  ) throws {
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(directoryDescriptor, ".writer.lock", &linked, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_mode & S_IFMT == S_IFREG, linked.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == geteuid(), linked.st_uid == geteuid(),
      opened.st_nlink == 1, linked.st_nlink == 1,
      opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
      linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
    else { throw SystemLoggerError.unsafeLogDirectory }
  }

  private static func scanSegments(directoryDescriptor: Int32) throws -> [Segment] {
    let duplicate = Darwin.dup(directoryDescriptor)
    guard duplicate >= 0 else { throw SystemLoggerError.fileOperationFailed(errno: errno) }
    guard let directory = fdopendir(duplicate) else {
      let failure = errno
      Darwin.close(duplicate)
      throw SystemLoggerError.fileOperationFailed(errno: failure)
    }
    defer { closedir(directory) }
    var loaded: [Segment] = []
    while let entry = readdir(directory) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(
          decoding: bytes.prefix(Int(entry.pointee.d_namlen)).map { UInt8($0) }, as: UTF8.self)
      }
      guard name.hasPrefix("diagnostics-"), name.hasSuffix(".jsonl") else { continue }
      let value = name.dropFirst("diagnostics-".count).dropLast(".jsonl".count)
      guard value.count == 20, let sequence = UInt64(value), name == segmentName(sequence) else {
        throw SystemLoggerError.invalidSegment
      }
      var metadata = stat()
      guard fstatat(directoryDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
        metadata.st_nlink == 1, metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
        metadata.st_size >= 0, metadata.st_size <= Int.max
      else { throw SystemLoggerError.invalidSegment }
      loaded.append(Segment(sequence: sequence, name: name, size: Int(metadata.st_size)))
    }
    loaded.sort { $0.sequence < $1.sequence }
    guard zip(loaded, loaded.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else {
      throw SystemLoggerError.invalidSegment
    }
    return loaded
  }

  private static func segmentName(_ sequence: UInt64) -> String {
    String(format: "diagnostics-%020llu.jsonl", sequence)
  }

  private static func createSegment(
    _ segment: Segment, directoryDescriptor: Int32, directoryURL: URL
  ) throws -> Int32 {
    let descriptor = Darwin.openat(
      directoryDescriptor, segment.name,
      O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SystemLoggerError.fileOperationFailed(errno: errno) }
    do {
      try fullSync(descriptor)
      try fullSync(directoryDescriptor)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      _ = Darwin.unlinkat(directoryDescriptor, segment.name, 0)
      _ = Darwin.fsync(directoryDescriptor)
      throw error
    }
  }

  private static func openSegment(
    _ segment: Segment, directoryDescriptor: Int32, directoryURL _: URL
  ) throws -> Int32 {
    let descriptor = Darwin.openat(
      directoryDescriptor, segment.name, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SystemLoggerError.fileOperationFailed(errno: errno) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
      metadata.st_size >= 0, Int(metadata.st_size) == segment.size
    else {
      Darwin.close(descriptor)
      throw SystemLoggerError.invalidSegment
    }
    return descriptor
  }

  private static func repairTornTail(
    descriptor: Int32,
    segment: Segment,
    directoryDescriptor: Int32,
    directoryURL _: URL
  ) throws -> Int {
    guard segment.size > 0 else { return 0 }
    var lastByte: UInt8 = 0
    guard Darwin.pread(descriptor, &lastByte, 1, off_t(segment.size - 1)) == 1 else {
      throw SystemLoggerError.fileOperationFailed(errno: errno)
    }
    guard lastByte != 0x0A else { return segment.size }
    var position = segment.size
    var byte: UInt8 = 0
    while position > 0 {
      position -= 1
      guard Darwin.pread(descriptor, &byte, 1, off_t(position)) == 1 else {
        throw SystemLoggerError.fileOperationFailed(errno: errno)
      }
      if byte == 0x0A {
        position += 1
        break
      }
    }
    guard Darwin.ftruncate(descriptor, off_t(position)) == 0 else {
      throw SystemLoggerError.fileOperationFailed(errno: errno)
    }
    try fullSync(descriptor)
    try fullSync(directoryDescriptor)
    return position
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw SystemLoggerError.fileOperationFailed(errno: errno) }
      offset += count
    }
  }

  private static func readExactly(descriptor: Int32, byteCount: Int) throws -> Data {
    var data = Data(count: byteCount)
    var offset = 0
    while offset < byteCount {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), byteCount - offset, off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw SystemLoggerError.fileOperationFailed(errno: errno) }
      offset += count
    }
    return data
  }

  private static func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard Darwin.fsync(descriptor) == 0 else {
      throw SystemLoggerError.fileOperationFailed(errno: errno)
    }
  }
}

/// `PORT-LOGGING-001` facade. Sensitive input is transformed into a redacted record before either
/// the Unified Logging sink or the durable structured store can observe it.
public final class SystemLogger: @unchecked Sendable {
  private let structuredStore: StructuredDiagnosticLogStore
  private let unifiedLogger: any UnifiedDiagnosticLogging
  private let auditClock: any AuditClock
  private let redactionPolicy: DiagnosticRedactionPolicy

  public init(
    structuredStore: StructuredDiagnosticLogStore,
    unifiedLogger: any UnifiedDiagnosticLogging = UnifiedSystemDiagnosticLogger(),
    auditClock: any AuditClock = SystemAuditClock(),
    redactionPolicy: DiagnosticRedactionPolicy = .init()
  ) {
    self.structuredStore = structuredStore
    self.unifiedLogger = unifiedLogger
    self.auditClock = auditClock
    self.redactionPolicy = redactionPolicy
  }

  public func log(
    level: SystemLogLevel,
    category: SystemLogCategory,
    eventName: SystemLogEventName,
    correlationID: DiagnosticCorrelationID,
    fields: [SystemLogFieldKey: DiagnosticInputField]
  ) throws {
    guard fields.count <= RedactedDiagnosticRecord.maximumFieldCount else {
      throw SystemLoggerError.fieldLimitExceeded
    }
    var redacted: [String: String] = [:]
    for key in fields.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard let field = fields[key],
        field.value.utf8.count <= RedactedDiagnosticRecord.maximumFieldValueBytes
      else { throw SystemLoggerError.fieldLimitExceeded }
      guard field.privacy == key.requiredPrivacy else {
        throw SystemLoggerError.invalidFieldPrivacy
      }
      if field.privacy == .publicValue, !key.validatePublicValue(field.value) {
        throw SystemLoggerError.invalidPublicFieldValue
      }
      redacted[key.rawValue] = redactionPolicy.redact(field)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let record = RedactedDiagnosticRecord(
      timestamp: formatter.string(from: auditClock.nowUTC), level: level, category: category,
      eventName: eventName.rawValue, correlationID: correlationID.rawValue, fields: redacted)
    try structuredStore.appendAndSynchronize(record)
    unifiedLogger.log(record)
  }
}
