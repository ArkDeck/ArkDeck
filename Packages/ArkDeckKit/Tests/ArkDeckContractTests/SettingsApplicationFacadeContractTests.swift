import ArkDeckWorkflows
import XCTest

final class SettingsApplicationFacadeContractTests: XCTestCase {
  func testSettingsDiagnosticsRequiresPreviewAndExplicitExport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-diagnostics-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let destination = root.appending(
      path: "ArkDeck-Diagnostics", directoryHint: .isDirectory)
    let provider = SettingsApplicationFacade.make()
    let preview = try await provider.previewDiagnosticBundle(at: destination)

    XCTAssertTrue(preview.deviceRawExcluded)
    XCTAssertEqual(
      Set(preview.includedEntries),
      Set(["bundle.json", "hdc/tool-placeholder.json", "metadata.json"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let exported = try await provider.exportDiagnosticBundle(
      to: destination, approvedPreview: preview)
    XCTAssertEqual(exported.standardizedFileURL, destination.standardizedFileURL)
    let manifest = try Data(contentsOf: destination.appending(path: "bundle.json"))
    XCTAssertTrue(manifest.contains(Data("\"automaticUploadEnabled\":false".utf8)))
    XCTAssertTrue(manifest.contains(Data("\"deviceRawExcluded\":true".utf8)))
  }

  func testSettingsSceneHasNamedLocalizedPartitionsIncludingRemoteBuildSources() throws {
    let repository = repositoryRoot()
    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"),
      encoding: .utf8)
    let viewModel = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsWorkspaceViewModel.swift"),
      encoding: .utf8)
    let catalogData = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/SettingsLocalizable.xcstrings"))
    let catalog = try XCTUnwrap(
      JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

    XCTAssertTrue(app.contains("SettingsRootView("))
    XCTAssertTrue(app.contains("SettingsApplicationFacade.make()"))
    XCTAssertTrue(viewModel.contains("func settingsText(_ key: String) -> String"))
    XCTAssertTrue(viewModel.contains("tableName: \"SettingsLocalizable\""))
    for key in [
      "settings.tab.general",
      "settings.tab.toolchains",
      "settings.tab.remoteSources",
      "settings.tab.storage",
      "settings.tab.updates",
      "settings.tab.diagnostics",
    ] {
      let entry = try XCTUnwrap(strings[key] as? [String: Any])
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
      XCTAssertNotNil(localizations["en"], key)
      XCTAssertNotNil(localizations["zh-Hans"], key)
      XCTAssertTrue(view.contains("settingsText(\"\(key)\")"), key)
    }
  }

  func testSettingsSourceKeepsDiagnosticRawExcludedAndUITestsOutOfModule() throws {
    let repository = repositoryRoot()
    let settingsFacade = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/SettingsApplicationFacade.swift"),
      encoding: .utf8)
    let supportFacade = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/RuntimeSupportBundleApplicationFacade.swift"),
      encoding: .utf8)
    let facade = settingsFacade + supportFacade
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"),
      encoding: .utf8)

    XCTAssertTrue(facade.contains("trigger: .userInitiated"))
    XCTAssertTrue(facade.contains("recentSessions: []"))
    XCTAssertTrue(facade.contains("path: .redacted"))
    XCTAssertTrue(facade.contains("serverEndpoint: .redacted"))
    XCTAssertTrue(view.contains("!preview.deviceRawExcluded"))
    XCTAssertFalse(view.contains("XCUIApplication"))
    XCTAssertFalse(view.contains("XCTest"))
  }

  private func repositoryRoot() -> URL {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root
  }
}

/// The Settings storage screen used to report one unlabelled figure, produced
/// by scanning the Session output root. Nothing has written that root since the
/// in-process flash host was retired, while every Job's bytes land in the
/// Runtime's artifact store — a directory the sandboxed App cannot even open.
/// The number was therefore structurally near zero and described nothing the
/// product does.
///
/// These tests hold the two roots apart: each figure is reported under its own
/// name, and neither is defaulted to zero when it is simply not known.
final class SettingsStorageDomainContractTests: XCTestCase {
  func testLegacyPolicyMigratesOnlyIntoAnUntouchedRuntimeOwner() async throws {
    let fixture = try StorageDomainFixture(label: "migration")
    defer { fixture.cleanup() }
    let legacy = try fixture.runtime.settingsStore.savePolicy(
      totalQuotaBytes: 9_000, safetyMarginBytes: 1_000, retentionDays: 30,
      expectedGeneration: 0)
    let untouched = SettingsStoragePresentation(
      generation: 1, rootPath: fixture.defaultRoot.path, usesCustomRoot: false,
      totalQuotaBytes: RuntimeSessionStorageStore.defaultPolicy.totalQuotaBytes,
      safetyMarginBytes: RuntimeSessionStorageStore.defaultPolicy.safetyMarginBytes,
      retentionDays: RuntimeSessionStorageStore.defaultPolicy.retentionDays,
      runtimeArtifacts: nil, sessionRoot: nil)

    let plan = try XCTUnwrap(
      SettingsLegacyStorageMigrationPlan(legacy: legacy, current: untouched))
    XCTAssertNil(plan.rootPath)
    XCTAssertEqual(
      plan.policy,
      RuntimeSessionStoragePolicy(
        totalQuotaBytes: 9_000, safetyMarginBytes: 1_000, retentionDays: 30))

    let alreadyOwned = SettingsStoragePresentation(
      generation: 2, rootPath: untouched.rootPath, usesCustomRoot: false,
      totalQuotaBytes: untouched.totalQuotaBytes,
      safetyMarginBytes: untouched.safetyMarginBytes,
      retentionDays: untouched.retentionDays,
      runtimeArtifacts: nil, sessionRoot: nil)
    XCTAssertNil(SettingsLegacyStorageMigrationPlan(legacy: legacy, current: alreadyOwned))
  }

