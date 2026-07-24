import ArkDeckCore
import Darwin
import Foundation
import XCTest

@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class SessionSettingsContractTests: XCTestCase {
  func testExactDefaultsTypedPersistenceAndCorruptionFailClosed() throws {
    let fixture = try SettingsFixture(label: "defaults")
    defer { fixture.cleanup() }

    let initial = try fixture.store.load()
    XCTAssertEqual(initial.schemaVersion, "1.0.0")
    XCTAssertEqual(initial.generation, 0)
    XCTAssertEqual(initial.rootSource, .defaultApplicationSupport)
    XCTAssertEqual(initial.sessionsRoot.path, fixture.defaultRoot.standardizedFileURL.path)
    XCTAssertEqual(initial.totalQuotaBytes, 20 * 1_024 * 1_024 * 1_024)
    XCTAssertEqual(initial.safetyMarginBytes, 2 * 1_024 * 1_024 * 1_024)
    XCTAssertEqual(initial.retentionDays, 90)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.defaultRoot.path))

    let saved = try fixture.store.savePolicy(
      totalQuotaBytes: 8_192, safetyMarginBytes: 1_024,
      retentionDays: 30, expectedGeneration: 0)
    XCTAssertEqual(saved.generation, 1)
    XCTAssertEqual(try fixture.store.load(), saved)

    fixture.defaults.set("wrong-type", forKey: SessionSettingsStore.persistenceKey)
    XCTAssertThrowsError(try fixture.store.load()) {
      XCTAssertEqual($0 as? SessionSettingsError, .configurationWrongType)
    }
    let corruptValue =
      fixture.defaults.object(forKey: SessionSettingsStore.persistenceKey) as? String
    XCTAssertThrowsError(
      try fixture.store.savePolicy(
        totalQuotaBytes: 9_000, safetyMarginBytes: 1_000,
        retentionDays: 31, expectedGeneration: 1))
    XCTAssertEqual(
      fixture.defaults.object(forKey: SessionSettingsStore.persistenceKey) as? String,
      corruptValue)

    fixture.defaults.set(
      try canonicalJSON(.object(["schemaVersion": .string("1.0.0")])),
      forKey: SessionSettingsStore.persistenceKey)
    XCTAssertThrowsError(try fixture.store.load()) {
      XCTAssertEqual($0 as? SessionSettingsError, .configurationMissingFields)
    }
  }

  func testGenerationOverflowAndInvalidPolicyDoNotOverwrite() throws {
    let fixture = try SettingsFixture(label: "overflow")
    defer { fixture.cleanup() }
    let envelope = try canonicalJSON(
      .object([
        "schemaVersion": .string("1.0.0"),
        "generation": .unsignedInteger(UInt64.max),
        "rootSource": .string("defaultApplicationSupport"),
        "expectedRootPath": .string(fixture.defaultRoot.standardizedFileURL.path),
        "totalQuotaBytes": .unsignedInteger(4_096),
        "safetyMarginBytes": .unsignedInteger(1_024),
        "retentionDays": .unsignedInteger(90),
      ]))
    fixture.defaults.set(envelope, forKey: SessionSettingsStore.persistenceKey)
    XCTAssertEqual(try fixture.store.load().generation, UInt64.max)
    XCTAssertThrowsError(
      try fixture.store.savePolicy(
        totalQuotaBytes: 4_096, safetyMarginBytes: 1_024,
        retentionDays: 90, expectedGeneration: UInt64.max)
    ) {
      XCTAssertEqual($0 as? SessionSettingsError, .generationOverflow)
    }
    XCTAssertEqual(
      fixture.defaults.data(forKey: SessionSettingsStore.persistenceKey), envelope)

    fixture.defaults.removeObject(forKey: SessionSettingsStore.persistenceKey)
    for (quota, margin, days, expected) in [
      (UInt64(0), UInt64(1), UInt64(1), SessionSettingsError.invalidQuota),
      (UInt64(1), UInt64(1), UInt64(1), SessionSettingsError.invalidQuota),
      (UInt64(2), UInt64(1), UInt64(0), SessionSettingsError.invalidRetentionDays),
    ] {
      XCTAssertThrowsError(
        try fixture.store.savePolicy(
          totalQuotaBytes: quota, safetyMarginBytes: margin,
          retentionDays: days, expectedGeneration: 0)
      ) {
        XCTAssertEqual($0 as? SessionSettingsError, expected)
      }
      XCTAssertNil(fixture.defaults.object(forKey: SessionSettingsStore.persistenceKey))
    }
  }

  func testBookmarkReopenStaleRefreshMismatchScopeDenialAndReset() throws {
    let bookmark = FakeSessionBookmarkAccess()
    let fixture = try SettingsFixture(label: "bookmark", bookmark: bookmark)
    defer { fixture.cleanup() }
    let custom = fixture.base.appending(path: "custom", directoryHint: .isDirectory)
    try makeOwnerOnlyDirectory(custom)
    bookmark.configure(resolvedURL: custom, stale: false, allowsScope: true)

    let selected = try fixture.store.selectCustomRoot(custom, expectedGeneration: 0)
    XCTAssertEqual(selected.generation, 1)
    XCTAssertEqual(selected.rootSource, .userBookmark)
    var access = try fixture.store.acquireRoot(for: selected)
    XCTAssertEqual(access.lease.url.path, custom.standardizedFileURL.path)
    access.lease.end()
    XCTAssertEqual(bookmark.stopCount, 2)

    bookmark.configure(resolvedURL: custom, stale: true, allowsScope: true)
    access = try fixture.store.acquireRoot(for: selected)
    XCTAssertEqual(access.settings.generation, 2)
    XCTAssertEqual(try fixture.store.load().generation, 2)
    access.lease.end()

    let mismatch = fixture.base.appending(path: "mismatch", directoryHint: .isDirectory)
    try makeOwnerOnlyDirectory(mismatch)
    bookmark.configure(resolvedURL: mismatch, stale: false, allowsScope: true)
    XCTAssertThrowsError(
      try fixture.store.acquireRoot(for: fixture.store.load())
    ) {
      XCTAssertEqual($0 as? SessionSettingsError, .requiresReselection)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.defaultRoot.path))

    bookmark.configure(resolvedURL: custom, stale: false, allowsScope: false)
    XCTAssertThrowsError(
      try fixture.store.acquireRoot(for: fixture.store.load())
    ) {
      XCTAssertEqual($0 as? SessionSettingsError, .requiresReselection)
    }

    let reset = try fixture.store.resetRootToDefault(expectedGeneration: 2)
    XCTAssertEqual(reset.generation, 3)
    XCTAssertEqual(reset.rootSource, .defaultApplicationSupport)
    let defaultAccess = try fixture.store.acquireRoot(for: reset)
    XCTAssertEqual(defaultAccess.lease.url.path, fixture.defaultRoot.standardizedFileURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.defaultRoot.path))
  }

  func testCatalogInitializesPinsRegistersNewSessionsAndPreservesMissingMetadata() throws {
    let root = try temporaryRoot("catalog-pins")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try makeFinalizedSession(
      root: root, year: "2026", month: "01", sessionID: "session-first",
      jobID: "job-first", completedAt: "2026-01-01T00:00:00.123456789Z",
      payloadBytes: 64)
    let catalog = try SessionRetentionCatalog(sessionsRoot: root)

    var snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertEqual(snapshot.catalogGeneration, 0)
    XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["session-first"])
    XCTAssertFalse(snapshot.sessions[0].isPinned)
    XCTAssertFalse(snapshot.unknownPressure)
    XCTAssertGreaterThan(snapshot.currentBytes, 64)
    XCTAssertNotNil(snapshot.sessions[0].completedAt)

    XCTAssertEqual(
      try catalog.updatePin(
        sessionID: "session-first", isPinned: true, expectedGeneration: 0),
      1)
    snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertTrue(snapshot.sessions[0].isPinned)

    let second = try makeFinalizedSession(
      root: root, year: "2026", month: "02", sessionID: "session-second",
      jobID: "job-second", completedAt: "2024-02-29T23:59:60.123+23:59",
      payloadBytes: 32)
    snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertTrue(snapshot.unknownPressure)
    XCTAssertTrue(snapshot.unknownSessionIDs.contains("session-second"))
    XCTAssertFalse(snapshot.sessions.contains { $0.sessionID == "session-second" })

    try catalog.registerFinalizedSession(
      sessionRoot: second, retentionDays: 90, policyGeneration: 0)
    snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertEqual(Set(snapshot.sessions.map(\.sessionID)), ["session-first", "session-second"])
    XCTAssertTrue(snapshot.sessions.first { $0.root == first }!.isPinned)

    try FileManager.default.removeItem(
      at: root.appending(path: SessionRetentionCatalog.metadataFileName))
    snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertNil(snapshot.catalogGeneration)
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.unknownPressure)
    XCTAssertEqual(Set(snapshot.unknownSessionIDs), ["session-first", "session-second"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testCatalogRejectsSymlinksDuplicateIdentityFIFOHardlinkAndMeasurementFault() throws {
    let root = try temporaryRoot("catalog-unsafe")
    let outside = try temporaryRoot("catalog-outside")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }

    XCTAssertEqual(
      symlink(outside.path, root.appending(path: "2024").path), 0)
    let year2025 = root.appending(path: "2025", directoryHint: .isDirectory)
    try makeOwnerOnlyDirectory(year2025)
    XCTAssertEqual(
      symlink(outside.path, year2025.appending(path: "01").path), 0)
    let month2026 =
      root
      .appending(path: "2026", directoryHint: .isDirectory)
      .appending(path: "01", directoryHint: .isDirectory)
    try makeOwnerOnlyDirectory(month2026)
    XCTAssertEqual(
      symlink(outside.path, month2026.appending(path: "session-link").path), 0)

    let hardlink = try makeFinalizedSession(
      root: root, year: "2026", month: "02", sessionID: "session-hardlink",
      jobID: "job-hardlink", completedAt: "2026-02-01T00:00:00Z", payloadBytes: 16)
    let externalLink = outside.appending(path: "payload-link")
    XCTAssertEqual(
      Darwin.link(hardlink.appending(path: "payload.bin").path, externalLink.path), 0)

    let fifo = try makeFinalizedSession(
      root: root, year: "2026", month: "03", sessionID: "session-fifo",
      jobID: "job-fifo", completedAt: "2026-03-01T00:00:00Z", payloadBytes: 16)
    XCTAssertEqual(mkfifo(fifo.appending(path: "unsafe.fifo").path, 0o600), 0)
    let socketSession = try makeFinalizedSession(
      root: root, year: "2026", month: "06", sessionID: "session-socket",
      jobID: "job-socket", completedAt: "2026-06-01T00:00:00Z", payloadBytes: 16)
    try makeUnixSocket(at: socketSession.appending(path: "unsafe.socket"))

    _ = try makeFinalizedSession(
      root: root, year: "2026", month: "04", sessionID: "session-duplicate",
      jobID: "job-duplicate-a", completedAt: "2026-04-01T00:00:00Z", payloadBytes: 8)
    let duplicateB = try makeFinalizedSession(
      root: root, year: "2027", month: "04", sessionID: "session-duplicate",
      jobID: "job-duplicate-b", completedAt: "2027-04-01T00:00:00Z", payloadBytes: 8)
    try writeOwnerOnly(
      Data("{}".utf8), to: duplicateB.appending(path: "manifest.json"), replace: true)

    let mismatch = try makeFinalizedSession(
      root: root, year: "2026", month: "05", sessionID: "session-mismatch",
      jobID: "job-mismatch", completedAt: "2026-05-01T00:00:00Z", payloadBytes: 8)
    try writeOwnerOnly(
      try identityData(sessionID: "different-session", jobID: "job-mismatch"),
      to: mismatch.appending(path: ".session-identity.json"), replace: true)

    let snapshot = try SessionRetentionCatalog(sessionsRoot: root)
      .scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.unknownPressure)
    for expected in [
      "2024", "2025/01", "2026/01/session-link", "2026/02/session-hardlink",
      "2026/03/session-fifo", "2026/06/session-socket", "session-duplicate",
      "2026/05/session-mismatch",
    ] {
      XCTAssertTrue(
        snapshot.unknownSessionIDs.contains(expected),
        "missing preserved-unknown marker \(expected)")
    }

    let faultRoot = try temporaryRoot("catalog-measurement-fault")
    defer { try? FileManager.default.removeItem(at: faultRoot) }
    _ = try makeFinalizedSession(
      root: faultRoot, year: "2026", month: "06", sessionID: "session-read-error",
      jobID: "job-read-error", completedAt: "2026-06-01T00:00:00Z", payloadBytes: 8)
    let faultCatalog = try SessionRetentionCatalog(
      sessionsRoot: faultRoot,
      faultInjector: SessionRetentionCatalogFaultInjector { point in
        if point == .beforeMeasurement { throw SessionSettingsTestError.injected }
      })
    let faultSnapshot = try faultCatalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertTrue(faultSnapshot.sessions.isEmpty)
    XCTAssertTrue(faultSnapshot.unknownPressure)
    XCTAssertTrue(faultSnapshot.unknownSessionIDs.contains("2026/06/session-read-error"))
    XCTAssertThrowsError(
      try SessionRetentionCatalog.checkedMeasurementTotal(UInt64.max, adding: 1))
  }

  func testCatalogTimeManifestAndMetadataDriftStayPreservedUnknown() throws {
    let root = try temporaryRoot("catalog-drift")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeFinalizedSession(
      root: root, year: "2026", month: "07", sessionID: "session-time-drift",
      jobID: "job-time-drift", completedAt: "2026-07-01T00:00:00Z", payloadBytes: 8)
    let catalog = try SessionRetentionCatalog(sessionsRoot: root)
    XCTAssertEqual(
      try catalog.scan(retentionDays: 90, policyGeneration: 0).sessions.count, 1)
    XCTAssertEqual(
      try catalog.updatePin(
        sessionID: "session-time-drift", isPinned: true, expectedGeneration: 0),
      1)

    let metadataURL = root.appending(path: SessionRetentionCatalog.metadataFileName)
    var metadata = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: metadataURL))
    guard case .object(var rootObject) = metadata,
      case .array(var entries)? = rootObject["entries"],
      case .object(var entry) = entries[0]
    else { return XCTFail("unexpected catalog metadata fixture") }
    entry["completedAt"] = .string("2000-01-01T00:00:00.000Z")
    entries[0] = .object(entry)
    rootObject["entries"] = .array(entries)
    metadata = .object(rootObject)
    try writeOwnerOnly(try canonicalJSON(metadata), to: metadataURL, replace: true)
    var snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertNotNil(snapshot.catalogGeneration)
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.unknownPressure)
    XCTAssertTrue(snapshot.unknownSessionIDs.contains("session-time-drift"))
    XCTAssertEqual(snapshot.entries.map(\.sessionID), ["session-time-drift"])
    XCTAssertTrue(snapshot.entries[0].isPinned)
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))

    try writeOwnerOnly(Data("{}".utf8), to: metadataURL, replace: true)
    snapshot = try catalog.scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertNil(snapshot.catalogGeneration)
    XCTAssertTrue(snapshot.unknownPressure)
    XCTAssertTrue(snapshot.sessions.isEmpty)

    let manifestRoot = try temporaryRoot("manifest-drift")
    defer { try? FileManager.default.removeItem(at: manifestRoot) }
    let corrupt = try makeFinalizedSession(
      root: manifestRoot, year: "2026", month: "07", sessionID: "session-manifest-drift",
      jobID: "job-manifest-drift", completedAt: "2026-07-01T00:00:00Z", payloadBytes: 8)
    try writeOwnerOnly(
      Data("{}".utf8), to: corrupt.appending(path: "manifest.json"), replace: true)
    let corruptSnapshot = try SessionRetentionCatalog(sessionsRoot: manifestRoot)
      .scan(retentionDays: 90, policyGeneration: 0)
    XCTAssertTrue(corruptSnapshot.sessions.isEmpty)
    XCTAssertTrue(corruptSnapshot.unknownPressure)
    XCTAssertTrue(
      corruptSnapshot.unknownSessionIDs.contains("2026/07/session-manifest-drift"))
  }

  func testRuntimeOrdersCleanupProtectsPinsAppliesOnlyAfterConfirmationAndRescans()
    async throws
  {
    let fixture = try SettingsFixture(label: "runtime-apply")
    defer { fixture.cleanup() }
    try makeOwnerOnlyDirectory(fixture.defaultRoot)
    let configured = try fixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    _ = try makeFinalizedSession(
      root: fixture.defaultRoot, year: "2020", month: "01", sessionID: "session-pinned",
      jobID: "job-pinned", completedAt: "2020-01-01T00:00:00Z", payloadBytes: 64)
    let expired = try makeFinalizedSession(
      root: fixture.defaultRoot, year: "2021", month: "01", sessionID: "session-expired",
      jobID: "job-expired", completedAt: "2021-01-01T00:00:00Z", payloadBytes: 64)
    let newer = try makeFinalizedSession(
      root: fixture.defaultRoot, year: "2022", month: "01", sessionID: "session-newer",
      jobID: "job-newer", completedAt: "2022-01-01T00:00:00Z", payloadBytes: 64)
    let runtime = SessionStorageApplicationRuntime(settingsStore: fixture.store)

    var preview = try await runtime.refresh()
    XCTAssertEqual(preview.settings, configured)
    preview = try await runtime.updatePin(
      sessionID: "session-pinned", isPinned: true,
      expectedCatalogGeneration: try XCTUnwrap(preview.catalogGeneration))
    XCTAssertEqual(preview.deletionSessionIDs, ["session-expired", "session-newer"])
    XCTAssertTrue(preview.blocksNewHeavyWriters)

    let confirmation = try await runtime.confirm(preview)
    let result = try await runtime.apply(confirmation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.defaultRoot
          .appending(path: "2020/01/session-pinned").path))
    XCTAssertTrue(result.previewAfterRescan.blocksNewHeavyWriters)
    let remainsBlocked = await runtime.coordinator.retentionAdmissionIsBlocked(
      on: result.previewAfterRescan.volumeIdentity)
    XCTAssertTrue(remainsBlocked)
  }

  func testCancelAndSettingsDriftCauseZeroDeleteDispatch() async throws {
    let fixture = try SettingsFixture(label: "runtime-stale")
    defer { fixture.cleanup() }
    try makeOwnerOnlyDirectory(fixture.defaultRoot)
    _ = try fixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    let session = try makeFinalizedSession(
      root: fixture.defaultRoot, year: "2020", month: "01", sessionID: "session-stale",
      jobID: "job-stale", completedAt: "2020-01-01T00:00:00Z", payloadBytes: 64)
    let deletes = LockedInteger()
    let runtime = SessionStorageApplicationRuntime(
      settingsStore: fixture.store,
      retentionController: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete { _ = deletes.increment() }
        }))

    var preview = try await runtime.refresh()
    var confirmation = try await runtime.confirm(preview)
    await runtime.cancelCleanup()
    do {
      _ = try await runtime.apply(confirmation)
      XCTFail("cancelled cleanup must not apply")
    } catch {
      XCTAssertEqual(error as? SessionRetentionRuntimeError, .confirmationRequired)
    }
    XCTAssertEqual(deletes.value, 0)

    preview = try await runtime.refresh()
    confirmation = try await runtime.confirm(preview)
    _ = try fixture.store.savePolicy(
      totalQuotaBytes: 1_001, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: preview.settings.generation)
    do {
      _ = try await runtime.apply(confirmation)
      XCTFail("settings drift must invalidate confirmation")
    } catch {
      XCTAssertEqual(error as? SessionRetentionRuntimeError, .stalePreview)
    }
    XCTAssertEqual(deletes.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
    let remainsBlocked = await runtime.coordinator.retentionAdmissionIsBlocked(
      on: confirmation.volumeIdentity)
    XCTAssertTrue(remainsBlocked)
  }

  func testPartialDeleteAndPostApplyRescanFailureRemainBlocked() async throws {
    let partialFixture = try SettingsFixture(label: "runtime-partial")
    defer { partialFixture.cleanup() }
    try makeOwnerOnlyDirectory(partialFixture.defaultRoot)
    _ = try partialFixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    let first = try makeFinalizedSession(
      root: partialFixture.defaultRoot, year: "2020", month: "01",
      sessionID: "session-first-delete", jobID: "job-first-delete",
      completedAt: "2020-01-01T00:00:00Z", payloadBytes: 64)
    let second = try makeFinalizedSession(
      root: partialFixture.defaultRoot, year: "2021", month: "01",
      sessionID: "session-second-delete", jobID: "job-second-delete",
      completedAt: "2021-01-01T00:00:00Z", payloadBytes: 64)
    let deleteCalls = LockedInteger()
    let partialRuntime = SessionStorageApplicationRuntime(
      settingsStore: partialFixture.store,
      retentionController: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete, deleteCalls.increment() == 2 {
            throw SessionSettingsTestError.injected
          }
        }))
    let partialPreview = try await partialRuntime.refresh()
    let partialConfirmation = try await partialRuntime.confirm(partialPreview)
    do {
      _ = try await partialRuntime.apply(partialConfirmation)
      XCTFail("second deletion fault must escape")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    let partialBlocked = await partialRuntime.coordinator.retentionAdmissionIsBlocked(
      on: partialPreview.volumeIdentity)
    XCTAssertTrue(partialBlocked)
    await partialRuntime.coordinator.setRetentionAdmission(
      blocked: false, on: partialPreview.volumeIdentity)
    let partialStillBlocked = await partialRuntime.coordinator.retentionAdmissionIsBlocked(
      on: partialPreview.volumeIdentity)
    XCTAssertTrue(partialStillBlocked)

    let rescanFixture = try SettingsFixture(label: "runtime-rescan")
    defer { rescanFixture.cleanup() }
    try makeOwnerOnlyDirectory(rescanFixture.defaultRoot)
    _ = try rescanFixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    let rescanSession = try makeFinalizedSession(
      root: rescanFixture.defaultRoot, year: "2020", month: "01",
      sessionID: "session-rescan", jobID: "job-rescan",
      completedAt: "2020-01-01T00:00:00Z", payloadBytes: 64)
    let scanCalls = LockedInteger()
    let rescanRuntime = SessionStorageApplicationRuntime(
      settingsStore: rescanFixture.store,
      catalogFaultInjector: SessionRetentionCatalogFaultInjector { point in
        if point == .beforeScan, scanCalls.increment() == 4 {
          throw SessionSettingsTestError.injected
        }
      })
    let rescanPreview = try await rescanRuntime.refresh()
    let rescanConfirmation = try await rescanRuntime.confirm(rescanPreview)
    do {
      _ = try await rescanRuntime.apply(rescanConfirmation)
      XCTFail("post-apply rescan failure must escape")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: rescanSession.path))
    let rescanBlocked = await rescanRuntime.coordinator.retentionAdmissionIsBlocked(
      on: rescanPreview.volumeIdentity)
    XCTAssertTrue(rescanBlocked)
    await rescanRuntime.coordinator.setRetentionAdmission(
      blocked: false, on: rescanPreview.volumeIdentity)
    let rescanStillBlocked = await rescanRuntime.coordinator.retentionAdmissionIsBlocked(
      on: rescanPreview.volumeIdentity)
    XCTAssertTrue(rescanStillBlocked)
  }

  func testCatalogRootAndVolumeDriftCauseZeroDeleteDispatch() async throws {
    let catalogFixture = try SettingsFixture(label: "catalog-generation-drift")
    defer { catalogFixture.cleanup() }
    try makeOwnerOnlyDirectory(catalogFixture.defaultRoot)
    _ = try catalogFixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    let catalogSession = try makeFinalizedSession(
      root: catalogFixture.defaultRoot, year: "2020", month: "01",
      sessionID: "session-catalog-drift", jobID: "job-catalog-drift",
      completedAt: "2020-01-01T00:00:00Z", payloadBytes: 32)
    let catalogDeletes = LockedInteger()
    let catalogRuntime = SessionStorageApplicationRuntime(
      settingsStore: catalogFixture.store,
      retentionController: countingController(catalogDeletes))
    let catalogPreview = try await catalogRuntime.refresh()
    let catalogConfirmation = try await catalogRuntime.confirm(catalogPreview)
    let externalCatalog = try SessionRetentionCatalog(
      sessionsRoot: catalogFixture.defaultRoot)
    _ = try externalCatalog.updatePin(
      sessionID: "session-catalog-drift", isPinned: true,
      expectedGeneration: try XCTUnwrap(catalogPreview.catalogGeneration))
    do {
      _ = try await catalogRuntime.apply(catalogConfirmation)
      XCTFail("catalog generation drift must invalidate confirmation")
    } catch {
      XCTAssertEqual(error as? SessionRetentionRuntimeError, .stalePreview)
    }
    XCTAssertEqual(catalogDeletes.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: catalogSession.path))

    let rootFixture = try SettingsFixture(label: "root-identity-drift")
    defer { rootFixture.cleanup() }
    try makeOwnerOnlyDirectory(rootFixture.defaultRoot)
    _ = try rootFixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    _ = try makeFinalizedSession(
      root: rootFixture.defaultRoot, year: "2020", month: "01",
      sessionID: "session-root-drift", jobID: "job-root-drift",
      completedAt: "2020-01-01T00:00:00Z", payloadBytes: 32)
    let rootDeletes = LockedInteger()
    let rootRuntime = SessionStorageApplicationRuntime(
      settingsStore: rootFixture.store,
      retentionController: countingController(rootDeletes))
    let rootPreview = try await rootRuntime.refresh()
    let rootConfirmation = try await rootRuntime.confirm(rootPreview)
    let preservedRoot = rootFixture.base.appending(
      path: "preserved-old-root", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: rootFixture.defaultRoot, to: preservedRoot)
    try makeOwnerOnlyDirectory(rootFixture.defaultRoot)
    do {
      _ = try await rootRuntime.apply(rootConfirmation)
      XCTFail("root identity drift must invalidate confirmation")
    } catch {
      XCTAssertEqual(error as? SessionRetentionRuntimeError, .stalePreview)
    }
    XCTAssertEqual(rootDeletes.value, 0)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: preservedRoot.appending(path: "2020/01/session-root-drift").path))

    let volumeFixture = try SettingsFixture(label: "volume-identity-drift")
    defer { volumeFixture.cleanup() }
    try makeOwnerOnlyDirectory(volumeFixture.defaultRoot)
    _ = try volumeFixture.store.savePolicy(
      totalQuotaBytes: 1_000, safetyMarginBytes: 100,
      retentionDays: 1, expectedGeneration: 0)
    let volumeSession = try makeFinalizedSession(
      root: volumeFixture.defaultRoot, year: "2020", month: "01",
      sessionID: "session-volume-drift", jobID: "job-volume-drift",
      completedAt: "2020-01-01T00:00:00Z", payloadBytes: 32)
    let volumeA = try VolumeIdentity(value: "fixture-volume-a")
    let volumeB = try VolumeIdentity(value: "fixture-volume-b")
    let volumeDeletes = LockedInteger()
    let volumeRuntime = SessionStorageApplicationRuntime(
      settingsStore: volumeFixture.store,
      volumeIdentityResolver: SequencedVolumeResolver([volumeA, volumeA, volumeB]),
      retentionController: countingController(volumeDeletes))
    let volumePreview = try await volumeRuntime.refresh()
    let volumeConfirmation = try await volumeRuntime.confirm(volumePreview)
    do {
      _ = try await volumeRuntime.apply(volumeConfirmation)
      XCTFail("volume identity drift must invalidate confirmation")
    } catch {
      XCTAssertEqual(error as? SessionRetentionRuntimeError, .stalePreview)
    }
    XCTAssertEqual(volumeDeletes.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: volumeSession.path))
  }

  func testProductionStorageCompositionUsesValidatedRootAndSharedCoordinator() async throws {
    let fixture = try SettingsFixture(label: "composition")
    defer { fixture.cleanup() }
    let runtime = SessionStorageApplicationRuntime(settingsStore: fixture.store)
    let first = try RockchipProductionStorageComposition.make(runtime: runtime)
    let second = try RockchipProductionStorageComposition.make(runtime: runtime)
    XCTAssertEqual(
      first.context.sessionStore.sessionsRoot.path,
      fixture.defaultRoot.standardizedFileURL.path)
    XCTAssertTrue(first.context.coordinator === runtime.coordinator)
    XCTAssertTrue(second.context.coordinator === runtime.coordinator)

    let catalog = try await first.context.prepareHeavyWriterAdmission()
    await runtime.coordinator.setRetentionAdmission(
      blocked: true, on: catalog.volumeIdentity)
    let blockedRequest = try StorageClaimRequest(
      claimID: "claim-blocked", jobID: "job-blocked",
      volumeIdentity: catalog.volumeIdentity,
      budget: StorageBudget(
        metadataHeadroomBytes: 1, finalizationHeadroomBytes: 1,
        remainingGrowthBytes: 1, writerClass: .heavy))
    let snapshot = HostStorageSnapshot(
      volumeIdentity: catalog.volumeIdentity,
      totalBytes: 10_000, availableBytes: 10_000, isReadOnly: false)
    let blockedAdmission = await runtime.coordinator.admit(
      blockedRequest, snapshot: snapshot)
    XCTAssertEqual(
      blockedAdmission, .queued(.insufficientHeadroom))

    await runtime.coordinator.setRetentionAdmission(
      blocked: false, on: catalog.volumeIdentity)
    let request = try StorageClaimRequest(
      claimID: "claim-real-store", jobID: "job-real-store",
      volumeIdentity: catalog.volumeIdentity,
      budget: StorageBudget(
        metadataHeadroomBytes: 1, finalizationHeadroomBytes: 1,
        remainingGrowthBytes: 1, writerClass: .heavy))
    guard
      case .admitted(let claim) = await runtime.coordinator.admit(
        request, snapshot: snapshot)
    else { return XCTFail("shared coordinator should admit the first heavy writer") }
    let layout = try first.context.sessionStore.createSession(
      sessionID: "session-real-store", jobID: "job-real-store",
      createdAt: Date(timeIntervalSince1970: 1_704_067_200), claim: claim)
    XCTAssertTrue(layout.root.path.hasPrefix(fixture.defaultRoot.path + "/"))

    _ = try fixture.store.savePolicy(
      totalQuotaBytes: 8_192, safetyMarginBytes: 1_024,
      retentionDays: 30, expectedGeneration: first.context.settings.generation)
    XCTAssertThrowsError(try first.context.requireCurrentSettings()) {
      guard case SessionSettingsError.staleGeneration = $0 else {
        return XCTFail("expected settings-generation drift, got \($0)")
      }
    }
  }
}

