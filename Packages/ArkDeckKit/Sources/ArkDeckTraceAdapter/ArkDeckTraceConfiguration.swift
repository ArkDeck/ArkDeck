import ArkTraceAppSupport
import ArkTraceRuntime
import Foundation
import UniformTypeIdentifiers

/// ArkDeck-owned composition values for the shared ArkTrace engine.
///
/// Shared parsing, storage, runtime, analysis and rendering code lives only in
/// ArkTrace. This adapter owns the values that legitimately differ for the
/// sandboxed ArkDeck product.
public enum ArkDeckTraceConfiguration {
  public static let bundleIdentifier = "com.arkdeck.desktop"
  public static let recentDocumentsKey = "ArkDeck.Trace.RecentTraceBookmarks.v1"
  public static let signpostSubsystem = "com.arkdeck.desktop.trace"
  public static let supportedTraceExtensions = [
    "htrace", "ftrace", "systrace", "trace",
  ]

  public static var supportedTraceContentTypes: [UTType] {
    supportedTraceExtensions.compactMap { UTType(filenameExtension: $0) }
  }

  /// The sandboxed App's cache root as observed from the unsandboxed daemon.
  /// Runtime derives this from the reviewed bundle identity; no control-plane
  /// request can select or widen it.
  public static func appContainerCachesDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory
      .appending(path: "Library/Containers", directoryHint: .isDirectory)
      .appending(path: bundleIdentifier, directoryHint: .isDirectory)
      .appending(path: "Data/Library/Caches", directoryHint: .isDirectory)
  }

  public static func cacheDirectories(
    cachesDirectory: URL
  ) -> (cache: URL, staging: URL) {
    let root = cachesDirectory.appending(
      path: "ArkDeck/Trace", directoryHint: .isDirectory)
    return (
      root.appending(path: "traces", directoryHint: .isDirectory),
      root.appending(path: "staging", directoryHint: .isDirectory)
    )
  }

  public static func make(
    bundleURL: URL = Bundle.main.bundleURL,
    cachesDirectory: URL? = nil
  ) -> TraceProductConfiguration {
    let base =
      cachesDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let directories = cacheDirectories(cachesDirectory: base)
    do {
      return try TraceProductConfiguration(
        bundleURL: bundleURL,
        cacheDirectory: directories.cache,
        stagingDirectory: directories.staging,
        recentDocumentsKey: recentDocumentsKey,
        signpostSubsystem: signpostSubsystem,
        bundledParser: TraceBundledParserLocation(
          executableRelativePath: "Contents/MacOS/trace_streamer",
          manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"
        ),
        bundledParserExecutionPolicy: .signedBundleInPlace
      )
    } catch {
      preconditionFailure("reviewed ArkDeck Trace configuration is invalid")
    }
  }
}

public struct ArkDeckTraceCacheInventory: Sendable, Equatable {
  public let entryCount: Int
  public let totalByteCount: Int64
  public let activeEntryCount: Int

  public init(entryCount: Int, totalByteCount: Int64, activeEntryCount: Int) {
    self.entryCount = entryCount
    self.totalByteCount = totalByteCount
    self.activeEntryCount = activeEntryCount
  }
}

public struct ArkDeckTraceCachePurgeReport: Sendable, Equatable {
  public let before: ArkDeckTraceCacheInventory
  public let after: ArkDeckTraceCacheInventory
  public let recoveredPrivateDirectoryCount: Int
  public let removedOrphanOwnerMarkerCount: Int
  public let removedEntryCount: Int
  public let skippedActiveEntryCount: Int

  public init(
    before: ArkDeckTraceCacheInventory,
    after: ArkDeckTraceCacheInventory,
    recoveredPrivateDirectoryCount: Int,
    removedOrphanOwnerMarkerCount: Int,
    removedEntryCount: Int,
    skippedActiveEntryCount: Int
  ) {
    self.before = before
    self.after = after
    self.recoveredPrivateDirectoryCount = recoveredPrivateDirectoryCount
    self.removedOrphanOwnerMarkerCount = removedOrphanOwnerMarkerCount
    self.removedEntryCount = removedEntryCount
    self.skippedActiveEntryCount = skippedActiveEntryCount
  }
}

/// ArkDeck's narrow adapter over ArkTrace's lease-aware maintenance owner.
/// The cache and staging siblings are fixed at construction and never appear
/// in inventory or purge results.
public actor ArkDeckTraceCacheMaintenanceService {
  private let service: TraceCacheMaintenanceService

  public init(cachesDirectory: URL) throws {
    let directories = ArkDeckTraceConfiguration.cacheDirectories(
      cachesDirectory: cachesDirectory)
    service = try TraceCacheMaintenanceService(
      cacheDirectory: directories.cache,
      stagingDirectory: directories.staging)
  }

  public func inventory() async throws -> ArkDeckTraceCacheInventory {
    Self.inventory(try await service.inventory())
  }

  public func purgeUnused() async throws -> ArkDeckTraceCachePurgeReport {
    let report = try await service.purgeUnused()
    return ArkDeckTraceCachePurgeReport(
      before: Self.inventory(report.before),
      after: Self.inventory(report.after),
      recoveredPrivateDirectoryCount: report.recoveredPrivateDirectoryCount,
      removedOrphanOwnerMarkerCount: report.removedOrphanOwnerMarkerCount,
      removedEntryCount: report.removedEntryCount,
      skippedActiveEntryCount: report.skippedActiveEntryCount)
  }

  private static func inventory(_ value: TraceCacheInventory) -> ArkDeckTraceCacheInventory {
    ArkDeckTraceCacheInventory(
      entryCount: value.entryCount,
      totalByteCount: value.totalByteCount,
      activeEntryCount: value.activeEntryCount)
  }
}
