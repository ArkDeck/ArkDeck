import ArkDeckCore
import Foundation

/// The App workspace that originally shaped a Runtime request.
///
/// This is a read-only presentation fact projected from the persisted request.
/// It is never consulted by admission, capability issuance, plan materialization,
/// dispatch, recovery, or target binding. `nil` is the honest result whenever
/// the request does not identify one of the App's product workspaces exactly.
public enum RuntimeWorkspaceKind: String, Sendable, Equatable, Codable, CaseIterable {
  case flash
  case viewer
  case trace
  case diagnostics
  case debug
  // Keep the published wire value so existing daemons and history remain readable.
  case device = "toolkit"
}

public enum RuntimeWorkspaceKindProjection {
  /// Compatibility for status produced before `workspaceKind` existed. Only
  /// operations whose reference is sufficient are projected; the shared
  /// `capture.diagnostics@1` surface deliberately remains unknown.
  public static func unambiguousKind(
    forOperation reference: String
  ) -> RuntimeWorkspaceKind? {
    let operationID = reference.split(separator: "@").first.map(String.init) ?? reference
    guard operationID != "capture.diagnostics" else { return nil }
    return kind(forOperation: reference, inputs: [:])
  }

  public static func kind(
    forOperation reference: String,
    inputs: [String: JSONValue],
    clientName: String? = nil
  ) -> RuntimeWorkspaceKind? {
    if ArkForgeFlashOperation.contains(reference)
      || ArkForgeFlashOperation.containsDurableRecordReference(reference)
    {
      return .flash
    }

    let operationID = reference.split(separator: "@").first.map(String.init) ?? reference
    switch operationID {
    case "debug.hap", "deploy.native-library.app-owned", "port-forward.create",
      "port-forward.remove":
      return .debug
    case "input.tap", "input.long-press", "input.swipe", "capture.screen-sequence":
      return .device
    case "observe.device", "observe.devices":
      return .viewer
    case "analyzer.analyze-trace", "analyzer.summarize-trace":
      return .trace
    case "analyzer.extract-crash-signature", "analyzer.summarize-hilog":
      return .diagnostics
    case "capture.diagnostics":
      return diagnosticsKind(inputs: inputs, clientName: clientName)
    default:
      return nil
    }
  }

  /// Compatibility for detail evidence written before the daemon projected
  /// `workspaceKind` into summaries. Display values are decoded only for the
  /// typed fields that can identify a shared diagnostics request without its
  /// client provenance. Ambiguous diagnostics/debug records remain unknown.
  public static func kind(
    forOperation reference: String,
    parameters: [RuntimeJobParameterPresentation]
  ) -> RuntimeWorkspaceKind? {
    let operationID = reference.split(separator: "@").first.map(String.init) ?? reference
    guard operationID == "capture.diagnostics" else {
      return unambiguousKind(forOperation: reference)
    }

    let booleanNames: Set<String> = [
      "uiComponentTree", "uiDump", "advancedDump", "uiScreenshot",
      "captureHilog", "crashLogs",
    ]
    let arrayNames: Set<String> = ["hilogFilters", "traceCategories"]
    guard parameters.contains(where: {
      booleanNames.contains($0.name) || arrayNames.contains($0.name)
    }) else { return nil }

    var inputs: [String: JSONValue] = [:]
    for parameter in parameters {
      if booleanNames.contains(parameter.name) {
        switch parameter.value {
        case "true": inputs[parameter.name] = .bool(true)
        case "false": inputs[parameter.name] = .bool(false)
        default: continue
        }
      } else if arrayNames.contains(parameter.name),
        let data = parameter.value.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case .array = value
      {
        inputs[parameter.name] = value
      }
    }

    switch diagnosticsKind(inputs: inputs, clientName: nil) {
    case .viewer: return .viewer
    case .trace: return .trace
    case .device: return .device
    case .flash, .diagnostics, .debug: return nil
    }
  }

  private static func diagnosticsKind(
    inputs: [String: JSONValue],
    clientName: String?
  ) -> RuntimeWorkspaceKind {
    if bool("uiComponentTree", in: inputs) || bool("uiDump", in: inputs)
      || bool("advancedDump", in: inputs)
    {
      return .viewer
    }
    if nonemptyArray("traceCategories", in: inputs) { return .trace }
    if bool("uiScreenshot", in: inputs),
      !bool("uiDump", in: inputs),
      !bool("uiComponentTree", in: inputs),
      !bool("advancedDump", in: inputs),
      !bool("captureHilog", in: inputs),
      !bool("crashLogs", in: inputs),
      !nonemptyArray("hilogFilters", in: inputs),
      !nonemptyArray("traceCategories", in: inputs)
    {
      return .device
    }

    switch clientName {
    case ArkDeckAgentClientName.traceWorkspace:
      return .trace
    case ArkDeckAgentClientName.deviceControl:
      return .device
    case ArkDeckAgentClientName.debugLogsWorkspace:
      return .debug
    default:
      return .diagnostics
    }
  }

  private static func bool(_ name: String, in inputs: [String: JSONValue]) -> Bool {
    guard case .bool(true)? = inputs[name] else { return false }
    return true
  }

  private static func nonemptyArray(_ name: String, in inputs: [String: JSONValue]) -> Bool {
    guard case .array(let values)? = inputs[name] else { return false }
    return !values.isEmpty
  }
}
