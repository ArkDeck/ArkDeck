import Darwin
import Foundation

public enum SessionRetentionCatalogError: Error, Equatable, Sendable {
  case invalidRoot
  case invalidRetentionDays
  case metadataUnavailable
  case metadataCorrupt
  case staleGeneration(expected: UInt64, actual: UInt64)
  case generationOverflow
  case unknownSession(String)
  case unsafeSession(String)
}

public enum SessionRetentionCatalogFaultPoint: String, CaseIterable, Sendable {
  case beforeScan
  case beforeMeasurement
  case beforeMetadataRead
  case beforeMetadataReplace
}

public struct SessionRetentionCatalogFaultInjector: @unchecked Sendable {
  private let body: @Sendable (SessionRetentionCatalogFaultPoint) throws -> Void

  public init(
    _ body: @escaping @Sendable (SessionRetentionCatalogFaultPoint) throws -> Void
  ) {
    self.body = body
  }

  public func check(_ point: SessionRetentionCatalogFaultPoint) throws {
    try body(point)
  }

  public static let none = SessionRetentionCatalogFaultInjector { _ in }
}

public struct SessionCatalogRootIdentity: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64

  fileprivate init(_ metadata: stat) {
    device = UInt64(UInt32(bitPattern: metadata.st_dev))
    inode = UInt64(metadata.st_ino)
  }
}

public struct SessionRetentionCatalogEntry: Equatable, Sendable {
  public let sessionID: String
  public let completedAt: Date
  public let expiresAt: Date
  public let isPinned: Bool
  public let policyGeneration: UInt64
}

public struct SessionRetentionCatalogSnapshot: Equatable, Sendable {
  public let catalogGeneration: UInt64?
  public let sessions: [RetainedSession]
  public let entries: [SessionRetentionCatalogEntry]
  public let currentBytes: UInt64
  public let unknownPressure: Bool
  public let unknownSessionIDs: [String]
  public let rootIdentity: SessionCatalogRootIdentity
  public let volumeIdentity: VolumeIdentity

  public var pinnedBytes: UInt64 {
    sessions.filter(\.isPinned).reduce(UInt64(0)) {
      SessionStorageValidation.saturatingAdd($0, $1.sizeBytes)
    }
  }
}

public struct SessionRetentionCatalog: Sendable {
  public static let metadataFileName = ".arkdeck-retention-catalog.json"
  private static let lockFileName = ".arkdeck-retention-catalog.lock"
  private static let initializedLockMarker: UInt8 = 0xA5
  private static let maximumIdentityBytes = 4 * 1_024
  private static let maximumMetadataBytes = 16 * 1_024 * 1_024

  public let sessionsRoot: URL
  private let volumeIdentityResolver: any VolumeIdentityResolving
  private let faultInjector: SessionRetentionCatalogFaultInjector
  private let configurationEpoch: StorageConfigurationEpoch?

  public init(
    sessionsRoot: URL,
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver(),
    faultInjector: SessionRetentionCatalogFaultInjector = .none,
    configurationEpoch: StorageConfigurationEpoch? = nil
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(sessionsRoot)
    self.sessionsRoot = sessionsRoot.standardizedFileURL
    self.volumeIdentityResolver = volumeIdentityResolver
    self.faultInjector = faultInjector
    self.configurationEpoch = configurationEpoch
  }

  public func scan(
    retentionDays: UInt64,
    policyGeneration: UInt64
  ) throws -> SessionRetentionCatalogSnapshot {
    let retentionDays = try validatedRetentionDays(retentionDays)
    return try withLockedRoot { root in
      try faultInjector.check(.beforeScan)
      return try scanLocked(
        root, retentionDays: retentionDays, policyGeneration: policyGeneration)
    }
  }

