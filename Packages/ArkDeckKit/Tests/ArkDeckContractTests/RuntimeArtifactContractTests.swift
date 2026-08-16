import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class RuntimeArtifactContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-artifact-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
    XCTAssertNotNil(metadata.retention.deadlineUTC)
    XCTAssertFalse(metadata.retention.pinned)
    XCTAssertGreaterThan(metadata.byteCount, 0)
    XCTAssertEqual(metadata.sha256.count, 64)
    XCTAssertFalse(metadata.createdAtUTC.isEmpty)
  }

  func testArtifactIDBindsDeclaredProductAndRepublishIsIdempotent() async throws {
    let store = try makeStore()
    let first = try await store.publish(request())
    let same = try await store.publish(request())
    XCTAssertEqual(first.artifactID, same.artifactID, "same content, same identity")
    let different = try await store.publish(
      request(name: "binding-snapshot.json", contents: "{\"serial\":\"other\"}"))
    XCTAssertNotEqual(first.artifactID, different.artifactID)
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed.count, 2, "the idempotent republish adds no duplicate row")
  }

  func testEqualBytesForDifferentDeclaredProductsKeepDistinctIdentities() async throws {
    let store = try makeStore()
    let first = try await store.publish(
      request(name: "device-facts.json", contents: "{}"))
    let second = try await store.publish(
      request(name: "binding-snapshot.json", contents: "{}"))
    XCTAssertNotEqual(
      first.artifactID, second.artifactID,
      "content deduplication must not overwrite a different declared product")
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed.count, 2)
  }

  func testPublishedNameCannotBeOverwrittenWithDifferentBytes() async throws {
    let store = try makeStore()
    let original = try await store.publish(
      request(name: "device-facts.json", contents: "{\"serial\":\"first\"}"))
    await XCTAssertThrowsErrorAsync(
      try await store.publish(
        request(name: "device-facts.json", contents: "{\"serial\":\"second\"}")))
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed, [original])
    let originalBytes = try await store.read(
      jobID: "job-1", artifactID: original.artifactID)
    XCTAssertEqual(originalBytes, Data("{\"serial\":\"first\"}".utf8))
  }

  func testIdempotentRepublishCannotDowngradeImmutableMetadata() async throws {
    let store = try makeStore()
    let original = try await store.publish(request(privacy: .sensitive))
    await XCTAssertThrowsErrorAsync(
      try await store.publish(request(privacy: .standard)))
    let listed = try await store.list(jobID: "job-1")
    XCTAssertEqual(listed, [original])
    await XCTAssertThrowsErrorAsync(
      try await store.read(jobID: "job-1", artifactID: original.artifactID))
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
    let secondChunk = try await store.read(
      jobID: "job-1", artifactID: metadata.artifactID,
      offset: 4, maximumBytes: 5)
    XCTAssertEqual(secondChunk, Data("rial\"".utf8))
    await XCTAssertThrowsErrorAsync(
      try await store.read(
        jobID: "job-1", artifactID: metadata.artifactID,
        offset: metadata.byteCount + 1, maximumBytes: 1))
    await XCTAssertThrowsErrorAsync(
      try await store.read(
        jobID: "job-1", artifactID: metadata.artifactID,
        maximumBytes: 4 * 1024 * 1024 + 1))
    await XCTAssertThrowsErrorAsync(
      try await store.inspect(jobID: "job-1", artifactID: "ART-nope"))
  }

  func testHostileNamesCannotEscapeStorage() async throws {
    let store = try makeStore()
    // The on-disk name is the derived ID, so even a hostile declared name
    // cannot place bytes outside the job directory.
    let hostile = try await store.publish(request(name: "../../etc/passwd"))
    let jobDirectory = root.appending(path: "job-1", directoryHint: .isDirectory)
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
    XCTAssertTrue(
      onDisk.contains(hostile.artifactID),
      "bytes live under the derived ID: \(onDisk)")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appending(path: "etc").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/passwd"))
    // A malformed job identifier is rejected outright.
    await XCTAssertThrowsErrorAsync(
      try await store.publish(request(jobID: "../escape")))
  }

  func testSymlinkedJobDirectoryIsRejected() async throws {
    let store = try makeStore()
    let outside = root.deletingLastPathComponent()
      .appending(path: "arkdeck-artifact-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "job-symlink"), withDestinationURL: outside)

    await XCTAssertThrowsErrorAsync(
      try await store.publish(request(jobID: "job-symlink")))
    XCTAssertTrue(
      (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty,
      "a poisoned job directory must not redirect Artifact writes")
  }

  func testPayloadAndIndexDriftFailClosedOnReopen() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(request())
    let payload = root.appending(path: "job-1/\(metadata.artifactID)")
    try Data("tampered".utf8).write(to: payload)
    await XCTAssertThrowsErrorAsync(try await store.list(jobID: "job-1"))

    try FileManager.default.removeItem(at: root)
    let fresh = try makeStore()
    _ = try await fresh.publish(request())
    let jobDirectory = root.appending(path: "job-1", directoryHint: .isDirectory)
    let index = jobDirectory.appending(path: "index.json")
    let outside = root.appending(path: "outside-index.json")
    try FileManager.default.copyItem(at: index, to: outside)
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)
    await XCTAssertThrowsErrorAsync(try await fresh.list(jobID: "job-1"))
  }

  func testArtifactLeaseResolvesImmutableBytesWithoutExposingAnInputPath() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(
      request(name: "demo.hap", contents: "hap-bytes"))
    let lease = try await store.leaseReference(
      jobID: metadata.jobID, artifactID: metadata.artifactID)
    XCTAssertTrue(lease.hasPrefix("lease-v1:"))
    XCTAssertFalse(lease.contains(root.path))
    let resolved = try await store.resolveLease(lease)
    XCTAssertEqual(resolved.artifactID, metadata.artifactID)
    XCTAssertEqual(resolved.sha256, metadata.sha256)
    XCTAssertEqual(try Data(contentsOf: resolved.fileURL), Data("hap-bytes".utf8))
  }

  func testFileBackedPublicationStreamsIntoATargetBoundLease() async throws {
    let store = try makeStore()
    let source = root.deletingLastPathComponent()
      .appending(path: "flash-source-\(UUID().uuidString).tar.gz")
    let bytes = Data(repeating: 0xab, count: 3 * 1_024 * 1_024 + 17)
    try bytes.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let digest =
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let request = RuntimeArtifactFilePublicationRequest(
      jobID: "input-flash-target-1", sessionID: "session-input-flash-target-1",
      stepID: "import-flash-bundle", name: "images.tar.gz",
      mediaType: "application/gzip", privacy: .standard,
      retentionClass: .pinnedUntilVerified,
      sourceOperation: "artifact.import-flash-bundle", providerID: "host",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-1", bindingRevision: 3,
        stableIdentitySHA256: String(repeating: "a", count: 64)),
      sourceFileURL: source, expectedByteCount: bytes.count,
      expectedSHA256: digest)

    let published = try await store.publishFile(request)
    let repeated = try await store.publishFile(request)
    XCTAssertEqual(repeated, published)
    XCTAssertEqual(published.byteCount, bytes.count)
    XCTAssertEqual(published.sha256, digest)
    XCTAssertTrue(published.retention.pinned)
    XCTAssertEqual(published.bindingSnapshot.bindingRevision, 3)
    let lease = try await store.leaseReference(
      jobID: published.jobID, artifactID: published.artifactID)
    XCTAssertFalse(lease.contains(source.path))
    let resolved = try await store.resolveLease(lease)
    XCTAssertEqual(try Data(contentsOf: resolved.fileURL), bytes)
  }

  func testFileBackedPublicationRejectsDigestDriftWithoutPublishing() async throws {
    let store = try makeStore()
    let source = root.deletingLastPathComponent()
      .appending(path: "flash-tampered-\(UUID().uuidString).tar.gz")
    try Data("wrong-flash-bundle".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let request = RuntimeArtifactFilePublicationRequest(
      jobID: "input-flash-target-2", sessionID: "session-input-flash-target-2",
      stepID: "import-flash-bundle", name: "images.tar.gz",
      mediaType: "application/gzip", privacy: .standard,
      retentionClass: .pinnedUntilVerified,
      sourceOperation: "artifact.import-flash-bundle", providerID: "host",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-2", bindingRevision: 4,
        stableIdentitySHA256: String(repeating: "b", count: 64)),
      sourceFileURL: source, expectedByteCount: 18,
      expectedSHA256: String(repeating: "0", count: 64))

    await XCTAssertThrowsErrorAsync(try await store.publishFile(request))
    let listed = try await store.list(jobID: "input-flash-target-2")
    XCTAssertTrue(listed.isEmpty)
  }

  func testLargeTextFilePublicationStreamsRedactionAcrossReadBoundaries() async throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUN_SLOW_ARTIFACT_TESTS"] == "1" else {
      throw XCTSkip(
        "slow 128 MiB artifact lane; run with ARKDECK_RUN_SLOW_ARTIFACT_TESTS=1")
    }
    let store = try makeStore(home: "/Users/tester")
    let source = root.deletingLastPathComponent()
      .appending(path: "large-text-source-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let writer = try FileHandle(forWritingTo: source)
    defer {
      try? writer.close()
      try? FileManager.default.removeItem(at: source)
    }
    // 128 MiB of source is written in 64 KiB chunks.  `token` begins over a
    // reader boundary, proving that the streaming redactor does not leak a
    // secret merely because its key spans two input buffers.
    let chunk = Data(repeating: 0x78, count: 64 * 1024)
    for _ in 0..<1_024 { try writer.write(contentsOf: chunk) }
    try writer.write(contentsOf: Data("tok".utf8))
    try writer.write(contentsOf: Data("en:supersecret-value-that-must-not-persist\n".utf8))
    try writer.write(contentsOf: Data("path=/Users/tester/private/workspace\n".utf8))
    for _ in 0..<1_024 { try writer.write(contentsOf: chunk) }
    try writer.synchronize()
    try writer.close()

    // Measure this process around publication, not the SwiftPM process tree.
    // `swift test` may compile or launch helper processes whose rusage is not
    // attributable to the artifact pipeline.  Sampling the test process pins
    // the property that matters here: a 128 MiB source must not add a
    // source-sized resident allocation while it is redacted and published.
    let baselineResidentSet = try XCTUnwrap(currentProcessResidentSetSize())
    let sampler = ArtifactRSSSampler(baseline: baselineResidentSet)
    sampler.start()
    defer { _ = sampler.stop() }
    let published = try await store.publishTextFile(
      RuntimeArtifactTextFilePublicationRequest(
        jobID: "large-text-job", sessionID: "session-large-text-job",
        stepID: "capture-large-log", name: "large.log", mediaType: "text/plain",
        privacy: .standard, retentionClass: .shortLived,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
        sourceFileURL: source))
    let peakResidentSet = sampler.stop()
    let residentGrowth = peakResidentSet - baselineResidentSet
    XCTAssertLessThan(
      residentGrowth, UInt64(48 * 1024 * 1024),
      "128 MiB streaming publication must not allocate a source-sized resident buffer")
    print(
      "ARKDECK_ARTIFACT_STREAMING sourceBytes=\(128 * 1024 * 1024) "
        + "baselineResidentSetBytes=\(baselineResidentSet) "
        + "peakResidentSetBytes=\(peakResidentSet) "
        + "residentGrowthBytes=\(residentGrowth)")
    XCTAssertGreaterThanOrEqual(published.byteCount, 128 * 1024 * 1024)
    XCTAssertTrue(published.redactionApplied)

    let lease = try await store.leaseReference(
      jobID: published.jobID, artifactID: published.artifactID)
    let resolved = try await store.resolveLease(lease)
    XCTAssertFalse(
      try fileContains(Data("supersecret-value-that-must-not-persist".utf8), at: resolved.fileURL))
    XCTAssertFalse(try fileContains(Data("/Users/tester".utf8), at: resolved.fileURL))
    XCTAssertTrue(try fileContains(Data("<REDACTED>".utf8), at: resolved.fileURL))
    XCTAssertTrue(try fileContains(Data("<HOME>".utf8), at: resolved.fileURL))
  }

  func testTextFileStreamingRedactionKeepsOrdinaryKeyPrefixes() async throws {
    let store = try makeStore(home: "/Users/tester")
    let source = root.deletingLastPathComponent()
      .appending(path: "stream-prefix-\(UUID().uuidString).txt")
    let sourceText =
      "tokenizer remains ordinary; secrettoken: second-secret-value\napi_key: abcdefghi\n/Users/tester/project\n"
    try Data(sourceText.utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let published = try await store.publishTextFile(
      RuntimeArtifactTextFilePublicationRequest(
        jobID: "stream-prefix-job", sessionID: "session-stream-prefix-job",
        stepID: "capture-log", name: "prefix.txt", mediaType: "text/plain",
        privacy: .standard, retentionClass: .default,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
        sourceFileURL: source))
    let text =
      String(
        data: try await store.read(jobID: published.jobID, artifactID: published.artifactID),
        encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("tokenizer remains ordinary"), text)
    XCTAssertTrue(text.contains("secrettoken: <REDACTED>"), text)
    XCTAssertTrue(text.contains("api_key: <REDACTED>"), text)
    XCTAssertFalse(text.contains("second-secret-value"), text)
    XCTAssertFalse(text.contains("abcdefghi"), text)
    XCTAssertFalse(text.contains("/Users/tester"), text)
  }

  func testExportRefusesOverwriteAndSanitizesName() async throws {
    let store = try makeStore()
    let hostile = try await store.publish(request(name: "../evil.json"))
    let destination = root.appending(path: "export", directoryHint: .isDirectory)
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
    let text =
      String(
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
      _ = try await store.publish(
        request(name: "binding-snapshot.json", contents: String(repeating: "b", count: 40)))
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

  func testQuotaUsageStaysExactAcrossIncrementalPublicationGCAndRestart() async throws {
    let store = try makeStore(quota: ArtifactQuota(totalBytes: 100))
    _ = try await store.publish(
      request(jobID: "job-cache-a", contents: String(repeating: "a", count: 30)))
    let firstUsage = try await store.totalBytesUsed()
    XCTAssertEqual(firstUsage, 30)
    _ = try await store.publish(
      request(jobID: "job-cache-b", contents: String(repeating: "b", count: 20)))
    let incrementalUsage = try await store.totalBytesUsed()
    XCTAssertEqual(
      incrementalUsage, 50,
      "subsequent publications must update the process-local quota total")

    let removed = try await store.collectGarbage(
      activeJobIDs: [], nowUTC: "2027-01-01T00:00:00Z")
    XCTAssertEqual(removed.count, 2)
    let usageAfterGC = try await store.totalBytesUsed()
    XCTAssertEqual(
      usageAfterGC, 0,
      "GC invalidates and rebuilds usage from the committed durable indexes")

    _ = try await store.publish(
      request(jobID: "job-after-gc", contents: String(repeating: "c", count: 90)))
    let usageAfterRepublish = try await store.totalBytesUsed()
    XCTAssertEqual(usageAfterRepublish, 90)

    let reopened = try makeStore(quota: ArtifactQuota(totalBytes: 100))
    let reopenedUsage = try await reopened.totalBytesUsed()
    XCTAssertEqual(
      reopenedUsage, 90,
      "a new daemon process must rebuild quota usage from durable truth")
    await XCTAssertThrowsErrorAsync(
      try await reopened.publish(
        request(
          jobID: "job-over-restart-quota", name: "binding-snapshot.json",
          contents: String(repeating: "d", count: 11))))
  }

  func testGarbageCollectionSparesActiveAndPinnedArtifacts() async throws {
    let store = try makeStore()
    _ = try await store.publish(request(jobID: "job-active"))
    let expired = try await store.publish(request(jobID: "job-expired"))
    let pinned = try await store.publish(
      request(jobID: "job-old", name: "backup-receipt.json", retentionClass: .pinnedUntilVerified))
    XCTAssertTrue(pinned.retention.pinned)
    let removed = try await store.collectGarbage(
      activeJobIDs: ["job-active"], nowUTC: "2027-01-01T00:00:00Z")
    XCTAssertEqual(removed, [expired.artifactID])
    let activeList = try await store.list(jobID: "job-active")
    let oldList = try await store.list(jobID: "job-old")
    let expiredList = try await store.list(jobID: "job-expired")
    XCTAssertEqual(activeList.count, 1)
    XCTAssertEqual(oldList.count, 1)
    XCTAssertTrue(expiredList.isEmpty)
  }

  /// `pinnedUntilVerified` yields `deadlineUTC: nil, pinned: true`, and nothing
  /// in the repository ever un-pins: `collectGarbage` only reclaims
  /// `expired && !pinned`, so every artifact in this set is retained forever.
  /// That is a deliberate evidence-retention choice, not an accident — but it
  /// means each addition permanently enlarges the floor of the store, so the
  /// set is pinned here and grows only on purpose. Un-pinning after
  /// verification is a separate design question and is not implemented.
  func testTheSetOfPermanentlyRetainedArtifactsIsDeclaredRatherThanIncidental() {
    var pinnedArtifacts: [String] = []
    for descriptor in RuntimeOperationCatalog.operations {
      for artifact in descriptor.artifacts where artifact.retentionClass == .pinnedUntilVerified {
        pinnedArtifacts.append("\(descriptor.reference)/\(artifact.name)")
      }
    }
    XCTAssertEqual(
      pinnedArtifacts.sorted(),
      [
        "deploy.native-library.system@1/backup-receipt.json",
        "workspace.apply-patch@1/applied-patch.json",
        "workspace.build-openharmony@1/unsigned.hap",
        "workspace.prepare-isolated-copy@1/isolated-workspace.json",
        "workspace.sign-openharmony-hap@1/signed.hap",
        "workspace.sign-openharmony-hap@1/signing-report.json",
      ],
      "a new pinnedUntilVerified artifact is never reclaimed; add it here deliberately")
  }

  func testGarbageCollectionComparesParsedUTCInsteadOfTimestampText() async throws {
    let store = try RuntimeArtifactStore(
      rootURL: root,
      retentionPolicy: ArtifactRetentionPolicy(
        defaultLifetimeSeconds: 1, shortLivedLifetimeSeconds: 1),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let artifact = try await store.publish(request(jobID: "job-fractional-gc"))

    let removed = try await store.collectGarbage(
      activeJobIDs: [], nowUTC: "2026-07-29T00:00:01.500Z")

    XCTAssertEqual(removed, [artifact.artifactID])
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
      jobID: "job-1", identity: "/data/local/tmp/arkdeck/job-1/trace-abc")
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

  func testShortArtifactIDInIndexFailsClosed() async throws {
    let store = try makeStore()
    let published = try await store.publish(request())
    let jobDirectory = root.appending(path: "job-1", directoryHint: .isDirectory)
    let shortID = "ART-\(published.sha256.prefix(16))"
    try FileManager.default.moveItem(
      at: jobDirectory.appending(path: published.artifactID),
      to: jobDirectory.appending(path: shortID))
    let indexURL = jobDirectory.appending(path: "index.json")
    var index = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))
        as? [String: Any])
    var artifacts = try XCTUnwrap(index["artifacts"] as? [[String: Any]])
    artifacts[0]["artifactID"] = shortID
    index["artifacts"] = artifacts
    try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
      .write(to: indexURL)

    let reopened = try makeStore()
    await XCTAssertThrowsErrorAsync(try await reopened.list(jobID: "job-1"))
  }

  func testEvidenceProjectionRehashesControlledArtifactBytes() async throws {
    let store = try makeStore()
    let metadata = try await store.publish(request())
    let verified = try await store.verifiedEvidenceArtifacts(jobID: "job-1")
    XCTAssertEqual(verified.count, 1)
    XCTAssertEqual(verified[0].sha256, metadata.sha256)
    XCTAssertTrue(verified[0].reference.hasPrefix("arkdeck-artifact://job-1/"))

    let bytesURL = root.appending(path: "job-1/\(metadata.artifactID)")
    try Data("tampered".utf8).write(to: bytesURL)
    await XCTAssertThrowsErrorAsync(
      try await store.verifiedEvidenceArtifacts(jobID: "job-1"))
  }

  func testEvidenceProjectionSkipsOnlyExplicitlyOmittedOptionalProduct() async throws {
    let store = try makeStore()
    let published = try await store.publish(request(name: "hilog.txt"))
    _ = try await store.recordMissing(
      jobID: "job-1", sessionID: "session-job-1", stepID: "receive-trace-artifact",
      name: "trace.htrace", mediaType: "application/octet-stream", privacy: .sensitive,
      retentionClass: .default, sourceOperation: "capture.diagnostics@1",
      providerID: "hdc",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
      reason: "step not selected by the request inputs")

    let verified = try await store.verifiedEvidenceArtifacts(
      jobID: "job-1", intentionallyOmittedNames: ["trace.htrace"])
    XCTAssertEqual(verified.map(\.sha256), [published.sha256])

    await XCTAssertThrowsErrorAsync(
      try await store.verifiedEvidenceArtifacts(jobID: "job-1"))
  }

  private func fileContains(_ needle: Data, at url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var carry = Data()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      var haystack = carry
      haystack.append(chunk)
      if haystack.range(of: needle) != nil { return true }
      carry = Data(haystack.suffix(max(0, needle.count - 1)))
    }
    return false
  }
}

