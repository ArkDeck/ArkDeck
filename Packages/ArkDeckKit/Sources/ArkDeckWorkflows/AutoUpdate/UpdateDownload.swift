import CryptoKit
import Darwin
import Foundation

public enum UpdateDownloadError: Error, Equatable, Sendable {
  case unsafeDirectory
  case fileOperationFailed(errno: Int32)
  case responseOverflow
  case truncated
  case digestMismatch
  case cancelled
  case unsafeArtifact
}

public struct UpdateFileIdentity: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let byteLength: UInt64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64

  public init(
    device: UInt64,
    inode: UInt64,
    byteLength: UInt64,
    modifiedSeconds: Int64,
    modifiedNanoseconds: Int64
  ) {
    self.device = device
    self.inode = inode
    self.byteLength = byteLength
    self.modifiedSeconds = modifiedSeconds
    self.modifiedNanoseconds = modifiedNanoseconds
  }
}

public struct DownloadedUpdateArtifact: Equatable, Sendable {
  public let url: URL
  public let byteLength: UInt64
  public let sha256: String
  public let identity: UpdateFileIdentity

  public init(url: URL, byteLength: UInt64, sha256: String, identity: UpdateFileIdentity) {
    self.url = url
    self.byteLength = byteLength
    self.sha256 = sha256
    self.identity = identity
  }
}

