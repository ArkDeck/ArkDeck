import AppKit
import ArkDeckWorkflows
import Combine
import SwiftUI

@main
struct ArkDeckApp: App {
  @StateObject private var hdcDiagnostics = HDCStatusViewModel(
    provider: HDCApplicationDiagnosticsFacade.make())
  @StateObject private var autoUpdate = AutoUpdateViewModel()
  @StateObject private var runtimeHistory = RuntimeHistoryViewModel(
    provider: RuntimeHistoryApplicationFacade.make())
  @StateObject private var flashWorkspace = FlashWorkspaceViewModel(
    provider: FlashApplicationFacade.make())
  @StateObject private var debugWorkspace = DebugWorkspaceViewModel(
    provider: DebugApplicationFacade.make())

  var body: some Scene {
    WindowGroup {
      AppShellView(
        hdcDiagnostics: hdcDiagnostics,
        autoUpdate: autoUpdate,
        runtimeHistory: runtimeHistory,
        flashWorkspace: flashWorkspace,
        debugWorkspace: debugWorkspace
      )
      .task {
        hdcDiagnostics.refresh()
        autoUpdate.startup()
        runtimeHistory.refresh()
        flashWorkspace.refresh()
        debugWorkspace.refresh()
      }
    }
    .defaultSize(width: 1180, height: 760)
    Settings {
      AutoUpdateSettingsView(model: autoUpdate)
        .frame(width: 520)
        .padding(24)
    }
  }
}

/// Shell navigation is presentation vocabulary owned by the App target; the
/// domain package deliberately knows nothing about it.
private enum ArkDeckNavigationItem: String, CaseIterable, Hashable, Identifiable, Sendable {
  case overview
  case flash
  case debug
  case uiDump
  case trace
  case history

  var id: String { rawValue }

  var localizationKey: String {
    switch self {
    case .overview: "app.navigation.overview"
    case .flash: "app.navigation.flash"
    case .debug: "app.navigation.debug"
    case .uiDump: "app.navigation.uiDump"
    case .trace: "app.navigation.trace"
    case .history: "app.navigation.history"
    }
  }

  var systemImageName: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .flash: "bolt"
    case .debug: "ladybug"
    case .uiDump: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .history: "clock.arrow.circlepath"
    }
  }

  var accessibilityIdentifier: String { "app.navigation.\(rawValue)" }
}

/// Native window shell: system split view, unified toolbar, and one workspace
/// per navigation item. Implemented workspaces consume only their own Runtime
/// projections; features without an accepted production surface remain
/// explicit rather than re-rendering another page's data under a new title.
private struct AppShellView: View {
  @SceneStorage("app.shell.selection")
  private var storedSelection = ArkDeckNavigationItem.overview.rawValue
  @ObservedObject var hdcDiagnostics: HDCStatusViewModel
  @ObservedObject var autoUpdate: AutoUpdateViewModel
  @ObservedObject var runtimeHistory: RuntimeHistoryViewModel
  @ObservedObject var flashWorkspace: FlashWorkspaceViewModel
  @ObservedObject var debugWorkspace: DebugWorkspaceViewModel

  private var selectedItem: ArkDeckNavigationItem {
    ArkDeckNavigationItem(rawValue: storedSelection) ?? .overview
  }

  private var selection: Binding<ArkDeckNavigationItem?> {
    Binding(
      get: { selectedItem },
      set: { storedSelection = ($0 ?? .overview).rawValue })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("app.navigation.section.device") {
          navigationRow(.overview)
        }
        Section("app.navigation.section.workflows") {
          navigationRow(.flash)
          navigationRow(.debug)
          navigationRow(.uiDump)
          navigationRow(.trace)
        }
        Section("app.navigation.section.records") {
          navigationRow(.history)
        }
      }
      .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 300)
      .navigationTitle("app.shell.title")
    } detail: {
      detail
        .navigationTitle(Text(LocalizedStringKey(selectedItem.localizationKey)))
        .toolbar { updateAttentionToolbarItem }
    }
    .frame(minWidth: 900, minHeight: 600)
  }

  @ViewBuilder
  private var detail: some View {
    switch selectedItem {
    case .overview:
      HDCStatusView(
        presentation: hdcDiagnostics.presentation,
        onRefresh: hdcDiagnostics.refresh,
        isRefreshInFlight: hdcDiagnostics.isRefreshInFlight,
        onRequestRecoveryImpactPreview: hdcDiagnostics.requestRecoveryImpactPreview,
        onConfirmRecoveryImpactPreview: hdcDiagnostics.confirmRecoveryImpactPreview,
        onDispatchConfirmedRecovery: hdcDiagnostics.dispatchConfirmedRecoveryAction,
        onSelectUserConfiguredExecutable: hdcDiagnostics.selectUserConfiguredExecutable,
        configurationError: hdcDiagnostics.configurationError)
    case .history:
      RuntimeHistoryView(
        presentation: runtimeHistory.presentation,
        isRefreshInFlight: runtimeHistory.isRefreshInFlight,
        onRefresh: runtimeHistory.refresh)
    case .flash:
      FlashWorkspaceView(
        model: flashWorkspace,
        runtimeHistory: runtimeHistory.presentation,
        isRuntimeHistoryRefreshing: runtimeHistory.isRefreshInFlight,
        onRefreshRuntimeHistory: runtimeHistory.refresh,
        onOpenHistory: { storedSelection = ArkDeckNavigationItem.history.rawValue })
    case .debug:
      DebugWorkspaceView(
        model: debugWorkspace,
        onOpenHistory: { storedSelection = ArkDeckNavigationItem.history.rawValue })
    case .uiDump, .trace:
      UnavailableFeatureView(
        titleKey: selectedItem.localizationKey,
        systemImageName: selectedItem.systemImageName)
    }
  }

  /// Only update states the user has to act on reach the main window; the
  /// complete update flow stays in the system Settings scene.
  @ToolbarContentBuilder
  private var updateAttentionToolbarItem: some ToolbarContent {
    if let attention = autoUpdate.attention {
      ToolbarItem(placement: .automatic) {
        SettingsLink {
          Label(
            LocalizedStringKey(attention.localizationKey),
            systemImage: attention.systemImageName)
          .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier("app.toolbar.updateAttention")
      }
    }
  }

  private func navigationRow(_ item: ArkDeckNavigationItem) -> some View {
    Label {
      Text(LocalizedStringKey(item.localizationKey))
    } icon: {
      Image(systemName: item.systemImageName)
    }
    .accessibilityIdentifier(item.accessibilityIdentifier)
    .tag(item)
  }
}

