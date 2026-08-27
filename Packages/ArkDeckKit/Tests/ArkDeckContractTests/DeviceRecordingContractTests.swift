import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ArkDeckWorkflows

/// The host-composed recording (TASK-IDC-002, recorded gap 2 of 5, App leg).
///
/// The device cannot record - `/system/bin` ships no recorder and the real
/// screen-capture API is `system_core`-gated - so a recording here is a run of
/// stills the runtime brings back in one archive, composed on this side.
///
/// The archive fixture below is a real one: 20 frames captured off
/// TGT-958780b2ffb7 on 2026-08-26. Set ARKDECK_TEST_FRAME_ARCHIVE to a
/// `frames.tar` to exercise the whole path against hardware output; without it
/// the synthetic archive still pins every rule.
final class DeviceRecordingContractTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-recording-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  // MARK: - Reading the archive

  func testFramesComeBackInCaptureOrder() throws {
    let archive = TarFixture.archive(
      entries: [("0003.jpeg", jpeg(3)), ("0001.jpeg", jpeg(1)), ("0002.jpeg", jpeg(2))])
    let frames = try DeviceFrameArchive.frames(in: archive)
    XCTAssertEqual(frames.map(\.name), ["0001.jpeg", "0002.jpeg", "0003.jpeg"])
  }

  /// `tar -C <dir> .` writes a "./" directory entry ahead of the files. It is
  /// not a frame and must not become one.
  func testTheDirectoryEntryTarWritesIsNotAFrame() throws {
    var entries: [(String, Data)] = [("./", Data())]
    entries += (1...3).map { (String(format: "./%04d.jpeg", $0), jpeg($0)) }
    let frames = try DeviceFrameArchive.frames(
      in: TarFixture.archive(entries: entries, directories: ["./"]))
    XCTAssertEqual(frames.map(\.name), ["0001.jpeg", "0002.jpeg", "0003.jpeg"])
  }

  /// Frames are named by index. Anything else in the archive is not something
  /// this provider wrote, so it is not composed.
  func testAnEntryThisProviderDidNotWriteIsNotComposed() throws {
    let archive = TarFixture.archive(
      entries: [("0001.jpeg", jpeg(1)), ("notes.txt", Data("hello".utf8))])
    XCTAssertEqual(try DeviceFrameArchive.frames(in: archive).map(\.name), ["0001.jpeg"])
  }

  func testSomethingThatIsNotATarIsRefusedRatherThanParsed() {
    XCTAssertThrowsError(
      try DeviceFrameArchive.frames(in: Data(repeating: 0x41, count: 4096))
    ) { error in
      XCTAssertEqual(error as? DeviceFrameArchive.ArchiveUnreadable, .notATarArchive)
    }
  }

  /// A transfer cut short must say so rather than return however many frames
  /// happened to survive. Without the end-of-archive blocks there is no way to
  /// tell a short run from a lost tail, and a recording quietly missing its
  /// last seconds is worse than one that refuses.
  func testAnArchiveCutShortSaysSoRatherThanLookingComplete() {
    let whole = TarFixture.archive(
      entries: (1...4).map { (String(format: "%04d.jpeg", $0), jpeg($0)) })

    // Only the terminator is gone: every frame is intact, and the reader still
    // refuses, because it cannot know that.
    XCTAssertThrowsError(try DeviceFrameArchive.frames(in: whole.prefix(whole.count - 1024)))
    { error in
      XCTAssertEqual(
        error as? DeviceFrameArchive.ArchiveUnreadable, .truncated(afterFrames: 4))
    }

    // Cut into the last entry: fewer frames survived, and the count says how
    // many, so a caller can tell how much of the run it is looking at.
    XCTAssertThrowsError(try DeviceFrameArchive.frames(in: whole.prefix(whole.count / 2)))
    { error in
      guard case .truncated(let after) = error as? DeviceFrameArchive.ArchiveUnreadable
      else { return XCTFail("expected a truncation, got \(error)") }
      XCTAssertLessThan(after, 4)
    }
  }

  // MARK: - Composing

  /// The timeline is built from what was observed, not from an average. At
  /// about 1.8 frames a second the spacing is uneven enough to see, and a
  /// movie laid out on a mean rate would misplace every frame but the first.
  func testTheTimelineIsBuiltFromTheObservedDurations() async throws {
    let frames = try DeviceFrameArchive.frames(
      in: TarFixture.archive(
        entries: (1...4).map { (String(format: "%04d.jpeg", $0), jpeg($0)) }))
    let uneven = [0.51, 0.94, 0.48, 0.55]
    let composition = try await DeviceRecordingComposer.compose(
      frames: frames, frameDurationsSeconds: uneven,
      into: scratch.appending(path: "uneven.mov"))
    XCTAssertEqual(composition.frameCount, 4)
    XCTAssertEqual(composition.durationSeconds, uneven.reduce(0, +), accuracy: 0.001)
    XCTAssertEqual(
      composition.framesPerSecond, 4 / uneven.reduce(0, +), accuracy: 0.01,
      "the rate is frames over the span they actually covered")
  }

  /// Every frame needs its own duration. Inventing a missing one is exactly
  /// the averaging this is built to avoid.
  func testAFrameWithNoObservedDurationIsRefusedRatherThanAveraged() async throws {
    let frames = try DeviceFrameArchive.frames(
      in: TarFixture.archive(
        entries: (1...3).map { (String(format: "%04d.jpeg", $0), jpeg($0)) }))
    do {
      _ = try await DeviceRecordingComposer.compose(
        frames: frames, frameDurationsSeconds: [0.5, 0.5],
        into: scratch.appending(path: "short.mov"))
      XCTFail("two durations cannot lay out three frames")
    } catch let failure as DeviceRecordingComposer.CompositionFailure {
      XCTAssertEqual(failure, .durationsDoNotMatchFrames(frames: 3, durations: 2))
    }
  }

  func testAnEmptyRunComposesNothing() async {
    do {
      _ = try await DeviceRecordingComposer.compose(
        frames: [], frameDurationsSeconds: [], into: scratch.appending(path: "none.mov"))
      XCTFail("there is no recording without frames")
    } catch let failure as DeviceRecordingComposer.CompositionFailure {
      XCTAssertEqual(failure, .noFrames)
    } catch {
      XCTFail("\(error)")
    }
  }

  /// Frames of differing size compose into nothing, which is why the capture
  /// refuses a half-scaled request in the first place.
  func testFramesOfDifferingSizeAreRefused() async throws {
    let frames = [
      DeviceFrameArchive.Frame(name: "0001.jpeg", bytes: jpeg(1, width: 64, height: 64)),
      DeviceFrameArchive.Frame(name: "0002.jpeg", bytes: jpeg(2, width: 48, height: 64)),
    ]
    do {
      _ = try await DeviceRecordingComposer.compose(
        frames: frames, frameDurationsSeconds: [0.5, 0.5],
        into: scratch.appending(path: "mixed.mov"))
      XCTFail("a movie has one frame size")
    } catch let failure as DeviceRecordingComposer.CompositionFailure {
      XCTAssertEqual(failure, .framesDifferInSize)
    }
  }

  // MARK: - Validating

  /// Validating reads the file back. "The writer said it finished" is the
  /// claim a validating step exists to doubt.
  func testValidatingReadsTheWrittenFileRatherThanTrustingTheWriter() async throws {
    let frames = try DeviceFrameArchive.frames(
      in: TarFixture.archive(
        entries: (1...6).map { (String(format: "%04d.jpeg", $0), jpeg($0)) }))
    let durations = Array(repeating: 0.543, count: 6)
    let composition = try await DeviceRecordingComposer.compose(
      frames: frames, frameDurationsSeconds: durations,
      into: scratch.appending(path: "valid.mov"))
    let reading = try await DeviceRecordingValidation.validate(composition)
    XCTAssertGreaterThan(reading.byteCount, 0)
    XCTAssertEqual(reading.width, 64)
    XCTAssertEqual(reading.height, 64)
    XCTAssertEqual(
      reading.durationSeconds, durations.reduce(0, +),
      accuracy: DeviceRecordingValidation.toleranceSeconds)
  }

  /// A file that is not there, or is empty, is not a recording — even when the
  /// composition record says one was written.
  func testAMissingFileIsRefusedEvenWhenTheRecordSaysItWasWritten() async throws {
    let claimed = DeviceRecordingComposer.Composition(
      url: scratch.appending(path: "never-written.mov"), frameCount: 4,
      width: 64, height: 64, durationSeconds: 2)
    do {
      _ = try await DeviceRecordingValidation.validate(claimed)
      XCTFail("nothing was written, so nothing can be shown")
    } catch let refusal as DeviceRecordingValidation.Refusal {
      XCTAssertEqual(refusal, .empty)
    }
  }

  /// The rate this reports is measured off the movie's own span, and it lands
  /// where the device measurements said it would: about 1.8 frames a second.
  func testTheReportedRateMatchesWhatTheDeviceCanActuallyDo() async throws {
    let frames = try DeviceFrameArchive.frames(
      in: TarFixture.archive(
        entries: (1...10).map { (String(format: "%04d.jpeg", $0), jpeg($0)) }))
    let composition = try await DeviceRecordingComposer.compose(
      frames: frames, frameDurationsSeconds: Array(repeating: 0.543, count: 10),
      into: scratch.appending(path: "rate.mov"))
    XCTAssertEqual(composition.framesPerSecond, 1.84, accuracy: 0.01)
  }

  // MARK: - Against a real archive

  /// The whole path against bytes a device produced. Opt-in because it needs
  /// an archive on disk; the run that produced the reference one captured 20
  /// frames off TGT-958780b2ffb7.
  func testARealDeviceArchiveComposesAndValidates() async throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_TEST_FRAME_ARCHIVE"] else {
      throw XCTSkip("set ARKDECK_TEST_FRAME_ARCHIVE to a frames.tar from a real capture")
    }
    let archive = try Data(contentsOf: URL(filePath: path))
    let frames = try DeviceFrameArchive.frames(in: archive)
    XCTAssertGreaterThan(frames.count, 1)
    XCTAssertEqual(frames.map(\.name), frames.map(\.name).sorted())
    let composition = try await DeviceRecordingComposer.compose(
      frames: frames, frameDurationsSeconds: Array(repeating: 0.543, count: frames.count),
      into: scratch.appending(path: "device.mov"))
    let reading = try await DeviceRecordingValidation.validate(composition)
    XCTAssertEqual(reading.width, 720)
    XCTAssertEqual(reading.height, 1280)
    XCTAssertGreaterThan(reading.byteCount, 0)
  }

  // MARK: - The pane's own pipeline

  /// Exactly what the recording pane does, in the order it does it: ask the
  /// provider for a run, compose it, then read the written file back. Driven
  /// through the same fixture the App installs under its launch argument, over
  /// an archive a device produced.
  ///
  /// The pane's stage transitions and result bar have their own real-device UI
  /// gate; this covers the work those stages name.
  func testThePaneSPipelineRunsOverAnArchiveADeviceProduced() async throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_TEST_FRAME_ARCHIVE"] else {
      throw XCTSkip("set ARKDECK_TEST_FRAME_ARCHIVE to a frames.tar from a real capture")
    }
    let provider = try XCTUnwrap(
      DeviceRecordingFixture.provider(arguments: ["--ui-test-device-recording=\(path)"]),
      "the fixture installs only under its own launch argument")
    let target = DeviceTargetPresentation(
      id: "TGT-1a62a0dbedd6", bindingRevision: 1, displayName: "DAYU200")

    guard case .captured(let recording) = await provider.recordScreen(
      frameCount: 20, target: target)
    else { return XCTFail("the fixture must replay the archive") }
    XCTAssertEqual(recording.frames.count, 20)
    XCTAssertEqual(recording.frameDurationsSeconds.count, recording.frames.count)

    let composition = try await DeviceRecordingComposer.compose(
      frames: recording.frames, frameDurationsSeconds: recording.frameDurationsSeconds,
      into: scratch.appending(path: "pane.mov"))
    let reading = try await DeviceRecordingValidation.validate(composition)
    XCTAssertEqual(reading.width, 720)
    XCTAssertEqual(reading.height, 1280)
    XCTAssertGreaterThan(reading.byteCount, 0)
    XCTAssertEqual(composition.framesPerSecond, 1.84, accuracy: 0.05)
  }

  /// An ordinary launch never reaches the fixture. Production is the only
  /// thing an ordinary launch can be talking to.
  func testAnOrdinaryLaunchNeverReachesTheFixture() {
    XCTAssertNil(DeviceRecordingFixture.provider(arguments: ["ArkDeck"]))
    XCTAssertNil(
      DeviceRecordingFixture.provider(arguments: ["--ui-test-auto-update-idle"]),
      "another workspace's UI-test argument must not install this one's fixture")
    XCTAssertFalse(DeviceRecordingFixture.isSelected(arguments: ["--ui-test-viewer"]))
  }

  /// The fixture replays what the archive holds and never invents a frame to
  /// reach the count that was asked for.
  func testTheFixtureNeverInventsAFrameItDoesNotHave() async throws {
    let archive = scratch.appending(path: "three.tar")
    try TarFixture.archive(
      entries: (1...3).map { (String(format: "%04d.jpeg", $0), jpeg($0)) }
    ).write(to: archive)
    let provider = try XCTUnwrap(
      DeviceRecordingFixture.provider(
        arguments: ["--ui-test-device-recording=\(archive.path)"]))
    guard case .captured(let recording) = await provider.recordScreen(
      frameCount: 40, target: DeviceTargetPresentation(
        id: "TGT-1", bindingRevision: 1, displayName: "d"))
    else { return XCTFail("three frames are still a run") }
    XCTAssertEqual(recording.frames.count, 3)
    XCTAssertEqual(
      recording.framesMissing, 37,
      "a short run says how short it is rather than reading as complete")
  }

  // MARK: - Fixtures

  /// A real encoded image, not a stub: the composer decodes what it is given,
  /// so a fixture that only looks like a picture would test nothing.
  private func jpeg(_ seed: Int, width: Int = 64, height: Int = 64) -> Data {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(
      red: Double(seed % 7) / 7, green: Double(seed % 5) / 5, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      out, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
  }
}

