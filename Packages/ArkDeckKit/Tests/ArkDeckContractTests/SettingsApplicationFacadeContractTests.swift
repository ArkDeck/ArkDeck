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
/// name, and neither is defaulted to zero when it is simply not known. Both
/// domains come from one `runtime.storage.status` reply, so the seam here is
/// the Runtime-owned storage owner and never this process's own preferences.
final class SettingsStorageDomainContractTests: XCTestCase {
  func testRuntimeArtifactsAndSessionRootAreReportedAsDistinctDomains() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-storage-domain-distinct-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = SettingsApplicationFacade.make(
      arguments: ["--ui-test-runtime-history"], fixtureRoot: root)

    // The owner composes itself on its first request, clearing its own root as
    // it does. Anything written before that would be swept away with it.
    let initial = try await provider.refresh().storage
    let strandedBytes = try writeUnidentifiedSession(
      under: URL(filePath: initial.rootPath, directoryHint: .isDirectory),
      sessionID: "session-stranded", byteCount: 8_192)
    let storage = try await provider.refresh().storage

    let artifacts = try XCTUnwrap(storage.runtimeArtifacts)
    XCTAssertEqual(artifacts.usedBytes, SettingsStorageUIFixture.artifactUsedBytes)
    XCTAssertEqual(artifacts.totalBytes, SettingsStorageUIFixture.artifactTotalBytes)
    XCTAssertEqual(artifacts.remainingBytes, artifacts.totalBytes - artifacts.usedBytes)

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
    let published = SettingsStorageUIFixture.publishedPolicy
    XCTAssertEqual(storage.totalQuotaBytes, published.totalQuotaBytes)
    XCTAssertNotEqual(storage.totalQuotaBytes, artifacts.totalBytes)
    XCTAssertEqual(storage.rootPath, initial.rootPath)
  }

  /// A Runtime that did not answer is not a Runtime storing nothing. The old
  /// screen could not tell those apart because it never asked the Runtime; the
  /// current facade has no second source to fall back to, so an unavailable
  /// owner produces no presentation at all rather than a plausible zero.
  func testAnUnavailableOwnerProducesNoPresentationAndAnEmptyRootReportsZero()
    async throws
  {
    let unavailableRoot = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-storage-domain-absent-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: unavailableRoot) }
    let unavailable = SettingsApplicationFacade.make(
      arguments: [
        "--ui-test-runtime-history", SettingsStorageUIFixture.unreachableArgument,
      ],
      fixtureRoot: unavailableRoot)
    do {
      _ = try await unavailable.refresh()
      XCTFail("an owner that did not answer must not produce a storage figure")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
    }

    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-storage-domain-empty-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = SettingsApplicationFacade.make(
      arguments: ["--ui-test-runtime-history"], fixtureRoot: root)
    let storage = try await provider.refresh().storage

    // The empty Session root still reports honestly — as the Session root.
    let sessionRoot = try XCTUnwrap(storage.sessionRoot)
    XCTAssertEqual(sessionRoot.measuredBytes, 0)
    XCTAssertEqual(sessionRoot.unaccountedSessionCount, 0)
    XCTAssertFalse(sessionRoot.measurementIncomplete)
    // ...and it is still not the artifact domain's figure.
    XCTAssertNotEqual(
      sessionRoot.measuredBytes, try XCTUnwrap(storage.runtimeArtifacts).usedBytes)
  }

  /// A Session directory with no identity or manifest — the exact shape left
  /// behind by the retired in-process host. The catalog cannot account for it,
  /// so it counts the bytes and keeps them forever.
  private func writeUnidentifiedSession(
    under sessionsRoot: URL, sessionID: String, byteCount: Int
  ) throws -> UInt64 {
    let session = sessionsRoot
      .appending(path: "2026", directoryHint: .isDirectory)
      .appending(path: "08", directoryHint: .isDirectory)
      .appending(path: sessionID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: session, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data(repeating: 0x41, count: byteCount).write(
      to: session.appending(path: "staging.img"))
    return UInt64(byteCount)
  }

  /// A mutation whose generation lost the race must be reconciled by reading
  /// the owner — never re-sent. The reconciliation used to live inside the
  /// one-time preference migration; it belongs to the three current mutation
  /// paths, which are the only writers left.
  func testAStorageMutationThatLosesItsGenerationPublishesTheWinnersState()
    async throws
  {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-storage-domain-conflict-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }
    let owner = SettingsStorageUIFixture.Owner(base: base)
    // A second writer publishes between this provider's status read and its
    // mutation, which is exactly how a generation goes stale in production.
    let raced = LockedFlag()
    let provider = SettingsApplicationFacade.make { method, params -> Data? in
      if method == "runtime.storage.policy", raced.takeOnce() {
        _ = await owner.reply(
          "runtime.storage.policy",
          [
            "expectedGeneration": params?["expectedGeneration"] ?? .string("2"),
            "totalQuotaBytes": .string("9663676416"),
            "safetyMarginBytes": .string("1073741824"),
            "retentionDays": .string("30"),
          ])
      }
      return await owner.reply(method, params)
    }

    let reconciled = try await provider.updateStoragePolicy(
      totalQuotaBytes: 7 * 1_024 * 1_024 * 1_024,
      safetyMarginBytes: 1_024 * 1_024 * 1_024,
      retentionDays: 21
    ).storage

    // The loser publishes what actually won and never re-sends its own write.
    XCTAssertEqual(reconciled.totalQuotaBytes, 9_663_676_416)
    XCTAssertEqual(reconciled.retentionDays, 30)
    let settled = try await provider.refresh().storage
    XCTAssertEqual(reconciled, settled)
  }

  /// A reply the reader cannot account for is refused, not rendered. Both
  /// failure surfaces exist so the pane can say "no answer" instead of
  /// showing a number that describes nothing.
  func testAnUnusableReplyIsRefusedRatherThanRendered() async throws {
    let unavailable = SettingsApplicationFacade.make { _, _ in nil }
    do {
      _ = try await unavailable.refresh()
      XCTFail("a transport that did not answer must not produce a presentation")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
    }

    // A well-formed envelope whose result is missing the artifact domain: the
    // exact shape a partially-updated daemon would send.
    let partial = SettingsApplicationFacade.make { _, _ in
      Data(
        """
        {"id":"x","ok":true,"result":{"schemaVersion":"arkdeck.runtime-storage/1"}}
        """.utf8)
    }
    do {
      _ = try await partial.refresh()
      XCTFail("a reply missing a storage domain must not be rendered as zero")
    } catch SettingsApplicationError.runtimeStorageResponseInvalid {
    }

    let refused = SettingsApplicationFacade.make { _, _ in
      Data(
        """
        {"id":"x","ok":false,"error":{"code":"recordUnreadable","message":"m"}}
        """.utf8)
    }
    do {
      _ = try await refused.refresh()
      XCTFail("a refusal must not produce a presentation")
    } catch SettingsApplicationError.runtimeStorageRejected(let code) {
      XCTAssertEqual(code, "recordUnreadable")
    }
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

/// One-shot flag for a racing writer, shared across the transport closure.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false

  func takeOnce() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}
