import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation

/// One explicit host-file publication. No device operation or export authority
/// is inferred from the Artifact's availability for reading.
package enum RuntimeArtifactExport {
  package enum FaultPoint: Sendable { case beforePublication, afterPublication }
  package typealias Fault = @Sendable (FaultPoint) throws -> Void

  package static func physicalPath(_ path: String) -> String {
    for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
      return "/private" + path
    }
    return path
  }

  package static func run(
    metadata: RuntimeArtifactMetadata, owner: ArtifactOwnerReference, source: Int32,
    destinationDirectory: URL, protectedRoot: URL, overwrite: Bool,
    fault: Fault, verifySource: () throws -> Void
  ) throws -> JSONValue {
    func refusal(_ code: String, _ message: String) -> AgentExecutionControlFailure { .init(code, message) }
    let destination = physicalPath(destinationDirectory.standardizedFileURL.path)
    let protected = physicalPath(protectedRoot.standardizedFileURL.path)
    guard destinationDirectory.isFileURL, destination.hasPrefix("/"),
      !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      destination != protected, !destination.hasPrefix(protected + "/") else {
      throw refusal("invalidInput", "export requires an explicit host directory outside Artifact storage")
    }
    let directory: Int32
    do { directory = try ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(destination) }
    catch { throw refusal("invalidInput", "export directory must exist and have no symbolic-link components") }
    defer { Darwin.close(directory) }
    var directoryIdentity = stat()
    guard fstat(directory, &directoryIdentity) == 0 else { throw refusal("recordUnreadable", "export directory identity is unavailable") }
    func checkDirectory() throws {
      let current: Int32
      do { current = try ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(destination) }
      catch { throw refusal("resourceConflict", "export directory changed during publication") }
      defer { Darwin.close(current) }
      var identity = stat()
      guard fstat(current, &identity) == 0, identity.st_dev == directoryIdentity.st_dev,
        identity.st_ino == directoryIdentity.st_ino else { throw refusal("resourceConflict", "export directory changed during publication") }
    }
    let safeName = metadata.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
    let name = "\(metadata.artifactID)-\(safeName)"
    guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      name.utf8.count <= 255 else { throw refusal("invalidInput", "export filename exceeds the host filename bound") }
    let path = URL(filePath: destination).appending(path: name).path
    func existing() throws -> stat? {
      var found = stat()
      if fstatat(directory, name, &found, AT_SYMLINK_NOFOLLOW) == 0 {
        guard found.st_mode & S_IFMT == S_IFREG, found.st_uid == geteuid(), found.st_nlink == 1 else {
          throw refusal("resourceConflict", "export destination is not an owned regular file")
        }
        return found
      }
      guard errno == ENOENT else { throw refusal("recordUnreadable", "export destination cannot be inspected") }
      return nil
    }
    let prior = try existing()
    guard prior == nil || overwrite else { throw refusal("resourceConflict", "export destination exists; explicit overwrite is required") }
    let temporary = ".arkdeck-export-\(UUID().uuidString.lowercased()).part"
    let output = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw refusal("operationFailed", "export staging file could not be created") }
    var published = false
    defer {
      // Only our retained private inode may be cleaned up, never a replaced
      // name or the published destination.
      if !published {
        var descriptor = stat(); var named = stat()
        if fstat(output, &descriptor) == 0, fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
          descriptor.st_dev == named.st_dev, descriptor.st_ino == named.st_ino {
          _ = unlinkat(directory, temporary, 0)
        }
      }
      Darwin.close(output)
    }
    do {
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      var offset = 0
      while offset < metadata.byteCount {
        let count = pread(source, &buffer, min(buffer.count, metadata.byteCount - offset), off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw refusal("artifactIntegrityFailed", "Artifact ended before its declared byte count") }
        try DurableFilePrimitives.writeAll(Data(buffer.prefix(count)), descriptor: output, path: path)
        offset += count
      }
      try verifySource()
      try DurableFilePrimitives.fullSync(output, path: path)
      var staged = stat(); var named = stat()
      guard fstat(output, &staged) == 0, staged.st_size == metadata.byteCount, staged.st_mode & S_IFMT == S_IFREG,
        staged.st_uid == geteuid(), staged.st_nlink == 1, staged.st_mode & 0o777 == 0o600,
        fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
        staged.st_dev == named.st_dev, staged.st_ino == named.st_ino else { throw refusal("artifactIntegrityFailed", "export staging identity changed") }
      var hasher = SHA256(); offset = 0
      while offset < metadata.byteCount {
        let count = pread(output, &buffer, min(buffer.count, metadata.byteCount - offset), off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw refusal("artifactIntegrityFailed", "export readback is incomplete") }
        hasher.update(data: Data(buffer.prefix(count))); offset += count
      }
      guard SHA256Hex.hexString(hasher.finalize()) == metadata.sha256 else { throw refusal("artifactIntegrityFailed", "export readback digest differs") }
      try fault(.beforePublication)
      try verifySource(); try checkDirectory()
      let current = try existing()
      guard (prior == nil && current == nil) || (prior != nil && current != nil
        && prior!.st_dev == current!.st_dev && prior!.st_ino == current!.st_ino
        && prior!.st_size == current!.st_size && prior!.st_mtimespec.tv_sec == current!.st_mtimespec.tv_sec
        && prior!.st_mtimespec.tv_nsec == current!.st_mtimespec.tv_nsec
        && prior!.st_ctimespec.tv_sec == current!.st_ctimespec.tv_sec && prior!.st_ctimespec.tv_nsec == current!.st_ctimespec.tv_nsec) else {
        throw refusal("resourceConflict", "export destination changed before publication")
      }
      var ready = stat(); var readyName = stat()
      guard fstat(output, &ready) == 0, fstatat(directory, temporary, &readyName, AT_SYMLINK_NOFOLLOW) == 0,
        ready.st_dev == staged.st_dev, ready.st_ino == staged.st_ino, ready.st_size == staged.st_size,
        ready.st_mtimespec.tv_sec == staged.st_mtimespec.tv_sec, ready.st_mtimespec.tv_nsec == staged.st_mtimespec.tv_nsec,
        ready.st_ctimespec.tv_sec == staged.st_ctimespec.tv_sec, ready.st_ctimespec.tv_nsec == staged.st_ctimespec.tv_nsec,
        readyName.st_dev == ready.st_dev, readyName.st_ino == ready.st_ino else { throw refusal("artifactIntegrityFailed", "verified export staging changed") }
      guard renameatx_np(directory, temporary, directory, name, prior == nil ? UInt32(RENAME_EXCL) : 0) == 0 else {
        throw refusal(errno == EEXIST ? "resourceConflict" : "operationFailed", "export publication was refused")
      }
      published = true
      try fault(.afterPublication)
      guard Darwin.fsync(directory) == 0 else { throw refusal("outcomeUnknown", "export was published but directory durability is unconfirmed") }
      try checkDirectory()
      var publishedIdentity = stat()
      guard fstat(output, &publishedIdentity) == 0 else { throw refusal("outcomeUnknown", "published export identity is unavailable") }
      hasher = SHA256(); offset = 0
      while offset < metadata.byteCount {
        let count = pread(output, &buffer, min(buffer.count, metadata.byteCount - offset), off_t(offset))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw refusal("outcomeUnknown", "published export readback is incomplete") }
        hasher.update(data: Data(buffer.prefix(count))); offset += count
      }
      var result = stat(); var final = stat()
      guard fstatat(directory, name, &result, AT_SYMLINK_NOFOLLOW) == 0,
        fstat(output, &final) == 0, SHA256Hex.hexString(hasher.finalize()) == metadata.sha256,
        result.st_dev == ready.st_dev, result.st_ino == ready.st_ino, result.st_size == metadata.byteCount,
        result.st_mode & S_IFMT == S_IFREG, result.st_nlink == 1,
        final.st_mtimespec.tv_sec == publishedIdentity.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == publishedIdentity.st_mtimespec.tv_nsec,
        final.st_ctimespec.tv_sec == publishedIdentity.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == publishedIdentity.st_ctimespec.tv_nsec,
        result.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, result.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
        result.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec, result.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else {
        throw refusal("outcomeUnknown", "export destination changed after publication")
      }
      return .object(["schemaVersion": .string("arkdeck.artifact-export/1"), "owner": owner.value,
        "artifactId": .string(metadata.artifactID), "artifactDigest": .string(metadata.sha256),
        "byteCount": .integer(Int64(metadata.byteCount)), "privacy": .string(metadata.privacy.rawValue),
        "exportedPath": .string(path), "overwritten": .bool(prior != nil)])
    } catch {
      if published { throw refusal("outcomeUnknown", "export publication may have completed; inspect the exact destination before retrying") }
      if let known = error as? AgentExecutionControlFailure { throw known }
      throw refusal("operationFailed", "export did not publish a destination file")
    }
  }
}
