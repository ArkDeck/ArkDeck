import Foundation
import Testing

@testable import ArkDeckClientKit

/// A press must not be aimed at a picture the device has moved past
/// (TASK-IDC-002, recorded gap 1 of 5).
///
/// This was the gap worth closing first because it is the only one of the
/// five that sends something to the device: the other four withhold work or
/// withhold an explanation, while this one lets a press be computed against
/// a screen that is no longer there and land wherever that point has since
/// moved to.
///
/// These pin both halves. A rule that refused too eagerly - anything
/// time-based - would refuse every gesture anyone ever made, since nobody
/// looks at a still and decides where to press inside a second.
struct DeviceFrameLivenessContractTests {
  /// Nothing has been shown yet, so there is nothing to aim at.
  @Test func aWorkspaceWithNoPictureRefuses() {
    #expect(DeviceFrameLiveness().refusesInput)
  }

  @Test func aFreshPictureIsAimable() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    #expect(!liveness.refusesInput)
  }

  /// The case the gap was about: press, then press again without looking.
  @Test func aSecondPressOnTheSamePictureIsRefused() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    liveness.settled(.confirmed(summary: [:]))
    #expect(
      liveness.refusesInput,
      """
      the gesture that just landed is the one change this workspace knows \
      changed the screen, so the picture it was aimed at is spent
      """)
  }

  /// Unknown is not a licence to keep aiming. A gesture that may have landed
  /// leaves a picture that may already be wrong, and the two are the same
  /// thing from here.
  @Test func anUnknownOutcomeAlsoSpendsThePicture() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    liveness.settled(.unknown(reason: "channel closed before the verdict"))
    #expect(liveness.refusesInput)
  }

  /// The other half of the rule. A clean failure reached no device, so the
  /// picture is still true and refusing here would cost a person their aim
  /// for nothing.
  @Test func aCleanFailureLeavesThePictureAimable() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    liveness.settled(.failed(reason: "device not adopted"))
    #expect(
      !liveness.refusesInput,
      "nothing reached the device, so nothing changed the screen")
  }

  /// Time alone must never spend a picture. Applying the runtime's own
  /// one-second freshness budget here would refuse every gesture ever made,
  /// which is why `DeviceScreenFrame.capturedAtUTC` is deliberately not a
  /// freshness claim.
  @Test func ageAloneNeverRefuses() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    // No call carries a clock, and none can: there is nothing here to pass a
    // later instant to. That absence is the assertion.
    #expect(!liveness.refusesInput)
  }

  /// Recapturing is the way back, and the only way.
  @Test func onlyAFreshPictureRestoresAim() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    liveness.settled(.confirmed(summary: [:]))
    #expect(liveness.refusesInput)
    liveness.captured()
    #expect(!liveness.refusesInput)
  }

  /// Two gestures in a row without a recapture do not somehow come back.
  @Test func stalenessDoesNotDecayBackToAimable() {
    var liveness = DeviceFrameLiveness()
    liveness.captured()
    liveness.settled(.confirmed(summary: [:]))
    liveness.settled(.failed(reason: "refused before dispatch"))
    #expect(
      liveness.refusesInput,
      "a failure after the screen already changed does not un-change it")
  }
}