  public func requireCurrentRoot(
    identity expectedIdentity: SessionCatalogRootIdentity,
    volumeIdentity expectedVolumeIdentity: VolumeIdentity
  ) throws {
    var pathMetadata = stat()
    guard Darwin.lstat(sessionsRoot.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFDIR,
      pathMetadata.st_uid == geteuid(),
      pathMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { throw SessionRetentionCatalogError.invalidRoot }
    let descriptor = Darwin.open(
      sessionsRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SessionRetentionCatalogError.invalidRoot }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(),
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_dev == pathMetadata.st_dev,
      opened.st_ino == pathMetadata.st_ino,
      SessionCatalogRootIdentity(opened) == expectedIdentity,
      try volumeIdentityResolver.resolve(openFileDescriptor: descriptor)
        == expectedVolumeIdentity
    else { throw SessionRetentionCatalogError.invalidRoot }
  }

  public func registerFinalizedSession(
    sessionRoot: URL,
    retentionDays: UInt64,
    policyGeneration: UInt64
  ) throws {
    let retentionDays = try validatedRetentionDays(retentionDays)
    try withLockedRoot { root in
      if case .missing = try loadMetadata(root) {
        _ = try scanLocked(
          root, retentionDays: retentionDays, policyGeneration: policyGeneration)
      }
      let metadata = try requireMetadata(root)
      let relative = try relativeSessionComponents(sessionRoot)
      guard
        let scanned = try scanSession(
          root: root, year: relative.year, month: relative.month,
          sessionID: relative.sessionID)
      else {
        throw SessionRetentionCatalogError.unsafeSession(relative.sessionID)
      }
      var document = metadata
      if let existing = document.entries.first(where: { $0.sessionID == scanned.sessionID }) {
        guard
          parseTimestamp(existing.completedAt) == scanned.completedAt,
          existing.policyGeneration == policyGeneration
        else {
          throw SessionRetentionCatalogError.unsafeSession(scanned.sessionID)
        }
        return
      }
      let expiresAt = try expiration(
        completedAt: scanned.completedAt, retentionDays: retentionDays)
      document.entries.append(
        PersistentEntry(
          sessionID: scanned.sessionID,
          completedAt: try formatTimestamp(scanned.completedAt),
          expiresAt: try formatTimestamp(expiresAt),
          isPinned: false,
          policyGeneration: policyGeneration))
      document.generation = try nextGeneration(document.generation)
      document.entries.sort { $0.sessionID < $1.sessionID }
      try writeMetadata(document, root: root)
    }
  }

  public func updatePin(
    sessionID: String,
    isPinned: Bool,
    expectedGeneration: UInt64
  ) throws -> UInt64 {
    try SessionStorageValidation.identifier(sessionID, field: "sessionId")
    return try withLockedRoot { root in
      var document = try requireMetadata(root)
      guard document.generation == expectedGeneration else {
        throw SessionRetentionCatalogError.staleGeneration(
          expected: expectedGeneration, actual: document.generation)
      }
      guard let index = document.entries.firstIndex(where: { $0.sessionID == sessionID }) else {
        throw SessionRetentionCatalogError.unknownSession(sessionID)
      }
      if document.entries[index].isPinned == isPinned { return document.generation }
      document.entries[index].isPinned = isPinned
      document.generation = try nextGeneration(document.generation)
      try writeMetadata(document, root: root)
      return document.generation
    }
  }

  private func scanLocked(
    _ root: LockedRoot,
    retentionDays: Int,
    policyGeneration: UInt64
  ) throws -> SessionRetentionCatalogSnapshot {
    let tree = try scanTree(root)
    let metadataState = try loadMetadata(root)
    var unknownIDs = Set(tree.unknownIDs)
    var unknownPressure = tree.unknownPressure
    var sessions: [RetainedSession] = []
    var entrySnapshots: [SessionRetentionCatalogEntry] = []
    let duplicateIDs = Set(
      Dictionary(grouping: tree.observedSessionIDs, by: { $0 })
        .filter { $0.value.count > 1 }.keys)
    unknownIDs.formUnion(duplicateIDs)
    if !duplicateIDs.isEmpty { unknownPressure = true }

    switch metadataState {
    case .corrupt:
      unknownPressure = true
      unknownIDs.formUnion(tree.sessions.map(\.sessionID))
      return snapshot(
        root: root, generation: nil, sessions: [], entries: [],
        currentBytes: tree.currentBytes, unknownPressure: unknownPressure,
        unknownIDs: unknownIDs)

    case .missing:
      var document = PersistentCatalog(generation: 0, entries: [])
      for scanned in tree.sessions where !duplicateIDs.contains(scanned.sessionID) {
        let expiresAt = try expiration(
          completedAt: scanned.completedAt, retentionDays: retentionDays)
        document.entries.append(
          PersistentEntry(
            sessionID: scanned.sessionID,
            completedAt: try formatTimestamp(scanned.completedAt),
            expiresAt: try formatTimestamp(expiresAt),
            isPinned: false,
            policyGeneration: policyGeneration))
        sessions.append(
          try RetainedSession(
            sessionID: scanned.sessionID, root: scanned.root,
            sizeBytes: scanned.sizeBytes, completedAt: scanned.completedAt,
            expiresAt: expiresAt, isPinned: false))
      }
      document.entries.sort { $0.sessionID < $1.sessionID }
      try writeMetadata(document, root: root)
      entrySnapshots = try publicEntries(from: document)
      return snapshot(
        root: root, generation: document.generation, sessions: sessions,
        entries: entrySnapshots, currentBytes: tree.currentBytes,
        unknownPressure: unknownPressure, unknownIDs: unknownIDs)

    case .valid(var document):
      var changed = false
      var retainedEntryIDs = Set<String>()
      let byID = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.sessionID, $0) })
      for scanned in tree.sessions {
        guard !duplicateIDs.contains(scanned.sessionID),
          var entry = byID[scanned.sessionID],
          parseTimestamp(entry.completedAt) == scanned.completedAt
        else {
          unknownPressure = true
          unknownIDs.insert(scanned.sessionID)
          continue
        }
        let expiresAt = try expiration(
          completedAt: scanned.completedAt, retentionDays: retentionDays)
        if parseTimestamp(entry.expiresAt) != expiresAt
          || entry.policyGeneration != policyGeneration
        {
          entry.expiresAt = try formatTimestamp(expiresAt)
          entry.policyGeneration = policyGeneration
          guard
            let index = document.entries.firstIndex(where: {
              $0.sessionID == scanned.sessionID
            })
          else { throw SessionRetentionCatalogError.metadataCorrupt }
          document.entries[index] = entry
          changed = true
        }
        retainedEntryIDs.insert(scanned.sessionID)
        sessions.append(
          try RetainedSession(
            sessionID: scanned.sessionID, root: scanned.root,
            sizeBytes: scanned.sizeBytes, completedAt: scanned.completedAt,
            expiresAt: expiresAt, isPinned: entry.isPinned))
      }

