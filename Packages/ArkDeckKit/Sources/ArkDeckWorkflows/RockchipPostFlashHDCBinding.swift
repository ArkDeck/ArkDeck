import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

/// Runtime-owned routing proof established only after a flashed DAYU200 has
/// returned over HDC and reported the exact published model/build. Firmware
/// may change the HDC serial while the Loader identity stays stable, so the
/// original adoption connect key cannot be treated as a permanent address.
package struct RockchipPostFlashHDCBinding: Codable, Sendable, Equatable {
  package static let currentSchemaVersion = "1.0.0"

  package let schemaVersion: String
  package let targetID: String
  package let bindingRevision: Int
  package let stableLoaderIdentitySHA256: String
  package let previousHDCIdentitySHA256: String
  package let hdcIdentitySHA256: String
  package let hdcConnectKey: String
  package let usbTopology: String
  package let productModel: String
  package let buildVersion: String
  package let jobID: String
  package let establishedAtUTC: String

  package init(
    targetID: String,
    bindingRevision: Int,
    stableLoaderIdentitySHA256: String,
    previousHDCIdentitySHA256: String,
    hdcIdentitySHA256: String,
    hdcConnectKey: String,
    usbTopology: String,
    productModel: String,
    buildVersion: String,
    jobID: String,
    establishedAtUTC: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableLoaderIdentitySHA256 = stableLoaderIdentitySHA256
    self.previousHDCIdentitySHA256 = previousHDCIdentitySHA256
    self.hdcIdentitySHA256 = hdcIdentitySHA256
    self.hdcConnectKey = hdcConnectKey
    self.usbTopology = usbTopology
    self.productModel = productModel
    self.buildVersion = buildVersion
    self.jobID = jobID
    self.establishedAtUTC = establishedAtUTC
  }

  package func covers(
    target: RuntimeTargetRecord,
    binding: RockchipProductBindingSnapshot
  ) throws -> Bool {
    guard target.targetID == targetID,
      target.bindingRevision == bindingRevision,
      target.stablePhysicalIdentitySHA256 == stableLoaderIdentitySHA256,
      try binding.coversRuntimeTarget(target)
    else { return false }
    return true
  }
}

