import CryptoKit
import Darwin
import Foundation

public enum ArtifactRole: String, Codable, CaseIterable, Sendable {
  case raw
  case derived
  case log
  case plan
  case diagnostic
  case partial
}

public struct ArtifactRecord: Codable, Equatable, Sendable {
  public let id: String
  public let role: ArtifactRole
  public let origin: String
  public let relativePath: String
  public let size: UInt64
  public let sha256: String
  public let mediaType: String?
  public let derivedFrom: [String]?

  public init(
    id: String,
    role: ArtifactRole,
    origin: String,
    relativePath: String,
    size: UInt64,
    sha256: String,
    mediaType: String? = nil,
    derivedFrom: [String]? = nil
  ) throws {
    try SessionStorageValidation.identifier(id, field: "artifact.id")
    try SessionStorageValidation.relativePath(relativePath)
    try SessionStorageValidation.sha256(sha256, field: "artifact.sha256")
    guard !origin.isEmpty, mediaType.map({ !$0.isEmpty }) ?? true,
      derivedFrom.map({ Set($0).count == $0.count }) ?? true
    else { throw SessionStorageError.invalidArtifact(id) }
    if let derivedFrom {
      for sourceID in derivedFrom {
        try SessionStorageValidation.identifier(sourceID, field: "artifact.derivedFrom")
      }
    }
    if role == .derived {
      guard let derivedFrom, !derivedFrom.isEmpty else {
        throw SessionStorageError.invalidArtifact("derived Artifact requires lineage")
      }
      let provenance = try DerivedArtifactProvenance(manifestOrigin: origin)
      guard provenance.inputHashes.count == derivedFrom.count else {
        throw SessionStorageError.invalidArtifact(
          "derived Artifact provenance does not match lineage")
      }
    } else if derivedFrom != nil {
      throw SessionStorageError.invalidArtifact(
        "non-derived Artifact cannot declare derivedFrom")
    }
    self.id = id
    self.role = role
    self.origin = origin
    self.relativePath = relativePath
    self.size = size
    self.sha256 = sha256.lowercased()
    self.mediaType = mediaType
    self.derivedFrom = derivedFrom
  }

  private enum CodingKeys: String, CodingKey {
    case id, role, origin, relativePath, size, sha256, mediaType, derivedFrom
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: ArtifactRecordAnyCodingKey.self)
    let keys = Set(dynamic.allKeys.map(\.stringValue))
    let required: Set<String> = ["id", "role", "origin", "relativePath", "size", "sha256"]
    let allowed = required.union(["mediaType", "derivedFrom"])
    guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
      throw SessionStorageError.invalidArtifact("unknown or missing Artifact record field")
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      role: container.decode(ArtifactRole.self, forKey: .role),
      origin: container.decode(String.self, forKey: .origin),
      relativePath: container.decode(String.self, forKey: .relativePath),
      size: container.decode(UInt64.self, forKey: .size),
      sha256: container.decode(String.self, forKey: .sha256),
      mediaType: container.decodeIfPresent(String.self, forKey: .mediaType),
      derivedFrom: container.decodeIfPresent([String].self, forKey: .derivedFrom))
  }
}

private struct ArtifactRecordAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

public struct ArtifactPublicationRequest: Sendable {
  public let artifactID: String
  public let role: ArtifactRole
  public let publicationName: String
  public let origin: String
  public let mediaType: String?
  public let derivedFrom: [String]?
  public let expectedSHA256: String?
  public let requiredPrefix: Data?
  let derivedSourceArtifacts: [ArtifactRecord]

  public init(
    artifactID: String,
    role: ArtifactRole,
    publicationName: String,
    origin: String,
    mediaType: String? = nil,
    derivedFrom: [String]? = nil,
    expectedSHA256: String? = nil,
    requiredPrefix: Data? = nil
  ) throws {
    try SessionStorageValidation.identifier(artifactID, field: "artifactId")
    try SessionStorageValidation.relativePath(publicationName)
    guard !publicationName.contains("/"), role != .partial, role != .derived, !origin.isEmpty,
      requiredPrefix?.count ?? 0 <= 4 * 1_024
    else {
      throw SessionStorageError.invalidArtifact(publicationName)
    }
    if let expectedSHA256 {
      try SessionStorageValidation.sha256(expectedSHA256, field: "expectedSha256")
    }
    guard derivedFrom == nil else {
      throw SessionStorageError.invalidArtifact(
        "non-derived Artifact cannot declare derivedFrom")
    }
    self.artifactID = artifactID
    self.role = role
    self.publicationName = publicationName
    self.origin = origin
    self.mediaType = mediaType
    self.derivedFrom = derivedFrom
    self.expectedSHA256 = expectedSHA256?.lowercased()
    self.requiredPrefix = requiredPrefix
    derivedSourceArtifacts = []
  }

  public init(
    derivedArtifactID artifactID: String,
    publicationName: String,
    provenance: DerivedArtifactProvenance,
    sourceArtifacts: [ArtifactRecord],
    mediaType: String? = nil,
    expectedSHA256: String? = nil,
    requiredPrefix: Data? = nil
  ) throws {
    try SessionStorageValidation.identifier(artifactID, field: "artifactId")
    try SessionStorageValidation.relativePath(publicationName)
    guard !publicationName.contains("/"), !sourceArtifacts.isEmpty,
      requiredPrefix?.count ?? 0 <= 4 * 1_024,
      mediaType.map({ !$0.isEmpty }) ?? true
    else { throw SessionStorageError.invalidArtifact(publicationName) }
    if let expectedSHA256 {
      try SessionStorageValidation.sha256(expectedSHA256, field: "expectedSha256")
    }
    let sourceIDs = sourceArtifacts.map(\.id)
    guard Set(sourceIDs).count == sourceIDs.count,
      !sourceIDs.contains(artifactID),
      sourceArtifacts.allSatisfy({ $0.role != .partial }),
      provenance.inputHashes == sourceArtifacts.map(\.sha256),
      !sourceArtifacts.contains(where: { $0.derivedFrom?.contains(artifactID) == true })
    else {
      throw SessionStorageError.invalidArtifact(
        "derived Artifact provenance does not match its source Artifacts")
    }
    self.artifactID = artifactID
    role = .derived
    self.publicationName = publicationName
    origin = try provenance.manifestOrigin()
    self.mediaType = mediaType
    derivedFrom = sourceIDs
    self.expectedSHA256 = expectedSHA256?.lowercased()
    self.requiredPrefix = requiredPrefix
    derivedSourceArtifacts = sourceArtifacts
  }
}

public struct PublishedArtifact: Equatable, Sendable {
  public let record: ArtifactRecord
  public let url: URL
}

public struct PartialArtifact: Equatable, Sendable {
  public let url: URL
  public let size: UInt64
}

final class AnchoredSessionArtifactDirectories {
  struct DirectoryLink {
    let parentDescriptor: Int32
    let name: String
    let descriptor: Int32
    let metadata: stat
    let displayPath: String
  }

  let layout: SessionLayout
  let rootDescriptor: Int32
  let artifactsDescriptor: Int32
  let rawDescriptor: Int32
  let derivedDescriptor: Int32
  let partialDescriptor: Int32
  let rootDevice: dev_t
  private let rootMetadata: stat
  private let artifactLinks: [DirectoryLink]

