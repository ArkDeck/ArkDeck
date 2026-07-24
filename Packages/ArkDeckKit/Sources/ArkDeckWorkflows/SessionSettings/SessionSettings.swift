import ArkDeckStorage
import Darwin
import Foundation

public enum SessionRootSource: String, Codable, Equatable, Sendable {
  case defaultApplicationSupport
  case userBookmark
}

public struct SessionSettingsSnapshot: Equatable, Sendable {
  public static let schemaVersion = "1.0.0"
  public static let defaultTotalQuotaBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024
  public static let defaultSafetyMarginBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
  public static let defaultRetentionDays: UInt64 = 90

  public let schemaVersion: String
  public let generation: UInt64
  public let rootSource: SessionRootSource
  public let expectedRootPath: String
  public let totalQuotaBytes: UInt64
  public let safetyMarginBytes: UInt64
  public let retentionDays: UInt64

  public var sessionsRoot: URL {
    URL(filePath: expectedRootPath, directoryHint: .isDirectory).standardizedFileURL
  }

  fileprivate init(
    generation: UInt64,
    rootSource: SessionRootSource,
    expectedRootPath: String,
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) {
    schemaVersion = Self.schemaVersion
    self.generation = generation
    self.rootSource = rootSource
    self.expectedRootPath = expectedRootPath
    self.totalQuotaBytes = totalQuotaBytes
    self.safetyMarginBytes = safetyMarginBytes
    self.retentionDays = retentionDays
  }
}

public enum SessionSettingsError: Error, Equatable, Sendable {
  case configurationMissingFields
  case configurationWrongType
  case unsupportedSchemaVersion
  case invalidRoot
  case invalidQuota
  case invalidRetentionDays
  case generationOverflow
  case staleGeneration(expected: UInt64, actual: UInt64)
  case persistenceFailed
  case requiresReselection
}

public enum SessionSettingsFaultPoint: String, CaseIterable, Sendable {
  case beforePersistence
  case beforeRootWriteProbe
}

public struct SessionSettingsFaultInjector: @unchecked Sendable {
  private let body: @Sendable (SessionSettingsFaultPoint) throws -> Void

  public init(
    _ body: @escaping @Sendable (SessionSettingsFaultPoint) throws -> Void
  ) {
    self.body = body
  }

  public func check(_ point: SessionSettingsFaultPoint) throws {
    try body(point)
  }

  public static let none = SessionSettingsFaultInjector { _ in }
}

public struct SessionBookmarkResolution: Equatable, Sendable {
  public let url: URL
  public let isStale: Bool

  public init(url: URL, isStale: Bool) {
    self.url = url
    self.isStale = isStale
  }
}

public protocol SessionBookmarkAccessing: Sendable {
  func makeReadWriteBookmark(for url: URL) throws -> Data
  func resolveReadWriteBookmark(_ data: Data) throws -> SessionBookmarkResolution
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
}

public struct SystemSessionBookmarkAccess: SessionBookmarkAccessing {
  public init() {}

  public func makeReadWriteBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
  }

  public func resolveReadWriteBookmark(_ data: Data) throws -> SessionBookmarkResolution {
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    return SessionBookmarkResolution(url: url, isStale: stale)
  }

  public func startAccessing(_ url: URL) -> Bool {
    url.startAccessingSecurityScopedResource()
  }

  public func stopAccessing(_ url: URL) {
    url.stopAccessingSecurityScopedResource()
  }
}

public final class SessionRootAccessLease: @unchecked Sendable {
  public let url: URL
  public let rootSource: SessionRootSource
  private let lock = NSLock()
  private var stop: (@Sendable () -> Void)?

  fileprivate init(
    url: URL,
    rootSource: SessionRootSource,
    stop: (@Sendable () -> Void)? = nil
  ) {
    self.url = url.standardizedFileURL
    self.rootSource = rootSource
    self.stop = stop
  }

  deinit { end() }

  public func end() {
    lock.lock()
    let stop = stop
    self.stop = nil
    lock.unlock()
    stop?()
  }
}

public struct SessionRootAccessContext: Sendable {
  public let settings: SessionSettingsSnapshot
  public let lease: SessionRootAccessLease

  public init(settings: SessionSettingsSnapshot, lease: SessionRootAccessLease) {
    self.settings = settings
    self.lease = lease
  }
}

public final class SessionSettingsStore: @unchecked Sendable {
  public static let persistenceKey = "ArkDeck.SessionSettings.v1"
  public let configurationEpoch: StorageConfigurationEpoch

