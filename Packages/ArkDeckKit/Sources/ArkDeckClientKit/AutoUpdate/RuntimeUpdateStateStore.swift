import ArkDeckCore
import Darwin
import Foundation

public enum RuntimeUpdateStateStoreError: Error, Equatable, Sendable {
  case unsafeDirectory
  case recordUnreadable
  case writeFailed
  case resourceConflict
  case operationInProgress
}

/// The durable owner for the consumer update lifecycle shared by the App and CLI.
///
/// The downloaded artifact path is intentionally private to this record. Public projections expose
/// only its signed digest and length, so callers can continue the typed lifecycle without gaining a
/// caller-supplied path surface.
public struct RuntimeUpdateSnapshot: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = "arkdeck.runtime-update-state/1"

  public let schemaVersion: String
  public let generation: UInt64
  public let state: AutoUpdateState
  public let activeOperationID: UUID?
  public let cancellationRequested: Bool
  public let updatedAtUTC: String

  public init(
    generation: UInt64,
    state: AutoUpdateState,
    activeOperationID: UUID? = nil,
    cancellationRequested: Bool = false,
    updatedAtUTC: String? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generation = generation
    self.state = state
    self.activeOperationID = activeOperationID
    self.cancellationRequested = cancellationRequested
    self.updatedAtUTC = updatedAtUTC ?? ISO8601Timestamps.string(from: Date())
  }

  public static func initial(now: Date = Date()) -> RuntimeUpdateSnapshot {
    RuntimeUpdateSnapshot(
      generation: 0, state: .idle,
      updatedAtUTC: ISO8601Timestamps.string(from: now))
  }
}

public struct RuntimeUpdateStatusProjection: Equatable, Sendable {
  public static let schemaVersion = "arkdeck.runtime-update-status/1"

  public let generation: UInt64
  public let phase: String
  public let isBusy: Bool
  public let cancellationRequested: Bool
  public let canCheck: Bool
  public let canDownload: Bool
  public let canHandoff: Bool
  public let updateVersion: String?
  public let releaseNotesSummary: String?
  public let artifactSHA256: String?
  public let artifactByteLength: UInt64?
  public let noUpdateReason: String?
  public let failureCode: String?
  public let updatedAtUTC: String

  public init(snapshot: RuntimeUpdateSnapshot) {
    generation = snapshot.generation
    cancellationRequested = snapshot.cancellationRequested
    updatedAtUTC = snapshot.updatedAtUTC

    var version: String?
    var notes: String?
    var digest: String?
    var length: UInt64?
    var noUpdate: String?
    var failure: String?
    let statePhase: String
    switch snapshot.state {
    case .idle:
      statePhase = "idle"
    case .checking:
      statePhase = "checking"
    case .available(let feed):
      statePhase = "available"
      version = feed.payload.version
      notes = feed.payload.releaseNotesSummary
    case .noUpdate(let reason):
      statePhase = "noUpdate"
      noUpdate = reason.rawValue
    case .downloading(let feed):
      statePhase = "downloading"
      version = feed.payload.version
      notes = feed.payload.releaseNotesSummary
    case .verifying(let artifact):
      statePhase = "verifying"
      digest = artifact.sha256
      length = artifact.byteLength
    case .awaitingConsent(let feed, let artifact):
      statePhase = "awaitingConsent"
      version = feed.payload.version
      notes = feed.payload.releaseNotesSummary
      digest = artifact.downloaded.sha256
      length = artifact.downloaded.byteLength
    case .handedOff:
      statePhase = "handedOff"
    case .failed(let code):
      statePhase = "failed"
      failure = code.rawValue
    case .cancelled:
      statePhase = "cancelled"
    }
    phase = statePhase
    isBusy = snapshot.activeOperationID != nil
    canCheck = !isBusy && !["awaitingConsent", "handedOff"].contains(statePhase)
    canDownload = !isBusy && statePhase == "available"
    canHandoff = !isBusy && statePhase == "awaitingConsent"
    updateVersion = version
    releaseNotesSummary = notes
    artifactSHA256 = digest
    artifactByteLength = length
    noUpdateReason = noUpdate
    failureCode = failure
  }
}

public final class RuntimeUpdateOperationLease: @unchecked Sendable {
  fileprivate let descriptor: Int32

  fileprivate init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

/// A canonical, owner-only, cross-process state store with a separate process-lifetime operation
/// lease. State readers never block on a network transfer; a crashed writer automatically releases
/// the lease, allowing explicit cleanup to settle its in-progress record without guessing liveness.
public final class RuntimeUpdateStateStore: @unchecked Sendable {
  private static let stateName = "state-v1.json"
  private static let stateLockName = ".state-v1.lock"
  private static let operationLockName = ".operation-v1.lock"
  private static let maximumStateBytes = 512 * 1_024

