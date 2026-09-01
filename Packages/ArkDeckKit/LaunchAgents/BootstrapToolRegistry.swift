import ArkDeckCore
import Darwin
import Foundation

/// Typed HDC candidates in the same bootstrap owner as daemon bundles.
/// Registration copies and inspects bytes. Only a published HDC identity may
/// be resolved for execution, and this store never changes active selection.
package final class BootstrapToolRegistry {
  private typealias Files = BootstrapBundleFiles
  package typealias ReferenceOwner = BootstrapBundleRegistry.ReferenceOwner
  private static let maximumToolBytes = BootstrapToolFiles.maximumBytes
  private let owner: BootstrapBundleRegistry
  private let inspectTrust: (URL) throws -> BootstrapToolTrust
  private let fault: (String) throws -> Void
  private let nowUTC: () -> String
  private let knownIdentity: (String) -> PublishedIdentity?

  private struct Record: Codable {
    let reference: String, contentDigest: String, executableSHA256: String, registeredAt: String
    let byteCount: Int64
    let quarantineSHA256: String?
    let trust: BootstrapToolTrust
    let dependencies: [BootstrapToolFiles.Dependency]
    let relocatable: Bool
    var generation: Int, state: String, references: [ReferenceOwner]

    func value(identity: PublishedIdentity?) -> JSONValue {
      .object([
        "schemaVersion": .string("arkdeck.runtime-tool/1"), "toolRef": .string(reference),
        "kind": .string("hdc"), "platform": .string("macos"), "source": .string("registeredCopy"),
        "generation": .string(String(generation)), "state": .string(state),
        "contentDigest": .string(contentDigest), "digestAlgorithm": .string("sha256-jcs"),
        "contentSchemaVersion": .string("arkdeck.tool-content/1"),
        "executableSHA256": .string(executableSHA256), "byteCount": .string(String(byteCount)),
        "quarantineSHA256": quarantineSHA256.map(JSONValue.string) ?? .null,
        "registeredAt": .string(registeredAt), "trust": trust.projection(identity: identity),
        "dependencies": .array(dependencies.map(\.value)),
        "dependencyLayout": .string("hdc-sibling-libusb/1"), "relocatable": .bool(relocatable),
        "selected": .bool(references.contains { $0.kind == .activeSelection }),
        "references": .array(references.map { .object(["kind": .string($0.kind.rawValue), "id": .string($0.id)]) }),
        "contentRetained": .bool(true),
      ])
    }
  }
  private struct Index: Codable {
    var schemaVersion = "arkdeck.bootstrap-tools/1"
    var records: [Record] = []
  }
  /// Diagnostic metadata supplied by the existing Provider composition. A
  /// registration layer cannot create a Provider support declaration.
  package struct PublishedIdentity: Equatable {
    package let version: String
    package let profileReferences: [String]
    package init(version: String, profileReferences: [String]) {
      self.version = version; self.profileReferences = profileReferences
    }
  }

  /// An immutable content manifest, not executable passthrough or dispatch
  /// authority. Runtime consumption must retain/revalidate the directory,
  /// executable and every dependency through its identity-bound Process path.
  package struct ResolvedHDC {
    package let executableURL: URL
    package let executableSHA256: String
    package let dependencies: [BootstrapToolFiles.Dependency]
  }

  package convenience init(knownIdentity: @escaping (String) -> PublishedIdentity? = { _ in nil }) throws {
    self.init(owner: try BootstrapBundleRegistry(), knownIdentity: knownIdentity)
  }
  package init(owner: BootstrapBundleRegistry,
    knownIdentity: @escaping (String) -> PublishedIdentity? = { _ in nil },
    inspectTrust: @escaping (URL) throws -> BootstrapToolTrust = BootstrapToolTrust.inspect,
    fault: @escaping (String) throws -> Void = { _ in },
    nowUTC: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
    self.owner = owner; self.inspectTrust = inspectTrust; self.fault = fault; self.nowUTC = nowUTC; self.knownIdentity = knownIdentity
  }

  package func register(file: URL) throws -> JSONValue {
    try owner.withSharedStore { directory, root in
      var index = try readIndex(directory)
      let retained = try retainedBytes(directory)
      let stagedName = ".tool-staging-\(UUID().uuidString.lowercased())"
      guard mkdirat(directory, stagedName, 0o700) == 0 else { throw Files.failure("ioFailure", "cannot create private host tool directory") }
      let staged = openat(directory, stagedName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard staged >= 0 else { throw Files.failure("ioFailure", "cannot open private host tool directory") }
      defer { close(staged) }
      var published = false
      defer { if !published { try? Files.removeStaging(stagedName, from: directory, expected: staged) } }
      let content = try BootstrapToolFiles.capture(file: file, into: staged, at: root.appending(path: stagedName),
        inspectTrust: inspectTrust, fault: fault)
      let reference = "tool:sha256:" + content.digest
      if let old = index.records.first(where: { $0.reference == reference }) {
        guard old.state == "available" else { throw Files.failure("resourceConflict", "this exact tool is retired; historical bytes remain retained") }
        try verify(old, directory: directory, root: root)
        return value(old)
      }
      let record = Record(reference: reference, contentDigest: content.digest, executableSHA256: content.sha256,
        registeredAt: nowUTC(), byteCount: content.byteCount, quarantineSHA256: content.quarantineSHA256,
        trust: content.trust, dependencies: content.dependencies, relocatable: content.relocatable,
        generation: 1, state: "available", references: [])
      var status = stat()
      let name = filename(record)
      let exists = fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0
      if exists { try verify(record, directory: directory, root: root) }
      else if errno != ENOENT { throw Files.failure("ioFailure", "cannot inspect tool publication destination") }
      guard index.records.count < 128, retained <= 2 * Files.maximumBytes - (exists ? 0 : content.byteCount) else {
        throw Files.failure("quotaExceeded", "registered host tools exceed the bootstrap quota")
      }
      try Files.requireLinkedDirectory(directory, url: root)
      try fault("beforeContentPublication")
      if renameatx_np(directory, stagedName, directory, name, UInt32(RENAME_EXCL)) != 0 {
        guard errno == EEXIST else { throw Files.failure("ioFailure", "cannot publish immutable host tool content") }
        try verify(record, directory: directory, root: root)
      } else { published = true }
      try Files.sync(directory)
      try fault("contentPublished")
      try verify(record, directory: directory, root: root)
      index.records.append(record); index.records.sort { $0.reference < $1.reference }
      try saveIndex(index, directory: directory, root: root)
      do { try fault("recordPublished") }
      catch { throw Files.failure("outcomeUnknown", "host tool record was published but its receipt was interrupted; inspect or register the same content") }
      return value(record)
    }
  }

  package func inspect(_ reference: String) throws -> JSONValue {
    try owner.withSharedStore { directory, root in
      let record = try find(reference, in: readIndex(directory))
      try verify(record, directory: directory, root: root)
      return value(record)
    }
  }

  package func list<T>(_ render: (URL, [JSONValue]) throws -> T) throws -> T {
    try owner.withSharedStore { directory, root in
      let index = try readIndex(directory)
      for record in index.records { try verify(record, directory: directory, root: root) }
      return try render(root.appending(path: "tool-snapshots"), index.records.map(value))
    }
  }

  package func remove(_ reference: String, expectedGeneration: String) throws -> JSONValue {
    try owner.withSharedStore { directory, root in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard expectedGeneration == "1" else { throw Files.failure("resourceConflict", "host tool generation does not match") }
      try verify(record, directory: directory, root: root)
      if record.state == "removed" { return value(record) }
      guard record.references.isEmpty else {
        throw Files.failure("resourceConflict", "tool is selected or retained by an installation, Job, execution, recovery, action or lease")
      }
      record.state = "removed"; record.generation = 2
      replace(record, in: &index); try saveIndex(index, directory: directory, root: root)
      return value(record)
    }
  }

  /// A pin protects storage; it does not establish tool trust or grant device
  /// authority. No public CLI command can acquire or release these references.
  package func acquire(_ reference: String, expectedGeneration: String, owner dependency: ReferenceOwner) throws -> JSONValue {
    try owner.withSharedStore { directory, root in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard record.state == "available", expectedGeneration == String(record.generation) else {
        throw Files.failure("resourceConflict", "tool is retired or its generation changed")
      }
      try verify(record, directory: directory, root: root)
      if !record.references.contains(dependency) {
        guard record.references.count < 1024 else { throw Files.failure("quotaExceeded", "tool reference bound reached") }
        record.references.append(dependency)
        record.references.sort { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        replace(record, in: &index); try saveIndex(index, directory: directory, root: root)
      }
      return value(record)
    }
  }

  package func release(_ reference: String, owner dependency: ReferenceOwner) throws {
    try owner.withSharedStore { directory, root in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      try verify(record, directory: directory, root: root)
      record.references.removeAll { $0 == dependency }
      replace(record, in: &index); try saveIndex(index, directory: directory, root: root)
    }
  }

  /// This is the only path-returning tool API. The exact durable consumer pin
  /// and published HDC identity are both required; an arbitrary Mach-O file
  /// registered for inspection can never become executable passthrough.
  package func resolveHDC(_ reference: String, expectedGeneration: String, owner dependency: ReferenceOwner) throws -> ResolvedHDC {
    try owner.withSharedStore { directory, root in
      let record = try find(reference, in: readIndex(directory))
      guard record.state == "available", expectedGeneration == String(record.generation), record.references.contains(dependency) else {
        throw Files.failure("resourceConflict", "tool execution requires an exact durable consumer reference")
      }
      try verify(record, directory: directory, root: root)
      guard record.relocatable, knownIdentity(record.executableSHA256) != nil else {
        throw Files.failure("operationUnavailable", "candidate has no published HDC executable identity; registration did not grant execution support")
      }
      return ResolvedHDC(executableURL: root.appending(path: filename(record)).appending(path: "hdc"),
        executableSHA256: record.executableSHA256, dependencies: record.dependencies)
    }
  }

  private func value(_ record: Record) -> JSONValue {
    record.value(identity: knownIdentity(record.executableSHA256))
  }
  private func filename(_ record: Record) -> String { "tool-\(record.contentDigest).hdc" }
  private func replace(_ record: Record, in index: inout Index) {
    index.records[index.records.firstIndex { $0.reference == record.reference }!] = record
  }
  private func find(_ reference: String, in index: Index) throws -> Record {
    guard reference.hasPrefix("tool:sha256:"), BootstrapToolTrust.digest(String(reference.dropFirst(12))) else {
      throw Files.failure("invalidInput", "expected a content-addressed HDC tool reference")
    }
    guard let record = index.records.first(where: { $0.reference == reference }) else { throw Files.failure("resourceNotFound", "tool reference does not exist") }
    return record
  }

  private func verify(_ record: Record, directory: Int32, root: URL) throws {
    do {
      let contentURL = root.appending(path: filename(record))
      let fd = try Files.openDirectory(contentURL, privateLeaf: true); defer { close(fd) }
      let measured = try BootstrapToolFiles.inspect(fd, at: contentURL, inspectTrust: inspectTrust)
      guard measured.digest == record.contentDigest, measured.sha256 == record.executableSHA256,
        measured.byteCount == record.byteCount, measured.quarantineSHA256 == record.quarantineSHA256,
        measured.trust == record.trust, measured.dependencies == record.dependencies, measured.relocatable == record.relocatable else {
        throw Files.failure("registered host tool content or dependency changed")
      }
      try Files.requireLinkedDirectory(directory, url: root)
    } catch { throw Files.failure("recordUnreadable", "registered host tool failed content, identity or trust validation") }
  }

  private func retainedBytes(_ directory: Int32) throws -> Int64 {
    let names = try Files.names(directory)
    guard names.count <= 300 else { throw Files.failure("quotaExceeded", "bootstrap entry bound reached") }
    var bytes: Int64 = 0, interrupted = 0
    for name in names where (name.hasPrefix("tool-") && name.hasSuffix(".hdc")) || name.hasPrefix(".tool-staging-") {
      if name.hasPrefix(".tool-staging-") { interrupted += 1 }
      guard interrupted < 4 else { throw Files.failure("quotaExceeded", "interrupted tool copies require inspection before more registration") }
      let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Files.failure("recordUnreadable", "retained host tool cannot be read safely") }
      defer { close(fd) }
      let status = try Files.status(fd)
      guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
        throw Files.failure("recordUnreadable", "retained host tool is unsafe")
      }
      let retained = try Files.scan(fd)
      guard retained.entries.count <= 3, retained.byteCount <= Self.maximumToolBytes else {
        throw Files.failure("recordUnreadable", "retained host tool exceeds its content bounds")
      }
      bytes += retained.byteCount
      guard bytes <= 2 * Files.maximumBytes else { throw Files.failure("quotaExceeded", "host tool retention quota reached") }
    }
    return bytes
  }

  private func readIndex(_ directory: Int32) throws -> Index {
    let fd = openat(directory, "tools.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT {
      let names = try Files.names(directory)
      guard !names.contains(where: { $0.hasPrefix("tool-") || $0.hasPrefix(".tool-") }) else {
        throw Files.failure("recordUnreadable", "tool index is missing beside retained tool state")
      }
      let initial = Index()
      try saveIndex(initial, directory: directory, root: nil)
      return initial
    }
    guard fd >= 0 else { throw Files.failure("recordUnreadable", "tool index cannot be opened") }
    defer { close(fd) }
    do {
      let before = try Files.status(fd)
      guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0 else {
        throw Files.failure("tool index ownership or permissions are unsafe")
      }
      let data = try Files.read(fd, maximum: Files.maximumMetadataBytes)
      guard Files.Identity(try Files.status(fd)) == Files.Identity(before) else { throw Files.failure("tool index changed while reading") }
      let raw = try ControlProtocolNegotiation.decodeObject(data, maximumBytes: Files.maximumMetadataBytes)
      let index = try JSONDecoder().decode(Index.self, from: data)
      let roundtrip = try ControlProtocolNegotiation.decodeObject(CanonicalJSONEncoders.canonical().encode(index), maximumBytes: Files.maximumMetadataBytes)
      guard raw == roundtrip, index.schemaVersion == "arkdeck.bootstrap-tools/1", index.records.count <= 128,
        index.records.map(\.reference) == index.records.map(\.reference).sorted(), Set(index.records.map(\.reference)).count == index.records.count else {
        throw Files.failure("tool index schema is invalid")
      }
      for record in index.records {
        _ = try find(record.reference, in: index)
        guard record.reference == "tool:sha256:" + record.contentDigest, BootstrapToolTrust.digest(record.executableSHA256),
          record.quarantineSHA256.map(BootstrapToolTrust.digest) ?? true,
          record.byteCount > 0, record.byteCount <= Self.maximumToolBytes, record.trust.isWellFormed,
          record.dependencies.count <= 1, record.dependencies.allSatisfy(\.isWellFormed),
          record.registeredAt.utf8.count <= 32, ISO8601DateFormatter().date(from: record.registeredAt) != nil,
          (record.state == "available" && record.generation == 1) || (record.state == "removed" && record.generation == 2 && record.references.isEmpty),
          record.references.count <= 1024, Set(record.references.map { $0.kind.rawValue + ":" + $0.id }).count == record.references.count,
          record.references.allSatisfy({ AgentExecutionIntent.validIdentifier($0.id) }) else { throw Files.failure("tool record is invalid") }
      }
      return index
    } catch { throw Files.failure("recordUnreadable", "tool index failed bounded schema and identity validation") }
  }

  private func saveIndex(_ index: Index, directory: Int32, root: URL?) throws {
    let bytes = try CanonicalJSONEncoders.canonical().encode(index)
    guard bytes.count <= Files.maximumMetadataBytes else { throw Files.failure("quotaExceeded", "tool index exceeds its bounded storage") }
    let name = ".tool-index-\(UUID().uuidString.lowercased())"
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Files.failure("ioFailure", "cannot create tool index transaction") }
    defer { close(fd); unlinkat(directory, name, 0) }
    try Files.write(bytes, to: fd); try Files.sync(fd)
    if let root { try Files.requireLinkedDirectory(directory, url: root) }
    guard renameat(directory, name, directory, "tools.json") == 0 else { throw Files.failure("ioFailure", "cannot publish tool index") }
    do { try Files.sync(directory) }
    catch { throw Files.failure("outcomeUnknown", "host tool index was published but durable completion is unconfirmed") }
  }
}
