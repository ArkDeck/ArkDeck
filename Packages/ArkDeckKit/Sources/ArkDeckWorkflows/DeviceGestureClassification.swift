import CoreGraphics
import Foundation

/// What one completed pointer sequence was, and where on the device it lands.
///
/// Kept out of the workspace so it can be exercised directly. It is the rule
/// IDC-AC-8 names twice - a hold of at least half a second that barely moved
/// is a long press and not a tap, and a tap is anchored where the press began
/// rather than where it was released - and neither had anywhere to be tested
/// while it lived in a view model.
public enum DeviceGestureClassification {
  /// Past this much travel the sequence is a drag, whatever it was going to
  /// be. Six points is the design's figure: below it a press is a press that
  /// wobbled, and moving the landing point to the release would put the
  /// gesture somewhere nobody aimed.
  public static let travelThresholdPoints: CGFloat = 6

  /// Half a second, from the design. A hold this long is deliberate, and
  /// reporting it as a tap would silently discard what somebody meant.
  public static let longPressThresholdSeconds: TimeInterval = 0.5

  /// The operation's published bounds. A duration is clamped into them rather
  /// than invented, so a gesture the device would refuse never leaves here.
  public static let swipeDurationBoundsMs = (lower: 80, upper: 2000)
  public static let longPressDurationBoundsMs = (lower: 500, upper: 2000)

  public static func classify(
    start: CGPoint, end: CGPoint, travelled: CGFloat, heldFor: TimeInterval,
    rendered: CGSize, frame: DeviceScreenFrame
  ) -> DeviceGestureRequest {
    func devicePoint(_ point: CGPoint) -> (x: Int, y: Int) {
      let x = Int((point.x / rendered.width) * CGFloat(frame.width))
      let y = Int((point.y / rendered.height) * CGFloat(frame.height))
      return (min(max(x, 0), frame.width - 1), min(max(y, 0), frame.height - 1))
    }
    // Anchored at the press, for every gesture: a tap lands where the finger
    // went down, and a swipe starts there.
    let from = devicePoint(start)

    if travelled >= travelThresholdPoints {
      let to = devicePoint(end)
      let duration = min(
        max(Int(heldFor * 1000), swipeDurationBoundsMs.lower), swipeDurationBoundsMs.upper)
      return DeviceGestureRequest(
        gesture: .swipe, x: from.x, y: from.y,
        frameWidth: frame.width, frameHeight: frame.height,
        toX: to.x, toY: to.y, durationMs: duration)
    }
    if heldFor >= longPressThresholdSeconds {
      return DeviceGestureRequest(
        gesture: .longPress, x: from.x, y: from.y,
        frameWidth: frame.width, frameHeight: frame.height,
        durationMs: min(
          max(Int(heldFor * 1000), longPressDurationBoundsMs.lower),
          longPressDurationBoundsMs.upper))
    }
    return DeviceGestureRequest(
      gesture: .tap, x: from.x, y: from.y,
      frameWidth: frame.width, frameHeight: frame.height)
  }
}
