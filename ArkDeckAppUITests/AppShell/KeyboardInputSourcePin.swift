import Carbon.HIToolbox
import XCTest

extension XCUIElement {
  /// XCTest waits poll on a coarse cadence. Most UI assertions inspect state
  /// that is already stable, so avoid spending the first polling interval
  /// when the current accessibility snapshot already answers the question.
  func waitForExistenceFast(timeout: TimeInterval) -> Bool {
    exists || waitForExistence(timeout: timeout)
  }

  func waitForNonExistenceFast(timeout: TimeInterval) -> Bool {
    !exists || waitForNonExistence(timeout: timeout)
  }
}

/// Pins a plain keyboard layout for the duration of a UI test run.
///
/// The runner has to synthesize keyboard events — `⌘R`, `Esc`, `⌘,` are the
/// point of several tests — and that needs an *enabled* input source. When the
/// selected source is a third-party input method that is absent from
/// `AppleEnabledInputSources`, macOS raises a permission prompt to enable it.
/// That prompt appears in front of the app under test, steals focus, and every
/// following assertion fails with "Not authorized" — which looks like a suite
/// full of product defects and is nothing of the kind.
///
/// Selecting an already-enabled layout needs no permission, so this asks for
/// nothing. The previous selection is restored once the whole bundle finishes.
enum KeyboardInputSourcePin {
  private nonisolated(unsafe) static var previousSource: TISInputSource?
  private nonisolated(unsafe) static var observer: RunLifetimeObserver?

  /// Best effort by design. If no plain layout is enabled on this host the
  /// tests should still run and report their own results rather than refuse to
  /// start; the prompt is a host condition, not a product one.
  static func pinPlainKeyboardLayout() {
    if previousSource == nil {
      previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }
    guard
      let plain = enabledSource(withID: "com.apple.keylayout.US")
        ?? enabledSource(withID: "com.apple.keylayout.ABC")
    else { return }
    TISSelectInputSource(plain)
  }

  /// Restoring per test class is wrong: the first suite's teardown hands the
  /// input source back while a later suite is still launching apps, and the
  /// prompt returns for the rest of the run. Restore once, at the end.
  static func restoreWhenTheRunFinishes() {
    guard observer == nil else { return }
    let created = RunLifetimeObserver()
    observer = created
    XCTestObservationCenter.shared.addTestObserver(created)
  }

  static func restorePreviousInputSource() {
    guard let previousSource else { return }
    TISSelectInputSource(previousSource)
    Self.previousSource = nil
  }

  /// Only sources that are already enabled are candidates: selecting a
  /// disabled one is exactly what triggers the prompt this exists to avoid.
  private static func enabledSource(withID identifier: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
    guard
      let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
        as? [TISInputSource]
    else { return nil }
    return sources.first { source in
      guard let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled)
      else { return false }
      return unsafeBitCast(enabled, to: CFBoolean.self) == kCFBooleanTrue
    }
  }
}

final class RunLifetimeObserver: NSObject, XCTestObservation {
  func testBundleDidFinish(_ testBundle: Bundle) {
    KeyboardInputSourcePin.restorePreviousInputSource()
  }
}
