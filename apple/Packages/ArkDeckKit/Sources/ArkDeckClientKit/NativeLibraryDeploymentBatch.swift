import ArkDeckCore
import Foundation
import Observation

/// App orchestration only. Each item keeps the published single-library operation,
/// its reviewed plan and its own Runtime admission, backup and verification.
public protocol NativeLibraryDeploymentProviding: Sendable {
  func prepareNativeLibrary(
    target: DebugTargetPresentation, fileURL: URL, targetBundle: String,
    libraryLogicalName: String, verificationProfile: String, rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult
  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation, sourceID: UUID, relativePath: String,
    targetBundle: String, libraryLogicalName: String, verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult
  func submitNativeLibrary(
    preparation: DebugNativeLibraryPreparation
  ) async -> DebugLogJobSubmissionResult
  func run(jobID: String) async -> DebugLogJobRunResult
}

public enum NativeLibraryDeploymentSource: Sendable, Equatable, Identifiable {
  case file(URL, directory: URL? = nil)
  case ssh(sourceID: UUID, sourceName: String, relativePath: String)

  public var id: String {
    switch self {
    case .file(let url, _): "file:" + url.standardizedFileURL.absoluteString
    case .ssh(let id, _, let path): "ssh:\(id.uuidString):\(path)"
    }
  }

  public var name: String {
    switch self {
    case .file(let url, _): url.lastPathComponent
    case .ssh(_, _, let path): String(path.split(separator: "/").last ?? "")
    }
  }

  public var location: String {
    switch self {
    case .file(let url, _): url.deletingLastPathComponent().path
    case .ssh(_, let source, let path): "\(source) · \(path)"
    }
  }
}

public struct NativeLibraryDeploymentRow: Identifiable, Sendable, Equatable {
  public enum State: String, Sendable {
    case pending, preparing, prepared, submitting, running, succeeded, failed
  }
  public let source: NativeLibraryDeploymentSource
  public internal(set) var state: State = .pending
  public internal(set) var preparation: DebugNativeLibraryPreparation?
  public internal(set) var jobID: String?
  public internal(set) var detail: String?
  public var id: String { source.id }
}

@MainActor
@Observable
public final class NativeLibraryDeploymentBatch {
  public enum Phase: String, Sendable {
    case idle, preparing, review, running, stopped, succeeded, failed
  }
  public static let maximumLibraries = 16
  public private(set) var phase: Phase = .idle
  public private(set) var rows: [NativeLibraryDeploymentRow] = []
  public private(set) var target: DebugTargetPresentation?
  public private(set) var targetBundle = ""
  public private(set) var failure: String?
  public private(set) var stopRequested = false
  public private(set) var isBusy = false
  private let provider: any NativeLibraryDeploymentProviding
  private var generation = 0

  public init(provider: any NativeLibraryDeploymentProviding) { self.provider = provider }

  /// Invalidates a review immediately. A submitted Job retains its original
  /// target and is allowed to finish; no subsequent item is submitted.
  public func invalidate() {
    generation += 1
    stopRequested = true
    if !isBusy, phase != .idle { phase = .stopped }
  }

  public func stop() { invalidate() }

