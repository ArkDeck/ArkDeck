import ArkDeckCore
import Darwin
import Foundation

/// One Runtime-owned transaction serializes idempotency, first preview
/// publication and generation changes. No caller can supply a store path.
package final class RuntimeHDCControlActionStore: @unchecked Sendable {
  private let directoryPath: String
  private let directory: Int32
  private let directoryIdentity: stat
  private let processLock = NSLock()
  private let maximumRecords = 4096
  private let maximumRecordBytes = 1024 * 1024
  private let maximumStoreBytes = 64 * 1024 * 1024

  package init(directory: URL) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/") else { throw Self.unreadable("control-action directory must be absolute") }
    let path = Self.physicalPath(directory.path)
    let fd = try Self.openDirectory(path, create: true)
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
      Darwin.close(fd); throw Self.unreadable("control-action directory is not owner-private")
    }
    directoryPath = path; self.directory = fd; directoryIdentity = metadata
  }

  deinit { Darwin.close(directory) }

  package func begin(intent: HDCControlActionIntent, catalogDigest: String, runtimeEpoch: String, now: Date) throws -> HDCControlActionRecord {
    try transaction {
      let all = try records()
      if let existing = all.first(where: { $0.intent.actionRequestID == intent.actionRequestID }) {
        guard existing.intent == intent else { throw HDCControlValue.failure("idempotencyConflict", "action request identity already belongs to a different intent") }
        return existing
      }
      guard all.count < maximumRecords else { throw HDCControlValue.failure("operationUnavailable", "control-action record limit reached") }
      let record = try HDCControlActionRecord(intent: intent, catalogDigest: catalogDigest, runtimeEpoch: runtimeEpoch, now: now)
      try write(record, replacing: nil, all: all)
      return record
    }
  }

  package func load(actionID: String) throws -> HDCControlActionRecord? {
    guard HDCControlValue.identifier(actionID) else { throw HDCControlValue.failure("invalidInput", "invalid control-action identity") }
    return try transaction { try records().first { $0.actionID == actionID } }
  }

  package func load(requestID: String) throws -> HDCControlActionRecord? {
    guard HDCControlValue.identifier(requestID) else { throw HDCControlValue.failure("invalidInput", "invalid action request identity") }
    return try transaction { try records().first { $0.intent.actionRequestID == requestID } }
  }

  package func list() throws -> [HDCControlActionRecord] {
    try transaction {
      try records().sorted { left, right in
        left.createdAt == right.createdAt ? left.actionID.utf8.lexicographicallyPrecedes(right.actionID.utf8) : left.createdAt < right.createdAt
      }
    }
  }

  /// The complete new record must be the exact next generation of the same
  /// immutable request. Preview replacement is never a legal update.
  package func replace(_ record: HDCControlActionRecord, expectedGeneration: UInt64) throws {
    try transaction {
      let all = try records()
      guard let previous = all.first(where: { $0.actionID == record.actionID }),
        previous.generation == expectedGeneration, expectedGeneration < UInt64(Int64.max), record.generation == expectedGeneration + 1,
        previous.intent == record.intent, previous.createdAt == record.createdAt, previous.expiresAt == record.expiresAt,
        previous.runtimeEpoch == record.runtimeEpoch, previous.value["catalogDigest"] == record.value["catalogDigest"],
        previous.preview == nil || previous.preview == record.preview,
        previous.preview == nil || previous.value["observationRelations"] == record.value["observationRelations"],
        previous.humanAction == nil || Self.sameHumanAction(previous.humanAction, record.humanAction),
        record.interactionReceipt == nil
          || previous.interactionChallenge == record.interactionChallenge,
        previous.interactionReceipt == nil || previous.interactionReceipt == record.interactionReceipt,
        record.lifecycleAudit.starts(with: previous.lifecycleAudit),
        record.lifecycleAudit.count <= previous.lifecycleAudit.count + 1,
        let oldTime = HDCControlValue.time(previous.lastObservedAt), let newTime = HDCControlValue.time(record.lastObservedAt), newTime >= oldTime,
        Self.permitsTransition(from: previous.state, to: record.state)
      else { throw HDCControlValue.failure("resourceConflict", "control action changed or update replaces immutable facts") }
      try write(record, replacing: previous, all: all)
    }
  }

  private static func permitsTransition(from: String, to: String) -> Bool {
    switch from {
    case "observing": return ["previewReady", "blocked", "expired", "previewDrifted"].contains(to)
    case "previewReady": return ["awaitingImpactApproval", "expired", "previewDrifted"].contains(to)
    case "awaitingImpactApproval": return ["awaitingImpactApproval", "approvalRecorded", "expired", "previewDrifted"].contains(to)
    case "approvalRecorded": return ["approvalRecorded", "dispatchPrepared", "expired", "previewDrifted"].contains(to)
    case "dispatchPrepared": return ["dispatchPrepared", "dispatching", "failed"].contains(to)
    case "dispatching": return ["dispatching", "succeeded", "outcomeUnknown"].contains(to)
    case "blocked": return ["expired", "previewDrifted"].contains(to)
    default: return false
    }
  }

  private static func sameHumanAction(
    _ previous: HDCControlHumanAction?, _ next: HDCControlHumanAction?
  ) -> Bool {
    guard let previous, let next else { return false }
    return previous.value.filter { $0.key != "status" }
      == next.value.filter { $0.key != "status" }
      && (previous.status == next.status
        || previous.status == "waiting" && ["expired", "resolved"].contains(next.status))
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    processLock.lock(); defer { processLock.unlock() }
    try validateDirectory()
    let lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw Self.unreadable("control-action lock cannot be opened") }
    defer { Darwin.close(lock) }
    var metadata = stat()
    guard fstat(lock, &metadata) == 0, Self.privateFile(metadata), metadata.st_size == 0 else { throw Self.unreadable("unsafe control-action lock") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      throw HDCControlValue.failure("resourceConflict", "another Runtime owner holds the control-action transaction")
    }
    defer { flock(lock, LOCK_UN) }
    try validateDirectory()
    var named = stat()
    guard fstatat(directory, ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.sameFile(metadata, named) else { throw Self.unreadable("control-action lock identity changed") }
    let result = try body()
    try validateDirectory()
    guard fstatat(directory, ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.sameFile(metadata, named) else { throw Self.unreadable("control-action lock changed during transaction") }
    return result
  }

  private func validateDirectory() throws {
    let current = try Self.openDirectory(directoryPath, create: false); defer { Darwin.close(current) }
    var metadata = stat(), retained = stat()
    guard fstat(current, &metadata) == 0, fstat(directory, &retained) == 0,
      metadata.st_dev == directoryIdentity.st_dev, metadata.st_ino == directoryIdentity.st_ino,
      retained.st_dev == metadata.st_dev, retained.st_ino == metadata.st_ino,
      retained.st_uid == geteuid(), retained.st_mode & S_IFMT == S_IFDIR, retained.st_mode & 0o077 == 0
    else { throw Self.unreadable("control-action directory identity changed") }
  }

  private func records() throws -> [HDCControlActionRecord] {
    // Open a new file description: dup would share a directory offset with
    // earlier scans and could silently make records disappear from discovery.
    let scan = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard scan >= 0, let stream = fdopendir(scan) else {
      if scan >= 0 { Darwin.close(scan) }; throw Self.unreadable("control-action directory cannot be enumerated")
    }
    defer { closedir(stream) }
    var names: [String] = []
    var temporaryNames: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." || name == ".lock" { continue }
      if Self.temporaryName(name) { temporaryNames.append(name) }
      else if name.hasPrefix("action-"), name.hasSuffix(".json"), HDCControlValue.digest(String(name.dropFirst(7).dropLast(5))) { names.append(name) }
      else { throw Self.unreadable("unexpected content in control-action directory") }
      guard names.count <= maximumRecords, temporaryNames.count <= 8 else { throw Self.unreadable("control-action directory exceeds its bound") }
      errno = 0
    }
    guard errno == 0 else { throw Self.unreadable("control-action directory enumeration failed") }
    var total = 0
    var records: [HDCControlActionRecord] = []
    var identities: Set<String> = []
    for name in names.sorted() {
      let bytes = try read(name)
      total += bytes.count
      guard total <= maximumStoreBytes else { throw Self.unreadable("control-action store exceeds its byte bound") }
      let fields = try ControlFrameJSON.decodeObject(bytes, maximumBytes: maximumRecordBytes)
      let record = try HDCControlActionRecord(value: fields)
      guard name == filename(record.intent.actionRequestID), identities.insert(record.actionID).inserted else { throw Self.unreadable("control-action record name or identity is inconsistent") }
      records.append(record)
    }
    // A pre-rename temporary file is not a committed request. Remove only
    // exact private regular orphan files under this retained directory lock.
    for name in temporaryNames {
      var metadata = stat()
      guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, Self.privateFile(metadata), metadata.st_size <= maximumRecordBytes,
        unlinkat(directory, name, 0) == 0 else { throw Self.unreadable("unsafe interrupted control-action publication") }
    }
    if !temporaryNames.isEmpty { try Self.syncDirectory(directory) }
    return records
  }

  private func read(_ name: String) throws -> Data {
    let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw Self.unreadable("control-action record cannot be opened") }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, Self.privateFile(before), before.st_size > 0, before.st_size <= maximumRecordBytes else { throw Self.unreadable("control-action record has unsafe identity or size") }
    var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw Self.unreadable("control-action record read failed") }
      if count == 0 { break }
      bytes.append(contentsOf: buffer.prefix(count))
      guard bytes.count <= maximumRecordBytes else { throw Self.unreadable("control-action record grew beyond its bound") }
    }
    var after = stat(), named = stat()
    guard bytes.count == before.st_size, fstat(fd, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameFile(before, after), Self.sameFile(before, named),
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw Self.unreadable("control-action record changed while reading") }
    return bytes
  }

  private func write(_ record: HDCControlActionRecord, replacing: HDCControlActionRecord?, all: [HDCControlActionRecord]) throws {
    _ = try HDCControlActionRecord(value: record.value)
    let bytes = try PortableCanonicalJSON.canonicalBytes(.object(record.value))
    guard bytes.count <= maximumRecordBytes else { throw HDCControlValue.failure("inputTooLarge", "control-action record is too large") }
    var total = bytes.count
    for old in all where old.actionID != replacing?.actionID { total += try PortableCanonicalJSON.canonicalBytes(.object(old.value)).count }
    guard total <= maximumStoreBytes else { throw HDCControlValue.failure("operationUnavailable", "control-action store byte limit reached") }
    let name = filename(record.intent.actionRequestID)
    let temporary = ".\(name).\(UUID().uuidString.lowercased()).tmp"
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Self.unreadable("control-action temporary file cannot be created") }
    defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
    try DurableFilePrimitives.writeAll(bytes, descriptor: fd, path: temporary)
    try DurableFilePrimitives.fullSync(fd, path: temporary)
    try validateDirectory()
    guard renameat(directory, temporary, directory, name) == 0 else { throw Self.unreadable("control-action atomic publication failed") }
    try Self.syncDirectory(directory)
  }

  private func filename(_ request: String) -> String { "action-" + SHA256Hex.string(of: Data(request.utf8)) + ".json" }
  private static func unreadable(_ message: String) -> AgentExecutionControlFailure { HDCControlValue.failure("recordUnreadable", message) }
  private static func privateFile(_ metadata: stat) -> Bool {
    metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == geteuid() && metadata.st_nlink == 1 && metadata.st_mode & 0o077 == 0
  }
  private static func sameFile(_ a: stat, _ b: stat) -> Bool {
    privateFile(a) && privateFile(b) && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
  }
  private static func syncDirectory(_ descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else { throw unreadable("control-action namespace synchronization failed") }
  }
  private static func temporaryName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0].isEmpty, parts[1].hasPrefix("action-"),
      HDCControlValue.digest(String(parts[1].dropFirst(7))), parts[2] == "json", parts[4] == "tmp",
      let id = UUID(uuidString: String(parts[3])) else { return false }
    return id.uuidString.lowercased() == parts[3]
  }
  private static func physicalPath(_ path: String) -> String {
    for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") { return "/private" + path }
    return path
  }
  private static func openDirectory(_ path: String, create: Bool) throws -> Int32 {
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw unreadable("unsafe control-action directory components") }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw unreadable("cannot open control-action filesystem root") }
    do {
      for component in components {
        var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, errno == ENOENT, create {
          guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw unreadable("cannot create control-action directory") }
          try syncDirectory(fd)
          next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw unreadable("control-action directory is missing or symlinked") }
        Darwin.close(fd); fd = next
      }
      return fd
    } catch { Darwin.close(fd); throw error }
  }
}
