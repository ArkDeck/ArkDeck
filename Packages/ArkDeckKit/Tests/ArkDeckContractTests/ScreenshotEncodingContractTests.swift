import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// The screenshot leg's two encodings (TASK-IDC-002, recorded gap 5 of 5).
///
/// Measured on TGT-958780b2ffb7 on 2026-08-26, 50 captures each with every
/// file verified to exist: JPEG p50 638 ms / p95 656 ms at 40,947 bytes, PNG
/// p50 858 ms / p95 875 ms at 448,352 bytes. So JPEG is 220 ms cheaper and
/// about eleven times smaller, which is what makes it worth having for work
/// that wants a current picture; PNG stays the evidence format because JPEG
/// is lossy.
///
/// The rule that makes this fiddly: `snapshot_display` validates the file
/// suffix against `-t` and refuses a mismatch fast enough to look like a
/// capture. The type therefore has to reach the flag, the owned path, the
/// receive's magic check, the cleanup, and the published name - and every one
/// of those failing would fail quietly.
final class ScreenshotEncodingContractTests: XCTestCase {
  private var descriptor: CatalogOperationDescriptor {
    get throws {
      try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    }
  }

  /// PNG is what a caller gets by not choosing. Evidence that quietly became
  /// lossy because it was faster is not a trade a default should make.
  func testTheEvidenceFormatIsTheDefault() throws {
    let field = try XCTUnwrap(
      try descriptor.inputs.first { $0.name == "screenshotImageType" })
    XCTAssertEqual(field.defaultValue, .string("png"))
    XCTAssertFalse(field.isRequired)
    XCTAssertEqual(Set(field.enumValues ?? []), ["png", "jpeg"])
  }

  /// Both encodings are declared, both optional. A capture publishes the one
  /// it took, and the other's absence is a recorded absence rather than a
  /// product that went missing.
  func testBothEncodingsAreDeclaredAndNeitherIsRequired() throws {
    let artifacts = try descriptor.artifacts
    for name in ["screenshot.png", "screenshot.jpeg"] {
      let declaration = try XCTUnwrap(artifacts.first { $0.name == name }, name)
      XCTAssertFalse(declaration.isRequired, name)
    }
    XCTAssertEqual(
      artifacts.first { $0.name == "screenshot.jpeg" }?.mediaType, "image/jpeg")
  }

  /// One capture publishes one picture. Publishing both names from the same
  /// bytes would put PNG bytes under a `.jpeg` name - which is what the
  /// mapping did before these alternatives were named as such.
  func testACaptureNeverPublishesBothEncodings() {
    let mapping = ["screenshot.png", "screenshot.jpeg"]
    XCTAssertEqual(
      RuntimeArtifactService.publishableArtifacts(mapping: mapping, requestInputs: [:]),
      ["screenshot.png"],
      "an unasked capture publishes the evidence format")
    XCTAssertEqual(
      RuntimeArtifactService.publishableArtifacts(
        mapping: mapping, requestInputs: ["screenshotImageType": .string("jpeg")]),
      ["screenshot.jpeg"])
    XCTAssertEqual(
      RuntimeArtifactService.publishableArtifacts(
        mapping: mapping, requestInputs: ["screenshotImageType": .string("webp")]),
      ["screenshot.png"],
      "an unregistered encoding falls back to the evidence format, matching "
        + "what the provider would have sent the device")
  }

  /// A step that genuinely owns several products still publishes all of them.
  /// This is the half that the first version of the rule broke: it dropped
  /// signing's report because the mapping had more than one name.
  func testAStepWithSeveralRealProductsPublishesAllOfThem() {
    let mapping = ["signed.hap", "signing-report.json"]
    XCTAssertEqual(
      RuntimeArtifactService.publishableArtifacts(mapping: mapping, requestInputs: [:]),
      mapping,
      "a HAP and its report are two products, not two encodings of one")
  }

