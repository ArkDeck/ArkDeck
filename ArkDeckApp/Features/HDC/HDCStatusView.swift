import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

/// Minimal HDC diagnostics and explicit lifecycle-control surface. All process
/// execution and lifecycle authority remains in the HDC use-case layer; this
/// view can only render a supplied presentation value and send explicit
/// preview, confirmation, and dispatch requests back to that use case.
struct HDCStatusView: View {
  let presentation: HDCDiagnosticsPresentation
  let onRefresh: (() -> Void)?
  let isRefreshInFlight: Bool
  let onRequestRecoveryImpactPreview: (() -> Void)?
  let onConfirmRecoveryImpactPreview: (() -> Void)?
  let onDispatchConfirmedRecovery: (() -> Void)?
  let onSelectUserConfiguredExecutable: ((URL) -> Void)?
  let configurationError: String?
  @State private var isSelectingExecutable = false
  @State private var importerError: String?

  init(
    presentation: HDCDiagnosticsPresentation,
    onRefresh: (() -> Void)? = nil,
    isRefreshInFlight: Bool = false,
    onRequestRecoveryImpactPreview: (() -> Void)? = nil,
    onConfirmRecoveryImpactPreview: (() -> Void)? = nil,
    onDispatchConfirmedRecovery: (() -> Void)? = nil,
    onSelectUserConfiguredExecutable: ((URL) -> Void)? = nil,
    configurationError: String? = nil
  ) {
    self.presentation = presentation
    self.onRefresh = onRefresh
    self.isRefreshInFlight = isRefreshInFlight
    self.onRequestRecoveryImpactPreview = onRequestRecoveryImpactPreview
    self.onConfirmRecoveryImpactPreview = onConfirmRecoveryImpactPreview
    self.onDispatchConfirmedRecovery = onDispatchConfirmedRecovery
    self.onSelectUserConfiguredExecutable = onSelectUserConfiguredExecutable
    self.configurationError = configurationError
  }

  var body: some View {
    GroupBox("HDC diagnostics") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        field("Path", presentation.absolutePath, id: "hdc.toolchain.path")
        field("Source", presentation.source, id: "hdc.toolchain.source")
        field("Hash", presentation.hash, id: "hdc.toolchain.hash")
        field("Platform trust", presentation.platformTrust, id: "hdc.toolchain.trust")
        field("Client version", presentation.clientVersion, id: "hdc.toolchain.clientVersion")
        field("Server version", presentation.serverVersion, id: "hdc.toolchain.serverVersion")
        field("Daemon version", presentation.daemonVersion, id: "hdc.toolchain.daemonVersion")
        field("Endpoint", presentation.endpoint, id: "hdc.endpoint")
        field("Server health", presentation.serverHealth.rawValue, id: "hdc.health")
        field("Generation", presentation.generation, id: "hdc.generation")
        field("Ownership", presentation.ownership.rawValue, id: "hdc.ownership")
        field("Authorization", authorizationText, id: "hdc.authorization")
        field("Channel protection", protectionText, id: "hdc.channelProtection")
        field("Subserver capability", subserverText, id: "hdc.subserver")
        field(
          "Automatic lifecycle dispatches",
          String(presentation.automaticLifecycleDispatchCount),
          id: "hdc.counters.autoLifecycle")
        field(
          "Automatic subserver dispatches",
          String(presentation.automaticSubserverDispatchCount),
          id: "hdc.counters.autoSubserver")
        field("Endpoint source", endpointSourceText, id: "hdc.endpoint.source")
        field("Ownership basis", ownershipBasisText, id: "hdc.ownership.basis")
        field("Device events", deviceEventsText, id: "hdc.devices.events")
      }
      if let onRefresh {
        Button("hdc.devices.refresh", action: onRefresh)
          .keyboardShortcut("r", modifiers: [.command])
          .accessibilityIdentifier("hdc.devices.refresh")
          .disabled(isRefreshInFlight)
      }
      if onSelectUserConfiguredExecutable != nil {
        Button("Choose HDC executable…") { isSelectingExecutable = true }
          .accessibilityIdentifier("hdc.toolchain.chooseExecutable")
          .disabled(isRefreshInFlight)
      }
      if let error = configurationError ?? importerError {
        Text(error)
          .foregroundStyle(.red)
          .accessibilityIdentifier("hdc.toolchain.configurationError")
      }
      if let tcpWarning = presentation.tcpUnprotectedWarning {
        Text(tcpWarning)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("hdc.tcp.warning")
          .padding(.top, 8)
      }
      if let keyAccessError = presentation.keyAccessError {
        Text(keyAccessError)
          .foregroundStyle(.red)
          .accessibilityIdentifier("hdc.keyAccessError")
          .padding(.top, 4)
      }
      if let criticalGateMessage = presentation.criticalGateMessage {
        Text(criticalGateMessage)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("hdc.lifecycle.criticalGate")
          .padding(.top, 4)
      }
      if let impact = presentation.lifecycleImpactPreview {
        Divider().padding(.vertical, 4)
        Text("Server recovery impact preview")
          .font(.headline)
          .accessibilityIdentifier("hdc.lifecycle.impactPreview")
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          field("Action", impact.action.rawValue, id: "hdc.lifecycle.action")
          field("Endpoint", impact.endpoint.rawValue, id: "hdc.lifecycle.endpoint")
          field("Generation", String(impact.generation), id: "hdc.lifecycle.generation")
          field("Ownership", impact.ownership.rawValue, id: "hdc.lifecycle.ownership")
          field(
            "Affected devices", impact.affectedDeviceCoordinators.joined(separator: ", "),
            id: "hdc.lifecycle.devices")
          field(
            "Affected Jobs", impact.affectedJobs.joined(separator: ", "), id: "hdc.lifecycle.jobs")
          field(
            "Other HDC clients", otherClientText(impact.otherClientDetection),
            id: "hdc.lifecycle.otherClients")
          field(
            "Expected interruption", impact.expectedInterruption, id: "hdc.lifecycle.interruption")
          field("Recovery path", impact.recoveryPath, id: "hdc.lifecycle.recoveryPath")
        }
        Text(
          "This preview requires an exact-generation user confirmation before recovery can dispatch."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("hdc.lifecycle.confirmationRequired")
      }
      recoveryControls
      Text(
        "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("hdc.lifecycle.previewRequirement")
      .padding(.top, 8)
    }
    .accessibilityIdentifier("hdc.diagnostics")
    .fileImporter(
      isPresented: $isSelectingExecutable,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        importerError = nil
        onSelectUserConfiguredExecutable?(url)
      case .failure(let error):
        importerError = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private func field(_ title: String, _ value: String, id: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      // Keep diagnostics exposed as a stable static-text accessibility value.
      // On macOS, text selection changes the accessibility representation and
      // makes the read-only value unavailable to UI automation.
      Text(value).accessibilityIdentifier(id)
    }
  }

