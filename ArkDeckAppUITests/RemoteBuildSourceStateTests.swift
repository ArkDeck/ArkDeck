import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Headless tests of the same App view-model sources compiled into this runner.
/// The controlled provider never opens SSH, Keychain, the Runtime, or a device.
@MainActor
final class RemoteBuildSourceStateTests: XCTestCase {
  func testSwitchingSourceCannotChooseAnOldEntryWhileLoadingOrAfterSuccess() async throws {
    let fixture = try await makeBrowser()
    fixture.model.open(fixture.entryA)
    XCTAssertEqual(fixture.model.selectedLibraryEntry, fixture.entryA)

    fixture.model.selectSource(fixture.sourceB.id)
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceB.id) }
    XCTAssertNil(fixture.model.listing)
    XCTAssertNil(fixture.model.selectedLibraryEntry)
    fixture.model.open(fixture.entryA)
    XCTAssertNil(fixture.model.selectedEntry)

    let listingB = RemoteBuildDirectoryListing(
      sourceID: fixture.sourceB.id, sourceName: fixture.sourceB.name,
      relativePath: "", entries: [fixture.entryB])
    try await fixture.provider.completeDirectory(for: fixture.sourceB.id, with: .success(listingB))
    try await waitUntil { !fixture.model.isLoading }

    fixture.model.open(fixture.entryA)
    XCTAssertNil(fixture.model.selectedLibraryEntry)
    fixture.model.open(fixture.entryB)
    XCTAssertEqual(fixture.model.selectedSource?.id, fixture.sourceB.id)
    XCTAssertEqual(fixture.model.selectedLibraryEntry, fixture.entryB)
  }

  func testFailedSourceSwitchDoesNotRestoreOldListingOrSelection() async throws {
    let fixture = try await makeBrowser()
    fixture.model.selectSource(fixture.sourceB.id)
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceB.id) }
    fixture.model.open(fixture.entryA)
    try await fixture.provider.completeDirectory(
      for: fixture.sourceB.id, with: .failure(RemoteSourceStateTestError.expectedFailure))
    try await waitUntil { !fixture.model.isLoading }

    fixture.model.open(fixture.entryA)
    XCTAssertNil(fixture.model.listing)
    XCTAssertNil(fixture.model.selectedEntry)
    XCTAssertNil(fixture.model.selectedLibraryEntry)
    XCTAssertNotNil(fixture.model.errorMessage)
  }

  func testClearingSourceDropsTheSelectedLibrary() async throws {
    let fixture = try await makeBrowser()
    fixture.model.open(fixture.entryA)
    XCTAssertEqual(fixture.model.selectedLibraryEntry, fixture.entryA)
    fixture.model.selectSource(nil)
    XCTAssertNil(fixture.model.selectedSourceID)
    XCTAssertNil(fixture.model.listing)
    XCTAssertNil(fixture.model.selectedEntry)
    XCTAssertNil(fixture.model.selectedLibraryEntry)
    XCTAssertFalse(fixture.model.isLoading)
  }

  func testDirectoryResponseMustBelongToTheRequestedSource() async throws {
    let fixture = try await makeBrowser()
    fixture.model.selectSource(fixture.sourceB.id)
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceB.id) }
    try await fixture.provider.completeDirectory(
      for: fixture.sourceB.id,
      with: .success(RemoteBuildDirectoryListing(
        sourceID: fixture.sourceA.id, sourceName: fixture.sourceA.name,
        relativePath: "", entries: [fixture.entryA])))
    try await waitUntil { !fixture.model.isLoading }
    XCTAssertNil(fixture.model.listing)
    XCTAssertNil(fixture.model.selectedLibraryEntry)
    XCTAssertNotNil(fixture.model.errorMessage)
  }

  func testReloadRetriesTheFailedDirectoryInsteadOfReturningToTheRoot() async throws {
    let fixture = try await makeBrowser()
    fixture.model.open(fixture.directoryA)
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceA.id) }
    try await fixture.provider.completeDirectory(
      for: fixture.sourceA.id, with: .failure(RemoteSourceStateTestError.expectedFailure))
    try await waitUntil { !fixture.model.isLoading }
    XCTAssertNil(fixture.model.listing)

    fixture.model.reload()
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceA.id) }
    let requestedPath = await fixture.provider.requestedDirectoryPath(for: fixture.sourceA.id)
    XCTAssertEqual(requestedPath, fixture.directoryA.relativePath)
    try await fixture.provider.completeDirectory(
      for: fixture.sourceA.id,
      with: .success(RemoteBuildDirectoryListing(
        sourceID: fixture.sourceA.id, sourceName: fixture.sourceA.name,
        relativePath: fixture.directoryA.relativePath, entries: [])))
    try await waitUntil { !fixture.model.isLoading }
    XCTAssertEqual(fixture.model.listing?.relativePath, fixture.directoryA.relativePath)
  }

  func testFailedDirectoryCanGoUpWithoutRestoringItsOldListing() async throws {
    let fixture = try await makeBrowser()
    fixture.model.open(fixture.directoryA)
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceA.id) }
    try await fixture.provider.completeDirectory(
      for: fixture.sourceA.id, with: .failure(RemoteSourceStateTestError.expectedFailure))
    try await waitUntil { !fixture.model.isLoading }
    XCTAssertNil(fixture.model.listing)
    XCTAssertEqual(fixture.model.requestedRelativePath, fixture.directoryA.relativePath)
    XCTAssertTrue(fixture.model.canGoUp)

    fixture.model.goUp()
    try await waitUntil { await fixture.provider.hasDirectoryRequest(for: fixture.sourceA.id) }
    let requestedPath = await fixture.provider.requestedDirectoryPath(for: fixture.sourceA.id)
    XCTAssertEqual(requestedPath, "")
    XCTAssertEqual(fixture.model.requestedRelativePath, "")
    XCTAssertFalse(fixture.model.canGoUp)
    XCTAssertNil(fixture.model.listing)
    try await fixture.provider.completeDirectory(
      for: fixture.sourceA.id,
      with: .success(RemoteBuildDirectoryListing(
        sourceID: fixture.sourceA.id, sourceName: fixture.sourceA.name,
        relativePath: "", entries: [fixture.entryA, fixture.directoryA])))
    try await waitUntil { !fixture.model.isLoading }
    XCTAssertEqual(fixture.model.listing?.relativePath, "")
    XCTAssertFalse(fixture.model.canGoUp)
    fixture.model.open(fixture.entryA)
    XCTAssertEqual(fixture.model.selectedLibraryEntry, fixture.entryA)
  }

  func testEditingOrClosingTheEditorDiscardsAnInFlightProbeResult() async throws {
    let provider = ControlledRemoteSourceStateProvider(sources: [])
    let model = SettingsWorkspaceViewModel(
      provider: UnusedSettingsStateProvider(), remoteSourceProvider: provider)
    let draftA = draft("A")
    let request = Task { await model.probeRemoteSource(draft: draftA, credential: nil) }
    try await waitUntil { await provider.hasProbeRequest }

    // Every editable field's onChange and the sheet's dismiss path call this.
    model.clearRemoteSourceProbe()
    try await provider.failProbe()
    let result = await request.value

    XCTAssertNil(result)
    XCTAssertNil(model.remoteSourceProbe)
    XCTAssertNil(model.remoteSourceError)
    XCTAssertFalse(model.isRemoteSourcesBusy)

    // A new edit session can still test and report its own current failure.
    let draftB = draft("B")
    let nextRequest = Task { await model.probeRemoteSource(draft: draftB, credential: nil) }
    try await waitUntil { await provider.hasProbeRequest }
    try await provider.failProbe()
    _ = await nextRequest.value
    XCTAssertEqual(model.remoteSourceError, RemoteSourceStateTestError.expectedFailure.localizedDescription)
    XCTAssertFalse(model.isRemoteSourcesBusy)
  }

  func testCancelledProbeCannotPublishItsLateFailure() async throws {
    let provider = ControlledRemoteSourceStateProvider(sources: [])
    let model = SettingsWorkspaceViewModel(
      provider: UnusedSettingsStateProvider(), remoteSourceProvider: provider)
    let draftA = draft("A")
    let request = Task { await model.probeRemoteSource(draft: draftA, credential: nil) }
    try await waitUntil { await provider.hasProbeRequest }
    request.cancel()
    try await provider.failProbe()
    _ = await request.value
    XCTAssertNil(model.remoteSourceProbe)
    XCTAssertNil(model.remoteSourceError)
    XCTAssertFalse(model.isRemoteSourcesBusy)
  }

  private func makeBrowser() async throws -> BrowserStateFixture {
    let sourceA = source("A")
    let sourceB = source("B")
    let entryA = entry("libA.so")
    let entryB = entry("libB.so")
    let directoryA = RemoteBuildDirectoryEntry(
      name: "release", relativePath: "release", kind: .directory,
      byteCount: nil, modifiedAt: nil)
    let provider = ControlledRemoteSourceStateProvider(sources: [sourceA, sourceB])
    let model = DebugRemoteBuildBrowserViewModel(provider: provider)
    model.loadSources()
    try await waitUntil { await provider.hasDirectoryRequest(for: sourceA.id) }
    try await provider.completeDirectory(
      for: sourceA.id,
      with: .success(RemoteBuildDirectoryListing(
        sourceID: sourceA.id, sourceName: sourceA.name,
        relativePath: "", entries: [entryA, directoryA])))
    try await waitUntil { !model.isLoading }
    return BrowserStateFixture(
      model: model, provider: provider, sourceA: sourceA, sourceB: sourceB,
      entryA: entryA, entryB: entryB, directoryA: directoryA)
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw RemoteSourceStateTestError.timedOut }
      await Task.yield()
    }
  }

  private func source(_ name: String) -> RemoteBuildSourcePresentation {
    RemoteBuildSourcePresentation(
      id: UUID(), name: name, host: "\(name.lowercased()).example", port: 22,
      username: "build", rootPath: "/build", authentication: .password,
      hostKeyFingerprint: "SHA256:fixture", credentialStored: true,
      usesSystemDefaultCredential: false, lastVerifiedAt: .now)
  }

  private func entry(_ name: String) -> RemoteBuildDirectoryEntry {
    RemoteBuildDirectoryEntry(
      name: name, relativePath: name, kind: .nativeLibrary,
      byteCount: 100, modifiedAt: .now)
  }

  private func draft(_ name: String) -> RemoteBuildSourceDraft {
    RemoteBuildSourceDraft(
      name: name, host: "\(name.lowercased()).example", username: "build",
      rootPath: "/build", authentication: .password)
  }
}

