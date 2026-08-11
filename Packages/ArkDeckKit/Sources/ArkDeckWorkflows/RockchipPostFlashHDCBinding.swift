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
  /// idempotent; replacing it requires the caller to name the currently
  /// trusted alias digest, so a stale Job cannot rotate a newer route.
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
      guard existing.targetID == candidate.targetID,
        existing.bindingRevision == candidate.bindingRevision,
        existing.stableLoaderIdentitySHA256 == candidate.stableLoaderIdentitySHA256,
        existing.hdcIdentitySHA256 == expectedPreviousHDCIdentitySHA256
      else { throw failure("post-flash binding changed before verified alias publication") }
    }

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
      ISO8601DateFormatter().date(from: value.establishedAtUTC) != nil
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
    value.count == 64 && value.allSatisfy {
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
