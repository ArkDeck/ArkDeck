import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// TASK-DHA-001 (D4): the device-to-host receive leg.
///
/// This leg is the one place where the process receipt cannot carry the
/// evidence. `hdc file recv` exits 0 and prints a progress line whether or
/// not usable bytes landed, so a verdict read off the receipt is a verdict
/// about hdc's own chattiness. Every test here therefore drives real bytes
/// through real files — several through a real child process — and asserts
/// on what the host actually holds afterwards.
final class ArtifactReceiveLegContractTests: XCTestCase {
  private var receiveRoot: URL!

  override func setUpWithError() throws {
    receiveRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-receive-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let receiveRoot { try? FileManager.default.removeItem(at: receiveRoot) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-30T00:00:00Z")
    }
  }

  private let connectKey = "150100424a544e4600"

  private var provider: HDCObservationProviderAdapter {
    HDCObservationProviderAdapter(factsPort: FactsPort(), hostReceiveRoot: receiveRoot)
  }

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-receive-1", stepID: "receive-trace-artifact", targetID: "TGT-1",
      bindingRevision: 7, connectKey: connectKey,
      nowUTC: "2026-07-30T00:00:00Z")
  }

  private func artifact(
    expectedSHA256: String? = nil, maximumBytes: Int = 64 * 1024 * 1024
  ) throws -> HDCOwnedRemoteArtifact {
    HDCOwnedRemoteArtifact(
      path: try HDCOwnedRemotePath(
        jobID: "job-receive-1", stepID: "capture-trace", nonce: "n1"),
      expectedSHA256: expectedSHA256, maximumBytes: maximumBytes)
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }

  // MARK: - Lowering

  /// `file recv` takes both paths. The pre-D4 argv named only the remote
  /// one, which is why nothing ever landed.
  func testReceiveArgvNamesTheHostDestination() throws {
    let owned = try artifact()
    let plan = try provider.lower(action: .hdc(.receiveOwnedArtifact(owned)), context: context)
    guard case .process(_, let arguments, let timeout) = plan.kind else {
      return XCTFail("expected a process plan")
    }
    let destination = receiveRoot.appendingPathComponent(
      "arkdeck-job-receive-1-capture-trace-n1.htrace", isDirectory: false)
    XCTAssertEqual(
      arguments,
      ["-t", connectKey, "file", "recv", owned.path.remotePath, destination.path])
    XCTAssertEqual(timeout, 60)
    XCTAssertEqual(plan.hostLanding?.destination, destination)
    XCTAssertEqual(plan.hostLanding?.maximumBytes, owned.maximumBytes)
  }

  /// deveco has to try `recv <remote> <dir>` and `recv <remote> <dir>/<name>`
  /// separately because the landing form differs by hdc build. Naming the
  /// local file after the remote basename makes both forms land on the same
  /// path, so the host check does not depend on which form the device took.
  func testHostDestinationSharesTheRemoteBasename() throws {
    let owned = try artifact()
    let plan = try provider.lower(action: .hdc(.receiveOwnedArtifact(owned)), context: context)
    let destination = try XCTUnwrap(plan.hostLanding?.destination)
    XCTAssertEqual(
      destination.lastPathComponent,
      URL(fileURLWithPath: owned.path.remotePath).lastPathComponent)
  }

  // MARK: - Verdict from the bytes on disk

  func testReceivedBytesDecideTheVerdictAndItsDigest() throws {
    let payload = Data("htrace-fixture-bytes".utf8)
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"),
      maximumBytes: 64 * 1024)
    try landing.prepareDestination()
    try payload.write(to: landing.destination)

    let outcome = try provider.verify(
      receipt: receipt(landing: landing), action: .hdc(.receiveOwnedArtifact(try artifact())),
      context: context)
    guard case .verified(let summary) = outcome else {
      return XCTFail("expected a verified receive, got \(outcome)")
    }
    XCTAssertEqual(summary["byteCount"], String(payload.count))
    XCTAssertEqual(summary["sha256"], sha256Hex(payload))
    // The summary is journalled and published; the host directory layout is
    // not evidence and does not belong in it.
    XCTAssertEqual(summary["localArtifact"], "trace.htrace")
    XCTAssertNil(summary.values.first { $0.contains(receiveRoot.path) })
  }

  /// A clean exit with no file is the pre-D4 failure mode: it used to reach
  /// `.verified` through a record ID nothing in the HDC path ever set.
  func testTransferThatLandsNowhereIsUnknownNotVerified() throws {
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"),
      maximumBytes: 64 * 1024)
    try landing.prepareDestination()

    let outcome = try provider.verify(
      receipt: receipt(landing: landing), action: .hdc(.receiveOwnedArtifact(try artifact())),
      context: context)
    guard case .unknown = outcome else {
      return XCTFail("a receive with no landed file must be unknown, got \(outcome)")
    }
  }

  func testEmptyReceivedFileFailsRatherThanPublishingZeroBytes() throws {
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"),
      maximumBytes: 64 * 1024)
    try landing.prepareDestination()
    try Data().write(to: landing.destination)

    let outcome = try provider.verify(
      receipt: receipt(landing: landing), action: .hdc(.receiveOwnedArtifact(try artifact())),
      context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("an empty received file must fail, got \(outcome)")
    }
    XCTAssertEqual(code, "emptyArtifact")
  }

  /// Over-budget bytes are refused without being hashed: the budget exists
  /// precisely so an unbounded file is never read end to end.
  func testOversizedReceiveFailsAndIsNeverDigested() throws {
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"), maximumBytes: 8)
    try landing.prepareDestination()
    try Data(repeating: 0x61, count: 4096).write(to: landing.destination)

    let landed = try XCTUnwrap(landing.inspectLanded())
    XCTAssertEqual(landed.byteCount, 4096)
    XCTAssertNil(landed.sha256, "an over-budget file must not be digested")

    let outcome = try provider.verify(
      receipt: receipt(landing: landing),
      action: .hdc(.receiveOwnedArtifact(try artifact(maximumBytes: 8))),
      context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("an oversized receive must fail, got \(outcome)")
    }
    XCTAssertEqual(code, "oversizedArtifact")
  }

  /// The pinned-hash branch used to copy the expectation into the summary
  /// and call that verification. Bytes that do not match must fail.
  func testPinnedHashMismatchFails() throws {
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"),
      maximumBytes: 64 * 1024)
    try landing.prepareDestination()
    try Data("not-the-pinned-bytes".utf8).write(to: landing.destination)

    let pinned = sha256Hex(Data("the-pinned-bytes".utf8))
    let outcome = try provider.verify(
      receipt: receipt(landing: landing),
      action: .hdc(.receiveOwnedArtifact(try artifact(expectedSHA256: pinned))),
      context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("a hash mismatch must fail, got \(outcome)")
    }
    XCTAssertEqual(code, "hashMismatch")
  }

  func testPinnedHashMatchVerifies() throws {
    let payload = Data("the-pinned-bytes".utf8)
    let landing = HostLandingExpectation(
      destination: receiveRoot.appendingPathComponent("trace.htrace"),
      maximumBytes: 64 * 1024)
    try landing.prepareDestination()
    try payload.write(to: landing.destination)

    let outcome = try provider.verify(
      receipt: receipt(landing: landing),
      action: .hdc(.receiveOwnedArtifact(try artifact(expectedSHA256: sha256Hex(payload)))),
      context: context)
    guard case .verified = outcome else {
      return XCTFail("matching bytes must verify, got \(outcome)")
    }
  }

  // MARK: - The capture leg's device-side readback

  private func traceAction() throws -> TypedProviderAction {
    .hdc(
      .captureTrace(
        try HDCTraceCaptureRequest(durationSeconds: 5, categories: ["ohos"]),
        into: try HDCOwnedRemotePath(
          jobID: "job-receive-1", stepID: "capture-trace", nonce: "n1")))
  }

  private func captureReceipt(listing: String, exit: Int32 = 0) -> ProviderProcessReceipt {
    func sub(_ stdout: String, exit: Int32 = 0) -> ProviderSubprocessReceipt {
      ProviderSubprocessReceipt(
        exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.02,
      subprocesses: [sub("", exit: exit), sub(listing)])
  }

  /// `hdc shell` reports the client's exit status, not the remote command's,
  /// so a clean hitrace exit is worth nothing. The listing decides.
  func testTraceVerdictComesFromTheListingNotTheCaptureExitStatus() throws {
    let verified = try provider.verify(
      receipt: captureReceipt(
        listing: "-rw-r--r-- 1 root root 4096 2026-07-31 00:00 /data/local/tmp/t.htrace\n",
        exit: 1),
      action: try traceAction(), context: context)
    guard case .verified(let summary) = verified else {
      return XCTFail("a written trace must verify even when hitrace exits non-zero, got \(verified)")
    }
    XCTAssertEqual(summary["remoteByteCount"], "4096")

    let cleanExitNoFile = try provider.verify(
      receipt: captureReceipt(
        listing: "ls: /data/local/tmp/t.htrace: No such file or directory\n"),
      action: try traceAction(), context: context)
    guard case .unknown = cleanExitNoFile else {
      return XCTFail("a clean exit with no file cannot be a verdict, got \(cleanExitNoFile)")
    }
  }

  func testZeroByteTraceIsAFailureNotAnEmptyArtifact() throws {
    let outcome = try provider.verify(
      receipt: captureReceipt(
        listing: "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/t.htrace\n"),
      action: try traceAction(), context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("a zero-byte trace must fail, got \(outcome)")
    }
    XCTAssertEqual(code, "emptyTrace")
  }

  func testNonRegularOrMissingReadbackStaysUnknown() throws {
    for listing in [
      "drwxr-xr-x 2 root root 4096 2026-07-31 00:00 /data/local/tmp\n",
      "\n",
      "-rw-r--r-- 1 root root\n",
    ] {
      let outcome = try provider.verify(
        receipt: captureReceipt(listing: listing), action: try traceAction(),
        context: context)
      guard case .unknown = outcome else {
        return XCTFail("unreadable listing \(listing.debugDescription) gave \(outcome)")
      }
    }
  }

  /// Without both invocations there is no readback to judge, and a truncated
  /// listing is not a listing.
  func testMissingOrTruncatedReadbackStaysUnknown() throws {
    let single = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.01)
    guard case .unknown = try provider.verify(
      receipt: single, action: try traceAction(), context: context)
    else {
      return XCTFail("a capture with no readback sequence must be unknown")
    }

    let truncated = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.02,
      subprocesses: [
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01),
        ProviderSubprocessReceipt(
          exitStatus: 0,
          stdout: Data("-rw-r--r-- 1 root root 4096 2026".utf8), stderr: Data(),
          stdoutTruncated: true, durationSeconds: 0.01),
      ])
    guard case .unknown = try provider.verify(
      receipt: truncated, action: try traceAction(), context: context)
    else {
      return XCTFail("a truncated listing must not be parsed as a size")
    }
  }

  // MARK: - Through the production dispatcher and a real child process

  /// The whole leg for real: the descriptor-bound dispatcher spawns a child
  /// that writes the file, and the receipt carries what the host measured.
  /// Fixture knobs travel as explicit child environment: the spawn base
  /// allowlist drops everything a test process merely exports.
  func testDispatchedReceiveMeasuresTheFileTheChildWrote() async throws {
    let payload = "bytes-from-a-real-child"
    let (dispatcher, plan) = try makeDispatchedPlan(
      childEnvironment: ["ARKDECK_FAKE_HDC_RECV_PAYLOAD": payload])

    let receipt = try await dispatcher.dispatch(plan)
    let landed = try XCTUnwrap(receipt.landedArtifact)
    XCTAssertEqual(landed.byteCount, payload.utf8.count)
    XCTAssertEqual(landed.sha256, sha256Hex(Data(payload.utf8)))
    XCTAssertEqual(
      try Data(contentsOf: landed.localURL), Data(payload.utf8),
      "the receipt must describe the bytes on disk, not the transfer banner")
    XCTAssertNotEqual(
      receipt.stdout, Data(payload.utf8),
      "stdout is hdc's progress line and must never stand in for the product")
  }

  func testDispatchedReceiveThatLandsNowhereCarriesNoArtifact() async throws {
    let (dispatcher, plan) = try makeDispatchedPlan(
      childEnvironment: ["ARKDECK_FAKE_HDC_RECV_MODE": "nothing"])

    let receipt = try await dispatcher.dispatch(plan)
    XCTAssertEqual(receipt.exitStatus, 0, "hdc exits cleanly even when nothing lands")
    XCTAssertNil(receipt.landedArtifact)
  }

  /// A leftover file from an earlier attempt must not be inspected as though
  /// this transfer had produced it.
  func testStaleFileFromAnEarlierAttemptCannotPassAsThisTransfer() async throws {
    let (dispatcher, plan) = try makeDispatchedPlan(
      childEnvironment: ["ARKDECK_FAKE_HDC_RECV_MODE": "nothing"])
    let destination = try XCTUnwrap(plan.hostLanding?.destination)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("stale-bytes-from-attempt-1".utf8).write(to: destination)

    let receipt = try await dispatcher.dispatch(plan)
    XCTAssertNil(
      receipt.landedArtifact,
      "the stale file must be cleared before the transfer, not measured after it")
  }

  private func makeDispatchedPlan(
    childEnvironment: [String: String] = [:]
  ) throws -> (DescriptorBoundProcessDispatcher, TypedProcessPlan) {
    let fixture = productsDirectory.appendingPathComponent("ArkDeckFakeHDCFixture")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("ArkDeckFakeHDCFixture binary not built")
    }
    let dispatcher = DescriptorBoundProcessDispatcher(
      resolver: try FixedExecutableResolver.hashing(path: fixture.path, providerID: "hdc"),
      childEnvironment: childEnvironment)
    let plan = try provider.lower(
      action: .hdc(.receiveOwnedArtifact(try artifact())), context: context)
    return (dispatcher, plan)
  }

  private func receipt(landing: HostLandingExpectation) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("FileTransfer finish, Size:0\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.01,
      landedArtifact: landing.inspectLanded())
  }
}