  public func prepare(
    sources: [NativeLibraryDeploymentSource], target: DebugTargetPresentation,
    targetBundle: String
  ) async {
    guard !isBusy else { return }
    generation += 1
    let current = generation
    self.target = target
    self.targetBundle = targetBundle
    rows = sources.map { NativeLibraryDeploymentRow(source: $0) }
    failure = nil
    stopRequested = false
    guard (1...Self.maximumLibraries).contains(sources.count),
      Set(sources.map(\.id)).count == sources.count,
      Set(sources.map(\.name)).count == sources.count,
      sources.allSatisfy({ DebugTypedValueValidator.isValidNativeLibraryLogicalName($0.name) }),
      DebugTypedValueValidator.isValidBundleName(targetBundle)
    else {
      phase = .failed
      failure = "Select 1–16 libraries with different lib<name>.so names and a valid bundle."
      return
    }
    isBusy = true
    phase = .preparing
    defer { isBusy = false }
    for index in rows.indices {
      guard current == generation, !Task.isCancelled else { phase = .stopped; return }
      rows[index].state = .preparing
      let source = rows[index].source
      let result: DebugNativeLibraryPreparationResult
      switch source {
      case .file(let url, let directory):
        let gainedScope = directory?.startAccessingSecurityScopedResource() == true
        defer { if gainedScope { directory?.stopAccessingSecurityScopedResource() } }
        if let directory, !NativeLibraryDirectorySource.contains(url, in: directory) {
          result = .failed("The selected library is no longer inside its source directory.")
        } else {
          result = await provider.prepareNativeLibrary(
            target: target, fileURL: url, targetBundle: targetBundle,
            libraryLogicalName: source.name, verificationProfile: "hashProcessAndMaps",
            rollbackPolicy: "autoRollback")
        }
      case .ssh(let sourceID, _, let relativePath):
        result = await provider.prepareRemoteNativeLibrary(
          target: target, sourceID: sourceID, relativePath: relativePath,
          targetBundle: targetBundle, libraryLogicalName: source.name,
          verificationProfile: "hashProcessAndMaps", rollbackPolicy: "autoRollback")
      }
      guard current == generation, !Task.isCancelled else { phase = .stopped; return }
      switch result {
      case .prepared(let plan):
        guard plan.operationReference == DebugApplicationFacade.nativeLibraryReference,
          plan.targetID == target.id, plan.bindingRevision == target.bindingRevision,
          plan.targetBundle == targetBundle, plan.libraryName == source.name,
          plan.verificationProfile == "hashProcessAndMaps", plan.rollbackPolicy == "autoRollback",
          SHA256Hex.isLowercaseSHA256(plan.planDigest), SHA256Hex.isLowercaseSHA256(plan.sha256)
        else { fail(index, "The plan does not match the selected target and library."); return }
        rows[index].preparation = plan
        rows[index].state = .prepared
      case .failed(let detail): fail(index, detail); return
      }
    }
    phase = .review
  }

  public func submitReviewed() async {
    guard !isBusy, phase == .review, !stopRequested,
      !rows.isEmpty, rows.allSatisfy({ $0.state == .prepared && $0.preparation != nil })
    else { return }
    isBusy = true
    phase = .running
    let current = generation
    defer { isBusy = false }
    for index in rows.indices {
      guard current == generation, !Task.isCancelled else { phase = .stopped; return }
      guard let plan = rows[index].preparation else {
        fail(index, "The reviewed plan is missing."); return
      }
      rows[index].state = .submitting
      let submission = await provider.submitNativeLibrary(preparation: plan)
      switch submission {
      case .failed(let detail):
        // A lost submit reply can hide an admitted Job. Never retry or advance.
        fail(index, detail); return
      case .submitted(let acceptance):
        guard !acceptance.jobID.isEmpty else {
          fail(index, "Runtime did not return the accepted Job ID."); return
        }
        rows[index].jobID = acceptance.jobID
        rows[index].state = .running
        // Even if the view changed while submit was in flight, this accepted
        // Job belongs to the reviewed batch. Retain its receipt before stopping.
        let result = await provider.run(jobID: acceptance.jobID)
        switch result {
        case .failed(let detail): fail(index, detail); return
        case .completed(let terminal):
          guard terminal.jobID == acceptance.jobID, terminal.state == "succeeded",
            !terminal.outcomeUnknown, terminal.operationFailure == nil
          else {
            fail(index, "Job \(acceptance.jobID) did not report verified success (\(terminal.state)).")
            return
          }
          rows[index].state = .succeeded
        }
      }
    }
    phase = current == generation && !Task.isCancelled ? .succeeded : .stopped
  }

  private func fail(_ index: Int, _ detail: String) {
    rows[index].state = .failed
    rows[index].detail = detail
    failure = detail
    phase = .failed
  }
}
