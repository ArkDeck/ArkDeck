import ArkDeckCore
import CryptoKit
import Darwin
import Dispatch
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
  case truncateFailed(path: String, errno: Int32)
  case syncFailed(path: String, errno: Int32)
  case replaceFailed(path: String, errno: Int32)
  case malformedCompletedRecord(line: Int)
  case sequenceViolation(String)
  case checkpointInvalid(String)
  case intentNotDurable
  case outcomeNotDurable
}

/// The only create-or-replace path for small Runtime durable documents.
///
/// `FileManager.replaceItemAt` is unsuitable here because its destination
/// must already exist.  POSIX `rename` has the required atomic semantics for
/// both a first publication and a replacement on the same volume.  The file
/// and its parent directory are synchronised on either path, so a successful
/// return makes the new name durable across a sudden process loss.
public enum DurableFileWriter {
  public static func createOrReplaceAtomically(destination: URL, data: Data) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(destination)
    let directory = destination.deletingLastPathComponent()
    try DurableFilePrimitives.createDirectoryIfNeeded(directory)
    try DurableFilePrimitives.rejectSymbolicLink(destination)

    let temporary = directory.appending(
      path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw DurableFileError.openFailed(path: temporary.path, errno: errno)
    }
    var descriptorOpen = true
    defer {
      if descriptorOpen { Darwin.close(descriptor) }
      try? FileManager.default.removeItem(at: temporary)
    }

    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporary.path)
    try DurableFilePrimitives.fullSync(descriptor, path: temporary.path)
    guard Darwin.close(descriptor) == 0 else {
      descriptorOpen = false
      throw DurableFileError.syncFailed(path: temporary.path, errno: errno)
    }
    descriptorOpen = false

    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw DurableFileError.replaceFailed(path: destination.path, errno: errno)
    }
    try DurableFilePrimitives.syncDirectory(directory)
  }
}

enum SessionTerminalPublicationLock {
  private static let lockName = SessionLayout.manifestLockFileName

  static func withExclusive<T>(in directory: URL, _ body: () throws -> T) throws -> T {
    let lockURL = directory.appending(path: lockName)
    try DurableFilePrimitives.rejectSymbolicLink(lockURL)
    var priorMetadata = stat()
    let mayNeedDurabilityBarrier = lstat(lockURL.path, &priorMetadata) != 0 && errno == ENOENT
    let descriptor = Darwin.open(
      lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw DurableFileError.openFailed(path: lockURL.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw DurableFileError.sequenceViolation("unsafe terminal publication lock")
    }
    if mayNeedDurabilityBarrier {
      try DurableFilePrimitives.fullSync(descriptor, path: lockURL.path)
      try DurableFilePrimitives.syncDirectory(directory)
    }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw DurableFileError.openFailed(path: lockURL.path, errno: errno)
    }
    defer { flock(descriptor, LOCK_UN) }
    var lockedMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &lockedMetadata) == 0,
      lstat(lockURL.path, &pathMetadata) == 0,
      lockedMetadata.st_mode & S_IFMT == S_IFREG,
      lockedMetadata.st_uid == geteuid(), lockedMetadata.st_nlink == 1,
      lockedMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      lockedMetadata.st_dev == pathMetadata.st_dev,
      lockedMetadata.st_ino == pathMetadata.st_ino
    else {
      throw DurableFileError.sequenceViolation("terminal publication lock path changed")
    }
    return try body()
  }
}

public struct JournalAbandonmentContext: Equatable, Sendable {
  public let requiredHazards: [String]
  public let requiresOutcomeUnknown: Bool

  public init(requiredHazards: [String], requiresOutcomeUnknown: Bool) {
    self.requiredHazards = requiredHazards
    self.requiresOutcomeUnknown = requiresOutcomeUnknown
  }
}

public protocol DurableJournalAppending: Sendable {
  func appendAndSynchronize(_ event: JournalEvent) throws
  func abandonmentContext() throws -> JournalAbandonmentContext
}

/// The validated tail of one open journal writer.  It allows the common
/// append path to validate only immutable metadata plus the last complete
/// record, instead of replaying every historical event.  Any observed change
/// outside this cursor falls back to a full replay before a new event is
/// accepted.
private struct JournalAppendCursor {
  var offset: Int64
  var lastSequence: Int?
  var lastRecordOffset: Int64?
  var lastRecordLength: Int
  var lastRecordSHA256: Data?
  var modificationSeconds: Int
  var modificationNanoseconds: Int
  var changeSeconds: Int
  var changeNanoseconds: Int