  func testRuntimeArtifactsAndSessionRootAreReportedAsDistinctDomains() async throws {
    let fixture = try StorageDomainFixture(label: "distinct")
    defer { fixture.cleanup() }
    let strandedBytes = try fixture.writeUnidentifiedSession(
      sessionID: "session-stranded", byteCount: 8_192)

    let provider = SettingsApplicationFacade.make(
      storageRuntime: fixture.runtime,
      runtimeArtifactUsage: {
        SettingsRuntimeArtifactUsage(
          usedBytes: 2_684_354_560, totalBytes: 8_589_934_592,
          remainingBytes: 5_905_580_032)
      })
    let storage = try await provider.refresh().storage

    let artifacts = try XCTUnwrap(storage.runtimeArtifacts)
    XCTAssertEqual(artifacts.usedBytes, 2_684_354_560)
    XCTAssertEqual(artifacts.totalBytes, 8_589_934_592)
    XCTAssertEqual(artifacts.remainingBytes, 5_905_580_032)

    // The Session root carries its own measurement, and it is nowhere near the
    // Runtime's. A single figure could only ever have been one of these two.
    let sessionRoot = try XCTUnwrap(storage.sessionRoot)
    XCTAssertGreaterThanOrEqual(sessionRoot.measuredBytes, strandedBytes)
    XCTAssertLessThan(sessionRoot.measuredBytes, artifacts.usedBytes)

    // Bytes that are stored and bytes that can be reclaimed are different
    // numbers: the catalog never deletes a Session it cannot identify, so the
    // count is reported rather than folded into the total.
    XCTAssertEqual(sessionRoot.unaccountedSessionCount, 1)
    XCTAssertTrue(sessionRoot.measurementIncomplete)
    XCTAssertEqual(sessionRoot.pinnedSessionCount, 0)

    // The editable policy governs the Session root, not the Runtime store, and
    // must not be read against the Runtime's own quota.
    XCTAssertEqual(storage.totalQuotaBytes, 20 * 1_024 * 1_024 * 1_024)
    XCTAssertNotEqual(storage.totalQuotaBytes, artifacts.totalBytes)
    XCTAssertEqual(storage.rootPath, fixture.defaultRoot.standardizedFileURL.path)
  }

  func testUnreportedRuntimeUsageIsAbsentAndAnEmptySessionRootIsNotTheProductFigure()
    async throws
  {
    let fixture = try StorageDomainFixture(label: "absent")
    defer { fixture.cleanup() }

    let provider = SettingsApplicationFacade.make(
      storageRuntime: fixture.runtime, runtimeArtifactUsage: { nil })
    let storage = try await provider.refresh().storage

    // A Runtime that did not answer is not a Runtime storing nothing. The old
    // screen could not tell those apart because it never asked the Runtime.
    XCTAssertNil(storage.runtimeArtifacts)

    // The empty Session root still reports honestly — as the Session root.
    let sessionRoot = try XCTUnwrap(storage.sessionRoot)
    XCTAssertEqual(sessionRoot.measuredBytes, 0)
    XCTAssertEqual(sessionRoot.unaccountedSessionCount, 0)
    XCTAssertFalse(sessionRoot.measurementIncomplete)
  }

  /// The production figure must keep coming from the Runtime. Recomputing it in
  /// process is the defect, not an optimisation: the App Sandbox places the
  /// daemon's state directory outside this container.
  func testProductionUsageIsReadFromRuntimeAndRenderedPerDomain() throws {
    let repository = repositoryRoot()
    let facade = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/SettingsApplicationFacade.swift"),
      encoding: .utf8)
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"),
      encoding: .utf8)

    XCTAssertTrue(facade.contains("method: \"runtime.storage.status\""))
    XCTAssertTrue(facade.contains("ArkDeckControlProtocol.currentVersion"))
    XCTAssertFalse(facade.contains("method: \"artifact.quota\""))
    XCTAssertTrue(view.contains("storage.runtimeArtifacts"))
    XCTAssertTrue(view.contains("sessionRoot.measuredBytes"))
    XCTAssertTrue(view.contains("settings.storage.runtimeUnavailable"))
    XCTAssertTrue(view.contains("settings.storage.sessionUsage"))
  }

  private func repositoryRoot() -> URL {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root
  }
}

private final class StorageDomainFixture {
  let base: URL
  let defaultRoot: URL
  let runtime: SessionStorageApplicationRuntime
  private let suiteName: String
  private let defaults: UserDefaults

  init(label: String) throws {
    base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-storage-domain-\(label)-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defaultRoot = base.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: defaultRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    suiteName = "dev.arkdeck.tests.storage-domain.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let root = defaultRoot
    runtime = SessionStorageApplicationRuntime(
      settingsStore: SessionSettingsStore(
        defaults: defaults, defaultRootProvider: { root }))
  }

  /// A Session directory with no identity or manifest — the exact shape left
  /// behind by the retired in-process host. The catalog cannot account for it,
  /// so it counts the bytes and keeps them forever.
  @discardableResult
  func writeUnidentifiedSession(sessionID: String, byteCount: Int) throws -> UInt64 {
    let month = defaultRoot
      .appending(path: "2026", directoryHint: .isDirectory)
      .appending(path: "08", directoryHint: .isDirectory)
    let session = month.appending(path: sessionID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: session, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data(repeating: 0x41, count: byteCount).write(
      to: session.appending(path: "staging.img"))
    return UInt64(byteCount)
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: base)
  }
}