private struct AutoUpdateSettingsView: View {
  @ObservedObject var model: AutoUpdateViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("update.title")
        .font(.title2)
      Toggle(
        "update.automaticChecks",
        isOn: Binding(
          get: { model.automaticChecksEnabled },
          set: { enabled in model.setAutomaticChecksEnabled(enabled) })
      )
      .accessibilityIdentifier("update.automaticChecks")
      Text("update.privacyDisclosure")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("update.checkNow", action: model.checkManually)
          .accessibilityIdentifier("update.checkNow")
          .disabled(model.isBusy || !model.canCheck)
        Button("update.download", action: model.download)
          .accessibilityIdentifier("update.download")
          .disabled(model.isBusy || !model.canDownload)
        Button("update.reveal", action: model.reveal)
          .accessibilityIdentifier("update.reveal")
          .disabled(model.isBusy || !model.canReveal)
      }
      Text(LocalizedStringKey(model.statusKey))
        .font(.headline)
        .accessibilityIdentifier("update.status")
      if let releaseNotesSummary = model.releaseNotesSummary {
        Text(releaseNotesSummary)
          .textSelection(.enabled)
      }
      Text("update.manualInstallDisclosure")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

@MainActor
private final class AutoUpdateViewModel: ObservableObject {
  @Published private(set) var automaticChecksEnabled = true
  @Published private(set) var statusKey = "update.status.idle"
  @Published private(set) var releaseNotesSummary: String?
  @Published private(set) var isBusy = false
  @Published private(set) var canCheck = true
  @Published private(set) var canDownload = false
  @Published private(set) var canReveal = false
  /// Only states the user has to act on reach the main window. Idle and
  /// up-to-date results stay in the Settings scene.
  @Published private(set) var attention: Attention?

  enum Attention: String, Sendable {
    case available
    case awaitingConsent
    case failed

    var localizationKey: String {
      switch self {
      case .available: "update.toolbar.available"
      case .awaitingConsent: "update.toolbar.awaitingConsent"
      case .failed: "update.toolbar.failed"
      }
    }

    var systemImageName: String {
      switch self {
      case .available: "arrow.down.circle"
      case .awaitingConsent: "hand.raised"
      case .failed: "exclamationmark.triangle"
      }
    }
  }

  private let service: AutoUpdateService?
  private let identity = AutoUpdateApplicationFacade.currentProductIdentity()
  private var started = false
  /// UI automation drives a declared state instead of the real updater, which
  /// is neither deterministic nor free of network effects. It is only the
  /// state: the mapping below is the product's own, so a test reads what the
  /// App really renders rather than a second copy of the rules.
  private let usesFixture: Bool

  init() {
    usesFixture = AutoUpdateUIFixture.isSelected()
    guard !usesFixture else {
      service = nil
      return
    }
    service = try? AutoUpdateApplicationFacade.make()
    if service == nil { statusKey = "update.status.unavailable" }
  }

  func startup() {
    if usesFixture {
      guard !started else { return }
      started = true
      Task { await synchronize() }
      return
    }
    guard !started, let service else { return }
    started = true
    Task {
      do {
        try await service.recoverOrphanPartials()
        automaticChecksEnabled = await service.automaticChecksEnabled
        _ = try await service.checkAutomaticallyIfDue(identity: identity)
        await synchronize()
      } catch AutoUpdateServiceError.automaticChecksDisabled,
        AutoUpdateServiceError.automaticCheckNotDue
      {
        await synchronize()
      } catch {
        // Only connectivity failure is softened. Integrity, replay and local-state failures keep
        // the service's explicit failed presentation instead of looking like a routine miss.
        if case .failed(.network) = await service.state {
          statusKey = "update.status.automaticCheckIncomplete"
          isBusy = false
        } else {
          await synchronize()
        }
      }
    }
  }

