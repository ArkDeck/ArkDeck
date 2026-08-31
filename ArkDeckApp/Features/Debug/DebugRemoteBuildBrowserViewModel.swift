import ArkDeckWorkflows
import Foundation
import Observation

@MainActor
@Observable
final class DebugRemoteBuildBrowserViewModel {
  private(set) var sources: [RemoteBuildSourcePresentation] = []
  private(set) var listing: RemoteBuildDirectoryListing?
  private(set) var isLoading = false
  private(set) var errorMessage: String?
  private(set) var selectedSourceID: UUID?
  private(set) var selectedEntry: RemoteBuildDirectoryEntry?

  private let provider: any RemoteBuildSourceProviding
  private var generation = 0
  private(set) var requestedRelativePath = ""

  init(provider: any RemoteBuildSourceProviding) { self.provider = provider }

  var selectedSource: RemoteBuildSourcePresentation? {
    sources.first { $0.id == selectedSourceID }
  }

  var canGoUp: Bool {
    !isLoading && selectedSource != nil && !requestedRelativePath.isEmpty
  }

  /// A path is meaningful only in the source and directory that displayed it.
  /// Both the button state and its action consume this same validated value.
  var selectedLibraryEntry: RemoteBuildDirectoryEntry? {
    guard !isLoading, let selectedSource, let listing,
      listing.sourceID == selectedSource.id,
      let selectedEntry, selectedEntry.kind == .nativeLibrary,
      listing.entries.contains(selectedEntry)
    else { return nil }
    return selectedEntry
  }

  func loadSources() {
    generation += 1
    let currentGeneration = generation
    isLoading = true
    errorMessage = nil
    listing = nil
    selectedEntry = nil
    requestedRelativePath = ""
    let provider = provider
    Task { [weak self] in
      do {
        let sources = try await provider.listSources()
        guard let self, currentGeneration == self.generation else { return }
        self.sources = sources
        if !sources.contains(where: { $0.id == self.selectedSourceID }) {
          self.selectedSourceID = sources.first?.id
        }
        if let sourceID = self.selectedSourceID {
          self.loadDirectory(sourceID: sourceID, relativePath: "")
        } else {
          self.listing = nil
          self.isLoading = false
        }
      } catch {
        guard let self, currentGeneration == self.generation else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }

  func selectSource(_ sourceID: UUID?) {
    guard selectedSourceID != sourceID else { return }
    selectedSourceID = sourceID
    selectedEntry = nil
    guard let sourceID else {
      generation += 1
      listing = nil
      requestedRelativePath = ""
      errorMessage = nil
      isLoading = false
      return
    }
    loadDirectory(sourceID: sourceID, relativePath: "")
  }

  func open(_ entry: RemoteBuildDirectoryEntry) {
    guard !isLoading, let sourceID = selectedSourceID, let listing,
      listing.sourceID == sourceID, listing.entries.contains(entry)
    else { return }
    switch entry.kind {
    case .directory:
      selectedEntry = nil
      loadDirectory(sourceID: sourceID, relativePath: entry.relativePath)
    case .nativeLibrary:
      selectedEntry = entry
    }
  }

  func goUp() {
    guard canGoUp, let sourceID = selectedSourceID else { return }
    let parent = requestedRelativePath.split(separator: "/").dropLast().joined(separator: "/")
    selectedEntry = nil
    loadDirectory(sourceID: sourceID, relativePath: parent)
  }

  func reload() {
    guard !isLoading, let sourceID = selectedSourceID else { return }
    loadDirectory(sourceID: sourceID, relativePath: requestedRelativePath)
  }

  private func loadDirectory(sourceID: UUID, relativePath: String) {
    generation += 1
    let currentGeneration = generation
    isLoading = true
    errorMessage = nil
    requestedRelativePath = relativePath
    listing = nil
    selectedEntry = nil
    let provider = provider
    Task { [weak self] in
      do {
        let listing = try await provider.listDirectory(
          sourceID: sourceID, relativePath: relativePath)
        guard let self, currentGeneration == self.generation else { return }
        guard self.selectedSourceID == sourceID, listing.sourceID == sourceID else {
          self.errorMessage = RemoteBuildSourceError.sourceNotFound.localizedDescription
          self.isLoading = false
          return
        }
        self.listing = listing
        self.isLoading = false
      } catch {
        guard let self, currentGeneration == self.generation else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }
}
