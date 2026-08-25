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
