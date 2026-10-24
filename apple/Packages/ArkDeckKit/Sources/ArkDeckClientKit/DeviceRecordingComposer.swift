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

  /// Decodes and draws every frame, so it runs on the concurrent pool rather
  /// than on its caller's actor.
  @concurrent
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
    guard writer.canAdd(input) else {
      throw CompositionFailure.writeFailed("the writer refused a video input")
    }
    // The frames are drawn with Core Graphics, so every buffer has to be one
    // a bitmap context can draw into.
    let attributes = CVPixelBufferCreationAttributes(
      pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
      size: CVImageSize(width: width, height: height),
      compatibility: [.cgImage, .cgBitmapContext])
    // The receiver adds the input to the writer. Its asynchronous append is
    // the non-real-time path: it waits until the input can take the next
    // frame, which is what polling isReadyForMoreMediaData used to do here.
    let receiver = writer.inputPixelBufferReceiver(
      for: input, pixelBufferAttributes: attributes)
    do {
      try writer.start()
    } catch {
      throw CompositionFailure.writeFailed("\(writer.error ?? error)")
    }
    writer.startSession(atSourceTime: .zero)
    let pool: CVMutablePixelBuffer.Pool
    do {
      pool = try receiver.pixelBufferPool
        ?? CVMutablePixelBuffer.Pool(pixelBufferAttributes: attributes)
    } catch {
      throw CompositionFailure.writeFailed("\(error)")
    }

    // 600 divides the frame rates a person would name and keeps the rounding
    // error under a millisecond at the spacing this actually produces.
    let timescale: CMTimeScale = 600
    var elapsed = 0.0
    for (index, image) in images.enumerated() {
      guard let buffer = pixelBuffer(from: image, in: pool) else {
        throw CompositionFailure.frameNotDecodable(name: frames[index].name)
      }
      let time = CMTime(seconds: elapsed, preferredTimescale: timescale)
      do {
        try await receiver.append(buffer, with: time)
      } catch {
        throw CompositionFailure.writeFailed(
          "frame \(frames[index].name) was refused: \(writer.error ?? error)")
      }
      elapsed += max(frameDurationsSeconds[index], minimumFrameSeconds)
    }
    receiver.finish()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw CompositionFailure.writeFailed(
        "\(writer.error.map { "\($0)" } ?? "writing did not complete")")
    }

    return Composition(
      url: url, frameCount: frames.count, width: width, height: height,
      durationSeconds: elapsed)
  }

  /// Draws one frame into a buffer from `pool` and hands it over read-only:
  /// once the writer has it, nothing here may change it.
  private static func pixelBuffer(
    from image: CGImage, in pool: CVMutablePixelBuffer.Pool
  ) -> CVReadOnlyPixelBuffer? {
    guard var buffer = try? pool.makeMutablePixelBuffer() else { return nil }
    let drawn = buffer.accessUnsafeMutableRawPlaneBytes { planes in
      guard
        let plane = planes.first,
        let context = CGContext(
          data: plane.bytes.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? CVReadOnlyPixelBuffer(buffer) : nil
  }
}