@MainActor
final class TraceCacheSettingsStateTests: XCTestCase {
  func testFailedPurgeReconcilesWithStatusWithoutRetryingTheMutation() async {
    let current = RuntimeTraceCacheInventory(
      entryCount: 1, totalByteCount: 1024, activeEntryCount: 1)
    let provider = TraceCacheStateProvider(
      purge: .failed("outcome unknown"), load: .loaded(current))
    let model = TraceCacheSettingsViewModel(provider: provider)

    await model.purgeUnused()

    XCTAssertEqual(model.failureMessage, "outcome unknown")
    XCTAssertEqual(model.inventory, current)
    XCTAssertNil(model.lastPurgeReport)
    let calls = await provider.calls()
    XCTAssertEqual(calls, ["purge", "status"])
  }

  func testSuccessfulPurgePublishesTheReturnedAfterInventory() async {
    let before = RuntimeTraceCacheInventory(
      entryCount: 3, totalByteCount: 4096, activeEntryCount: 1)
    let after = RuntimeTraceCacheInventory(
      entryCount: 1, totalByteCount: 1024, activeEntryCount: 1)
    let report = RuntimeTraceCachePurgeReport(
      before: before, after: after,
      recoveredPrivateDirectoryCount: 0,
      removedOrphanOwnerMarkerCount: 0,
      removedEntryCount: 2,
      skippedActiveEntryCount: 1)
    let provider = TraceCacheStateProvider(
      purge: .completed(report), load: .loaded(before))
    let model = TraceCacheSettingsViewModel(provider: provider)

    await model.purgeUnused()

    XCTAssertEqual(model.inventory, after)
    XCTAssertEqual(model.lastPurgeReport, report)
    XCTAssertNil(model.failureMessage)
    let calls = await provider.calls()
    XCTAssertEqual(calls, ["purge"])
  }
}

