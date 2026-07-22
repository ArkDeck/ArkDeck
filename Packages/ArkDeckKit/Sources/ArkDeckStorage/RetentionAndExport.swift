import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum SessionExportDeviceIdentifierPolicy: Equatable, Sendable {
  case redact
  case include
}

public struct SessionExportPlan: Equatable, Sendable {
  public let includedRelativePaths: [String]
  public let excludedDeviceDataRelativePaths: [String]
  public let sensitiveDataWarning: String
  public let deviceIdentifierPolicy: SessionExportDeviceIdentifierPolicy

  public init(
    includedRelativePaths: [String],
    excludedDeviceDataRelativePaths: [String],
    sensitiveDataWarning: String,
    deviceIdentifierPolicy: SessionExportDeviceIdentifierPolicy = .redact
  ) {
    self.includedRelativePaths = includedRelativePaths
    self.excludedDeviceDataRelativePaths = excludedDeviceDataRelativePaths
    self.sensitiveDataWarning = sensitiveDataWarning
    self.deviceIdentifierPolicy = deviceIdentifierPolicy
  }
}

public struct SessionExportPlanner: Sendable {
  public init() {}

  public func plan(
    artifacts: [ArtifactRecord],
    includeDeviceData: Bool,
    deviceIdentifierPolicy: SessionExportDeviceIdentifierPolicy = .redact
  ) -> SessionExportPlan {
    let deviceRaw = artifacts.filter { $0.role == .raw || $0.role == .partial }
    let included = artifacts.filter { artifact in
      includeDeviceData || (artifact.role != .raw && artifact.role != .partial)
    }
    return SessionExportPlan(
      includedRelativePaths: (["manifest.json"] + included.map(\.relativePath)).sorted(),
      excludedDeviceDataRelativePaths: includeDeviceData
        ? []
        : deviceRaw.map { artifact in
          deviceIdentifierPolicy == .redact
            ? Self.opaqueExcludedPath(artifact.relativePath)
            : artifact.relativePath
        }.sorted(),
      sensitiveDataWarning:
        "UI Dump、Trace 与 hilog 可能包含文本、路径、设备标识和时序；仅在用户明确选择后包含设备数据。",
      deviceIdentifierPolicy: deviceIdentifierPolicy
    )
  }

