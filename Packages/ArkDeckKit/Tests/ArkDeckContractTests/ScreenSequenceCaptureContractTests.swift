import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

/// A bounded run of stills, because the platform offers nothing better
/// (TASK-IDC-002, recorded gap 2 of 5).
///
/// Measured on the device on 2026-08-26, and the reason this shape exists at
/// all: `/system/bin` ships no recorder; `uitest uiRecord` records UI events
/// into a CSV rather than pixels; and the real capability
/// (`libnative_avscreen_capture.so`) is an in-app API whose permission
/// `ohos.permission.CAPTURE_SCREEN` the device's own permission_definitions
/// declares `system_core` / `system_grant`, so no side-loaded app can hold it
/// and no shell can reach it.
///
/// What is reachable is one still at a time: 543 ms/frame for JPEG at
/// 720x1280, 537 ms at 360x640, 765 ms for PNG, over 20 frames each. The cost
/// is the display readback, which is why scaling down saves nothing and why
/// the rate is reported rather than promised.
final class ScreenSequenceCaptureContractTests: XCTestCase {
  private var hdc: HDCObservationProviderAdapter {
    HDCObservationProviderAdapter(factsPort: SequenceFactsPort())
  }

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-seq", stepID: "capture-screen-sequence", targetID: "TGT-1",
      bindingRevision: 1, connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "b", count: 64),
      nowUTC: "2026-08-26T00:00:00Z")
  }

  private var descriptor: CatalogOperationDescriptor {
    get throws {
      try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "capture.screen-sequence@1"))
    }
  }

  private func captureStep() throws -> CatalogStepDescriptor {
    try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-screen-sequence" })
  }

  private func inputs(frames: Int, type: String = "jpeg") -> [String: JSONValue] {
    ["frameCount": .integer(Int64(frames)), "imageType": .string(type)]
  }

  private func invocations(of plan: TypedProcessPlan) throws -> [[String]] {
    guard case .processSequence(_, let invocations) = plan.kind else {
      throw SequenceTestFailure.notASequence
    }
    return invocations.map(\.arguments)
  }

  // MARK: - The lowering

  /// One typed invocation per frame, and no shell fragment anywhere. A device
  /// loop would save 54 ms a frame (543 against 597, measured) and cost the
  /// property that every argument is a bounded token this provider chose.
  func testEveryFrameIsItsOwnTypedInvocationWithNoShellFragment() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 4),
      context: context)
    let plan = try hdc.lower(action: action, context: context)
    let arguments = try invocations(of: plan)
    XCTAssertEqual(
      arguments.count, 1 + 4 + 2,
      "mkdir, one per frame, tar, readback")
    for argv in arguments {
      for token in argv {
        XCTAssertFalse(
          token.contains(";") || token.contains("&&") || token.contains("|")
            || token.contains("$(") || token.contains("`"),
          "no argument may carry anything a shell would reinterpret: \(token)")
      }
    }
  }

  /// The suffix rule, which is not cosmetic and is not a retry: the device
  /// refuses a name whose suffix disagrees with `-t` and exits fast enough to
  /// look like success. Measured again on 2026-08-26 while timing this leg -
  /// a run against extensionless names produced twenty refusals in 10.7s and
  /// no files, and would have been read as a capture at 1.86 fps.
  func testTheRequestedTypeAndEveryFrameSuffixAgree() throws {
    for type in ["png", "jpeg"] {
      let action = try hdc.action(
        for: try captureStep(), operation: try descriptor,
        inputs: inputs(frames: 3, type: type), context: context)
      let arguments = try invocations(of: try hdc.lower(action: action, context: context))
      let captures = arguments.filter { $0.contains("snapshot_display") }
      XCTAssertEqual(captures.count, 3)
      for whole in captures {
        // hdc carries its own `-t <connectKey>` ahead of the remote command,
        // so the capture's flags are the ones after the program name.
        let argv = Array(whole[try XCTUnwrap(whole.firstIndex(of: "snapshot_display"))...])
        let requested = try XCTUnwrap(argv.firstIndex(of: "-t").map { argv[$0 + 1] })
        let path = try XCTUnwrap(argv.firstIndex(of: "-f").map { argv[$0 + 1] })
        XCTAssertEqual(requested, type)
        XCTAssertTrue(
          path.hasSuffix("." + type),
          "\(path) would be refused for a \(type) capture")
      }
    }
  }

  /// Frames are named by index, never by anything a caller supplied, and the
  /// zero padding makes the archive's own ordering the capture order.
  func testFramesAreNamedByIndexInCaptureOrder() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 11),
      context: context)
    let arguments = try invocations(of: try hdc.lower(action: action, context: context))
    let names = arguments.filter { $0.contains("snapshot_display") }
      .compactMap { whole -> String? in
        guard let start = whole.firstIndex(of: "snapshot_display") else { return nil }
        let argv = Array(whole[start...])
        return argv.firstIndex(of: "-f").map { (argv[$0 + 1] as NSString).lastPathComponent }
      }
    XCTAssertEqual(names.first, "0001.jpeg")
    XCTAssertEqual(names.last, "0011.jpeg")
    XCTAssertEqual(names, names.sorted(), "the archive order must be the capture order")
  }

  /// A lone dimension is refused rather than sent: the device would pick the
  /// other one, and frames of differing size compose into nothing.
  func testAHalfScaledRequestIsRefused() {
    XCTAssertThrowsError(
      try HDCScreenSequenceRequest(frameCount: 4, width: 360, height: nil))
    XCTAssertThrowsError(
      try HDCScreenSequenceRequest(frameCount: 4, width: nil, height: 640))
  }

  func testTheRunIsBounded() {
    XCTAssertThrowsError(try HDCScreenSequenceRequest(frameCount: 1))
    XCTAssertThrowsError(
      try HDCScreenSequenceRequest(frameCount: HDCScreenSequenceRequest.maximumFrames + 1))
  }

  // MARK: - The verdict

  private func receipt(
    frames: Int, failing: Set<Int> = [], archiveBytes: Int, frameSeconds: Double = 0.543
  ) -> ProviderProcessReceipt {
    func sub(_ stdout: String, exit: Int32 = 0, seconds: Double) -> ProviderSubprocessReceipt {
      ProviderSubprocessReceipt(
        exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(), stdoutTruncated: false,
        durationSeconds: seconds)
    }
    var subs = [sub("", seconds: 0.01)]
    for index in 0..<frames {
      subs.append(sub("", exit: failing.contains(index) ? 1 : 0, seconds: frameSeconds))
    }
    subs.append(sub("", seconds: 0.05))
    subs.append(
      sub(
        "-rw-r--r-- 1 root root \(archiveBytes) 2026-08-26 00:00 "
          + "/data/local/tmp/arkdeck-job-seq-capture-screen-sequence-owned.tar\n",
        seconds: 0.01))
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
      durationSeconds: 1, subprocesses: subs)
  }

  /// The `ls -l` readback decides the step, not the captures' exit codes -
  /// the same rule every other file leg carries.
  func testTheArchiveReadbackIsWhatDecidesTheStep() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 5),
      context: context)
    guard
      case .verified(let summary) = try hdc.verify(
        receipt: receipt(frames: 5, archiveBytes: 210_432), action: action, context: context)
    else { return XCTFail("a readback describing a non-empty archive is a verified capture") }
    XCTAssertEqual(summary["remoteByteCount"], "210432")
  }

  func testAZeroByteArchiveIsAFailureNotAnArtifact() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 5),
      context: context)
    guard
      case .failed(let code, _) = try hdc.verify(
        receipt: receipt(frames: 5, archiveBytes: 0), action: action, context: context)
    else { return XCTFail("an empty archive is not a sequence") }
    XCTAssertEqual(code, "emptyScreenSequence")
  }

  /// The expected subprocess count is derived from the request, not written
  /// down. A hard-coded count is exactly how the single-still leg once
  /// returned unknown for every ring capture: it expected 2 and got 7.
  func testAShapeThatDoesNotMatchTheRequestIsUnknownRatherThanGuessedAt() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 5),
      context: context)
    guard
      case .unknown = try hdc.verify(
        receipt: receipt(frames: 4, archiveBytes: 210_432), action: action, context: context)
    else { return XCTFail("a receipt for four frames cannot decide a five-frame capture") }
  }

  /// A frame that failed is a gap in the sequence, not the end of it, and the
  /// count that was actually captured travels rather than being rounded up to
  /// what was asked for.
  func testAFailedFrameIsReportedAsAGapNotAsAFullRun() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 6),
      context: context)
    guard
      case .verified(let summary) = try hdc.verify(
        receipt: receipt(frames: 6, failing: [2, 4], archiveBytes: 160_000),
        action: action, context: context)
    else { return XCTFail("four good frames out of six are still a sequence") }
    XCTAssertEqual(summary["requestedFrameCount"], "6")
    XCTAssertEqual(summary["capturedFrameCount"], "4")
  }

  /// The rate is measured, never claimed. This is the number the workspace
  /// shows, and at 543 ms a frame it is about 1.8 - which is why the product
  /// says what it achieved rather than implying a video rate.
  func testTheRateIsReadOffWhatWasObserved() throws {
    let action = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 10),
      context: context)
    guard
      case .verified(let summary) = try hdc.verify(
        receipt: receipt(frames: 10, archiveBytes: 410_000, frameSeconds: 0.543),
        action: action, context: context)
    else { return XCTFail("expected a verified capture") }
    XCTAssertEqual(summary["observedFramesPerSecond"], "1.84")
    XCTAssertEqual(
      summary["frameDurationsSeconds"]?.split(separator: ",").count, 10,
      "every frame's own duration travels, because the composed timeline is "
        + "built from what was observed rather than from an assumed cadence")
  }

  // MARK: - Cleanup

  /// Cleanup names exactly the frames this provider wrote and then `rmdir`s -
  /// never `rm -rf`. `rmdir` refuses a directory that still holds something,
  /// so a cleanup that did not fully clean reports rather than deleting what
  /// it was not asked to.
  func testCleanupNamesOnlyWhatTheCaptureWroteAndNeverRecurses() throws {
    let cleanupStep = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "cleanup-screen-sequence-temp" })
    let action = try hdc.action(
      for: cleanupStep, operation: try descriptor, inputs: inputs(frames: 7), context: context)
    let arguments = try invocations(of: try hdc.lower(action: action, context: context))
    let removals = try XCTUnwrap(arguments.first { $0.contains("rm") })
    XCTAssertFalse(removals.contains("-rf"), "cleanup must not recurse")
    XCTAssertEqual(
      removals.filter { $0.hasSuffix(".jpeg") }.count, 7,
      "exactly the frames this capture wrote, by name")
    XCTAssertTrue(arguments.contains { $0.contains("rmdir") })
    XCTAssertFalse(
      arguments.contains { $0.contains("find") || $0.contains("*") },
      "nothing here reads the directory back to decide what to delete")
  }

  /// The directory being gone is the proof, not `rmdir` exiting zero.
  func testCleanupIsDecidedByTheDirectoryBeingGone() throws {
    let cleanupStep = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "cleanup-screen-sequence-temp" })
    let action = try hdc.action(
      for: cleanupStep, operation: try descriptor, inputs: inputs(frames: 3), context: context)
    // HDC reports its own transport status, not the remote command's, so an
    // `ls` on a path that is gone still exits 0. Only the listing grammar can
    // decide, which is why these fixtures carry stdout rather than a code.
    func listing(_ stdout: String) -> ProviderProcessReceipt {
      func sub(_ text: String) -> ProviderSubprocessReceipt {
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data(text.utf8), stderr: Data(), stdoutTruncated: false,
          durationSeconds: 0.01)
      }
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.04, subprocesses: [sub(""), sub(""), sub(""), sub(stdout)])
    }
    let directory = "/data/local/tmp/arkdeck-job-seq-capture-screen-sequence-owned-frames"
    guard
      case .verified = try hdc.verify(
        receipt: listing("ls: \(directory): No such file or directory\n"),
        action: action, context: context)
    else { return XCTFail("a listing that finds nothing is a clean cleanup") }
    guard
      case .failed(let code, _) = try hdc.verify(
        receipt: listing("drwxr-xr-x 2 root root 3452 2026-08-26 00:00 \(directory)\n"),
        action: action, context: context)
    else { return XCTFail("a directory still listed after cleanup is residue") }
    XCTAssertEqual(code, "sequenceCleanupResidue")
    // A readback nothing can parse is unknown, never a quiet success: the
    // engine keeps the intent outstanding for reconcile rather than guessing.
    guard
      case .unknown = try hdc.verify(
        receipt: listing("something else entirely\n"), action: action, context: context)
    else { return XCTFail("an unparseable listing cannot decide a cleanup") }
  }

  /// The capture and its cleanup derive their paths from the same inputs, so
  /// the cleanup cannot end up naming a directory the capture never wrote.
  func testCaptureAndCleanupAgreeOnEveryOwnedPath() throws {
    let capture = try hdc.action(
      for: try captureStep(), operation: try descriptor, inputs: inputs(frames: 5),
      context: context)
    let cleanup = try hdc.action(
      for: try XCTUnwrap(descriptor.steps.first { $0.stepID == "cleanup-screen-sequence-temp" }),
      operation: try descriptor, inputs: inputs(frames: 5), context: context)
    guard case .hdc(.captureScreenSequence(_, let capturedFrames, let capturedArchive)) = capture,
      case .hdc(.cleanupScreenSequence(_, let cleanedFrames, let cleanedArchive)) = cleanup
    else { return XCTFail("both steps must lower to the sequence actions") }
    XCTAssertEqual(capturedFrames, cleanedFrames)
    XCTAssertEqual(capturedArchive, cleanedArchive)
  }
}

private enum SequenceTestFailure: Error { case notASequence }

private struct SequenceFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "b", count: 64),
      serverFacts: ["endpoint": "127.0.0.1:8710"],
      deviceIdentitySHA256: String(repeating: "a", count: 64),
      deviceMode: "hdc", buildFingerprint: "fixture-build",
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-08-26T00:00:00Z")
  }
}
