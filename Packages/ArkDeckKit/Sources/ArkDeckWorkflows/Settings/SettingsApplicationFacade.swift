import ArkDeckStorage
import Foundation

/// App-facing Settings values. The App receives bounded presentation data and
/// explicit user actions, never a storage catalog, exporter, or Runtime
/// coordinator that could be used to bypass their validation contracts.
public struct SettingsGeneralPresentation: Equatable, Sendable {
  public let appName: String
  public let appVersion: String
  public let buildVersion: String
  public let platform: String
  public let architecture: String

  public init(
    appName: String,
    appVersion: String,
    buildVersion: String,
    platform: String,
    architecture: String
  ) {
    self.appName = appName
    self.appVersion = appVersion
    self.buildVersion = buildVersion
    self.platform = platform
    self.architecture = architecture
  }
}

public struct SettingsStoragePresentation: Equatable, Sendable {
  public let generation: UInt64
  public let rootPath: String
  public let usesCustomRoot: Bool
  public let totalQuotaBytes: UInt64
  public let safetyMarginBytes: UInt64
  public let retentionDays: UInt64
  public let currentBytes: UInt64?
  public let pinnedBytes: UInt64?
  public let pinnedSessionCount: Int?
  public let unknownPressure: Bool?
  public let blocksNewHeavyWriters: Bool?

  public init(
    generation: UInt64,
    rootPath: String,
    usesCustomRoot: Bool,
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64,
    currentBytes: UInt64?,
    pinnedBytes: UInt64?,
    pinnedSessionCount: Int?,
    unknownPressure: Bool?,
    blocksNewHeavyWriters: Bool?
  ) {
    self.generation = generation
    self.rootPath = rootPath
    self.usesCustomRoot = usesCustomRoot
    self.totalQuotaBytes = totalQuotaBytes
    self.safetyMarginBytes = safetyMarginBytes
    self.retentionDays = retentionDays
    self.currentBytes = currentBytes
    self.pinnedBytes = pinnedBytes
    self.pinnedSessionCount = pinnedSessionCount
    self.unknownPressure = unknownPressure
    self.blocksNewHeavyWriters = blocksNewHeavyWriters
  }
}

public struct SettingsApplicationPresentation: Equatable, Sendable {
  public let general: SettingsGeneralPresentation
  public let storage: SettingsStoragePresentation

  public init(
    general: SettingsGeneralPresentation,
    storage: SettingsStoragePresentation
  ) {
    self.general = general
    self.storage = storage
  }
}

public struct SettingsDiagnosticBundlePreview: Equatable, Sendable {
  public let scopeSHA256: String
  public let includedEntries: [String]
  public let estimatedBytes: UInt64
  public let deviceRawExcluded: Bool
  public let sensitiveDataWarning: String

  public init(
    scopeSHA256: String,
    includedEntries: [String],
    estimatedBytes: UInt64,
    deviceRawExcluded: Bool,
    sensitiveDataWarning: String
  ) {
    self.scopeSHA256 = scopeSHA256
    self.includedEntries = includedEntries
    self.estimatedBytes = estimatedBytes
    self.deviceRawExcluded = deviceRawExcluded
    self.sensitiveDataWarning = sensitiveDataWarning
  }
}

public enum SettingsApplicationError: Error, Equatable, Sendable {
  case diagnosticsUnavailable
}

public protocol SettingsApplicationProviding: Sendable {
  func refresh() async throws -> SettingsApplicationPresentation
  func updateStoragePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) async throws -> SettingsApplicationPresentation
  func selectStorageRoot(_ url: URL) async throws -> SettingsApplicationPresentation
  func resetStorageRoot() async throws -> SettingsApplicationPresentation
  func previewDiagnosticBundle(at destination: URL) async throws
    -> SettingsDiagnosticBundlePreview
  func exportDiagnosticBundle(
    to destination: URL,
    approvedPreview: SettingsDiagnosticBundlePreview
  ) async throws -> URL
}

public enum SettingsApplicationFacade {
  public static func make() -> any SettingsApplicationProviding {
    ProductionSettingsApplicationProvider()
  }
}

