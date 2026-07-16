import ArkDeckCore
import Darwin
import Foundation

public enum DurabilityFaultPoint: String, CaseIterable, Sendable {
  case journalAppend
  case journalWrite
  case journalFileSync
  case journalDirectorySync
  case outcomeAppend
  case checkpointTemporaryWrite
  case checkpointFileSync
  case checkpointReplace
  case checkpointDirectorySync
}

public struct DurabilityFaultInjector: @unchecked Sendable {
  private let body: (DurabilityFaultPoint) throws -> Void

  public init(_ body: @escaping (DurabilityFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: DurabilityFaultPoint) throws { try body(point) }

  public static let none = DurabilityFaultInjector { _ in }
}

public enum DurableFileError: Error, Equatable, Sendable {
  case pathMustBeAbsolute(String)
  case symbolicLinkRejected(String)
  case openFailed(path: String, errno: Int32)
  case writeFailed(path: String, errno: Int32)
  case syncFailed(path: String, errno: Int32)
  case replaceFailed(path: String, errno: Int32)
  case malformedCompletedRecord(line: Int)
  case sequenceViolation(String)
  case checkpointInvalid(String)
  case intentNotDurable
  case outcomeNotDurable
}

public protocol DurableJournalAppending: Sendable {
  func appendAndSynchronize(_ event: JournalEvent) throws
}

public final class FileDurableJournal: DurableJournalAppending, @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private let faultInjector: DurabilityFaultInjector
  private var appendState: JournalAppendValidationState
  private var poisoned = false

  public init(url: URL, faultInjector: DurabilityFaultInjector = .none) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    self.url = url
    self.faultInjector = faultInjector
    try DurableFilePrimitives.createDirectoryIfNeeded(url.deletingLastPathComponent())
    try DurableFilePrimitives.rejectSymbolicLink(url)

    let existed = FileManager.default.fileExists(atPath: url.path)
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw DurableFileError.openFailed(path: url.path, errno: errno) }
    defer { Darwin.close(descriptor) }
    if !existed {
      try DurableFilePrimitives.fullSync(descriptor, path: url.path)
      try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
    }
    appendState = try JournalAppendValidationState(
      replay: DurableJournalRecovery.inspect(url: url))
  }

  public func appendAndSynchronize(_ event: JournalEvent) throws {
    try faultInjector.check(event.kind == .stepOutcome ? .outcomeAppend : .journalAppend)
    var data = try JournalEventCodec.encode(event)
    data.append(0x0A)

    lock.lock()
    defer { lock.unlock() }

    guard !poisoned else {
      throw DurableFileError.sequenceViolation("journal writer is poisoned after a failed append")
    }
    try appendState.validate(event)
    do {
      let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else {
        throw DurableFileError.openFailed(path: url.path, errno: errno)
      }
      defer { Darwin.close(descriptor) }
      try faultInjector.check(.journalWrite)
      try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: url.path)
      try faultInjector.check(.journalFileSync)
      try DurableFilePrimitives.fullSync(descriptor, path: url.path)
      try faultInjector.check(.journalDirectorySync)
      try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
      appendState.accept(event)
    } catch {
      poisoned = true
      throw error
    }
  }
}

public final class WriteAheadIntentGate: @unchecked Sendable {
  private let journal: any DurableJournalAppending

  public init(journal: any DurableJournalAppending) {
    self.journal = journal
  }

  public func dispatch<T>(intent: JournalEvent, operation: () throws -> T) throws -> T {
    guard intent.kind == .stepIntent || intent.kind == .compensationIntent else {
      throw JournalEventValidationError.malformedEnvelope("dispatch gate requires an intent")
    }
    do {
      try journal.appendAndSynchronize(intent)
    } catch {
      throw DurableFileError.intentNotDurable
    }
    return try operation()
  }
}

public struct JournalCheckpoint: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let sessionID: String
  public let jobID: String
  public let journalSequence: Int
  public let state: String
  public let updatedAt: String

  public init(
    sessionID: String,
    jobID: String,
    journalSequence: Int,
    state: String,
    updatedAt: String
  ) throws {
    guard !sessionID.isEmpty, !jobID.isEmpty, journalSequence >= 0,
      JobState(rawValue: state) != nil,
      ISO8601DateFormatter().date(from: updatedAt) != nil
    else { throw DurableFileError.checkpointInvalid("invalid checkpoint fields") }
    schemaVersion = "1.0.0"
    self.sessionID = sessionID
    self.jobID = jobID
    self.journalSequence = journalSequence
    self.state = state
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case sessionID = "sessionId"
    case jobID = "jobId"
    case journalSequence
    case state
    case updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
      throw DurableFileError.checkpointInvalid("unknown or missing checkpoint fields")
    }
    let schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    guard schemaVersion == "1.0.0" else {
      throw DurableFileError.checkpointInvalid("unsupported checkpoint schemaVersion")
    }
    try self.init(
      sessionID: container.decode(String.self, forKey: .sessionID),
      jobID: container.decode(String.self, forKey: .jobID),
      journalSequence: container.decode(Int.self, forKey: .journalSequence),
      state: container.decode(String.self, forKey: .state),
      updatedAt: container.decode(String.self, forKey: .updatedAt)
    )
  }
}

