import ArkDeckCore
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

/// The Runtime-owned Session output root, measured by its durable owner.
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
  /// `nil` only on the legacy injected test seam when the root could not be measured.
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
  case runtimeStorageUnavailable
  case runtimeStorageRejected(String)
  case runtimeStorageResponseInvalid
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
  /// The production provider — or, for a launch that declares the Runtime a
  /// fixture, the same provider answered by `SettingsStorageUIFixture` in
  /// place of the daemon. Validation, the migration guard and the presentation
  /// mapping are shared; only the transport differs. A launch without that
  /// argument never reaches the fixture.
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any SettingsApplicationProviding {
    make(arguments: arguments, fixtureRoot: nil)
  }

  /// Test seam: the fixture launch with its owner rooted where the test says,
  /// so contract tests running in parallel processes never share the App's
  /// one fixed owner directory. Production is unreachable from here: without
  /// the selecting argument the root is ignored and the XPC provider is made.
  package static func make(
    arguments: [String], fixtureRoot: URL?
  ) -> any SettingsApplicationProviding {
    if let owner = SettingsStorageUIFixture.owner(arguments: arguments, root: fixtureRoot) {
      return ProductionSettingsApplicationProvider(
        runtimeRequest: { method, params in
          guard await owner.isReachable() else { return .failure(.unavailable("fixture")) }
          return .success(await owner.reply(method, params))
        },
        migratesLegacyPreferences: false)
    }
    return ProductionSettingsApplicationProvider()
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

package struct SettingsLegacyStorageMigrationPlan: Equatable, Sendable {
  package let rootPath: String?
  package let policy: RuntimeSessionStoragePolicy?

  package init?(
    legacy: SessionSettingsSnapshot,
    current: SettingsStoragePresentation
  ) {
    // Generation 1 is the daemon's unpublished initial state. Once any App or
    // CLI caller has changed it, old process-local preferences lose the race
    // and can never overwrite the Runtime owner.
    guard current.generation == 1, !current.usesCustomRoot, legacy.generation > 0 else {
      return nil
    }
    if legacy.rootSource == .userBookmark {
      let canonical = legacy.sessionsRoot.resolvingSymlinksInPath().standardizedFileURL.path
      rootPath = canonical == current.rootPath ? nil : canonical
    } else {
      rootPath = nil
    }
    let candidate = RuntimeSessionStoragePolicy(
      totalQuotaBytes: legacy.totalQuotaBytes,
      safetyMarginBytes: legacy.safetyMarginBytes,
      retentionDays: legacy.retentionDays)
    if candidate.totalQuotaBytes == current.totalQuotaBytes,
      candidate.safetyMarginBytes == current.safetyMarginBytes,
      candidate.retentionDays == current.retentionDays
    {
      policy = nil
    } else {
      policy = candidate
    }
    if rootPath == nil, policy == nil { return nil }
  }
}

private actor ProductionSettingsApplicationProvider: SettingsApplicationProviding {
  /// One Runtime storage request: the method and its closed parameters in, the
  /// daemon's framed reply out. Production sends it over XPC; the UI fixture
  /// answers it in process from the same owner type the daemon composes.
  typealias RuntimeRequest = @Sendable (
    _ method: String, _ params: [String: JSONValue]?
  ) async -> RuntimeXPCRequestTransport.ResultValue

  private let legacyStorageRuntime: SessionStorageApplicationRuntime?
  private let legacyRuntimeArtifactUsage: (@Sendable () async -> SettingsRuntimeArtifactUsage?)?
  private let legacyMigrationStore: SessionSettingsStore?
  private let runtimeRequest: RuntimeRequest
  private let supportBundleProvider: any RuntimeSupportBundleProviding
  private let general: SettingsGeneralPresentation
  private var legacyMigrationAssessed = false

  init(
    storageRuntime: SessionStorageApplicationRuntime? = nil,
    runtimeArtifactUsage: (@Sendable () async -> SettingsRuntimeArtifactUsage?)? = nil,
    runtimeRequest: @escaping RuntimeRequest = { method, params in
      await RuntimeXPCRequestTransport.request(
        method: method, params: params,
        protocolVersion: ArkDeckControlProtocol.currentVersion)
    },
    migratesLegacyPreferences: Bool = true,
    bundle: Bundle = .main
  ) {
    legacyStorageRuntime = storageRuntime
    legacyRuntimeArtifactUsage = runtimeArtifactUsage
    self.runtimeRequest = runtimeRequest
    // The one-time migration reads this process's own preferences. Under the
    // UI fixture that would carry a developer's custom root or policy into the
    // fixture owner and make the pane host-dependent again, so it stays off.
    legacyMigrationStore =
      storageRuntime == nil && migratesLegacyPreferences ? SessionSettingsStore() : nil
    supportBundleProvider = RuntimeSupportBundleApplicationFacade.make(bundle: bundle)
    general = Self.makeGeneralPresentation(bundle: bundle)
  }

  func refresh() async throws -> SettingsApplicationPresentation {
    let storage: SettingsStoragePresentation
    if let storageRuntime = legacyStorageRuntime {
      let settings = try storageRuntime.settingsStore.load()
      let retention = try? await storageRuntime.refresh()
      let artifacts: SettingsRuntimeArtifactUsage?
      if let legacyRuntimeArtifactUsage {
        artifacts = await legacyRuntimeArtifactUsage()
      } else {
        artifacts = nil
      }
      storage = Self.makeStoragePresentation(
        settings: settings, retention: retention, runtimeArtifacts: artifacts)
    } else {
      let current = try await runtimeStorage(method: "runtime.storage.status")
      storage = try await migrateLegacyStorageIfNeeded(current)
    }
    return SettingsApplicationPresentation(
      general: general, storage: storage)
  }

  private func migrateLegacyStorageIfNeeded(
    _ current: SettingsStoragePresentation
  ) async throws -> SettingsStoragePresentation {
    guard !legacyMigrationAssessed else { return current }
    legacyMigrationAssessed = true
    guard let legacyMigrationStore,
      let legacy = try? legacyMigrationStore.load(),
      let plan = SettingsLegacyStorageMigrationPlan(legacy: legacy, current: current)
    else { return current }

    var migrated = current
    do {
      // Move the root first. A root that the daemon cannot validate leaves the
      // policy untouched and asks the user to reselect instead of publishing a
      // half-migrated configuration. Every mutation is generation-bound.
      if let rootPath = plan.rootPath {
        migrated = try await runtimeStorage(
          method: "runtime.storage.root",
          params: [
            "expectedGeneration": .string(String(migrated.generation)),
            "rootPath": .string(rootPath),
          ])
      }
      if let policy = plan.policy {
        migrated = try await runtimeStorage(
          method: "runtime.storage.policy",
          params: [
            "expectedGeneration": .string(String(migrated.generation)),
            "totalQuotaBytes": .string(String(policy.totalQuotaBytes)),
            "safetyMarginBytes": .string(String(policy.safetyMarginBytes)),
            "retentionDays": .string(String(policy.retentionDays)),
          ])
      }
      return migrated
    } catch SettingsApplicationError.runtimeStorageRejected("resourceConflict") {
      // Another App/CLI writer published first. Read its result and never
      // replay the obsolete process-local preference.
      return try await runtimeStorage(method: "runtime.storage.status")
    }
  }

  func updateStoragePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) async throws -> SettingsApplicationPresentation {
    if let storageRuntime = legacyStorageRuntime {
      let current = try storageRuntime.settingsStore.load()
      _ = try storageRuntime.settingsStore.savePolicy(
        totalQuotaBytes: totalQuotaBytes,
        safetyMarginBytes: safetyMarginBytes,
        retentionDays: retentionDays,
        expectedGeneration: current.generation)
      return try await refresh()
    }
    let current = try await runtimeStorage(method: "runtime.storage.status")
    let storage = try await runtimeStorage(
      method: "runtime.storage.policy",
      params: [
        "expectedGeneration": .string(String(current.generation)),
        "totalQuotaBytes": .string(String(totalQuotaBytes)),
        "safetyMarginBytes": .string(String(safetyMarginBytes)),
        "retentionDays": .string(String(retentionDays)),
      ])
    return SettingsApplicationPresentation(general: general, storage: storage)
  }

  func selectStorageRoot(_ url: URL) async throws -> SettingsApplicationPresentation {
    if let storageRuntime = legacyStorageRuntime {
      let current = try storageRuntime.settingsStore.load()
      _ = try storageRuntime.settingsStore.selectCustomRoot(
        url, expectedGeneration: current.generation)
      return try await refresh()
    }
    let current = try await runtimeStorage(method: "runtime.storage.status")
    let storage = try await runtimeStorage(
      method: "runtime.storage.root",
      params: [
        "expectedGeneration": .string(String(current.generation)),
        "rootPath": .string(url.resolvingSymlinksInPath().standardizedFileURL.path),
      ])
    return SettingsApplicationPresentation(general: general, storage: storage)
  }

  func resetStorageRoot() async throws -> SettingsApplicationPresentation {
    if let storageRuntime = legacyStorageRuntime {
      let current = try storageRuntime.settingsStore.load()
      _ = try storageRuntime.settingsStore.resetRootToDefault(
        expectedGeneration: current.generation)
      return try await refresh()
    }
    let current = try await runtimeStorage(method: "runtime.storage.status")
    let storage = try await runtimeStorage(
      method: "runtime.storage.root",
      params: [
        "expectedGeneration": .string(String(current.generation)),
        "resetToDefault": .bool(true),
      ])
    return SettingsApplicationPresentation(general: general, storage: storage)
  }

  private func runtimeStorage(
    method: String,
    params: [String: JSONValue]? = nil
  ) async throws -> SettingsStoragePresentation {
    let response = await runtimeRequest(method, params)
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure: throw SettingsApplicationError.runtimeStorageUnavailable
    }
    guard let decoded = try? JSONSerialization.jsonObject(with: data),
      let envelope = decoded as? [String: Any]
    else { throw SettingsApplicationError.runtimeStorageResponseInvalid }
    if let error = envelope["error"] as? [String: Any],
      let code = error["code"] as? String
    {
      throw SettingsApplicationError.runtimeStorageRejected(code)
    }
    guard let result = envelope["result"] as? [String: Any],
      Self.hasExactKeys(result, ["schemaVersion", "sessionDomain", "artifactDomain"]),
      result["schemaVersion"] as? String == "arkdeck.runtime-storage/1",
      let sessions = result["sessionDomain"] as? [String: Any],
      Self.hasExactKeys(
        sessions,
        [
          "schemaVersion", "generation", "rootPath", "rootKind", "policy", "usage",
          "catalogGeneration",
        ]),
      sessions["schemaVersion"] as? String == "arkdeck.session-storage-status/1",
      let generation = Self.positiveDecimal(sessions["generation"]),
      let rootPath = sessions["rootPath"] as? String, rootPath.hasPrefix("/"),
      rootPath == URL(filePath: rootPath, directoryHint: .isDirectory).standardizedFileURL.path,
      let rootKind = sessions["rootKind"] as? String,
      ["default", "custom"].contains(rootKind),
      let policy = sessions["policy"] as? [String: Any],
      Self.hasExactKeys(
        policy, ["totalQuotaBytes", "safetyMarginBytes", "retentionDays"]),
      let totalQuota = Self.positiveDecimal(policy["totalQuotaBytes"]),
      let margin = Self.positiveDecimal(policy["safetyMarginBytes"]),
      let retention = Self.positiveDecimal(policy["retentionDays"]),
      totalQuota > margin,
      let usage = sessions["usage"] as? [String: Any],
      Self.hasExactKeys(
        usage,
        [
          "usedBytes", "pinnedBytes", "sessionCount", "pinnedSessionCount",
          "unaccountedSessionCount", "measurementIncomplete",
        ]),
      let used = Self.decimal(usage["usedBytes"]),
      let pinned = Self.decimal(usage["pinnedBytes"]),
      pinned <= used,
      let sessionCount = Self.count(usage["sessionCount"]),
      let pinnedCount = Self.count(usage["pinnedSessionCount"]),
      pinnedCount <= sessionCount,
      let unaccounted = Self.count(usage["unaccountedSessionCount"]),
      let incomplete = usage["measurementIncomplete"] as? Bool,
      Self.isOptionalDecimal(sessions["catalogGeneration"]),
      let artifacts = result["artifactDomain"] as? [String: Any],
      Self.hasExactKeys(
        artifacts,
        [
          "schemaVersion", "rootReference", "policy", "totalBytes", "usedBytes",
          "remainingBytes",
        ]),
      artifacts["schemaVersion"] as? String == "arkdeck.artifact-storage-status/1",
      artifacts["rootReference"] as? String == "arkdeck-runtime://artifacts",
      artifacts["policy"] as? String == "refuseNewWorkNeverEvict",
      let artifactTotal = Self.decimal(artifacts["totalBytes"]),
      let artifactUsed = Self.decimal(artifacts["usedBytes"]),
      let artifactRemaining = Self.decimal(artifacts["remainingBytes"]),
      artifactUsed <= artifactTotal,
      artifactRemaining == artifactTotal - artifactUsed
    else { throw SettingsApplicationError.runtimeStorageResponseInvalid }
    return SettingsStoragePresentation(
      generation: generation,
      rootPath: rootPath,
      usesCustomRoot: rootKind == "custom",
      totalQuotaBytes: totalQuota,
      safetyMarginBytes: margin,
      retentionDays: retention,
      runtimeArtifacts: SettingsRuntimeArtifactUsage(
        usedBytes: artifactUsed, totalBytes: artifactTotal,
        remainingBytes: artifactRemaining),
      sessionRoot: SettingsSessionRootUsage(
        measuredBytes: used, pinnedBytes: pinned,
        pinnedSessionCount: pinnedCount,
        unaccountedSessionCount: unaccounted,
        measurementIncomplete: incomplete))
  }

  private static func decimal(_ value: Any?) -> UInt64? {
    guard let text = value as? String, !text.isEmpty,
      text.utf8.allSatisfy({ (48...57).contains($0) }),
      text == "0" || text.first != "0"
    else { return nil }
    return UInt64(text)
  }

  private static func positiveDecimal(_ value: Any?) -> UInt64? {
    decimal(value).flatMap { $0 > 0 ? $0 : nil }
  }

  private static func isOptionalDecimal(_ value: Any?) -> Bool {
    value is NSNull || decimal(value) != nil
  }

  private static func hasExactKeys(_ object: [String: Any], _ keys: Set<String>) -> Bool {
    Set(object.keys) == keys
  }

  private static func count(_ value: Any?) -> Int? {
    decimal(value).flatMap(Int.init(exactly:))
  }

  func previewDiagnosticBundle(at destination: URL) async throws
    -> SettingsDiagnosticBundlePreview
  {
    let preview = try await supportBundleProvider.preview(at: destination)
    return SettingsDiagnosticBundlePreview(
      scopeSHA256: preview.scopeSHA256,
      includedEntries: preview.includedEntries,
      estimatedBytes: preview.estimatedBytes,
      deviceRawExcluded: preview.deviceRawExcluded,
      sensitiveDataWarning: preview.sensitiveDataWarning)
  }

  func exportDiagnosticBundle(
    to destination: URL,
    approvedPreview: SettingsDiagnosticBundlePreview
  ) async throws -> URL {
    let receipt = try await supportBundleProvider.export(
      to: destination, approvedScopeSHA256: approvedPreview.scopeSHA256)
    return URL(filePath: receipt.destination, directoryHint: .isDirectory)
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
