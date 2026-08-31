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

/// The Runtime's artifact store: the bytes this product actually writes.
///
/// The Runtime reports this rather than the App measuring it, because the App
/// cannot measure it. The App Sandbox puts the daemon's state directory
/// outside this container, so anything counted in-process describes the
/// Session output root below and nothing else — which is what this screen
/// used to show while every Job's bytes accumulated somewhere it never looked.
public struct SettingsRuntimeArtifactUsage: Equatable, Sendable {
  public let usedBytes: UInt64
  public let totalBytes: UInt64
  public let remainingBytes: UInt64

  public init(usedBytes: UInt64, totalBytes: UInt64, remainingBytes: UInt64) {
    self.usedBytes = usedBytes
    self.totalBytes = totalBytes
    self.remainingBytes = remainingBytes
  }
}

/// The App-owned Session output root, measured in this process.
///
/// A second root, not a second view of the same bytes: nothing the Runtime
/// publishes lands here. It is reported under its own name so the quota,
/// safety margin and retention window — which govern this root and nothing
/// else — are read against the tree they actually apply to.
public struct SettingsSessionRootUsage: Equatable, Sendable {
  public let measuredBytes: UInt64
  public let pinnedBytes: UInt64
  public let pinnedSessionCount: Int
  /// Sessions the retention catalog could not identify. It never deletes what
  /// it cannot account for, so those bytes are held indefinitely. They are
  /// inside `measuredBytes` and named separately here because "stored" and
  /// "reclaimable" are not the same number.
  public let unaccountedSessionCount: Int
  /// Some part of the tree could not be classified or measured exactly, so
  /// `measuredBytes` is a floor rather than a total.
  public let measurementIncomplete: Bool

  public init(
    measuredBytes: UInt64,
    pinnedBytes: UInt64,
    pinnedSessionCount: Int,
    unaccountedSessionCount: Int,
    measurementIncomplete: Bool
  ) {
    self.measuredBytes = measuredBytes
    self.pinnedBytes = pinnedBytes
    self.pinnedSessionCount = pinnedSessionCount
    self.unaccountedSessionCount = unaccountedSessionCount
    self.measurementIncomplete = measurementIncomplete
  }
}

/// Storage as the product has it: two roots, each named, neither standing in
/// for the other.
///
/// Both figures are optional and neither is defaulted to zero. A store that
/// did not answer and a store with nothing in it are different facts, and a
/// screen that renders the first as the second is how a usage number comes to
/// describe a directory nothing writes to.
public struct SettingsStoragePresentation: Equatable, Sendable {
  public let generation: UInt64
  public let rootPath: String
  public let usesCustomRoot: Bool
  public let totalQuotaBytes: UInt64
  public let safetyMarginBytes: UInt64
  public let retentionDays: UInt64
  /// `nil` when the Runtime did not report its artifact usage.
  public let runtimeArtifacts: SettingsRuntimeArtifactUsage?
  /// `nil` when the Session output root could not be measured.
  public let sessionRoot: SettingsSessionRootUsage?