  init(layout: SessionLayout) throws {
    self.layout = layout
    var opened: [Int32] = []
    do {
      let root = Darwin.open(
        layout.root.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard root >= 0 else {
        throw SessionStorageError.writeFailed(path: layout.root.path, errno: errno)
      }
      opened.append(root)
      let rootMetadata = try Self.validateRoot(descriptor: root, layout: layout)
      let artifacts = try Self.openDirectory(
        parent: root, name: "artifacts", rootDevice: rootMetadata.st_dev,
        displayPath: layout.root.appending(path: "artifacts").path)
      opened.append(artifacts.descriptor)
      let raw = try Self.openDirectory(
        parent: artifacts.descriptor, name: "raw", rootDevice: rootMetadata.st_dev,
        displayPath: layout.rawDirectory.path)
      opened.append(raw.descriptor)
      let derived = try Self.openDirectory(
        parent: artifacts.descriptor, name: "derived", rootDevice: rootMetadata.st_dev,
        displayPath: layout.derivedDirectory.path)
      opened.append(derived.descriptor)
      let partial = try Self.openDirectory(
        parent: artifacts.descriptor, name: "partial", rootDevice: rootMetadata.st_dev,
        displayPath: layout.partialDirectory.path)
      opened.append(partial.descriptor)

      self.rootDescriptor = root
      self.artifactsDescriptor = artifacts.descriptor
      self.rawDescriptor = raw.descriptor
      self.derivedDescriptor = derived.descriptor
      self.partialDescriptor = partial.descriptor
      self.rootDevice = rootMetadata.st_dev
      self.rootMetadata = rootMetadata
      self.artifactLinks = [
        DirectoryLink(
          parentDescriptor: root, name: "artifacts", descriptor: artifacts.descriptor,
          metadata: artifacts.metadata,
          displayPath: layout.root.appending(path: "artifacts").path),
        DirectoryLink(
          parentDescriptor: artifacts.descriptor, name: "raw", descriptor: raw.descriptor,
          metadata: raw.metadata, displayPath: layout.rawDirectory.path),
        DirectoryLink(
          parentDescriptor: artifacts.descriptor, name: "derived",
          descriptor: derived.descriptor, metadata: derived.metadata,
          displayPath: layout.derivedDirectory.path),
        DirectoryLink(
          parentDescriptor: artifacts.descriptor, name: "partial",
          descriptor: partial.descriptor, metadata: partial.metadata,
          displayPath: layout.partialDirectory.path),
      ]
    } catch {
      for descriptor in opened.reversed() { Darwin.close(descriptor) }
      throw error
    }
  }

  deinit {
    Darwin.close(partialDescriptor)
    Darwin.close(derivedDescriptor)
    Darwin.close(rawDescriptor)
    Darwin.close(artifactsDescriptor)
    Darwin.close(rootDescriptor)
  }

  func validateBindings() throws {
    _ = try Self.validateRoot(descriptor: rootDescriptor, layout: layout)
    for link in artifactLinks {
      try Self.validate(link: link, rootDevice: rootMetadata.st_dev)
    }
  }

  func syncDirectory(_ descriptor: Int32, path: String) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: path, errno: errno)
    }
  }

  func entryNames(descriptor: Int32, path: String) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw SessionStorageError.writeFailed(path: path, errno: errno)
    }
    guard let directory = fdopendir(duplicate) else {
      let failure = errno
      Darwin.close(duplicate)
      throw SessionStorageError.writeFailed(path: path, errno: failure)
    }
    defer { closedir(directory) }
    // The duplicated descriptor shares the original's directory offset; rewind so repeated
    // enumerations of the same anchored descriptor always observe the full directory.
    rewinddir(directory)
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        if errno != 0 {
          throw SessionStorageError.writeFailed(path: path, errno: errno)
        }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names.sorted()
  }

  func snapshot(record: ArtifactRecord) throws -> AnchoredManifestArtifactSnapshot {
    try AnchoredManifestArtifactSnapshot(directories: self, record: record)
  }

  private static func validateRoot(descriptor: Int32, layout: SessionLayout) throws -> stat {
    var opened = stat()
    var path = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      lstat(layout.root.path, &path) == 0, path.st_mode & S_IFMT == S_IFDIR,
      path.st_dev == opened.st_dev, path.st_ino == opened.st_ino
    else {
      throw SessionStorageError.invalidArtifact(
        "Session root is not an anchored owner-safe directory")
    }
    return opened
  }

  private static func openDirectory(
    parent: Int32,
    name: String,
    rootDevice: dev_t,
    displayPath: String
  ) throws -> (descriptor: Int32, metadata: stat) {
    let descriptor = Darwin.openat(
      parent, name, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
    }
    var isOpen = true
    defer { if isOpen { Darwin.close(descriptor) } }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      metadata.st_dev == rootDevice
    else {
      throw SessionStorageError.invalidArtifact("unsafe Artifact directory: \(displayPath)")
    }
    isOpen = false
    return (descriptor, metadata)
  }

  private static func validate(link: DirectoryLink, rootDevice: dev_t) throws {
    var opened = stat()
    var path = stat()
    guard fstat(link.descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_dev == rootDevice,
      fstatat(link.parentDescriptor, link.name, &path, AT_SYMLINK_NOFOLLOW) == 0,
      path.st_mode & S_IFMT == S_IFDIR, path.st_dev == opened.st_dev,
      path.st_ino == opened.st_ino, opened.st_dev == link.metadata.st_dev,
      opened.st_ino == link.metadata.st_ino
    else {
      throw SessionStorageError.invalidArtifact(
        "Artifact directory path changed during publication: \(link.displayPath)")
    }
  }
}

final class AnchoredManifestArtifactSnapshot {
  private let directories: AnchoredSessionArtifactDirectories
  private let record: ArtifactRecord
  private let links: [AnchoredSessionArtifactDirectories.DirectoryLink]
  private let fileDescriptor: Int32
  private let fileParentDescriptor: Int32
  private let fileName: String
  private let initialMetadata: stat

