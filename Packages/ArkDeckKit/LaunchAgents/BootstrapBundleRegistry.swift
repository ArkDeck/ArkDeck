import ArkDeckCore
import Darwin
import Foundation

/// One current-user bootstrap store, usable before agentd exists. CLI, service
/// adapter and an App bridge must use this owner, never an App-container copy.
/// It holds content and references, not Runtime admission authority.
package final class BootstrapBundleRegistry {
  private typealias Files = BootstrapBundleFiles
  package enum ReferenceKind: String, Codable { case installation, rollback, controlAction, job, recovery }
  package struct ReferenceOwner: Codable, Equatable {
    package let kind: ReferenceKind
    package let id: String
    package init(kind: ReferenceKind, id: String) throws {
      guard AgentExecutionIntent.validIdentifier(id) else { throw Files.failure("invalidInput", "invalid bundle reference owner") }
      self.kind = kind; self.id = id
    }
  }
  private struct Record: Codable {
    let reference: String, digest: String, registeredAtUTC: String, version: String?
    let byteCount: Int64, entryCount: Int
    var generation: UInt64, state: String, references: [ReferenceOwner]
    var value: JSONValue {
      .object([
        "schemaVersion": .string("arkdeck.runtime-bundle/1"), "bundleRef": .string(reference),
        "kind": .string("daemon-bundle"), "platform": .string("macos"),
        "generation": .string(String(generation)), "state": .string(state),
        "contentDigest": .string(digest), "digestAlgorithm": .string("sha256-jcs"),
        "contentSchemaVersion": .string("arkdeck.bundle-content/1"),
        "byteCount": .string(String(byteCount)), "entryCount": .string(String(entryCount)),
        "registeredAtUTC": .string(registeredAtUTC), "version": version.map(JSONValue.string) ?? .null,
        "trust": .object(["policy": .string("arkdeck.daemon-helper/1"), "signature": .string("verified"),
          "teamIdentifier": .string(ArkDeckHelperIdentity.teamIdentifier),
          "executionAssessment": .string("notPerformed")]),
        "references": .array(references.map { .object(["kind": .string($0.kind.rawValue), "id": .string($0.id)]) }),
        "contentRetained": .bool(true),
      ])
    }
  }
  private struct Index: Codable {
    var schemaVersion = "arkdeck.bootstrap-bundles/1"
    var records: [Record] = []
  }
  private let root: URL
  private let validateBundle: (URL) throws -> Void
  private let fault: (String) throws -> Void
  private let nowUTC: () -> String

  package convenience init() throws {
    // getpwuid_r deliberately ignores HOME and App Sandbox's container home.
    // A sandboxed caller without the shared bridge fails, rather than creating
    // a second registry that disagrees with the CLI/service owner.
    var record = passwd(), resolved: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    let code = getpwuid_r(geteuid(), &record, &buffer, buffer.count, &resolved)
    guard code == 0, resolved != nil, let home = record.pw_dir,
      let path = String(validatingCString: home), path.hasPrefix("/") else {
      throw Files.failure("runtimeUnavailable", "current-user bootstrap home is unavailable")
    }
    self.init(root: URL(filePath: path).appending(path: "Library/Application Support/ArkDeck/Bootstrap/v1"))
  }

  package init(root: URL, validateBundle: ((URL) throws -> Void)? = nil,
    fault: @escaping (String) throws -> Void = { _ in },
    nowUTC: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
    self.root = root
    self.validateBundle = validateBundle ?? { candidate in
      _ = try LaunchAgentService.validateProductionDaemonBundle(candidate, fileManager: .default)
    }
    self.fault = fault; self.nowUTC = nowUTC
  }

  /// Registration publishes immutable content before the durable record. A
  /// crash can leave an unreferenced private bundle, never a dangling receipt.
  /// Retrying the same exact content discovers the same reference/generation.
  package func register(file: URL) throws -> JSONValue {
    try locked { directory in
      var index = try readIndex(directory)
      // Count private orphan/staging content too: interrupted registrations
      // must not evade the quota merely because they have no index record.
      let retained = try retainedBytes(directory)
      let source = try Files.openDirectory(file)
      defer { close(source) }
      guard file.pathExtension == "app" else { throw Files.failure("invalidInput", "daemon-bundle registration requires an app bundle") }
      let stageName = ".staging-\(UUID().uuidString.lowercased()).app"
      guard mkdirat(directory, stageName, 0o700) == 0 else { throw Files.failure("cannot create bundle staging directory") }
      let stageURL = root.appending(path: stageName)
      let stage = openat(directory, stageName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard stage >= 0 else { throw Files.failure("cannot open bundle staging directory") }
      defer { close(stage) }
      var published = false
      defer { if !published { try? Files.removeStaging(stageName, from: directory, expected: stage) } }
      let copied = try Files.scan(source, copyingTo: stage)
      try fault("copied")
      try Files.requireLinkedDirectory(source, url: file)
      let sourceReadback = try Files.scan(source)
      guard sourceReadback == copied else { throw Files.failure("bundle source changed after copy") }
      try Files.requireLinkedDirectory(stage, url: stageURL)
      let beforeTrust = try Files.scan(stage)
      guard beforeTrust.entries == copied.entries else { throw Files.failure("private bundle copy differs from source") }
      let bundleVersion = try version(at: stage)
      try validateBundle(stageURL)
      let staged = try Files.scan(stage)
      guard staged == beforeTrust else { throw Files.failure("private bundle identity changed during trust validation") }
      try Files.requireLinkedDirectory(source, url: file)
      guard try Files.scan(source) == copied else { throw Files.failure("bundle source changed during trust validation") }
      let digest = try staged.digest
      let reference = "bundle:sha256:" + digest
      if let existing = index.records.first(where: { $0.reference == reference }) {
        guard existing.state == "available" else { throw Files.failure("resourceConflict", "this exact bundle was removed; its historical content is retained") }
        try verify(existing, directory: directory)
        return existing.value
      }
      let record = Record(reference: reference, digest: digest, registeredAtUTC: nowUTC(),
        version: bundleVersion, byteCount: copied.byteCount, entryCount: copied.entries.count,
        generation: 1, state: "available", references: [])
      let name = contentName(record)
      var orphan = stat()
      let exists = fstatat(directory, name, &orphan, AT_SYMLINK_NOFOLLOW) == 0
      if exists { try verify(record, directory: directory) }
      else if errno != ENOENT { throw Files.failure("ioFailure", "cannot inspect bundle publication destination") }
      // An exact orphan is already included in retainedBytes. Counting it a
      // second time would make a lost receipt unrecoverable at the quota.
      guard index.records.count < 128, retained <= 2 * Files.maximumBytes - (exists ? 0 : copied.byteCount) else {
        throw Files.failure("quotaExceeded", "registered bundle content exceeds the bootstrap quota")
      }
      try Files.requireLinkedDirectory(directory, url: root)
      try fault("beforeContentPublication")
      if renameatx_np(directory, stageName, directory, name, UInt32(RENAME_EXCL)) != 0 {
        guard errno == EEXIST else { throw Files.failure("cannot publish immutable bundle content") }
        // Only an exact, fully revalidated orphan from a lost previous receipt
        // can be adopted. Never replace bytes at an existing reference.
        try verify(record, directory: directory)
      } else { published = true }
      try Files.sync(directory)
      try fault("contentPublished")
      try verify(record, directory: directory)
      index.records.append(record)
      index.records.sort { $0.reference < $1.reference }
      try saveIndex(index, directory)
      do { try fault("recordPublished") }
      catch { throw Files.failure("outcomeUnknown", "bundle record is published but its receipt was interrupted; inspect or register the exact content again") }
      return record.value
    }
  }

  package func inspect(_ reference: String) throws -> JSONValue {
    try locked { directory in
      let record = try find(reference, in: readIndex(directory))
      try verify(record, directory: directory)
      return record.value
    }
  }

  /// The existing snapshot pager runs while this same cross-process lock is
  /// held, including retention. Its immutable pages survive later removals.
  package func list<T>(_ render: (URL, [JSONValue]) throws -> T) throws -> T {
    try locked { directory in
      let index = try readIndex(directory)
      for record in index.records { try verify(record, directory: directory) }
      return try render(root.appending(path: "bundle-snapshots"), index.records.map(\.value))
    }
  }

  package func remove(_ reference: String, expectedGeneration: String) throws -> JSONValue {
    try locked { directory in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard expectedGeneration == "1" else { throw Files.failure("resourceConflict", "bundle generation does not match") }
      try verify(record, directory: directory)
      if record.state == "removed" { return record.value }
      guard record.references.isEmpty else { throw Files.failure("resourceConflict", "bundle is retained by an installation, rollback, pending action or Runtime owner") }
      record.state = "removed"; record.generation = 2
      index.records[index.records.firstIndex(where: { $0.reference == reference })!] = record
      try saveIndex(index, directory)
      return record.value
    }
  }

  /// Only trusted product owners call this API. Acquiring a durable reference
  /// and remove serialize on the same lock. Acquire precedes external intent;
  /// interruption leaves a pin that must be reconciled, not guessed away.
  package func acquire(_ reference: String, expectedGeneration: String, owner: ReferenceOwner) throws -> URL {
    try locked { directory in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard record.state == "available", expectedGeneration == String(record.generation) else {
        throw Files.failure("resourceConflict", "bundle is removed or its generation changed")
      }
      try verify(record, directory: directory)
      if !record.references.contains(owner) {
        guard record.references.count < 1024 else { throw Files.failure("quotaExceeded", "bundle reference bound reached") }
        record.references.append(owner)
        record.references.sort { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        index.records[index.records.firstIndex(where: { $0.reference == reference })!] = record
        try saveIndex(index, directory)
      }
      return root.appending(path: contentName(record))
    }
  }

  package func release(_ reference: String, owner: ReferenceOwner) throws {
    try locked { directory in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      try verify(record, directory: directory)
      record.references.removeAll { $0 == owner }
      index.records[index.records.firstIndex(where: { $0.reference == reference })!] = record
      try saveIndex(index, directory)
    }
  }

  private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
    let directory = try Files.openDirectory(root, create: true, privateLeaf: true)
    defer { close(directory) }
    let lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard lock >= 0 else { throw Files.failure("recordUnreadable", "cannot open bootstrap owner lock") }
    defer { close(lock) }
    let identity = try Files.status(lock)
    guard identity.st_mode & S_IFMT == S_IFREG, identity.st_nlink == 1,
      identity.st_uid == geteuid(), identity.st_mode & 0o077 == 0 else {
      throw Files.failure("recordUnreadable", "bootstrap owner lock is unsafe")
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Files.failure("resourceConflict", "another bootstrap operation holds the store; retry after it completes") }
    defer { flock(lock, LOCK_UN) }
    try Files.requireLinkedDirectory(directory, url: root)
    var linked = stat()
    guard fstatat(directory, ".lock", &linked, AT_SYMLINK_NOFOLLOW) == 0,
      identity.st_dev == linked.st_dev, identity.st_ino == linked.st_ino else { throw Files.failure("bootstrap lock was replaced") }
    let output = try body(directory)
    try Files.requireLinkedDirectory(directory, url: root)
    return output
  }

  private func contentName(_ record: Record) -> String { "bundle-\(record.digest).app" }

  private func retainedBytes(_ directory: Int32) throws -> Int64 {
    let names = try Files.names(directory)
    guard names.count <= 140 else { throw Files.failure("quotaExceeded", "bootstrap directory entry bound reached") }
    var bytes: Int64 = 0, stagingCount = 0
    for name in names where name.hasPrefix("bundle-") && name.hasSuffix(".app") || name.hasPrefix(".staging-") {
      if name.hasPrefix(".staging-") { stagingCount += 1 }
      guard stagingCount < 4 else { throw Files.failure("quotaExceeded", "interrupted bootstrap staging requires inspection before more registration") }
      let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard child >= 0 else { throw Files.failure("recordUnreadable", "retained bootstrap content is unsafe") }
      defer { close(child) }
      bytes += try Files.scan(child).byteCount
      guard bytes <= 2 * Files.maximumBytes else { throw Files.failure("quotaExceeded", "retained bundle content exceeds the bootstrap quota") }
    }
    return bytes
  }
  private func find(_ reference: String, in index: Index) throws -> Record {
    guard reference.hasPrefix("bundle:sha256:"), reference.count == 78,
      reference.dropFirst(14).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw Files.failure("invalidInput", "expected a content-addressed daemon bundle reference")
    }
    guard let record = index.records.first(where: { $0.reference == reference }) else { throw Files.failure("resourceNotFound", "bundle reference does not exist") }
    return record
  }

  private func verify(_ record: Record, directory: Int32) throws {
    let name = contentName(record)
    let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw Files.failure("recordUnreadable", "registered bundle content is missing or symbolic") }
    defer { close(fd) }
    let before = try Files.scan(fd)
    guard try before.digest == record.digest, before.byteCount == record.byteCount, before.entries.count == record.entryCount else {
      throw Files.failure("recordUnreadable", "registered bundle content failed integrity validation")
    }
    let url = root.appending(path: name)
    try Files.requireLinkedDirectory(fd, url: url)
    guard try version(at: fd) == record.version else { throw Files.failure("recordUnreadable", "registered bundle version changed") }
    try validateBundle(url)
    guard try Files.scan(fd) == before, try version(at: fd) == record.version else {
      throw Files.failure("recordUnreadable", "registered bundle changed during trust validation")
    }
    try Files.requireLinkedDirectory(fd, url: url)
  }

  private func version(at directory: Int32) throws -> String? {
    let contents = openat(directory, "Contents", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard contents >= 0 else { throw Files.failure("invalidInput", "bundle Contents directory is missing") }
    defer { close(contents) }
    let fd = openat(contents, "Info.plist", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw Files.failure("invalidInput", "bundle Info.plist is missing") }
    defer { close(fd) }
    guard try Files.status(fd).st_mode & S_IFMT == S_IFREG else { throw Files.failure("invalidInput", "bundle Info.plist must be a regular file") }
    let bytes = try Files.read(fd, maximum: 64 * 1024)
    guard let info = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any] else {
      throw Files.failure("invalidInput", "bundle Info.plist must contain a property-list dictionary")
    }
    guard let rawVersion = info["CFBundleShortVersionString"] else { return nil }
    guard let text = rawVersion as? String else { throw Files.failure("invalidInput", "bundle version must be a string") }
    guard !text.isEmpty, text.utf8.count <= 128, text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
      throw Files.failure("invalidInput", "bundle version is outside the bounded schema")
    }
    return text
  }

  private func readIndex(_ directory: Int32) throws -> Index {
    let fd = openat(directory, "bundles.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT {
      // An empty index is durable before the first staging copy. A missing
      // index beside retained bytes could have contained live dependencies;
      // it is corruption, never an empty inventory or adoptable orphan.
      guard try Files.names(directory).filter({ $0 != ".lock" }).isEmpty else {
        throw Files.failure("recordUnreadable", "bundle index is missing beside retained bootstrap state")
      }
      let initial = Index()
      try saveIndex(initial, directory)
      return initial
    }
    guard fd >= 0 else { throw Files.failure("recordUnreadable", "bundle index cannot be opened") }
    defer { close(fd) }
    let before = try Files.status(fd)
    guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
      before.st_mode & 0o077 == 0 else { throw Files.failure("recordUnreadable", "bundle index is unsafe") }
    do {
      let data = try Files.read(fd, maximum: Files.maximumMetadataBytes)
      guard Files.Identity(try Files.status(fd)) == Files.Identity(before) else { throw Files.failure("bundle index changed") }
      let raw = try ControlProtocolNegotiation.decodeObject(data, maximumBytes: Files.maximumMetadataBytes)
      let index = try JSONDecoder().decode(Index.self, from: data)
      let roundtrip = try ControlProtocolNegotiation.decodeObject(CanonicalJSONEncoders.canonical().encode(index), maximumBytes: Files.maximumMetadataBytes)
      guard raw == roundtrip, index.schemaVersion == "arkdeck.bootstrap-bundles/1", index.records.count <= 128,
        index.records.map(\.reference) == index.records.map(\.reference).sorted(),
        Set(index.records.map(\.reference)).count == index.records.count else { throw Files.failure("invalid registry schema") }
      for record in index.records {
        _ = try find(record.reference, in: index)
        guard record.reference == "bundle:sha256:" + record.digest,
          record.byteCount >= 0, record.byteCount <= Files.maximumBytes,
          (1...Files.maximumEntries).contains(record.entryCount),
          record.registeredAtUTC.utf8.count <= 32, ISO8601DateFormatter().date(from: record.registeredAtUTC) != nil,
          record.version.map({ !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) }) ?? true,
          (record.state == "available" && record.generation == 1) || (record.state == "removed" && record.generation == 2 && record.references.isEmpty),
          record.references.count <= 1024, Set(record.references.map { $0.kind.rawValue + ":" + $0.id }).count == record.references.count,
          record.references.allSatisfy({ AgentExecutionIntent.validIdentifier($0.id) }) else { throw Files.failure("invalid bundle record") }
      }
      return index
    } catch { throw Files.failure("recordUnreadable", "bundle index failed bounded schema and identity validation") }
  }

  private func saveIndex(_ index: Index, _ directory: Int32) throws {
    let data = try CanonicalJSONEncoders.canonical().encode(index)
    guard data.count <= Files.maximumMetadataBytes else { throw Files.failure("quotaExceeded", "bundle index exceeds its bound") }
    let name = ".index-\(UUID().uuidString.lowercased())"
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Files.failure("recordUnreadable", "cannot create bundle index transaction") }
    defer { close(fd); unlinkat(directory, name, 0) }
    try Files.write(data, to: fd); try Files.sync(fd)
    try Files.requireLinkedDirectory(directory, url: root)
    guard renameat(directory, name, directory, "bundles.json") == 0 else { throw Files.failure("recordUnreadable", "cannot commit bundle index") }
    do { try Files.sync(directory) }
    catch { throw Files.failure("outcomeUnknown", "bundle index was published but durability is unconfirmed; inspect the exact reference") }
  }
}
