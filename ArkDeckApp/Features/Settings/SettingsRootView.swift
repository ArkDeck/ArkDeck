import AppKit
import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView<UpdatesContent: View>: View {
  @ObservedObject var model: SettingsWorkspaceViewModel
  let hdcPresentation: HDCDiagnosticsPresentation
  let isHDCRefreshInFlight: Bool
  let hdcConfigurationError: String?
  let hasActiveRuntimeJobs: Bool
  let onHDCRefresh: () -> Void
  let onSelectHDC: (URL) -> Void
  let updatesContent: UpdatesContent

  init(
    model: SettingsWorkspaceViewModel,
    hdcPresentation: HDCDiagnosticsPresentation,
    isHDCRefreshInFlight: Bool,
    hdcConfigurationError: String?,
    hasActiveRuntimeJobs: Bool,
    onHDCRefresh: @escaping () -> Void,
    onSelectHDC: @escaping (URL) -> Void,
    @ViewBuilder updatesContent: () -> UpdatesContent
  ) {
    self.model = model
    self.hdcPresentation = hdcPresentation
    self.isHDCRefreshInFlight = isHDCRefreshInFlight
    self.hdcConfigurationError = hdcConfigurationError
    self.hasActiveRuntimeJobs = hasActiveRuntimeJobs
    self.onHDCRefresh = onHDCRefresh
    self.onSelectHDC = onSelectHDC
    self.updatesContent = updatesContent()
  }

  var body: some View {
    TabView {
      GeneralSettingsPane(model: model)
        .tabItem {
          Label(settingsText("settings.tab.general"), systemImage: "gearshape")
        }
      ToolchainsSettingsPane(
        presentation: hdcPresentation,
        isRefreshInFlight: isHDCRefreshInFlight,
        configurationError: hdcConfigurationError,
        hasActiveRuntimeJobs: hasActiveRuntimeJobs,
        onRefresh: onHDCRefresh,
        onSelectExecutable: onSelectHDC
      )
      .tabItem {
        Label(settingsText("settings.tab.toolchains"), systemImage: "wrench.and.screwdriver")
      }
      StorageSettingsPane(model: model)
        .tabItem {
          Label(settingsText("settings.tab.storage"), systemImage: "externaldrive")
        }
      SettingsPaneContainer {
        updatesContent
      }
      .tabItem {
        Label(settingsText("settings.tab.updates"), systemImage: "arrow.triangle.2.circlepath")
      }
      DiagnosticsSettingsPane(model: model)
        .tabItem {
          Label(settingsText("settings.tab.diagnostics"), systemImage: "stethoscope")
        }
    }
    .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
    .task { model.refresh() }
  }
}

private struct GeneralSettingsPane: View {
  @ObservedObject var model: SettingsWorkspaceViewModel

  var body: some View {
    SettingsPaneContainer {
      SettingsPaneHeader(
        title: settingsText("settings.general.title"),
        subtitle: settingsText("settings.general.subtitle"))
      if let general = model.presentation?.general {
        GroupBox(settingsText("settings.general.build")) {
          SettingsValueGrid(rows: [
            .init(settingsText("settings.general.app"), general.appName),
            .init(settingsText("settings.general.version"), general.appVersion),
            .init(settingsText("settings.general.buildNumber"), general.buildVersion),
            .init(settingsText("settings.general.platform"), general.platform),
            .init(settingsText("settings.general.architecture"), general.architecture),
          ])
        }
      } else {
        SettingsLoadingRow()
      }
      GroupBox(settingsText("settings.general.privacy")) {
        VStack(alignment: .leading, spacing: 10) {
          SettingsAssuranceRow(
            icon: "lock.shield",
            title: settingsText("settings.general.localFirst"),
            detail: settingsText("settings.general.localFirst.detail"))
          SettingsAssuranceRow(
            icon: "icloud.slash",
            title: settingsText("settings.general.noUpload"),
            detail: settingsText("settings.general.noUpload.detail"))
        }
      }
    }
  }
}

private struct ToolchainsSettingsPane: View {
  let presentation: HDCDiagnosticsPresentation
  let isRefreshInFlight: Bool
  let configurationError: String?
  let hasActiveRuntimeJobs: Bool
  let onRefresh: () -> Void
  let onSelectExecutable: (URL) -> Void
  @State private var isSelectingExecutable = false
  @State private var importerError: String?

