import ArkDeckWorkflows
import Foundation
import Observation

@MainActor
@Observable
final class SettingsWorkspaceViewModel {
  static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

  private(set) var presentation: SettingsApplicationPresentation?
  private(set) var isRefreshing = false
  private(set) var isStorageBusy = false
  private(set) var isDiagnosticsBusy = false
  private(set) var storageError: String?
  private(set) var diagnosticPreview: SettingsDiagnosticBundlePreview?
  private(set) var diagnosticDestination: URL?
  private(set) var exportedDiagnosticURL: URL?
  private(set) var diagnosticsMessage: String?
  private(set) var remoteSources: [RemoteBuildSourcePresentation] = []
  private(set) var isRemoteSourcesBusy = false
  private(set) var remoteSourceError: String?
  private(set) var remoteSourceProbe: RemoteBuildSourceProbe?

  private let provider: any SettingsApplicationProviding
  private let remoteSourceProvider: any RemoteBuildSourceProviding
  private var remoteSourceProbeGeneration = 0

  init(
    provider: any SettingsApplicationProviding,
    remoteSourceProvider: any RemoteBuildSourceProviding = RemoteBuildSourceApplicationFacade.make()
  ) {
    self.provider = provider
    self.remoteSourceProvider = remoteSourceProvider
  }

  func refreshRemoteSources() {
    guard !isRemoteSourcesBusy else { return }
    isRemoteSourcesBusy = true
    remoteSourceError = nil
    let provider = remoteSourceProvider
    Task { [weak self] in
      do {
        self?.remoteSources = try await provider.listSources()
      } catch {
        self?.remoteSourceError = error.localizedDescription
      }
      self?.isRemoteSourcesBusy = false
    }
  }

  func clearRemoteSourceProbe() {
    // Editing or closing the form invalidates the request as well as its UI.
    // A provider can still finish; it must not republish a superseded probe.
    remoteSourceProbeGeneration += 1
    remoteSourceProbe = nil
    remoteSourceError = nil
  }

  func probeRemoteSource(
    draft: RemoteBuildSourceDraft,
    credential: RemoteBuildSourceCredentialInput?
  ) async -> RemoteBuildSourceProbe? {
    guard !isRemoteSourcesBusy else { return nil }
    isRemoteSourcesBusy = true
    clearRemoteSourceProbe()
    let generation = remoteSourceProbeGeneration
    defer { isRemoteSourcesBusy = false }
    let result: Result<RemoteBuildSourceProbe, Error>
    do {
      result = .success(try await remoteSourceProvider.probe(draft: draft, credential: credential))
    } catch {
      result = .failure(error)
    }
    guard generation == remoteSourceProbeGeneration, !Task.isCancelled else { return nil }
    switch result {
    case .success(let probe):
      remoteSourceProbe = probe
      return probe
    case .failure(let error):
      remoteSourceError = error.localizedDescription
      return nil
    }
  }

  func saveRemoteSource(_ probe: RemoteBuildSourceProbe) async -> Bool {
    guard !isRemoteSourcesBusy, remoteSourceProbe == probe else { return false }
    isRemoteSourcesBusy = true
    remoteSourceError = nil
    defer { isRemoteSourcesBusy = false }
    do {
      _ = try await remoteSourceProvider.save(probe: probe)
      remoteSources = try await remoteSourceProvider.listSources()
      remoteSourceProbe = nil
      return true
    } catch {
      remoteSourceError = error.localizedDescription
      return false
    }
  }

  func removeRemoteSource(_ sourceID: UUID) async {
    guard !isRemoteSourcesBusy else { return }
    isRemoteSourcesBusy = true
    remoteSourceError = nil
    defer { isRemoteSourcesBusy = false }
    do {
      try await remoteSourceProvider.remove(sourceID: sourceID)
      remoteSources = try await remoteSourceProvider.listSources()
    } catch {
      remoteSourceError = error.localizedDescription
    }
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

func settingsText(_ key: String) -> String {
  NSLocalizedString(
    key,
    tableName: "SettingsLocalizable",
    bundle: .main,
    value: key,
    comment: "")
}
