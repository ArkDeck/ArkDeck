import AVFoundation
import Foundation

/// Reads the composed file back before anyone is told it exists.
///
/// This is a separate step from composing rather than a phrase in the same
/// one, because "the writer said it finished" and "the file plays what it
/// claims" are different facts and only the second is worth showing a person.
/// The writer reporting `.completed` is what a validating step is there to
/// doubt.
public enum DeviceRecordingValidation {
  public struct Reading: Sendable, Equatable {
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let byteCount: Int
  }

  public enum Refusal: Error, Equatable {
    case unreadable(String)
    case noVideoTrack
    /// The written span disagrees with the span the frames covered. Not a
    /// rounding complaint: the tolerance is a whole frame at the rate this
    /// achieves, so this fires only when frames were dropped or doubled.
    case durationDisagrees(wrote: Double, expected: Double)
    case sizeDisagrees(wrote: String, expected: String)
    case empty
  }

  /// A frame at the rate a screen sequence actually achieves is about half a
  /// second, so a disagreement smaller than that cannot be a lost frame.
  static let toleranceSeconds = 0.25

  public static func validate(
    _ composition: DeviceRecordingComposer.Composition
  ) async throws -> Reading {
    let byteCount =
      (try? FileManager.default.attributesOfItem(atPath: composition.url.path)[.size] as? Int)
      .flatMap { $0 } ?? 0
    guard byteCount > 0 else { throw Refusal.empty }

    let asset = AVURLAsset(url: composition.url)
    let tracks: [AVAssetTrack]
    let duration: CMTime
    do {
      tracks = try await asset.loadTracks(withMediaType: .video)
      duration = try await asset.load(.duration)
    } catch {
      throw Refusal.unreadable("\(error)")
    }
    guard let track = tracks.first else { throw Refusal.noVideoTrack }
    let size: CGSize
    do {
      size = try await track.load(.naturalSize)
    } catch {
      throw Refusal.unreadable("\(error)")
    }

    let wrote = duration.seconds
    guard abs(wrote - composition.durationSeconds) <= toleranceSeconds else {
      throw Refusal.durationDisagrees(wrote: wrote, expected: composition.durationSeconds)
    }
    guard Int(size.width) == composition.width, Int(size.height) == composition.height else {
      throw Refusal.sizeDisagrees(
        wrote: "\(Int(size.width))×\(Int(size.height))",
        expected: "\(composition.width)×\(composition.height)")
    }
    return Reading(
      durationSeconds: wrote, width: composition.width, height: composition.height,
      byteCount: byteCount)
  }
}