public protocol JournalCheckpointSaving: Sendable {
  func save(_ checkpoint: JournalCheckpoint) throws
}

public final class AtomicJournalCheckpointStore: JournalCheckpointSaving, @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private let faultInjector: DurabilityFaultInjector

  public init(url: URL, faultInjector: DurabilityFaultInjector = .none) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    self.url = url
    self.faultInjector = faultInjector
    try DurableFilePrimitives.createDirectoryIfNeeded(url.deletingLastPathComponent())
    try DurableFilePrimitives.rejectSymbolicLink(url)
  }

  public func save(_ checkpoint: JournalCheckpoint) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(checkpoint)
    let temporaryURL = url.deletingLastPathComponent().appending(
      path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

    lock.lock()
    defer { lock.unlock() }

    let descriptor = Darwin.open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw DurableFileError.openFailed(path: temporaryURL.path, errno: errno)
    }
    var closeDescriptor = true
    defer {
      if closeDescriptor { Darwin.close(descriptor) }
      try? FileManager.default.removeItem(at: temporaryURL)
    }

    try faultInjector.check(.checkpointTemporaryWrite)
    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporaryURL.path)
    try faultInjector.check(.checkpointFileSync)
    try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
    guard Darwin.close(descriptor) == 0 else {
      closeDescriptor = false
      throw DurableFileError.syncFailed(path: temporaryURL.path, errno: errno)
    }
    closeDescriptor = false

    try faultInjector.check(.checkpointReplace)
    guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
      throw DurableFileError.replaceFailed(path: url.path, errno: errno)
    }
    try faultInjector.check(.checkpointDirectorySync)
    try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
  }

  public func load() throws -> JournalCheckpoint {
    let data = try Data(contentsOf: url)
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      throw DurableFileError.checkpointInvalid("checkpoint must be an object")
    }
    try object.requireKeys([
      "schemaVersion", "sessionId", "jobId", "journalSequence", "state", "updatedAt",
    ])
    return try JSONDecoder().decode(JournalCheckpoint.self, from: data)
  }
}

public final class DurableOutcomeCheckpointGate: @unchecked Sendable {
  private let journal: any DurableJournalAppending
  private let checkpointStore: any JournalCheckpointSaving

  public init(journal: any DurableJournalAppending, checkpointStore: any JournalCheckpointSaving) {
    self.journal = journal
    self.checkpointStore = checkpointStore
  }

  public func record(outcome: JournalEvent, checkpoint: JournalCheckpoint) throws {
    guard outcome.kind == .stepOutcome || outcome.kind == .compensationOutcome else {
      throw JournalEventValidationError.malformedEnvelope("outcome gate requires an outcome")
    }
    do {
      try journal.appendAndSynchronize(outcome)
    } catch {
      throw DurableFileError.outcomeNotDurable
    }
    try checkpointStore.save(checkpoint)
  }
}

enum DurableFilePrimitives {
  static func requireAbsoluteFileURL(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw DurableFileError.pathMustBeAbsolute(url.path)
    }
  }

  static func createDirectoryIfNeeded(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  static func rejectSymbolicLink(_ url: URL) throws {
    var status = stat()
    if lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
      throw DurableFileError.symbolicLinkRejected(url.path)
    }
  }

  static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw DurableFileError.writeFailed(path: path, errno: errno)
        }
        guard written > 0 else { throw DurableFileError.writeFailed(path: path, errno: EIO) }
        offset += written
      }
    }
  }

  static func fullSync(_ descriptor: Int32, path: String) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw DurableFileError.syncFailed(path: path, errno: errno)
    }
    guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
      throw DurableFileError.syncFailed(path: path, errno: errno)
    }
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw DurableFileError.openFailed(path: url.path, errno: errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw DurableFileError.syncFailed(path: url.path, errno: errno)
    }
  }
}
