import Foundation

/// The closed coverage classification vocabulary of the CLI product spec (§14).
public enum ProductCoverageClassification: String, CaseIterable, Sendable {
  case direct
  case generic
  case local
  case presentation
  case platformService
  case `internal`
  case refused
  case blocked
}

/// One App product capability: a route, tab, panel, menu action or other
/// user-triggerable surface that the coverage manifest must classify.
///
/// The App references these identities from its navigation and tab enums, so
/// a surface cannot exist in the App without a stable feature ID, and the
/// registry cannot name a surface the App no longer has without the contract
/// tests noticing (§14 "orphan or unknown ID fails closed").
public struct AppProductCapability: Sendable, Equatable {
  public let id: String
  /// The surface identity from `docs/design/implementation-coverage.json`,
  /// or a `menu.*` identity for a menu command.
  public let surface: String
  public let title: String
  public let owner: String
  public let classification: ProductCoverageClassification
  /// The CLI argv patterns that reach the same product outcome. Empty only
  /// for `presentation`, which by definition needs no leaf.
  public let cliEquivalent: [String]

  public init(
    id: String, surface: String, title: String, owner: String,
    classification: ProductCoverageClassification, cliEquivalent: [String]
  ) {
    self.id = id
    self.surface = surface
    self.title = title
    self.owner = owner
    self.classification = classification
    self.cliEquivalent = cliEquivalent
  }
}

/// The App's navigation routes, each bound to its capability identity.
public enum AppNavigationCapability: String, CaseIterable, Sendable {
  case overview = "app.overview.main"
  case flash = "app.flash.main"
  case debug = "app.debug.artifacts"
  case uiDump = "app.viewer.main"
  case trace = "app.trace.capture"
  case device = "app.device.control"
  case diagnostics = "app.diagnostics.capture"
  case history = "app.history.list"
}

/// The Debug workspace tabs, each bound to its capability identity.
public enum AppDebugTabCapability: String, CaseIterable, Sendable {
  case artifacts = "app.debug.artifacts"
  case logs = "app.debug.logs"
  case apps = "app.debug.apps"
  case network = "app.debug.network"
  case commands = "app.debug.commands"
}

/// The Viewer inspector tabs, each bound to its capability identity.
public enum AppViewerTabCapability: String, CaseIterable, Sendable {
  case properties = "app.viewer.properties"
  case layout = "app.viewer.layout"
  case accessibility = "app.viewer.accessibility"
  case rawDump = "app.viewer.raw"
  case advancedDump = "app.viewer.advanced"
}

/// `openspec/contracts/app-product-capability-registry.yaml` is generated from
/// this table by `arkdeck maintainer contracts export`; the contract tests hold
/// the two identical.
public enum AppProductCapabilityRegistry {
  public static let schemaVersion = "arkdeck.app-product-capability-registry/1"

  public static func capability(id: String) -> AppProductCapability? {
    capabilities.first { $0.id == id }
  }

  private static func entry(
    _ surface: String, _ title: String, _ owner: String,
    _ classification: ProductCoverageClassification, _ cli: [String] = []
  ) -> AppProductCapability {
    AppProductCapability(
      id: "app." + surface, surface: surface, title: title, owner: owner,
      classification: classification, cliEquivalent: cli)
  }

