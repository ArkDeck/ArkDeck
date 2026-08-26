import ArkDeckCore
import Foundation

/// What a diagnostic session can be shown to say, derived only from the time
/// facts its artifacts carry.
///
/// The reader exists because the interesting moment is always before the mark:
/// a person notices a stutter and reaches for the keyboard afterwards. So the
/// session keeps the run-up, and this decides what may honestly be put beside
/// each mark - and, more often than it is comfortable to, that the answer is
/// nothing.
public struct DiagnosticSessionReading: Sendable, Equatable {
  /// How host time and device time relate for this session.
  ///
  /// There is no fourth state for "probably fine". A reader that cannot say
  /// how a mark lines up with the device's own record has to say so, because
  /// everything below it - which log line, which frame, which event - is only
  /// meaningful through this.
  public enum Alignment: Sendable, Equatable {
    /// One clock produced both sides.
    case sameClock
    /// Two clocks with a measured offset, good to this tolerance.
    case calibrated(toleranceMs: Int)
    /// No calibration was established. The session is still readable; nothing
    /// in it may be lined up against device time.
    case cannotAlign(reason: String)
  }

  /// Why a mark has no picture beside it. Each is a different fact and none of
  /// them is "here is an older picture".
  public enum ScreenshotAbsence: Sendable, Equatable {
    /// A screenshot exists but was taken too far from the mark to stand for it.
    case takenTooFarFromTheMark(offsetMs: Int)
    /// A screenshot exists and might be this moment, but the window the host
    /// could observe it in is wider than the tolerance this rule is written
    /// to, so nothing here can decide. Measured on the device: taking a
    /// screenshot occupies about 550 ms, against a 150 ms rule.
    case shutterWindowWiderThanTheRule(windowMs: Int)
    /// The capture tried and failed, and said why.
    case captureFailed(reason: String)
    /// Nothing was captured for this mark.
    case notCaptured
  }

  public struct Screenshot: Sendable, Equatable {
    public let artifactName: String
    public let capturedAtUTC: String
    /// How long after the mark the shutter actually opened. Always shown: a
    /// screenshot stands for the moment it was taken, never for the moment it
    /// was asked for.
    public let takenAfterMarkMs: Int

    public init(artifactName: String, capturedAtUTC: String, takenAfterMarkMs: Int) {
      self.artifactName = artifactName
      self.capturedAtUTC = capturedAtUTC
      self.takenAfterMarkMs = takenAfterMarkMs
    }
  }

  /// A screenshot and the interval the host could observe its shutter in.
  ///
  /// The host cannot see the shutter open; it sees the interval it was
  /// dispatching in. Carrying the interval is what lets the reader distinguish
  /// "this picture is not this moment" from "nothing here can tell".
  public struct ObservedScreenshot: Sendable, Equatable {
    public let artifactName: String
    public let windowStartUTC: String
    public let windowEndUTC: String

    public init(artifactName: String, windowStartUTC: String, windowEndUTC: String) {
      self.artifactName = artifactName
      self.windowStartUTC = windowStartUTC
      self.windowEndUTC = windowEndUTC
    }
  }

  public struct Mark: Sendable, Equatable {
    public let ordinal: Int
    public let isAutomatic: Bool
    public let atHostUTC: String
    public let label: String?
    /// Present only when a screenshot was taken close enough to stand for this
    /// mark. Its absence carries the reason rather than a blank.
    public let screenshot: Screenshot?
    public let screenshotAbsence: ScreenshotAbsence?
    /// What an automatic mark was derived from. A person reading a track needs
    /// to know whether a mark is theirs.
    public let trigger: String?

    public init(
      ordinal: Int, isAutomatic: Bool, atHostUTC: String, label: String?,
      screenshot: Screenshot?, screenshotAbsence: ScreenshotAbsence?, trigger: String?
    ) {
      self.ordinal = ordinal
      self.isAutomatic = isAutomatic
      self.atHostUTC = atHostUTC
      self.label = label
      self.screenshot = screenshot
      self.screenshotAbsence = screenshotAbsence
      self.trigger = trigger
    }
  }

  /// A product the session declared and did not publish. Named rather than
  /// omitted: a reader who cannot see the trace must learn that there is no
  /// trace, not that this session had nothing to say about it.
  public struct MissingProduct: Sendable, Equatable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
      self.name = name
      self.reason = reason
    }
  }

  public let jobID: String
  public let alignment: Alignment
  public let marks: [Mark]
  public let missingProducts: [MissingProduct]
  /// Marker kinds this session never looked for, carried through from the
  /// capture so their absence does not read as their absence from the run.
  public let notDerived: [String]
  /// True when a declared product is missing. The reader says Partial rather
  /// than presenting an incomplete session as a whole one.
  public var isPartial: Bool { !missingProducts.isEmpty }

  public init(
    jobID: String, alignment: Alignment, marks: [Mark],
    missingProducts: [MissingProduct], notDerived: [String]
  ) {
    self.jobID = jobID
    self.alignment = alignment
    self.marks = marks
    self.missingProducts = missingProducts
    self.notDerived = notDerived
  }
}

extension DiagnosticSessionReading {
  /// How far from a mark a screenshot may have been taken and still be shown
  /// beside it. Past this it is a picture of a different moment, and the reader
  /// says so rather than letting the eye assume otherwise.
  public static let screenshotAppliesWithinMs = 150