      let observedSessionIDs = Set(tree.observedSessionIDs)
      let filteredEntries =
        tree.hasUnscopedUnknown
        ? document.entries
        : document.entries.filter {
          retainedEntryIDs.contains($0.sessionID)
            || observedSessionIDs.contains($0.sessionID)
        }
      if filteredEntries.count != document.entries.count {
        document.entries = filteredEntries
        changed = true
      }
      if changed {
        document.generation = try nextGeneration(document.generation)
        document.entries.sort { $0.sessionID < $1.sessionID }
        try writeMetadata(document, root: root)
      }
      entrySnapshots = try publicEntries(from: document)
      return snapshot(
        root: root, generation: document.generation,
        sessions: sessions.sorted {
          $0.sessionID < $1.sessionID
        }, entries: entrySnapshots, currentBytes: tree.currentBytes,
        unknownPressure: unknownPressure, unknownIDs: unknownIDs)
    }
  }

  private func snapshot(
    root: LockedRoot,
    generation: UInt64?,
    sessions: [RetainedSession],
    entries: [SessionRetentionCatalogEntry],
    currentBytes: UInt64,
    unknownPressure: Bool,
    unknownIDs: Set<String>
  ) -> SessionRetentionCatalogSnapshot {
    SessionRetentionCatalogSnapshot(
      catalogGeneration: generation,
      sessions: sessions,
      entries: entries.sorted { $0.sessionID < $1.sessionID },
      currentBytes: currentBytes,
      unknownPressure: unknownPressure,
      unknownSessionIDs: unknownIDs.sorted(),
      rootIdentity: root.identity,
      volumeIdentity: root.volumeIdentity)
  }

  private func scanTree(_ root: LockedRoot) throws -> ScannedTree {
    var sessions: [ScannedSession] = []
    var unknownIDs: [String] = []
    var observedSessionIDs: [String] = []
    var currentBytes: UInt64 = 0
    var unknownPressure = false
    var hasUnscopedUnknown = false

    for year in try directoryEntryNames(root.descriptor) {
      if year == Self.metadataFileName || year == Self.lockFileName { continue }
      guard isYear(year),
        let yearDescriptor = openOwnedDirectory(
          parent: root.descriptor, name: year, expectedDevice: root.device)
      else {
        hasUnscopedUnknown = true
        recordUnknown(
          name: year, parent: root.descriptor, expectedDevice: root.device,
          currentBytes: &currentBytes, unknownPressure: &unknownPressure,
          unknownIDs: &unknownIDs)
        continue
      }
      defer { Darwin.close(yearDescriptor) }
      for month in try directoryEntryNames(yearDescriptor) {
        let relativeMonth = "\(year)/\(month)"
        guard isMonth(month),
          let monthDescriptor = openOwnedDirectory(
            parent: yearDescriptor, name: month, expectedDevice: root.device)
        else {
          hasUnscopedUnknown = true
          recordUnknown(
            name: month, displayName: relativeMonth, parent: yearDescriptor,
            expectedDevice: root.device, currentBytes: &currentBytes,
            unknownPressure: &unknownPressure, unknownIDs: &unknownIDs)
          continue
        }
        defer { Darwin.close(monthDescriptor) }
        for sessionID in try directoryEntryNames(monthDescriptor) {
          observedSessionIDs.append(sessionID)
          let relativeSession = "\(year)/\(month)/\(sessionID)"
          do {
            try SessionStorageValidation.identifier(sessionID, field: "sessionId")
            guard
              let scanned = try scanSession(
                parent: monthDescriptor, year: year, month: month,
                sessionID: sessionID, expectedDevice: root.device)
            else {
              recordUnknown(
                name: sessionID, displayName: relativeSession, parent: monthDescriptor,
                expectedDevice: root.device, currentBytes: &currentBytes,
                unknownPressure: &unknownPressure, unknownIDs: &unknownIDs)
              continue
            }
            sessions.append(scanned)
            add(scanned.sizeBytes, to: &currentBytes, unknownPressure: &unknownPressure)
          } catch {
            recordUnknown(
              name: sessionID, displayName: relativeSession, parent: monthDescriptor,
              expectedDevice: root.device, currentBytes: &currentBytes,
              unknownPressure: &unknownPressure, unknownIDs: &unknownIDs)
          }
        }
      }
    }
    return ScannedTree(
      sessions: sessions, unknownIDs: unknownIDs,
      observedSessionIDs: observedSessionIDs,
      currentBytes: currentBytes, unknownPressure: unknownPressure,
      hasUnscopedUnknown: hasUnscopedUnknown)
  }

  private func scanSession(
    root: LockedRoot,
    year: String,
    month: String,
    sessionID: String
  ) throws -> ScannedSession? {
    guard
      let yearDescriptor = openOwnedDirectory(
        parent: root.descriptor, name: year, expectedDevice: root.device)
    else { return nil }
    defer { Darwin.close(yearDescriptor) }
    guard
      let monthDescriptor = openOwnedDirectory(
        parent: yearDescriptor, name: month, expectedDevice: root.device)
    else { return nil }
    defer { Darwin.close(monthDescriptor) }
    return try scanSession(
      parent: monthDescriptor, year: year, month: month,
      sessionID: sessionID, expectedDevice: root.device)
  }

  private func scanSession(
    parent: Int32,
    year: String,
    month: String,
    sessionID: String,
    expectedDevice: dev_t
  ) throws -> ScannedSession? {
    guard
      let descriptor = openOwnedDirectory(
        parent: parent, name: sessionID, expectedDevice: expectedDevice)
    else { return nil }
    defer { Darwin.close(descriptor) }
    let identityData = try readRegularFile(
      parent: descriptor, name: ".session-identity.json",
      maximumBytes: Self.maximumIdentityBytes, expectedDevice: expectedDevice)
    let identity = try decodeIdentity(identityData)
    guard identity.sessionID == sessionID else { return nil }
    let manifestData = try readRegularFile(
      parent: descriptor, name: SessionLayout.manifestFileName,
      maximumBytes: SessionManifestDocument.maximumCanonicalBytes,
      expectedDevice: expectedDevice)
    let manifest = try SessionManifestDocument(data: manifestData)
    guard manifestData == manifest.canonicalData,
      manifest.sessionID == sessionID, manifest.jobID == identity.jobID
    else { return nil }
    try faultInjector.check(.beforeMeasurement)
    let size = try measureDirectory(descriptor, expectedDevice: expectedDevice)
    let root =
      sessionsRoot
      .appending(path: year, directoryHint: .isDirectory)
      .appending(path: month, directoryHint: .isDirectory)
      .appending(path: sessionID, directoryHint: .isDirectory)
    return ScannedSession(
      sessionID: sessionID, root: root, sizeBytes: size,
      completedAt: manifest.completedAt)
  }

  private func recordUnknown(
    name: String,
    displayName: String? = nil,
    parent: Int32,
    expectedDevice: dev_t,
    currentBytes: inout UInt64,
    unknownPressure: inout Bool,
    unknownIDs: inout [String]
  ) {
    unknownPressure = true
    unknownIDs.append(displayName ?? name)
    if let measured = try? measureEntry(
      parent: parent, name: name, expectedDevice: expectedDevice)
    {
      add(measured, to: &currentBytes, unknownPressure: &unknownPressure)
    }
  }

  private func measureEntry(
    parent: Int32,
    name: String,
    expectedDevice: dev_t
  ) throws -> UInt64 {
    var metadata = stat()
    guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
      metadata.st_uid == geteuid(), metadata.st_dev == expectedDevice,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { throw SessionRetentionCatalogError.invalidRoot }
    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
        throw SessionRetentionCatalogError.invalidRoot
      }
      return UInt64(metadata.st_size)
    case S_IFDIR:
      guard
        let descriptor = openOwnedDirectory(
          parent: parent, name: name, expectedDevice: expectedDevice)
      else { throw SessionRetentionCatalogError.invalidRoot }
      defer { Darwin.close(descriptor) }
      return try measureDirectory(descriptor, expectedDevice: expectedDevice)
    default:
      throw SessionRetentionCatalogError.invalidRoot
    }
  }

  private func measureDirectory(_ descriptor: Int32, expectedDevice: dev_t) throws -> UInt64 {
    var total: UInt64 = 0
    for name in try directoryEntryNames(descriptor) {
      var metadata = stat()
      guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
        metadata.st_uid == geteuid(), metadata.st_dev == expectedDevice,
        metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
      else { throw SessionRetentionCatalogError.invalidRoot }
      let bytes: UInt64
      switch metadata.st_mode & S_IFMT {
      case S_IFREG:
        guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
          throw SessionRetentionCatalogError.invalidRoot
        }
        bytes = UInt64(metadata.st_size)
      case S_IFDIR:
        guard
          let child = openOwnedDirectory(
            parent: descriptor, name: name, expectedDevice: expectedDevice)
        else { throw SessionRetentionCatalogError.invalidRoot }
        defer { Darwin.close(child) }
        bytes = try measureDirectory(child, expectedDevice: expectedDevice)
      default:
        throw SessionRetentionCatalogError.invalidRoot
      }
      total = try Self.checkedMeasurementTotal(total, adding: bytes)
    }
    return total
  }

  private func loadMetadata(_ root: LockedRoot) throws -> MetadataState {
    try faultInjector.check(.beforeMetadataRead)
    var metadata = stat()
    if fstatat(root.descriptor, Self.metadataFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
      return errno == ENOENT && root.metadataMissingIsFresh ? .missing : .corrupt
    }
    do {
      let data = try readRegularFile(
        parent: root.descriptor, name: Self.metadataFileName,
        maximumBytes: Self.maximumMetadataBytes, expectedDevice: root.device)
      let document = try JSONDecoder().decode(PersistentCatalog.self, from: data)
      guard document.schemaVersion == "1.0.0",
        try canonicalData(document) == data,
        Set(document.entries.map(\.sessionID)).count == document.entries.count
      else { return .corrupt }
      for entry in document.entries {
        try SessionStorageValidation.identifier(entry.sessionID, field: "sessionId")
        guard parseTimestamp(entry.completedAt) != nil,
          parseTimestamp(entry.expiresAt) != nil
        else { return .corrupt }
      }
      if root.metadataMissingIsFresh {
        try markCatalogInitialized(root)
      }
      return .valid(document)
    } catch {
      return .corrupt
    }
  }

  private func requireMetadata(_ root: LockedRoot) throws -> PersistentCatalog {
    switch try loadMetadata(root) {
    case .valid(let document):
      return document
    case .missing:
      throw SessionRetentionCatalogError.metadataUnavailable
    case .corrupt:
      throw SessionRetentionCatalogError.metadataCorrupt
    }
  }

  private func writeMetadata(_ document: PersistentCatalog, root: LockedRoot) throws {
    if let configurationEpoch {
      try configurationEpoch.performMutation {
        try writeMetadataUnderConfigurationFence(document, root: root)
      }
    } else {
      try writeMetadataUnderConfigurationFence(document, root: root)
    }
  }

  private func writeMetadataUnderConfigurationFence(
    _ document: PersistentCatalog,
    root: LockedRoot
  ) throws {
    let data = try canonicalData(document)
    guard !data.isEmpty, data.count <= Self.maximumMetadataBytes else {
      throw SessionRetentionCatalogError.metadataCorrupt
    }
    var existing = stat()
    if fstatat(root.descriptor, Self.metadataFileName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
      guard existing.st_mode & S_IFMT == S_IFREG,
        existing.st_uid == geteuid(), existing.st_nlink == 1,
        existing.st_mode & (S_IWGRP | S_IWOTH) == 0,
        existing.st_dev == root.device
      else { throw SessionRetentionCatalogError.metadataCorrupt }
    } else if errno != ENOENT {
      throw SessionRetentionCatalogError.metadataCorrupt
    }

    let temporaryName = ".arkdeck-retention-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      root.descriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: Self.metadataFileName, errno: errno)
    }
    var isOpen = true
    defer {
      if isOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(root.descriptor, temporaryName, 0)
    }
    try DurableFilePrimitives.writeAll(
      data, descriptor: descriptor, path: Self.metadataFileName)
    try DurableFilePrimitives.fullSync(descriptor, path: Self.metadataFileName)
    guard Darwin.close(descriptor) == 0 else {
      isOpen = false
      throw SessionStorageError.writeFailed(path: Self.metadataFileName, errno: errno)
    }
    isOpen = false
    try faultInjector.check(.beforeMetadataReplace)
    guard
      renameatx_np(
        root.descriptor, temporaryName, root.descriptor, Self.metadataFileName, 0) == 0
    else {
      throw SessionStorageError.writeFailed(path: Self.metadataFileName, errno: errno)
    }
    guard Darwin.fsync(root.descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: Self.metadataFileName, errno: errno)
    }
    try markCatalogInitialized(root)
  }

  private func markCatalogInitialized(_ root: LockedRoot) throws {
    var metadata = stat()
    guard fstat(root.lockDescriptor, &metadata) == 0 else {
      throw SessionRetentionCatalogError.invalidRoot
    }
    if metadata.st_size == 1 {
      var marker: UInt8 = 0
      let readCount = withUnsafeMutableBytes(of: &marker) {
        Darwin.pread(root.lockDescriptor, $0.baseAddress, 1, 0)
      }
      guard readCount == 1,
        marker == Self.initializedLockMarker
      else { throw SessionRetentionCatalogError.invalidRoot }
      return
    }
    guard metadata.st_size == 0 else {
      throw SessionRetentionCatalogError.invalidRoot
    }
    var marker = Self.initializedLockMarker
    let written = withUnsafeBytes(of: &marker) {
      Darwin.pwrite(root.lockDescriptor, $0.baseAddress, 1, 0)
    }
    guard written == 1 else {
      throw SessionStorageError.writeFailed(path: Self.lockFileName, errno: errno)
    }
    try DurableFilePrimitives.fullSync(
      root.lockDescriptor, path: Self.lockFileName)
    guard Darwin.fsync(root.descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: Self.lockFileName, errno: errno)
    }
  }

  private func withLockedRoot<T>(_ body: (LockedRoot) throws -> T) throws -> T {
    var pathMetadata = stat()
    guard Darwin.lstat(sessionsRoot.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFDIR,
      pathMetadata.st_uid == geteuid(),
      pathMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { throw SessionRetentionCatalogError.invalidRoot }
    let rootDescriptor = Darwin.open(
      sessionsRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw SessionRetentionCatalogError.invalidRoot }
    defer { Darwin.close(rootDescriptor) }
    var rootMetadata = stat()
    guard fstat(rootDescriptor, &rootMetadata) == 0,
      rootMetadata.st_mode & S_IFMT == S_IFDIR,
      rootMetadata.st_uid == geteuid(),
      rootMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      rootMetadata.st_dev == pathMetadata.st_dev,
      rootMetadata.st_ino == pathMetadata.st_ino
    else { throw SessionRetentionCatalogError.invalidRoot }

    var priorLockMetadata = stat()
    if fstatat(
      rootDescriptor, Self.lockFileName, &priorLockMetadata,
      AT_SYMLINK_NOFOLLOW) != 0, errno != ENOENT
    {
      throw SessionRetentionCatalogError.invalidRoot
    }
    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else { throw SessionRetentionCatalogError.invalidRoot }
    defer { Darwin.close(lockDescriptor) }
    var lockMetadata = stat()
    guard fstat(lockDescriptor, &lockMetadata) == 0,
      lockMetadata.st_mode & S_IFMT == S_IFREG,
      lockMetadata.st_uid == geteuid(), lockMetadata.st_nlink == 1,
      lockMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      lockMetadata.st_dev == rootMetadata.st_dev
    else { throw SessionRetentionCatalogError.invalidRoot }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw SessionRetentionCatalogError.invalidRoot
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }
    guard fstat(lockDescriptor, &lockMetadata) == 0,
      lockMetadata.st_size == 0 || lockMetadata.st_size == 1
    else { throw SessionRetentionCatalogError.invalidRoot }
    if lockMetadata.st_size == 1 {
      var marker: UInt8 = 0
      let readCount = withUnsafeMutableBytes(of: &marker) {
        Darwin.pread(lockDescriptor, $0.baseAddress, 1, 0)
      }
      guard readCount == 1,
        marker == Self.initializedLockMarker
      else { throw SessionRetentionCatalogError.invalidRoot }
    }
    return try body(
      LockedRoot(
        descriptor: rootDescriptor, lockDescriptor: lockDescriptor,
        device: rootMetadata.st_dev,
        identity: SessionCatalogRootIdentity(rootMetadata),
        volumeIdentity: try volumeIdentityResolver.resolve(
          openFileDescriptor: rootDescriptor),
        metadataMissingIsFresh: lockMetadata.st_size == 0))
  }

  private func openOwnedDirectory(
    parent: Int32,
    name: String,
    expectedDevice: dev_t
  ) -> Int32? {
    var link = stat()
    guard fstatat(parent, name, &link, AT_SYMLINK_NOFOLLOW) == 0,
      link.st_mode & S_IFMT == S_IFDIR,
      link.st_uid == geteuid(), link.st_dev == expectedDevice,
      link.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { return nil }
    let descriptor = Darwin.openat(
      parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), opened.st_dev == expectedDevice,
      opened.st_dev == link.st_dev, opened.st_ino == link.st_ino,
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  private func readRegularFile(
    parent: Int32,
    name: String,
    maximumBytes: Int,
    expectedDevice: dev_t
  ) throws -> Data {
    var link = stat()
    guard fstatat(parent, name, &link, AT_SYMLINK_NOFOLLOW) == 0,
      link.st_mode & S_IFMT == S_IFREG,
      link.st_uid == geteuid(), link.st_nlink == 1,
      link.st_mode & (S_IWGRP | S_IWOTH) == 0,
      link.st_dev == expectedDevice, link.st_size > 0,
      link.st_size <= maximumBytes
    else { throw SessionRetentionCatalogError.invalidRoot }
    let descriptor = Darwin.openat(
      parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SessionRetentionCatalogError.invalidRoot }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == geteuid(), opened.st_nlink == 1,
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_dev == link.st_dev, opened.st_ino == link.st_ino,
      opened.st_size == link.st_size
    else { throw SessionRetentionCatalogError.invalidRoot }
    var data = Data(count: Int(opened.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset, off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw SessionRetentionCatalogError.invalidRoot }
      offset += count
    }
    var final = stat()
    var finalLink = stat()
    guard fstat(descriptor, &final) == 0,
      fstatat(parent, name, &finalLink, AT_SYMLINK_NOFOLLOW) == 0,
      final.st_dev == opened.st_dev, final.st_ino == opened.st_ino,
      final.st_size == opened.st_size,
      finalLink.st_dev == opened.st_dev, finalLink.st_ino == opened.st_ino
    else { throw SessionRetentionCatalogError.invalidRoot }
    return data
  }

  private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
    let duplicated = Darwin.dup(descriptor)
    guard duplicated >= 0 else { throw SessionRetentionCatalogError.invalidRoot }
    guard let directory = fdopendir(duplicated) else {
      Darwin.close(duplicated)
      throw SessionRetentionCatalogError.invalidRoot
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw SessionRetentionCatalogError.invalidRoot }
        break
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(
          decoding: bytes.prefix(Int(entry.pointee.d_namlen)).map { UInt8($0) },
          as: UTF8.self)
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names.sorted()
  }

  private func relativeSessionComponents(
    _ sessionRoot: URL
  ) throws -> (year: String, month: String, sessionID: String) {
    try DurableFilePrimitives.requireAbsoluteFileURL(sessionRoot)
    let rootPath = sessionsRoot.standardizedFileURL.path
    let sessionPath = sessionRoot.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard sessionPath.hasPrefix(prefix) else {
      throw SessionRetentionCatalogError.invalidRoot
    }
    let components = sessionPath.dropFirst(prefix.count).split(separator: "/").map(String.init)
    guard components.count == 3, isYear(components[0]), isMonth(components[1]) else {
      throw SessionRetentionCatalogError.invalidRoot
    }
    try SessionStorageValidation.identifier(components[2], field: "sessionId")
    return (components[0], components[1], components[2])
  }

  private func decodeIdentity(_ data: Data) throws -> SessionIdentityRecord {
    let identity = try JSONDecoder().decode(SessionIdentityRecord.self, from: data)
    guard identity.schemaVersion == "1.0.0",
      try canonicalData(identity) == data
    else { throw SessionRetentionCatalogError.invalidRoot }
    try SessionStorageValidation.identifier(identity.sessionID, field: "sessionId")
    try SessionStorageValidation.identifier(identity.jobID, field: "jobId")
    return identity
  }

  private func publicEntries(
    from document: PersistentCatalog
  ) throws -> [SessionRetentionCatalogEntry] {
    try document.entries.map { entry in
      guard let completedAt = parseTimestamp(entry.completedAt),
        let expiresAt = parseTimestamp(entry.expiresAt)
      else { throw SessionRetentionCatalogError.metadataCorrupt }
      return SessionRetentionCatalogEntry(
        sessionID: entry.sessionID, completedAt: completedAt, expiresAt: expiresAt,
        isPinned: entry.isPinned, policyGeneration: entry.policyGeneration)
    }
  }

  private func validatedRetentionDays(_ value: UInt64) throws -> Int {
    guard value > 0, let days = Int(exactly: value) else {
      throw SessionRetentionCatalogError.invalidRetentionDays
    }
    return days
  }

  private func expiration(completedAt: Date, retentionDays: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let value = calendar.date(byAdding: .day, value: retentionDays, to: completedAt) else {
      throw SessionRetentionCatalogError.invalidRetentionDays
    }
    return value
  }

  private func nextGeneration(_ generation: UInt64) throws -> UInt64 {
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw SessionRetentionCatalogError.generationOverflow }
    return next.partialValue
  }

  private func add(
    _ value: UInt64,
    to total: inout UInt64,
    unknownPressure: inout Bool
  ) {
    let sum = total.addingReportingOverflow(value)
    if sum.overflow {
      total = UInt64.max
      unknownPressure = true
    } else {
      total = sum.partialValue
    }
  }

  static func checkedMeasurementTotal(
    _ total: UInt64,
    adding value: UInt64
  ) throws -> UInt64 {
    let sum = total.addingReportingOverflow(value)
    guard !sum.overflow else { throw SessionRetentionCatalogError.invalidRoot }
    return sum.partialValue
  }

  private func isYear(_ value: String) -> Bool {
    value.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
  }

  private func isMonth(_ value: String) -> Bool {
    guard value.count == 2, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let month = Int(value)
    else { return false }
    return (1...12).contains(month)
  }

  private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func formatTimestamp(_ value: Date) throws -> String {
    var wholeSeconds = floor(value.timeIntervalSinceReferenceDate)
    var nanoseconds = Int(
      ((value.timeIntervalSinceReferenceDate - wholeSeconds) * 1_000_000_000).rounded())
    if nanoseconds == 1_000_000_000 {
      wholeSeconds += 1
      nanoseconds = 0
    }
    guard (0..<1_000_000_000).contains(nanoseconds) else {
      throw SessionRetentionCatalogError.metadataCorrupt
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: Date(timeIntervalSinceReferenceDate: wholeSeconds))
    guard let year = components.year, (1...9_999).contains(year),
      let month = components.month, let day = components.day,
      let hour = components.hour, let minute = components.minute,
      let second = components.second
    else { throw SessionRetentionCatalogError.metadataCorrupt }
    return
      "\(padded(year, width: 4))-\(padded(month, width: 2))-\(padded(day, width: 2))"
      + "T\(padded(hour, width: 2)):\(padded(minute, width: 2)):"
      + "\(padded(second, width: 2)).\(padded(nanoseconds, width: 9))Z"
  }

  private func parseTimestamp(_ value: String) -> Date? {
    try? SessionManifestDocument.lockedTimestampDate(
      value, field: "retention catalog timestamp")
  }

  private func padded(_ value: Int, width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
  }
}

