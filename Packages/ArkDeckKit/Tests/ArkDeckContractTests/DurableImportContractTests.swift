import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only fixtures: actual owner persistence, daemon and CLI. No device acceptance.
final class DurableImportContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var targets: RuntimeTargetStore!
  private var target: RuntimeTargetRecord!
  private var server: AgentDaemonServer?
  private var handler: RuntimeControlPlaneHandler?
  private var engine: RuntimeJobEngine!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private let now = "2026-09-01T00:00:00Z"
  private let hap = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x61, count: 4092)
  private enum FixtureError: Error { case missing, injected }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "di-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let key = "150100424a544e4600"
    target = try targets.adopt(stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: key),
      connectKey: key, toolVersion: "3.2.0f", nowUTC: now).record
  }
  override func tearDownWithError() throws {
    server?.stop(); server = nil; engine = nil; artifacts = nil; targets = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func intent(_ id: String = "upload-test", bytes: Data? = nil, kind: String = "hap", name: String = "fixture.hap") throws -> ArtifactImportIntent {
    let data = bytes ?? hap
    return try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(id), "kind": .string(kind), "targetId": .string(target.targetID),
      "bindingRevision": .string(String(target.bindingRevision)), "deviceProfile": kind == "flash-bundle" ? .string("dayu200") : .null,
      "name": .string(name), "byteCount": .string(String(data.count)), "sha256": .string(SHA256Hex.string(of: data))])
  }
  private var binding: ArtifactBindingSnapshot { .init(targetID: target.targetID, bindingRevision: target.bindingRevision, stableIdentitySHA256: target.stablePhysicalIdentitySHA256) }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw FixtureError.missing }; return fields
  }
  private func text(_ value: JSONValue?) throws -> String {
    guard case .string(let text)? = value else { throw FixtureError.missing }; return text
  }
  private func assertCode(_ code: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("expected \(code)", file: file, line: line) }
    catch let failure as AgentExecutionControlFailure { XCTAssertEqual(failure.code, code, file: file, line: line) }
    catch { XCTFail("unexpected \(error)", file: file, line: line) }
  }
  private func begin(_ id: String = "upload-test") async throws -> ArtifactImportProjection {
    try ArtifactImportProjection(await artifacts.beginImport(intent(id), binding: binding))
  }
  private func append(_ record: ArtifactImportProjection, data: Data, offset: Int = 0) async throws -> ArtifactImportProjection {
    try ArtifactImportProjection(await artifacts.appendImport(id: record.id, generation: record.generation,
      offset: offset, chunk: data, sha256: SHA256Hex.string(of: data)))
  }
  private func commit(_ record: ArtifactImportProjection) async throws -> ArtifactImportProjection {
    try ArtifactImportProjection(await artifacts.commitImport(id: record.id, generation: record.generation) { _, value in
      ["kind": .string(value.intent.kind), "container": .string("zip")]
    })
  }
  private func startServer(policy: FlashBundleImportPolicy? = nil, observer: (@Sendable (String) -> Void)? = nil) throws {
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(
        factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: .init()))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
    let handler: RuntimeControlPlaneHandler
    if let policy {
      handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
        nowUTC: { "2026-09-01T00:00:00Z" }, targetStore: targets, bootstrap: nil, artifactStore: artifacts,
        flashBundleImportDirectory: nil, flashBundleImportPolicy: policy, methodObserver: observer)
    } else {
      handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
        nowUTC: { "2026-09-01T00:00:00Z" }, targetStore: targets, artifactStore: artifacts, methodObserver: observer)
    }
    self.handler = handler
    server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
  }
  private func cli(_ args: [String], socketPath: String? = nil) throws -> (Int32, [String: JSONValue]) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = args + ["--socket", try socketPath ?? XCTUnwrap(server).socketURL.path, "--output", "json"]
    let output = root.appending(path: "out-\(UUID()).json")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    process.standardOutput = handle; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? handle.close() }
    let end = Date().addingTimeInterval(25)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else { throw FixtureError.missing }
    try handle.close()
    return (process.terminationStatus, try object(CLIStrictJSON.decode(Data(contentsOf: output))))
  }

  func testStableRequestOwnerExactRetryAndConflictingChunksAcrossRestart() async throws {
    let begun = try await begin()
    let first = Data(hap.prefix(100))
    let partial = try await append(begun, data: first)
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    let same = try await begin()
    XCTAssertEqual(same.id, begun.id); XCTAssertEqual(same.nextOffset, 100)
    let duplicate = try await append(same, data: first)
    XCTAssertEqual(duplicate.value, partial.value)
    await assertCode("resourceConflict") { _ = try await self.append(same, data: Data(repeating: 0x62, count: 100)) }
    await assertCode("resourceConflict") { _ = try await self.append(same, data: Data([1]), offset: 101) }
    await assertCode("idempotencyConflict") {
      _ = try await self.artifacts.beginImport(self.intent(bytes: Data(repeating: 0x62, count: self.hap.count)), binding: self.binding)
    }
    let complete = try await append(same, data: Data(hap.dropFirst(100)), offset: 100)
    let published = try await commit(complete)
    let replayed = try await commit(complete)
    XCTAssertEqual(published.value, replayed.value)
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:02Z" })
    let rediscovered = try ArtifactImportProjection(await artifacts.inspectImport(requestID: "upload-test").projection)
    XCTAssertEqual(rediscovered.value, published.value)
    let receipt = try object(object(published.value)["receipt"]!)
    let resolved = try await artifacts.resolveLease(text(receipt["lease"]))
    XCTAssertEqual(try Data(contentsOf: resolved.fileURL), hap)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "artifacts/.imports-v1/payloads/\(begun.id).stage").path))
  }

  func testAbortIsDurableTombstoneAndCannotAbortCommit() async throws {
    let begun = try await begin()
    _ = try await append(begun, data: Data(hap.prefix(100)))
    let aborted = try await artifacts.abortImport(requestID: "upload-test", generation: 1)
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    let retried = try await artifacts.abortImport(requestID: "upload-test", generation: 1)
    XCTAssertEqual(aborted, retried)
    let repeatedBegin = try await begin()
    XCTAssertEqual(repeatedBegin.state, "aborted"); XCTAssertEqual(repeatedBegin.id, begun.id)
    await assertCode("resourceConflict") { _ = try await self.append(begun, data: self.hap) }
    let second = try await begin("committed-upload")
    let full = try await append(second, data: hap)
    _ = try await commit(full)
    await assertCode("resourceConflict") { _ = try await self.artifacts.abortImport(requestID: "committed-upload", generation: 1) }
  }

  func testCorruptCommittedPrefixIsNeverRecreatedOrOverwritten() async throws {
    let begun = try await begin()
    _ = try await append(begun, data: Data(hap.prefix(100)))
    let payload = root.appending(path: "artifacts/.imports-v1/payloads/\(begun.id).stage")
    let fd = open(payload.path, O_WRONLY | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(fd, 0)
    var changed: UInt8 = 0xff; XCTAssertEqual(pwrite(fd, &changed, 1, 4), 1); close(fd)
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    await assertCode("recordUnreadable") { _ = try await self.artifacts.inspectImport(id: begun.id) }
    await assertCode("recordUnreadable") { _ = try await self.append(begun, data: self.hap) }
    XCTAssertEqual(try Data(contentsOf: payload)[4], 0xff)
    try FileManager.default.removeItem(at: payload)
    await assertCode("recordUnreadable") { _ = try await self.artifacts.inspectImport(id: begun.id) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
  }

  func testSymlinkRecordAndStagingAreRefusedWithoutFollowingThem() async throws {
    let begun = try await begin()
    let payload = root.appending(path: "artifacts/.imports-v1/payloads/\(begun.id).stage")
    let outside = root.appending(path: "unrelated")
    try hap.write(to: outside)
    try FileManager.default.removeItem(at: payload)
    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
    await assertCode("recordUnreadable") { _ = try await self.artifacts.inspectImport(id: begun.id) }
    XCTAssertEqual(try Data(contentsOf: outside), hap)
    let missing = root.appending(path: "does-not-exist")
    let key = SHA256Hex.string(of: Data("dangling".utf8))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "artifacts/.imports-v1/records/\(key).json"), withDestinationURL: missing)
    await assertCode("recordUnreadable") { _ = try await self.artifacts.inspectImport(requestID: "dangling") }
  }

  func testSnapshotRemainsFixedAfterMutationRestartAndRejectsQueryDrift() async throws {
    _ = try await begin("first"); _ = try await begin("second")
    let first = try await artifacts.listImports(["pageSize": .integer(1)])
    try ArtifactImportProjection.validatePage(first)
    let fields = try object(first); let cursor = try text(fields["nextCursor"])
    _ = try await begin("third")
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    let next = try await artifacts.listImports(["pageSize": .integer(1), "cursor": .string(cursor)])
    try ArtifactImportProjection.validatePage(next)
    XCTAssertEqual(try object(next)["snapshotRevision"], fields["snapshotRevision"])
    XCTAssertEqual(try object(next)["hasMore"], .bool(false))
    await assertCode("invalidCursor") { _ = try await self.artifacts.listImports(["pageSize": .integer(2), "cursor": .string(cursor)]) }
  }

  func testRealProcessKillRecoversPartialSyncedCommittingAndPublishedWindows() async throws {
    for window in ["import-partial", "import-synced", "import-committing", "import-published"] {
      let directory = root.appending(path: window)
      let child = Process()
      child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckEngineCrashFixture")
      child.arguments = [window, directory.path]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run()
      defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let ready = directory.appending(path: "ready")
      let end = Date().addingTimeInterval(15)
      while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < end { usleep(10_000) }
      guard FileManager.default.fileExists(atPath: ready.path) else { XCTFail("crash fixture never reached \(window)"); continue }
      kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
      XCTAssertEqual(child.terminationReason, .uncaughtSignal)
      let store = try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:02Z" })
      let recovered = try await store.inspectImport(requestID: "crash-upload")
      let interruptedAppend = ["import-partial", "import-synced"].contains(window)
      XCTAssertEqual(recovered.nextOffset, interruptedAppend ? 32 : hap.count)
      let staged = directory.appending(path: "artifacts/.imports-v1/payloads/\(recovered.importID).stage")
      XCTAssertEqual(try Data(contentsOf: staged).count, recovered.nextOffset)
      if interruptedAppend {
        let suffix = Data(hap.dropFirst(32))
        _ = try await store.appendImport(id: recovered.importID, generation: 1, offset: 32, chunk: suffix, sha256: SHA256Hex.string(of: suffix))
      }
      let result = try ArtifactImportProjection(await store.commitImport(id: recovered.importID, generation: 1) { _, _ in
        if !interruptedAppend { throw FixtureError.injected } // A durable validation decision must not be re-run.
        return ["kind": .string("hap"), "container": .string("zip")]
      })
      XCTAssertEqual(result.state, "committed")
      let inventory = try await store.list(jobID: recovered.importID)
      XCTAssertEqual(inventory.count, 1, "restart must converge on one immutable Artifact")
      let replay = try await store.commitImport(id: recovered.importID, generation: 1) { _, _ in throw FixtureError.injected }
      XCTAssertEqual(replay, result.value)
      XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
  }

  func testCLIResumesStagedHAPReturnsSameReceiptAndCreatesNoJob() async throws {
    let begun = try await begin()
    _ = try await append(begun, data: Data(hap.prefix(32)))
    try startServer()
    let file = root.appending(path: "fixture.hap"); try hap.write(to: file)
    let args = ["artifact", "import", "hap", "--import-request-id", "upload-test", "--target", target.targetID, "--file", file.path]
    let result = try cli(args)
    XCTAssertEqual(result.0, 0, "\(result.1)")
    let projection = try ArtifactImportProjection(XCTUnwrap(result.1["result"]))
    XCTAssertEqual(projection.id, begun.id); XCTAssertEqual(projection.state, "committed")
    let repeated = try cli(args)
    XCTAssertEqual(repeated.0, 0); XCTAssertEqual(repeated.1["result"], result.1["result"])
    let inspected = try cli(["artifact", "import", "inspect", "--import-request-id", "upload-test"])
    XCTAssertEqual(inspected.0, 0); XCTAssertEqual(inspected.1["result"], result.1["result"])
    let jobs = try await engine.jobListSnapshot(RuntimeJobListQuery([:]))
    XCTAssertEqual(try object(jobs)["items"], .array([])); XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLIReleaseIsGenerationBoundRediscoverableAndDoesNotRepinOnUploadRetry() async throws {
    try startServer()
    let file = root.appending(path: "fixture.hap"); try hap.write(to: file)
    let upload = ["artifact", "import", "hap", "--import-request-id", "release-cli", "--target", target.targetID, "--file", file.path]
    let committed = try cli(upload)
    XCTAssertEqual(committed.0, 0)
    let record = try ArtifactImportProjection(XCTUnwrap(committed.1["result"]))
    let command = ["artifact", "import", "release", "--import", record.id, "--generation", "2"]
    let released = try cli(command)
    XCTAssertEqual(released.0, 0, "\(released.1)")
    let receipt = try ArtifactImportReleaseProjection(XCTUnwrap(released.1["result"]))
    XCTAssertEqual(receipt.importID, record.id)
    let repeated = try cli(command)
    XCTAssertEqual(repeated.0, 0); XCTAssertEqual(repeated.1["result"], released.1["result"])
    let stale = try cli(["artifact", "import", "release", "--import", record.id, "--generation", "3"])
    XCTAssertNotEqual(stale.0, 0)
    XCTAssertEqual(try object(XCTUnwrap(stale.1["error"]))["code"], .string("resourceConflict"))
    let inspected = try cli(["artifact", "import", "inspect", "--import", record.id])
    let current = try ArtifactImportProjection(XCTUnwrap(inspected.1["result"]))
    XCTAssertEqual(current.state, "released"); XCTAssertEqual(current.generation, 3)
    XCTAssertEqual(try object(current.value)["receipt"], try object(record.value)["receipt"])
    let listed = try cli(["artifact", "import", "list", "--state", "released"])
    XCTAssertEqual(try object(XCTUnwrap(listed.1["result"]))["items"], .array([current.value]))
    let retry = try cli(upload)
    XCTAssertEqual(retry.0, 1); XCTAssertEqual(retry.1["result"], current.value)
    let metadata = try await artifacts.inspect(jobID: record.id, artifactID: receipt.artifactID)
    XCTAssertFalse(metadata.retention.pinned)
    let bytes = try await artifacts.read(jobID: record.id, artifactID: receipt.artifactID, maximumBytes: hap.count, allowSensitive: false)
    XCTAssertEqual(bytes, hap)
    let jobs = try await engine.listJobs(); XCTAssertTrue(jobs.isEmpty); XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLIChangedSourceFailsIntegrityWithoutAbortingStaging() async throws {
    let begun = try await begin()
    _ = try await append(begun, data: Data(hap.prefix(100)))
    try startServer()
    let file = root.appending(path: "fixture.hap"); var changed = hap; changed[100] = 0xff; try changed.write(to: file)
    let result = try cli(["artifact", "import", "hap", "--import-request-id", "upload-test", "--target", target.targetID, "--file", file.path])
    XCTAssertNotEqual(result.0, 0)
    XCTAssertEqual(try object(XCTUnwrap(result.1["error"]))["code"], .string("artifactIntegrityFailed"))
    let saved = try await artifacts.inspectImport(id: begun.id)
    XCTAssertEqual(saved.state, "inProgress"); XCTAssertEqual(saved.nextOffset, 100); XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLIRegisteredValidatorsKeepPatchExactSensitiveNativeSignedAndFlashPinned() async throws {
    let patch = Data("diff --git a/src/main.txt b/src/main.txt\n--- a/src/main.txt\n+++ b/src/main.txt\n@@ -1 +1 @@\n-old\n+token=private-source-input\n".utf8)
    let native = NativeLibraryTestFixture.arm64ELF()
    let archive = Data(repeating: 0xab, count: 2 * 1024 * 1024 + 10)
    let archiveDigest = SHA256Hex.string(of: archive)
    let policy = FlashBundleImportPolicy(expectedByteCount: archive.count, expectedSHA256: archiveDigest) { url in
      guard try Data(contentsOf: url) == archive else { throw FixtureError.injected }
      return FlashBundleImportValidation(byteCount: archive.count, sha256: archiveDigest)
    }
    try startServer(policy: policy)
    for (kind, name, bytes) in [("workspace-patch", "fixture.patch", patch), ("native-library", "libfixture.so", native), ("flash-bundle", "daily-images.tar.gz", archive)] {
      let file = root.appending(path: name); try bytes.write(to: file)
      let result = try cli(["artifact", "import", kind, "--import-request-id", "upload-" + kind, "--target", target.targetID, "--file", file.path])
      XCTAssertEqual(result.0, 0, "\(result.1)")
      let projection = try ArtifactImportProjection(XCTUnwrap(result.1["result"]))
      let receipt = try object(object(projection.value)["receipt"]!)
      let lease = try await artifacts.resolveLease(text(receipt["lease"]))
      XCTAssertEqual(try Data(contentsOf: lease.fileURL), bytes)
      XCTAssertEqual(receipt["privacy"], .string(kind == "workspace-patch" ? "sensitive" : "standard"))
    }
    let bad = root.appending(path: "libinvalid.so"); try hap.write(to: bad)
    let failure = try cli(["artifact", "import", "native-library", "--import-request-id", "bad-native", "--target", target.targetID, "--file", bad.path])
    XCTAssertNotEqual(failure.0, 0)
    let failed = try await artifacts.inspectImport(requestID: "bad-native")
    XCTAssertEqual(failed.state, "inProgress"); XCTAssertNil(failed.receipt)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLILostBeginAppendAndCommitRepliesRediscoverOneImportWithoutResendingBytes() async throws {
    try startServer()
    let handler = try XCTUnwrap(self.handler)
    let path = root.appending(path: "drop.sock").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { close(listener) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      path.utf8CString.withUnsafeBytes { destination.copyMemory(from: $0) }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 2), 0)
    let served = expectation(description: "all lost replies recovered")
    DispatchQueue.global().async {
      defer { served.fulfill() }
      var dropped = Set<String>()
      // negotiate, inspect, target, begin, inspect, append, inspect, commit, inspect
      for _ in 0..<9 {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 5000) > 0 else { return XCTFail("missing recovery request") }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return XCTFail("fixture accept failed") }
        defer { close(connection) }
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var frame = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while !frame.contains(10) && frame.count < 4 * 1024 * 1024 {
          let count = read(connection, &buffer, buffer.count)
          guard count > 0 else { return XCTFail("fixture request incomplete") }
          frame.append(contentsOf: buffer.prefix(count))
        }
        let request = Data(frame.prefix { $0 != 10 })
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any], let method = object["method"] as? String else {
          return XCTFail("fixture request malformed")
        }
        let shouldDrop = ["artifact.import.begin", "artifact.import.append", "artifact.import.commit"].contains(method) && dropped.insert(method).inserted
        let done = DispatchSemaphore(value: 0)
        Task.detached {
          defer { done.signal() }
          let response = await handler.handleLine(request)
          if !shouldDrop {
            response.withUnsafeBytes { bytes in
              var sent = 0
              while sent < bytes.count {
                let count = write(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count <= 0 { break }; sent += count
              }
            }
          }
        }
        guard done.wait(timeout: .now() + 5) == .success else { return XCTFail("fixture owner stalled") }
      }
      XCTAssertEqual(dropped.count, 3)
    }
    let file = root.appending(path: "fixture.hap"); try hap.write(to: file)
    let result = try cli(["artifact", "import", "hap", "--import-request-id", "lost-replies", "--target", target.targetID, "--file", file.path], socketPath: path)
    XCTAssertEqual(result.0, 0, "\(result.1)")
    let projection = try ArtifactImportProjection(XCTUnwrap(result.1["result"]))
    let record = try await artifacts.inspectImport(requestID: "lost-replies")
    XCTAssertEqual(projection.id, record.importID); XCTAssertEqual(record.state, "committed")
    XCTAssertEqual(record.chunks.count, 1, "inspect must skip the already committed chunk")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    await fulfillment(of: [served], timeout: 6)
  }

  func testCLIExpiredBudgetKeepsExistingUploadAndNeverAborts() async throws {
    let record = try await begin()
    _ = try await append(record, data: Data(hap.prefix(100)))
    try startServer(observer: { method in
      if method == "artifact.import.inspect" { Thread.sleep(forTimeInterval: 0.05) }
    })
    let file = root.appending(path: "fixture.hap"); try hap.write(to: file)
    let result = try cli(["artifact", "import", "hap", "--import-request-id", "upload-test", "--target", target.targetID, "--file", file.path, "--timeout", "20ms"])
    XCTAssertEqual(result.0, 75, "\(result.1)")
    let saved = try await artifacts.inspectImport(id: record.id)
    XCTAssertEqual(saved.state, "inProgress"); XCTAssertEqual(saved.nextOffset, 100)
  }

  func testDeclaredStagingQuotaDoesNotDeleteAnotherOwnerOrAllocateDeclaredBytes() async throws {
    var fields = try object(intent("large").projection)
    fields["kind"] = .string("flash-bundle"); fields["name"] = .string("images.tar.gz")
    fields["deviceProfile"] = .string("dayu200"); fields["byteCount"] = .string(String(8 * 1024 * 1024 * 1024))
    let large = try ArtifactImportProjection(await artifacts.beginImport(ArtifactImportIntent(fields), binding: binding))
    await assertCode("quotaExceeded") { _ = try await self.begin("next") }
    let persisted = try await artifacts.inspectImport(id: large.id)
    XCTAssertEqual(persisted.nextOffset, 0); XCTAssertEqual(persisted.state, "inProgress")
    _ = try await artifacts.abortImport(requestID: "large", generation: 1)
    let next = try await begin("next"); XCTAssertEqual(next.nextOffset, 0)
  }

  func testPublishedButUncommittedImportCannotBeResolvedAsAnInputLease() async throws {
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), importFault: { point in
      if point == .afterPublication { throw FixtureError.injected }
    }, nowUTC: { "2026-09-01T00:00:00Z" })
    let begun = try await begin(); let full = try await append(begun, data: hap)
    do { _ = try await commit(full); XCTFail("expected publication fault") } catch FixtureError.injected { }
    let published = try await artifacts.list(jobID: begun.id)
    let item = try XCTUnwrap(published.first)
    let lease = "lease-v1:\(begun.id):\(item.artifactID)"
    do { _ = try await artifacts.resolveLease(lease); XCTFail("uncommitted lease must not be executable") }
    catch RuntimeArtifactError.artifactNotFound { }
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    _ = try await commit(full)
    let resolved = try await artifacts.resolveLease(lease)
    XCTAssertEqual(resolved.sha256, SHA256Hex.string(of: hap))
  }

  func testClosedMetadataAndProjectionRejectAmbiguousCountsAndOwners() async throws {
    let metadata = try object(intent().projection)
    for (key, value) in [("byteCount", JSONValue.string("04096")), ("bindingRevision", .integer(1)), ("deviceProfile", .string("unregistered")), ("name", .string("fixture.hap\n")), ("path", .string("/private/secret"))] {
      var fields = metadata; fields[key] = value
      XCTAssertThrowsError(try ArtifactImportIntent(fields))
    }
    let begin = try await begin(); let full = try await append(begin, data: hap); let committed = try await commit(full)
    var fields = try object(committed.value); var receipt = try object(fields["receipt"]!)
    receipt["owner"] = .object(["kind": .string("job"), "id": .string(begin.id)]); fields["receipt"] = .object(receipt)
    XCTAssertThrowsError(try ArtifactImportProjection(.object(fields)))
    fields = try object(begin.value); fields["state"] = .string("committing")
    XCTAssertThrowsError(try ArtifactImportProjection(.object(fields)))
  }
}
