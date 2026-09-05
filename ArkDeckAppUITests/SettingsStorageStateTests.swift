import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Headless tests of the Settings view model compiled into this runner. The
/// controlled provider never reaches the Runtime, a device or the Keychain.
@MainActor
final class SettingsStorageStateTests: XCTestCase {
  /// The refresh is not one-shot: a failure reports, the same entry point
  /// tries again, and the retry publishes. The failure being retried is
  /// cleared for the attempt, so a pane shows the attempt rather than the past.
  func testAFailedRefreshReportsAndTheSameEntryPointRecovers() async throws {
    let provider = ControlledSettingsStateProvider()
    let model = SettingsWorkspaceViewModel(
      provider: provider, remoteSourceProvider: UnusedRemoteSourceStateProvider())

    await provider.enqueue(.failure(SettingsStateTestError.expectedFailure))
    model.refresh()
    XCTAssertTrue(model.isRefreshing)
    try await waitUntil { !model.isRefreshing }
    XCTAssertNil(model.presentation)
    XCTAssertNotNil(model.storageError)

    await provider.enqueue(.success(Self.published))
    model.refresh()
    XCTAssertTrue(model.isRefreshing, "a second refresh must not be refused as a duplicate")
    XCTAssertNil(
      model.storageError, "an attempt in flight does not keep reporting the failure it retries")
    try await waitUntil { !model.isRefreshing }
    XCTAssertEqual(model.presentation, Self.published)
    XCTAssertNil(model.storageError)
    let refreshes = await provider.refreshCount
    XCTAssertEqual(refreshes, 2)
  }

  /// A refresh that fails after a presentation was published keeps what the
  /// panes already show and reports beside it; the next success replaces it.
  func testALaterFailureKeepsThePublishedPresentationAndReports() async throws {
    let provider = ControlledSettingsStateProvider()
    let model = SettingsWorkspaceViewModel(
      provider: provider, remoteSourceProvider: UnusedRemoteSourceStateProvider())

    await provider.enqueue(.success(Self.published))
    model.refresh()
    try await waitUntil { !model.isRefreshing }
    XCTAssertEqual(model.presentation, Self.published)

    await provider.enqueue(.failure(SettingsStateTestError.expectedFailure))
    model.refresh()
    try await waitUntil { !model.isRefreshing }
    XCTAssertEqual(model.presentation, Self.published)
    XCTAssertNotNil(model.storageError)

    await provider.enqueue(.success(Self.published))
    model.refresh()
    try await waitUntil { !model.isRefreshing }
    XCTAssertNil(model.storageError)
  }

  private static let published = SettingsApplicationPresentation(
    general: SettingsGeneralPresentation(
      appName: "ArkDeck", appVersion: "0.0", buildVersion: "1",
      platform: "macOS 26.0.0", architecture: "arm64"),
    storage: SettingsStoragePresentation(
      generation: 2, rootPath: "/private/tmp/sessions", usesCustomRoot: false,
      totalQuotaBytes: 12 * 1_024 * 1_024 * 1_024,
      safetyMarginBytes: 3 * 1_024 * 1_024 * 1_024,
      retentionDays: 45, runtimeArtifacts: nil, sessionRoot: nil))

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw SettingsStateTestError.timedOut }
      await Task.yield()
    }
  }
}

private enum SettingsStateTestError: Error {
  case expectedFailure
  case unexpectedCall
  case timedOut
}

private actor ControlledSettingsStateProvider: SettingsApplicationProviding {
  private var outcomes: [Result<SettingsApplicationPresentation, Error>] = []
  private(set) var refreshCount = 0

  func enqueue(_ outcome: Result<SettingsApplicationPresentation, Error>) {
    outcomes.append(outcome)
  }

  func refresh() async throws -> SettingsApplicationPresentation {
    refreshCount += 1
    guard !outcomes.isEmpty else { throw SettingsStateTestError.unexpectedCall }
    return try outcomes.removeFirst().get()
  }

  func updateStoragePolicy(
    totalQuotaBytes: UInt64, safetyMarginBytes: UInt64, retentionDays: UInt64
  ) async throws -> SettingsApplicationPresentation {
    throw SettingsStateTestError.unexpectedCall
  }

  func selectStorageRoot(_ url: URL) async throws -> SettingsApplicationPresentation {
    throw SettingsStateTestError.unexpectedCall
  }

  func resetStorageRoot() async throws -> SettingsApplicationPresentation {
    throw SettingsStateTestError.unexpectedCall
  }

  func previewDiagnosticBundle(at destination: URL) async throws
    -> SettingsDiagnosticBundlePreview
  {
    throw SettingsStateTestError.unexpectedCall
  }

  func exportDiagnosticBundle(
    to destination: URL, approvedPreview: SettingsDiagnosticBundlePreview
  ) async throws -> URL {
    throw SettingsStateTestError.unexpectedCall
  }
}

private struct UnusedRemoteSourceStateProvider: RemoteBuildSourceProviding {
  func listSources() async throws -> [RemoteBuildSourcePresentation] {
    throw SettingsStateTestError.unexpectedCall
  }

  func probe(
    draft: RemoteBuildSourceDraft, credential: RemoteBuildSourceCredentialInput?
  ) async throws -> RemoteBuildSourceProbe {
    throw SettingsStateTestError.unexpectedCall
  }

  func save(probe: RemoteBuildSourceProbe) async throws -> RemoteBuildSourcePresentation {
    throw SettingsStateTestError.unexpectedCall
  }

  func remove(sourceID: UUID) async throws {
    throw SettingsStateTestError.unexpectedCall
  }

  func listDirectory(sourceID: UUID, relativePath: String) async throws
    -> RemoteBuildDirectoryListing
  {
    throw SettingsStateTestError.unexpectedCall
  }

  func fetchNativeLibrary(sourceID: UUID, relativePath: String) async throws
    -> RemoteBuildNativeLibraryArtifact
  {
    throw SettingsStateTestError.unexpectedCall
  }
}