  private var authorizationText: String {
    switch presentation.authorization {
    case .ready: "ready"
    case .unauthorizedWaitingForTrust: "unauthorized — unlock and trust the device, then retry"
    case .denied(let reason): "denied — \(reason); retry is non-destructive"
    case .timedOut: "timed out — retry is non-destructive"
    case .cancelled: "cancelled — retry is non-destructive"
    case .keyAccessDenied(let reason): "key access denied — \(reason)"
    case .unavailable(let reason): "unavailable — \(reason)"
    }
  }

  private var protectionText: String {
    switch presentation.channelProtection {
    case .encryptedVerified(let evidence):
      "encrypted verified (\(evidence.evidenceVersion), \(evidence.source))"
    case .unverifiedAssumeUnprotected: "unverified; assumed unprotected"
    }
  }

  private var subserverText: String {
    switch presentation.subserverCapability {
    case .supportedReadOnly: "supported (read-only; no automatic spawn or migration)"
    case .unsupported: "unsupported"
    case .unknown(let reason): "unknown — \(reason)"
    }
  }

  private var endpointSourceText: String {
    presentation.endpointSource?.rawValue ?? "unknown"
  }

  private var ownershipBasisText: String {
    guard let basis = presentation.ownershipBasis else { return "unavailable" }
    return [
      "preExistingServerReceipt=\(basis.preExistingServerReceipt)",
      "zeroAutomaticLifecycleDispatch=\(basis.zeroAutomaticLifecycleDispatch)",
      "generationMintedFromObservation=\(basis.generationMintedFromObservation)",
      "noActiveOrUnreconciledManagedProvenance=\(basis.noActiveOrUnreconciledManagedProvenance)",
    ].joined(separator: "; ")
  }

  private var deviceEventsText: String {
    guard !presentation.deviceEvents.isEmpty else { return "none" }
    return presentation.deviceEvents.map { event in
      var components = [event.timestamp, event.kind.rawValue]
      if let identifier = event.redactedDeviceIdentifier {
        components.append(identifier)
      }
      return components.joined(separator: " ")
    }.joined(separator: " | ")
  }

  @ViewBuilder
  private var recoveryControls: some View {
    switch presentation.lifecycleRecovery {
    case .unavailable(let reason):
      Text(reason)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("hdc.lifecycle.recoveryUnavailable")
      recoveryPreviewButton
    case .preview:
      recoveryPreviewButton
      if let onConfirmRecoveryImpactPreview {
        Button("Confirm displayed recovery impact", action: onConfirmRecoveryImpactPreview)
          .accessibilityIdentifier("hdc.lifecycle.confirmImpactPreview")
      }
    case .confirmed(let confirmation):
      Text(
        "Recovery impact confirmed for generation \(confirmation.generation). Dispatch remains separately gated."
      )
      .foregroundStyle(.green)
      .accessibilityIdentifier("hdc.lifecycle.confirmed")
      if let onDispatchConfirmedRecovery {
        Button("Dispatch confirmed recovery", action: onDispatchConfirmedRecovery)
          .accessibilityIdentifier("hdc.lifecycle.dispatch")
      }
    case .blocked(let reason):
      Text(reason)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("hdc.lifecycle.recoveryBlocked")
      recoveryPreviewButton
    }
  }

  @ViewBuilder
  private var recoveryPreviewButton: some View {
    if let onRequestRecoveryImpactPreview {
      Button("Request recovery impact preview", action: onRequestRecoveryImpactPreview)
        .accessibilityIdentifier("hdc.lifecycle.requestImpactPreview")
    }
  }

  private func otherClientText(_ detection: HDCServerOtherClientDetection) -> String {
    switch detection {
    case .detected(let clients): "detected: \(clients.joined(separator: ", "))"
    case .noneDetectedExternalClientsMayStillExist:
      "none detected; unknown external clients may still exist"
    case .unavailableExternalClientsMayStillExist:
      "unavailable; unknown external clients may still exist"
    }
  }
}