private actor TraceCacheStateProvider: RuntimeTraceCacheApplicationProviding {
  let purgeResult: RuntimeTraceCachePurgeResult
  let loadResult: RuntimeTraceCacheLoadResult
  private var recordedCalls: [String] = []

  init(purge: RuntimeTraceCachePurgeResult, load: RuntimeTraceCacheLoadResult) {
    purgeResult = purge
    loadResult = load
  }

  func loadTraceCache() async -> RuntimeTraceCacheLoadResult {
    recordedCalls.append("status")
    return loadResult
  }

  func purgeUnusedTraceCache() async -> RuntimeTraceCachePurgeResult {
    recordedCalls.append("purge")
    return purgeResult
  }

  func calls() -> [String] { recordedCalls }
}

private struct BrowserStateFixture {
  let model: DebugRemoteBuildBrowserViewModel
  let provider: ControlledRemoteSourceStateProvider
  let sourceA: RemoteBuildSourcePresentation
  let sourceB: RemoteBuildSourcePresentation
  let entryA: RemoteBuildDirectoryEntry
  let entryB: RemoteBuildDirectoryEntry
  let directoryA: RemoteBuildDirectoryEntry
}

private enum RemoteSourceStateTestError: Error {
  case expectedFailure
  case unexpectedCall
  case missingContinuation
  case timedOut
}