/// Owner-only, fail-closed store for the post-flash HDC alias. The raw HDC
/// connect key never leaves this product boundary; App projections receive
/// only target ID, revision, mode and disposition.
package struct RockchipPostFlashHDCBindingStore: Sendable {
  package static let fileName = "rockchip-post-flash-hdc-binding.json"
  private static let lockName = ".rockchip-post-flash-hdc-binding.lock"
  private static let maximumBytes = 64 * 1_024

  private let rootURL: URL

  package init(rootURL: URL) {
    self.rootURL = rootURL
  }

  package func loadIfPresent() throws -> RockchipPostFlashHDCBinding? {
    try prepareRoot()
    let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw failure("post-flash binding root cannot be opened") }
    defer { Darwin.close(root) }
    return try load(rootDescriptor: root)
  }

  /// Publishes one exact verified alias. Repeating the same proof is
  /// idempotent.
  ///
  /// What stops a stale Job rotating a newer route is the else-branch below,
  /// whose fourth conjunct compares the *store's* current alias against
  /// `expectedPreviousHDCIdentitySHA256`. The guard immediately following this
  /// comment is not a second line of defence and must not be read as one: the
  /// sole production caller — the `verifyBoundBuild` arm of
  /// `FoundationRockchipRuntimeActionExecutor.execute` — passes
  /// `expectation.previousIdentitySHA256` to *both* operands, so in production
  /// the comparison can only ever be true and checks well-formedness alone.
  package func publish(
    _ candidate: RockchipPostFlashHDCBinding,
    expectedPreviousHDCIdentitySHA256: String
  ) throws -> RockchipPostFlashHDCBinding {
    try validate(candidate)
    guard Self.isSHA256(expectedPreviousHDCIdentitySHA256),
      candidate.previousHDCIdentitySHA256 == expectedPreviousHDCIdentitySHA256
    else { throw failure("post-flash binding previous alias is invalid") }
    try prepareRoot()
    let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw failure("post-flash binding root cannot be opened") }
    defer { Darwin.close(root) }
    let lock = Darwin.openat(
      root, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw failure("post-flash binding lock cannot be opened") }
    defer { Darwin.close(lock) }
    try validateFile(lock, label: "post-flash binding lock")
    guard flock(lock, LOCK_EX) == 0 else {
      throw failure("post-flash binding lock cannot be acquired")
    }
    defer { _ = flock(lock, LOCK_UN) }

    if let existing = try load(rootDescriptor: root) {
      // A read-only action may be dispatched again after the alias was
      // committed but before its durable host receipt was written.  Its wall
      // clock can advance across daemon restart; the identity proof cannot.
      // Treat that exact same Job proof as idempotent and retain the original
      // establishment time instead of making recovery depend on timestamp
      // equality.
      if existing.sameProof(as: candidate) { return existing }
      if existing.targetID == candidate.targetID,
        existing.bindingRevision < candidate.bindingRevision
      {
        // A binding-revision advance opens a new alias epoch. The entry from
        // an earlier revision of the same target is superseded evidence —
        // archived beside the store, never silently discarded — and the
        // candidate establishes the alias for its own epoch. The chain rule
        // (`previous` must name the trusted alias) holds *within* an epoch,
        // and a candidate older than the store below stays refused, so a
        // stale Job still cannot rotate a newer route.
        //
        // Measured 2026-08-18: the revision-3 entry of 2026-08-14 blocked
        // every revision-4 publication, failing the postflight after all nine
        // partitions had verifiably written.
        try archiveSuperseded(existing, rootDescriptor: root)
      } else {
        guard existing.targetID == candidate.targetID,
          existing.bindingRevision == candidate.bindingRevision,
          existing.stableLoaderIdentitySHA256 == candidate.stableLoaderIdentitySHA256,
          existing.hdcIdentitySHA256 == expectedPreviousHDCIdentitySHA256
        else { throw failure("post-flash binding changed before verified alias publication") }
      }
    }

    return try commit(candidate, rootDescriptor: root)
  }

  /// Atomic write plus readback, shared by publication and lineage
  /// reconciliation. The caller already holds the store lock.
  private func commit(
    _ candidate: RockchipPostFlashHDCBinding, rootDescriptor root: Int32
  ) throws -> RockchipPostFlashHDCBinding {
    let encoder = CanonicalJSONEncoders.canonical()
    var data = try encoder.encode(candidate)
    data.append(0x0A)
    guard data.count <= Self.maximumBytes else {
      throw failure("post-flash binding document exceeds its limit")
    }
    let temporaryName = ".post-flash-binding.\(UUID().uuidString.lowercased()).part"
    let temporary = Darwin.openat(
      root, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard temporary >= 0 else {
      throw failure("post-flash binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporary) }
      _ = unlinkat(root, temporaryName, 0)
    }
    try writeAll(data, descriptor: temporary)
    guard fchmod(temporary, 0o600) == 0,
      Darwin.fsync(temporary) == 0,
      Darwin.fcntl(temporary, F_FULLFSYNC) == 0,
      Darwin.close(temporary) == 0
    else { throw failure("post-flash binding temporary file cannot be synchronized") }
    temporaryOpen = false
    guard renameat(root, temporaryName, root, Self.fileName) == 0,
      Darwin.fsync(root) == 0
    else { throw failure("post-flash binding cannot be committed") }
    guard let readback = try load(rootDescriptor: root), readback == candidate else {
      throw failure("post-flash binding readback failed")
    }
    return readback
  }

  /// The exact reason a stored alias cannot be compared to the live target,
  /// and what the Runtime proved about it. This is a fact, not a decision.
  package struct ReissuedLineageReconciliation: Sendable, Equatable {
    package let archivedRevision: Int
    package let publishedRevision: Int
    package let targetID: String
    package let hdcIdentitySHA256: String
  }

  /// Reconcile an alias whose revision was issued by a target store that no
  /// longer exists.
  ///
  /// `bindingRevision` on this record is a copy of the *target store's* counter
  /// at publication time. The two Rockchip stores live in the Application
  /// Support root while the target store that issues those revisions lives
  /// inside the daemon state directory, so retiring the state directory — an
  /// operation the product itself offers — reissues the counter from 1 while
  /// this record keeps the retired store's high-water mark. Every later Flash
  /// on that host is then refused as "stored alias revision N is newer than
  /// target revision M", forever, with no product path out.
  ///
  /// A reissue is distinguishable from a genuinely newer route, and the proof
  /// is mechanical rather than asserted. A target's `bindingRevision` is 1 at
  /// adoption and thereafter only moves through `advanceBindingLineage`, which
  /// refuses unless the stable physical identity *changes*. So within one
  /// store a `(targetID, stableIdentity)` pair has exactly one revision, and
  /// there is no path that lowers one. A stored alias whose target, Loader
  /// identity, HDC identity, connect key and build all equal the live target's
  /// freshly observed facts, but whose revision is higher, therefore cannot be
  /// describing a newer route: a newer route differs in at least one of those
  /// identities, because that is what a route is. The only remaining
  /// explanation is that the counter restarted underneath it.
  ///
  /// Anything less than all five agreeing keeps the original refusal. Nothing
  /// here invents a revision, lowers one, edits a target, rewrites evidence or
  /// resolves an unknown Job outcome: the superseded entry is archived beside
  /// the store and the same route is republished under the live revision.
  ///
  /// The five facts are the target and Loader identity from the durable target
  /// store, and the HDC identity, connect key and USB topology of whatever is
  /// physically attached right now. Every one is observed by the Runtime; none
  /// is supplied by the caller as an assertion, and none can be satisfied by
  /// handing this function a value copied out of the record it is judging.
  /// The record's `buildVersion` is deliberately **not** a precondition: it can
  /// only be read back over HDC, this is a host-local repair that dispatches
  /// nothing to the device, and comparing the stored value against itself would
  /// be the same empty guard as the one documented on `publish`.
  package func reconcileReissuedLineage(
    target: RuntimeTargetRecord,
    observedHDCIdentitySHA256: String,
    observedHDCConnectKey: String,
    observedUSBTopology: String,
    nowUTC: String
  ) throws -> ReissuedLineageReconciliation? {
    try prepareRoot()
    let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw failure("post-flash binding root cannot be opened") }
    defer { Darwin.close(root) }
    let lock = Darwin.openat(
      root, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw failure("post-flash binding lock cannot be opened") }
    defer { Darwin.close(lock) }
    try validateFile(lock, label: "post-flash binding lock")
    guard flock(lock, LOCK_EX) == 0 else {
      throw failure("post-flash binding lock cannot be acquired")
    }
    defer { _ = flock(lock, LOCK_UN) }

    guard let existing = try load(rootDescriptor: root) else { return nil }
    // Only the reissue shape. A stored alias at or below the live revision is
    // the ordinary case and is not this function's business.
    guard existing.bindingRevision > target.bindingRevision else { return nil }
    guard existing.targetID == target.targetID,
      existing.stableLoaderIdentitySHA256 == target.stablePhysicalIdentitySHA256,
      existing.hdcIdentitySHA256 == observedHDCIdentitySHA256,
      existing.hdcConnectKey == observedHDCConnectKey,
      existing.usbTopology == observedUSBTopology,
      Self.isSHA256(observedHDCIdentitySHA256),
      Self.sha256(observedHDCConnectKey) == observedHDCIdentitySHA256,
      ISO8601Timestamps.parse(nowUTC) != nil
    else { return nil }

    let republished = RockchipPostFlashHDCBinding(
      targetID: existing.targetID,
      bindingRevision: target.bindingRevision,
      stableLoaderIdentitySHA256: existing.stableLoaderIdentitySHA256,
      // The chain rule holds within an epoch. The republished entry opens the
      // live store's epoch for a route that is already the trusted one, so it
      // names itself as its own previous alias — exactly what the publisher's
      // sole production caller passes, and what the original entry recorded.
      previousHDCIdentitySHA256: existing.hdcIdentitySHA256,
      hdcIdentitySHA256: existing.hdcIdentitySHA256,
      hdcConnectKey: existing.hdcConnectKey,
      usbTopology: existing.usbTopology,
      productModel: existing.productModel,
      buildVersion: existing.buildVersion,
      jobID: existing.jobID,
      establishedAtUTC: nowUTC)
    try validate(republished)
    // Archive first. `archiveSuperseded` refuses a name collision that holds a
    // different entry, so the live record is never overwritten while the entry
    // it replaces is unpreserved.
    try archiveSuperseded(existing, rootDescriptor: root)
    _ = try commit(republished, rootDescriptor: root)
    return ReissuedLineageReconciliation(
      archivedRevision: existing.bindingRevision,
      publishedRevision: target.bindingRevision,
      targetID: existing.targetID,
      hdcIdentitySHA256: existing.hdcIdentitySHA256)
  }

  /// Archives a superseded epoch's entry beside the store.
  ///
  /// Named by its establishment time, so re-archiving the same epoch after a
  /// crash between archive and commit is idempotent rather than an error.
  /// History is preserved, not rewritten: the archive carries the entry
  /// byte-for-byte re-encoded, and nothing ever deletes one.
  private func archiveSuperseded(
    _ existing: RockchipPostFlashHDCBinding, rootDescriptor: Int32
  ) throws {
    let stamp = existing.establishedAtUTC.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }.reduce(into: "") { $0.unicodeScalars.append($1) }
    let name = "post-flash-superseded-\(stamp.isEmpty ? "unknown" : stamp).json"
    let encoder = CanonicalJSONEncoders.canonical()
    var data = try encoder.encode(existing)
    data.append(0x0A)
    let descriptor = Darwin.openat(
      rootDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    if descriptor < 0 {
      // The name is derived from the establishment time alone, so two entries
      // of different epochs can collide on it. Returning success here archived
      // nothing and let the caller overwrite the live record, discarding the
      // entry this function promises to preserve. Idempotency is re-archiving
      // *the same* entry; anything else is a collision and must refuse.
      if errno == EEXIST {
        guard try archivedEntryMatches(data, name: name, rootDescriptor: rootDescriptor) else {
          throw failure(
            "superseded post-flash binding archive \(name) already holds a different entry")
        }
        return
      }
      throw failure("superseded post-flash binding archive cannot be created")
    }
    defer { Darwin.close(descriptor) }
    try writeAll(data, descriptor: descriptor)
    guard Darwin.fsync(descriptor) == 0, Darwin.fsync(rootDescriptor) == 0 else {
      throw failure("superseded post-flash binding archive cannot be synchronized")
    }
  }

  /// True only when the archive already on disk is byte-for-byte the entry
  /// this call would have written.
  private func archivedEntryMatches(
    _ data: Data, name: String, rootDescriptor: Int32
  ) throws -> Bool {
    let descriptor = Darwin.openat(rootDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw failure("superseded post-flash binding archive cannot be reopened")
    }
    defer { Darwin.close(descriptor) }
    try validateFile(descriptor, label: "superseded post-flash binding archive")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
      metadata.st_size <= Self.maximumBytes
    else { throw failure("superseded post-flash binding archive size is invalid") }
    guard Int(metadata.st_size) == data.count else { return false }
    var existing = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while existing.count < data.count {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, data.count - existing.count))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw failure("superseded post-flash binding archive is truncated")
      }
      existing.append(contentsOf: buffer.prefix(count))
    }
    return existing == data
  }

  private func load(rootDescriptor: Int32) throws -> RockchipPostFlashHDCBinding? {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw failure("post-flash binding cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateFile(descriptor, label: "post-flash binding")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else { throw failure("post-flash binding size is invalid") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < Int(metadata.st_size) {
      let count = Darwin.read(
        descriptor, &buffer, min(buffer.count, Int(metadata.st_size) - data.count))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw failure("post-flash binding is truncated") }
      data.append(contentsOf: buffer.prefix(count))
    }
    let result: RockchipPostFlashHDCBinding
    do {
      result = try JSONDecoder().decode(RockchipPostFlashHDCBinding.self, from: data)
    } catch {
      throw failure("post-flash binding cannot be decoded")
    }
    try validate(result)
    return result
  }

  private func validate(_ value: RockchipPostFlashHDCBinding) throws {
    guard value.schemaVersion == RockchipPostFlashHDCBinding.currentSchemaVersion,
      !value.targetID.isEmpty,
      value.bindingRevision > 0,
      Self.isSHA256(value.stableLoaderIdentitySHA256),
      Self.isSHA256(value.previousHDCIdentitySHA256),
      Self.isSHA256(value.hdcIdentitySHA256),
      !value.hdcConnectKey.isEmpty,
      value.hdcConnectKey.utf8.count <= 1_024,
      value.hdcConnectKey.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      }),
      Self.sha256(value.hdcConnectKey) == value.hdcIdentitySHA256,
      !value.usbTopology.isEmpty,
      value.usbTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      !value.productModel.isEmpty,
      !value.buildVersion.isEmpty,
      !value.jobID.isEmpty,
      ISO8601Timestamps.parse(value.establishedAtUTC) != nil
    else { throw failure("post-flash binding document is invalid") }
  }

  private func prepareRoot() throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw failure("post-flash binding root must be absolute")
    }
    try FileManager.default.createDirectory(
      at: rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(rootURL.path, 0o700) == 0 else {
      throw failure("post-flash binding root must be owner-only")
    }
  }

  private func validateFile(_ descriptor: Int32, label: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == 0o600
    else { throw failure("\(label) must be an owner-only regular file") }
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw failure("post-flash binding write failed") }
        offset += count
      }
    }
  }

  private static func sha256(_ value: String) -> String {
    SHA256Hex.string(of: Data(value.utf8))
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy {
        ("0"..."9").contains($0) || ("a"..."f").contains($0)
      }
  }

  private func failure(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

extension RockchipPostFlashHDCBinding {
  fileprivate func sameProof(as other: Self) -> Bool {
    schemaVersion == other.schemaVersion
      && targetID == other.targetID
      && bindingRevision == other.bindingRevision
      && stableLoaderIdentitySHA256 == other.stableLoaderIdentitySHA256
      && previousHDCIdentitySHA256 == other.previousHDCIdentitySHA256
      && hdcIdentitySHA256 == other.hdcIdentitySHA256
      && hdcConnectKey == other.hdcConnectKey
      && usbTopology == other.usbTopology
      && productModel == other.productModel
      && buildVersion == other.buildVersion
      && jobID == other.jobID
  }
}