  public static let capabilities: [AppProductCapability] = [
    // Shell
    entry("shell.navigation", "Workspace navigation", "AppShell", .presentation),
    entry("shell.inspector", "Inspector panel chrome", "AppShell", .presentation),
    entry(
      "shell.recovery", "Recovery and human-action banner", "AppShell", .direct,
      ["arkdeck human-action list", "arkdeck recovery cleanup list", "arkdeck control-action list"]),
    // Device
    entry(
      "device.details", "Observed device details", "Device", .direct,
      ["arkdeck device candidates", "arkdeck target show --target <id>"]),
    entry(
      "device.trust", "First-trust prompt and adoption", "Device", .direct,
      ["arkdeck device wait --candidate <key> ...", "arkdeck target adopt --candidate <key> ..."]),
    entry(
      "device.rename", "Local display name", "Device", .local,
      ["arkdeck device display-name set ...", "arkdeck target display-name set ..."]),
    entry(
      "device.control", "Typed pointer input", "Device", .direct,
      ["arkdeck input tap ...", "arkdeck input long-press ...", "arkdeck input swipe ..."]),
    entry(
      "device.recording", "Screen capture and recording", "Device", .direct,
      ["arkdeck screen capture", "arkdeck screen record --inputs-file <path>"]),
    entry("device.events", "Live input event feedback", "Device", .presentation, ["arkdeck job events --job <id>"]),
    // Overview
    entry(
      "overview.main", "Current target and next step", "Overview", .direct,
      ["arkdeck doctor", "arkdeck target availability --target <id>"]),
    entry(
      "overview.environment", "Environment and connection facts", "Overview", .direct,
      ["arkdeck runtime health", "arkdeck runtime hdc status"]),
    entry(
      "overview.resume", "Resume a waiting execution", "Overview", .direct,
      ["arkdeck agent resume --resume-reference <ref>", "arkdeck human-action resume ..."]),
    entry(
      "overview.hdcImpact", "HDC lifecycle impact preview", "Overview", .direct,
      ["arkdeck runtime hdc impact-preview", "arkdeck control-action show --control-action <id>"]),
    // Flash
    entry(
      "flash.main", "Flash prerequisites and device access", "Flash", .direct,
      ["arkdeck flash prerequisites --target <id>", "arkdeck flash device-access --target <id>",
        "arkdeck flash bootloader-status --target <id>"]),
    entry(
      "flash.plan", "Exact flash plan", "Flash", .direct,
      ["arkdeck flash lane-preview --target <id> ...", "arkdeck job plan --operation flash.full-restore@1 ..."]),
    entry(
      "flash.runtime", "Flash execution timeline", "Flash", .direct,
      ["arkdeck flash run --target <id> --inputs-file <path>", "arkdeck job watch --job <id>"]),
    // Debug
    entry(
      "debug.artifacts", "Native library deployment", "Debug", .direct,
      ["arkdeck artifact import native-library ...", "arkdeck debug native deploy --inputs-file <path>"]),
    entry(
      "debug.browser", "Remote build source browser", "Debug", .platformService,
      ["arkdeck artifact import native-library ...", "arkdeck debug native deploy --inputs-file <path>"]),
    entry(
      "debug.plan", "Deployment replacement plan", "Debug", .direct,
      ["arkdeck job plan --operation deploy.native-library.app-owned@1 ..."]),
    entry("debug.logs", "Bounded HiLog window", "Debug", .direct, ["arkdeck debug logs --inputs-file <path>"]),
    entry("debug.logConfirm", "HiLog request confirmation", "Debug", .presentation, ["arkdeck debug logs --inputs-file <path>"]),
    entry(
      "debug.apps", "HAP install, launch and observe", "Debug", .direct,
      ["arkdeck artifact import hap ...", "arkdeck debug hap --inputs-file <path>"]),
    entry(
      "debug.network", "Typed port forwarding", "Debug", .direct,
      ["arkdeck port-forward create --inputs-file <path>", "arkdeck port-forward remove --inputs-file <path>"]),
    entry(
      "debug.commands", "Closed read-only command templates", "Debug", .direct,
      ["arkdeck debug template list", "arkdeck debug template run --inputs-file <path>"]),
    // Viewer
    entry("viewer.main", "UI dump capture", "Viewer", .direct, ["arkdeck ui-dump capture"]),
    entry("viewer.properties", "Node properties", "Viewer", .local, ["arkdeck ui-dump inspect ..."]),
    entry("viewer.layout", "Layout bounds", "Viewer", .local, ["arkdeck ui-dump inspect ...", "arkdeck ui-dump hit-test ..."]),
    entry("viewer.accessibility", "Accessibility tree", "Viewer", .local, ["arkdeck ui-dump inspect ..."]),
    entry("viewer.raw", "Raw dump text", "Viewer", .direct, ["arkdeck artifact read --job <id> --artifact <id> --allow-sensitive"]),
    entry("viewer.advanced", "Component detail dump", "Viewer", .direct, ["arkdeck ui-dump component-detail --inputs-file <path>"]),
    // Trace
    entry("trace.capture", "Trace capture", "Trace", .direct, ["arkdeck trace capture --inputs-file <path>"]),
    entry("trace.runtime", "Trace runtime readiness", "Trace", .direct, ["arkdeck trace probe --target <id>"]),
    entry(
      "trace.artifact", "Trace artifact export", "Trace", .direct,
      ["arkdeck trace export --job <id> --artifact <id> ...", "arkdeck artifact read ..."]),
    entry("traceViewer.recent", "Recent traces", "TraceViewer", .presentation, ["arkdeck job list"]),
    entry("traceViewer.timeline", "Trace timeline", "TraceViewer", .presentation, ["arkdeck trace inspect ...", "arkdeck analyze trace ..."]),
    entry("traceViewer.event", "Trace event detail", "TraceViewer", .presentation, ["arkdeck trace inspect ..."]),
    entry("traceViewer.range", "Trace range selection", "TraceViewer", .presentation, ["arkdeck trace inspect ..."]),
    entry("traceViewer.annotation", "Trace annotation", "TraceViewer", .presentation),
    entry("traceViewer.loading", "Trace loading state", "TraceViewer", .presentation),
    entry("traceViewer.shortcuts", "Trace keyboard shortcuts", "TraceViewer", .presentation),
    // Diagnostics
    entry("diagnostics.capture", "Diagnostics capture", "Diagnostics", .direct, ["arkdeck diagnostics capture --inputs-file <path>"]),
    entry(
      "diagnostics.reader", "Diagnostics reader", "Diagnostics", .local,
      ["arkdeck diagnostics inspect ...", "arkdeck diagnostics preview ..."]),
    entry("diagnostics.hilogSummary", "HiLog summary", "Diagnostics", .direct, ["arkdeck analyze hilog-summary --inputs-file <path>"]),
    entry("diagnostics.concept", "Diagnostics concept pages", "Diagnostics", .presentation),
    // History
    entry("history.list", "Job history", "History", .direct, ["arkdeck job list"]),
    entry("history.filters", "Saved history filter", "History", .local, ["arkdeck history filter list", "arkdeck history filter save ..."]),
    entry(
      "history.detail", "Job detail and evidence", "History", .direct,
      ["arkdeck job show --job <id>", "arkdeck job result --job <id>", "arkdeck job evidence --job <id>"]),
    entry(
      "history.export", "Artifact and Session export", "History", .direct,
      ["arkdeck artifact export ...", "arkdeck session export preview ...", "arkdeck session export apply ..."]),
    entry("history.context", "Workspace continuation context", "History", .direct, ["arkdeck workspace continuation inspect --source-job <id>"]),
    // Settings
    entry("settings.general", "General preferences", "Settings", .presentation),
    entry(
      "settings.toolchains", "Tool, bundle and signing lifecycle", "Settings", .direct,
      ["arkdeck runtime tool list", "arkdeck runtime bundle list", "arkdeck runtime signing status",
        "arkdeck workspace preset list"]),
    entry("settings.servers", "Remote build sources", "Settings", .platformService, ["arkdeck artifact import native-library ..."]),
    entry("settings.serverEditor", "Remote build source editor", "Settings", .platformService, ["arkdeck artifact import native-library ..."]),
    entry("settings.serverDelete", "Remote build source removal", "Settings", .platformService, ["arkdeck artifact import native-library ..."]),
    entry("settings.storage", "Runtime storage", "Settings", .local, ["arkdeck runtime storage status", "arkdeck runtime storage policy ...", "arkdeck runtime storage root ..."]),
    entry("settings.traceCache", "Trace derived cache", "Settings", .local, ["arkdeck trace cache status", "arkdeck trace cache purge"]),
    entry("settings.traceLicenses", "Trace licenses", "Settings", .presentation),
    entry("settings.updates", "Runtime updates", "Settings", .local, ["arkdeck runtime update check", "arkdeck runtime update status"]),
    entry("settings.diagnostics", "Support bundle", "Settings", .local, ["arkdeck runtime support-bundle preview", "arkdeck runtime support-bundle export ..."]),
    entry("system.panels", "System panels", "AppShell", .presentation),
    entry(
      "automation.retired", "Retired Automation plane", "AppShell", .refused,
      ["arkdeck agent run --operation <reference> ..."]),
    entry("design.components", "Design-system component gallery", "AppShell", .presentation),
    // Menu commands
    entry("menu.trace.capture", "Trace › Capture Trace…", "TraceViewer", .direct, ["arkdeck trace capture --inputs-file <path>"]),
    entry("menu.trace.open", "Trace › Open Trace…", "TraceViewer", .presentation, ["arkdeck trace inspect ..."]),
    entry("menu.trace.reload", "Trace › Reload Trace", "TraceViewer", .presentation),
    entry("menu.trace.filterProcesses", "Trace › Filter Trace Processes", "TraceViewer", .presentation),
    entry("menu.trace.searchEvents", "Trace › Search Events", "TraceViewer", .presentation),
    entry("menu.help.traceShortcuts", "Help › Trace Keyboard Shortcuts", "TraceViewer", .presentation),
  ]
}