  var body: some View {
    SettingsPaneContainer {
      SettingsPaneHeader(
        title: settingsText("settings.toolchains.title"),
        subtitle: settingsText("settings.toolchains.subtitle"))
      GroupBox(settingsText("settings.toolchains.hdc")) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 8) {
            Image(systemName: healthSymbol)
              .foregroundStyle(healthColor)
              .accessibilityHidden(true)
            Text(healthText)
              .font(.headline)
            Spacer()
            if isRefreshInFlight {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel(settingsText("settings.common.refreshing"))
            }
          }
          SettingsValueGrid(
            rows: [
              .init(settingsText("settings.toolchains.path"), presentation.absolutePath),
              .init(settingsText("settings.toolchains.source"), presentation.source),
              .init(settingsText("settings.toolchains.sha256"), presentation.hash),
              .init(settingsText("settings.toolchains.trust"), presentation.platformTrust),
              .init(
                settingsText("settings.toolchains.clientVersion"),
                presentation.clientVersion),
              .init(
                settingsText("settings.toolchains.serverVersion"),
                presentation.serverVersion),
              .init(
                settingsText("settings.toolchains.daemonVersion"),
                presentation.daemonVersion),
              .init(settingsText("settings.toolchains.endpoint"), presentation.endpoint),
            ],
            monospacedValueLabels: [
              settingsText("settings.toolchains.path"),
              settingsText("settings.toolchains.sha256"),
            ])
          Divider()
          HStack {
            Button(settingsText("settings.toolchains.choose")) {
              isSelectingExecutable = true
            }
            .accessibilityIdentifier("settings.toolchains.choose")
            .disabled(isRefreshInFlight)
            Button(settingsText("settings.common.refresh"), action: onRefresh)
              .accessibilityIdentifier("settings.toolchains.refresh")
              .disabled(isRefreshInFlight)
            Spacer()
          }
          // The pane's main fact: a running Job keeps the toolchain pinned at
          // its creation; switching is never retroactive. While Jobs are
          // actually running the sentence escalates to a warn callout,
          // because that is the moment it can be misread.
          if hasActiveRuntimeJobs {
            Label {
              Text(settingsText("settings.toolchains.futureJobsActive"))
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("settings.toolchains.activeJobsCallout")
          } else {
            Text(settingsText("settings.toolchains.futureJobs"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if let error = importerError
        ?? (configurationError == nil
          ? nil : settingsText("settings.toolchains.selectionError"))
      {
        SettingsErrorBanner(message: error)
      }
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
        onSelectExecutable(url)
      case .failure:
        importerError = settingsText("settings.toolchains.selectionError")
      }
    }
  }

  private var healthSymbol: String {
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": "checkmark.circle.fill"
    case "unhealthy": "exclamationmark.triangle.fill"
    default: "questionmark.circle"
    }
  }

  private var healthText: String {
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": settingsText("settings.toolchains.health.healthy")
    case "unavailable": settingsText("settings.toolchains.health.unavailable")
    default: settingsText("settings.toolchains.health.unknown")
    }
  }

  private var healthColor: Color {
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": .green
    case "unhealthy": .orange
    default: .secondary
    }
  }
}

private struct StorageSettingsPane: View {
  @ObservedObject var model: SettingsWorkspaceViewModel
  @State private var quotaGiB = ""
  @State private var safetyMarginGiB = ""
  @State private var retentionDays = ""
  @State private var validationMessage: String?
  @State private var isSelectingRoot = false