  init(metadata: stat, replay: JournalReplay) throws {
    offset = Int64(metadata.st_size)
    lastSequence = replay.lastDurableSequence
    modificationSeconds = Int(metadata.st_mtimespec.tv_sec)
    modificationNanoseconds = Int(metadata.st_mtimespec.tv_nsec)
    changeSeconds = Int(metadata.st_ctimespec.tv_sec)
    changeNanoseconds = Int(metadata.st_ctimespec.tv_nsec)
    guard let last = replay.events.last else {
      lastRecordOffset = nil
      lastRecordLength = 0
      lastRecordSHA256 = nil
      return
    }
    var encoded = try JournalEventCodec.encode(last)
    encoded.append(0x0A)
    lastRecordOffset = offset - Int64(encoded.count)
    lastRecordLength = encoded.count
    lastRecordSHA256 = Data(SHA256.hash(data: encoded))
  }

  func matches(_ metadata: stat) -> Bool {
    Int64(metadata.st_size) == offset
      && Int(metadata.st_mtimespec.tv_sec) == modificationSeconds
      && Int(metadata.st_mtimespec.tv_nsec) == modificationNanoseconds
      && Int(metadata.st_ctimespec.tv_sec) == changeSeconds
      && Int(metadata.st_ctimespec.tv_nsec) == changeNanoseconds
  }

  func validatesTail(on descriptor: Int32, path: String) throws -> Bool {
    guard let lastRecordOffset, let lastRecordSHA256 else { return offset == 0 }
    var data = Data(count: lastRecordLength)
    var readOffset = 0
    while readOffset < data.count {
      let remaining = data.count - readOffset
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: readOffset), remaining,
          off_t(lastRecordOffset) + off_t(readOffset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw DurableFileError.openFailed(path: path, errno: count < 0 ? errno : EIO)
      }
      readOffset += count
    }
    return Data(SHA256.hash(data: data)) == lastRecordSHA256
  }

  mutating func accept(
    event: JournalEvent, encodedData: Data, metadata: stat
  ) {
    lastRecordOffset = offset
    lastRecordLength = encodedData.count
    lastRecordSHA256 = Data(SHA256.hash(data: encodedData))
    offset = Int64(metadata.st_size)
    lastSequence = event.sequence
    modificationSeconds = Int(metadata.st_mtimespec.tv_sec)
    modificationNanoseconds = Int(metadata.st_mtimespec.tv_nsec)
    changeSeconds = Int(metadata.st_ctimespec.tv_sec)
    changeNanoseconds = Int(metadata.st_ctimespec.tv_nsec)
  }
}

/// Per-append measurements used only by the durable-journal performance
/// contract.  Keeping this internal prevents benchmark instrumentation from
/// becoming a Runtime API while still making the hot-path guarantees
/// inspectable in the package's test target.
struct JournalAppendMeasurement: Equatable, Sendable {
  let validationBytesRead: Int
  let usedFullReplay: Bool
  let fileSyncNanoseconds: UInt64
  let directorySyncNanoseconds: UInt64
  let totalAppendNanoseconds: UInt64
}

