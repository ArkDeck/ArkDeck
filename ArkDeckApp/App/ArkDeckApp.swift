import AppKit
import ArkDeckCore
import ArkDeckWorkflows
import Combine
import SwiftUI

@main
struct ArkDeckApp: App {
  @StateObject private var hdcDiagnostics = HDCStatusViewModel(
    provider: HDCApplicationDiagnosticsFacade.make())
  @StateObject private var autoUpdate = AutoUpdateViewModel()

  var body: some Scene {
    WindowGroup {
      AppShellView(hdcDiagnostics: hdcDiagnostics, autoUpdate: autoUpdate)
        .task {
          hdcDiagnostics.refresh()
          autoUpdate.startup()
        }
    }
    Settings {
      AutoUpdateSettingsView(model: autoUpdate)
        .frame(width: 520)
        .padding(24)
    }
  }
}

private struct AppShellView: View {
  @State private var selection: ArkDeckNavigationItem? = .overview
  @ObservedObject var hdcDiagnostics: HDCStatusViewModel
  @ObservedObject var autoUpdate: AutoUpdateViewModel

  var body: some View {
    NavigationSplitView {
      List(ArkDeckNavigationItem.allCases, selection: $selection) { item in
        Label {
          Text(LocalizedStringKey(item.localizationKey))
        } icon: {
          Image(systemName: item.systemImageName)
        }
      }
      .navigationTitle("app.shell.title")
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(
            LocalizedStringKey(
              selection?.localizationKey ?? ArkDeckNavigationItem.overview.localizationKey)
          )
          .font(.largeTitle)
          Text("app.shell.status")
            .font(.headline)
          Text("app.shell.nonDestructiveNote")
            .foregroundStyle(.secondary)
          HDCStatusView(
            presentation: hdcDiagnostics.presentation,
            onRequestRecoveryImpactPreview: hdcDiagnostics.requestRecoveryImpactPreview,
            onConfirmRecoveryImpactPreview: hdcDiagnostics.confirmRecoveryImpactPreview,
            onDispatchConfirmedRecovery: hdcDiagnostics.dispatchConfirmedRecoveryAction,
            onSelectUserConfiguredExecutable: hdcDiagnostics.selectUserConfiguredExecutable,
            configurationError: hdcDiagnostics.configurationError)
          Divider()
          AutoUpdateSettingsView(model: autoUpdate)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(32)
      }
      .navigationTitle("app.shell.title")
    }
    .frame(minWidth: 860, minHeight: 560)
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
          set: { enabled in model.setAutomaticChecksEnabled(enabled) }))
      Text("update.privacyDisclosure")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("update.checkNow", action: model.checkManually)
          .disabled(model.isBusy || !model.canCheck)
        Button("update.download", action: model.download)
          .disabled(model.isBusy || !model.canDownload)
        Button("update.reveal", action: model.reveal)
          .disabled(model.isBusy || !model.canReveal)
      }
      Text(LocalizedStringKey(model.statusKey))
        .font(.headline)
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

  private let service: AutoUpdateService?
  private let identity = AutoUpdateApplicationFacade.currentProductIdentity()
  private var started = false

  init() {
    service = try? AutoUpdateApplicationFacade.make()
    if service == nil { statusKey = "update.status.unavailable" }
  }

  func startup() {
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
        // Automatic network failure is intentionally non-modal. Manual checks expose failure.
        statusKey = "update.status.current"
        isBusy = false
      }
    }
  }

  func setAutomaticChecksEnabled(_ enabled: Bool) {
    automaticChecksEnabled = enabled
    guard let service else { return }
    Task { await service.setAutomaticChecksEnabled(enabled) }
  }

  func checkManually() {
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
    guard let service else { return }
    let state = await service.state
    isBusy = false
    canCheck = true
    canDownload = false
    canReveal = false
    releaseNotesSummary = nil
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
    case .awaitingConsent(let artifact):
      statusKey = "update.status.awaitingConsent"
      releaseNotesSummary = artifact.downloaded.url.lastPathComponent
      canCheck = false
      canReveal = true
    case .handedOff:
      statusKey = "update.status.handedOff"
      canCheck = false
    case .failed:
      statusKey = "update.status.failed"
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
  let lifecycleDispatchIsProductionComposed: Bool
  private let provider: any HDCApplicationDiagnosticsProviding

  init(provider: any HDCApplicationDiagnosticsProviding) {
    self.provider = provider
    lifecycleDispatchIsProductionComposed = provider.lifecycleDispatchIsProductionComposed
  }

  func refresh() {
    load { provider in await provider.refresh() }
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
