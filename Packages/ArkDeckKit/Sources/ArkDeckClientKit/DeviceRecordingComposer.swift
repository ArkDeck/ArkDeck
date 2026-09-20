import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Turns the frames a device gave up into one file somebody can keep.
///
/// The composing is done here because the device cannot do it: nothing on the
/// platform records, so a "recording" is a run of stills and the movie is made
/// on this side. See `HDCScreenSequenceRequest` for why that is the only road.
///
/// Presentation times come from each frame's own observed duration, never from
/// an assumed cadence. At about 1.8 frames a second the spacing is uneven
/// enough to see, and a movie laid out on an average would misplace every
/// frame but the first - which for a diagnostics recording is the whole point
/// of having it.
public enum DeviceRecordingComposer {
  /// What was actually written, as opposed to what was asked for.
  public struct Composition: Sendable, Equatable {
    public let url: URL
    public let frameCount: Int
    public let width: Int
    public let height: Int
    /// Wall-clock span the movie covers, from the observed durations.
    public let durationSeconds: Double
    /// Frames divided by that span. The number the workspace shows, and the
    /// reason it is shown rather than promised.
    public var framesPerSecond: Double {
      durationSeconds > 0 ? Double(frameCount) / durationSeconds : 0
    }
  }

  public enum CompositionFailure: Error, Equatable {
    case noFrames
    case frameNotDecodable(name: String)
    case framesDifferInSize
    /// Every frame needs a duration, because the timeline is built from them
    /// rather than from a rate. A missing one would have to be invented.
    case durationsDoNotMatchFrames(frames: Int, durations: Int)
    case writeFailed(String)
  }

  /// The smallest span a frame may occupy. A duration of zero would place two
  /// frames at the same instant and the second would never be shown.
  static let minimumFrameSeconds = 0.001

  public static func compose(
    frames: [DeviceFrameArchive.Frame],
    frameDurationsSeconds: [Double],
    into url: URL
  ) async throws -> Composition {
    guard !frames.isEmpty else { throw CompositionFailure.noFrames }
    guard frameDurationsSeconds.count == frames.count else {
      throw CompositionFailure.durationsDoNotMatchFrames(
        frames: frames.count, durations: frameDurationsSeconds.count)
    }

    var images: [CGImage] = []
    images.reserveCapacity(frames.count)
    for frame in frames {
      guard
        let source = CGImageSourceCreateWithData(frame.bytes as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw CompositionFailure.frameNotDecodable(name: frame.name) }
      images.append(image)
    }
    let width = images[0].width
    let height = images[0].height
    guard images.allSatisfy({ $0.width == width && $0.height == height }) else {
      throw CompositionFailure.framesDifferInSize
    }

    try? FileManager.default.removeItem(at: url)
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    } catch {
      throw CompositionFailure.writeFailed("\(error)")
    }
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(input) else {
      throw CompositionFailure.writeFailed("the writer refused a video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw CompositionFailure.writeFailed("\(writer.error.map { "\($0)" } ?? "writing refused")")
    }
    writer.startSession(atSourceTime: .zero)

    // 600 divides the frame rates a person would name and keeps the rounding
    // error under a millisecond at the spacing this actually produces.
    let timescale: CMTimeScale = 600
    var elapsed = 0.0
    for (index, image) in images.enumerated() {
      guard let buffer = pixelBuffer(from: image, width: width, height: height) else {
        throw CompositionFailure.frameNotDecodable(name: frames[index].name)
      }
      while !input.isReadyForMoreMediaData {
        try? await Task.sleep(nanoseconds: 2_000_000)
      }
      let time = CMTime(seconds: elapsed, preferredTimescale: timescale)
      guard adaptor.append(buffer, withPresentationTime: time) else {
        throw CompositionFailure.writeFailed(
          "\(writer.error.map { "\($0)" } ?? "frame \(frames[index].name) was refused")")
      }
      elapsed += max(frameDurationsSeconds[index], minimumFrameSeconds)
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw CompositionFailure.writeFailed(
        "\(writer.error.map { "\($0)" } ?? "writing did not complete")")
    }

    return Composition(
      url: url, frameCount: frames.count, width: width, height: height,
      durationSeconds: elapsed)
  }

  private static func pixelBuffer(
    from image: CGImage, width: Int, height: Int
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
      [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary,
      &buffer)
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