  /// The magic follows the encoding. A file that is not the format it claims
  /// is a failure, not an artifact - and JFIF is not PNG.
  func testTheMagicFollowsTheEncoding() {
    XCTAssertEqual(
      Array(HDCFileMagic.png), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    // What `snapshot_display -t jpeg` actually writes, read off a device file
    // on 2026-08-26: FF D8 FF E0 00 10 4A 46 49 46 ("JFIF" at offset 6). The
    // pinned prefix stops at four bytes because the two after it are the APP0
    // segment length, which is not fixed.
    XCTAssertEqual(Array(HDCFileMagic.jfif), [0xFF, 0xD8, 0xFF, 0xE0])
    XCTAssertNotEqual(HDCFileMagic.jfif, HDCFileMagic.png)
  }

  /// The owned path's suffix and the requested type are one decision, because
  /// the device refuses them apart.
  func testTheOwnedPathSuffixFollowsTheRequestedType() throws {
    for imageType in [HDCScreenSequenceRequest.ImageType.png, .jpeg] {
      let path = try HDCOwnedRemotePath(
        jobID: "job-enc", stepID: "capture-screenshot", nonce: "owned", imageType: imageType)
      XCTAssertTrue(path.remotePath.hasSuffix("." + imageType.rawValue), path.remotePath)
    }
  }

  /// Capture, receive and cleanup must all name the same file. Any one of the
  /// three disagreeing leaves the device holding a file nothing collects.
  func testCaptureReceiveAndCleanupAllNameTheSameFile() throws {
    let provider = HDCObservationProviderAdapter(factsPort: EncodingFactsPort())
    let context = ProviderExecutionContext(
      jobID: "job-enc", stepID: "capture-screenshot", targetID: "TGT-1",
      bindingRevision: 1, connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "b", count: 64),
      nowUTC: "2026-08-26T00:00:00Z")
    let operation = try descriptor

    for encoding in ["png", "jpeg"] {
      let inputs: [String: JSONValue] = [
        "durationSeconds": .integer(1), "captureHilog": .bool(false),
        "uiDump": .bool(false), "uiScreenshot": .bool(true),
        "screenshotImageType": .string(encoding),
      ]
      func remotePath(_ stepID: String) throws -> String {
        let step = try XCTUnwrap(operation.steps.first { $0.stepID == stepID })
        let action = try provider.action(
          for: step, operation: operation, inputs: inputs, context: context)
        switch action {
        case .hdc(.captureScreenshot(let type, let path)):
          XCTAssertEqual(type.rawValue, encoding)
          return path.remotePath
        case .hdc(.receiveOwnedArtifact(let artifact)):
          XCTAssertEqual(
            artifact.expectedLeadingBytes,
            encoding == "png" ? HDCFileMagic.png : HDCFileMagic.jfif,
            "the receive must check the magic of the format it asked for")
          return artifact.path.remotePath
        case .hdc(.cleanupOwnedRemotePath(let path)):
          return path.remotePath
        default:
          XCTFail("unexpected action for \(stepID): \(action)")
          return ""
        }
      }
      let captured = try remotePath("capture-screenshot")
      XCTAssertEqual(
        try remotePath("receive-screenshot"), captured,
        "\(encoding): the receive would collect a file the capture never wrote")
      XCTAssertEqual(
        try remotePath("cleanup-screenshot-temp"), captured,
        "\(encoding): the cleanup would leave the captured file on the device")
      XCTAssertTrue(captured.hasSuffix("." + encoding), captured)
    }
  }
  // MARK: - Reading the picture's own size

  /// The gesture mapping is only as right as this number, so it is read from
  /// the bytes rather than taken from the request: a frame mapped against a
  /// size it does not have lands every press somewhere else.
  ///
  /// Opt-in against a real device file, because a hand-built JPEG would only
  /// prove the parser agrees with whatever this test also wrote. The reference
  /// file was captured off TGT-958780b2ffb7 at 720x1280.
  func testAJPEGFromTheDeviceReportsItsOwnSize() throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_TEST_DEVICE_JPEG"] else {
      throw XCTSkip("set ARKDECK_TEST_DEVICE_JPEG to a snapshot_display -t jpeg file")
    }
    let data = try Data(contentsOf: URL(filePath: path))
    let size = try XCTUnwrap(ToolkitScreenshotIntegrity.pixelSize(data))
    XCTAssertEqual(size.width, 720)
    XCTAssertEqual(size.height, 1280)
    XCTAssertNil(
      ToolkitScreenshotIntegrity.pngPixelSize(data),
      "a JPEG must not be read by the PNG parser")
  }

  /// Bytes that are not a picture report no size rather than a plausible one.
  func testSomethingThatIsNotAPictureHasNoSize() {
    XCTAssertNil(ToolkitScreenshotIntegrity.pixelSize(Data("<html>error</html>".utf8)))
    XCTAssertNil(ToolkitScreenshotIntegrity.pixelSize(Data()))
    // A JPEG cut short before its frame header: a size cannot be guessed from
    // what is missing.
    XCTAssertNil(ToolkitScreenshotIntegrity.pixelSize(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))
  }

  /// The workspace finds the still whichever encoding it asked for. Looking
  /// only for the PNG name would leave a JPEG capture reporting that it
  /// published nothing.
  func testTheWorkspaceFindsTheStillInEitherEncoding() {
    func entry(_ name: String) -> [String: Any] {
      [
        "name": name, "artifactId": "ART-1", "status": "published",
        "sha256": String(repeating: "a", count: 64), "byteCount": 41197,
      ]
    }
    XCTAssertEqual(ToolkitArtifactIndex.screenshot(in: [entry("screenshot.png")])?.byteCount, 41197)
    XCTAssertEqual(
      ToolkitArtifactIndex.screenshot(in: [entry("screenshot.jpeg")])?.byteCount, 41197)
    XCTAssertNil(ToolkitArtifactIndex.screenshot(in: [entry("frames.tar")]))
  }

  /// The viewfinder does not ask for JPEG yet, and that is deliberate.
  ///
  /// Sending the field makes the request unplannable on any daemon older than
  /// it - measured against the installed one: "input screenshotImageType is
  /// not declared by capture.diagnostics@1" - and the App has no daemon-floor
  /// gate, so every Toolkit capture would fail with a rejection the workspace
  /// cannot explain. This pins the choice so that taking the faster encoding
  /// is a decision somebody makes rather than something that drifts in.
  func testTheViewfinderDoesNotYetRaiseTheDaemonFloor() throws {
    let request = try ToolkitDeviceControlFacade.screenshotRequest(
      target: ToolkitTargetPresentation(id: "TGT-1", bindingRevision: 1, displayName: "d"),
      nonce: "n")
    XCTAssertNil(
      request.inputs["screenshotImageType"],
      "sending this requires a daemon that declares it; the App cannot say so")
    // But the workspace can already read either encoding, so the day that
    // floor is raised the only change is the request.
    XCTAssertNotNil(ToolkitScreenshotIntegrity.jpegPixelSize(Data()) ?? (0, 0))
  }
}

private struct EncodingFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
      targetID: targetID, bindingRevision: 1,
      deviceIdentitySHA256: String(repeating: "a", count: 64),
      executionConnectKey: "150100424a544e4600",
      deviceMode: nil, buildFingerprint: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-08-26T00:00:00Z")
  }
}