  private static func opaqueExcludedPath(_ relativePath: String) -> String {
    let digest = SHA256.hash(data: Data(relativePath.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "excluded-device-data/\(digest.prefix(24))"
  }
}

public struct MaterializedSessionExport: Equatable, Sendable {
  public let root: URL
  public let plan: SessionExportPlan
}

private final class AnchoredExportStaging {
  let parentDescriptor: Int32
  let descriptor: Int32
  let parentURL: URL
  let destinationURL: URL
  let stagingURL: URL
  private let parentDevice: dev_t
  private let parentInode: ino_t
  private let stagingDevice: dev_t
  private let stagingInode: ino_t
  private let destinationName: String
  private let stagingName: String
  private var published = false
  private var expectedFiles: [String: (size: UInt64, sha256: String)] = [:]

  init(parent: URL, destination: URL) throws {
    parentURL = parent.standardizedFileURL
    destinationURL = destination.standardizedFileURL
    destinationName = destination.lastPathComponent
    try SessionStorageValidation.relativePath(destinationName)
    guard !destinationName.contains("/") else {
      throw SessionStorageError.invalidRelativePath(destinationName)
    }
    stagingName = ".\(destinationName).export.\(UUID().uuidString).tmp"
    stagingURL = parentURL.appending(path: stagingName, directoryHint: .isDirectory)

    let openedParent = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard openedParent >= 0 else {
      throw SessionStorageError.writeFailed(path: parentURL.path, errno: errno)
    }
    var openedStaging: Int32 = -1
    do {
      var parentPath = stat()
      var parent = stat()
      guard Darwin.lstat(parentURL.path, &parentPath) == 0,
        fstat(openedParent, &parent) == 0,
        parentPath.st_mode & S_IFMT == S_IFDIR, parent.st_mode & S_IFMT == S_IFDIR,
        parentPath.st_uid == geteuid(), parent.st_uid == geteuid(),
        parentPath.st_dev == parent.st_dev, parentPath.st_ino == parent.st_ino
      else {
        throw SessionStorageError.invalidRecord("export parent directory changed while opening")
      }
      var destinationMetadata = stat()
      if fstatat(openedParent, destinationName, &destinationMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
        throw SessionStorageError.writeFailed(path: destinationURL.path, errno: EEXIST)
      }
      guard errno == ENOENT else {
        throw SessionStorageError.writeFailed(path: destinationURL.path, errno: errno)
      }
      guard Darwin.mkdirat(openedParent, stagingName, 0o700) == 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
      openedStaging = Darwin.openat(
        openedParent, stagingName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard openedStaging >= 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
      var staging = stat()
      var stagingLink = stat()
      guard fstat(openedStaging, &staging) == 0,
        fstatat(openedParent, stagingName, &stagingLink, AT_SYMLINK_NOFOLLOW) == 0,
        staging.st_mode & S_IFMT == S_IFDIR, stagingLink.st_mode & S_IFMT == S_IFDIR,
        staging.st_uid == geteuid(), stagingLink.st_uid == geteuid(),
        staging.st_dev == parent.st_dev, staging.st_dev == stagingLink.st_dev,
        staging.st_ino == stagingLink.st_ino
      else { throw SessionStorageError.invalidRecord("export staging directory is not anchored") }
      guard Darwin.fsync(openedStaging) == 0, Darwin.fsync(openedParent) == 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
      parentDescriptor = openedParent
      descriptor = openedStaging
      parentDevice = parent.st_dev
      parentInode = parent.st_ino
      stagingDevice = staging.st_dev
      stagingInode = staging.st_ino
    } catch {
      if openedStaging >= 0 { _ = Darwin.close(openedStaging) }
      var stagingMetadata = stat()
      if fstatat(openedParent, stagingName, &stagingMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
        _ = Darwin.unlinkat(
          openedParent, stagingName,
          stagingMetadata.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0)
        _ = Darwin.fsync(openedParent)
      }
      _ = Darwin.close(openedParent)
      throw error
    }
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parentDescriptor)
  }

  static func finalComponent(of relativePath: String) throws -> String {
    try SessionStorageValidation.relativePath(relativePath)
    guard let name = relativePath.split(separator: "/").last else {
      throw SessionStorageError.invalidRelativePath(relativePath)
    }
    return String(name)
  }

  func openParentDirectory(for relativePath: String) throws -> Int32 {
    try SessionStorageValidation.relativePath(relativePath)
    let components = relativePath.split(separator: "/").map(String.init)
    guard !components.isEmpty else {
      throw SessionStorageError.invalidRelativePath(relativePath)
    }
    var current = Darwin.dup(descriptor)
    guard current >= 0 else {
      throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
    }
    do {
      for component in components.dropLast() {
        var metadata = stat()
        let exists = fstatat(current, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0
        if !exists {
          guard errno == ENOENT, Darwin.mkdirat(current, component, 0o700) == 0 else {
            throw SessionStorageError.writeFailed(
              path: stagingURL.appending(path: component).path, errno: errno)
          }
          guard Darwin.fsync(current) == 0 else {
            throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
          }
        } else if metadata.st_mode & S_IFMT != S_IFDIR {
          throw SessionStorageError.invalidRecord("export staging path is not a directory")
        }
        let opened = Darwin.openat(
          current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else {
          throw SessionStorageError.writeFailed(
            path: stagingURL.appending(path: component).path, errno: errno)
        }
        var openedMetadata = stat()
        var linkMetadata = stat()
        guard fstat(opened, &openedMetadata) == 0,
          fstatat(current, component, &linkMetadata, AT_SYMLINK_NOFOLLOW) == 0,
          openedMetadata.st_mode & S_IFMT == S_IFDIR,
          openedMetadata.st_uid == geteuid(), openedMetadata.st_dev == stagingDevice,
          openedMetadata.st_dev == linkMetadata.st_dev,
          openedMetadata.st_ino == linkMetadata.st_ino
        else {
          Darwin.close(opened)
          throw SessionStorageError.invalidRecord("export staging directory was substituted")
        }
        Darwin.close(current)
        current = opened
      }
      return current
    } catch {
      Darwin.close(current)
      throw error
    }
  }

  func synchronizeDirectory(_ directory: Int32, displayPath: URL) throws {
    guard Darwin.fsync(directory) == 0 else {
      throw SessionStorageError.writeFailed(path: displayPath.path, errno: errno)
    }
  }

  func synchronizeParent() throws {
    guard Darwin.fsync(parentDescriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: parentURL.path, errno: errno)
    }
  }

  func recordFile(relativePath: String, size: UInt64, sha256: String) throws {
    try SessionStorageValidation.relativePath(relativePath)
    try SessionStorageValidation.sha256(sha256, field: "export.sha256")
    guard expectedFiles.updateValue((size, sha256.lowercased()), forKey: relativePath) == nil else {
      throw SessionStorageError.invalidRecord("duplicate exported file path")
    }
  }

  func publish() throws {
    try validateParentBinding()
    try validateOwnedEntry(name: stagingName)
    try validateExpectedFiles()
    guard
      renameatx_np(
        parentDescriptor, stagingName, parentDescriptor, destinationName,
        UInt32(RENAME_EXCL)) == 0
    else {
      throw SessionStorageError.writeFailed(path: destinationURL.path, errno: errno)
    }
    published = true
    try validatePublishedBinding()
  }

  func validatePublishedBinding() throws {
    try validateParentBinding()
    try validateOwnedEntry(name: destinationName)
    try validateExpectedFiles()
  }

  func cleanup() throws {
    let currentName = published ? destinationName : stagingName
    var link = stat()
    guard fstatat(parentDescriptor, currentName, &link, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw SessionStorageError.writeFailed(
        path: parentURL.appending(path: currentName).path, errno: errno)
    }
    if link.st_mode & S_IFMT == S_IFDIR,
      link.st_dev == stagingDevice, link.st_ino == stagingInode
    {
      try removeContents(of: descriptor, displayPath: stagingURL.path)
      guard Darwin.unlinkat(parentDescriptor, currentName, AT_REMOVEDIR) == 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
    } else if link.st_mode & S_IFMT != S_IFDIR {
      guard Darwin.unlinkat(parentDescriptor, currentName, 0) == 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
    } else {
      throw SessionStorageError.invalidRecord("refusing to remove substituted export directory")
    }
    try synchronizeParent()
  }

  private func validateParentBinding() throws {
    var parent = stat()
    var path = stat()
    guard fstat(parentDescriptor, &parent) == 0, Darwin.lstat(parentURL.path, &path) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
      parent.st_uid == geteuid(), path.st_uid == geteuid(),
      parent.st_dev == parentDevice, parent.st_ino == parentInode,
      parent.st_dev == path.st_dev, parent.st_ino == path.st_ino
    else { throw SessionStorageError.invalidRecord("export parent directory was substituted") }
  }

  private func validateOwnedEntry(name: String) throws {
    var opened = stat()
    var link = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(parentDescriptor, name, &link, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, link.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), link.st_uid == geteuid(),
      opened.st_dev == stagingDevice, opened.st_ino == stagingInode,
      opened.st_dev == link.st_dev, opened.st_ino == link.st_ino
    else { throw SessionStorageError.invalidRecord("export staging directory was substituted") }
  }

  private func validateExpectedFiles() throws {
    for (relativePath, expected) in expectedFiles.sorted(by: { $0.key < $1.key }) {
      let components = relativePath.split(separator: "/").map(String.init)
      guard let fileName = components.last else {
        throw SessionStorageError.invalidRelativePath(relativePath)
      }
      var parent = Darwin.dup(descriptor)
      guard parent >= 0 else {
        throw SessionStorageError.writeFailed(path: stagingURL.path, errno: errno)
      }
      do {
        for component in components.dropLast() {
          let next = Darwin.openat(
            parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
          guard next >= 0 else {
            throw SessionStorageError.writeFailed(
              path: stagingURL.appending(path: relativePath).path, errno: errno)
          }
          var directory = stat()
          guard fstat(next, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
            directory.st_uid == geteuid(), directory.st_dev == stagingDevice
          else {
            Darwin.close(next)
            throw SessionStorageError.invalidRecord("exported file ancestry was substituted")
          }
          Darwin.close(parent)
          parent = next
        }
        let file = Darwin.openat(
          parent, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else {
          throw SessionStorageError.writeFailed(
            path: stagingURL.appending(path: relativePath).path, errno: errno)
        }
        do {
          var metadata = stat()
          guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == geteuid(), metadata.st_nlink == 1,
            metadata.st_dev == stagingDevice, metadata.st_size >= 0,
            UInt64(metadata.st_size) == expected.size
          else { throw SessionStorageError.invalidRecord("exported file identity changed") }
          let digest = try Self.hash(
            descriptor: file, size: expected.size,
            displayPath: stagingURL.appending(path: relativePath).path)
          guard digest == expected.sha256 else {
            throw SessionStorageError.checksumMismatch(expected: expected.sha256, actual: digest)
          }
          Darwin.close(file)
        } catch {
          Darwin.close(file)
          throw error
        }
        Darwin.close(parent)
      } catch {
        Darwin.close(parent)
        throw error
      }
    }
  }

  private static func hash(descriptor: Int32, size: UInt64, displayPath: String) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset: UInt64 = 0
    while offset < size {
      let requested = min(buffer.count, Int(size - offset))
      let count = Darwin.pread(descriptor, &buffer, requested, off_t(offset))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(
          path: displayPath, errno: count < 0 ? errno : EIO)
      }
      hasher.update(data: Data(buffer[0..<count]))
      offset += UInt64(count)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
      UInt64(metadata.st_size) == size
    else { throw SessionStorageError.invalidRecord("exported file changed while hashing") }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func removeContents(of directory: Int32, displayPath: String) throws {
    for name in try directoryEntryNames(directory, displayPath: displayPath) {
      var metadata = stat()
      guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw SessionStorageError.writeFailed(path: "\(displayPath)/\(name)", errno: errno)
      }
      if metadata.st_mode & S_IFMT == S_IFDIR {
        let child = Darwin.openat(
          directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else {
          throw SessionStorageError.writeFailed(path: "\(displayPath)/\(name)", errno: errno)
        }
        var opened = stat()
        guard fstat(child, &opened) == 0, opened.st_dev == metadata.st_dev,
          opened.st_ino == metadata.st_ino
        else {
          Darwin.close(child)
          throw SessionStorageError.invalidRecord("export cleanup path was substituted")
        }
        do {
          try removeContents(of: child, displayPath: "\(displayPath)/\(name)")
          Darwin.close(child)
        } catch {
          Darwin.close(child)
          throw error
        }
        guard Darwin.unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
          throw SessionStorageError.writeFailed(path: "\(displayPath)/\(name)", errno: errno)
        }
      } else {
        guard Darwin.unlinkat(directory, name, 0) == 0 else {
          throw SessionStorageError.writeFailed(path: "\(displayPath)/\(name)", errno: errno)
        }
      }
    }
    guard Darwin.fsync(directory) == 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
  }

  private func directoryEntryNames(_ directoryDescriptor: Int32, displayPath: String) throws
    -> [String]
  {
    let duplicate = Darwin.dup(directoryDescriptor)
    guard duplicate >= 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
    guard let directory = fdopendir(duplicate) else {
      let failure = errno
      Darwin.close(duplicate)
      throw SessionStorageError.writeFailed(path: displayPath, errno: failure)
    }
    defer { closedir(directory) }
    // The duplicated descriptor shares the original's directory offset; rewind so repeated
    // enumerations of the same anchored descriptor always observe the full directory.
    rewinddir(directory)
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
        }
        break
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(
          decoding: bytes.prefix(Int(entry.pointee.d_namlen)).map { UInt8($0) },
          as: UTF8.self)
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names
  }
}

public struct SessionDiagnosticExporter: Sendable {
  private static let maximumRedactedArtifactBytes = 64 * 1_024 * 1_024
  private static let minimumSubstringIdentifierBytes = 4
  private let volumeIdentityResolver: any VolumeIdentityResolving
  private let faultInjector: SessionStorageFaultInjector

  public init(
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver(),
    faultInjector: SessionStorageFaultInjector = .none
  ) {
    self.volumeIdentityResolver = volumeIdentityResolver
    self.faultInjector = faultInjector
  }

  public func export(
    layout: SessionLayout,
    artifacts: [ArtifactRecord],
    claim: StorageClaim,
    to destination: URL,
    includeDeviceData: Bool = false,
    deviceIdentifierPolicy: SessionExportDeviceIdentifierPolicy = .redact
  ) throws -> MaterializedSessionExport {
    do {
      try DurableFilePrimitives.requireAbsoluteFileURL(destination)
      guard claim.writerClass == .heavy else {
        throw SessionStorageError.invalidRecord(
          "diagnostic export requires a heavy-writer StorageClaim")
      }
      try claim.requireOptionalWriteAuthorization(forJobID: layout.jobID)
      let parent = destination.deletingLastPathComponent()
      try DurableFilePrimitives.rejectSymbolicLink(parent)
      try requireClaimVolume(claim, at: parent)
      let manifestSource = layout.manifestURL.standardizedFileURL
      try requireContainedSource(manifestSource, relativePath: "manifest.json", layout: layout)
      let manifestData = try readBoundedRegularFile(
        manifestSource, maximumBytes: 16 * 1_024 * 1_024)
      let manifest = try SessionManifestDocument(data: manifestData)
      // The durable manifest seeds the redaction identifier set; a manifest that does not belong
      // to this Session/Job must never drive an export of this Session's bytes.
      guard manifest.sessionID == layout.sessionID, manifest.jobID == layout.jobID else {
        throw SessionStorageError.invalidManifest("manifest Session/Job identity mismatch")
      }
      guard artifacts == manifest.artifacts else {
        throw SessionStorageError.invalidRecord(
          "export Artifact records must exactly match the durable manifest")
      }
      var paths = Set<String>()
      for artifact in manifest.artifacts {
        guard paths.insert(artifact.relativePath).inserted else {
          throw SessionStorageError.invalidRecord(
            "duplicate export Artifact path: \(artifact.relativePath)")
        }
      }

      let durablePlan = SessionExportPlanner().plan(
        artifacts: manifest.artifacts, includeDeviceData: includeDeviceData,
        deviceIdentifierPolicy: deviceIdentifierPolicy)
      let includedPaths = Set(
        durablePlan.includedRelativePaths.filter { $0 != "manifest.json" })
      let includedArtifacts = manifest.artifacts.filter {
        includedPaths.contains($0.relativePath)
      }
      let includedArtifactIDs = Set(includedArtifacts.map(\.id))
      let staging = try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
        try requireClaimVolume(claim, at: parent)
        return try AnchoredExportStaging(parent: parent, destination: destination)
      }
      var consumedGrowthBytes: UInt64 = 0
      var completed = false
      defer {
        if !completed {
          do {
            try staging.cleanup()
            try? claim.refundOptionalWrite(bytes: consumedGrowthBytes)
          } catch {}
        }
      }

      var manifestRoot = try manifestRootForExport(
        manifestData, policy: deviceIdentifierPolicy)
      var exportedArtifacts: [ArtifactRecord] = []
      var exportedRelativePaths: Set<String> = []
      for artifact in includedArtifacts {
        let preservesDerivedLineage =
          artifact.role != .derived
          || artifact.derivedFrom?.allSatisfy(includedArtifactIDs.contains) == true
        let exportedRole: ArtifactRole = preservesDerivedLineage ? artifact.role : .diagnostic
        let exportedDerivedFrom = preservesDerivedLineage ? artifact.derivedFrom : nil
        let relativePath = artifact.relativePath
        try SessionStorageValidation.relativePath(relativePath)
        let source = layout.root.appending(path: relativePath).standardizedFileURL
        try requireContainedSource(source, relativePath: relativePath, layout: layout)
        let exportedRelativePath =
          deviceIdentifierPolicy == .redact
          ? try redactRelativePath(
            relativePath, identifiers: manifestRoot.deviceIdentifiers)
          : relativePath
        guard exportedRelativePaths.insert(exportedRelativePath).inserted else {
          throw SessionStorageError.invalidRecord(
            "redacted export Artifact paths collide: \(exportedRelativePath)")
        }
        let target = staging.stagingURL.appending(path: exportedRelativePath).standardizedFileURL
        let targetDirectoryDescriptor = try claim.performOptionalWrite(
          bytes: 0, forJobID: layout.jobID
        ) {
          try staging.openParentDirectory(for: exportedRelativePath)
        }
        defer { Darwin.close(targetDirectoryDescriptor) }
        let targetName = try AnchoredExportStaging.finalComponent(of: exportedRelativePath)

        let exportedRecord: ArtifactRecord
        if deviceIdentifierPolicy == .redact,
          !manifestRoot.deviceIdentifiers.isEmpty
        {
          let sourceData = try readBoundedRegularFile(
            source, maximumBytes: Self.maximumRedactedArtifactBytes)
          try validate(data: sourceData, against: artifact)
          let redacted = try redactData(
            sourceData, identifiers: manifestRoot.deviceIdentifiers)
          try writeExclusive(
            redacted, toParentDescriptor: targetDirectoryDescriptor,
            name: targetName, displayURL: target, claim: claim, jobID: layout.jobID,
            consumedGrowthBytes: &consumedGrowthBytes)
          exportedRecord = try ArtifactRecord(
            id: redactSchemaIdentifier(artifact.id, identifiers: manifestRoot.deviceIdentifiers),
            role: exportedRole,
            origin: exportedRole == .derived
              ? artifact.origin
              : exportLineage(for: artifact, redacted: true),
            relativePath: exportedRelativePath,
            size: UInt64(redacted.count),
            sha256: SessionStorageValidation.lowercaseSHA256(redacted),
            mediaType: try artifact.mediaType.map {
              try redactManifestString($0, identifiers: manifestRoot.deviceIdentifiers)
            },
            derivedFrom: exportedDerivedFrom?.map {
              redactSchemaIdentifier($0, identifiers: manifestRoot.deviceIdentifiers)
            })
        } else {
          let copied = try copyRegularFile(
            from: source, toParentDescriptor: targetDirectoryDescriptor,
            name: targetName, displayURL: target, claim: claim,
            jobID: layout.jobID,
            consumedGrowthBytes: &consumedGrowthBytes)
          guard copied.size == artifact.size, copied.sha256 == artifact.sha256 else {
            throw SessionStorageError.checksumMismatch(
              expected: artifact.sha256, actual: copied.sha256)
          }
          exportedRecord =
            preservesDerivedLineage
            ? artifact
            : try ArtifactRecord(
              id: artifact.id, role: .diagnostic,
              origin: exportLineage(for: artifact, redacted: false),
              relativePath: artifact.relativePath, size: artifact.size,
              sha256: artifact.sha256, mediaType: artifact.mediaType)
        }
        try staging.synchronizeDirectory(
          targetDirectoryDescriptor, displayPath: target.deletingLastPathComponent())
        try staging.recordFile(
          relativePath: exportedRecord.relativePath, size: exportedRecord.size,
          sha256: exportedRecord.sha256)
        exportedArtifacts.append(exportedRecord)
      }

      if deviceIdentifierPolicy == .redact, !manifestRoot.deviceIdentifiers.isEmpty {
        let exportedByOriginalID = Dictionary(
          uniqueKeysWithValues: zip(includedArtifacts, exportedArtifacts).map {
            original, exported in
            (original.id, exported)
          })
        exportedArtifacts = try zip(includedArtifacts, exportedArtifacts).map {
          original, exported in
          guard exported.role == .derived, let sourceIDs = original.derivedFrom else {
            return exported
          }
          let originalProvenance = try DerivedArtifactProvenance(
            manifestOrigin: original.origin)
          let exportedSourceHashes = try sourceIDs.map { sourceID in
            guard let source = exportedByOriginalID[sourceID] else {
              throw SessionStorageError.invalidRecord(
                "exported derived Artifact is missing source Artifact: \(sourceID)")
            }
            return source.sha256
          }
          let parameters = [
            "export.originalOperationSha256": SessionStorageValidation.lowercaseSHA256(
              Data(originalProvenance.operation.utf8)),
            "export.originalArtifactSha256": original.sha256,
          ]
          guard exported.size <= UInt64(Int64.max) else {
            throw SessionStorageError.invalidRecord(
              "exported derived Artifact size exceeds provenance bound")
          }
          let statistics = [
            "export.outputBytes": Int64(exported.size),
            "export.sourceCount": Int64(sourceIDs.count),
          ]
          let exportProvenance = try DerivedArtifactProvenance(
            operation: "device-identifier-redaction", inputHashes: exportedSourceHashes,
            parameters: parameters, statistics: statistics)
          return try ArtifactRecord(
            id: exported.id, role: exported.role,
            origin: exportProvenance.manifestOrigin(), relativePath: exported.relativePath,
            size: exported.size, sha256: exported.sha256, mediaType: exported.mediaType,
            derivedFrom: exported.derivedFrom)
        }
      }

      manifestRoot.root["artifacts"] = .array(
        try exportedArtifacts.map { artifact in
          try JSONDecoder().decode(
            JSONValue.self, from: SessionStorageValidation.canonicalData(artifact))
        })
      let transformedManifest = try SessionStorageValidation.canonicalData(
        JSONValue.object(manifestRoot.root))
      let validatedExportManifest = try SessionManifestDocument(data: transformedManifest)
      guard validatedExportManifest.artifacts == exportedArtifacts else {
        throw SessionStorageError.invalidManifest(
          "exported manifest Artifact metadata did not round-trip")
      }
      guard transformedManifest.count <= 16 * 1_024 * 1_024 else {
        throw SessionStorageError.invalidManifest("redacted manifest exceeds 16 MiB")
      }
      try writeExclusive(
        transformedManifest, toParentDescriptor: staging.descriptor,
        name: "manifest.json", displayURL: staging.stagingURL.appending(path: "manifest.json"),
        claim: claim, jobID: layout.jobID,
        consumedGrowthBytes: &consumedGrowthBytes)
      try staging.synchronizeDirectory(staging.descriptor, displayPath: staging.stagingURL)
      try staging.recordFile(
        relativePath: "manifest.json", size: UInt64(transformedManifest.count),
        sha256: SessionStorageValidation.lowercaseSHA256(transformedManifest))
      try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
        try requireClaimVolume(claim, descriptor: staging.parentDescriptor)
        try requireClaimVolume(claim, descriptor: staging.descriptor)
        try faultInjector.check(.exportBeforeReplace)
        try staging.publish()
        try faultInjector.check(.exportAfterReplace)
        try staging.validatePublishedBinding()
        try staging.synchronizeParent()
        try staging.validatePublishedBinding()
      }
      completed = true
      let exportedPlan = SessionExportPlan(
        includedRelativePaths: (["manifest.json"] + exportedArtifacts.map(\.relativePath))
          .sorted(),
        excludedDeviceDataRelativePaths: durablePlan.excludedDeviceDataRelativePaths,
        sensitiveDataWarning: durablePlan.sensitiveDataWarning,
        deviceIdentifierPolicy: deviceIdentifierPolicy)
      return MaterializedSessionExport(root: destination, plan: exportedPlan)
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  private func manifestRootForExport(
    _ data: Data,
    policy: SessionExportDeviceIdentifierPolicy
  ) throws -> (root: [String: JSONValue], deviceIdentifiers: Set<String>) {
    guard case .object(var root) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      throw SessionStorageError.invalidManifest("manifest must be an object")
    }
    guard policy == .redact else { return (root, []) }
    var identifiers: Set<String> = []
    var identityKeyIdentifiers: Set<String> = []
    let hasRealDeviceIdentity: Bool = {
      guard case .object(let target)? = root["originalTarget"],
        case .string(let kind)? = target["kind"]
      else { return false }
      return kind == "real"
    }()
    if case .object(var target)? = root["originalTarget"] {
      target["connectKey"] = redactScalar(target["connectKey"], identifiers: &identifiers)
      target["identitySnapshot"] = redactTree(
        target["identitySnapshot"], identifiers: &identifiers,
        keyIdentifiers: &identityKeyIdentifiers)
      root["originalTarget"] = .object(target)
    }
    if case .array(let bindings)? = root["bindingHistory"] {
      root["bindingHistory"] = .array(
        bindings.map { binding in
          guard case .object(var object) = binding else { return binding }
          object["connectKey"] = redactScalar(object["connectKey"], identifiers: &identifiers)
          object["identitySnapshot"] = redactTree(
            object["identitySnapshot"], identifiers: &identifiers,
            keyIdentifiers: &identityKeyIdentifiers)
          object["evidence"] = redactTree(
            object["evidence"], identifiers: &identifiers,
            keyIdentifiers: &identityKeyIdentifiers)
          return .object(object)
        })
    }
    let knownIdentifiers =
      hasRealDeviceIdentity ? identifiers.union(identityKeyIdentifiers) : identifiers
    root = try scrubManifestReferences(root, identifiers: knownIdentifiers)
    try rehashManifestArguments(&root)
    return (root, knownIdentifiers)
  }

  private func redactScalar(
    _ value: JSONValue?, identifiers: inout Set<String>
  ) -> JSONValue? {
    guard case .string(let identifier)? = value, !identifier.isEmpty else { return value }
    identifiers.insert(identifier)
    return .string("[REDACTED-DEVICE-ID]")
  }

  private func redactTree(
    _ value: JSONValue?,
    identifiers: inout Set<String>,
    keyIdentifiers: inout Set<String>
  ) -> JSONValue? {
    guard let value else { return nil }
    switch value {
    case .string(let identifier):
      guard !identifier.isEmpty else { return value }
      identifiers.insert(identifier)
      return .string("[REDACTED-DEVICE-ID]")
    case .array(let values):
      return .array(
        values.map {
          redactTree(
            $0, identifiers: &identifiers, keyIdentifiers: &keyIdentifiers)!
        })
    case .object(let object):
      var redacted: [String: JSONValue] = [:]
      for key in object.keys.sorted() {
        // Arbitrary identity/evidence keys are redacted in the manifest and must also seed the
        // byte-level Artifact scrubber when the identifier appears nowhere as a value.
        keyIdentifiers.insert(key)
        let digest = SessionStorageValidation.lowercaseSHA256(Data(key.utf8))
        var redactedKey = "redacted-field-\(digest)"
        var collisionIndex = 0
        while redacted[redactedKey] != nil {
          collisionIndex += 1
          redactedKey = "redacted-field-\(digest)-\(collisionIndex)"
        }
        redacted[redactedKey] = redactTree(
          object[key], identifiers: &identifiers, keyIdentifiers: &keyIdentifiers)!
      }
      return .object(redacted)
    case .integer(let identifier):
      let string = String(identifier)
      if string.utf8.count >= Self.minimumSubstringIdentifierBytes {
        identifiers.insert(string)
      }
      return .string("[REDACTED-DEVICE-ID]")
    case .unsignedInteger(let identifier):
      let string = String(identifier)
      if string.utf8.count >= Self.minimumSubstringIdentifierBytes {
        identifiers.insert(string)
      }
      return .string("[REDACTED-DEVICE-ID]")
    case .number(let identifier):
      let string = String(identifier)
      if string.utf8.count >= Self.minimumSubstringIdentifierBytes {
        identifiers.insert(string)
      }
      return .string("[REDACTED-DEVICE-ID]")
    case .bool:
      return .string("[REDACTED-DEVICE-ID]")
    default:
      return value
    }
  }

  private func scrubManifestReferences(
    _ root: [String: JSONValue],
    identifiers: Set<String>
  ) throws -> [String: JSONValue] {
    Dictionary(
      uniqueKeysWithValues: try root.map { key, value in
        (key, try scrubKnownIdentifiers(value, path: [key], identifiers: identifiers))
      })
  }

  private func scrubKnownIdentifiers(
    _ value: JSONValue,
    path: [String],
    identifiers: Set<String>
  ) throws -> JSONValue {
    let pathKey = path.joined(separator: ".")
    if isPreservedManifestPath(path, pathKey: pathKey) { return value }
    switch value {
    case .string(let string):
      if isSchemaIdentifierPath(path) {
        return .string(redactSchemaIdentifier(string, identifiers: identifiers))
      }
      return .string(try redactManifestString(string, identifiers: identifiers))
    case .array(let values):
      return .array(
        try values.map {
          try scrubKnownIdentifiers($0, path: path + ["*"], identifiers: identifiers)
        })
    case .object(let object):
      return .object(
        Dictionary(
          uniqueKeysWithValues: try object.map { childKey, childValue in
            (
              childKey,
              try scrubKnownIdentifiers(
                childValue, path: path + [childKey], identifiers: identifiers)
            )
          }))
    default:
      return value
    }
  }

  private func redactManifestString(
    _ string: String,
    identifiers: Set<String>
  ) throws -> String {
    if identifiers.contains(string) { return "[REDACTED-DEVICE-ID]" }
    let redacted = try replaceIdentifiers(
      in: Data(string.utf8), identifiers: identifiers,
      replacement: [UInt8]("[R]".utf8))
    return String(decoding: redacted, as: UTF8.self)
  }

  private func redactSchemaIdentifier(_ string: String, identifiers: Set<String>) -> String {
    guard containsDeviceIdentifier(string, identifiers: identifiers) else { return string }
    let digest = SessionStorageValidation.lowercaseSHA256(Data(string.utf8))
    return "redacted-device-\(digest.prefix(24))"
  }

  private func containsDeviceIdentifier(_ string: String, identifiers: Set<String>) -> Bool {
    if identifiers.contains(string) { return true }
    return identifiers.contains { identifier in
      identifier.utf8.count >= Self.minimumSubstringIdentifierBytes
        && string.range(of: identifier) != nil
    }
  }

  private func redactRelativePath(_ path: String, identifiers: Set<String>) throws -> String {
    let redacted = path.split(separator: "/").map { component -> String in
      let string = String(component)
      guard containsDeviceIdentifier(string, identifiers: identifiers) else { return string }
      return redactSchemaIdentifier(string, identifiers: identifiers)
    }.joined(separator: "/")
    try SessionStorageValidation.relativePath(redacted)
    return redacted
  }

  private func isSchemaIdentifierPath(_ path: [String]) -> Bool {
    let pathKey = path.joined(separator: ".")
    if Self.schemaIdentifierManifestPaths.contains(pathKey) { return true }
    guard path.contains("arguments") else { return false }
    let field = path.reversed().first { $0 != "*" && $0 != "arguments" }
    return field.map(Self.workflowArgumentIdentifierKeys.contains) ?? false
  }

  private func isPreservedManifestPath(_ path: [String], pathKey: String) -> Bool {
    if Self.preservedManifestStringPaths.contains(pathKey) { return true }
    guard path.contains("arguments"), let field = path.last else { return false }
    return Self.workflowArgumentDigestKeys.contains(field)
  }

  private func rehashManifestArguments(_ root: inout [String: JSONValue]) throws {
    if case .array(let steps)? = root["steps"] {
      root["steps"] = .array(
        try steps.map { value in
          guard case .object(var step) = value else { return value }
          try rehashArguments(in: &step)
          if case .array(let descriptors)? = step["compensationDescriptors"] {
            step["compensationDescriptors"] = .array(
              try descriptors.map { descriptor in
                guard case .object(var object) = descriptor else { return descriptor }
                try rehashArguments(in: &object)
                return .object(object)
              })
          }
          return .object(step)
        })
    }
    if case .array(let compensations)? = root["compensations"] {
      root["compensations"] = .array(
        try compensations.map { value in
          guard case .object(var compensation) = value,
            case .object(var descriptor)? = compensation["descriptor"]
          else { return value }
          try rehashArguments(in: &descriptor)
          compensation["descriptor"] = .object(descriptor)
          return .object(compensation)
        })
    }
    if case .object(var recovery)? = root["recovery"],
      case .array(let descriptors)? = recovery["unexecutedCompensations"]
    {
      recovery["unexecutedCompensations"] = .array(
        try descriptors.map { value in
          guard case .object(var descriptor) = value else { return value }
          try rehashArguments(in: &descriptor)
          return .object(descriptor)
        })
      root["recovery"] = .object(recovery)
    }
  }

  private func rehashArguments(in object: inout [String: JSONValue]) throws {
    guard case .object(let arguments)? = object["arguments"], object["argumentsHash"] != nil
    else { return }
    object["argumentsHash"] = .string(
      SessionStorageValidation.lowercaseSHA256(
        try SessionStorageValidation.canonicalData(JSONValue.object(arguments))))
  }

  private func redactData(_ data: Data, identifiers: Set<String>) throws -> Data {
    try replaceIdentifiers(
      in: data, identifiers: identifiers,
      replacement: [UInt8]("[REDACTED-DEVICE-ID]".utf8))
  }

  private func replaceIdentifiers(
    in data: Data,
    identifiers: Set<String>,
    replacement: [UInt8]
  ) throws -> Data {
    let input = [UInt8](data)
    let patterns = identifiers.map { [UInt8]($0.utf8) }
      .filter { $0.count >= Self.minimumSubstringIdentifierBytes }
      .sorted { $0.count > $1.count }
    var output = Data()
    output.reserveCapacity(data.count)
    var index = 0
    while index < input.count {
      if let match = patterns.first(where: { pattern in
        index + pattern.count <= input.count
          && input[index..<(index + pattern.count)].elementsEqual(pattern)
      }) {
        guard output.count <= Self.maximumRedactedArtifactBytes - replacement.count else {
          throw SessionStorageError.invalidRecord(
            "redacted Artifact expansion exceeds 64 MiB")
        }
        output.append(contentsOf: replacement)
        index += match.count
      } else {
        guard output.count < Self.maximumRedactedArtifactBytes else {
          throw SessionStorageError.invalidRecord(
            "redacted Artifact expansion exceeds 64 MiB")
        }
        output.append(input[index])
        index += 1
      }
    }
    return output
  }

  private static let preservedManifestStringPaths: Set<String> = [
    "schemaVersion", "coreSpecBaseline", "status", "executionMode",
    "executionAuthority", "outcomeCertainty", "sessionDisposition", "createdAt", "completedAt",
    "archivedAt", "originalTarget.kind", "originalTarget.transport",
    "authorization.authorizationRef.authorizationId",
    "authorization.authorizationRef.mainCommitOID",
    "authorization.authorizationRef.authorizationBlobOID",
    "authorization.usageReservationId",
    "authorization.destructiveIntentEventIds.*",
    "bindingHistory.*.transport", "bindingHistory.*.confirmedBy",
    "bindingHistory.*.channelProtection", "toolchain.kind", "toolchain.sha256",
    "toolchain.serverOwnership", "workflow.kind", "workflow.profileVersion", "steps.*.kind",
    "steps.*.effect", "steps.*.cancellation", "steps.*.bindingRequirement",
    "steps.*.argumentsHash", "steps.*.compensationTrigger", "steps.*.disposition",
    "steps.*.outcomeCertainty", "steps.*.semanticResult",
    "steps.*.compensationDescriptors.*.kind", "steps.*.compensationDescriptors.*.effect",
    "steps.*.compensationDescriptors.*.cancellation",
    "steps.*.compensationDescriptors.*.bindingRequirement",
    "steps.*.compensationDescriptors.*.trigger",
    "steps.*.compensationDescriptors.*.argumentsHash", "parameters.*.beforeState.state",
    "parameters.*.desiredState.state", "parameters.*.afterState.state",
    "parameters.*.restoreState.state", "parameters.*.restoreDisposition",
    "compensations.*.descriptor.kind", "compensations.*.descriptor.effect",
    "compensations.*.descriptor.cancellation", "compensations.*.descriptor.bindingRequirement",
    "compensations.*.descriptor.trigger", "compensations.*.descriptor.argumentsHash",
    "compensations.*.disposition", "compensations.*.outcomeCertainty",
    "compensations.*.result", "confirmations.*.kind", "confirmations.*.scopeHash",
    "confirmations.*.decision", "confirmations.*.actor", "confirmations.*.actor.kind",
    "confirmations.*.actor.authorizationRef.authorizationId",
    "confirmations.*.actor.authorizationRef.mainCommitOID",
    "confirmations.*.actor.authorizationRef.authorizationBlobOID",
    "confirmations.*.decidedAt",
    "artifacts.*.role", "artifacts.*.sha256", "recovery.deviceHazards.*.severity",
    "recovery.deviceHazards.*.outcomeCertainty", "recovery.lastDeviceMode.state",
    "recovery.managedHostProcessState", "recovery.unexecutedCompensations.*.kind",
    "recovery.unexecutedCompensations.*.effect",
    "recovery.unexecutedCompensations.*.cancellation",
    "recovery.unexecutedCompensations.*.bindingRequirement",
    "recovery.unexecutedCompensations.*.trigger",
    "recovery.unexecutedCompensations.*.argumentsHash", "recovery.userConfirmation.actor",
    "recovery.userConfirmation.decision", "recovery.userConfirmation.confirmedAt",
  ]

  private static let schemaIdentifierManifestPaths: Set<String> = [
    "sessionId", "jobId", "steps.*.id", "steps.*.sourceStepId",
    "steps.*.compensationDescriptors.*.id",
    "parameters.*.name", "compensations.*.descriptor.id", "compensations.*.sourceStepId",
    "compensations.*.failure.code", "compensations.*.journalEventIds.*",
    "confirmations.*.confirmationId",
    "confirmations.*.relatedStepIds.*", "artifacts.*.id", "artifacts.*.derivedFrom.*",
    "failure.code", "recovery.deviceHazards.*.code", "recovery.abandonAuditEventIds.*",
    "recovery.lastConfirmedStepId", "recovery.unexecutedCompensations.*.id",
    "recovery.userConfirmation.confirmationId", "recovery.recoveryOfSessionId",
    "recovery.recoveryOfJobId",
  ]

  private static let workflowArgumentIdentifierKeys: Set<String> = [
    "artifactId", "artifactSeriesId", "bufferId", "captureStepId", "clientIdentity",
    "confirmationId", "evidencePolicy", "forwardId", "imageArtifactId", "inputArtifactIds",
    "outputArtifactId", "ownershipEvidenceId", "packageArtifactId", "probeId", "processorId",
    "name", "profileId", "promptKey", "reason", "safeBoundaryId", "sessionId",
    "snapshotStepId",
    "sourceArtifactId", "stopPolicy", "toolIdentity", "volumeIdentity",
  ]

  private static let workflowArgumentDigestKeys: Set<String> = [
    "expectedSha256", "impactSnapshotHash", "imageSha256", "packageSha256", "scopeHash",
    "sourceSha256",
  ]

  private func exportLineage(for artifact: ArtifactRecord, redacted: Bool) -> String {
    let transformation = redacted ? "redacted" : "copied"
    return
      "export:v1:\(transformation):source-role:\(artifact.role.rawValue):source-sha256:\(artifact.sha256)"
  }

  private func validate(data: Data, against artifact: ArtifactRecord) throws {
    let digest = SessionStorageValidation.lowercaseSHA256(data)
    guard UInt64(data.count) == artifact.size, digest == artifact.sha256 else {
      throw SessionStorageError.checksumMismatch(
        expected: artifact.sha256, actual: digest)
    }
  }

  private func createAndSynchronizeDirectoryChain(_ directory: URL, rootedAt root: URL) throws {
    let standardizedRoot = root.standardizedFileURL
    let standardizedDirectory = directory.standardizedFileURL
    let rootPrefix =
      standardizedRoot.path.hasSuffix("/")
      ? standardizedRoot.path : standardizedRoot.path + "/"
    guard
      standardizedDirectory == standardizedRoot
        || standardizedDirectory.path.hasPrefix(rootPrefix)
    else { throw SessionStorageError.retentionTargetEscapesRoot(directory.path) }
    try FileManager.default.createDirectory(
      at: standardizedDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var current = standardizedDirectory
    var directories: [URL] = []
    while current != standardizedRoot {
      directories.append(current)
      current = current.deletingLastPathComponent()
    }
    try DurableFilePrimitives.syncDirectory(standardizedRoot)
    for created in directories.reversed() {
      try DurableFilePrimitives.syncDirectory(created)
    }
  }

  private func requireContainedSource(
    _ source: URL,
    relativePath: String,
    layout: SessionLayout
  ) throws {
    try DurableFilePrimitives.rejectSymbolicLink(source)
    let root = layout.root.standardizedFileURL.resolvingSymlinksInPath()
    let expected = root.appending(path: relativePath).standardizedFileURL
    guard source.resolvingSymlinksInPath() == expected else {
      throw SessionStorageError.retentionTargetEscapesRoot(source.path)
    }
  }

  private func copyRegularFile(
    from source: URL,
    toParentDescriptor parentDescriptor: Int32,
    name: String,
    displayURL target: URL,
    claim: StorageClaim,
    jobID: String,
    consumedGrowthBytes: inout UInt64
  ) throws
    -> (size: UInt64, sha256: String)
  {
    let input = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard input >= 0 else {
      throw SessionStorageError.writeFailed(path: source.path, errno: errno)
    }
    defer { Darwin.close(input) }
    var metadata = stat()
    guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SessionStorageError.invalidRecord("export source must be a regular file")
    }
    let output = try claim.performOptionalWrite(bytes: 0, forJobID: jobID) {
      let descriptor = Darwin.openat(
        parentDescriptor, name,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw SessionStorageError.writeFailed(path: target.path, errno: errno)
      }
      return descriptor
    }
    var outputIsOpen = true
    defer { if outputIsOpen { Darwin.close(output) } }
    try requireClaimVolume(claim, descriptor: output)
    var hasher = SHA256()
    var byteCount: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(input, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw SessionStorageError.writeFailed(path: source.path, errno: errno)
      }
      let data = Data(buffer[0..<count])
      try claim.performOptionalWrite(bytes: UInt64(count), forJobID: jobID) {
        consumedGrowthBytes = try SessionStorageValidation.addingWithoutOverflow(
          consumedGrowthBytes, UInt64(count))
        try DurableFilePrimitives.writeAll(data, descriptor: output, path: target.path)
      }
      hasher.update(data: data)
      byteCount += UInt64(count)
    }
    try DurableFilePrimitives.fullSync(output, path: target.path)
    guard Darwin.close(output) == 0 else {
      outputIsOpen = false
      throw SessionStorageError.writeFailed(path: target.path, errno: errno)
    }
    outputIsOpen = false
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (byteCount, digest)
  }

  private func readBoundedRegularFile(_ source: URL, maximumBytes: Int) throws -> Data {
    let descriptor = Darwin.open(
      source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: source.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= maximumBytes
    else { throw SessionStorageError.invalidRecord("export source is not a bounded regular file") }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(
          path: source.path, errno: count < 0 ? errno : EIO)
      }
      offset += count
    }
    return data
  }

  private func writeExclusive(
    _ data: Data,
    toParentDescriptor parentDescriptor: Int32,
    name: String,
    displayURL target: URL,
    claim: StorageClaim,
    jobID: String,
    consumedGrowthBytes: inout UInt64
  ) throws {
    let descriptor = try claim.performOptionalWrite(bytes: 0, forJobID: jobID) {
      let opened = Darwin.openat(
        parentDescriptor, name,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard opened >= 0 else {
        throw SessionStorageError.writeFailed(path: target.path, errno: errno)
      }
      return opened
    }
    var isOpen = true
    defer { if isOpen { Darwin.close(descriptor) } }
    try requireClaimVolume(claim, descriptor: descriptor)
    try claim.performOptionalWrite(bytes: UInt64(data.count), forJobID: jobID) {
      consumedGrowthBytes = try SessionStorageValidation.addingWithoutOverflow(
        consumedGrowthBytes, UInt64(data.count))
      try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: target.path)
    }
    try DurableFilePrimitives.fullSync(descriptor, path: target.path)
    guard Darwin.close(descriptor) == 0 else {
      isOpen = false
      throw SessionStorageError.writeFailed(path: target.path, errno: errno)
    }
    isOpen = false
  }

  private func requireClaimVolume(_ claim: StorageClaim, at url: URL) throws {
    let actual = try volumeIdentityResolver.resolve(url)
    guard actual == claim.volumeIdentity else {
      throw SessionStorageError.volumeIdentityChanged(
        expected: claim.volumeIdentity, actual: actual)
    }
  }

  private func requireClaimVolume(_ claim: StorageClaim, descriptor: Int32) throws {
    let actual = try volumeIdentityResolver.resolve(openFileDescriptor: descriptor)
    guard actual == claim.volumeIdentity else {
      throw SessionStorageError.volumeIdentityChanged(
        expected: claim.volumeIdentity, actual: actual)
    }
  }
}

public struct RetainedSession: Equatable, Sendable {
  public let sessionID: String
  public let root: URL
  public let sizeBytes: UInt64
  public let completedAt: Date
  public let expiresAt: Date?
  public let isPinned: Bool