private actor ProductionSettingsApplicationProvider: SettingsApplicationProviding {
  private let storageRuntime: SessionStorageApplicationRuntime
  private let diagnosticExporter: LocalDiagnosticBundleExporter?
  private let general: SettingsGeneralPresentation

  init(
    storageRuntime: SessionStorageApplicationRuntime = .production,
    bundle: Bundle = .main
  ) {
    self.storageRuntime = storageRuntime
    diagnosticExporter = try? LocalDiagnosticBundleExporter()
    general = Self.makeGeneralPresentation(bundle: bundle)
  }

  func refresh() async throws -> SettingsApplicationPresentation {
    let settings = try storageRuntime.settingsStore.load()
    let retention = try? await storageRuntime.refresh()
    return SettingsApplicationPresentation(
      general: general,
      storage: Self.makeStoragePresentation(settings: settings, retention: retention))
  }

  func updateStoragePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) async throws -> SettingsApplicationPresentation {
    let current = try storageRuntime.settingsStore.load()
    _ = try storageRuntime.settingsStore.savePolicy(
      totalQuotaBytes: totalQuotaBytes,
      safetyMarginBytes: safetyMarginBytes,
      retentionDays: retentionDays,
      expectedGeneration: current.generation)
    return try await refresh()
  }

  func selectStorageRoot(_ url: URL) async throws -> SettingsApplicationPresentation {
    let current = try storageRuntime.settingsStore.load()
    _ = try storageRuntime.settingsStore.selectCustomRoot(
      url, expectedGeneration: current.generation)
    return try await refresh()
  }

  func resetStorageRoot() async throws -> SettingsApplicationPresentation {
    let current = try storageRuntime.settingsStore.load()
    _ = try storageRuntime.settingsStore.resetRootToDefault(
      expectedGeneration: current.generation)
    return try await refresh()
  }

  func previewDiagnosticBundle(at destination: URL) async throws
    -> SettingsDiagnosticBundlePreview
  {
    guard let diagnosticExporter else {
      throw SettingsApplicationError.diagnosticsUnavailable
    }
    return Self.presentation(
      try diagnosticExporter.preview(try diagnosticRequest(destination: destination)))
  }

  func exportDiagnosticBundle(
    to destination: URL,
    approvedPreview: SettingsDiagnosticBundlePreview
  ) async throws -> URL {
    guard let diagnosticExporter else {
      throw SettingsApplicationError.diagnosticsUnavailable
    }
    let storagePreview = LocalDiagnosticBundlePreview(
      scopeSHA256: approvedPreview.scopeSHA256,
      includedEntries: approvedPreview.includedEntries,
      estimatedBytes: approvedPreview.estimatedBytes,
      deviceRawExcluded: approvedPreview.deviceRawExcluded,
      sensitiveDataWarning: approvedPreview.sensitiveDataWarning)
    return try diagnosticExporter.export(
      diagnosticRequest(destination: destination),
      trigger: .userInitiated,
      approvedPreview: storagePreview
    ).root
  }

  private func diagnosticRequest(destination: URL) throws -> LocalDiagnosticBundleRequest {
    LocalDiagnosticBundleRequest(
      destination: destination,
      metadata: try DiagnosticBundleMetadata(
        appName: general.appName,
        appVersion: general.appVersion,
        buildVersion: general.buildVersion,
        platform: general.platform,
        architecture: general.architecture),
      tool: DiagnosticToolPlaceholder(
        path: .redacted,
        version: .unverified,
        serverEndpoint: .redacted,
        serverOwnership: .unverified),
      logs: [],
      recentSessions: [])
  }

  private static func presentation(
    _ preview: LocalDiagnosticBundlePreview
  ) -> SettingsDiagnosticBundlePreview {
    SettingsDiagnosticBundlePreview(
      scopeSHA256: preview.scopeSHA256,
      includedEntries: preview.includedEntries,
      estimatedBytes: preview.estimatedBytes,
      deviceRawExcluded: preview.deviceRawExcluded,
      sensitiveDataWarning: preview.sensitiveDataWarning)
  }

  private static func makeStoragePresentation(
    settings: SessionSettingsSnapshot,
    retention: SessionRetentionPreview?
  ) -> SettingsStoragePresentation {
    SettingsStoragePresentation(
      generation: settings.generation,
      rootPath: settings.expectedRootPath,
      usesCustomRoot: settings.rootSource == .userBookmark,
      totalQuotaBytes: settings.totalQuotaBytes,
      safetyMarginBytes: settings.safetyMarginBytes,
      retentionDays: settings.retentionDays,
      currentBytes: retention?.currentBytes,
      pinnedBytes: retention?.pinnedBytes,
      pinnedSessionCount: retention?.entries.filter(\.isPinned).count,
      unknownPressure: retention?.unknownPressure,
      blocksNewHeavyWriters: retention?.blocksNewHeavyWriters)
  }

  private static func makeGeneralPresentation(bundle: Bundle) -> SettingsGeneralPresentation {
    let version = bounded(
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      fallback: "development")
    let build = bounded(
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      fallback: "development")
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    return SettingsGeneralPresentation(
      appName: "ArkDeck",
      appVersion: version,
      buildVersion: build,
      platform:
        "macOS \(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
      architecture: architecture)
  }

  private static func bounded(_ value: String?, fallback: String) -> String {
    guard let value, !value.isEmpty else { return fallback }
    return String(value.prefix(256))
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }
}