public final class FileDurableJournal: DurableJournalAppending, @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private let faultInjector: DurabilityFaultInjector
  private var appendState: JournalAppendValidationState
  private var appendCursor: JournalAppendCursor
  private var poisoned = false
  private let boundDevice: dev_t
  private let boundInode: ino_t
  private let appendMeasurementSink: ((JournalAppendMeasurement) -> Void)?

  public convenience init(url: URL, faultInjector: DurabilityFaultInjector = .none) throws {
    try self.init(url: url, faultInjector: faultInjector, appendMeasurementSink: nil)
  }

  init(
    url: URL,
    faultInjector: DurabilityFaultInjector = .none,
    appendMeasurementSink: ((JournalAppendMeasurement) -> Void)?
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    self.url = url
    self.faultInjector = faultInjector
    self.appendMeasurementSink = appendMeasurementSink
    try DurableFilePrimitives.createDirectoryIfNeeded(url.deletingLastPathComponent())
    let inspection = try SessionTerminalPublicationLock.withExclusive(
      in: url.deletingLastPathComponent()
    ) {
      try DurableFilePrimitives.rejectSymbolicLink(url)
      var pathMetadata = stat()
      let existed: Bool
      if lstat(url.path, &pathMetadata) == 0 {
        existed = true
      } else if errno == ENOENT {
        existed = false
      } else {
        throw DurableFileError.openFailed(path: url.path, errno: errno)
      }
      if !existed, try Self.terminalManifestExists(beside: url) {
        throw DurableFileError.sequenceViolation(
          "cannot create a journal after terminal Manifest publication")
      }
      let descriptor = Darwin.open(
        url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw DurableFileError.openFailed(path: url.path, errno: errno)
      }
      defer { Darwin.close(descriptor) }
      if !existed {
        try DurableFilePrimitives.fullSync(descriptor, path: url.path)
        try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
      }
      var inspection = try DurableJournalRecovery.inspect(
        openFileDescriptor: descriptor, path: url.path)
      if inspection.replay.hasTornTail {
        guard try !Self.terminalManifestExists(beside: url) else {
          throw DurableFileError.sequenceViolation(
            "cannot repair a torn journal after terminal Manifest publication")
        }
        guard inspection.replay.events.first?.kind == .jobCreated else {
          throw DurableFileError.sequenceViolation(
            "cannot repair a torn journal without a durable jobCreated record")
        }
        try DurableFilePrimitives.discardTornTail(
          at: url, descriptor: descriptor,
          durableRecordCount: inspection.replay.events.count)
        inspection = try DurableJournalRecovery.inspect(
          openFileDescriptor: descriptor, path: url.path)
      }
      return inspection
    }
    appendState = try JournalAppendValidationState(replay: inspection.replay)
    appendCursor = try JournalAppendCursor(metadata: inspection.metadata, replay: inspection.replay)
    // Pin the writer to the durable journal inode it opened. External replacement of the file
    // (unlink+recreate, rename-over) must fail attributably at the next operation instead of
    // silently re-deriving state from a rewritten history. Cooperating writers on the same
    // inode (including in-place torn-tail repair) remain valid.
    boundDevice = inspection.metadata.st_dev
    boundInode = inspection.metadata.st_ino
  }

  public func abandonmentContext() throws -> JournalAbandonmentContext {
    lock.lock()
    defer { lock.unlock() }
    guard !poisoned else {
      throw DurableFileError.sequenceViolation("journal writer is poisoned after a failed append")
    }
    let inspection = try SessionTerminalPublicationLock.withExclusive(
      in: url.deletingLastPathComponent()
    ) {
      let descriptor = Darwin.open(
        url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else {
        throw DurableFileError.openFailed(path: url.path, errno: errno)
      }
      defer { Darwin.close(descriptor) }
      return try DurableJournalRecovery.inspect(
        openFileDescriptor: descriptor, path: url.path)
    }
    try requireBoundJournal(inspection.metadata)
    appendState = try JournalAppendValidationState(replay: inspection.replay)
    appendCursor = try JournalAppendCursor(metadata: inspection.metadata, replay: inspection.replay)
    return appendState.abandonmentContext
  }

  public func appendAndSynchronize(_ event: JournalEvent) throws {
    // The resource timings are a benchmark-only observation seam.  Do not
    // make every production journal append pay for clock reads when no test
    // has opted into those measurements.
    let measuresAppend = appendMeasurementSink != nil
    let appendStarted = measuresAppend ? DispatchTime.now().uptimeNanoseconds : 0
    try faultInjector.check(event.kind == .stepOutcome ? .outcomeAppend : .journalAppend)
    var data = try JournalEventCodec.encode(event)
    data.append(0x0A)

    lock.lock()
    defer { lock.unlock() }

    guard !poisoned else {
      throw DurableFileError.sequenceViolation("journal writer is poisoned after a failed append")
    }
    var mutationStarted = false
    do {
      try SessionTerminalPublicationLock.withExclusive(in: url.deletingLastPathComponent()) {
        guard try !Self.terminalManifestExists(beside: url) else {
          throw DurableFileError.sequenceViolation(
            "journal append follows terminal Manifest publication")
        }
        let descriptor = Darwin.open(
          url.path, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
          throw DurableFileError.openFailed(path: url.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
          throw DurableFileError.openFailed(path: url.path, errno: errno)
        }
        try requireBoundJournal(metadata)
        var currentState: JournalAppendValidationState
        var currentCursor: JournalAppendCursor
        var validationBytesRead = 0
        var usedFullReplay = false
        if appendCursor.matches(metadata),
          try appendCursor.validatesTail(on: descriptor, path: url.path)
        {
          validationBytesRead = appendCursor.lastRecordLength
          currentState = appendState
          currentCursor = appendCursor
        } else {
          usedFullReplay = true
          validationBytesRead = Int(metadata.st_size)
          let inspection = try DurableJournalRecovery.inspect(
            openFileDescriptor: descriptor, path: url.path)
          try requireBoundJournal(inspection.metadata)
          currentState = try JournalAppendValidationState(replay: inspection.replay)
          currentCursor = try JournalAppendCursor(
            metadata: inspection.metadata, replay: inspection.replay)
        }
        try currentState.validate(event)
        mutationStarted = true
        try faultInjector.check(.journalWrite)
        try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: url.path)
        try faultInjector.check(.journalFileSync)
        let fileSyncStarted = measuresAppend ? DispatchTime.now().uptimeNanoseconds : 0
        try DurableFilePrimitives.fullSync(descriptor, path: url.path)
        let fileSyncNanoseconds = measuresAppend
          ? DispatchTime.now().uptimeNanoseconds - fileSyncStarted
          : 0
        try faultInjector.check(.journalDirectorySync)
        let directorySyncStarted = measuresAppend ? DispatchTime.now().uptimeNanoseconds : 0
        try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
        let directorySyncNanoseconds = measuresAppend
          ? DispatchTime.now().uptimeNanoseconds - directorySyncStarted
          : 0
        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0 else {
          throw DurableFileError.openFailed(path: url.path, errno: errno)
        }
        try requireBoundJournal(finalMetadata)
        currentState.accept(event)
        appendState = currentState
        currentCursor.accept(event: event, encodedData: data, metadata: finalMetadata)
        appendCursor = currentCursor
        if let appendMeasurementSink {
          appendMeasurementSink(JournalAppendMeasurement(
            validationBytesRead: validationBytesRead,
            usedFullReplay: usedFullReplay,
            fileSyncNanoseconds: fileSyncNanoseconds,
            directorySyncNanoseconds: directorySyncNanoseconds,
            totalAppendNanoseconds: DispatchTime.now().uptimeNanoseconds - appendStarted))
        }
      }
    } catch {
      if mutationStarted { poisoned = true }
      throw error
    }
  }

  private func requireBoundJournal(_ metadata: stat) throws {
    guard metadata.st_dev == boundDevice, metadata.st_ino == boundInode else {
      throw DurableFileError.sequenceViolation(
        "journal path no longer identifies the writer's bound durable journal")
    }
  }

  private static func terminalManifestExists(beside journalURL: URL) throws -> Bool {
    let manifestURL = journalURL.deletingLastPathComponent()
      .appending(path: SessionLayout.manifestFileName)
    var metadata = stat()
    if lstat(manifestURL.path, &metadata) == 0 { return true }
    guard errno == ENOENT else {
      throw DurableFileError.openFailed(path: manifestURL.path, errno: errno)
    }
    return false
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

package enum DurableFilePrimitives {
  package static func requireAbsoluteFileURL(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw DurableFileError.pathMustBeAbsolute(url.path)
    }
  }

  package static func createDirectoryIfNeeded(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  package static func rejectSymbolicLink(_ url: URL) throws {
    var status = stat()
    if lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
      throw DurableFileError.symbolicLinkRejected(url.path)
    }
  }

  package static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
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

  package static func fullSync(_ descriptor: Int32, path: String) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw DurableFileError.syncFailed(path: path, errno: errno)
    }
    guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
      throw DurableFileError.syncFailed(path: path, errno: errno)
    }
  }

  package static func discardTornTail(
    at url: URL,
    descriptor: Int32,
    durableRecordCount: Int
  ) throws {
    let data = try Data(contentsOf: url)
    var newlineCount = 0
    var durableLength: Int?
    for index in data.indices where data[index] == 0x0A {
      newlineCount += 1
      if newlineCount == durableRecordCount {
        durableLength = data.distance(
          from: data.startIndex, to: data.index(after: index))
        break
      }
    }
    guard let durableLength else {
      throw DurableFileError.sequenceViolation(
        "torn journal does not contain every replayed durable record")
    }
    guard Darwin.ftruncate(descriptor, off_t(durableLength)) == 0 else {
      throw DurableFileError.truncateFailed(path: url.path, errno: errno)
    }
    try fullSync(descriptor, path: url.path)
    try syncDirectory(url.deletingLastPathComponent())
  }

  package static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw DurableFileError.openFailed(path: url.path, errno: errno) }
    defer { Darwin.close(descriptor) }
    // Darwin fsync on the directory fd is the namespace-entry durability barrier. F_FULLFSYNC is
    // reserved here for regular-file contents and is not assumed to support directory descriptors.
    guard Darwin.fsync(descriptor) == 0 else {
      throw DurableFileError.syncFailed(path: url.path, errno: errno)
    }
  }
}