/// Owns only the update cache directory. It never writes to the installed application.
public struct UpdateArtifactStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL
  }

  public static func production() throws -> UpdateArtifactStore {
    let caches = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return UpdateArtifactStore(
      directory: caches.appending(path: "ArkDeck-Updates", directoryHint: .isDirectory))
  }

  public func removeOrphanPartials() throws {
    let directoryDescriptor = try openSecureDirectory()
    defer { Darwin.close(directoryDescriptor) }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw UpdateDownloadError.fileOperationFailed(errno: Self.posixErrorCode(for: error))
    }
    for name in names where name.hasSuffix(".part") {
      guard name == URL(fileURLWithPath: name).lastPathComponent else { continue }
      if unlinkat(directoryDescriptor, name, 0) != 0, errno != ENOENT {
        throw UpdateDownloadError.fileOperationFailed(errno: errno)
      }
    }
    try fullSync(directoryDescriptor)
  }

  public func writeVerified(
    stream: AsyncThrowingStream<Data, any Error>,
    expectedLength: UInt64,
    expectedSHA256: String
  ) async throws -> DownloadedUpdateArtifact {
    guard expectedLength > 0 else { throw UpdateDownloadError.truncated }
    let directoryDescriptor = try openSecureDirectory()
    defer { Darwin.close(directoryDescriptor) }

    let stem = UUID().uuidString.lowercased()
    let partialName = stem + ".part"
    let finalName = stem + ".dmg"
    let descriptor = Darwin.openat(
      directoryDescriptor, partialName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600)
    guard descriptor >= 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    var partialExists = true
    defer {
      Darwin.close(descriptor)
      if partialExists { _ = unlinkat(directoryDescriptor, partialName, 0) }
    }

    var hasher = SHA256()
    var received: UInt64 = 0
    do {
      for try await chunk in stream {
        if Task.isCancelled { throw UpdateDownloadError.cancelled }
        guard UInt64(chunk.count) <= expectedLength - min(expectedLength, received) else {
          throw UpdateDownloadError.responseOverflow
        }
        try writeAll(chunk, descriptor: descriptor)
        hasher.update(data: chunk)
        received += UInt64(chunk.count)
      }
    } catch is CancellationError {
      throw UpdateDownloadError.cancelled
    }
    if Task.isCancelled { throw UpdateDownloadError.cancelled }
    guard received == expectedLength else { throw UpdateDownloadError.truncated }
    let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard actualDigest == expectedSHA256 else { throw UpdateDownloadError.digestMismatch }
    try fullSync(descriptor)
    guard fchmod(descriptor, 0o400) == 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    try fullSync(descriptor)
    guard renameat(directoryDescriptor, partialName, directoryDescriptor, finalName) == 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    partialExists = false
    try fullSync(directoryDescriptor)

    let identity = try Self.identity(descriptor: descriptor)
    let finalURL = directory.appending(path: finalName)
    guard try Self.identity(at: finalURL) == identity else {
      _ = unlinkat(directoryDescriptor, finalName, 0)
      throw UpdateDownloadError.unsafeArtifact
    }
    return DownloadedUpdateArtifact(
      url: finalURL, byteLength: received, sha256: actualDigest, identity: identity)
  }

  public func remove(_ artifact: DownloadedUpdateArtifact) {
    guard artifact.url.deletingLastPathComponent().standardizedFileURL == directory else { return }
    _ = Darwin.unlink(artifact.url.path)
  }

  public static func verifyFile(
    at url: URL,
    expectedLength: UInt64,
    expectedSHA256: String
  ) throws -> UpdateFileIdentity {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    defer { Darwin.close(descriptor) }
    let before = try identity(descriptor: descriptor)
    guard before.byteLength == expectedLength else { throw UpdateDownloadError.truncated }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw UpdateDownloadError.fileOperationFailed(errno: errno)
      }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA256 else { throw UpdateDownloadError.digestMismatch }
    let after = try identity(descriptor: descriptor)
    guard after == before, try identity(at: url) == before else {
      throw UpdateDownloadError.unsafeArtifact
    }
    return before
  }

  public static func identity(at url: URL) throws -> UpdateFileIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    return try identity(metadata)
  }

  private func openSecureDirectory() throws -> Int32 {
    guard directory.isFileURL, directory.path.hasPrefix("/") else {
      throw UpdateDownloadError.unsafeDirectory
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw UpdateDownloadError.fileOperationFailed(errno: Self.posixErrorCode(for: error))
    }
    let descriptor = Darwin.open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    do {
      guard fchmod(descriptor, 0o700) == 0 else {
        throw UpdateDownloadError.fileOperationFailed(errno: errno)
      }
      let opened = try Self.identityOfDirectory(descriptor: descriptor)
      var linked = stat()
      guard lstat(directory.path, &linked) == 0, linked.st_mode & S_IFMT == S_IFDIR,
        linked.st_uid == geteuid(), linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
        opened.device == UInt64(linked.st_dev), opened.inode == UInt64(linked.st_ino)
      else { throw UpdateDownloadError.unsafeDirectory }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func identityOfDirectory(descriptor: Int32) throws -> UpdateFileIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else { throw UpdateDownloadError.unsafeDirectory }
    return try identity(metadata, requiredType: S_IFDIR)
  }

  private static func identity(descriptor: Int32) throws -> UpdateFileIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
    return try identity(metadata)
  }

  private static func identity(
    _ metadata: stat,
    requiredType: mode_t = S_IFREG
  ) throws -> UpdateFileIdentity {
    guard metadata.st_mode & S_IFMT == requiredType, metadata.st_uid == geteuid(),
      requiredType == S_IFDIR || metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
      metadata.st_size >= 0
    else { throw UpdateDownloadError.unsafeArtifact }
    return UpdateFileIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      byteLength: UInt64(metadata.st_size),
      modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw UpdateDownloadError.fileOperationFailed(errno: count == 0 ? EIO : errno)
      }
      offset += count
    }
  }

  private static func posixErrorCode(for error: any Error) -> Int32 {
    let cocoaError = error as NSError
    if cocoaError.domain == NSPOSIXErrorDomain {
      return Int32(clamping: cocoaError.code)
    }
    if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain
    {
      return Int32(clamping: underlying.code)
    }
    return EIO
  }

  private func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else {
      throw UpdateDownloadError.fileOperationFailed(errno: errno)
    }
  }
}
