import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DebugArtifactsWorkspace: View {
  private enum BuildSourceKind: String, CaseIterable {
    case local
    case remote
  }

  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeArtifacts: [DebugRuntimeArtifactRow]
  let onOpenLogs: () -> Void

  @State private var isImporterPresented = false
  @State private var isDirectoryImporterPresented = false
  @State private var isReadingDirectories = false
  @State private var directoryCandidates: [NativeLibraryDeploymentSource] = []
  @State private var queuedLibraries: [NativeLibraryDeploymentSource] = []
  @State private var isBatchReviewPresented = false
  @State private var batchPreparationRequest: UUID?
  @State private var presentedPreparation: DebugNativeLibraryPreparation?
  @State private var isRemoteBrowserPresented = false
  @State private var buildSourceKind = BuildSourceKind.local
  @State private var selectedLibraryURL: URL?
  @State private var selectedRemoteLibrary: DebugRemoteLibrarySelection?
  @State private var remoteBrowserModel = DebugRemoteBuildBrowserViewModel(
    provider: RemoteBuildSourceApplicationFacade.make())
  private let remoteBindingProvider: any RemoteBuildSourceBindingProviding =
    RemoteBuildSourceBindingApplicationFacade.make()
  @State private var selectionError: String?
  @State private var targetBundle = ""
  @State private var libraryLogicalName = ""
  private let verificationProfile = "hashProcessAndMaps"
  private let rollbackPolicy = "autoRollback"

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var inputsAreValid: Bool {
    target != nil
      && selectedLibraryURL != nil
      && DebugTypedValueValidator.isValidBundleName(targetBundle)
      && DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName)
  }

  private var nativeLibraryFeedbackMatchesTarget: Bool {
    model.nativeLibraryFeedbackMatches(
      target: target,
      fileURL: selectedLibraryURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
  }

  private var currentPreparation: DebugNativeLibraryPreparation? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryPreparation
  }

  private var currentTerminal: DebugLogJobTerminalPresentation? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryTerminal
  }

  private var currentFailure: String? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryPreparationFailure ?? model.nativeLibraryFailure
  }

  private var currentAccessibilityStatus: DebugAccessibilityStatus? {
    if let currentFailure {
      return DebugAccessibilityStatus(message: currentFailure, isUrgent: true)
    }
    if let currentTerminal {
      let message =
        currentTerminal.state == "succeeded" && !currentTerminal.outcomeUnknown
        ? DebugL10n.text("debug.artifacts.verified")
        : DebugL10n.text("debug.artifacts.notVerified")
      return DebugAccessibilityStatus(message: message, isUrgent: currentTerminal.outcomeUnknown)
    }
    if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.running"), isUrgent: false)
    }
    if model.isPreparingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.preparing"), isUrgent: false)
    }
    if currentPreparation != nil {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.planReady"), isUrgent: false)
    }
    return nil
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      targetScope
      // `WorkspaceColumns` measures the container instead of comparing ideal
      // sizes, so the fold happens at a real width. `ViewThatFits` could not:
      // a column of prose has an unbounded ideal width.
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        buildSource
      } trailing: {
        deploymentInputs
          .disabled(model.nativeLibraryBatch.isBusy)
      }
      reviewAndRun
        .background {
          DebugAccessibilityAnnouncementBridge(status: currentAccessibilityStatus)
        }
      if !directoryCandidates.isEmpty { directorySelection }
      if !queuedLibraries.isEmpty { batchDeployment }
      productionBoundary
      if !runtimeArtifacts.isEmpty { resultArtifacts }
      DebugRecentJobsSection(model: model, jobs: relatedJobs)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "so") ?? .data],
      allowsMultipleSelection: true,
      onCompletion: handleLibrarySelection
    )
    .fileImporter(
      isPresented: $isDirectoryImporterPresented, allowedContentTypes: [.folder],
      allowsMultipleSelection: true, onCompletion: handleDirectorySelection)
    .sheet(isPresented: $isBatchReviewPresented) {
      DebugNativeLibraryBatchSheet(model: model)
    }
    .sheet(item: $presentedPreparation) {
      DebugNativeLibraryPlanSheet(model: model, preparation: $0)
    }
    .sheet(isPresented: $isRemoteBrowserPresented) {
      DebugRemoteBuildBrowserSheet(model: remoteBrowserModel) { selection in
        selectedRemoteLibrary = selection
        selectedLibraryURL = selection.identityURL
        libraryLogicalName = selection.entry.name
        selectionError = nil
        if let targetID = target?.id {
          let remoteBindingProvider = remoteBindingProvider
          Task { @MainActor in
            do {
              try await remoteBindingProvider.bind(
                sourceID: selection.sourceID, toTargetID: targetID)
            } catch {
              selectionError =
                DebugL10n.text("debug.artifacts.remoteBindingFailed")
                + " " + error.localizedDescription
            }
          }
        }
        model.clearNativeLibraryPreparation()
        isRemoteBrowserPresented = false
      }
    }
    .onChange(of: target?.id) { _, _ in invalidatePreparations() }
    .onChange(of: target?.bindingRevision) { _, _ in invalidatePreparations() }
    .onChange(of: targetBundle) { _, _ in invalidatePreparations() }
    .onChange(of: libraryLogicalName) { _, _ in model.clearNativeLibraryPreparation() }
    .onDisappear { invalidatePreparations() }
  }

  private var targetScope: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
      Text(DebugL10n.text("debug.artifacts.target"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
      if let target {
        Text("\(target.id) · binding r\(target.bindingRevision)")
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
        WorkspaceChip(
          text: Text(DebugL10n.text("debug.artifacts.targetConfirmed")),
          tone: .ok,
          symbol: "checkmark.circle")
        WorkspaceChip(text: Text("deviceMutation"), tone: .warning)
      } else {
        Text(DebugL10n.text("debug.target.none"))
          .font(WorkspaceFont.monospacedValue)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("debug.artifacts.targetScope")
  }

  private var buildSource: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.artifacts.source.title")),
      accessory: { DebugAvailabilityStatus(operation: operation) }
    ) {
      // Spec §4.4: state availability before offering the configuration it
      // gates. A ready operation is the accessory line above and nothing
      // more; only a blocker earns page space.
      DebugAvailabilityNotice(operation: operation)
      Text(DebugL10n.text("debug.artifacts.source.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Picker("", selection: $buildSourceKind) {
        Text(DebugL10n.text("debug.artifacts.source.local"))
          .tag(BuildSourceKind.local)
        Text(DebugL10n.text("debug.artifacts.source.remote"))
          .tag(BuildSourceKind.remote)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .accessibilityLabel(DebugL10n.text("debug.artifacts.source.kind"))
      .accessibilityIdentifier("debug.artifacts.source.kind")
      if buildSourceKind == .local {
        Button {
          isImporterPresented = true
        } label: {
          Label(
            DebugL10n.text("debug.artifacts.chooseLibrary"),
            systemImage: "doc.badge.plus")
        }
        .accessibilityIdentifier("debug.artifacts.chooseLibrary")
        Button {
          isDirectoryImporterPresented = true
        } label: {
          Label(DebugL10n.text("debug.artifacts.chooseDirectory"), systemImage: "folder")
        }
        .disabled(isReadingDirectories || model.nativeLibraryBatch.isBusy)
        .accessibilityIdentifier("debug.artifacts.chooseDirectory")
        if isReadingDirectories { ProgressView().controlSize(.small) }
      } else {
        Button {
          isRemoteBrowserPresented = true
        } label: {
          Label(
            DebugL10n.text("debug.artifacts.browseRemote"),
            systemImage: "server.rack")
        }
        .accessibilityIdentifier("debug.artifacts.browseRemote")
        Text(DebugL10n.text("debug.artifacts.wslSource"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(DebugL10n.text("debug.artifacts.selectedLibrary"))
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        Text(
          selectedRemoteLibrary?.entry.name ?? selectedLibraryURL?.lastPathComponent
            ?? DebugL10n.text("debug.artifacts.noLibrary")
        )
        .font(WorkspaceFont.monospacedValue)
        .foregroundStyle(selectedLibraryURL == nil ? .secondary : .primary)
        .textSelection(.enabled)
      }
      if let selectedRemoteLibrary {
        Text("\(selectedRemoteLibrary.sourceName) · \(selectedRemoteLibrary.entry.relativePath)")
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .help(selectedRemoteLibrary.entry.relativePath)
      }
      if let selectionError {
        Label(selectionError, systemImage: "xmark.octagon")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if selectedLibraryURL != nil {
        Button(DebugL10n.text("debug.artifacts.batch.add")) { addCurrentLibrary() }
          .disabled(model.nativeLibraryBatch.isBusy)
          .accessibilityIdentifier("debug.artifacts.batch.add")
      }
      WorkspaceNotice(tone: .neutral, symbol: "externaldrive") {
        Text(DebugL10n.text("debug.artifacts.sourceBoundary"))
      }
    }
    .onChange(of: buildSourceKind) { _, _ in
      selectedLibraryURL = nil
      selectedRemoteLibrary = nil
      selectionError = nil
      model.clearNativeLibraryPreparation()
    }
  }

  private var directorySelection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.artifacts.directory.title"))) {
      Text(DebugL10n.text("debug.artifacts.directory.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(directoryCandidates) { source in
            Toggle(isOn: Binding(
              get: { queuedLibraries.contains { $0.id == source.id } },
              set: { selected in
                if selected { addToBatch(source) }
                else { removeFromBatch(source.id) }
              }
            )) {
              VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text(source.name).font(WorkspaceFont.monospacedValue)
                Text(source.location).font(WorkspaceFont.caption).foregroundStyle(.secondary)
                  .lineLimit(1).truncationMode(.middle).help(source.location)
              }
            }
            .toggleStyle(.checkbox)
            .disabled(model.nativeLibraryBatch.isBusy)
          }
        }
      }
      .frame(maxHeight: 240)
    }
  }

  private var batchDeployment: some View {
    let batch = model.nativeLibraryBatch
    return WorkspaceSection(Text(DebugL10n.text("debug.artifacts.batch.title"))) {
      Text(DebugL10n.text("debug.artifacts.batch.detail"))
        .font(WorkspaceFont.secondary).foregroundStyle(.secondary)
      ForEach(queuedLibraries) { source in
        HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(source.name).font(WorkspaceFont.monospacedValue)
            Text(source.location).font(WorkspaceFont.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle).help(source.location)
            if let row = batch.rows.first(where: { $0.id == source.id }) {
              Text(DebugL10n.text("debug.artifacts.batch.row.\(row.state.rawValue)"))
                .font(WorkspaceFont.secondary)
              if let jobID = row.jobID {
                Text(jobID).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
              }
            }
          }
          Spacer()
          Button(DebugL10n.text("debug.artifacts.batch.remove"), systemImage: "minus.circle") {
            removeFromBatch(source.id)
          }
          .labelStyle(.iconOnly)
          .disabled(batch.isBusy)
        }
      }
      if batch.phase != .idle {
        Text(DebugL10n.text("debug.artifacts.batch.phase.\(batch.phase.rawValue)"))
          .font(WorkspaceFont.label)
          .accessibilityIdentifier("debug.artifacts.batch.status")
        if let batchTarget = batch.target {
          Text("\(batchTarget.id) · binding r\(batchTarget.bindingRevision) · \(batch.targetBundle)")
            .font(WorkspaceFont.monospacedDense).foregroundStyle(.secondary)
        }
      }
      if let failure = batch.failure {
        Text(failure).font(WorkspaceFont.secondary).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack(spacing: WorkspaceMetrics.contentGap) {
        if batch.isBusy {
          ProgressView().controlSize(.small)
          Button(DebugL10n.text("debug.artifacts.batch.stop")) { batch.stop() }
            .disabled(batch.stopRequested)
        } else {
          Button(DebugL10n.text("debug.artifacts.batch.prepare")) {
            guard let target else { return }
            let sources = queuedLibraries
            let bundle = targetBundle
            let request = UUID()
            batchPreparationRequest = request
            Task {
              guard batchPreparationRequest == request else { return }
              await batch.prepare(sources: sources, target: target, targetBundle: bundle)
              guard batchPreparationRequest == request else { return }
              isBatchReviewPresented = batch.phase == .review
            }
          }
          .disabled(target == nil || !operationIsAvailable
            || !DebugTypedValueValidator.isValidBundleName(targetBundle)
            || model.isPreparingNativeLibrary || model.isSubmittingNativeLibrary)
          .accessibilityIdentifier("debug.artifacts.batch.prepare")
        }
      }
    }
  }

  private func invalidatePreparations() {
    batchPreparationRequest = nil
    model.clearNativeLibraryPreparation()
    model.nativeLibraryBatch.invalidate()
    isBatchReviewPresented = false
  }

  private func addCurrentLibrary() {
    if let selectedRemoteLibrary {
      addToBatch(.ssh(
        sourceID: selectedRemoteLibrary.sourceID, sourceName: selectedRemoteLibrary.sourceName,
        relativePath: selectedRemoteLibrary.entry.relativePath))
    } else if let selectedLibraryURL { addToBatch(.file(selectedLibraryURL)) }
  }

  private func addToBatch(_ source: NativeLibraryDeploymentSource) {
    guard !model.nativeLibraryBatch.isBusy, !queuedLibraries.contains(where: { $0.id == source.id })
    else { return }
    guard queuedLibraries.count < NativeLibraryDeploymentBatch.maximumLibraries else {
      selectionError = DebugL10n.text("debug.artifacts.batch.limit"); return
    }
    queuedLibraries.append(source)
    invalidatePreparations()
  }

  private func removeFromBatch(_ id: String) {
    guard !model.nativeLibraryBatch.isBusy else { return }
    queuedLibraries.removeAll { $0.id == id }
    invalidatePreparations()
  }

  private func handleDirectorySelection(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result else {
      if case .failure(let error) = result { selectionError = error.localizedDescription }
      return
    }
    isReadingDirectories = true
    selectionError = nil
    Task {
      defer { isReadingDirectories = false }
      do {
        directoryCandidates = try await NativeLibraryDirectorySource.libraries(in: urls)
        if directoryCandidates.isEmpty {
          selectionError = DebugL10n.text("debug.artifacts.directory.empty")
        }
      } catch { selectionError = error.localizedDescription }
    }
  }

  private var deploymentInputs: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.artifacts.destination.title"))) {
      Text(DebugL10n.text("debug.artifacts.destination.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LabeledContent(DebugL10n.text("debug.artifacts.bundle")) {
        TextField("com.example.app", text: $targetBundle)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 220)
          .accessibilityIdentifier("debug.artifacts.bundle")
      }
      LabeledContent(DebugL10n.text("debug.artifacts.logicalName")) {
        TextField("libfeature_debug.so", text: $libraryLogicalName)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 220)
          .accessibilityIdentifier("debug.artifacts.logicalName")
      }
      LabeledContent(DebugL10n.text("debug.artifacts.abi")) {
        Text(DebugL10n.text("debug.artifacts.abi.observed"))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      if !targetBundle.isEmpty
        && !DebugTypedValueValidator.isValidBundleName(targetBundle)
      {
        Label(
          DebugL10n.text("debug.artifacts.bundleInvalid"),
          systemImage: "exclamationmark.circle"
        )
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .accessibilityIdentifier("debug.artifacts.bundle.invalid")
      }
      if !libraryLogicalName.isEmpty
        && !DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName)
      {
        Label(
          DebugL10n.text("debug.artifacts.logicalNameInvalid"),
          systemImage: "exclamationmark.circle"
        )
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .accessibilityIdentifier("debug.artifacts.logicalName.invalid")
      }
      DisclosureGroup(DebugL10n.text("debug.artifacts.advanced")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          LabeledContent(DebugL10n.text("debug.artifacts.verification")) {
            Text(DebugL10n.text("debug.artifacts.verify.maps"))
              .multilineTextAlignment(.trailing)
          }
          LabeledContent(DebugL10n.text("debug.artifacts.rollback")) {
            Text(DebugL10n.text("debug.artifacts.rollback.auto"))
              .multilineTextAlignment(.trailing)
          }
          Text(DebugL10n.text("debug.artifacts.policy.required"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WorkspaceMetrics.tightGap)
      }
    }
  }

  private var reviewAndRun: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.artifacts.review.title"))) {
      Text(DebugL10n.text("debug.artifacts.review.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let preparation = currentPreparation {
        WorkspaceNotice(tone: .ok, identifier: "debug.artifacts.planReady") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(DebugL10n.text("debug.artifacts.planReady"))
              .bold()
            DebugCodeRow(
              label: "ELF",
              value:
                "\(preparation.abi) · ELF\(preparation.elfClassBits) · machine \(preparation.machine)"
            )
            DebugCodeRow(label: "Build ID", value: preparation.buildID)
            DebugCodeRow(label: "SHA-256", value: preparation.sha256)
          }
        }
      }
      if model.isPreparingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          ProgressView().controlSize(.small)
          Text(DebugL10n.text("debug.artifacts.preparing"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("debug.artifacts.preparing")
      }
      if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
        WorkspaceNotice(tone: .accent, identifier: "debug.artifacts.running") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(DebugL10n.text("debug.artifacts.running"))
              .bold()
            Text(
              model.workspace.jobs.first(where: {
                $0.id == model.activeNativeLibraryJobID
              })?.timeline.last ?? DebugL10n.text("debug.artifacts.running.detail")
            )
            .font(WorkspaceFont.monospacedDense)
          }
        }
      }
      if let terminal = currentTerminal {
        WorkspaceNotice(
          tone: terminal.state == "succeeded" && !terminal.outcomeUnknown ? .ok : .danger,
          identifier: "debug.artifacts.terminal"
        ) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(
              terminal.state == "succeeded" && !terminal.outcomeUnknown
                ? DebugL10n.text("debug.artifacts.verified")
                : DebugL10n.text("debug.artifacts.notVerified")
            )
            .bold()
            if let latest = terminal.timeline.last {
              Text(latest)
                .font(WorkspaceFont.monospacedDense)
                .textSelection(.enabled)
            }
          }
        }
      }
      if let failure = currentFailure {
        Label(failure, systemImage: "xmark.octagon")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier("debug.artifacts.failure")
      }
      HStack(spacing: WorkspaceMetrics.contentGap) {
        if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
          Button(DebugL10n.text("debug.action.cancel")) {
            model.cancelNativeLibrary()
          }
          .disabled(model.isCancellingNativeLibrary)
          .accessibilityIdentifier("debug.artifacts.cancel")
        } else {
          Button(
            currentPreparation == nil
              ? DebugL10n.text("debug.artifacts.preview")
              : DebugL10n.text("debug.artifacts.reopenPlan")
          ) {
            if currentPreparation != nil {
              presentedPreparation = currentPreparation
            } else {
              preparePlan()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            !inputsAreValid || !operationIsAvailable
              || model.isPreparingNativeLibrary || model.isSubmittingNativeLibrary
              || model.nativeLibraryBatch.isBusy
          )
          .accessibilityIdentifier("debug.artifacts.preview")
        }
        if currentTerminal?.state == "succeeded" {
          Button(DebugL10n.text("debug.artifacts.openLogs"), action: onOpenLogs)
            .accessibilityIdentifier("debug.artifacts.openLogs")
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var productionBoundary: some View {
    WorkspaceNotice(tone: .warning, identifier: "debug.artifacts.productionBoundary") {
      Text(DebugL10n.text("debug.artifacts.productionBoundary"))
    }
  }

  private var resultArtifacts: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.artifacts.results.title")),
      spacing: WorkspaceMetrics.tightGap
    ) {
      ForEach(runtimeArtifacts) { row in
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(row.artifact.name).font(WorkspaceFont.monospacedValue)
            Text(row.artifact.sha256)
              .font(WorkspaceFont.monospacedDense)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Text(
            ByteCountFormatter.string(fromByteCount: row.artifact.byteCount, countStyle: .file)
          )
          .font(WorkspaceFont.tabularSecondary)
        }
      }
    }
  }

  private func preparePlan() {
    guard let target, let fileURL = selectedLibraryURL else { return }
    Task {
      let prepared: Bool
      if let selectedRemoteLibrary {
        prepared = await model.prepareRemoteNativeLibrary(
          target: target,
          selectionIdentityURL: fileURL,
          sourceID: selectedRemoteLibrary.sourceID,
          relativePath: selectedRemoteLibrary.entry.relativePath,
          targetBundle: targetBundle,
          libraryLogicalName: libraryLogicalName,
          verificationProfile: verificationProfile,
          rollbackPolicy: rollbackPolicy)
      } else {
        prepared = await model.prepareNativeLibrary(
          target: target,
          fileURL: fileURL,
          targetBundle: targetBundle,
          libraryLogicalName: libraryLogicalName,
          verificationProfile: verificationProfile,
          rollbackPolicy: rollbackPolicy)
      }
      if prepared { presentedPreparation = currentPreparation }
    }
  }

  private func handleLibrarySelection(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      selectedLibraryURL = url
      selectedRemoteLibrary = nil
      libraryLogicalName = url.lastPathComponent
      selectionError = nil
      model.clearNativeLibraryPreparation()
      if urls.count > 1 { for url in urls { addToBatch(.file(url)) } }
    case .failure(let error):
      selectionError = error.localizedDescription
    }
  }
}

