import ArkDeckCore
import Foundation

/// The product-owned input projections for the four convenience captures
/// backed by `capture.diagnostics@1`.
///
/// A preset is deliberately narrower than the operation descriptor. Callers
/// can still reach the complete descriptor through `agent run`, while the App
/// and CLI convenience names share these exact fixed selections instead of
/// maintaining parallel dictionaries that drift.
public enum DiagnosticCapturePreset {
  public static let operationReference = "capture.diagnostics@1"
  public static let shortCaptureDurationSeconds = 1

  public static func screen(imageType: String? = nil) throws -> [String: JSONValue] {
    if let imageType, !["png", "jpeg"].contains(imageType) {
      throw DiagnosticCapturePresetError.invalid(
        "screenshotImageType must be png or jpeg")
    }
    var inputs = base(
      uiDump: false,
      uiScreenshot: true,
      uiComponentTree: false)
    if let imageType { inputs["screenshotImageType"] = .string(imageType) }
    return inputs
  }

  public static func uiDump() -> [String: JSONValue] {
    base(
      uiDump: true,
      uiScreenshot: true,
      uiComponentTree: true)
  }

  public static func componentDetail(
    windowID: String,
    componentID: String
  ) throws -> [String: JSONValue] {
    guard validComponentIdentifier(windowID), validComponentIdentifier(componentID) else {
      throw DiagnosticCapturePresetError.invalid(
        "windowId and componentId must be 1...20 ASCII decimal digits")
    }
    var inputs = base(
      uiDump: false,
      uiScreenshot: false,
      uiComponentTree: false)
    inputs["advancedDump"] = .bool(true)
    inputs["windowId"] = .string(windowID)
    inputs["componentId"] = .string(componentID)
    return inputs
  }

  public static func trace(
    durationSeconds: Int,
    categories: [String],
    bufferKB: Int,
    ringBuffered: Bool = false
  ) throws -> [String: JSONValue] {
    guard (1...600).contains(durationSeconds) else {
      throw DiagnosticCapturePresetError.invalid(
        "durationSeconds must be in 1...600")
    }
    guard (1_024...65_536).contains(bufferKB) else {
      throw DiagnosticCapturePresetError.invalid(
        "traceBufferKB must be in 1024...65536")
    }
    guard !categories.isEmpty, categories.count <= 24,
      Set(categories).count == categories.count,
      categories.allSatisfy(validTraceCategory)
    else {
      throw DiagnosticCapturePresetError.invalid(
        "traceCategories must contain 1...24 unique ASCII letter, digit, or underscore values of at most 64 bytes"
      )
    }
    var inputs: [String: JSONValue] = [
      "durationSeconds": .integer(Int64(durationSeconds)),
      "hilogFilters": .array([]),
      "traceCategories": .array(categories.map(JSONValue.string)),
      "traceBufferKB": .integer(Int64(bufferKB)),
      "uiDump": .bool(false),
      "crashLogs": .bool(false),
      "uiScreenshot": .bool(false),
      "uiComponentTree": .bool(false),
      "redactionProfile": .string("standard"),
    ]
    if ringBuffered { inputs["ringBuffered"] = .bool(true) }
    return inputs
  }

  /// The Debug workspace's bounded HiLog window, shared by the App's
  /// `submitLogs` and `arkdeck debug logs`. Exactly the dictionary the App has
  /// always sent: `captureHilog` stays at the descriptor default (true) and
  /// every other leg is off, so the effective effect remains read-only.
  public static func logs(
    durationSeconds: Int,
    filters: [String]
  ) throws -> [String: JSONValue] {
    guard (1...600).contains(durationSeconds) else {
      throw DiagnosticCapturePresetError.invalid("durationSeconds must be in 1...600")
    }
    guard filters.count <= 16,
      filters.allSatisfy(DebugTypedValueValidator.isSafeHilogComponent)
    else {
      throw DiagnosticCapturePresetError.invalid(
        "hilogFilters must contain at most 16 typed component filters of at most 200 "
          + "alphanumeric, dot, underscore, colon or hyphen characters")
    }
    return [
      "durationSeconds": .integer(Int64(durationSeconds)),
      "hilogFilters": .array(filters.map(JSONValue.string)),
      "uiDump": .bool(false),
      "crashLogs": .bool(false),
      "uiScreenshot": .bool(false),
      "uiComponentTree": .bool(false),
      "redactionProfile": .string("standard"),
    ]
  }

  private static func base(
    uiDump: Bool,
    uiScreenshot: Bool,
    uiComponentTree: Bool
  ) -> [String: JSONValue] {
    [
      "durationSeconds": .integer(Int64(shortCaptureDurationSeconds)),
      "captureHilog": .bool(false),
      "hilogFilters": .array([]),
      "uiDump": .bool(uiDump),
      "crashLogs": .bool(false),
      "uiScreenshot": .bool(uiScreenshot),
      "uiComponentTree": .bool(uiComponentTree),
      "redactionProfile": .string("standard"),
    ]
  }

  private static func validComponentIdentifier(_ value: String) -> Bool {
    (1...20).contains(value.utf8.count)
      && value.allSatisfy { $0.isASCII && $0.isNumber }
  }

  private static func validTraceCategory(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
      }
  }
}

public enum DiagnosticCapturePresetError: Error, Equatable, Sendable {
  case invalid(String)

  public var reason: String {
    switch self {
    case .invalid(let reason): reason
    }
  }
}
