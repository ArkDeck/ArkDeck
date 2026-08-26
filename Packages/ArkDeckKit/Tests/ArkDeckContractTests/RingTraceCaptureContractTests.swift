import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Ring-buffered trace capture (TASK-IDC-003 stage 1).
///
/// `hitrace -t N` has to be started before the interesting thing and reports
/// only its own window. An armed ring can be snapshotted after it, and the
/// snapshot carries everything since the arm.
///
/// How far back a snapshot reaches is not a property of arming - measured on
/// the device, one dump reached 25.6s before its marker and another 0.06s,
/// depending on what the kernel buffer already held. That is why the anchor
/// exists, and why these tests pin the anchor's order rather than a window.
final class RingTraceCaptureContractTests: XCTestCase {
  private let hdc = HDCObservationProviderAdapter(factsPort: RingFactsPort())

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-ring-1", stepID: "capture-trace", targetID: "TGT-1",
      bindingRevision: 1, connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "b", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-08-25T00:00:00Z")
  }

  private func lowered(
    ringBuffered: Bool, anchor: String? = "ARKDECKANCHORjobring1capturetrace"
  ) throws -> [[String]] {
    let path = try hdc.mintOwnedRemotePath(jobID: "job-ring-1", stepID: "capture-trace")
    let request = try HDCTraceCaptureRequest(
      durationSeconds: 5, categories: ["ohos", "graphic"], bufferKB: 20480,
      ringBuffered: ringBuffered, coverageAnchor: ringBuffered ? anchor : nil)
    let plan = try hdc.lower(action: .hdc(.captureTrace(request, into: path)), context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      throw XCTSkip("the trace leg lowers to a sequence")
    }
    return invocations.map(\.arguments)
  }

  /// The three segments, in the order that makes the snapshot mean anything:
  /// arm, wait, snapshot, stop. `--trace_finish_nodump` rather than
  /// `--trace_finish`, because the snapshot above is the product and a second
  /// dump would write a copy nobody asked for.
  func testTheRingIsArmedSnapshotAndThenStopped() throws {
    let argv = try lowered(ringBuffered: true)
    let verbs = argv.compactMap { line -> String? in
      line.first(where: { $0.hasPrefix("--trace_") || $0 == "sleep" || $0 == "ls" })
    }
    XCTAssertEqual(
      verbs, ["--trace_begin", "sleep", "--trace_dump", "--trace_finish_nodump", "ls"])
  }

  /// `--overwrite` reads like the ring behaviour and means the opposite: with
  /// it the *newest* traces are discarded, and the default is what drops the
  /// oldest. A lowering written from the flag name would keep the first
  /// seconds of a session and throw away the part worth capturing.
  func testTheRingNeverPassesOverwrite() throws {
    let argv = try lowered(ringBuffered: true)
    for line in argv {
      XCTAssertFalse(
        line.contains("--overwrite"),
        "--overwrite discards the newest traces, which is the opposite of a ring")
    }
  }

  /// The anchor is written into the device's own marker sink and read straight
  /// back out of the ring. The write alone would only say the command ran; the
  /// readback says the ring is live and holding it, and the anchor's later
  /// presence in the dump is what proves how far back the snapshot reaches -
  /// a check that needs no trace decoder, only a string search.
  func testTheCoverageAnchorIsWrittenAndReadBackBeforeTheWindow() throws {
    let argv = try lowered(ringBuffered: true)
    let joined = argv.map { $0.joined(separator: " ") }
    let write = try XCTUnwrap(joined.firstIndex { $0.contains("trace_marker") })
    let read = try XCTUnwrap(joined.firstIndex { $0.contains("grep -c") })
    let window = try XCTUnwrap(joined.firstIndex { $0.contains("sleep") })
    XCTAssertLessThan(write, read, "the readback has to follow the write")
    XCTAssertLessThan(
      read, window,
      "a ring that was not confirmed live before the window cannot be trusted after it")
    XCTAssertTrue(joined[write].contains("ARKDECKANCHOR"))
    XCTAssertTrue(joined[read].contains("ARKDECKANCHOR"))
  }

  /// Measured: passing the redirect as its own argv element does not redirect
  /// on this path - the text comes back on stdout and the file is never
  /// written. The marker write is therefore one line, and the anchor is
  /// bounded to letters and digits so there is nothing in it for a shell to
  /// reinterpret.
  func testTheMarkerWriteIsOneLineAndCarriesNothingAShellWouldReread() throws {
    let argv = try lowered(ringBuffered: true)
    let write = try XCTUnwrap(argv.first { $0.contains(where: { $0.contains("trace_marker") }) })
    let line = try XCTUnwrap(write.last)
    XCTAssertTrue(line.hasPrefix("echo ARKDECKANCHOR"))
    XCTAssertTrue(line.contains("> /sys/kernel/tracing/trace_marker"))
    XCTAssertFalse(
      line.contains(";") || line.contains("|") || line.contains("$") || line.contains("`"))
  }

  func testAnAnchorIsRefusedUnlessItIsARingCaptureAndABoundedIdentifier() {
    XCTAssertThrowsError(
      try HDCTraceCaptureRequest(
        durationSeconds: 5, categories: ["ohos"], ringBuffered: false,
        coverageAnchor: "ARKDECKANCHORabc"),
      "a blocking capture has no ring to anchor")
    for bad in ["ARKDECK ANCHOR", "ARKDECK;rm", "short", String(repeating: "x", count: 65)] {
      XCTAssertThrowsError(
        try HDCTraceCaptureRequest(
          durationSeconds: 5, categories: ["ohos"], ringBuffered: true, coverageAnchor: bad),
        "\(bad) must not reach a shell line")
    }
  }

  /// The blocking shape stays exactly as it was: a caller who does not ask for
  /// a ring gets the capture they already had.
  func testTheBlockingCaptureIsUnchanged() throws {
    let argv = try lowered(ringBuffered: false)
    XCTAssertEqual(argv.count, 2)
    XCTAssertTrue(argv[0].contains("-t"))
    XCTAssertTrue(argv[0].contains("hitrace"))
    XCTAssertFalse(argv[0].contains("--trace_begin"))
    XCTAssertTrue(argv[1].contains("ls"))
  }

  private func receipt(_ outputs: [String]) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0,
      subprocesses: outputs.map {
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data($0.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0)
      })
  }

  private func verdict(
    _ outputs: [String], ringBuffered: Bool = true,
    anchor: String? = "ARKDECKANCHORjobring1capturetrace"
  ) throws -> ProviderSemanticOutcome {
    let path = try hdc.mintOwnedRemotePath(jobID: "job-ring-1", stepID: "capture-trace")
    let request = try HDCTraceCaptureRequest(
      durationSeconds: 5, categories: ["ohos"], ringBuffered: ringBuffered,
      coverageAnchor: ringBuffered ? anchor : nil)
    return try hdc.verify(
      receipt: receipt(outputs), action: .hdc(.captureTrace(request, into: path)),
      context: context)
  }

  private var ringOutputs: [String] {
    ["OpenRecording done", "", "1", "", "trace read done", "end capture trace"]
  }

  /// The ring runs more invocations than the blocking shape and its readback
  /// is the last of them. Judging by a fixed index left every ring capture
  /// unknown - found by running one on the device, because the argv the tests
  /// above pin was right and the verdict reading it was not.
  func testTheRingIsJudgedByItsLastReadbackNotAFixedIndex() throws {
    var outputs = ringOutputs
    outputs.append("-rw-r--r-- 1 root root 7039 2017-08-27 06:30 /data/local/tmp/t.trace")
    guard case .verified(let summary) = try verdict(outputs) else {
      return XCTFail("a ring that wrote a trace is verified: \(try verdict(outputs))")
    }
    XCTAssertEqual(summary["remoteByteCount"], "7039")
    XCTAssertEqual(summary["ringHeldCoverageAnchor"], "true")
    XCTAssertEqual(summary["coverageAnchor"], "ARKDECKANCHORjobring1capturetrace")
  }

  /// The anchor readback is in the receipt, so whether the ring was holding it
  /// is a fact the verdict already has. Recording an anchor without checking
  /// it would publish a coverage claim nobody verified.
  func testARingThatWasNotHoldingTheAnchorSaysSo() throws {
    var outputs = ringOutputs
    outputs[2] = "0"
    outputs.append("-rw-r--r-- 1 root root 7039 2017-08-27 06:30 /data/local/tmp/t.trace")
    guard case .verified(let summary) = try verdict(outputs) else {
      return XCTFail("the trace was still written; only its coverage is in doubt")
    }
    XCTAssertEqual(summary["ringHeldCoverageAnchor"], "false")
  }

  func testARingThatNeverAnsweredTheAnchorReadbackIsUnknown() throws {
    var outputs = ringOutputs
    outputs[2] = ""
    outputs.append("-rw-r--r-- 1 root root 7039 2017-08-27 06:30 /data/local/tmp/t.trace")
    guard case .unknown = try verdict(outputs) else {
      return XCTFail("a ring that did not answer cannot be reported as covered")
    }
  }

  func testAShortSequenceIsStillUnknown() throws {
    guard case .unknown = try verdict(["OpenRecording done", "1"]) else {
      return XCTFail("a truncated sequence is not a capture")
    }
  }

  /// The verdict counts the invocations it expects, and the lowering decides
  /// how many there are. Those two drifting apart is what left every ring
  /// capture unknown once already, so they are tied together here: add a
  /// segment to the ring and this fails until the verdict is told.
  func testTheVerdictAndTheLoweringAgreeOnHowManySegmentsARingHas() throws {
    for anchored in [true, false] {
      let argv = try lowered(ringBuffered: true, anchor: anchored ? "ARKDECKANCHORdrift" : nil)
      var outputs = Array(repeating: "", count: argv.count)
      if anchored, outputs.count > 2 { outputs[2] = "1" }
      outputs[outputs.count - 1] =
        "-rw-r--r-- 1 root root 512 2017-08-27 06:30 /data/local/tmp/t.trace"
      let path = try hdc.mintOwnedRemotePath(jobID: "job-ring-1", stepID: "capture-trace")
      let request = try HDCTraceCaptureRequest(
        durationSeconds: 5, categories: ["ohos", "graphic"], bufferKB: 20480,
        ringBuffered: true, coverageAnchor: anchored ? "ARKDECKANCHORdrift" : nil)
      let outcome = try hdc.verify(
        receipt: receipt(outputs), action: .hdc(.captureTrace(request, into: path)),
        context: context)
      guard case .verified = outcome else {
        return XCTFail(
          "the verdict expects a different number of segments than the lowering emits "
            + "(anchored: \(anchored), emitted: \(argv.count)): \(outcome)")
      }
    }
  }

  /// Every invocation in the ring reaches the device, so every one of them has
  /// to name the target it reaches.
  func testEveryRingInvocationIsTargetBound() throws {
    for line in try lowered(ringBuffered: true) {
      guard let index = line.firstIndex(of: "-t") else {
        return XCTFail("a ring invocation reached the device unbound: \(line)")
      }
      XCTAssertEqual(line[line.index(after: index)], "150100424a544e4600")
    }
  }
}

private struct RingFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64),
      serverFacts: ["endpoint": "127.0.0.1:8710"],
      deviceIdentitySHA256: String(repeating: "b", count: 64),
      deviceMode: "hdc", buildFingerprint: "fixture-build",
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-08-25T00:00:00Z")
  }
}