  private let defaults: UserDefaults
  private let defaultRootProvider: @Sendable () throws -> URL
  private let bookmarkAccess: any SessionBookmarkAccessing
  private let faultInjector: SessionSettingsFaultInjector
  private let lock = NSLock()

  public init(
    defaults: UserDefaults = .standard,
    defaultRootProvider: @escaping @Sendable () throws -> URL = {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false)
      return
        support
        .appending(path: "ArkDeck", directoryHint: .isDirectory)
        .appending(path: "Sessions", directoryHint: .isDirectory)
    },
    bookmarkAccess: any SessionBookmarkAccessing = SystemSessionBookmarkAccess(),
    configurationEpoch: StorageConfigurationEpoch = StorageConfigurationEpoch(),
    faultInjector: SessionSettingsFaultInjector = .none
  ) {
    self.defaults = defaults
    self.defaultRootProvider = defaultRootProvider
    self.bookmarkAccess = bookmarkAccess
    self.configurationEpoch = configurationEpoch
    self.faultInjector = faultInjector
  }

  public func load() throws -> SessionSettingsSnapshot {
    try locked { try loadEnvelope().snapshot }
  }

  public func savePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64,
    expectedGeneration: UInt64
  ) throws -> SessionSettingsSnapshot {
    try locked {
      var envelope = try loadEnvelope()
      try requireGeneration(expectedGeneration, envelope: envelope)
      try validatePolicy(
        totalQuotaBytes: totalQuotaBytes,
        safetyMarginBytes: safetyMarginBytes,
        retentionDays: retentionDays)
      envelope.generation = try nextGeneration(envelope.generation)
      envelope.totalQuotaBytes = totalQuotaBytes
      envelope.safetyMarginBytes = safetyMarginBytes
      envelope.retentionDays = retentionDays
      try persist(envelope)
      return envelope.snapshot
    }
  }

  public func selectCustomRoot(
    _ url: URL,
    expectedGeneration: UInt64
  ) throws -> SessionSettingsSnapshot {
    try locked {
      var envelope = try loadEnvelope()
      try requireGeneration(expectedGeneration, envelope: envelope)
      let root = try standardizedAbsoluteFileURL(url)
      guard bookmarkAccess.startAccessing(root) else {
        throw SessionSettingsError.requiresReselection
      }
      defer { bookmarkAccess.stopAccessing(root) }
      do {
        try validateRoot(root, createIfMissing: false)
        let bookmark = try bookmarkAccess.makeReadWriteBookmark(for: root)
        guard !bookmark.isEmpty else { throw SessionSettingsError.requiresReselection }
        envelope.generation = try nextGeneration(envelope.generation)
        envelope.rootSource = .userBookmark
        envelope.expectedRootPath = root.path
        envelope.bookmark = bookmark
        try persist(envelope)
        return envelope.snapshot
      } catch let error as SessionSettingsError {
        throw error
      } catch {
        throw SessionSettingsError.requiresReselection
      }
    }
  }

  public func resetRootToDefault(
    expectedGeneration: UInt64
  ) throws -> SessionSettingsSnapshot {
    try locked {
      var envelope = try loadEnvelope()
      try requireGeneration(expectedGeneration, envelope: envelope)
      let root = try standardizedAbsoluteFileURL(defaultRootProvider())
      envelope.generation = try nextGeneration(envelope.generation)
      envelope.rootSource = .defaultApplicationSupport
      envelope.expectedRootPath = root.path
      envelope.bookmark = nil
      try persist(envelope)
      return envelope.snapshot
    }
  }

  public func resetAllToDefaults(
    expectedGeneration: UInt64
  ) throws -> SessionSettingsSnapshot {
    try locked {
      let current = try loadEnvelope()
      try requireGeneration(expectedGeneration, envelope: current)
      let root = try standardizedAbsoluteFileURL(defaultRootProvider())
      let envelope = PersistentSessionSettings(
        generation: try nextGeneration(current.generation),
        rootSource: .defaultApplicationSupport,
        expectedRootPath: root.path,
        totalQuotaBytes: SessionSettingsSnapshot.defaultTotalQuotaBytes,
        safetyMarginBytes: SessionSettingsSnapshot.defaultSafetyMarginBytes,
        retentionDays: SessionSettingsSnapshot.defaultRetentionDays,
        bookmark: nil)
      try persist(envelope)
      return envelope.snapshot
    }
  }

  public func acquireRoot(
    for expected: SessionSettingsSnapshot
  ) throws -> SessionRootAccessContext {
    try locked {
      var envelope = try loadEnvelope()
      guard envelope.snapshot == expected else {
        throw SessionSettingsError.staleGeneration(
          expected: expected.generation, actual: envelope.generation)
      }
      let expectedURL = try standardizedAbsoluteFileURL(
        URL(filePath: envelope.expectedRootPath))
      switch envelope.rootSource {
      case .defaultApplicationSupport:
        let actualDefault = try standardizedAbsoluteFileURL(defaultRootProvider())
        guard actualDefault.path == expectedURL.path, envelope.bookmark == nil else {
          throw SessionSettingsError.invalidRoot
        }
        try validateRoot(expectedURL, createIfMissing: true)
        return SessionRootAccessContext(
          settings: envelope.snapshot,
          lease: SessionRootAccessLease(
            url: expectedURL, rootSource: .defaultApplicationSupport))

      case .userBookmark:
        guard let bookmark = envelope.bookmark, !bookmark.isEmpty else {
          throw SessionSettingsError.configurationMissingFields
        }
        let resolution: SessionBookmarkResolution
        do {
          resolution = try bookmarkAccess.resolveReadWriteBookmark(bookmark)
        } catch {
          throw SessionSettingsError.requiresReselection
        }
        let resolved = try standardizedAbsoluteFileURL(resolution.url)
        guard resolved.path == expectedURL.path, bookmarkAccess.startAccessing(resolved) else {
          throw SessionSettingsError.requiresReselection
        }
        var accessTransferred = false
        defer {
          if !accessTransferred { bookmarkAccess.stopAccessing(resolved) }
        }
        do {
          try validateRoot(resolved, createIfMissing: false)
          if resolution.isStale {
            do {
              let replacement = try bookmarkAccess.makeReadWriteBookmark(for: resolved)
              guard !replacement.isEmpty else {
                throw SessionSettingsError.requiresReselection
              }
              envelope.generation = try nextGeneration(envelope.generation)
              envelope.bookmark = replacement
              try persist(envelope)
            } catch {
              throw SessionSettingsError.requiresReselection
            }
          }
          accessTransferred = true
          return SessionRootAccessContext(
            settings: envelope.snapshot,
            lease: SessionRootAccessLease(
              url: resolved, rootSource: .userBookmark,
              stop: { [bookmarkAccess] in bookmarkAccess.stopAccessing(resolved) }))
        } catch let error as SessionSettingsError {
          throw error
        } catch {
          throw SessionSettingsError.requiresReselection
        }
      }
    }
  }

  public func requireCurrent(_ expected: SessionSettingsSnapshot) throws {
    try locked {
      let actual = try loadEnvelope().snapshot
      guard actual == expected else {
        throw SessionSettingsError.staleGeneration(
          expected: expected.generation, actual: actual.generation)
      }
    }
  }

  private func loadEnvelope() throws -> PersistentSessionSettings {
    guard let object = defaults.object(forKey: Self.persistenceKey) else {
      let root = try standardizedAbsoluteFileURL(defaultRootProvider())
      return PersistentSessionSettings(
        generation: 0, rootSource: .defaultApplicationSupport,
        expectedRootPath: root.path,
        totalQuotaBytes: SessionSettingsSnapshot.defaultTotalQuotaBytes,
        safetyMarginBytes: SessionSettingsSnapshot.defaultSafetyMarginBytes,
        retentionDays: SessionSettingsSnapshot.defaultRetentionDays,
        bookmark: nil)
    }
    guard let data = object as? Data else {
      throw SessionSettingsError.configurationWrongType
    }
    let envelope: PersistentSessionSettings
    do {
      envelope = try JSONDecoder().decode(PersistentSessionSettings.self, from: data)
      guard try canonicalData(envelope) == data else {
        throw SessionSettingsError.configurationMissingFields
      }
    } catch let error as SessionSettingsError {
      throw error
    } catch {
      throw SessionSettingsError.configurationMissingFields
    }
    guard envelope.schemaVersion == SessionSettingsSnapshot.schemaVersion else {
      throw SessionSettingsError.unsupportedSchemaVersion
    }
    try validatePolicy(
      totalQuotaBytes: envelope.totalQuotaBytes,
      safetyMarginBytes: envelope.safetyMarginBytes,
      retentionDays: envelope.retentionDays)
    let expectedURL = try standardizedAbsoluteFileURL(
      URL(filePath: envelope.expectedRootPath))
    guard expectedURL.path == envelope.expectedRootPath else {
      throw SessionSettingsError.invalidRoot
    }
    switch envelope.rootSource {
    case .defaultApplicationSupport:
      let defaultURL = try standardizedAbsoluteFileURL(defaultRootProvider())
      guard envelope.bookmark == nil, expectedURL.path == defaultURL.path else {
        throw SessionSettingsError.invalidRoot
      }
    case .userBookmark:
      guard envelope.bookmark?.isEmpty == false else {
        throw SessionSettingsError.configurationMissingFields
      }
    }
    return envelope
  }

  private func persist(_ envelope: PersistentSessionSettings) throws {
    let data = try canonicalData(envelope)
    try configurationEpoch.performMutation {
      try faultInjector.check(.beforePersistence)
      defaults.set(data, forKey: Self.persistenceKey)
      guard let persisted = defaults.object(forKey: Self.persistenceKey) as? Data,
        persisted == data
      else { throw SessionSettingsError.persistenceFailed }
    }
  }

  private func validatePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) throws {
    guard totalQuotaBytes > safetyMarginBytes, safetyMarginBytes > 0 else {
      throw SessionSettingsError.invalidQuota
    }
    guard retentionDays > 0, Int(exactly: retentionDays) != nil else {
      throw SessionSettingsError.invalidRetentionDays
    }
  }

  private func validateRoot(_ url: URL, createIfMissing: Bool) throws {
    if createIfMissing {
      do {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw SessionSettingsError.invalidRoot
      }
    }
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IWUSR | S_IXUSR) == (S_IWUSR | S_IXUSR),
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { throw SessionSettingsError.invalidRoot }
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SessionSettingsError.invalidRoot }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(),
      opened.st_mode & (S_IWUSR | S_IXUSR) == (S_IWUSR | S_IXUSR),
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino
    else { throw SessionSettingsError.invalidRoot }

    do {
      try faultInjector.check(.beforeRootWriteProbe)
    } catch {
      throw SessionSettingsError.invalidRoot
    }
    let probeName = ".arkdeck-settings-write-probe-\(UUID().uuidString)"
    let probe = Darwin.openat(
      descriptor, probeName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard probe >= 0 else { throw SessionSettingsError.invalidRoot }
    var probeIsOpen = true
    defer {
      if probeIsOpen { Darwin.close(probe) }
      _ = Darwin.unlinkat(descriptor, probeName, 0)
    }
    guard Darwin.close(probe) == 0 else {
      probeIsOpen = false
      throw SessionSettingsError.invalidRoot
    }
    probeIsOpen = false
    guard Darwin.unlinkat(descriptor, probeName, 0) == 0 else {
      throw SessionSettingsError.invalidRoot
    }
  }

  private func standardizedAbsoluteFileURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw SessionSettingsError.invalidRoot
    }
    return url.standardizedFileURL
  }

  private func requireGeneration(
    _ expected: UInt64,
    envelope: PersistentSessionSettings
  ) throws {
    guard envelope.generation == expected else {
      throw SessionSettingsError.staleGeneration(
        expected: expected, actual: envelope.generation)
    }
  }

  private func nextGeneration(_ generation: UInt64) throws -> UInt64 {
    let next = generation.addingReportingOverflow(1)
    guard !next.overflow else { throw SessionSettingsError.generationOverflow }
    return next.partialValue
  }

  private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

private struct PersistentSessionSettings: Codable {
  let schemaVersion: String
  var generation: UInt64
  var rootSource: SessionRootSource
  var expectedRootPath: String
  var totalQuotaBytes: UInt64
  var safetyMarginBytes: UInt64
  var retentionDays: UInt64
  var bookmark: Data?

  init(
    generation: UInt64,
    rootSource: SessionRootSource,
    expectedRootPath: String,
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64,
    bookmark: Data?
  ) {
    schemaVersion = SessionSettingsSnapshot.schemaVersion
    self.generation = generation
    self.rootSource = rootSource
    self.expectedRootPath = expectedRootPath
    self.totalQuotaBytes = totalQuotaBytes
    self.safetyMarginBytes = safetyMarginBytes
    self.retentionDays = retentionDays
    self.bookmark = bookmark
  }

  var snapshot: SessionSettingsSnapshot {
    SessionSettingsSnapshot(
      generation: generation, rootSource: rootSource,
      expectedRootPath: expectedRootPath,
      totalQuotaBytes: totalQuotaBytes,
      safetyMarginBytes: safetyMarginBytes,
      retentionDays: retentionDays)
  }
}