private enum SessionSettingsTestError: Error {
  case injected
}

private final class SettingsFixture {
  let base: URL
  let defaultRoot: URL
  let suiteName: String
  let defaults: UserDefaults
  let store: SessionSettingsStore

  init(
    label: String,
    bookmark: any SessionBookmarkAccessing = FakeSessionBookmarkAccess()
  ) throws {
    base = try temporaryRoot("settings-\(label)")
    defaultRoot = base.appending(path: "default-sessions", directoryHint: .isDirectory)
    suiteName = "dev.arkdeck.tests.session-settings.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    store = SessionSettingsStore(
      defaults: defaults,
      defaultRootProvider: { [defaultRoot] in defaultRoot },
      bookmarkAccess: bookmark)
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: base)
  }
}

private final class FakeSessionBookmarkAccess: SessionBookmarkAccessing, @unchecked Sendable {
  private let lock = NSLock()
  private var resolvedURL: URL?
  private var stale = false
  private var allowsScope = true
  private var bookmarkGeneration = 0
  private var stops = 0

  var stopCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return stops
  }

  func configure(resolvedURL: URL, stale: Bool, allowsScope: Bool) {
    lock.lock()
    self.resolvedURL = resolvedURL
    self.stale = stale
    self.allowsScope = allowsScope
    lock.unlock()
  }

  func makeReadWriteBookmark(for url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    bookmarkGeneration += 1
    if resolvedURL == nil { resolvedURL = url }
    return Data("bookmark-\(bookmarkGeneration)".utf8)
  }

  func resolveReadWriteBookmark(_: Data) throws -> SessionBookmarkResolution {
    lock.lock()
    defer { lock.unlock() }
    guard let resolvedURL else { throw SessionSettingsTestError.injected }
    return SessionBookmarkResolution(url: resolvedURL, isStale: stale)
  }

  func startAccessing(_: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return allowsScope
  }

  func stopAccessing(_: URL) {
    lock.lock()
    stops += 1
    lock.unlock()
  }
}