  /// Builds the reading from a session's own artifacts.
  ///
  /// `markersDocument` is the published `markers.json`. `screenshots` are the
  /// captures and their real shutter instants. `declaredButMissing` is what the
  /// session promised and did not deliver.
  public static func make(
    markersDocument: [String: Any],
    screenshots: [(artifactName: String, capturedAtUTC: String)] = [],
    observedScreenshots: [ObservedScreenshot] = [],
    failedScreenshots: [(atHostUTC: String, reason: String)] = [],
    declaredButMissing: [MissingProduct] = [],
    calibration: Alignment? = nil
  ) -> DiagnosticSessionReading {
    let jobID = markersDocument["jobId"] as? String ?? ""
    let raw = markersDocument["markers"] as? [[String: Any]] ?? []
    let notDerived = (markersDocument["notDerived"] as? [[String: Any]] ?? [])
      .compactMap { $0["kind"] as? String }

    var marks: [Mark] = []
    for (index, entry) in raw.enumerated() {
      let at = entry["atHostUTC"] as? String
      let isAutomatic = (entry["kind"] as? String) == "auto"
      let instant = at.flatMap(ISO8601Timestamps.parse)

      var screenshot: Screenshot?
      var absence: ScreenshotAbsence?
      if let instant {
        let offsets = screenshots.compactMap { shot -> (Screenshot, Int)? in
          guard let taken = ISO8601Timestamps.parse(shot.capturedAtUTC) else { return nil }
          let delta = Int((taken.timeIntervalSince(instant) * 1000).rounded())
          return (
            Screenshot(
              artifactName: shot.artifactName, capturedAtUTC: shot.capturedAtUTC,
              takenAfterMarkMs: delta),
            abs(delta)
          )
        }
        if let nearest = offsets.min(by: { $0.1 < $1.1 }) {
          if nearest.1 <= screenshotAppliesWithinMs {
            screenshot = nearest.0
          } else {
            absence = .takenTooFarFromTheMark(offsetMs: nearest.0.takenAfterMarkMs)
          }
        }

        // A capture whose observed window contains the mark might be this
        // moment. Whether it is depends on where inside that window the
        // shutter opened, which nothing recorded - so when the window is
        // wider than the rule, the reader says the rule cannot decide rather
        // than deciding on its behalf.
        if screenshot == nil {
          let tolerance = Double(screenshotAppliesWithinMs) / 1000
          for observed in observedScreenshots {
            guard let start = ISO8601Timestamps.parse(observed.windowStartUTC),
              let end = ISO8601Timestamps.parse(observed.windowEndUTC),
              // A mark comes first and the shutter follows, so the mark is
              // usually just before the window rather than inside it. What
              // matters is whether the window overlaps the mark's tolerance
              // at all.
              end.timeIntervalSince(instant) >= -tolerance,
              start.timeIntervalSince(instant) <= tolerance
            else { continue }
            let width = Int((end.timeIntervalSince(start) * 1000).rounded())
            if width <= screenshotAppliesWithinMs {
              screenshot = Screenshot(
                artifactName: observed.artifactName,
                capturedAtUTC: observed.windowStartUTC,
                takenAfterMarkMs: Int((start.timeIntervalSince(instant) * 1000).rounded()))
            } else {
              absence = .shutterWindowWiderThanTheRule(windowMs: width)
            }
            break
          }
        }
        if screenshot == nil, absence == nil {
          // A failure at this mark is a better answer than "nothing was taken".
          if let failure = failedScreenshots.first(where: {
            ISO8601Timestamps.parse($0.atHostUTC).map {
              abs($0.timeIntervalSince(instant)) * 1000 <= Double(screenshotAppliesWithinMs)
            } == true
          }) {
            absence = .captureFailed(reason: failure.reason)
          } else {
            absence = .notCaptured
          }
        }
      } else {
        absence = .notCaptured
      }

      marks.append(
        Mark(
          ordinal: index + 1,
          isAutomatic: isAutomatic,
          atHostUTC: at ?? "",
          label: entry["label"] as? String,
          screenshot: screenshot,
          screenshotAbsence: absence,
          trigger: entry["trigger"] as? String))
    }

    return DiagnosticSessionReading(
      jobID: jobID,
      // Without a calibration fact the honest state is that nothing can be
      // lined up against device time. A default of "probably the same clock"
      // would make every reading below it quietly unsound.
      alignment: calibration
        ?? .cannotAlign(reason: "no host-to-device calibration was established for this session"),
      marks: marks,
      missingProducts: declaredButMissing,
      notDerived: notDerived)
  }
}

/// What the reader is currently pointed at.
///
/// A selected event survives the cursor moving away from it. Reading a stutter
/// means looking at an event and then at the log lines around it, and losing
/// the event because the eye went to a log line would make that impossible.
public struct DiagnosticReaderSelection: Sendable, Equatable {
  public struct Event: Sendable, Equatable {
    public let identity: String
    public let name: String
    public let startUTC: String

    public init(identity: String, name: String, startUTC: String) {
      self.identity = identity
      self.name = name
      self.startUTC = startUTC
    }
  }

  public private(set) var cursorUTC: String
  public private(set) var event: Event?

  public init(cursorUTC: String, event: Event? = nil) {
    self.cursorUTC = cursorUTC
    self.event = event
  }

  /// Moving the cursor - by clicking a log line, say - never changes which
  /// event is selected.
  public mutating func moveCursor(to instant: String) {
    cursorUTC = instant
  }

  /// Only choosing an event changes the event.
  public mutating func select(_ event: Event) {
    self.event = event
    cursorUTC = event.startUTC
  }

  /// How far the cursor has drifted from the selected event, so the reader can
  /// say the selection is still there and no longer under the cursor.
  public func cursorOffsetFromEventMs() -> Int? {
    guard let event, let start = ISO8601Timestamps.parse(event.startUTC),
      let cursor = ISO8601Timestamps.parse(cursorUTC)
    else { return nil }
    return Int((cursor.timeIntervalSince(start) * 1000).rounded())
  }
}