  public let directory: URL
  private let processLock: NSLock
  private let now: @Sendable () -> Date

  public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
    self.directory = directory.standardizedFileURL
    self.processLock = RuntimeUpdateProcessLockRegistry.shared.lock(for: self.directory.path)
    self.now = now
  }

  public static func production() throws -> RuntimeUpdateStateStore {
    do {
      let support = try AutoUpdateFilesystemLayout.applicationSupportDirectory()
      return RuntimeUpdateStateStore(
        directory: support.appending(
          path: "ArkDeck/AutoUpdateLifecycle", directoryHint: .isDirectory))
    } catch {
      throw RuntimeUpdateStateStoreError.unsafeDirectory
    }
  }

  public func load() throws -> RuntimeUpdateSnapshot {
    try withStateTransaction { directoryDescriptor in
      if let existing = try Self.loadRecord(directoryDescriptor: directoryDescriptor) {
        return existing
      }
      let initial = RuntimeUpdateSnapshot.initial(now: now())
      try Self.persist(initial, directoryDescriptor: directoryDescriptor)
      return initial
    }
  }

  public func replace(
    expectedGeneration: UInt64,
    state: AutoUpdateState,
    activeOperationID: UUID? = nil,
    cancellationRequested: Bool = false
  ) throws -> RuntimeUpdateSnapshot {
    try withStateTransaction { directoryDescriptor in
      let current = try Self.loadRecord(directoryDescriptor: directoryDescriptor)
        ?? RuntimeUpdateSnapshot.initial(now: now())
      guard current.generation == expectedGeneration, current.generation < UInt64.max else {
        throw RuntimeUpdateStateStoreError.resourceConflict
      }
      let next = RuntimeUpdateSnapshot(
        generation: current.generation + 1,
        state: state,
        activeOperationID: activeOperationID,
        cancellationRequested: cancellationRequested,
        updatedAtUTC: ISO8601Timestamps.string(from: now()))
      guard Self.isValid(next) else { throw RuntimeUpdateStateStoreError.writeFailed }
      try Self.persist(next, directoryDescriptor: directoryDescriptor)
      return next
    }
  }

  /// Records cancellation without waiting for the operation lease. The active foreground owner
  /// observes the generation/cancellation change and cannot publish a success transition afterward.
  public func requestCancellation() throws -> RuntimeUpdateSnapshot {
    try withStateTransaction { directoryDescriptor in
      let current = try Self.loadRecord(directoryDescriptor: directoryDescriptor)
        ?? RuntimeUpdateSnapshot.initial(now: now())
      guard current.activeOperationID != nil else { return current }
      guard current.generation < UInt64.max else {
        throw RuntimeUpdateStateStoreError.resourceConflict
      }
      let next = RuntimeUpdateSnapshot(
        generation: current.generation + 1,
        state: current.state,
        activeOperationID: current.activeOperationID,
        cancellationRequested: true,
        updatedAtUTC: ISO8601Timestamps.string(from: now()))
      try Self.persist(next, directoryDescriptor: directoryDescriptor)
      return next
    }
  }