  public init(
    generation: UInt64,
    rootPath: String,
    usesCustomRoot: Bool,
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64,
    runtimeArtifacts: SettingsRuntimeArtifactUsage?,
    sessionRoot: SettingsSessionRootUsage?
  ) {
    self.generation = generation
    self.rootPath = rootPath
    self.usesCustomRoot = usesCustomRoot
    self.totalQuotaBytes = totalQuotaBytes
    self.safetyMarginBytes = safetyMarginBytes
    self.retentionDays = retentionDays
    self.runtimeArtifacts = runtimeArtifacts
    self.sessionRoot = sessionRoot
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

  /// Test seam. The artifact figure comes from the Runtime over the read-only
  /// control plane, which a contract test cannot stand up; everything else is
  /// the production path, including the Session root scan.
  package static func make(
    storageRuntime: SessionStorageApplicationRuntime,
    runtimeArtifactUsage: @escaping @Sendable () async -> SettingsRuntimeArtifactUsage?
  ) -> any SettingsApplicationProviding {
    ProductionSettingsApplicationProvider(
      storageRuntime: storageRuntime, runtimeArtifactUsage: runtimeArtifactUsage)
  }
}

private actor ProductionSettingsApplicationProvider: SettingsApplicationProviding {
  private let storageRuntime: SessionStorageApplicationRuntime
  private let runtimeArtifactUsage: @Sendable () async -> SettingsRuntimeArtifactUsage?
  private let diagnosticExporter: LocalDiagnosticBundleExporter?
  private let general: SettingsGeneralPresentation

  init(
    storageRuntime: SessionStorageApplicationRuntime = .production,
    runtimeArtifactUsage: @escaping @Sendable () async -> SettingsRuntimeArtifactUsage? = {
      await ProductionSettingsApplicationProvider.readRuntimeArtifactUsage()
    },
    bundle: Bundle = .main
  ) {
    self.storageRuntime = storageRuntime
    self.runtimeArtifactUsage = runtimeArtifactUsage
    diagnosticExporter = try? LocalDiagnosticBundleExporter()
    general = Self.makeGeneralPresentation(bundle: bundle)
  }

  func refresh() async throws -> SettingsApplicationPresentation {
    let settings = try storageRuntime.settingsStore.load()
    let retention = try? await storageRuntime.refresh()
    let artifacts = await runtimeArtifactUsage()
    return SettingsApplicationPresentation(
      general: general,
      storage: Self.makeStoragePresentation(
        settings: settings, retention: retention, runtimeArtifacts: artifacts))
  }

  /// The Runtime's own figure, read over the allowlisted read-only method.
  ///
  /// Anything short of three well-formed nonnegative counts is "not measured".
  /// Substituting zero for an unanswered question is the shape of the defect
  /// this replaced: the number was always plausible and never about the store
  /// the Runtime writes to.
  private static func readRuntimeArtifactUsage() async -> SettingsRuntimeArtifactUsage? {
    guard
      case .success(let data) = await RuntimeXPCRequestTransport.request(
        method: "artifact.quota", params: [:]),
      let decoded = try? JSONSerialization.jsonObject(with: data),
      let envelope = decoded as? [String: Any],
      envelope["error"] == nil,
      let result = envelope["result"] as? [String: Any],
      let used = result["usedBytes"] as? Int, used >= 0,
      let total = result["totalBytes"] as? Int, total >= 0,
      let remaining = result["remainingBytes"] as? Int, remaining >= 0
    else { return nil }
    return SettingsRuntimeArtifactUsage(
      usedBytes: UInt64(used), totalBytes: UInt64(total), remainingBytes: UInt64(remaining))
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

  /// The retention preview also carries `blocksNewHeavyWriters`, and it is
  /// deliberately not projected here. It is a verdict about admission into the
  /// Session output root, decided from a scan of that root and enforced by a
  /// coordinator no production writer consults. Shown next to a usage figure it
  /// reads as "the product may keep working", which it was never about.
  private static func makeStoragePresentation(
    settings: SessionSettingsSnapshot,
    retention: SessionRetentionPreview?,
    runtimeArtifacts: SettingsRuntimeArtifactUsage?
  ) -> SettingsStoragePresentation {
    SettingsStoragePresentation(
      generation: settings.generation,
      rootPath: settings.expectedRootPath,
      usesCustomRoot: settings.rootSource == .userBookmark,
      totalQuotaBytes: settings.totalQuotaBytes,
      safetyMarginBytes: settings.safetyMarginBytes,
      retentionDays: settings.retentionDays,
      runtimeArtifacts: runtimeArtifacts,
      sessionRoot: retention.map {
        SettingsSessionRootUsage(
          measuredBytes: $0.currentBytes,
          pinnedBytes: $0.pinnedBytes,
          pinnedSessionCount: $0.entries.filter(\.isPinned).count,
          unaccountedSessionCount: $0.unknownSessionIDs.count,
          measurementIncomplete: $0.unknownPressure)
      })
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