  init(directories: AnchoredSessionArtifactDirectories, record: ArtifactRecord) throws {
    self.directories = directories
    self.record = record
    let components = record.relativePath.split(separator: "/").map(String.init)
    guard let fileName = components.last else {
      throw SessionStorageError.invalidArtifact("Artifact path is empty")
    }
    var openedDirectories: [Int32] = []
    var links: [AnchoredSessionArtifactDirectories.DirectoryLink] = []
    var parent = directories.rootDescriptor
    do {
      for (index, component) in components.dropLast().enumerated() {
        let displayPath = directories.layout.root
          .appending(path: components.prefix(index + 1).joined(separator: "/")).path
        let opened = Darwin.openat(
          parent, component,
          O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else {
          if errno == ELOOP || errno == ENOTDIR {
            throw SessionStorageError.invalidArtifact(
              "Artifact path contains a symbolic link: \(displayPath)")
          }
          throw SessionStorageError.writeFailed(path: displayPath, errno: errno)
        }
        openedDirectories.append(opened)
        var metadata = stat()
        guard fstat(opened, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_uid == geteuid(),
          metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            && metadata.st_dev == directories.rootDevice
        else {
          throw SessionStorageError.invalidArtifact(
            "unsafe Artifact path component: \(displayPath)")
        }
        links.append(
          .init(
            parentDescriptor: parent, name: component, descriptor: opened,
            metadata: metadata, displayPath: displayPath))
        parent = opened
      }
      let file = Darwin.openat(
        parent, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard file >= 0 else {
        if errno == ELOOP || errno == ENOTDIR {
          throw SessionStorageError.invalidArtifact(
            "Artifact path contains a symbolic link: \(record.relativePath)")
        }
        throw SessionStorageError.writeFailed(
          path: directories.layout.root.appending(path: record.relativePath).path,
          errno: errno)
      }
      var metadata = stat()
      guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == geteuid(), metadata.st_nlink == 1,
        metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
        metadata.st_dev == directories.rootDevice, metadata.st_size >= 0
      else {
        Darwin.close(file)
        throw SessionStorageError.invalidArtifact(
          "Artifact manifest path is not an owner-safe regular file: \(record.relativePath)")
      }
      self.links = links
      self.fileDescriptor = file
      self.fileParentDescriptor = parent
      self.fileName = fileName
      self.initialMetadata = metadata
    } catch {
      for descriptor in openedDirectories.reversed() { Darwin.close(descriptor) }
      throw error
    }
    try validate()
  }

  deinit {
    Darwin.close(fileDescriptor)
    for link in links.reversed() { Darwin.close(link.descriptor) }
  }

  func validate() throws {
    try directories.validateBindings()
    for link in links {
      var opened = stat()
      var path = stat()
      guard fstat(link.descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
        opened.st_uid == geteuid(), opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
        opened.st_dev == directories.rootDevice,
        fstatat(link.parentDescriptor, link.name, &path, AT_SYMLINK_NOFOLLOW) == 0,
        path.st_mode & S_IFMT == S_IFDIR, path.st_dev == opened.st_dev,
        path.st_ino == opened.st_ino, opened.st_dev == link.metadata.st_dev,
        opened.st_ino == link.metadata.st_ino
      else {
        throw SessionStorageError.invalidArtifact(
          "Artifact path component changed before manifest commit: \(link.displayPath)")
      }
    }
    var current = stat()
    var path = stat()
    guard fstat(fileDescriptor, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
      current.st_uid == geteuid(), current.st_nlink == 1,
      current.st_mode & (S_IWGRP | S_IWOTH) == 0,
      current.st_dev == directories.rootDevice,
      fstatat(fileParentDescriptor, fileName, &path, AT_SYMLINK_NOFOLLOW) == 0,
      path.st_mode & S_IFMT == S_IFREG, path.st_dev == current.st_dev,
      path.st_ino == current.st_ino, sameFileIdentityAndContent(initialMetadata, current),
      current.st_size >= 0, UInt64(current.st_size) == record.size
    else {
      throw SessionStorageError.invalidArtifact(
        "Artifact path/size changed before manifest commit: \(record.relativePath)")
    }
    var hasher = SHA256()
    var offset: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < current.st_size {
      let count = Darwin.pread(
        fileDescriptor, &buffer, min(buffer.count, Int(current.st_size - offset)), off_t(offset))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(
          path: record.relativePath, errno: count < 0 ? errno : EIO)
      }
      hasher.update(data: Data(buffer[0..<count]))
      offset += Int64(count)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    var final = stat()
    guard digest == record.sha256, fstat(fileDescriptor, &final) == 0,
      sameFileIdentityAndContent(current, final)
    else {
      throw SessionStorageError.invalidArtifact(
        "Artifact bytes do not match manifest metadata: \(record.relativePath)")
    }
  }
}

struct ArtifactPublicationRecoveryRecord: Codable, Equatable {
  static let maximumCanonicalBytes = 64 * 1_024

  let schemaVersion: String
  let record: ArtifactRecord

  init(record: ArtifactRecord) {
    schemaVersion = "1.0.0"
    self.record = record
  }
}

final class ArtifactRecoveryMarkerCleanupPlan {
  struct Marker {
    let name: String
    let device: dev_t
    let inode: ino_t
  }

  let directories: AnchoredSessionArtifactDirectories
  let markers: [Marker]
  let artifacts: [AnchoredManifestArtifactSnapshot]

  init(
    directories: AnchoredSessionArtifactDirectories,
    markers: [Marker],
    artifacts: [AnchoredManifestArtifactSnapshot]
  ) {
    self.directories = directories
    self.markers = markers
    self.artifacts = artifacts
  }

  func validateArtifacts() throws {
    try directories.validateBindings()
    for artifact in artifacts { try artifact.validate() }
  }
}

enum ArtifactPublicationRecoveryStore {
  static func preflightCommit(
    layout: SessionLayout,
    artifacts: [ArtifactRecord],
    directories: AnchoredSessionArtifactDirectories
  ) throws -> ArtifactRecoveryMarkerCleanupPlan {
    try directories.validateBindings()
    let entries = try directories.entryNames(
      descriptor: directories.partialDescriptor, path: layout.partialDirectory.path)
    let names = entries.filter {
      $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
    }.sorted()
    var markers: [ArtifactRecoveryMarkerCleanupPlan.Marker] = []
    for name in names {
      let snapshot = try read(name: name, layout: layout, directories: directories)
      guard snapshot.recovery.schemaVersion == "1.0.0",
        markerURL(layout: layout, artifact: snapshot.recovery.record).lastPathComponent == name
      else {
        throw SessionStorageError.invalidArtifact(
          "Artifact recovery marker conflicts with proposed terminal manifest")
      }
      if !artifacts.contains(snapshot.recovery.record) {
        // A marker the terminal manifest does not own is tolerated only while its publication
        // provably never completed: the final path must be absent. The partial/marker pair then
        // stays behind as recovery evidence (roll-forward remains possible by republishing with
        // the completed partial as the source) without ever blocking terminal publication.
        // A durable final the manifest omits is still a conflict.
        let record = snapshot.recovery.record
        let finalName = record.relativePath.split(separator: "/").last.map(String.init) ?? ""
        let finalDirectoryDescriptor =
          record.role == .derived ? directories.derivedDescriptor : directories.rawDescriptor
        var finalMetadata = stat()
        if fstatat(finalDirectoryDescriptor, finalName, &finalMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
          throw SessionStorageError.invalidArtifact(
            "Artifact recovery marker conflicts with proposed terminal manifest")
        }
        guard errno == ENOENT else {
          throw SessionStorageError.writeFailed(
            path: layout.partialDirectory.appending(path: name).path, errno: errno)
        }
        continue
      }
      markers.append(
        .init(
          name: name, device: snapshot.metadata.st_dev,
          inode: snapshot.metadata.st_ino))
    }
    // Orphaned marker temporaries are crash residue from an interrupted marker write. No live
    // writer can exist here (the publisher holds the terminal lock plus every shard), so they
    // are reclaimed with the same descriptor-bound identity guard as committed markers.
    for name in entries.filter({
      $0.hasPrefix(".publication-marker.") && $0.hasSuffix(".tmp")
    }).sorted() {
      var metadata = stat()
      guard fstatat(directories.partialDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
      else {
        if errno == ENOENT { continue }
        throw SessionStorageError.writeFailed(
          path: layout.partialDirectory.appending(path: name).path, errno: errno)
      }
      guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
      markers.append(.init(name: name, device: metadata.st_dev, inode: metadata.st_ino))
    }
    let artifactSnapshots = try artifacts.map { try directories.snapshot(record: $0) }
    return ArtifactRecoveryMarkerCleanupPlan(
      directories: directories, markers: markers, artifacts: artifactSnapshots)
  }

  static func cleanupCommitted(
    layout: SessionLayout,
    plan: ArtifactRecoveryMarkerCleanupPlan,
    faultInjector: SessionStorageFaultInjector
  ) throws {
    try plan.directories.validateBindings()
    for marker in plan.markers {
      var pathMetadata = stat()
      if fstatat(
        plan.directories.partialDescriptor, marker.name, &pathMetadata,
        AT_SYMLINK_NOFOLLOW) != 0
      {
        guard errno == ENOENT else {
          throw SessionStorageError.writeFailed(
            path: layout.partialDirectory.appending(path: marker.name).path, errno: errno)
        }
        continue
      }
      // A path replaced after preflight is not part of this commit. Leave it as recovery evidence;
      // the durable manifest already owns only the descriptor-bound marker snapshot.
      guard pathMetadata.st_mode & S_IFMT == S_IFREG,
        pathMetadata.st_dev == marker.device, pathMetadata.st_ino == marker.inode
      else {
        continue
      }
      try faultInjector.check(.artifactRecoveryRecordCleanup)
      guard Darwin.unlinkat(plan.directories.partialDescriptor, marker.name, 0) == 0 else {
        if errno == ENOENT { continue }
        throw SessionStorageError.writeFailed(
          path: layout.partialDirectory.appending(path: marker.name).path, errno: errno)
      }
      try faultInjector.check(.artifactRecoveryRecordCleanupDirectorySync)
    }
    // This barrier also repairs a prior attempt that unlinked its last marker before reporting a
    // directory-sync fault. At this point the terminal manifest already owns every ArtifactRecord.
    try plan.directories.syncDirectory(
      plan.directories.partialDescriptor, path: layout.partialDirectory.path)
  }

  private static func markerURL(layout: SessionLayout, artifact: ArtifactRecord) -> URL {
    let publicationName = artifact.relativePath.split(separator: "/").last.map(String.init) ?? ""
    let publicationKey = SessionStorageValidation.lowercaseSHA256(
      Data("\(artifact.id)\u{0}\(artifact.role.rawValue)\u{0}\(publicationName)".utf8))
    return layout.partialDirectory.appending(
      path: ".publication-\(publicationKey).json")
  }

  private static func read(
    name: String,
    layout: SessionLayout,
    directories: AnchoredSessionArtifactDirectories
  ) throws -> (
    recovery: ArtifactPublicationRecoveryRecord, metadata: stat
  ) {
    let url = layout.partialDirectory.appending(path: name)
    let descriptor = Darwin.openat(
      directories.partialDescriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= ArtifactPublicationRecoveryRecord.maximumCanonicalBytes
    else { throw SessionStorageError.invalidArtifact("invalid Artifact recovery marker") }
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
          path: url.path, errno: count < 0 ? errno : EIO)
      }
      offset += count
    }
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let recovery = try JSONDecoder().decode(ArtifactPublicationRecoveryRecord.self, from: data)
    var pathMetadata = stat()
    guard
      fstatat(
        directories.partialDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      pathMetadata.st_dev == metadata.st_dev, pathMetadata.st_ino == metadata.st_ino
    else {
      throw SessionStorageError.invalidArtifact(
        "Artifact recovery marker path changed during preflight")
    }
    return (recovery, metadata)
  }
}

enum SessionArtifactPublicationBarrier {
  private static let shards = "0123456789abcdef".map(String.init)

  static func acquireShard(
    directories: AnchoredSessionArtifactDirectories,
    publicationKey: String
  ) throws -> Int32 {
    let name = ".publication-lock-\(publicationKey.prefix(1)).lock"
    let url = directories.layout.partialDirectory.appending(path: name)
    let descriptor = Darwin.openat(
      directories.partialDescriptor, name,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    var isOpen = true
    defer { if isOpen { Darwin.close(descriptor) } }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw SessionStorageError.invalidArtifact("unsafe Artifact publication lock")
    }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    // flock identity is the inode. A lock file unlinked/recreated while this caller was blocked
    // would leave two holders on different inodes; re-verify the path still owns the locked
    // inode after acquisition, exactly like the terminal publication lock does.
    var lockedMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &lockedMetadata) == 0,
      fstatat(directories.partialDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      lockedMetadata.st_mode & S_IFMT == S_IFREG,
      lockedMetadata.st_uid == geteuid(), lockedMetadata.st_nlink == 1,
      lockedMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      lockedMetadata.st_dev == pathMetadata.st_dev,
      lockedMetadata.st_ino == pathMetadata.st_ino
    else {
      throw SessionStorageError.invalidArtifact(
        "Artifact publication lock path changed after acquisition")
    }
    isOpen = false
    return descriptor
  }

  static func withAllShards<T>(
    layout: SessionLayout,
    body: (AnchoredSessionArtifactDirectories) throws -> T
  ) throws -> T {
    let directories = try AnchoredSessionArtifactDirectories(layout: layout)
    var descriptors: [Int32] = []
    defer {
      for descriptor in descriptors.reversed() {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
      }
    }
    for shard in shards {
      descriptors.append(
        try acquireShard(directories: directories, publicationKey: shard))
    }
    try directories.validateBindings()
    return try body(directories)
  }
}

private struct ReusablePublicationPartial {
  let descriptor: Int32
  let metadata: stat
  let size: UInt64
  let sha256: String
  let prefix: Data
}

public final class SessionArtifactStore: @unchecked Sendable {
  public let layout: SessionLayout
  private let faultInjector: SessionStorageFaultInjector
  private let volumeIdentityResolver: any VolumeIdentityResolving

  public init(
    layout: SessionLayout,
    faultInjector: SessionStorageFaultInjector = .none,
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver()
  ) {
    self.layout = layout
    self.faultInjector = faultInjector
    self.volumeIdentityResolver = volumeIdentityResolver
  }

  public func publish(
    from sourceURL: URL,
    request: ArtifactPublicationRequest,
    claim: StorageClaim
  ) throws
    -> PublishedArtifact
  {
    try SessionStorageValidation.mappingDurableFileErrors {
      try publishUnmapped(from: sourceURL, request: request, claim: claim)
    }
  }

  private func publishUnmapped(
    from sourceURL: URL,
    request: ArtifactPublicationRequest,
    claim: StorageClaim
  ) throws -> PublishedArtifact {
    try claim.requireOptionalWriteAuthorization(forJobID: layout.jobID)
    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try DurableFilePrimitives.requireAbsoluteFileURL(sourceURL)
    try DurableFilePrimitives.rejectSymbolicLink(sourceURL)
    let directories = try AnchoredSessionArtifactDirectories(layout: layout)
    try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
    try claim.requireSessionBinding(
      sessionID: layout.sessionID, root: layout.root,
      rootDescriptor: directories.rootDescriptor)
    let directory = request.role == .derived ? layout.derivedDirectory : layout.rawDirectory
    let targetDescriptor =
      request.role == .derived ? directories.derivedDescriptor : directories.rawDescriptor
    let relativeDirectory = request.role == .derived ? "artifacts/derived" : "artifacts/raw"
    let finalURL = directory.appending(path: request.publicationName)
    let publicationKey = SessionStorageValidation.lowercaseSHA256(
      Data("\(request.artifactID)\u{0}\(request.role.rawValue)\u{0}\(request.publicationName)".utf8)
    )
    let temporaryURL = layout.partialDirectory.appending(
      path: "\(publicationKey).part")
    let temporaryName = temporaryURL.lastPathComponent
    let recoveryURL = layout.partialDirectory.appending(
      path: ".publication-\(publicationKey).json")
    let recoveryName = recoveryURL.lastPathComponent

    // O_NONBLOCK ensures a FIFO cannot block the store before fstat rejects it.
    let source = Darwin.open(sourceURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard source >= 0 else {
      throw SessionStorageError.writeFailed(path: sourceURL.path, errno: errno)
    }
    defer { Darwin.close(source) }
    var sourceMetadata = stat()
    guard fstat(source, &sourceMetadata) == 0 else {
      throw SessionStorageError.writeFailed(path: sourceURL.path, errno: errno)
    }
    guard sourceMetadata.st_mode & S_IFMT == S_IFREG else {
      throw SessionStorageError.invalidArtifact("publication source must be a regular file")
    }

    try faultInjector.check(.artifactPublicationLock)
    let publicationLock = try SessionArtifactPublicationBarrier.acquireShard(
      directories: directories, publicationKey: publicationKey)
    defer {
      flock(publicationLock, LOCK_UN)
      Darwin.close(publicationLock)
    }
    try claim.requireOptionalWriteAuthorization(forJobID: layout.jobID)
    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
    try directories.validateBindings()
    try requireTerminalManifestAbsent(directories: directories)
    let derivedSourceSnapshots = try request.derivedSourceArtifacts.map {
      try directories.snapshot(record: $0)
    }
    var recoveryMetadata = stat()
    if fstatat(
      directories.partialDescriptor, recoveryName, &recoveryMetadata,
      AT_SYMLINK_NOFOLLOW) == 0
    {
      return try recoverPublication(
        sourceDescriptor: source, request: request, claim: claim,
        finalURL: finalURL, temporaryURL: temporaryURL, recoveryURL: recoveryURL,
        directories: directories, targetDescriptor: targetDescriptor,
        derivedSourceSnapshots: derivedSourceSnapshots)
    } else if errno != ENOENT {
      throw SessionStorageError.writeFailed(path: recoveryURL.path, errno: errno)
    }
    var existingFinalMetadata = stat()
    if fstatat(
      targetDescriptor, request.publicationName, &existingFinalMetadata,
      AT_SYMLINK_NOFOLLOW) == 0
    {
      // This also repairs a recovery-marker deletion whose directory barrier failed after unlink.
      try directories.syncDirectory(
        directories.partialDescriptor, path: layout.partialDirectory.path)
      throw SessionStorageError.artifactAlreadyPublished(finalURL.path)
    } else if errno != ENOENT {
      throw SessionStorageError.writeFailed(path: finalURL.path, errno: errno)
    }
    let reusablePartial = try prepareExistingPartial(
      sourceDescriptor: source, temporaryName: temporaryName, temporaryURL: temporaryURL,
      claim: claim, directories: directories,
      requiredPrefixCount: request.requiredPrefix?.count ?? 0)

    let destination: Int32
    let destinationMetadata: stat
    if let reusablePartial {
      destination = reusablePartial.descriptor
      destinationMetadata = reusablePartial.metadata
    } else {
      destination = try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
        let descriptor = Darwin.openat(
          directories.partialDescriptor, temporaryName,
          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
          throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
        }
        return descriptor
      }
      destinationMetadata = try publicationFileMetadata(
        descriptor: destination, path: temporaryURL.path)
    }
    var destinationIsOpen = true
    defer {
      if destinationIsOpen { Darwin.close(destination) }
    }
    try requireClaimVolume(claim, descriptor: destination)
    try SessionStorageValidation.mappingDurableFileErrors {
      try faultInjector.check(.artifactPartialDirectorySync)
      try directories.syncDirectory(
        directories.partialDescriptor, path: layout.partialDirectory.path)
    }

    let byteCount: UInt64
    let prefix: Data
    let digest: String
    let requiredPrefixCount = request.requiredPrefix?.count ?? 0
    if let reusablePartial {
      byteCount = reusablePartial.size
      prefix = reusablePartial.prefix
      digest = reusablePartial.sha256
    } else {
      var hasher = SHA256()
      var writtenBytes: UInt64 = 0
      var chargedBytes: UInt64 = 0
      var capturedPrefix = Data()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      do {
        while true {
          let count = Darwin.read(source, &buffer, buffer.count)
          if count == 0 { break }
          guard count > 0 else {
            if errno == EINTR { continue }
            throw SessionStorageError.writeFailed(path: sourceURL.path, errno: errno)
          }
          let chunk = Data(buffer[0..<count])
          try faultInjector.check(.artifactWrite)
          try claim.performOptionalWrite(bytes: UInt64(count), forJobID: layout.jobID) {
            chargedBytes = try SessionStorageValidation.addingWithoutOverflow(
              chargedBytes, UInt64(count))
            try SessionStorageValidation.mappingDurableFileErrors {
              try DurableFilePrimitives.writeAll(
                chunk, descriptor: destination, path: temporaryURL.path)
            }
          }
          hasher.update(data: chunk)
          writtenBytes += UInt64(count)
          if capturedPrefix.count < requiredPrefixCount {
            capturedPrefix.append(chunk.prefix(requiredPrefixCount - capturedPrefix.count))
          }
        }
      } catch {
        // A low-level write may persist only part of a pre-authorized chunk. Keep accounting
        // for the bytes that remain in the recoverable partial, but refund the unwritten tail.
        var partialMetadata = stat()
        if fstat(destination, &partialMetadata) == 0, partialMetadata.st_size >= 0 {
          let persistedBytes = UInt64(partialMetadata.st_size)
          if chargedBytes > persistedBytes {
            try? claim.refundOptionalWrite(bytes: chargedBytes - persistedBytes)
          }
        }
        throw error
      }
      byteCount = writtenBytes
      prefix = capturedPrefix
      digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    try faultInjector.check(.artifactSourceValidation)
    try validateStablePublicationSource(
      descriptor: source, initialMetadata: sourceMetadata, byteCount: byteCount)

    if request.role == .raw, Darwin.fchmod(destination, S_IRUSR) != 0 {
      throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
    }
    try SessionStorageValidation.mappingDurableFileErrors {
      try faultInjector.check(.artifactFileSync)
      try DurableFilePrimitives.fullSync(destination, path: temporaryURL.path)
    }
    try faultInjector.check(.artifactValidation)
    guard byteCount > 0 else { throw SessionStorageError.emptyArtifact }
    if let requiredPrefix = request.requiredPrefix, prefix != requiredPrefix {
      throw SessionStorageError.invalidArtifact("basic format prefix mismatch")
    }
    if let expected = request.expectedSHA256, expected != digest {
      throw SessionStorageError.checksumMismatch(expected: expected, actual: digest)
    }

    let record = try ArtifactRecord(
      id: request.artifactID,
      role: request.role,
      origin: request.origin,
      relativePath: "\(relativeDirectory)/\(request.publicationName)",
      size: byteCount,
      sha256: digest,
      mediaType: request.mediaType,
      derivedFrom: request.derivedFrom)
    try validatePublicationFileIdentity(
      descriptor: destination, expected: destinationMetadata,
      parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
      requireReadOnly: request.role == .raw)
    for snapshot in derivedSourceSnapshots { try snapshot.validate() }
    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
      try requireTerminalManifestAbsent(directories: directories)
      for snapshot in derivedSourceSnapshots { try snapshot.validate() }
      try writeRecoveryRecord(
        record, name: recoveryName, url: recoveryURL, directories: directories)
    }

    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
      try faultInjector.check(.artifactReplace)
      try requireTerminalManifestAbsent(directories: directories)
      try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
      try requireClaimVolume(claim, descriptor: directories.partialDescriptor)
      try requireClaimVolume(claim, descriptor: targetDescriptor)
      try directories.validateBindings()
      for snapshot in derivedSourceSnapshots { try snapshot.validate() }
      try validatePublicationFileIdentity(
        descriptor: destination, expected: destinationMetadata,
        parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
        requireReadOnly: request.role == .raw)
      guard
        renameatx_np(
          directories.partialDescriptor, temporaryName, targetDescriptor,
          request.publicationName, UInt32(RENAME_EXCL)) == 0
      else {
        if errno == EEXIST { throw SessionStorageError.artifactAlreadyPublished(finalURL.path) }
        throw SessionStorageError.writeFailed(path: finalURL.path, errno: errno)
      }
      try validatePublicationFileIdentity(
        descriptor: destination, expected: destinationMetadata,
        parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
        requireReadOnly: request.role == .raw)
    }
    try SessionStorageValidation.mappingDurableFileErrors {
      try faultInjector.check(.artifactDirectorySync)
      try directories.syncDirectory(targetDescriptor, path: directory.path)
    }
    try SessionStorageValidation.mappingDurableFileErrors {
      try faultInjector.check(.artifactSourceDirectorySync)
      try directories.syncDirectory(
        directories.partialDescriptor, path: layout.partialDirectory.path)
    }
    try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
    try requireClaimVolume(claim, descriptor: targetDescriptor)
    try directories.validateBindings()
    for snapshot in derivedSourceSnapshots { try snapshot.validate() }
    try validatePublicationFileIdentity(
      descriptor: destination, expected: destinationMetadata,
      parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
      requireReadOnly: request.role == .raw)
    guard Darwin.close(destination) == 0 else {
      destinationIsOpen = false
      throw SessionStorageError.writeFailed(path: finalURL.path, errno: errno)
    }
    destinationIsOpen = false

    return PublishedArtifact(record: record, url: finalURL)
  }

  private func prepareExistingPartial(
    sourceDescriptor: Int32,
    temporaryName: String,
    temporaryURL: URL,
    claim: StorageClaim,
    directories: AnchoredSessionArtifactDirectories,
    requiredPrefixCount: Int
  ) throws -> ReusablePublicationPartial? {
    let descriptor = Darwin.openat(
      directories.partialDescriptor, temporaryName,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
    }
    var descriptorIsOpen = true
    defer { if descriptorIsOpen { Darwin.close(descriptor) } }
    let metadata = try publicationFileMetadata(
      descriptor: descriptor, path: temporaryURL.path)
    try requireClaimVolume(claim, descriptor: descriptor)
    try validatePublicationFileIdentity(
      descriptor: descriptor, expected: metadata,
      parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
      requireReadOnly: false)
    let sourceFingerprint = try fingerprint(
      descriptor: sourceDescriptor, path: "publication source",
      requiredPrefixCount: requiredPrefixCount)
    let partialFingerprint = try fingerprint(
      descriptor: descriptor, path: temporaryURL.path,
      requiredPrefixCount: requiredPrefixCount)
    try validatePublicationFileIdentity(
      descriptor: descriptor, expected: metadata,
      parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
      requireReadOnly: false)
    if sourceFingerprint.size == partialFingerprint.size,
      sourceFingerprint.sha256 == partialFingerprint.sha256
    {
      descriptorIsOpen = false
      return ReusablePublicationPartial(
        descriptor: descriptor, metadata: metadata, size: sourceFingerprint.size,
        sha256: sourceFingerprint.sha256, prefix: sourceFingerprint.prefix)
    }

    try validatePublicationFileIdentity(
      descriptor: descriptor, expected: metadata,
      parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
      requireReadOnly: false)
    guard Darwin.unlinkat(directories.partialDescriptor, temporaryName, 0) == 0 else {
      throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
    }
    // Refund before the directory barrier: the bytes are already released in the live
    // filesystem, and a failed sync must not strand them charged for the claim's lifetime.
    try claim.refundOptionalWrite(bytes: partialFingerprint.size)
    try directories.syncDirectory(
      directories.partialDescriptor, path: layout.partialDirectory.path)
    return nil
  }

  private func publicationFileMetadata(descriptor: Int32, path: String) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SessionStorageError.invalidArtifact("publication file is not regular: \(path)")
    }
    return metadata
  }

  private func validatePublicationFileIdentity(
    descriptor: Int32,
    expected: stat,
    parentDescriptor: Int32,
    name: String,
    at url: URL,
    requireReadOnly: Bool
  ) throws {
    let opened = try publicationFileMetadata(descriptor: descriptor, path: url.path)
    var pathMetadata = stat()
    guard fstatat(parentDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
      pathMetadata.st_dev == opened.st_dev, pathMetadata.st_ino == opened.st_ino,
      opened.st_uid == geteuid(), pathMetadata.st_uid == geteuid(),
      opened.st_nlink == 1, pathMetadata.st_nlink == 1,
      pathMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      !requireReadOnly || pathMetadata.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0
    else {
      throw SessionStorageError.invalidArtifact(
        "publication partial path no longer owns the opened inode")
    }
  }

  private func recoverPublication(
    sourceDescriptor: Int32,
    request: ArtifactPublicationRequest,
    claim: StorageClaim,
    finalURL: URL,
    temporaryURL: URL,
    recoveryURL: URL,
    directories: AnchoredSessionArtifactDirectories,
    targetDescriptor: Int32,
    derivedSourceSnapshots: [AnchoredManifestArtifactSnapshot]
  ) throws -> PublishedArtifact {
    let temporaryName = temporaryURL.lastPathComponent
    let recoveryName = recoveryURL.lastPathComponent
    let recoveryData = try readBoundedRegularFile(
      name: recoveryName, url: recoveryURL,
      maximumBytes: ArtifactPublicationRecoveryRecord.maximumCanonicalBytes,
      directories: directories)
    var duplicateValidator = StrictJSONDuplicateValidator(data: recoveryData)
    try duplicateValidator.validate()
    let recovery = try JSONDecoder().decode(
      ArtifactPublicationRecoveryRecord.self, from: recoveryData)
    guard recovery.schemaVersion == "1.0.0" else {
      throw SessionStorageError.invalidArtifact("unsupported publication recovery record")
    }
    let expectedDirectory = request.role == .derived ? "artifacts/derived" : "artifacts/raw"
    let record = recovery.record
    guard record.id == request.artifactID, record.role == request.role,
      record.origin == request.origin,
      record.relativePath == "\(expectedDirectory)/\(request.publicationName)",
      record.mediaType == request.mediaType, record.derivedFrom == request.derivedFrom,
      request.expectedSHA256.map({ $0 == record.sha256 }) ?? true
    else {
      throw SessionStorageError.invalidArtifact(
        "publication retry does not match its durable recovery record")
    }
    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try requireTerminalManifestAbsent(directories: directories)
    try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
    try requireClaimVolume(claim, descriptor: directories.partialDescriptor)
    try requireClaimVolume(claim, descriptor: targetDescriptor)
    try directories.validateBindings()
    for snapshot in derivedSourceSnapshots { try snapshot.validate() }

    let requiredPrefixCount = request.requiredPrefix?.count ?? 0
    var existingFinalRejectsSource = false
    if let finalFile = try openPublicationFileIfPresent(
      parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
      claim: claim, requireReadOnly: request.role == .raw)
    {
      defer { Darwin.close(finalFile.descriptor) }
      let finalFingerprint = try fingerprint(
        descriptor: finalFile.descriptor, path: finalURL.path,
        requiredPrefixCount: requiredPrefixCount)
      try validatePublicationFileIdentity(
        descriptor: finalFile.descriptor, expected: finalFile.metadata,
        parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
        requireReadOnly: request.role == .raw)
      guard finalFingerprint.size == record.size, finalFingerprint.sha256 == record.sha256 else {
        throw SessionStorageError.artifactAlreadyPublished(finalURL.path)
      }
      let sourceFingerprint = try fingerprint(
        descriptor: sourceDescriptor, path: "publication source",
        requiredPrefixCount: requiredPrefixCount)
      if sourceFingerprint.size != record.size || sourceFingerprint.sha256 != record.sha256 {
        existingFinalRejectsSource = true
      } else if let requiredPrefix = request.requiredPrefix,
        sourceFingerprint.prefix != requiredPrefix
      {
        throw SessionStorageError.invalidArtifact("basic format prefix mismatch")
      }
      try faultInjector.check(.artifactDirectorySync)
      try directories.syncDirectory(
        targetDescriptor, path: finalURL.deletingLastPathComponent().path)
      try faultInjector.check(.artifactSourceDirectorySync)
      try directories.syncDirectory(
        directories.partialDescriptor, path: layout.partialDirectory.path)
      try directories.validateBindings()
      for snapshot in derivedSourceSnapshots { try snapshot.validate() }
      try validatePublicationFileIdentity(
        descriptor: finalFile.descriptor, expected: finalFile.metadata,
        parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
        requireReadOnly: request.role == .raw)
    } else {
      guard
        let partialFile = try openPublicationFileIfPresent(
          parentDescriptor: directories.partialDescriptor, name: temporaryName,
          at: temporaryURL, claim: claim, requireReadOnly: request.role == .raw)
      else {
        throw SessionStorageError.invalidArtifact(
          "publication recovery record has no final or partial Artifact")
      }
      defer { Darwin.close(partialFile.descriptor) }
      let sourceFingerprint = try fingerprint(
        descriptor: sourceDescriptor, path: "publication source",
        requiredPrefixCount: requiredPrefixCount)
      guard sourceFingerprint.size == record.size, sourceFingerprint.sha256 == record.sha256 else {
        throw SessionStorageError.checksumMismatch(
          expected: record.sha256, actual: sourceFingerprint.sha256)
      }
      if let requiredPrefix = request.requiredPrefix,
        sourceFingerprint.prefix != requiredPrefix
      {
        throw SessionStorageError.invalidArtifact("basic format prefix mismatch")
      }
      let partialFingerprint = try fingerprint(
        descriptor: partialFile.descriptor, path: temporaryURL.path,
        requiredPrefixCount: requiredPrefixCount)
      try validatePublicationFileIdentity(
        descriptor: partialFile.descriptor, expected: partialFile.metadata,
        parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
        requireReadOnly: request.role == .raw)
      guard partialFingerprint.size == record.size, partialFingerprint.sha256 == record.sha256
      else {
        throw SessionStorageError.checksumMismatch(
          expected: record.sha256, actual: partialFingerprint.sha256)
      }
      try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
      try claim.performOptionalWrite(bytes: 0, forJobID: layout.jobID) {
        try faultInjector.check(.artifactReplace)
        try requireTerminalManifestAbsent(directories: directories)
        try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
        try requireClaimVolume(claim, descriptor: directories.partialDescriptor)
        try requireClaimVolume(claim, descriptor: targetDescriptor)
        try directories.validateBindings()
        for snapshot in derivedSourceSnapshots { try snapshot.validate() }
        try validatePublicationFileIdentity(
          descriptor: partialFile.descriptor, expected: partialFile.metadata,
          parentDescriptor: directories.partialDescriptor, name: temporaryName, at: temporaryURL,
          requireReadOnly: request.role == .raw)
        guard
          renameatx_np(
            directories.partialDescriptor, temporaryName, targetDescriptor,
            request.publicationName, UInt32(RENAME_EXCL)) == 0
        else {
          if errno == EEXIST {
            throw SessionStorageError.artifactAlreadyPublished(finalURL.path)
          }
          throw SessionStorageError.writeFailed(path: finalURL.path, errno: errno)
        }
        try validatePublicationFileIdentity(
          descriptor: partialFile.descriptor, expected: partialFile.metadata,
          parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
          requireReadOnly: request.role == .raw)
      }
      try faultInjector.check(.artifactDirectorySync)
      try directories.syncDirectory(
        targetDescriptor, path: finalURL.deletingLastPathComponent().path)
      try faultInjector.check(.artifactSourceDirectorySync)
      try directories.syncDirectory(
        directories.partialDescriptor, path: layout.partialDirectory.path)
      try directories.validateBindings()
      for snapshot in derivedSourceSnapshots { try snapshot.validate() }
      try validatePublicationFileIdentity(
        descriptor: partialFile.descriptor, expected: partialFile.metadata,
        parentDescriptor: targetDescriptor, name: request.publicationName, at: finalURL,
        requireReadOnly: request.role == .raw)
    }
    if existingFinalRejectsSource {
      throw SessionStorageError.artifactAlreadyPublished(finalURL.path)
    }
    try claim.requireSessionBinding(sessionID: layout.sessionID, root: layout.root)
    try requireTerminalManifestAbsent(directories: directories)
    try requireClaimVolume(claim, descriptor: directories.rootDescriptor)
    try requireClaimVolume(claim, descriptor: targetDescriptor)
    try directories.validateBindings()
    for snapshot in derivedSourceSnapshots { try snapshot.validate() }
    return PublishedArtifact(record: record, url: finalURL)
  }

  private func openPublicationFileIfPresent(
    parentDescriptor: Int32,
    name: String,
    at url: URL,
    claim: StorageClaim,
    requireReadOnly: Bool
  ) throws -> (descriptor: Int32, metadata: stat)? {
    let descriptor = Darwin.openat(
      parentDescriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    var descriptorIsOpen = true
    defer { if descriptorIsOpen { Darwin.close(descriptor) } }
    let metadata = try publicationFileMetadata(descriptor: descriptor, path: url.path)
    try requireClaimVolume(claim, descriptor: descriptor)
    try validatePublicationFileIdentity(
      descriptor: descriptor, expected: metadata, parentDescriptor: parentDescriptor,
      name: name, at: url, requireReadOnly: requireReadOnly)
    descriptorIsOpen = false
    return (descriptor, metadata)
  }

  private func writeRecoveryRecord(
    _ record: ArtifactRecord,
    name: String,
    url: URL,
    directories: AnchoredSessionArtifactDirectories
  ) throws {
    let data = try SessionStorageValidation.canonicalData(
      ArtifactPublicationRecoveryRecord(record: record))
    guard data.count <= ArtifactPublicationRecoveryRecord.maximumCanonicalBytes else {
      throw SessionStorageError.invalidArtifact(
        "Artifact recovery marker exceeds \(ArtifactPublicationRecoveryRecord.maximumCanonicalBytes) bytes"
      )
    }
    let temporaryName = ".publication-marker.\(UUID().uuidString).tmp"
    let temporaryURL = layout.partialDirectory.appending(path: temporaryName)
    let descriptor = Darwin.openat(
      directories.partialDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
    }
    var isOpen = true
    defer {
      if isOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(directories.partialDescriptor, temporaryName, 0)
    }
    try faultInjector.check(.artifactRecoveryRecordWrite)
    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporaryURL.path)
    try faultInjector.check(.artifactRecoveryRecordSync)
    try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
    guard Darwin.close(descriptor) == 0 else {
      isOpen = false
      throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
    }
    isOpen = false
    try faultInjector.check(.artifactRecoveryRecordReplace)
    guard
      renameatx_np(
        directories.partialDescriptor, temporaryName, directories.partialDescriptor, name,
        UInt32(RENAME_EXCL)) == 0
    else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    try faultInjector.check(.artifactRecoveryRecordDirectorySync)
    try directories.syncDirectory(
      directories.partialDescriptor, path: layout.partialDirectory.path)
  }

  private func readBoundedRegularFile(
    name: String,
    url: URL,
    maximumBytes: Int,
    directories: AnchoredSessionArtifactDirectories
  ) throws -> Data {
    let descriptor = Darwin.openat(
      directories.partialDescriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0, metadata.st_size <= maximumBytes
    else { throw SessionStorageError.invalidArtifact("invalid publication recovery record") }
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
          path: url.path, errno: count < 0 ? errno : EIO)
      }
      offset += count
    }
    // A previous marker write may have reached the page cache before its sync reported failure.
    // Recovery cannot trust that marker until the same opened inode crosses a durability barrier.
    try DurableFilePrimitives.fullSync(descriptor, path: url.path)
    try directories.syncDirectory(
      directories.partialDescriptor, path: layout.partialDirectory.path)
    var pathMetadata = stat()
    guard
      fstatat(
        directories.partialDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      pathMetadata.st_dev == metadata.st_dev, pathMetadata.st_ino == metadata.st_ino
    else {
      throw SessionStorageError.invalidArtifact(
        "publication recovery record path changed while being read")
    }
    return data
  }

  private func fingerprint(
    descriptor: Int32,
    path: String,
    requiredPrefixCount: Int
  ) throws -> (size: UInt64, sha256: String, prefix: Data) {
    var initialMetadata = stat()
    guard fstat(descriptor, &initialMetadata) == 0,
      initialMetadata.st_mode & S_IFMT == S_IFREG,
      initialMetadata.st_size >= 0
    else { throw SessionStorageError.invalidArtifact("publication input is not regular") }
    var hasher = SHA256()
    var prefix = Data()
    var offset: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < initialMetadata.st_size {
      let requested = min(buffer.count, Int(initialMetadata.st_size - offset))
      let count = Darwin.pread(descriptor, &buffer, requested, off_t(offset))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(path: path, errno: count < 0 ? errno : EIO)
      }
      let data = Data(buffer[0..<count])
      hasher.update(data: data)
      if prefix.count < requiredPrefixCount {
        prefix.append(data.prefix(requiredPrefixCount - prefix.count))
      }
      offset += Int64(count)
    }
    try validateStablePublicationSource(
      descriptor: descriptor, initialMetadata: initialMetadata, byteCount: UInt64(offset))
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (UInt64(offset), digest, prefix)
  }

  private func validateStablePublicationSource(
    descriptor: Int32,
    initialMetadata: stat,
    byteCount: UInt64
  ) throws {
    var finalMetadata = stat()
    guard fstat(descriptor, &finalMetadata) == 0,
      finalMetadata.st_size >= 0,
      sameFileIdentityAndContent(initialMetadata, finalMetadata),
      byteCount == UInt64(finalMetadata.st_size)
    else {
      throw SessionStorageError.invalidArtifact(
        "publication source changed while it was being streamed")
    }
  }

  private func requireTerminalManifestAbsent(
    directories: AnchoredSessionArtifactDirectories
  ) throws {
    var metadata = stat()
    if fstatat(
      directories.rootDescriptor, layout.manifestURL.lastPathComponent, &metadata,
      AT_SYMLINK_NOFOLLOW) == 0
    {
      throw SessionStorageError.invalidArtifact(
        "terminal manifest already published for this Session")
    }
    guard errno == ENOENT else {
      throw SessionStorageError.writeFailed(path: layout.manifestURL.path, errno: errno)
    }
  }

  private func requireClaimVolume(_ claim: StorageClaim, descriptor: Int32) throws {
    let actual = try volumeIdentityResolver.resolve(openFileDescriptor: descriptor)
    guard actual == claim.volumeIdentity else {
      throw SessionStorageError.volumeIdentityChanged(
        expected: claim.volumeIdentity, actual: actual)
    }
  }

  public func partialArtifacts() throws -> [PartialArtifact] {
    try SessionStorageValidation.mappingDurableFileErrors {
      let directories = try AnchoredSessionArtifactDirectories(layout: layout)
      let names = try directories.entryNames(
        descriptor: directories.partialDescriptor, path: layout.partialDirectory.path
      ).filter { $0.hasSuffix(".part") }
      return try names.map { name in
        let url = layout.partialDirectory.appending(path: name)
        let descriptor = Darwin.openat(
          directories.partialDescriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
          throw SessionStorageError.writeFailed(path: url.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var path = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
          opened.st_uid == geteuid(), opened.st_nlink == 1,
          opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
          opened.st_dev == directories.rootDevice, opened.st_size >= 0,
          fstatat(directories.partialDescriptor, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
          path.st_mode & S_IFMT == S_IFREG, path.st_dev == opened.st_dev,
          path.st_ino == opened.st_ino
        else {
          throw SessionStorageError.invalidArtifact("partial is not an owner-safe regular file")
        }
        return PartialArtifact(url: url, size: UInt64(opened.st_size))
      }
    }
  }
}

public struct InputImageReference: Codable, Equatable, Sendable {
  public let path: String
  public let size: UInt64
  public let sha256: String
  public let volumeIdentity: VolumeIdentity
  public let fileSystemDevice: UInt64
  public let fileSystemInode: UInt64
  public let fileGeneration: UInt64
}

public struct InputImageReferencer: Sendable {
  private let resolver: any VolumeIdentityResolving
  private let faultInjector: SessionStorageFaultInjector

  public init(
    resolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver(),
    faultInjector: SessionStorageFaultInjector = .none
  ) {
    self.resolver = resolver
    self.faultInjector = faultInjector
  }

  public func reference(_ url: URL) throws -> InputImageReference {
    try SessionStorageValidation.mappingDurableFileErrors {
      try referenceUnmapped(url)
    }
  }

  private func referenceUnmapped(_ url: URL) throws -> InputImageReference {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    try DurableFilePrimitives.rejectSymbolicLink(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var initialMetadata = stat()
    guard fstat(descriptor, &initialMetadata) == 0,
      initialMetadata.st_mode & S_IFMT == S_IFREG
    else {
      throw SessionStorageError.invalidArtifact("input reference must be a regular file")
    }
    var hasher = SHA256()
    var byteCount: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw SessionStorageError.writeFailed(path: url.path, errno: errno)
      }
      hasher.update(data: Data(buffer[0..<count]))
      byteCount += UInt64(count)
    }
    var finalMetadata = stat()
    guard fstat(descriptor, &finalMetadata) == 0,
      sameFileIdentityAndContent(initialMetadata, finalMetadata),
      byteCount == UInt64(finalMetadata.st_size)
    else {
      throw SessionStorageError.invalidArtifact("input changed while it was being referenced")
    }
    let volumeIdentity = try resolver.resolve(openFileDescriptor: descriptor)
    try faultInjector.check(.inputReferencePathValidation)
    var pathMetadata = stat()
    guard lstat(url.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      sameFileIdentityAndContent(finalMetadata, pathMetadata)
    else {
      throw SessionStorageError.invalidArtifact(
        "input path no longer identifies the referenced file")
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return InputImageReference(
      path: url.path,
      size: byteCount,
      sha256: digest,
      volumeIdentity: volumeIdentity,
      fileSystemDevice: UInt64(UInt32(bitPattern: finalMetadata.st_dev)),
      fileSystemInode: UInt64(finalMetadata.st_ino),
      fileGeneration: UInt64(finalMetadata.st_gen))
  }
}

private func sameFileIdentityAndContent(_ lhs: stat, _ rhs: stat) -> Bool {
  lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
    && lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
    && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
    && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

public struct DerivedArtifactProvenance: Codable, Equatable, Sendable {
  public static let maximumCanonicalBytes = 16 * 1_024

  public let operation: String
  public let inputHashes: [String]
  public let parameters: [String: String]
  public let statistics: [String: Int64]

  public init(
    operation: String,
    inputHashes: [String],
    parameters: [String: String],
    statistics: [String: Int64]
  ) throws {
    self.operation = operation
    self.inputHashes = inputHashes.map { $0.lowercased() }
    self.parameters = parameters
    self.statistics = statistics
    try validate()
    guard try SessionStorageValidation.canonicalData(self).count <= Self.maximumCanonicalBytes
    else {
      throw SessionStorageError.invalidArtifact("derived provenance exceeds bound")
    }
  }

  public init(manifestOrigin: String) throws {
    guard manifestOrigin.hasPrefix("derived:"),
      let data = Data(base64Encoded: String(manifestOrigin.dropFirst("derived:".count))),
      !data.isEmpty, data.count <= Self.maximumCanonicalBytes
    else {
      throw SessionStorageError.invalidArtifact("derived Artifact origin is not typed provenance")
    }
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let decoded = try JSONDecoder().decode(Self.self, from: data)
    guard try decoded.manifestOrigin() == manifestOrigin else {
      throw SessionStorageError.invalidArtifact("derived Artifact provenance is not canonical")
    }
    self = decoded
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operation, inputHashes, parameters, statistics
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: DerivedProvenanceAnyCodingKey.self)
    guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw SessionStorageError.invalidArtifact(
        "unknown or missing derived provenance field")
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      operation: container.decode(String.self, forKey: .operation),
      inputHashes: container.decode([String].self, forKey: .inputHashes),
      parameters: container.decode([String: String].self, forKey: .parameters),
      statistics: container.decode([String: Int64].self, forKey: .statistics))
  }

  public func manifestOrigin() throws -> String {
    let data = try SessionStorageValidation.canonicalData(self)
    guard data.count <= Self.maximumCanonicalBytes else {
      throw SessionStorageError.invalidArtifact("derived provenance exceeds bound")
    }
    return "derived:" + data.base64EncodedString()
  }

  private func validate() throws {
    guard !operation.isEmpty, operation.utf8.count <= 256,
      !inputHashes.isEmpty, inputHashes.count <= 256,
      !parameters.isEmpty, parameters.count <= 256,
      !statistics.isEmpty, statistics.count <= 256
    else {
      throw SessionStorageError.invalidArtifact("derived provenance is incomplete")
    }
    for hash in inputHashes {
      try SessionStorageValidation.sha256(hash, field: "derived.inputHashes")
    }
    guard
      parameters.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 128 && value.utf8.count <= 4 * 1_024
      }),
      statistics.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 128 && value >= 0
      })
    else {
      throw SessionStorageError.invalidArtifact("derived provenance field exceeds bound")
    }
  }
}

private struct DerivedProvenanceAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
