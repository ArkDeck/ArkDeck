import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

package enum VerifiedRegularFileError: Error, Equatable {
  case invalidPath
  case openFailed(Int32)
  case unsafeFile
  case identityChanged
  case hashMismatch
  case inodePathUnavailable
  case descriptorInvalid
}

/// Retains one verified regular-file inode while a child opens it. Callers
/// put `inodePath` in argv instead of the mutable pathname; the descriptor is
/// held until the child completes and is revalidated in the final pre-spawn
/// critical section.
package final class VerifiedRegularFileDescriptor: @unchecked Sendable {
  package let authorizedPath: String
  package let inodePath: String
  package let sha256: String
  package let byteCount: Int

  private var descriptor: Int32
  private let openedDevice: dev_t
  private let openedInode: ino_t

  private init(
    authorizedPath: String,
    inodePath: String,
    sha256: String,
    byteCount: Int,
    descriptor: Int32,
    openedDevice: dev_t,
    openedInode: ino_t
  ) {
    self.authorizedPath = authorizedPath
    self.inodePath = inodePath
    self.sha256 = sha256
    self.byteCount = byteCount
    self.descriptor = descriptor
    self.openedDevice = openedDevice
    self.openedInode = openedInode
  }

  package static func open(
    path: URL,
    expectedSHA256: String,
    maximumBytes: Int = 512 * 1_024 * 1_024
  ) throws -> VerifiedRegularFileDescriptor {
    let canonical = path.standardizedFileURL
    guard path.isFileURL, path.path.hasPrefix("/"), path.path == canonical.path,
      path.resolvingSymlinksInPath().standardizedFileURL.path == path.path,
      expectedSHA256.count == 64,
      expectedSHA256.utf8.allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      })
    else { throw VerifiedRegularFileError.invalidPath }

    var pathMetadata = stat()
    guard path.path.withCString({ lstat($0, &pathMetadata) }) == 0 else {
      throw VerifiedRegularFileError.openFailed(errno)
    }
    guard pathMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      pathMetadata.st_mode & 0o022 == 0,
      pathMetadata.st_size > 0,
      pathMetadata.st_size <= maximumBytes
    else { throw VerifiedRegularFileError.unsafeFile }

    let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
    do {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw VerifiedRegularFileError.descriptorInvalid
      }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        metadata.st_dev == pathMetadata.st_dev,
        metadata.st_ino == pathMetadata.st_ino,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        metadata.st_size > 0,
        metadata.st_size <= maximumBytes
      else { throw VerifiedRegularFileError.identityChanged }
      let observedSHA256 = try hash(descriptor)
      guard observedSHA256 == expectedSHA256 else {
        throw VerifiedRegularFileError.hashMismatch
      }
      let device = UInt64(UInt32(bitPattern: metadata.st_dev))
      let inode = UInt64(metadata.st_ino)
      let inodePath = "/.vol/\(device)/\(inode)"
      var inodeMetadata = stat()
      guard inodePath.withCString({ lstat($0, &inodeMetadata) }) == 0,
        inodeMetadata.st_dev == metadata.st_dev,
        inodeMetadata.st_ino == metadata.st_ino,
        inodeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      else { throw VerifiedRegularFileError.inodePathUnavailable }
      return VerifiedRegularFileDescriptor(
        authorizedPath: path.path, inodePath: inodePath,
        sha256: observedSHA256, byteCount: Int(metadata.st_size),
        descriptor: descriptor, openedDevice: metadata.st_dev,
        openedInode: metadata.st_ino)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  package func revalidate() throws {
    guard descriptor >= 0 else { throw VerifiedRegularFileError.descriptorInvalid }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_dev == openedDevice,
      metadata.st_ino == openedInode,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_size == byteCount
    else { throw VerifiedRegularFileError.descriptorInvalid }
    var pathMetadata = stat()
    guard authorizedPath.withCString({ lstat($0, &pathMetadata) }) == 0,
      pathMetadata.st_dev == openedDevice,
      pathMetadata.st_ino == openedInode,
      pathMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else { throw VerifiedRegularFileError.identityChanged }
    var inodeMetadata = stat()
    guard inodePath.withCString({ lstat($0, &inodeMetadata) }) == 0,
      inodeMetadata.st_dev == openedDevice,
      inodeMetadata.st_ino == openedInode,
      inodeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else { throw VerifiedRegularFileError.inodePathUnavailable }
    guard try Self.hash(descriptor) == sha256 else {
      throw VerifiedRegularFileError.hashMismatch
    }
  }

  package func close() {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  deinit { close() }

  private static func hash(_ descriptor: Int32) throws -> String {
    var hasher = SHA256()
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(descriptor, bytes.baseAddress, bytes.count, offset)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw VerifiedRegularFileError.descriptorInvalid
      }
      hasher.update(data: Data(buffer.prefix(count)))
      offset += off_t(count)
    }
    return SHA256Hex.hexString(hasher.finalize())
  }
}
