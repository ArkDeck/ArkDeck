import Foundation

/// How much room a run of stills will need.
///
/// This exists so the workspace can be refused before it starts. A 300-frame
/// run takes about three minutes on this hardware; finding out at the end that
/// there was never room to publish it wastes all of it, and leaves a person
/// believing they recorded something.
///
/// The number here is the same number the runtime will check. The operation's
/// `preflight-host-storage` step reads `totalArtifactByteBudget` from the
/// request, so a workspace that estimated its own figure and sent a different
/// one could pass its own check and still be refused - two answers to one
/// question. Sending this as the budget makes the two agree by construction.
public enum ToolkitRecordingBudget {
  /// Measured on hardware, 2026-08-26: a 20-frame JPEG archive off a
  /// 720x1280 display came back at 851,456 bytes, which is 42,573 a frame
  /// including the archive's own block padding.
  public static let measuredBytesPerFrame = 42_573

  /// What a run publishes: the frames, plus their timing index.
  ///
  /// Half again the measured size, because the measurement is one screen and
  /// a busier one compresses worse. Under-estimating is the failure that
  /// matters: it lets a run start that the runtime will refuse, which is the
  /// exact outcome this exists to prevent.
  public static func bytes(frameCount: Int) -> Int {
    let frames = frameCount * measuredBytesPerFrame * 3 / 2
    // The catalog floors the budget at a mebibyte, and a short run would
    // otherwise ask for less than the store will accept as a request.
    return max(1 << 20, frames + (64 << 10))
  }

  /// Whether a run of this length can be published, and what to say if not.
  public static func refusal(
    frameCount: Int, remainingBytes: Int
  ) -> Refusal? {
    let needed = bytes(frameCount: frameCount)
    guard needed > remainingBytes else { return nil }
    return Refusal(
      neededBytes: needed, remainingBytes: remainingBytes,
      framesThatWouldFit: framesThatFit(in: remainingBytes))
  }

  /// The longest run that would fit, so a refusal offers something to do
  /// rather than only saying no.
  public static func framesThatFit(in remainingBytes: Int) -> Int {
    var count = 0
    // Walked rather than solved, so this can never disagree with `bytes` -
    // an inverse derived by algebra is a second definition that drifts.
    while bytes(frameCount: count + 1) <= remainingBytes { count += 1 }
    return count
  }

  public struct Refusal: Sendable, Equatable {
    public let neededBytes: Int
    public let remainingBytes: Int
    public let framesThatWouldFit: Int
  }
}