  var body: some View {
    SettingsPaneContainer {
      SettingsPaneHeader(
        title: settingsText("settings.storage.title"),
        subtitle: settingsText("settings.storage.subtitle"))
      if let storage = model.presentation?.storage {
        GroupBox(settingsText("settings.storage.location")) {
          VStack(alignment: .leading, spacing: 12) {
            LabeledContent(settingsText("settings.storage.root")) {
              Text(storage.rootPath)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
            }
            LabeledContent(settingsText("settings.storage.rootSource")) {
              Text(
                settingsText(
                  storage.usesCustomRoot
                    ? "settings.storage.rootSource.custom"
                    : "settings.storage.rootSource.default"))
            }
            HStack {
              Button(settingsText("settings.storage.chooseRoot")) {
                isSelectingRoot = true
              }
              .accessibilityIdentifier("settings.storage.chooseRoot")
              .disabled(model.isStorageBusy)
              Button(settingsText("settings.storage.resetRoot"), action: model.resetStorageRoot)
                .disabled(model.isStorageBusy || !storage.usesCustomRoot)
              Spacer()
            }
            Text(settingsText("settings.storage.futureJobs"))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        GroupBox(settingsText("settings.storage.policy")) {
          VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
              storageField(
                label: settingsText("settings.storage.quota"),
                value: $quotaGiB,
                suffix: settingsText("settings.storage.gib"),
                id: "settings.storage.quota")
              storageField(
                label: settingsText("settings.storage.margin"),
                value: $safetyMarginGiB,
                suffix: settingsText("settings.storage.gib"),
                id: "settings.storage.margin")
              storageField(
                label: settingsText("settings.storage.retention"),
                value: $retentionDays,
                suffix: settingsText("settings.storage.days"),
                id: "settings.storage.retention")
            }
            HStack {
              Button(settingsText("settings.storage.save"), action: savePolicy)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.storage.save")
                .disabled(model.isStorageBusy)
              if model.isStorageBusy {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityLabel(settingsText("settings.common.saving"))
              }
            }
            Text(settingsText("settings.storage.policyDetail"))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        GroupBox(settingsText("settings.storage.usage")) {
          storageUsage(storage)
        }
      } else {
        SettingsLoadingRow()
      }
      if let validationMessage {
        SettingsErrorBanner(message: validationMessage)
      }
      if let error = model.storageError {
        SettingsErrorBanner(message: error)
      }
    }
    .onAppear(perform: synchronizeDrafts)
    .onChange(of: model.presentation?.storage) { _, _ in synchronizeDrafts() }
    .fileImporter(
      isPresented: $isSelectingRoot,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        validationMessage = nil
        model.selectStorageRoot(url)
      case .failure:
        validationMessage = settingsText("settings.storage.selectionError")
      }
    }
  }

  private func storageField(
    label: String,
    value: Binding<String>,
    suffix: String,
    id: String
  ) -> some View {
    GridRow {
      Text(label)
      HStack(spacing: 8) {
        TextField(label, text: value)
          .frame(width: 110)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(id)
        Text(suffix).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func storageUsage(_ storage: SettingsStoragePresentation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if let currentBytes = storage.currentBytes {
        ProgressView(
          value: Double(currentBytes),
          total: Double(max(storage.totalQuotaBytes, 1))
        )
        .accessibilityLabel(settingsText("settings.storage.usage"))
        .accessibilityValue(
          "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: currentBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.totalQuotaBytes), countStyle: .file))"
        )
        SettingsValueGrid(rows: [
          .init(
            settingsText("settings.storage.currentUsage"),
            ByteCountFormatter.string(
              fromByteCount: Int64(clamping: currentBytes), countStyle: .file)),
          .init(
            settingsText("settings.storage.pinned"),
            pinnedSummary(storage)),
          .init(
            settingsText("settings.storage.admission"),
            settingsText(
              storage.blocksNewHeavyWriters == true
                ? "settings.storage.admission.blocked"
                : "settings.storage.admission.ready")),
        ])
        if storage.unknownPressure == true {
          Label(
            settingsText("settings.storage.unknownPressure"),
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
        }
      } else {
        Label(
          settingsText("settings.storage.measurementUnavailable"),
          systemImage: "questionmark.circle"
        )
        .foregroundStyle(.secondary)
      }
      Text(settingsText("settings.storage.pinGuarantee"))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func pinnedSummary(_ storage: SettingsStoragePresentation) -> String {
    guard let count = storage.pinnedSessionCount, let bytes = storage.pinnedBytes else {
      return settingsText("settings.common.unknown")
    }
    return String.localizedStringWithFormat(
      settingsText("settings.storage.pinnedFormat"),
      count,
      ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
  }

  private func synchronizeDrafts() {
    guard let storage = model.presentation?.storage else { return }
    quotaGiB = String(storage.totalQuotaBytes / SettingsWorkspaceViewModel.gibibyte)
    safetyMarginGiB = String(storage.safetyMarginBytes / SettingsWorkspaceViewModel.gibibyte)
    retentionDays = String(storage.retentionDays)
    validationMessage = nil
  }

  private func savePolicy() {
    guard let quota = UInt64(quotaGiB), let margin = UInt64(safetyMarginGiB),
      let retention = UInt64(retentionDays),
      quota > margin, margin > 0, retention > 0,
      !quota.multipliedReportingOverflow(by: SettingsWorkspaceViewModel.gibibyte).overflow,
      !margin.multipliedReportingOverflow(by: SettingsWorkspaceViewModel.gibibyte).overflow
    else {
      validationMessage = settingsText("settings.storage.validationError")
      return
    }
    validationMessage = nil
    model.updateStoragePolicy(
      totalQuotaBytes: quota * SettingsWorkspaceViewModel.gibibyte,
      safetyMarginBytes: margin * SettingsWorkspaceViewModel.gibibyte,
      retentionDays: retention)
  }
}

private struct DiagnosticsSettingsPane: View {
  @ObservedObject var model: SettingsWorkspaceViewModel

  var body: some View {
    SettingsPaneContainer {
      SettingsPaneHeader(
        title: settingsText("settings.diagnostics.title"),
        subtitle: settingsText("settings.diagnostics.subtitle"))
      GroupBox(settingsText("settings.diagnostics.defaultScope")) {
        VStack(alignment: .leading, spacing: 10) {
          SettingsAssuranceRow(
            icon: "checkmark.circle",
            title: settingsText("settings.diagnostics.metadata"),
            detail: settingsText("settings.diagnostics.metadata.detail"))
          SettingsAssuranceRow(
            icon: "eye.slash",
            title: settingsText("settings.diagnostics.redactedHDC"),
            detail: settingsText("settings.diagnostics.redactedHDC.detail"))
          SettingsAssuranceRow(
            icon: "nosign",
            title: settingsText("settings.diagnostics.rawExcluded"),
            detail: settingsText("settings.diagnostics.rawExcluded.detail"))
        }
      }
      GroupBox(settingsText("settings.diagnostics.export")) {
        VStack(alignment: .leading, spacing: 12) {
          Text(settingsText("settings.diagnostics.previewFirst"))
            .fixedSize(horizontal: false, vertical: true)
          Button(settingsText("settings.diagnostics.chooseAndPreview"), action: chooseDestination)
            .accessibilityIdentifier("settings.diagnostics.preview")
            .disabled(model.isDiagnosticsBusy)
          if model.isDiagnosticsBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(settingsText("settings.common.working"))
          }
          if let destination = model.diagnosticDestination,
            let preview = model.diagnosticPreview
          {
            Divider()
            LabeledContent(settingsText("settings.diagnostics.destination")) {
              Text(destination.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
            }
            SettingsValueGrid(
              rows: [
                .init(
                  settingsText("settings.diagnostics.size"),
                  ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: preview.estimatedBytes),
                    countStyle: .file)),
                .init(settingsText("settings.diagnostics.scopeHash"), preview.scopeSHA256),
                .init(
                  settingsText("settings.diagnostics.deviceRaw"),
                  settingsText(
                    preview.deviceRawExcluded
                      ? "settings.diagnostics.excluded"
                      : "settings.diagnostics.notExcluded")),
              ], monospacedValueLabels: [settingsText("settings.diagnostics.scopeHash")])
            VStack(alignment: .leading, spacing: 5) {
              Text(settingsText("settings.diagnostics.entries"))
                .font(.subheadline.weight(.semibold))
              ForEach(preview.includedEntries, id: \.self) { entry in
                Label(entry, systemImage: "doc")
                  .font(.system(.caption, design: .monospaced))
              }
            }
            Label(
              settingsText("settings.diagnostics.warning"),
              systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            HStack {
              Button(
                settingsText("settings.diagnostics.exportNow"), action: model.exportDiagnostics
              )
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("settings.diagnostics.export")
              .disabled(
                model.isDiagnosticsBusy || model.exportedDiagnosticURL != nil
                  || !preview.deviceRawExcluded)
              if let exportedURL = model.exportedDiagnosticURL {
                Button(settingsText("settings.diagnostics.reveal")) {
                  NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                }
              }
            }
          }
          Text(settingsText("settings.diagnostics.noAutomaticUpload"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let message = model.diagnosticsMessage {
        if model.exportedDiagnosticURL != nil {
          SettingsSuccessBanner(message: message)
        } else {
          SettingsErrorBanner(message: message)
        }
      }
    }
  }

  private func chooseDestination() {
    let panel = NSSavePanel()
    panel.title = settingsText("settings.diagnostics.panelTitle")
    panel.prompt = settingsText("settings.diagnostics.panelPrompt")
    panel.nameFieldStringValue = "ArkDeck-Diagnostics"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      model.previewDiagnostics(at: url)
    }
  }
}

@MainActor
final class SettingsWorkspaceViewModel: ObservableObject {
  static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

  @Published private(set) var presentation: SettingsApplicationPresentation?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isStorageBusy = false
  @Published private(set) var isDiagnosticsBusy = false
  @Published private(set) var storageError: String?
  @Published private(set) var diagnosticPreview: SettingsDiagnosticBundlePreview?
  @Published private(set) var diagnosticDestination: URL?
  @Published private(set) var exportedDiagnosticURL: URL?
  @Published private(set) var diagnosticsMessage: String?

  private let provider: any SettingsApplicationProviding

  init(provider: any SettingsApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      do {
        let presentation = try await provider.refresh()
        guard !Task.isCancelled else { return }
        self?.presentation = presentation
        self?.storageError = nil
      } catch {
        self?.storageError = settingsText("settings.error.refresh")
      }
      self?.isRefreshing = false
    }
  }

  func updateStoragePolicy(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) {
    storageOperation(errorKey: "settings.error.savePolicy") { provider in
      try await provider.updateStoragePolicy(
        totalQuotaBytes: totalQuotaBytes,
        safetyMarginBytes: safetyMarginBytes,
        retentionDays: retentionDays)
    }
  }

  func selectStorageRoot(_ url: URL) {
    storageOperation(errorKey: "settings.error.selectRoot") { provider in
      try await provider.selectStorageRoot(url)
    }
  }

  func resetStorageRoot() {
    storageOperation(errorKey: "settings.error.resetRoot") { provider in
      try await provider.resetStorageRoot()
    }
  }

  func previewDiagnostics(at destination: URL) {
    guard !isDiagnosticsBusy else { return }
    isDiagnosticsBusy = true
    diagnosticDestination = destination
    diagnosticPreview = nil
    exportedDiagnosticURL = nil
    diagnosticsMessage = nil
    let provider = provider
    Task { [weak self] in
      do {
        let preview = try await provider.previewDiagnosticBundle(at: destination)
        guard !Task.isCancelled else { return }
        self?.diagnosticPreview = preview
      } catch {
        self?.diagnosticDestination = nil
        self?.diagnosticsMessage = settingsText("settings.error.previewDiagnostics")
      }
      self?.isDiagnosticsBusy = false
    }
  }

  func exportDiagnostics() {
    guard !isDiagnosticsBusy, let destination = diagnosticDestination,
      let preview = diagnosticPreview
    else { return }
    isDiagnosticsBusy = true
    diagnosticsMessage = nil
    let provider = provider
    Task { [weak self] in
      do {
        let url = try await provider.exportDiagnosticBundle(
          to: destination, approvedPreview: preview)
        guard !Task.isCancelled else { return }
        self?.exportedDiagnosticURL = url
        self?.diagnosticsMessage = settingsText("settings.diagnostics.exported")
      } catch {
        self?.diagnosticsMessage = settingsText("settings.error.exportDiagnostics")
      }
      self?.isDiagnosticsBusy = false
    }
  }

  private func storageOperation(
    errorKey: String,
    _ operation:
      @escaping @Sendable (
        any SettingsApplicationProviding
      ) async throws -> SettingsApplicationPresentation
  ) {
    guard !isStorageBusy else { return }
    isStorageBusy = true
    storageError = nil
    let provider = provider
    Task { [weak self] in
      do {
        let presentation = try await operation(provider)
        guard !Task.isCancelled else { return }
        self?.presentation = presentation
      } catch {
        self?.storageError = settingsText(errorKey)
      }
      self?.isStorageBusy = false
    }
  }
}

private struct SettingsPaneContainer<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) { content }
        .frame(maxWidth: 720, alignment: .topLeading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .top)
    }
  }
}

private struct SettingsPaneHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct SettingsValueRow: Identifiable {
  let label: String
  let value: String
  var id: String { label }

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }
}

private struct SettingsValueGrid: View {
  let rows: [SettingsValueRow]
  var monospacedValueLabels: Set<String> = []

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
      ForEach(rows) { row in
        GridRow {
          Text(row.label)
            .foregroundStyle(.secondary)
          Text(row.value)
            .font(
              monospacedValueLabels.contains(row.label)
                ? .system(.body, design: .monospaced)
                : .body
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SettingsAssuranceRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .frame(width: 20)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct SettingsLoadingRow: View {
  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(settingsText("settings.common.loading"))
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}

private struct SettingsErrorBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.orange)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .combine)
  }
}

private struct SettingsSuccessBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "checkmark.circle.fill")
      .foregroundStyle(.green)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .combine)
  }
}

private func settingsText(_ key: String) -> String {
  NSLocalizedString(
    key,
    tableName: "SettingsLocalizable",
    bundle: .main,
    value: key,
    comment: "")
}