private final class ArtifactRSSSampler: @unchecked Sendable {
  private let lock = NSLock()
  private let finished = DispatchSemaphore(value: 0)
  private var stopped = false
  private var joined = false
  private var peakResidentSet: UInt64

  init(baseline: UInt64) {
    peakResidentSet = baseline
  }

  func start() {
    let sampler = self
    Thread.detachNewThread { sampler.sampleUntilStopped() }
  }

  func stop() -> UInt64 {
    lock.lock()
    stopped = true
    let shouldWait = !joined
    joined = true
    lock.unlock()
    if shouldWait { _ = finished.wait(timeout: .now() + 1) }
    lock.lock()
    defer { lock.unlock() }
    return peakResidentSet
  }

  private func sampleUntilStopped() {
    defer { finished.signal() }
    while true {
      lock.lock()
      let shouldStop = stopped
      lock.unlock()
      if shouldStop { return }
      if let residentSet = currentProcessResidentSetSize() {
        lock.lock()
        peakResidentSet = max(peakResidentSet, residentSet)
        lock.unlock()
      }
      usleep(5_000)
    }
  }
}

private func currentProcessResidentSetSize() -> UInt64? {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { infoPointer in
    infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
      task_info(
        mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
    }
  }
  guard result == KERN_SUCCESS else { return nil }
  return UInt64(info.resident_size)
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
