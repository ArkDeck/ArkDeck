import Foundation

/// Whether the picture on screen still shows the device.
///
/// Not a matter of age. The runtime's own freshness budget is a second, and a
/// still is read at a person's own pace - they look, they think, they decide
/// where to press. A rule counting seconds would refuse every gesture anyone
/// ever made, which is why `DeviceScreenFrame` deliberately does not turn its
/// capture instant into a freshness claim.
///
/// What invalidates the picture is something having changed the screen, and
/// the one change this workspace knows about for certain is the gesture it
/// just sent. So the rule is about what happened, not about how long ago the
/// picture was taken.
public struct DeviceFrameLiveness: Sendable, Equatable {
  /// True while the picture is still the device's current screen as far as
  /// anything here can tell.
  public private(set) var showsTheDevice: Bool

  public init(showsTheDevice: Bool = false) {
    self.showsTheDevice = showsTheDevice
  }

  /// A fresh picture arrived. This is the only thing that restores liveness:
  /// there is no way to un-change a screen.
  public mutating func captured() {
    showsTheDevice = true
  }

  /// A gesture reached its verdict.
  ///
  /// Confirmed and unknown both invalidate the picture: one is known to have
  /// landed and the other may have, and a picture that might already be wrong
  /// is not one to aim at. Only a clean failure leaves it true, because
  /// nothing reached the device.
  public mutating func settled(_ outcome: DeviceGestureOutcome) {
    if case .failed = outcome { return }
    showsTheDevice = false
  }

  /// Whether a press must be refused. Refusing is the point: a second press
  /// computed against a picture taken before the first one lands wherever the
  /// screen has since moved that point to, which is nowhere anybody aimed.
  public var refusesInput: Bool { !showsTheDevice }
}