  func setAutomaticChecksEnabled(_ enabled: Bool) {
    automaticChecksEnabled = enabled
    guard let service else { return }
    Task { await service.setAutomaticChecksEnabled(enabled) }
  }

  func checkManually() {
    // Under the fixture a check re-reads the declared state, so one launched
    // instance walks every state through the App's real check path.
    if usesFixture {
      Task { await synchronize() }
      return
    }
    guard let service else { return }
    isBusy = true
    statusKey = "update.status.checking"
    Task {
      do {
        _ = try await service.checkManually(identity: identity)
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  func download() {
    guard let service else { return }
    isBusy = true
    statusKey = "update.status.downloading"
    Task {
      do {
        _ = try await service.downloadAvailableUpdate()
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  func reveal() {
    guard let service else { return }
    isBusy = true
    Task {
      do {
        _ = try await service.handoff(
          explicitConsent: true, revealer: FinderUpdateArtifactRevealer())
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  private func synchronize() async {
    let state: AutoUpdateState
    if usesFixture {
      guard let declared = AutoUpdateUIFixture.state() else { return }
      state = declared
    } else if let service {
      state = await service.state
    } else {
      return
    }
    isBusy = false
    canCheck = true
    canDownload = false
    canReveal = false
    releaseNotesSummary = nil
    attention = nil
    switch state {
    case .idle:
      statusKey = "update.status.idle"
    case .checking:
      statusKey = "update.status.checking"
      isBusy = true
      canCheck = false
    case .available(let feed):
      statusKey = "update.status.available"
      releaseNotesSummary = feed.payload.releaseNotesSummary
      canDownload = true
      attention = .available
    case .noUpdate:
      statusKey = "update.status.current"
    case .downloading:
      statusKey = "update.status.downloading"
      isBusy = true
      canCheck = false
    case .verifying:
      statusKey = "update.status.verifying"
      isBusy = true
      canCheck = false
    case .awaitingConsent(let feed, _):
      statusKey = "update.status.awaitingConsent"
      releaseNotesSummary = feed.payload.releaseNotesSummary
      canCheck = false
      canReveal = true
      attention = .awaitingConsent
    case .handedOff:
      statusKey = "update.status.handedOff"
      canCheck = false
    case .failed:
      statusKey = "update.status.failed"
      attention = .failed
    case .cancelled:
      statusKey = "update.status.cancelled"
    }
  }
}

private struct FinderUpdateArtifactRevealer: UpdateArtifactRevealing {
  @MainActor
  func revealInFinder(_ url: URL) throws {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

/// Bridges the App presentation to a domain-owned state provider. The model
/// has no candidate, process runner, lifecycle executor, or durable-audit
/// access of its own.
@MainActor
private final class HDCStatusViewModel: ObservableObject {
  @Published private(set) var presentation: HDCDiagnosticsPresentation = .loading
  @Published private(set) var configurationError: String?
  @Published private(set) var isRefreshInFlight = false
  let lifecycleDispatchIsProductionComposed: Bool
  private let provider: any HDCApplicationDiagnosticsProviding

  init(provider: any HDCApplicationDiagnosticsProviding) {
    self.provider = provider
    lifecycleDispatchIsProductionComposed = provider.lifecycleDispatchIsProductionComposed
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self else { return }
      defer { self.isRefreshInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
    }
  }

  func requestRecoveryImpactPreview() {
    load { provider in await provider.requestRecoveryImpactPreview() }
  }

  func confirmRecoveryImpactPreview() {
    load { provider in await provider.confirmRecoveryImpactPreview() }
  }

  func dispatchConfirmedRecovery() {
    load { provider in await provider.dispatchConfirmedRecovery() }
  }

  var dispatchConfirmedRecoveryAction: (() -> Void)? {
    guard lifecycleDispatchIsProductionComposed else { return nil }
    return dispatchConfirmedRecovery
  }

  func selectUserConfiguredExecutable(_ url: URL) {
    guard !isRefreshInFlight else { return }
    let provider = provider
    Task { [weak self] in
      do {
        let next = try await provider.selectUserConfiguredExecutable(url)
        guard !Task.isCancelled else { return }
        self?.configurationError = nil
        self?.presentation = next
      } catch {
        self?.configurationError =
          "Unable to retain access to the selected HDC executable: \(error)"
      }
    }
  }

  private func load(
    _ operation:
      @escaping @Sendable (any HDCApplicationDiagnosticsProviding) async
      -> HDCDiagnosticsPresentation
  ) {
    let provider = provider
    Task { [weak self] in
      let next = await operation(provider)
      guard !Task.isCancelled else { return }
      self?.presentation = next
    }
  }
}
