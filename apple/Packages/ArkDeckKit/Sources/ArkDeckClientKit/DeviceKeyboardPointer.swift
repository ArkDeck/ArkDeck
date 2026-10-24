import Foundation

/// Local keyboard navigation. Moving or placing a swipe anchor never submits
/// input; only an explicit activation creates a request for Runtime admission.
public struct DeviceKeyboardPointer: Sendable, Equatable {
  public private(set) var x: Double = 0.5
  public private(set) var y: Double = 0.5
  public private(set) var anchor: CGPoint?

  public init() {}

  public mutating func move(dx: Double, dy: Double) {
    guard dx.isFinite, dy.isFinite else { return }
    x = min(1, max(0, x + dx))
    y = min(1, max(0, y + dy))
  }

  public mutating func beginSwipe() { anchor = CGPoint(x: x, y: y) }
  public mutating func cancelSwipe() { anchor = nil }

  public func request(_ gesture: DeviceGesture, frame: DeviceScreenFrame) -> DeviceGestureRequest? {
    guard frame.width > 0, frame.height > 0 else { return nil }
    let point = CGPoint(x: x, y: y)
    guard gesture != .swipe || anchor != nil else { return nil }
    let start = gesture == .swipe ? (anchor ?? point) : point
    func pixel(_ unit: Double, _ size: Int) -> Int {
      min(size - 1, max(0, Int((unit * Double(size - 1)).rounded())))
    }
    return DeviceGestureRequest(
      gesture: gesture, x: pixel(start.x, frame.width), y: pixel(start.y, frame.height),
      frameWidth: frame.width, frameHeight: frame.height,
      toX: gesture == .swipe ? pixel(x, frame.width) : nil,
      toY: gesture == .swipe ? pixel(y, frame.height) : nil,
      durationMs: gesture == .tap ? nil : (gesture == .longPress ? 800 : 300))
  }
}