  public init(
    sessionID: String,
    root: URL,
    sizeBytes: UInt64,
    completedAt: Date,
    expiresAt: Date?,
    isPinned: Bool
  ) throws {
    try SessionStorageValidation.identifier(sessionID, field: "sessionId")
    try DurableFilePrimitives.requireAbsoluteFileURL(root)
    self.sessionID = sessionID
    self.root = root
    self.sizeBytes = sizeBytes
    self.completedAt = completedAt
    self.expiresAt = expiresAt
    self.isPinned = isPinned
  }
}

public struct SessionRetentionPlan: Equatable, Sendable {
  public let deletionSessionIDs: [String]
  public let projectedBytes: UInt64
  public let safetyTargetBytes: UInt64
  public let pinnedBytes: UInt64
  public let blocksNewHeavyWriters: Bool
}

public struct SessionRetentionController: Sendable {
  private let faultInjector: SessionStorageFaultInjector

  public init(faultInjector: SessionStorageFaultInjector = .none) {
    self.faultInjector = faultInjector
  }

  public func plan(
    sessions: [RetainedSession],
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    now: Date
  ) -> SessionRetentionPlan {
    let safetyTarget =
      totalQuotaBytes > safetyMarginBytes
      ? totalQuotaBytes - safetyMarginBytes : 0
    let total = sessions.reduce(UInt64(0)) {
      SessionStorageValidation.saturatingAdd($0, $1.sizeBytes)
    }
    let pinnedBytes = sessions.filter(\.isPinned).reduce(UInt64(0)) {
      SessionStorageValidation.saturatingAdd($0, $1.sizeBytes)
    }
    guard total > safetyTarget else {
      return SessionRetentionPlan(
        deletionSessionIDs: [], projectedBytes: total, safetyTargetBytes: safetyTarget,
        pinnedBytes: pinnedBytes, blocksNewHeavyWriters: false)
    }

    let candidates = sessions.filter { !$0.isPinned }.sorted { lhs, rhs in
      let lhsExpired = lhs.expiresAt.map { $0 <= now } ?? false
      let rhsExpired = rhs.expiresAt.map { $0 <= now } ?? false
      if lhsExpired != rhsExpired { return lhsExpired && !rhsExpired }
      if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
      return lhs.sessionID < rhs.sessionID
    }
    var projected = total
    var deletionIDs: [String] = []
    for session in candidates where projected > safetyTarget {
      deletionIDs.append(session.sessionID)
      projected = projected >= session.sizeBytes ? projected - session.sizeBytes : 0
    }
    return SessionRetentionPlan(
      deletionSessionIDs: deletionIDs,
      projectedBytes: projected,
      safetyTargetBytes: safetyTarget,
      pinnedBytes: pinnedBytes,
      blocksNewHeavyWriters: projected > safetyTarget)
  }

