import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class RuntimeArtifactContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-artifact-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func makeStore(
    quota: ArtifactQuota = ArtifactQuota(),
    home: String = "/Users/tester"
  ) throws -> RuntimeArtifactStore {
    try RuntimeArtifactStore(
      rootURL: root, quota: quota,
      redaction: ArtifactRedactionPolicy(homeDirectory: home),
      nowUTC: { "2026-07-29T00:00:00Z" })
  }

  private func request(
    jobID: String = "job-1",
    name: String = "device-facts.json",
    contents: String = "{\"serial\":\"abc\"}",
    privacy: CatalogArtifactPrivacy = .standard,
    retentionClass: CatalogArtifactRetentionClass = .default
  ) -> RuntimeArtifactPublicationRequest {
    RuntimeArtifactPublicationRequest(
      jobID: jobID, sessionID: "session-\(jobID)", stepID: "probe-device", name: name,
      mediaType: "application/json", privacy: privacy, retentionClass: retentionClass,
      sourceOperation: "observe.device@1", providerID: "hdc",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
      contents: Data(contents.utf8))
  }

  // MARK: - Metadata completeness

  func testPublishedArtifactCarriesCompleteMetadata() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(request())
    XCTAssertTrue(metadata.artifactID.hasPrefix("ART-"))
    XCTAssertEqual(metadata.jobID, "job-1")
    XCTAssertEqual(metadata.stepID, "probe-device")
    XCTAssertEqual(metadata.name, "device-facts.json")
    XCTAssertEqual(metadata.mediaType, "application/json")
    XCTAssertEqual(metadata.sourceOperation, "observe.device@1")
    XCTAssertEqual(metadata.providerID, "hdc")
    XCTAssertEqual(metadata.bindingSnapshot.targetID, "TGT-1")
    XCTAssertEqual(metadata.bindingSnapshot.bindingRevision, 1)
    XCTAssertEqual(metadata.privacy, .standard)
    XCTAssertEqual(metadata.status, .published)
    XCTAssertGreaterThan(metadata.byteCount, 0)
    XCTAssertEqual(metadata.sha256.count, 64)
    XCTAssertFalse(metadata.createdAtUTC.isEmpty)
  }

  func testArtifactIDIsContentDerivedAndRepublishIsIdempotent() async throws {
    let store = try makeStore()
    let first = try await store.publish(request())
    let same = try await store.publish(request())
    XCTAssertEqual(first.artifactID, same.artifactID, "same content, same identity")
    let different = try await store.publish(request(contents: "{\"serial\":\"other\"}"))
    XCTAssertNotEqual(first.artifactID, different.artifactID)
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed.count, 2, "the idempotent republish adds no duplicate row")
  }

  // MARK: - Access is by ID only

  func testReadAndInspectGoThroughIDs() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(request())
    let inspected = try await store.inspect(jobID: "job-1", artifactID: metadata.artifactID)
    XCTAssertEqual(inspected, metadata)
    let data = try await store.read(jobID: "job-1", artifactID: metadata.artifactID)
    XCTAssertEqual(String(data: data, encoding: .utf8), "{\"serial\":\"abc\"}")
    // Bounded read.
    let clipped = try await store.read(
      jobID: "job-1", artifactID: metadata.artifactID, maximumBytes: 4)
    XCTAssertEqual(clipped.count, 4)
    await XCTAssertThrowsErrorAsync(
      try await store.inspect(jobID: "job-1", artifactID: "ART-nope"))
  }

  func testHostileNamesCannotEscapeStorage() async throws {
    let store = try makeStore()
    // The on-disk name is the derived ID, so even a hostile declared name
    // cannot place bytes outside the job directory.
    let hostile = try await store.publish(request(name: "../../etc/passwd"))
    let jobDirectory = root.appendingPathComponent("job-1", isDirectory: true)
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
    XCTAssertTrue(
      onDisk.contains(hostile.artifactID),
      "bytes live under the derived ID: \(onDisk)")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("etc").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/passwd"))
    // A malformed job identifier is rejected outright.
    await XCTAssertThrowsErrorAsync(
      try await store.publish(request(jobID: "../escape")))
  }

  func testExportRefusesOverwriteAndSanitizesName() async throws {
    let store = try makeStore()
    let hostile = try await store.publish(request(name: "../evil.json"))
    let destination = root.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let exported = try await store.export(
      jobID: "job-1", artifactID: hostile.artifactID, destinationDirectory: destination)
    XCTAssertEqual(exported.deletingLastPathComponent().path, destination.path)
    XCTAssertFalse(exported.lastPathComponent.contains(".."))
    // Second export refuses rather than clobbering.
    await XCTAssertThrowsErrorAsync(
      try await store.export(
        jobID: "job-1", artifactID: hostile.artifactID, destinationDirectory: destination))
    // A non-directory destination is rejected.
    await XCTAssertThrowsErrorAsync(
      try await store.export(
        jobID: "job-1", artifactID: hostile.artifactID, destinationDirectory: exported))
  }

  // MARK: - Privacy

  func testSensitiveArtifactsNeedExplicitOptIn() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(request(privacy: .sensitive))
    await XCTAssertThrowsErrorAsync(
      try await store.read(jobID: "job-1", artifactID: metadata.artifactID))
    let data = try await store.read(
      jobID: "job-1", artifactID: metadata.artifactID, allowSensitive: true)
    XCTAssertFalse(data.isEmpty)
  }

  func testDefaultRedactionRemovesSecretsAndHostPaths() async throws {
    let store = try makeStore(home: "/Users/tester")
    let metadata = try await store.publish(
      request(
        jobID: "job-redact",
        contents: "{\"token\":\"ghs_abcdef123456\",\"path\":\"/Users/tester/secret\"}"))
    XCTAssertTrue(metadata.redactionApplied, "redaction must be recorded, not silent")
    let text = String(
      data: try await store.read(jobID: "job-redact", artifactID: metadata.artifactID),
      encoding: .utf8) ?? ""
    XCTAssertFalse(text.contains("ghs_abcdef123456"), text)
    XCTAssertFalse(text.contains("/Users/tester"), text)
    XCTAssertTrue(text.contains("<HOME>"))
    XCTAssertTrue(text.contains("<REDACTED>"))
    // The stored hash covers the redacted bytes actually on disk.
    XCTAssertEqual(metadata.byteCount, text.utf8.count)
  }

  // MARK: - Missing products stay visible

  func testMissingArtifactIsRecordedWithItsReason() async throws {
    let store = try makeStore()
    _ = try await store.publish(request(name: "hilog.txt"))
    let missing = try await store.recordMissing(
      jobID: "job-1", sessionID: "session-job-1", stepID: "capture-trace",
      name: "trace.htrace", mediaType: "application/octet-stream", privacy: .sensitive,
      retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
      reason: "trace category unsupported on this build")
    XCTAssertEqual(missing.status, .missing(reason: "trace category unsupported on this build"))
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed.count, 2)
    XCTAssertEqual(listed.filter { $0.status.isPublished }.count, 1)
    // Reading a missing product fails rather than returning empty bytes,
    // so a caller can never mistake absence for an empty capture.
    await XCTAssertThrowsErrorAsync(
      try await store.read(jobID: "job-1", artifactID: missing.artifactID))
  }

  // MARK: - Quota and GC

  func testQuotaRefusesNewWorkWithoutDamagingExistingArtifacts() async throws {
    let store = try makeStore(quota: ArtifactQuota(totalBytes: 64))
    let first = try await store.publish(request(contents: String(repeating: "a", count: 40)))
    do {
      _ = try await store.publish(request(contents: String(repeating: "b", count: 40)))
      XCTFail("exceeding the quota must be refused")
    } catch let error as RuntimeArtifactError {
      guard case .quotaExceeded = error else { return XCTFail("unexpected \(error)") }
    }
    // The existing artifact is untouched: refuse new, never evict old.
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed.map(\.artifactID), [first.artifactID])
    let firstBytes = try await store.read(jobID: "job-1", artifactID: first.artifactID)
    XCTAssertFalse(firstBytes.isEmpty)
  }

  func testGarbageCollectionSparesActiveAndPinnedArtifacts() async throws {
    let store = try makeStore()
    _ = try await store.publish(request(jobID: "job-active"))
    let pinned = try await store.publish(
      request(jobID: "job-old", name: "backup-receipt.json", retentionClass: .pinnedUntilVerified))
    XCTAssertTrue(pinned.retention.pinned)
    let removed = try await store.collectGarbage(
      activeJobIDs: ["job-active"], nowUTC: "2027-01-01T00:00:00Z")
    XCTAssertTrue(removed.isEmpty, "nothing has a lapsed deadline yet: \(removed)")
    let activeList = try await store.list(jobID: "job-active")
    let oldList = try await store.list(jobID: "job-old")
    XCTAssertEqual(activeList.count, 1)
    XCTAssertEqual(oldList.count, 1)
  }

  // MARK: - Cleanup debt

  func testCleanupDebtIsRecordedAndSettleable() async throws {
    let store = try makeStore()
    try await store.recordCleanupDebt(
      jobID: "job-1", stepID: "cleanup-remote-temp",
      remotePath: "/data/local/tmp/arkdeck/job-1/trace-abc", reason: "device disconnected")
    let outstanding = try await store.outstandingCleanupDebt()
    XCTAssertEqual(outstanding.count, 1)
    XCTAssertEqual(outstanding[0].remotePath, "/data/local/tmp/arkdeck/job-1/trace-abc")
    try await store.settleCleanupDebt(
      jobID: "job-1", remotePath: "/data/local/tmp/arkdeck/job-1/trace-abc")
    let settled = try await store.outstandingCleanupDebt()
    XCTAssertTrue(settled.isEmpty)
  }

  func testIndexSurvivesReopen() async throws {
    let published: RuntimeArtifactMetadata
    do {
      let store = try makeStore()
      published = try await store.publish(request())
    }
    let reopened = try makeStore()
    let reopenedList = try await reopened.list(jobID: "job-1")
    XCTAssertEqual(reopenedList, [published])
  }
}

func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected an error", file: file, line: line)
  } catch {
    // expected
  }
}