  public func acquireOperationLease() throws -> RuntimeUpdateOperationLease {
    let directoryDescriptor = try openSecureDirectory()
    defer { Darwin.close(directoryDescriptor) }
    let descriptor = Darwin.openat(
      directoryDescriptor, Self.operationLockName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RuntimeUpdateStateStoreError.writeFailed }
    guard Self.validateLock(descriptor) else {
      Darwin.close(descriptor)
      throw RuntimeUpdateStateStoreError.recordUnreadable
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      if errno == EWOULDBLOCK { throw RuntimeUpdateStateStoreError.operationInProgress }
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    return RuntimeUpdateOperationLease(descriptor: descriptor)
  }

  public func operationIsActive() throws -> Bool {
    do {
      _ = try acquireOperationLease()
      return false
    } catch RuntimeUpdateStateStoreError.operationInProgress {
      return true
    }
  }

  private func withStateTransaction<T>(_ body: (Int32) throws -> T) throws -> T {
    processLock.lock()
    defer { processLock.unlock() }
    let directoryDescriptor = try openSecureDirectory()
    defer { Darwin.close(directoryDescriptor) }
    let lockDescriptor = Darwin.openat(
      directoryDescriptor, Self.stateLockName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else { throw RuntimeUpdateStateStoreError.writeFailed }
    defer { Darwin.close(lockDescriptor) }
    guard Self.validateLock(lockDescriptor) else {
      throw RuntimeUpdateStateStoreError.recordUnreadable
    }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }
    return try body(directoryDescriptor)
  }

  private func openSecureDirectory() throws -> Int32 {
    guard directory.isFileURL, directory.path.hasPrefix("/") else {
      throw RuntimeUpdateStateStoreError.unsafeDirectory
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeUpdateStateStoreError.unsafeDirectory
    }
    let descriptor = Darwin.open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw RuntimeUpdateStateStoreError.unsafeDirectory }
    do {
      guard fchmod(descriptor, 0o700) == 0 else {
        throw RuntimeUpdateStateStoreError.unsafeDirectory
      }
      var opened = stat()
      var linked = stat()
      guard fstat(descriptor, &opened) == 0,
        lstat(directory.path, &linked) == 0,
        opened.st_mode & S_IFMT == S_IFDIR,
        linked.st_mode & S_IFMT == S_IFDIR,
        opened.st_uid == geteuid(), linked.st_uid == geteuid(),
        opened.st_mode & mode_t(0o777) == mode_t(0o700),
        linked.st_mode & mode_t(0o777) == mode_t(0o700),
        opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
      else { throw RuntimeUpdateStateStoreError.unsafeDirectory }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func validateLock(_ descriptor: Int32) -> Bool {
    guard fchmod(descriptor, 0o600) == 0 else { return false }
    var metadata = stat()
    return fstat(descriptor, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFREG
      && metadata.st_uid == geteuid()
      && metadata.st_nlink == 1
      && metadata.st_mode & mode_t(0o777) == mode_t(0o600)
  }

  private static func loadRecord(directoryDescriptor: Int32) throws -> RuntimeUpdateSnapshot? {
    let descriptor = Darwin.openat(
      directoryDescriptor, stateName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw RuntimeUpdateStateStoreError.recordUnreadable
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & mode_t(0o777) == mode_t(0o400),
      metadata.st_size > 0, metadata.st_size <= maximumStateBytes
    else { throw RuntimeUpdateStateStoreError.recordUnreadable }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw RuntimeUpdateStateStoreError.recordUnreadable }
      if count == 0 { break }
      guard data.count + count <= maximumStateBytes else {
        throw RuntimeUpdateStateStoreError.recordUnreadable
      }
      data.append(contentsOf: buffer[0..<count])
    }
    guard data.count == metadata.st_size,
      let record = try? JSONDecoder().decode(RuntimeUpdateSnapshot.self, from: data),
      isValid(record), try canonicalData(record) == data
    else { throw RuntimeUpdateStateStoreError.recordUnreadable }
    return record
  }

  private static func persist(
    _ record: RuntimeUpdateSnapshot,
    directoryDescriptor: Int32
  ) throws {
    let data: Data
    do {
      data = try canonicalData(record)
    } catch {
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    guard !data.isEmpty, data.count <= maximumStateBytes else {
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    let temporaryName = ".state-\(UUID().uuidString.lowercased()).part"
    let descriptor = Darwin.openat(
      directoryDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RuntimeUpdateStateStoreError.writeFailed }
    var temporaryExists = true
    defer {
      Darwin.close(descriptor)
      if temporaryExists { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    try writeAll(data, descriptor: descriptor)
    try strictFileSync(descriptor)
    guard fchmod(descriptor, 0o400) == 0 else {
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    try strictFileSync(descriptor)
    guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, stateName) == 0 else {
      throw RuntimeUpdateStateStoreError.writeFailed
    }
    temporaryExists = false
    try syncDirectory(directoryDescriptor)
  }

  private static func canonicalData(_ record: RuntimeUpdateSnapshot) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(record)
  }

  private static func isValid(_ record: RuntimeUpdateSnapshot) -> Bool {
    guard record.schemaVersion == RuntimeUpdateSnapshot.currentSchemaVersion,
      ISO8601Timestamps.parse(record.updatedAtUTC) != nil
    else { return false }
    let hasOperation = record.activeOperationID != nil
    if record.cancellationRequested && !hasOperation { return false }
    switch record.state {
    case .checking, .downloading, .verifying:
      return hasOperation
    case .awaitingConsent:
      return true
    default:
      return !hasOperation
    }
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw RuntimeUpdateStateStoreError.writeFailed }
      offset += count
    }
  }

  private static func strictFileSync(_ descriptor: Int32) throws {
    guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else {
      throw RuntimeUpdateStateStoreError.writeFailed
    }
  }

  private static func syncDirectory(_ descriptor: Int32) throws {
    guard fsync(descriptor) == 0 else { throw RuntimeUpdateStateStoreError.writeFailed }
  }
}

private final class RuntimeUpdateProcessLockRegistry: @unchecked Sendable {
  static let shared = RuntimeUpdateProcessLockRegistry()
  private let registryLock = NSLock()
  private var locks: [String: NSLock] = [:]

  func lock(for path: String) -> NSLock {
    registryLock.withLock {
      if let existing = locks[path] { return existing }
      let lock = NSLock()
      locks[path] = lock
      return lock
    }
  }
}