/// A tar writer, so the reader is exercised against the format rather than
/// against a mirror of its own parsing.
private enum TarFixture {
  static func archive(entries: [(String, Data)], directories: Set<String> = []) -> Data {
    var out = Data()
    for (name, payload) in entries {
      out.append(header(name: name, size: payload.count, isDirectory: directories.contains(name)))
      out.append(payload)
      let padding = (512 - payload.count % 512) % 512
      out.append(Data(repeating: 0, count: padding))
    }
    out.append(Data(repeating: 0, count: 1024))
    return out
  }

  private static func header(name: String, size: Int, isDirectory: Bool) -> Data {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int, width: Int) {
      for (index, byte) in Array(text.utf8).prefix(width - 1).enumerated() {
        block[offset + index] = byte
      }
    }
    put(name, at: 0, width: 100)
    put("000644 ", at: 100, width: 8)
    put("000000 ", at: 108, width: 8)
    put("000000 ", at: 116, width: 8)
    put(String(format: "%011o ", size), at: 124, width: 12)
    put(String(format: "%011o ", 0), at: 136, width: 12)
    block[156] = isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
    put("ustar", at: 257, width: 6)
    put("00", at: 263, width: 3)
    // The checksum is computed with its own field read as spaces.
    for index in 148..<156 { block[index] = UInt8(ascii: " ") }
    let checksum = block.reduce(0) { $0 + Int($1) }
    put(String(format: "%06o", checksum), at: 148, width: 7)
    block[154] = 0
    block[155] = UInt8(ascii: " ")
    return Data(block)
  }
}