private actor ControlledRemoteSourceStateProvider: RemoteBuildSourceProviding {
  let sources: [RemoteBuildSourcePresentation]
  private var directoryRequests: [UUID: CheckedContinuation<RemoteBuildDirectoryListing, Error>] = [:]
  private var requestedPaths: [UUID: String] = [:]
  private var probeRequest: CheckedContinuation<RemoteBuildSourceProbe, Error>?

  init(sources: [RemoteBuildSourcePresentation]) { self.sources = sources }

  var hasProbeRequest: Bool { probeRequest != nil }

  func hasDirectoryRequest(for sourceID: UUID) -> Bool { directoryRequests[sourceID] != nil }

  func requestedDirectoryPath(for sourceID: UUID) -> String? { requestedPaths[sourceID] }

  func listSources() async throws -> [RemoteBuildSourcePresentation] { sources }

  func listDirectory(sourceID: UUID, relativePath: String) async throws -> RemoteBuildDirectoryListing {
    requestedPaths[sourceID] = relativePath
    return try await withCheckedThrowingContinuation { directoryRequests[sourceID] = $0 }
  }

  func completeDirectory(
    for sourceID: UUID, with result: Result<RemoteBuildDirectoryListing, Error>
  ) throws {
    guard let continuation = directoryRequests.removeValue(forKey: sourceID) else {
      throw RemoteSourceStateTestError.missingContinuation
    }
    requestedPaths[sourceID] = nil
    continuation.resume(with: result)
  }

  func probe(
    draft: RemoteBuildSourceDraft, credential: RemoteBuildSourceCredentialInput?
  ) async throws -> RemoteBuildSourceProbe {
    try await withCheckedThrowingContinuation { probeRequest = $0 }
  }

  func failProbe() throws {
    guard let continuation = probeRequest else { throw RemoteSourceStateTestError.missingContinuation }
    probeRequest = nil
    continuation.resume(throwing: RemoteSourceStateTestError.expectedFailure)
  }

  // Trust tokens are deliberately not constructible outside their provider.
  // The single generation guard is exercised through the failure result;
  // these tests do not weaken that boundary to fabricate a successful probe.
  func save(probe: RemoteBuildSourceProbe) async throws -> RemoteBuildSourcePresentation {
    throw RemoteSourceStateTestError.unexpectedCall
  }

  func remove(sourceID: UUID) async throws { throw RemoteSourceStateTestError.unexpectedCall }

  func fetchNativeLibrary(
    sourceID: UUID, relativePath: String
  ) async throws -> RemoteBuildNativeLibraryArtifact {
    throw RemoteSourceStateTestError.unexpectedCall
  }
}

private struct UnusedSettingsStateProvider: SettingsApplicationProviding {
  func refresh() async throws -> SettingsApplicationPresentation {
    throw RemoteSourceStateTestError.unexpectedCall
  }
  func updateStoragePolicy(
    totalQuotaBytes: UInt64, safetyMarginBytes: UInt64, retentionDays: UInt64
  ) async throws -> SettingsApplicationPresentation {
    throw RemoteSourceStateTestError.unexpectedCall
  }
  func selectStorageRoot(_ url: URL) async throws -> SettingsApplicationPresentation {
    throw RemoteSourceStateTestError.unexpectedCall
  }
  func resetStorageRoot() async throws -> SettingsApplicationPresentation {
    throw RemoteSourceStateTestError.unexpectedCall
  }
  func previewDiagnosticBundle(at destination: URL) async throws -> SettingsDiagnosticBundlePreview {
    throw RemoteSourceStateTestError.unexpectedCall
  }
  func exportDiagnosticBundle(
    to destination: URL, approvedPreview: SettingsDiagnosticBundlePreview
  ) async throws -> URL {
    throw RemoteSourceStateTestError.unexpectedCall
  }
}