private final class LockedInteger: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func increment() -> Int {
    lock.lock()
    stored += 1
    let result = stored
    lock.unlock()
    return result
  }
}

private final class SequencedVolumeResolver: VolumeIdentityResolving, @unchecked Sendable {
  private let lock = NSLock()
  private var identities: [VolumeIdentity]

  init(_ identities: [VolumeIdentity]) {
    self.identities = identities
  }

  func resolve(_: URL) throws -> VolumeIdentity {
    try next()
  }

  func resolve(openFileDescriptor _: Int32) throws -> VolumeIdentity {
    try next()
  }

  private func next() throws -> VolumeIdentity {
    lock.lock()
    defer { lock.unlock() }
    guard let first = identities.first else { throw SessionSettingsTestError.injected }
    if identities.count > 1 { identities.removeFirst() }
    return first
  }
}

private func countingController(_ counter: LockedInteger) -> SessionRetentionController {
  SessionRetentionController(
    faultInjector: SessionStorageFaultInjector { point in
      if point == .retentionBeforeDelete { _ = counter.increment() }
    })
}

private func temporaryRoot(_ label: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "arkdeck-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
  try makeOwnerOnlyDirectory(root)
  return root
}

private func makeOwnerOnlyDirectory(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  guard chmod(url.path, 0o700) == 0 else {
    throw SessionSettingsTestError.injected
  }
}