  public func apply(
    _ plan: SessionRetentionPlan,
    sessions: [RetainedSession],
    sessionsRoot: URL
  ) throws {
    do {
      try applyUnmapped(plan, sessions: sessions, sessionsRoot: sessionsRoot)
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  private func applyUnmapped(
    _ plan: SessionRetentionPlan,
    sessions: [RetainedSession],
    sessionsRoot: URL
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(sessionsRoot)
    try DurableFilePrimitives.rejectSymbolicLink(sessionsRoot)
    let lexicalRoot = sessionsRoot.standardizedFileURL
    var pathRootMetadata = stat()
    guard lstat(lexicalRoot.path, &pathRootMetadata) == 0,
      pathRootMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw SessionStorageError.invalidRecord("retention root is not a directory")
    }
    let rootDescriptor = Darwin.open(
      lexicalRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: lexicalRoot.path, errno: errno)
    }
    defer { Darwin.close(rootDescriptor) }
    var openedRootMetadata = stat()
    guard fstat(rootDescriptor, &openedRootMetadata) == 0,
      openedRootMetadata.st_dev == pathRootMetadata.st_dev,
      openedRootMetadata.st_ino == pathRootMetadata.st_ino
    else {
      throw SessionStorageError.invalidRecord("retention root changed while being opened")
    }
    var byID: [String: RetainedSession] = [:]
    for session in sessions {
      guard byID.updateValue(session, forKey: session.sessionID) == nil else {
        throw SessionStorageError.invalidRecord(
          "duplicate retained Session identity: \(session.sessionID)")
      }
    }
    for sessionID in plan.deletionSessionIDs {
      guard let session = byID[sessionID], !session.isPinned else {
        throw SessionStorageError.invalidRecord("retention plan references pinned/unknown Session")
      }
      let lexicalTarget = session.root.standardizedFileURL
      let lexicalRootPrefix =
        lexicalRoot.path.hasSuffix("/")
        ? lexicalRoot.path : lexicalRoot.path + "/"
      guard lexicalTarget.path.hasPrefix(lexicalRootPrefix) else {
        throw SessionStorageError.retentionTargetEscapesRoot(session.root.path)
      }
      let relativePath = String(lexicalTarget.path.dropFirst(lexicalRootPrefix.count))
      try SessionStorageValidation.relativePath(relativePath)
      let components = relativePath.split(separator: "/").map(String.init)
      guard components.count >= 3, components.last == sessionID else {
        throw SessionStorageError.retentionTargetEscapesRoot(session.root.path)
      }
      var openedParents: [Int32] = []
      var parentDescriptor = rootDescriptor
      defer {
        for descriptor in openedParents.reversed() {
          Darwin.close(descriptor)
        }
      }
      for component in components.dropLast() {
        let opened = Darwin.openat(
          parentDescriptor, component,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else {
          throw SessionStorageError.retentionTargetEscapesRoot(session.root.path)
        }
        openedParents.append(opened)
        parentDescriptor = opened
      }
      try faultInjector.check(.retentionBeforeDelete)
      try removeAnchoredDirectory(
        parentDescriptor: parentDescriptor, name: components.last!, displayPath: session.root.path)
    }
  }

  private func removeAnchoredDirectory(
    parentDescriptor: Int32,
    name: String,
    displayPath: String
  ) throws {
    let descriptor = Darwin.openat(
      parentDescriptor, name,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.invalidRecord(
        "retention target is not an anchored directory: \(displayPath)")
    }
    defer { Darwin.close(descriptor) }
    var openedMetadata = stat()
    guard fstat(descriptor, &openedMetadata) == 0,
      openedMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw SessionStorageError.invalidRecord("retention target is not a directory")
    }
    for childName in try directoryEntryNames(descriptor: descriptor, path: displayPath) {
      var childMetadata = stat()
      guard fstatat(descriptor, childName, &childMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw SessionStorageError.writeFailed(path: "\(displayPath)/\(childName)", errno: errno)
      }
      if childMetadata.st_mode & S_IFMT == S_IFDIR {
        try removeAnchoredDirectory(
          parentDescriptor: descriptor, name: childName,
          displayPath: "\(displayPath)/\(childName)")
      } else {
        guard Darwin.unlinkat(descriptor, childName, 0) == 0 else {
          throw SessionStorageError.writeFailed(
            path: "\(displayPath)/\(childName)", errno: errno)
        }
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
    var currentMetadata = stat()
    guard fstatat(parentDescriptor, name, &currentMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      currentMetadata.st_mode & S_IFMT == S_IFDIR,
      currentMetadata.st_dev == openedMetadata.st_dev,
      currentMetadata.st_ino == openedMetadata.st_ino
    else {
      throw SessionStorageError.invalidRecord(
        "retention target changed during anchored deletion: \(displayPath)")
    }
    guard Darwin.unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
    guard Darwin.fsync(parentDescriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
  }

  private func directoryEntryNames(descriptor: Int32, path: String) throws -> [String] {
    let duplicated = Darwin.dup(descriptor)
    guard duplicated >= 0 else {
      throw SessionStorageError.writeFailed(path: path, errno: errno)
    }
    guard let directory = fdopendir(duplicated) else {
      let failure = errno
      Darwin.close(duplicated)
      throw SessionStorageError.writeFailed(path: path, errno: failure)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw SessionStorageError.writeFailed(path: path, errno: errno)
        }
        break
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(
          decoding: bytes.prefix(Int(entry.pointee.d_namlen)).map { UInt8($0) },
          as: UTF8.self)
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names
  }
}
