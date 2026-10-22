import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class DebugWorkspaceViewModel {
  private struct TargetBindingScope: Equatable {
    let targetID: String
    let bindingRevision: Int

    init(target: DebugTargetPresentation) {
      targetID = target.id
      bindingRevision = target.bindingRevision
    }

    func matches(_ target: DebugTargetPresentation?) -> Bool {
      guard let target else { return false }
      return targetID == target.id && bindingRevision == target.bindingRevision
    }
  }

  private struct CommandFeedbackScope: Equatable {
    let target: TargetBindingScope
    let templateID: String
  }

  private struct NativeLibraryFeedbackScope: Equatable {
    let targetID: String
    let bindingRevision: Int
    let fileURL: URL
    let targetBundle: String
    let libraryLogicalName: String
    let verificationProfile: String
    let rollbackPolicy: String
  }

  private(set) var workspace = DebugWorkspacePresentation.loading
  private var refreshState = DebugWorkspaceRefreshState()
  private(set) var hasLoadedWorkspace = false
  var isRefreshing: Bool { refreshState.inFlight != nil }
  private(set) var artifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]
  private(set) var exportStatesByArtifactID: [String: RuntimeArtifactExportState] = [:]
  private(set) var isSubmittingLogs = false
  private(set) var isCancellingLogs = false
  private(set) var activeLogJobID: String?
  private(set) var logTerminal: DebugLogJobTerminalPresentation?
  private(set) var logFailure: String?
  private(set) var isSubmittingCommand = false
  private(set) var isCancellingCommand = false
  private(set) var activeCommandJobID: String?
  private(set) var commandTerminal: DebugLogJobTerminalPresentation?
  private(set) var commandFailure: String?
  private(set) var isMutatingPortRule = false
  private(set) var isCancellingPortRule = false
  private(set) var activePortRuleJobID: String?
  private(set) var portRuleTerminal: DebugLogJobTerminalPresentation?
  private(set) var portRuleFailure: String?
  private(set) var isSubmittingHAP = false
  private(set) var isCancellingHAP = false
  private(set) var activeHAPJobID: String?
  private(set) var hapTerminal: DebugLogJobTerminalPresentation?
  private(set) var hapFailure: String?
  private(set) var isPreparingNativeLibrary = false
  private(set) var nativeLibraryPreparation: DebugNativeLibraryPreparation?
  private(set) var nativeLibraryPreparationFailure: String?
  private(set) var isSubmittingNativeLibrary = false
  private(set) var isCancellingNativeLibrary = false
  private(set) var activeNativeLibraryJobID: String?
  private(set) var nativeLibraryTerminal: DebugLogJobTerminalPresentation?
  private(set) var nativeLibraryFailure: String?
  private(set) var cancellingOutstandingJobIDs: Set<String> = []
  private var historyArtifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]

  private var logFeedbackScope: TargetBindingScope?
  private var hapFeedbackScope: TargetBindingScope?
  private var portRuleFeedbackScope: TargetBindingScope?
  private var commandFeedbackScope: CommandFeedbackScope?
  private var nativeLibraryFeedbackScope: NativeLibraryFeedbackScope?
  private var nativeLibraryPreparationGeneration = 0

  private let provider: any DebugApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding
  let nativeLibraryBatch: NativeLibraryDeploymentBatch

  init(
    provider: any DebugApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil
  ) {
    self.provider = provider
    self.nativeLibraryBatch = NativeLibraryDeploymentBatch(provider: provider)
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
  }

  func logFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    logFeedbackScope?.matches(target) == true
  }

  func hapFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    hapFeedbackScope?.matches(target) == true
  }

  func portRuleFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    portRuleFeedbackScope?.matches(target) == true
  }

  func commandFeedbackMatches(
    target: DebugTargetPresentation?,
    templateID: String?
  ) -> Bool {
    guard let templateID else { return false }
    return commandFeedbackScope
      == target.map {
        CommandFeedbackScope(target: TargetBindingScope(target: $0), templateID: templateID)
      }
  }

  fileprivate func runtimeArtifactRows(
    operationReference: String,
    targetID: String?
  ) -> [DebugRuntimeArtifactRow] {
    workspace.jobs
      .filter {
        $0.operationReference == operationReference
          && (targetID == nil || $0.targetID == targetID)
      }
      .flatMap { job in
        (artifactsByJobID[job.id] ?? []).map {
          DebugRuntimeArtifactRow(jobID: job.id, artifact: $0)
        }
      }
  }

  func nativeLibraryFeedbackMatches(
    target: DebugTargetPresentation?,
    fileURL: URL?,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) -> Bool {
    guard let target, let fileURL else { return false }
    return nativeLibraryFeedbackScope
      == NativeLibraryFeedbackScope(
        targetID: target.id,
        bindingRevision: target.bindingRevision,
        fileURL: fileURL,
        targetBundle: targetBundle,
        libraryLogicalName: libraryLogicalName,
        verificationProfile: verificationProfile,
        rollbackPolicy: rollbackPolicy)
  }

  func exportArtifact(
    jobID: String,
    artifact: RuntimeArtifactPresentation,
    destinationURL: URL,
    allowSensitive: Bool
  ) {
    guard exportStatesByArtifactID[artifact.id] != .exporting else { return }
    exportStatesByArtifactID[artifact.id] = .exporting
    let detailProvider = detailProvider
    Task { [weak self] in
      let result = await detailProvider.exportArtifact(
        jobID: jobID,
        artifact: artifact,
        destinationURL: destinationURL,
        allowSensitive: allowSensitive)
      guard let self, !Task.isCancelled else { return }
      switch result {
      case .completed(let url):
        self.exportStatesByArtifactID[artifact.id] = .completed(url)
      case .failed(let reason):
        self.exportStatesByArtifactID[artifact.id] = .failed(reason)
      }
    }
  }

  func selectTarget(_ targetID: String?) {
    refreshState.select(targetID)
    refresh()
  }

  func refresh(targetID: String? = nil) {
    guard let request = refreshState.begin(fallbackTargetID: targetID) else { return }
    let provider = provider
    let detailProvider = detailProvider
    Task { [weak self] in
      let next = await provider.refreshWorkspace(targetID: request.targetID)
      var artifacts: [String: [RuntimeArtifactPresentation]] = [:]
      for job in next.jobs.prefix(6) {
        let detail = await detailProvider.loadJobDetail(
          jobID: job.id,
          operationReference: job.operationReference)
        if case .available = detail.artifactAvailability {
          artifacts[job.id] = detail.artifacts
        }
      }
      guard let self, self.refreshState.finish(request) else { return }
      guard !Task.isCancelled else { return }
      self.hasLoadedWorkspace = true
      if let batchTarget = self.nativeLibraryBatch.target,
        !next.targets.contains(where: {
          $0.id == batchTarget.id && $0.bindingRevision == batchTarget.bindingRevision
        }) {
        self.nativeLibraryBatch.invalidate()
      }
      self.workspace = next
      artifacts.merge(self.historyArtifactsByJobID) { _, historical in historical }
      self.artifactsByJobID = artifacts
    }
  }

  /// Makes immutable Artifact metadata from the selected History record
  /// available to Debug without submitting or running anything.
  func rememberHistoryContext(_ context: RuntimeHistoryWorkspaceContext) {
    guard context.workspaceKind == .debug else { return }
    historyArtifactsByJobID[context.jobID] = context.artifacts
    artifactsByJobID[context.jobID] = context.artifacts
  }

  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) {
    guard !isSubmittingLogs else { return }
    logFeedbackScope = TargetBindingScope(target: target)
    isSubmittingLogs = true
    activeLogJobID = nil
    logTerminal = nil
    logFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitLogs(
        target: target, durationSeconds: durationSeconds, filters: filters)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.logFailure = failure
        self.isSubmittingLogs = false
      case .submitted(let acceptance):
        self.activeLogJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeLogJobID = nil
        self.isSubmittingLogs = false
        switch result {
        case .completed(let terminal): self.logTerminal = terminal
        case .failed(let failure): self.logFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelLogs() {
    guard let jobID = activeLogJobID, !isCancellingLogs else { return }
    isCancellingLogs = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingLogs = false
      if !accepted { self.logFailure = "Runtime refused the cancellation request" }
    }
  }

  func submitHAP(
    target: DebugTargetPresentation,
    fileURL: URL,
    additionalFileURLs: [URL],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int
  ) {
    guard !isSubmittingHAP else { return }
    hapFeedbackScope = TargetBindingScope(target: target)
    isSubmittingHAP = true
    activeHAPJobID = nil
    hapTerminal = nil
    hapFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitHAP(
        target: target, fileURL: fileURL, additionalFileURLs: additionalFileURLs,
        bundleName: bundleName, abilityName: abilityName,
        installPolicy: installPolicy, cleanupPolicy: cleanupPolicy,
        postRunAbilityState: postRunAbilityState,
        captureDiagnostics: captureDiagnostics,
        diagnosticsDurationSeconds: diagnosticsDurationSeconds)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.hapFailure = failure
        self.isSubmittingHAP = false
      case .submitted(let acceptance):
        self.activeHAPJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeHAPJobID = nil
        self.isSubmittingHAP = false
        switch result {
        case .completed(let terminal): self.hapTerminal = terminal
        case .failed(let failure): self.hapFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelHAP() {
    guard let jobID = activeHAPJobID, !isCancellingHAP else { return }
    isCancellingHAP = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingHAP = false
      if !accepted { self.hapFailure = "Runtime refused the cancellation request" }
    }
  }

  func prepareNativeLibrary(
    target: DebugTargetPresentation,
    fileURL: URL,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> Bool {
    guard !isPreparingNativeLibrary, !isSubmittingNativeLibrary, !nativeLibraryBatch.isBusy else { return false }
    nativeLibraryPreparationGeneration += 1
    let preparationGeneration = nativeLibraryPreparationGeneration
    nativeLibraryFeedbackScope = NativeLibraryFeedbackScope(
      targetID: target.id,
      bindingRevision: target.bindingRevision,
      fileURL: fileURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    isPreparingNativeLibrary = true
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let result = await provider.prepareNativeLibrary(
      target: target,
      fileURL: fileURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    guard preparationGeneration == nativeLibraryPreparationGeneration else {
      isPreparingNativeLibrary = false
      return false
    }
    guard !Task.isCancelled else {
      isPreparingNativeLibrary = false
      return false
    }
    isPreparingNativeLibrary = false
    switch result {
    case .prepared(let preparation):
      nativeLibraryPreparation = preparation
      return true
    case .failed(let failure):
      nativeLibraryPreparationFailure = failure
      return false
    }
  }

  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation,
    selectionIdentityURL: URL,
    sourceID: UUID,
    relativePath: String,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> Bool {
    guard !isPreparingNativeLibrary, !isSubmittingNativeLibrary, !nativeLibraryBatch.isBusy else { return false }
    nativeLibraryPreparationGeneration += 1
    let preparationGeneration = nativeLibraryPreparationGeneration
    nativeLibraryFeedbackScope = NativeLibraryFeedbackScope(
      targetID: target.id,
      bindingRevision: target.bindingRevision,
      fileURL: selectionIdentityURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    isPreparingNativeLibrary = true
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let result = await provider.prepareRemoteNativeLibrary(
      target: target,
      sourceID: sourceID,
      relativePath: relativePath,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    guard preparationGeneration == nativeLibraryPreparationGeneration else {
      isPreparingNativeLibrary = false
      return false
    }
    guard !Task.isCancelled else {
      isPreparingNativeLibrary = false
      return false
    }
    isPreparingNativeLibrary = false
    switch result {
    case .prepared(let preparation):
      nativeLibraryPreparation = preparation
      return true
    case .failed(let failure):
      nativeLibraryPreparationFailure = failure
      return false
    }
  }

  func clearNativeLibraryPreparation() {
    nativeLibraryPreparationGeneration += 1
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
  }

  func submitNativeLibrary(_ preparation: DebugNativeLibraryPreparation) {
    guard !isSubmittingNativeLibrary, !nativeLibraryBatch.isBusy,
      nativeLibraryPreparation?.planDigest == preparation.planDigest,
      nativeLibraryFeedbackScope?.targetID == preparation.targetID,
      nativeLibraryFeedbackScope?.bindingRevision == preparation.bindingRevision,
      nativeLibraryFeedbackScope?.targetBundle == preparation.targetBundle,
      nativeLibraryFeedbackScope?.libraryLogicalName == preparation.libraryName,
      nativeLibraryFeedbackScope?.verificationProfile == preparation.verificationProfile,
      nativeLibraryFeedbackScope?.rollbackPolicy == preparation.rollbackPolicy
    else { return }
    isSubmittingNativeLibrary = true
    activeNativeLibraryJobID = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitNativeLibrary(preparation: preparation)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.nativeLibraryFailure = failure
        self.isSubmittingNativeLibrary = false
      case .submitted(let acceptance):
        self.activeNativeLibraryJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: preparation.targetID)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeNativeLibraryJobID = nil
        self.isSubmittingNativeLibrary = false
        switch result {
        case .completed(let terminal): self.nativeLibraryTerminal = terminal
        case .failed(let failure): self.nativeLibraryFailure = failure
        }
        self.refresh(targetID: preparation.targetID)
      }
    }
  }

  func cancelNativeLibrary() {
    guard let jobID = activeNativeLibraryJobID, !isCancellingNativeLibrary else { return }
    isCancellingNativeLibrary = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingNativeLibrary = false
      if !accepted {
        self.nativeLibraryFailure = "Runtime refused the cancellation request"
      }
    }
  }

  func isCancellingOutstandingJob(_ jobID: String) -> Bool {
    cancellingOutstandingJobIDs.contains(jobID)
  }

  func cancelOutstandingJob(_ job: DebugJobPresentation) {
    guard job.isActive, !isCancellingOutstandingJob(job.id) else { return }
    cancellingOutstandingJobIDs.insert(job.id)
    let provider = provider
    Task { [weak self] in
      guard let self else { return }
      defer { self.cancellingOutstandingJobIDs.remove(job.id) }
      guard await provider.cancel(jobID: job.id) else {
        self.recordCancellationFailure(for: job)
        return
      }
      for _ in 0..<80 {
        guard !Task.isCancelled else { return }
        let next = await provider.refreshWorkspace(targetID: job.targetID)
        guard !Task.isCancelled else { return }
        self.workspace = next
        guard next.jobs.first(where: { $0.id == job.id })?.isActive == true else { return }
        try? await Task.sleep(for: .milliseconds(750))
      }
    }
  }

  private func recordCancellationFailure(for job: DebugJobPresentation) {
    let message = "Runtime refused the cancellation request"
    switch job.operationReference {
    case DebugApplicationFacade.debugHAPReference: hapFailure = message
    case DebugApplicationFacade.captureDiagnosticsReference: logFailure = message
    case DebugApplicationFacade.nativeLibraryReference: nativeLibraryFailure = message
    case DebugApplicationFacade.debugTemplateReference: commandFailure = message
    default: portRuleFailure = message
    }
  }

  func mutatePortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) {
    guard !isMutatingPortRule else { return }
    portRuleFeedbackScope = TargetBindingScope(target: target)
    isMutatingPortRule = true
    activePortRuleJobID = nil
    portRuleTerminal = nil
    portRuleFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitPortRule(
        target: target, rule: rule, removing: removing)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.portRuleFailure = failure
        self.isMutatingPortRule = false
      case .submitted(let acceptance):
        self.activePortRuleJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activePortRuleJobID = nil
        self.isMutatingPortRule = false
        switch result {
        case .completed(let terminal): self.portRuleTerminal = terminal
        case .failed(let failure): self.portRuleFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelPortRuleMutation() {
    guard let jobID = activePortRuleJobID, !isCancellingPortRule else { return }
    isCancellingPortRule = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingPortRule = false
      if !accepted { self.portRuleFailure = "Runtime refused the cancellation request" }
    }
  }

  func submitTemplate(target: DebugTargetPresentation, templateID: String) {
    guard !isSubmittingCommand else { return }
    commandFeedbackScope = CommandFeedbackScope(
      target: TargetBindingScope(target: target), templateID: templateID)
    isSubmittingCommand = true
    activeCommandJobID = nil
    commandTerminal = nil
    commandFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitTemplate(target: target, templateID: templateID)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.commandFailure = failure
        self.isSubmittingCommand = false
      case .submitted(let acceptance):
        self.activeCommandJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeCommandJobID = nil
        self.isSubmittingCommand = false
        switch result {
        case .completed(let terminal): self.commandTerminal = terminal
        case .failed(let failure): self.commandFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelCommand() {
    guard let jobID = activeCommandJobID, !isCancellingCommand else { return }
    isCancellingCommand = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingCommand = false
      if !accepted { self.commandFailure = "Runtime refused the cancellation request" }
    }
  }

  func clearCommandResult() {
    guard activeCommandJobID == nil else { return }
    commandFeedbackScope = nil
    commandTerminal = nil
    commandFailure = nil
  }
}

