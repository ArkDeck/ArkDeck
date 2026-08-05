import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

/// Device Overview workspace. All command execution and lifecycle authority
/// remains in the HDC use-case layer; this view can only render a supplied
/// presentation value and send explicit preview, confirmation, and dispatch
/// requests back to that use case.
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
  @State private var isAdvancedExpanded = false
  @State private var isImpactReviewRequested = false

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
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        statusStrip
        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: 360), spacing: 24, alignment: .topLeading)
          ],
          alignment: .leading,
          spacing: 24
        ) {
          serverAndToolchainSection
          deviceAndChannelSection
          capabilitiesSection
          needsAttentionSection
        }
        advancedDiagnosticsSection
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(24)
    }
    .accessibilityIdentifier("hdc.diagnostics")
    // The refresh control renders in the window's unified toolbar but is
    // declared here, so it exists — and `⌘R` is live — only while the Overview
    // is the visible workspace.
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let onRefresh {
          Button("hdc.devices.refresh", action: onRefresh)
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityIdentifier("hdc.devices.refresh")
            .disabled(isRefreshInFlight)
        }
      }
    }
    .sheet(isPresented: impactReviewBinding) {
      HDCRecoveryImpactSheet(
        presentation: presentation,
        onConfirm: onConfirmRecoveryImpactPreview.map { confirm in
          {
            confirm()
            isImpactReviewRequested = false
          }
        },
        onCancel: { isImpactReviewRequested = false })
    }
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

  // MARK: - Status strip

  private var statusStrip: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 168), spacing: 20, alignment: .topLeading)],
      alignment: .leading,
      spacing: 12
    ) {
      statusItem(
        titleKey: "overview.status.server",
        tone: serverHealthTone,
        value: Text(LocalizedStringKey(serverHealthKey)),
        id: "overview.status.server.value")
      statusItem(
        titleKey: "overview.status.trust",
        tone: trustTone,
        value: Text(LocalizedStringKey(trustSummaryKey)),
        id: "overview.status.trust.value")
      statusItem(
        titleKey: "overview.status.channel",
        tone: channelTone,
        value: Text(LocalizedStringKey(channelSummaryKey)),
        id: "overview.status.channel.value")
      statusItem(
        titleKey: "overview.status.needsAttention",
        tone: needsAttentionTone,
        value: Text(needsAttentionSummary),
        id: "overview.status.needsAttention.value")
    }
    .overlay(alignment: .topTrailing) {
      if isRefreshInFlight {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("overview.status.refreshing")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("overview.status.refreshing")
        }
      }
    }
  }

  private func statusItem(
    titleKey: String,
    tone: StatusTone,
    value: Text,
    id: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(LocalizedStringKey(titleKey))
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        // The symbol is redundant with the adjacent status text on purpose:
        // no status here may be readable by colour alone.
        Image(systemName: tone.symbol)
          .foregroundStyle(tone.color)
          .accessibilityHidden(true)
        value
          .font(.body)
          .accessibilityIdentifier(id)
      }
    }
  }

  // MARK: - Sections

  private var serverAndToolchainSection: some View {
    section("overview.section.serverToolchain", id: "overview.section.serverToolchain") {
      diagnosticsGrid {
        field("overview.field.serverHealth", presentation.serverHealth.rawValue, id: "hdc.health")
        field("overview.field.endpoint", presentation.endpoint, id: "hdc.endpoint")
        field(
          "overview.field.clientVersion", presentation.clientVersion,
          id: "hdc.toolchain.clientVersion")
        field(
          "overview.field.serverVersion", presentation.serverVersion,
          id: "hdc.toolchain.serverVersion")
        field(
          "overview.field.daemonVersion", presentation.daemonVersion,
          id: "hdc.toolchain.daemonVersion")
        field("overview.field.source", presentation.source, id: "hdc.toolchain.source")
        field(
          "overview.field.platformTrust", presentation.platformTrust, id: "hdc.toolchain.trust")
      }
      if onSelectUserConfiguredExecutable != nil {
        Button("overview.action.chooseExecutable") { isSelectingExecutable = true }
          .accessibilityIdentifier("hdc.toolchain.chooseExecutable")
          .disabled(isRefreshInFlight)
      }
    }
  }

  private var deviceAndChannelSection: some View {
    section("overview.section.deviceChannel", id: "overview.section.deviceChannel") {
      diagnosticsGrid {
        field("overview.field.authorization", authorizationText, id: "hdc.authorization")
        field("overview.field.channelProtection", protectionText, id: "hdc.channelProtection")
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("overview.field.deviceEvents")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        deviceEventList
      }
    }
  }

  private var capabilitiesSection: some View {
    section("overview.section.capabilities", id: "overview.section.capabilities") {
      diagnosticsGrid {
        field("overview.field.ownership", presentation.ownership.rawValue, id: "hdc.ownership")
        field("overview.field.subserver", subserverText, id: "hdc.subserver")
        field(
          "overview.field.lifecycleAvailability", lifecycleAvailabilityText,
          id: "hdc.lifecycle.availability")
      }
    }
  }

  private var needsAttentionSection: some View {
    section("overview.section.needsAttention", id: "overview.section.needsAttention") {
      if attentionItems.isEmpty && !recoveryNeedsAttention {
        Text("overview.attention.clear")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("overview.attention.clear")
      }
      ForEach(attentionItems) { item in
        VStack(alignment: .leading, spacing: 4) {
          Label {
            Text(LocalizedStringKey(item.titleKey))
          } icon: {
            Image(systemName: item.tone.symbol).foregroundStyle(item.tone.color)
          }
          .font(.subheadline.weight(.semibold))
          Text(item.reason)
            .font(.callout)
            .accessibilityIdentifier(item.id)
            .fixedSize(horizontal: false, vertical: true)
          Text(LocalizedStringKey(item.nextStepKey))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      recoveryControls
    }
  }

  private var advancedDiagnosticsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        isAdvancedExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .accessibilityHidden(true)
          Text("overview.section.advanced")
            .font(.headline)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("overview.advanced.toggle")
      .accessibilityAddTraits(.isHeader)
      if isAdvancedExpanded {
        Divider()
        diagnosticsGrid {
          field(
            "overview.field.path", presentation.absolutePath, id: "hdc.toolchain.path",
            style: .monospaced)
          field(
            "overview.field.hash", presentation.hash, id: "hdc.toolchain.hash",
            style: .monospaced)
          field(
            "overview.field.generation", presentation.generation, id: "hdc.generation",
            style: .digits)
          field("overview.field.endpointSource", endpointSourceText, id: "hdc.endpoint.source")
          field("overview.field.ownershipBasis", ownershipBasisText, id: "hdc.ownership.basis")
          field(
            "overview.field.autoLifecycleDispatches",
            String(presentation.automaticLifecycleDispatchCount),
            id: "hdc.counters.autoLifecycle",
            style: .digits)
          field(
            "overview.field.autoSubserverDispatches",
            String(presentation.automaticSubserverDispatchCount),
            id: "hdc.counters.autoSubserver",
            style: .digits)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Recovery

  @ViewBuilder
  private var recoveryControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch presentation.lifecycleRecovery {
      case .unavailable(let reason):
        Text(reason)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("hdc.lifecycle.recoveryUnavailable")
          .fixedSize(horizontal: false, vertical: true)
        recoveryPreviewButton
      case .preview:
        recoveryPreviewButton
      case .confirmed(let confirmation):
        Label {
          Text(
            "Recovery impact confirmed for generation \(confirmation.generation). Dispatch remains separately gated."
          )
          .accessibilityIdentifier("hdc.lifecycle.confirmed")
          .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "checkmark.seal").foregroundStyle(.green)
        }
        .font(.callout)
        if let onDispatchConfirmedRecovery {
          Button("overview.recovery.dispatch", action: onDispatchConfirmedRecovery)
            .accessibilityIdentifier("hdc.lifecycle.dispatch")
        }
      case .blocked(let reason):
        Label {
          Text(reason)
            .accessibilityIdentifier("hdc.lifecycle.recoveryBlocked")
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        .font(.callout)
        recoveryPreviewButton
      }
      Text(
        "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("hdc.lifecycle.previewRequirement")
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var recoveryPreviewButton: some View {
    if let onRequestRecoveryImpactPreview {
      Button("overview.recovery.previewImpact") {
        isImpactReviewRequested = true
        onRequestRecoveryImpactPreview()
      }
      .accessibilityIdentifier("hdc.lifecycle.requestImpactPreview")
    }
  }

  /// The review sheet opens only once a real impact snapshot exists. A request
  /// that resolves to blocked or unavailable therefore never produces a modal
  /// that looks like it could still continue.
  private var impactReviewBinding: Binding<Bool> {
    Binding(
      get: { isImpactReviewRequested && presentation.lifecycleImpactPreview != nil },
      set: { isImpactReviewRequested = $0 })
  }

  // MARK: - Building blocks

  private func section<Content: View>(
    _ titleKey: String,
    id: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(LocalizedStringKey(titleKey))
        .font(.headline)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(.isHeader)
      Divider()
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func diagnosticsGrid<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      content()
    }
  }

  private enum FieldStyle {
    case plain
    case monospaced
    case digits
  }

  @ViewBuilder
  private func field(
    _ titleKey: String,
    _ value: String,
    id: String,
    style: FieldStyle = .plain
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(LocalizedStringKey(titleKey))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      // Keep diagnostics exposed as a stable static-text accessibility value.
      // On macOS, text selection changes the accessibility representation and
      // makes the read-only value unavailable to UI automation, so the full
      // value is wrapped instead of truncated or made selectable.
      Text(value)
        .modifier(FieldTextStyle(style: style))
        .accessibilityIdentifier(id)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private struct FieldTextStyle: ViewModifier {
    let style: FieldStyle

    func body(content: Content) -> some View {
      switch style {
      case .plain: content
      case .monospaced: content.font(.body.monospaced())
      case .digits: content.font(.body.monospacedDigit())
      }
    }
  }

  /// Bounded, per-event rows for reading, plus one combined accessibility
  /// value so the exact ordered, redacted history stays a single stable
  /// assistive-technology and automation string.
  private var deviceEventList: some View {
    VStack(alignment: .leading, spacing: 3) {
      if presentation.deviceEvents.isEmpty {
        Text(deviceEventsText)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(presentation.deviceEvents.enumerated()), id: \.offset) { _, event in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.timestamp)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(event.kind.rawValue)
              .font(.caption)
            if let identifier = event.redactedDeviceIdentifier {
              Text(identifier)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(Text(deviceEventsText))
    .accessibilityIdentifier("hdc.devices.events")
  }

  // MARK: - Derived presentation values

  private struct AttentionItem: Identifiable {
    let id: String
    let titleKey: String
    let reason: String
    let nextStepKey: String
    let tone: StatusTone
  }

  private enum StatusTone {
    case ok
    case warning
    case danger
    case unknown

    var color: Color {
      switch self {
      case .ok: .green
      case .warning: .orange
      case .danger: .red
      case .unknown: .secondary
      }
    }

    var symbol: String {
      switch self {
      case .ok: "checkmark.circle"
      case .warning: "exclamationmark.triangle"
      case .danger: "xmark.octagon"
      case .unknown: "questionmark.circle"
      }
    }
  }

  private var attentionItems: [AttentionItem] {
    var items: [AttentionItem] = []
    if let error = configurationError ?? importerError {
      items.append(
        AttentionItem(
          id: "hdc.toolchain.configurationError",
          titleKey: "overview.attention.configuration",
          reason: error,
          nextStepKey: "overview.attention.nextStep.chooseExecutable",
          tone: .danger))
    }
    if presentation.authorization != .ready {
      items.append(
        AttentionItem(
          id: "overview.attention.trust.reason",
          titleKey: "overview.attention.trust",
          reason: authorizationText,
          nextStepKey: "overview.attention.nextStep.refresh",
          tone: .warning))
    }
    if let tcpWarning = presentation.tcpUnprotectedWarning {
      items.append(
        AttentionItem(
          id: "hdc.tcp.warning",
          titleKey: "overview.attention.channel",
          reason: tcpWarning,
          nextStepKey: "overview.attention.nextStep.isolatedNetwork",
          tone: .warning))
    }
    if let keyAccessError = presentation.keyAccessError {
      items.append(
        AttentionItem(
          id: "hdc.keyAccessError",
          titleKey: "overview.attention.keyAccess",
          reason: keyAccessError,
          nextStepKey: "overview.attention.nextStep.keyAccess",
          tone: .danger))
    }
    if let criticalGateMessage = presentation.criticalGateMessage {
      items.append(
        AttentionItem(
          id: "hdc.lifecycle.criticalGate",
          titleKey: "overview.attention.criticalGate",
          reason: criticalGateMessage,
          nextStepKey: "overview.attention.nextStep.criticalGate",
          tone: .warning))
    }
    return items
  }

  private var recoveryNeedsAttention: Bool {
    if case .blocked = presentation.lifecycleRecovery { return true }
    return false
  }

  private var needsAttentionCount: Int {
    attentionItems.count + (recoveryNeedsAttention ? 1 : 0)
  }

  private var needsAttentionSummary: String {
    switch needsAttentionCount {
    case 0: String(localized: "overview.status.needsAttention.none")
    case 1: String(localized: "overview.status.needsAttention.one")
    default:
      String(
        format: String(localized: "overview.status.needsAttention.other"), needsAttentionCount)
    }
  }

  private var needsAttentionTone: StatusTone {
    needsAttentionCount == 0 ? .ok : .warning
  }

  private var serverHealthKey: String {
    switch presentation.serverHealth {
    case .healthy: "overview.serverHealth.healthy"
    case .unavailable: "overview.serverHealth.unavailable"
    case .unknown: "overview.serverHealth.unknown"
    }
  }

  private var serverHealthTone: StatusTone {
    switch presentation.serverHealth {
    case .healthy: .ok
    case .unavailable: .danger
    case .unknown: .unknown
    }
  }

  private var trustSummaryKey: String {
    switch presentation.authorization {
    case .ready: "overview.trust.ready"
    case .unauthorizedWaitingForTrust: "overview.trust.waiting"
    case .denied: "overview.trust.denied"
    case .timedOut: "overview.trust.timedOut"
    case .cancelled: "overview.trust.cancelled"
    case .keyAccessDenied: "overview.trust.keyAccessDenied"
    case .unavailable: "overview.trust.unavailable"
    }
  }

  private var trustTone: StatusTone {
    switch presentation.authorization {
    case .ready: .ok
    case .unauthorizedWaitingForTrust, .timedOut, .cancelled, .unavailable: .warning
    case .denied, .keyAccessDenied: .danger
    }
  }

  private var channelSummaryKey: String {
    switch presentation.channelProtection {
    case .encryptedVerified: "overview.channel.encryptedVerified"
    case .unverifiedAssumeUnprotected: "overview.channel.unverified"
    }
  }

  private var channelTone: StatusTone {
    switch presentation.channelProtection {
    case .encryptedVerified: .ok
    case .unverifiedAssumeUnprotected: .warning
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

  private var lifecycleAvailabilityText: String {
    switch presentation.lifecycleRecovery {
    case .unavailable: "unavailable"
    case .preview: "impact preview available for confirmation"
    case .confirmed: "confirmed; dispatch separately gated"
    case .blocked: "blocked"
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
}

/// Host-wide recovery impact, reviewed before any confirmation exists. The
/// sheet can only confirm the exact snapshot it displays; it never dispatches.
private struct HDCRecoveryImpactSheet: View {
  let presentation: HDCDiagnosticsPresentation
  let onConfirm: (() -> Void)?
  let onCancel: () -> Void
  @FocusState private var isCancelFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("overview.recovery.sheetTitle")
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      if let snapshot = presentation.lifecycleImpactPreview {
        Text("Server recovery impact preview")
          .font(.headline)
          .accessibilityIdentifier("hdc.lifecycle.impactPreview")
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          row("overview.impact.action", snapshot.action.rawValue, id: "hdc.lifecycle.action")
          row("overview.impact.endpoint", snapshot.endpoint.rawValue, id: "hdc.lifecycle.endpoint")
          row(
            "overview.impact.generation", String(snapshot.generation),
            id: "hdc.lifecycle.generation")
          row(
            "overview.impact.ownership", snapshot.ownership.rawValue, id: "hdc.lifecycle.ownership")
          row(
            "overview.impact.devices",
            snapshot.affectedDeviceCoordinators.joined(separator: ", "),
            id: "hdc.lifecycle.devices")
          row(
            "overview.impact.jobs", snapshot.affectedJobs.joined(separator: ", "),
            id: "hdc.lifecycle.jobs")
          row(
            "overview.impact.otherClients", otherClientText(snapshot.otherClientDetection),
            id: "hdc.lifecycle.otherClients")
          row(
            "overview.impact.interruption", snapshot.expectedInterruption,
            id: "hdc.lifecycle.interruption")
          row(
            "overview.impact.recoveryPath", snapshot.recoveryPath,
            id: "hdc.lifecycle.recoveryPath")
        }
        Text(
          "This preview requires an exact-generation user confirmation before recovery can dispatch."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("hdc.lifecycle.confirmationRequired")
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("overview.recovery.cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .focused($isCancelFocused)
          .accessibilityIdentifier("hdc.lifecycle.cancelImpactPreview")
        if let onConfirm, let snapshot = presentation.lifecycleImpactPreview {
          Button(
            String(
              format: String(localized: "overview.recovery.confirmGeneration"),
              snapshot.generation),
            action: onConfirm
          )
          .accessibilityIdentifier("hdc.lifecycle.confirmImpactPreview")
        }
      }
    }
    .padding(24)
    .frame(minWidth: 520, maxWidth: 640, alignment: .leading)
    .defaultFocus($isCancelFocused, true)
  }

  private func row(_ titleKey: String, _ value: String, id: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(LocalizedStringKey(titleKey))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      Text(value)
        .accessibilityIdentifier(id)
        .fixedSize(horizontal: false, vertical: true)
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