@discardableResult
private func makeFinalizedSession(
  root: URL,
  year: String,
  month: String,
  sessionID: String,
  jobID: String,
  completedAt: String,
  payloadBytes: Int
) throws -> URL {
  let session =
    root
    .appending(path: year, directoryHint: .isDirectory)
    .appending(path: month, directoryHint: .isDirectory)
    .appending(path: sessionID, directoryHint: .isDirectory)
  try makeOwnerOnlyDirectory(session)
  try writeOwnerOnly(
    try identityData(sessionID: sessionID, jobID: jobID),
    to: session.appending(path: ".session-identity.json"))
  try writeOwnerOnly(
    try SessionStorageFixtures.manifest(
      sessionID: sessionID, jobID: jobID, timestamp: completedAt),
    to: session.appending(path: "manifest.json"))
  try writeOwnerOnly(
    Data(repeating: 0x5A, count: payloadBytes),
    to: session.appending(path: "payload.bin"))
  return session
}

private func identityData(sessionID: String, jobID: String) throws -> Data {
  try canonicalJSON(
    .object([
      "schemaVersion": .string("1.0.0"),
      "sessionId": .string(sessionID),
      "jobId": .string(jobID),
    ]))
}

private func canonicalJSON(_ value: JSONValue) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

private func writeOwnerOnly(
  _ data: Data,
  to url: URL,
  replace: Bool = false
) throws {
  if replace { try? FileManager.default.removeItem(at: url) }
  let descriptor = Darwin.open(
    url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
  guard descriptor >= 0 else { throw SessionSettingsTestError.injected }
  defer { Darwin.close(descriptor) }
  try data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw SessionSettingsTestError.injected }
      offset += count
    }
  }
  guard fsync(descriptor) == 0 else { throw SessionSettingsTestError.injected }
}

private func makeUnixSocket(at url: URL) throws {
  let boundURL = FileManager.default.temporaryDirectory
    .appending(path: "ark-sock-\(UUID().uuidString.prefix(8))")
  defer { _ = Darwin.unlink(boundURL.path) }
  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw SessionSettingsTestError.injected }
  defer { Darwin.close(descriptor) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(boundURL.path.utf8) + [UInt8(0)]
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard pathBytes.count <= capacity else { throw SessionSettingsTestError.injected }
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    buffer.copyBytes(from: pathBytes)
  }
  let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(descriptor, $0, length)
    }
  }
  guard result == 0 else { throw SessionSettingsTestError.injected }
  guard Darwin.rename(boundURL.path, url.path) == 0 else {
    throw SessionSettingsTestError.injected
  }
}
