import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class HDCE0ActionPackContractTests: XCTestCase {
  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        deviceIdentitySHA256: nil, deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private var provider: HDCObservationProviderAdapter {
    HDCObservationProviderAdapter(factsPort: FactsPort())
  }

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-1", stepID: "step-1", targetID: "TGT-1", bindingRevision: 1,
      connectKey: "150100424a544e4600",
      nowUTC: "2026-07-29T00:00:00Z")
  }

  // MARK: - Bounds and defaults

  func testHilogRequestBounds() throws {
    XCTAssertNoThrow(try HDCHilogCaptureRequest(durationSeconds: 1))
    XCTAssertNoThrow(try HDCHilogCaptureRequest(durationSeconds: 600))
    XCTAssertThrowsError(try HDCHilogCaptureRequest(durationSeconds: 0))
    XCTAssertThrowsError(try HDCHilogCaptureRequest(durationSeconds: 601))
    XCTAssertThrowsError(
      try HDCHilogCaptureRequest(
        durationSeconds: 10, filters: Array(repeating: "*:E", count: 17)))
    XCTAssertThrowsError(try HDCHilogCaptureRequest(durationSeconds: 10, byteBudget: 1023))
    // Shell fragments in filters are rejected outright.
    for hostile in ["*:E; rm -rf /", "$(whoami)", "a`b`", "x|y", "a&&b"] {
      XCTAssertThrowsError(
        try HDCHilogCaptureRequest(durationSeconds: 10, filters: [hostile]), hostile)
    }
    let defaulted = try HDCHilogCaptureRequest(durationSeconds: 5)
    XCTAssertEqual(defaulted.byteBudget, 16 * 1024 * 1024, "budget has a bounded default")
  }

  func testTraceAndUIDumpBounds() throws {
    XCTAssertNoThrow(try HDCTraceCaptureRequest(durationSeconds: 5, categories: ["ohos"]))
    XCTAssertThrowsError(try HDCTraceCaptureRequest(durationSeconds: 5, categories: []))
    XCTAssertThrowsError(
      try HDCTraceCaptureRequest(
        durationSeconds: 5, categories: Array(repeating: "ohos", count: 25)))
    XCTAssertThrowsError(
      try HDCTraceCaptureRequest(durationSeconds: 5, categories: ["ohos; reboot"]))
    XCTAssertThrowsError(
      try HDCTraceCaptureRequest(durationSeconds: 5, categories: ["ohos"], bufferKB: 100))
    XCTAssertThrowsError(try HDCUIDumpRequest(byteBudget: 10))
    // r2: the default is the only scope a stdout UI dump can honestly have.
    XCTAssertEqual(try HDCUIDumpRequest().scope, .windowList)
    XCTAssertEqual(HDCUIDumpRequest.Scope.allCases, [.windowList])
  }

  func testPropertyQueriesAreAllowlisted() {
    // The type system is the allowlist: the enum has no raw-key case, so a
    // caller cannot express an unlisted property at all.
    XCTAssertEqual(HDCAllowlistedProperty.allCases.count, 6)
    for property in HDCAllowlistedProperty.allCases {
      XCTAssertTrue(
        property.rawValue.hasPrefix("const.") || property.rawValue.hasPrefix("ro."),
        property.rawValue)
    }
  }

  // MARK: - Provider-owned remote temp paths

  func testRemoteTempPathsAreProviderOwnedAndCollisionFree() throws {
    let adapter = provider
    let first = try adapter.mintOwnedRemotePath(jobID: "job-1", stepID: "capture-trace")
    let second = try adapter.mintOwnedRemotePath(jobID: "job-1", stepID: "capture-trace")
    XCTAssertNotEqual(first.remotePath, second.remotePath, "nonce prevents collisions")
    for path in [first, second] {
      XCTAssertTrue(path.remotePath.hasPrefix("/data/local/tmp/arkdeck-"))
      XCTAssertTrue(path.remotePath.contains("job-1"))
      XCTAssertTrue(path.remotePath.contains("capture-trace"))
    }
    // A different job cannot land on another job's path.
    let otherJob = try adapter.mintOwnedRemotePath(jobID: "job-2", stepID: "capture-trace")
    XCTAssertFalse(otherJob.remotePath.contains("arkdeck-job-1-"))
    XCTAssertThrowsError(
      try adapter.mintOwnedRemotePath(jobID: "../escape", stepID: "capture-trace"))
  }

  func testRemoteTempPathRejectsAnOversizedFilesystemComponent() {
    XCTAssertThrowsError(
      try HDCOwnedRemotePath(
        jobID: String(repeating: "j", count: 128),
        stepID: String(repeating: "s", count: 128),
        nonce: String(repeating: "n", count: 128)))
  }

  func testCleanupOnlyAcceptsOwnedPathType() throws {
    // Structural: cleanupOwnedRemotePath takes HDCOwnedRemotePath, which
    // has no public initializer - a raw string cannot reach it. The
    // lowered plan therefore always references a provider-minted path.
    let path = try provider.mintOwnedRemotePath(jobID: "job-1", stepID: "cleanup")
    let plan = try provider.lower(
      action: .hdc(.cleanupOwnedRemotePath(path)), context: context)
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("cleanup lowers to a process plan")
    }
    XCTAssertEqual(argv.last, path.remotePath)
  }

  // MARK: - Verification grid

  func testDegenerateOutputsGetExplicitOutcomes() throws {
    let request = try HDCHilogCaptureRequest(durationSeconds: 5)
    let action = TypedProviderAction.hdc(.captureHilog(request))
    let truncated = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("partial".utf8), stderr: Data(),
      stdoutTruncated: true, durationSeconds: 1)
    guard case .failed(let code, _) = try provider.verify(
      receipt: truncated, action: action, context: context)
    else {
      return XCTFail("truncated capture must fail explicitly")
    }
    XCTAssertEqual(code, "truncated")

    let nonUTF8Hilog = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data([0xFF, 0xFE]), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 1)
    guard case .verified(let rawSummary) = try provider.verify(
      receipt: nonUTF8Hilog, action: action, context: context)
    else {
      return XCTFail("HiLog must preserve non-UTF-8 bytes as a sensitive raw artifact")
    }
    XCTAssertEqual(rawSummary["byteCount"], "2")

    let uiDumpAction = TypedProviderAction.hdc(
      .captureUIDump(try HDCUIDumpRequest(scope: .windowList)))
    guard case .failed(let invalidCode, _) = try provider.verify(
      receipt: nonUTF8Hilog, action: uiDumpAction, context: context)
    else {
      return XCTFail("invalid UTF-8 UI dump must fail explicitly")
    }
    XCTAssertEqual(invalidCode, "invalidEncoding")

    let empty = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1)
    guard case .unknown = try provider.verify(receipt: empty, action: action, context: context)
    else {
      return XCTFail("empty capture is unknown, never success")
    }

    let good = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("01-01 00:00:00 log line\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 1)
    guard case .verified(let summary) = try provider.verify(
      receipt: good, action: action, context: context)
    else {
      return XCTFail("a real capture must verify")
    }
    XCTAssertEqual(summary["byteCount"], "24")
  }

  func testPropertyVerificationRejectsEmptyAndOversized() throws {
    let action = TypedProviderAction.hdc(.queryProperty(.productModel))
    let empty = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("   \n".utf8), stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.1)
    guard case .unknown = try provider.verify(receipt: empty, action: action, context: context)
    else {
      return XCTFail("blank property output is unknown")
    }
    let good = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("DAYU200\n".utf8), stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.1)
    guard case .verified(let summary) = try provider.verify(
      receipt: good, action: action, context: context)
    else {
      return XCTFail("a property value must verify")
    }
    XCTAssertEqual(summary["value"], "DAYU200")
  }

  /// `param get` answers either bare or as `<key> = <value>` depending on the
  /// device build; the echoed key must never reach the summary as part of the
  /// value. Stripping is anchored on the requested key so a value that
  /// legitimately contains `=` survives intact.
  func testPropertyVerificationStripsOnlyTheRequestedParamKeyPrefix() throws {
    let action = TypedProviderAction.hdc(.queryProperty(.productModel))
    let cases: [(String, String)] = [
      ("DAYU200\n", "DAYU200"),
      ("const.product.model = DAYU200\n", "DAYU200"),
      ("const.product.model=DAYU200\n", "DAYU200"),
      ("  const.product.model\t=\tDAYU200  \n", "DAYU200"),
      // A different key is not this step's echo: keep it verbatim rather than
      // silently reinterpreting another property's answer.
      ("const.product.name = rk3568\n", "const.product.name = rk3568"),
      // Values carrying `=` must not be cut at the first one.
      ("YnVpbGQ=\n", "YnVpbGQ="),
      ("const.product.model = YnVpbGQ=\n", "YnVpbGQ="),
    ]
    for (stdout, expected) in cases {
      let receipt = ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.1)
      guard case .verified(let summary) = try provider.verify(
        receipt: receipt, action: action, context: context)
      else {
        return XCTFail("property output \(stdout.debugDescription) must verify")
      }
      XCTAssertEqual(
        summary["value"], expected,
        "unexpected value for stdout \(stdout.debugDescription)")
    }
  }

  func testArtifactReceiveAndCleanupAccounting() throws {
    let path = try provider.mintOwnedRemotePath(jobID: "job-1", stepID: "receive")
    let artifact = HDCOwnedRemoteArtifact(
      path: path, expectedSHA256: String(repeating: "b", count: 64), maximumBytes: 1024)
    let action = TypedProviderAction.hdc(.receiveOwnedArtifact(artifact))
    let withoutLocal = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1)
    guard case .unknown = try provider.verify(
      receipt: withoutLocal, action: action, context: context)
    else {
      return XCTFail("receive without a local artifact reference is unknown")
    }

    // Cleanup failure becomes explicit debt, never a silent success.
    let cleanupAction = TypedProviderAction.hdc(.cleanupOwnedRemotePath(path))
    let failedCleanup = ProviderProcessReceipt(
      exitStatus: 1, stdout: Data(), stderr: Data("no such file".utf8),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .failed(let code, _) = try provider.verify(
      receipt: failedCleanup, action: cleanupAction, context: context)
    else {
      return XCTFail("failed cleanup must be reported")
    }
    XCTAssertEqual(code, "cleanupDebt")
  }

  func testEffectClassification() throws {
    XCTAssertEqual(TypedProviderAction.hdc(.queryProperty(.productModel)).effect, .readOnly)
    XCTAssertEqual(
      TypedProviderAction.hdc(.captureHilog(try HDCHilogCaptureRequest(durationSeconds: 5)))
        .effect, .readOnly)
    XCTAssertEqual(TypedProviderAction.hdc(.captureUIDump(try HDCUIDumpRequest())).effect, .readOnly)
    let path = try provider.mintOwnedRemotePath(jobID: "job-1", stepID: "trace")
    XCTAssertEqual(
      TypedProviderAction.hdc(
        .captureTrace(
          try HDCTraceCaptureRequest(durationSeconds: 5, categories: ["ohos"]), into: path)
      ).effect, .deviceMutation,
      "writing a remote temp file is a bounded mutation, not read-only")
    XCTAssertEqual(
      TypedProviderAction.hdc(.cleanupOwnedRemotePath(path)).effect, .deviceMutation)
  }

  func testMutatingRemoteActionsDoNotReconcileWithoutEvidence() async throws {
    let path = try provider.mintOwnedRemotePath(jobID: "job-1", stepID: "trace")
    let reference = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "trace", intentEventID: "i",
      action: .hdc(.cleanupOwnedRemotePath(path)))
    guard case .stillUnknown = try await provider.reconcile(
      intent: reference, context: context)
    else {
      return XCTFail("owned-path mutation must not self-confirm")
    }
    let readOnly = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "property", intentEventID: "i",
      action: .hdc(.queryProperty(.productModel)))
    let readOnlyOutcome = try await provider.reconcile(intent: readOnly, context: context)
    XCTAssertEqual(readOnlyOutcome, .confirmedNotExecuted)
  }
}
