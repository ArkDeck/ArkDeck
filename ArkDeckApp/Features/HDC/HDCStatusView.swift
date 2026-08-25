import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

/// Device Overview workspace. All command execution and lifecycle authority
/// remains in the HDC use-case layer; this view can only render a supplied
/// presentation value and send explicit preview, confirmation, and dispatch
/// requests back to that use case.
struct HDCStatusView: View {
  let presentation: HDCDiagnosticsPresentation
  let capabilityMatrix: OverviewCapabilityMatrixPresentation
  let onRefresh: (() -> Void)?
  let isRefreshInFlight: Bool
  let onRequestRecoveryImpactPreview: (() -> Void)?
  let onConfirmRecoveryImpactPreview: (() -> Void)?
  let onDispatchConfirmedRecovery: (() -> Void)?
  let onSelectUserConfiguredExecutable: ((URL) -> Void)?
  let configurationError: String?
  /// Content rendered above the diagnostics, inside the same scrolling page.
  /// The Overview's record lives here rather than in a second scroll view, so
  /// one workspace keeps one scroll position and one toolbar.
  let header: AnyView?
  @State private var isSelectingExecutable = false
  @State private var importerError: String?
  @State private var isAdvancedExpanded = false
  @State private var isImpactReviewRequested = false

  init(
    presentation: HDCDiagnosticsPresentation,
    capabilityMatrix: OverviewCapabilityMatrixPresentation = .loading,
    onRefresh: (() -> Void)? = nil,
    isRefreshInFlight: Bool = false,
    onRequestRecoveryImpactPreview: (() -> Void)? = nil,
    onConfirmRecoveryImpactPreview: (() -> Void)? = nil,
    onDispatchConfirmedRecovery: (() -> Void)? = nil,
    onSelectUserConfiguredExecutable: ((URL) -> Void)? = nil,
    configurationError: String? = nil,
    header: AnyView? = nil
  ) {
    self.presentation = presentation
    self.capabilityMatrix = capabilityMatrix
    self.onRefresh = onRefresh
    self.isRefreshInFlight = isRefreshInFlight
    self.onRequestRecoveryImpactPreview = onRequestRecoveryImpactPreview
    self.onConfirmRecoveryImpactPreview = onConfirmRecoveryImpactPreview
    self.onDispatchConfirmedRecovery = onDispatchConfirmedRecovery
    self.onSelectUserConfiguredExecutable = onSelectUserConfiguredExecutable
    self.configurationError = configurationError
    self.header = header
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      if let header { header }
      statusStrip
      // Two fixed columns, not an adaptive grid: `.adaptive` derives its column
      // count from the pane width, so a maximised window laid all four sections
      // side by side and crushed the capability matrix. `.grid2` in the
      // prototype is two columns or one, never four.
      WorkspaceColumns(spacing: WorkspaceMetrics.sectionGap) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          serverAndToolchainSection
          capabilitiesSection
        }
      } trailing: {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          deviceAndChannelSection
          needsAttentionSection
        }
      }
      advancedDiagnosticsSection
    }
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

  /// `.summary-strip` in the prototype: one bordered band whose four cells are
  /// separated by the same hairline as everything else. The adaptive grid this
  /// replaces derived its column count from the pane width, so a wide window
  /// clumped all four cells into the left third; the refresh indicator was an
  /// overlay that landed on top of the fourth cell every time ⌘R ran.
  private var statusStrip: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      HStack(spacing: WorkspaceMetrics.tightGap) {
        Spacer(minLength: 0)
        if isRefreshInFlight {
          ProgressView().controlSize(.small)
          Text("overview.status.refreshing")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("overview.status.refreshing")
        }
      }
      .frame(height: 18)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 0) {
          statusItem(statusStripItems[0])
          Divider()
          statusItem(statusStripItems[1])
          Divider()
          statusItem(statusStripItems[2])
          Divider()
          statusItem(statusStripItems[3])
        }
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            statusItem(statusStripItems[0])
            Divider()
            statusItem(statusStripItems[1])
          }
          Divider()
          HStack(spacing: 0) {
            statusItem(statusStripItems[2])
            Divider()
            statusItem(statusStripItems[3])
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
      )
      .clipShape(
        RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
  }

  /// The strip's four slots, declared once so the wide row and the folded
  /// two-by-two grid cannot drift apart (spec §5.1 fixes both the slots and
  /// their order).
  private struct StatusStripItem {
    let titleKey: String
    let tone: StatusTone
    let value: Text
    let id: String
  }

  private var statusStripItems: [StatusStripItem] {
    [
      StatusStripItem(
        titleKey: "overview.status.server",
        tone: serverHealthTone,
        value: Text(LocalizedStringKey(serverHealthKey)),
        id: "overview.status.server.value"),
      StatusStripItem(
        titleKey: "overview.status.trust",
        tone: trustTone,
        value: Text(LocalizedStringKey(trustSummaryKey)),
        id: "overview.status.trust.value"),
      StatusStripItem(
        titleKey: "overview.status.channel",
        tone: channelTone,
        value: Text(LocalizedStringKey(channelSummaryKey)),
        id: "overview.status.channel.value"),
      StatusStripItem(
        titleKey: "overview.status.needsAttention",
        tone: needsAttentionTone,
        value: Text(needsAttentionSummary),
        id: "overview.status.needsAttention.value"),
    ]
  }

  private func statusItem(_ item: StatusStripItem) -> some View {
    let titleKey = item.titleKey
    let tone = item.tone
    let value = item.value
    let id = item.id
    return VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Text(LocalizedStringKey(titleKey))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: WorkspaceMetrics.tightGap) {
        // The symbol is redundant with the adjacent status text on purpose:
        // no status here may be readable by colour alone.
        Image(systemName: tone.symbol)
          .foregroundStyle(tone.color)
          .accessibilityHidden(true)
        value
          .font(WorkspaceFont.body)
          .lineLimit(2)
          .accessibilityIdentifier(id)
      }
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
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
      if onSelectUserConfiguredExecutable != nil && !presentation.isRuntimeManaged {
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
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Text("overview.field.deviceEvents")
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
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
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Text(capabilityMatrixTitle)
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("overview.capabilities.matrixTitle")
        if let failure = capabilityMatrix.failure, capabilityMatrix.items.isEmpty {
          Label(failure, systemImage: "questionmark.circle")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("overview.capabilities.failure")
        } else if capabilityMatrix.items.isEmpty {
          HStack(spacing: WorkspaceMetrics.tightGap) {
            ProgressView().controlSize(.small)
            Text("overview.capabilities.loading")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
        } else {
          Grid(
            alignment: .leading,
            horizontalSpacing: WorkspaceMetrics.keyColumnGap,
            verticalSpacing: WorkspaceMetrics.tightGap
          ) {
            GridRow {
              Text("overview.capabilities.column.capability")
              Text("overview.capabilities.column.state")
              Text("overview.capabilities.column.evidence")
            }
            .font(WorkspaceFont.label)
            .foregroundStyle(.secondary)
            Divider().gridCellColumns(3)
            ForEach(capabilityMatrix.items) { item in
              GridRow(alignment: .firstTextBaseline) {
                // Capability name and its probe evidence are the same class of
                // value, so they share one mono size instead of 13 next to 10.
                Text(item.name).font(WorkspaceFont.monospacedValue)
                Label {
                  Text(LocalizedStringKey(capabilityStateKey(item.state)))
                    .font(WorkspaceFont.body)
                } icon: {
                  Image(systemName: capabilityStateSymbol(item.state))
                    .foregroundStyle(capabilityStateColor(item.state))
                    .accessibilityHidden(true)
                }
                .accessibilityIdentifier("overview.capabilities.\(item.id).state")
                Text(item.evidence)
                  .font(WorkspaceFont.monospacedValue)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("overview.capabilities.\(item.id).evidence")
              }
            }
          }
        }
      }
    }
  }

  private var capabilityMatrixTitle: String {
    guard let targetID = capabilityMatrix.targetID else {
      return String(localized: "overview.capabilities.title.noTarget")
    }
    return String(
      localized: .overviewCapabilitiesTitleTarget(
        targetID, capabilityMatrix.bindingRevision ?? 0))
  }

  private func capabilityStateKey(_ state: OverviewCapabilityState) -> String {
    switch state {
    case .available: "overview.capabilities.state.available"
    case .limited: "overview.capabilities.state.limited"
    case .unavailable: "overview.capabilities.state.unavailable"
    case .unknown: "overview.capabilities.state.unknown"
    }
  }

  private func capabilityStateSymbol(_ state: OverviewCapabilityState) -> String {
    switch state {
    case .available: "checkmark.circle"
    case .limited: "minus.circle"
    case .unavailable: "xmark.octagon"
    case .unknown: "questionmark.circle"
    }
  }

  private func capabilityStateColor(_ state: OverviewCapabilityState) -> Color {
    switch state {
    case .available: .green
    case .limited: .orange
    case .unavailable: .red
    case .unknown: .secondary
    }
  }

  private var needsAttentionSection: some View {
    section("overview.section.needsAttention", id: "overview.section.needsAttention") {
      if attentionItems.isEmpty && !recoveryNeedsAttention {
        Text("overview.attention.clear")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("overview.attention.clear")
      }
      ForEach(attentionItems) { item in
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Label {
            Text(LocalizedStringKey(item.titleKey))
          } icon: {
            Image(systemName: item.tone.symbol).foregroundStyle(item.tone.color)
          }
          .font(WorkspaceFont.body.weight(.semibold))
          Text(item.reason)
            .font(WorkspaceFont.secondary)
            .accessibilityIdentifier(item.id)
            .fixedSize(horizontal: false, vertical: true)
          Text(LocalizedStringKey(item.nextStepKey))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      recoveryControls
    }
  }

  private var advancedDiagnosticsSection: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionHeaderGap) {
        Button {
          isAdvancedExpanded.toggle()
        } label: {
          HStack(spacing: WorkspaceMetrics.tightGap) {
            Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
              .imageScale(.small)
              .frame(width: 12)
              .accessibilityHidden(true)
            Text("overview.section.advanced")
              .font(WorkspaceFont.sectionTitle)
            Spacer(minLength: 0)
          }
          .frame(minHeight: 24)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .accessibilityIdentifier("overview.advanced.toggle")
        .accessibilityAddTraits(.isHeader)
        // The rule belongs to the section, not to the disclosure state: the
        // last band of the page must not change structure on click.
        Divider()
      }
      if isAdvancedExpanded {
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
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      switch presentation.lifecycleRecovery {
      case .unavailable(let reason):
        Text(reason)
          .font(WorkspaceFont.secondary)
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
        .font(WorkspaceFont.secondary)
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
        .font(WorkspaceFont.secondary)
        recoveryPreviewButton
      }
      Text(
        "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck."
      )
      .font(WorkspaceFont.secondary)
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
    WorkspaceSection(Text(LocalizedStringKey(titleKey)), identifier: id) {
      content()
    }
  }

  private func diagnosticsGrid<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: WorkspaceMetrics.keyColumnGap,
      verticalSpacing: WorkspaceMetrics.rowGap
    ) {
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
      case .plain: content.font(WorkspaceFont.body)
      // Paths, hashes and generations are compared character by character, so
      // they share the one mono size the rest of the App uses (spec §2).
      case .monospaced: content.font(WorkspaceFont.monospacedValue)
      case .digits: content.font(WorkspaceFont.tabularValue)
      }
    }
  }

  /// Bounded, per-event rows for reading, plus one combined accessibility
  /// value so the exact ordered, redacted history stays a single stable
  /// assistive-technology and automation string.
  private var deviceEventList: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      if presentation.deviceEvents.isEmpty {
        Text(deviceEventsText)
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
      } else {
        // A Grid, not free HStacks: timestamp, kind and identifier are columns
        // and have to line up down the list.
        Grid(
          alignment: .leading,
          horizontalSpacing: WorkspaceMetrics.keyColumnGap,
          verticalSpacing: WorkspaceMetrics.rowGap
        ) {
          ForEach(Array(presentation.deviceEvents.enumerated()), id: \.offset) { _, event in
            GridRow(alignment: .firstTextBaseline) {
              Text(event.timestamp)
                .font(WorkspaceFont.monospacedDense.monospacedDigit())
                .foregroundStyle(.secondary)
              Text(event.kind.rawValue)
                .font(WorkspaceFont.secondary)
              // A redacted identifier is one comparable token: elide its middle
              // rather than wrapping it across three lines of fragments.
              Text(event.redactedDeviceIdentifier ?? "")
                .font(WorkspaceFont.monospacedDense)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(event.redactedDeviceIdentifier ?? "")
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
      String(localized: .overviewStatusNeedsAttentionOther(needsAttentionCount))
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
    VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
      Text("overview.recovery.sheetTitle")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      if let snapshot = presentation.lifecycleImpactPreview {
        // A subtitle under the sheet's one heading, not a second heading.
        Text("Server recovery impact preview")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("hdc.lifecycle.impactPreview")
        Grid(
          alignment: .leading,
          horizontalSpacing: WorkspaceMetrics.keyColumnGap,
          verticalSpacing: WorkspaceMetrics.rowGap
        ) {
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
        .font(WorkspaceFont.secondary)
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
              localized: .overviewRecoveryConfirmGeneration(snapshot.generation)),
            action: onConfirm
          )
          .accessibilityIdentifier("hdc.lifecycle.confirmImpactPreview")
        }
      }
    }
    .padding(WorkspaceMetrics.pageInsetHorizontal)
    .frame(minWidth: 520, maxWidth: 640, alignment: .leading)
    .defaultFocus($isCancelFocused, true)
  }

  /// The same fact row the page behind the sheet uses: secondary label, mono
  /// value. Job IDs, device coordinators and the generation are all values a
  /// reader has to compare character by character (spec §2).
  private func row(_ titleKey: String, _ value: String, id: String) -> some View {
    WorkspaceFactRow(
      name: Text(LocalizedStringKey(titleKey)),
      value: Text(value),
      identifier: id)
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