private struct LockedRoot {
  let descriptor: Int32
  let lockDescriptor: Int32
  let device: dev_t
  let identity: SessionCatalogRootIdentity
  let volumeIdentity: VolumeIdentity
  let metadataMissingIsFresh: Bool
}

private struct ScannedSession {
  let sessionID: String
  let root: URL
  let sizeBytes: UInt64
  let completedAt: Date
}

private struct ScannedTree {
  let sessions: [ScannedSession]
  let unknownIDs: [String]
  let observedSessionIDs: [String]
  let currentBytes: UInt64
  let unknownPressure: Bool
  let hasUnscopedUnknown: Bool
}

private enum MetadataState {
  case missing
  case valid(PersistentCatalog)
  case corrupt
}

private struct SessionIdentityRecord: Codable {
  let schemaVersion: String
  let sessionID: String
  let jobID: String

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sessionID = "sessionId"
    case jobID = "jobId"
  }
}

private struct PersistentCatalog: Codable {
  let schemaVersion: String
  var generation: UInt64
  var entries: [PersistentEntry]

  init(generation: UInt64, entries: [PersistentEntry]) {
    schemaVersion = "1.0.0"
    self.generation = generation
    self.entries = entries
  }
}

private struct PersistentEntry: Codable {
  let sessionID: String
  let completedAt: String
  var expiresAt: String
  var isPinned: Bool
  var policyGeneration: UInt64

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case completedAt
    case expiresAt
    case isPinned
    case policyGeneration
  }
}
