import ArkDeckCore
import ArkDeckWorkflows
import Combine
import SwiftUI

@main
struct ArkDeckApp: App {
  @StateObject private var hdcDiagnostics = HDCStatusViewModel(
    provider: HDCApplicationDiagnosticsFacade.make())

  var body: some Scene {
    WindowGroup {
      AppShellView(hdcDiagnostics: hdcDiagnostics)
        .task {
          hdcDiagnostics.refresh()
        }
    }
  }
}

private struct AppShellView: View {
  @State private var selection: ArkDeckNavigationItem? = .overview
  @ObservedObject var hdcDiagnostics: HDCStatusViewModel

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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(32)
      }
      .navigationTitle("app.shell.title")
    }
    .frame(minWidth: 860, minHeight: 560)
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
