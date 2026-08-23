import ArkDeckWorkflows
import Observation
import SwiftUI

struct TraceWorkspaceView: View {
  var model: TraceWorkspaceViewModel

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      availability
      target
      relatedDiagnosticsJobs
      TraceConfigurationView(model: model)
      TraceProgressArtifactsView(model: model)
      review
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.refresh()
        } label: {
          Label(traceString("trace.action.refresh"), systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("trace.refresh")
        .disabled(model.isRefreshing)
      }
    }
  }

  private var availability: some View {
    WorkspaceSection(Text(traceString("trace.availability.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        HStack(alignment: .firstTextBaseline) {
          availabilityStatus
          Spacer(minLength: 12)
          Text(model.workspace.operation.reference)
            .font(WorkspaceFont.monospacedValue)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkspaceMetrics.blockGap) { capabilityLabels }
          VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) { capabilityLabels }
        }

        if !model.hasAdapterCapabilityFacts {
          traceNotice(
            traceString("trace.availability.probeGap"),
            systemImage: "waveform.badge.exclamationmark",
            color: .orange,
            identifier: "trace.availability.probeGap")
        }
      }
    }
  }

  @ViewBuilder
  private var availabilityStatus: some View {
    switch model.workspace.operation.availability {
    case .checking:
      Label(traceString("trace.availability.checking"), systemImage: "hourglass")
        .accessibilityIdentifier("trace.availability.status")
    case .available:
      Label(traceString("trace.availability.available"), systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityIdentifier("trace.availability.status")
    case .unavailable(let reasons):
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Label(
          traceString("trace.availability.unavailable"), systemImage: "xmark.octagon.fill"
        )
        .foregroundStyle(.red)
        .accessibilityIdentifier("trace.availability.status")
        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
          Text(reason).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
        }
      }
    }
  }

  @ViewBuilder
  private var capabilityLabels: some View {
    traceCapability(
      traceString("trace.availability.categories"),
      supported: model.workspace.operation.supportsTypedTraceCategories)
    traceCapability(
      traceString("trace.availability.raw"),
      supported: model.workspace.operation.supportsRawTraceArtifact)
    traceCapability(
      traceString("trace.availability.adapter"),
      supported: model.hasAdapterCapabilityFacts)
    traceCapability(
      traceString("trace.availability.parameters"),
      supported: model.hasParameterSnapshotFacts)
  }

  private var target: some View {
    WorkspaceSection(Text(traceString("trace.target.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        if model.workspace.targets.isEmpty {
          traceNotice(
            model.workspace.targetLoadFailure ?? traceString("trace.target.empty"),
            systemImage: "externaldrive.badge.questionmark",
            color: .secondary,
            identifier: "trace.target.empty")
        } else {
          Picker(traceString("trace.target.label"), selection: targetBinding) {
            ForEach(model.workspace.targets) { target in
              Text(target.id).tag(target.id)
            }
          }
          .frame(maxWidth: 460, alignment: .leading)
          .accessibilityIdentifier("trace.target.picker")
        }

        if let target = model.selectedTarget {
          Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: 5) {
            traceReviewRow(
              traceString("trace.target.binding"), String(target.bindingRevision),
              monospaced: true)
            traceReviewRow(
              traceString("trace.target.tool"), target.toolVersion,
              monospaced: true)
            traceReviewRow(
              traceString("trace.target.adopted"), target.adoptedAtUTC,
              monospaced: true)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var relatedDiagnosticsJobs: some View {
    if let failure = model.workspace.jobLoadFailure {
      traceNotice(
        failure,
        systemImage: "exclamationmark.triangle",
        color: .orange,
        identifier: "trace.jobs.failure")
    } else if !model.workspace.relatedDiagnosticsJobs.isEmpty {
      WorkspaceSection(Text(traceString("trace.jobs.title"))) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(model.workspace.relatedDiagnosticsJobs.prefix(3)) { job in
            HStack(spacing: WorkspaceMetrics.tightGap) {
              if job.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              } else if traceActiveJobStates.contains(job.state) {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
              }
              VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text(job.id).font(WorkspaceFont.monospacedValue)
                Text(traceString("trace.jobs.selectionUnknown"))
                  .font(WorkspaceFont.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              Text(job.state)
              Text(job.targetID).font(WorkspaceFont.monospacedDense).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
          }
          Text(traceString("trace.jobs.readOnly"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var review: some View {
    WorkspaceSection(Text(traceString("trace.review.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.rowGap) {
          traceReviewRow(
            traceString("trace.review.target"),
            model.selectedTarget?.id ?? traceString("trace.value.notSelected"),
            monospaced: model.selectedTarget != nil)
          traceReviewRow(
            traceString("trace.review.preset"), model.configurationTitle)
          traceReviewRow(
            traceString("trace.review.tags"),
            model.requestedTags.isEmpty
              ? traceString("trace.value.none") : model.requestedTags.joined(separator: ", "),
            monospaced: true)
          traceReviewRow(
            traceString("trace.review.duration"), "\(model.durationText) s",
            monospaced: true)
          traceReviewRow(
            traceString("trace.review.buffer"), "\(model.bufferText) KB",
            monospaced: true)
          traceReviewRow(
            traceString("trace.review.effect"), "deviceMutation",
            monospaced: true)
          traceReviewRow(
            traceString("trace.review.cancellation"),
            model.workspace.operation.traceStepCancellation
              ?? traceString("trace.value.unavailable"),
            monospaced: true)
        }

        Divider()

        Text(traceString("trace.review.blockers"))
          .font(WorkspaceFont.label)
        if reviewBlockers.isEmpty {
          Label(traceString("trace.review.ready"), systemImage: "checkmark.shield.fill")
            .font(.callout)
            .foregroundStyle(.green)
        } else {
          ForEach(Array(reviewBlockers.enumerated()), id: \.offset) { _, blocker in
            Label(blocker, systemImage: "xmark.circle")
              .font(.callout)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        HStack {
          if let activeJobID = model.activeJobID {
            Button(traceString("trace.action.cancel")) { model.cancel() }
              .disabled(model.isCancelling)
              .accessibilityIdentifier("trace.cancel")
            Text(activeJobID)
              .font(WorkspaceFont.monospacedDense)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          Button(model.isSubmitting ? traceString("trace.action.running") : startActionTitle) {
            model.submit()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("trace.start")
          .disabled(!reviewBlockers.isEmpty || model.isSubmitting)
          .help(reviewBlockers.joined(separator: "\n"))
        }
        if let failure = model.submissionFailure {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("trace.submission.failure")
        } else if let terminal = model.terminalSubmission {
          // An unknown outcome is a state, so it carries a symbol as well as a
          // colour (spec §2, §4.4).
          Label {
            Text("\(terminal.state) · \(terminal.jobID)")
              .textSelection(.enabled)
          } icon: {
            Image(systemName: terminal.outcomeUnknown ? "questionmark.diamond.fill" : "clock")
          }
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(terminal.outcomeUnknown ? Color.orange : Color.secondary)
        }
        Text(traceString("trace.review.typedDispatch"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  /// The button admits what it would do: a run that mutates parameters says
  /// so before capturing, and the configuration name and duration ride along
  /// so the reader can match them against the left column before acting.
  private var startActionTitle: String {
    let resource =
      model.parameterMode == .unchanged
      ? LocalizedStringResource.TraceLocalizable.traceActionStartNamed(
        model.configurationTitle, model.durationText)
      : LocalizedStringResource.TraceLocalizable.traceActionApplyAndStartNamed(
        model.configurationTitle, model.durationText)
    return String(localized: resource)
  }

  private var reviewBlockers: [String] {
    var values: [String] = []
    switch model.workspace.operation.availability {
    case .checking:
      values.append(traceString("trace.blocker.checking"))
    case .unavailable(let reasons):
      values.append(traceString("trace.blocker.operation"))
      values.append(contentsOf: reasons)
    case .available:
      break
    }
    if model.selectedTarget == nil {
      values.append(traceString("trace.blocker.target"))
    }
    if !model.durationIsValid {
      values.append(traceString("trace.blocker.duration"))
    }
    if !model.bufferIsValid {
      values.append(traceString("trace.blocker.buffer"))
    }
    if !model.hasAdapterCapabilityFacts {
      values.append(traceString("trace.blocker.adapter"))
    }
    // Two distinct failures share this list: an empty request (a capture
    // always carries at least one tag) and a non-empty one whose members no
    // probe has classified yet. Neither implies the other.
    if model.requestedTags.isEmpty {
      values.append(traceString("trace.blocker.noTags"))
    } else if !model.unsupportedRequestedTags.isEmpty {
      values.append(traceString("trace.blocker.tags"))
    }
    if !model.hasParameterSnapshotFacts {
      values.append(traceString("trace.blocker.parameters"))
    }
    return values
  }

  private var targetBinding: Binding<String> {
    Binding(
      get: { model.selectedTargetID },
      set: { model.setTargetID($0) })
  }
}

@MainActor
@Observable
final class TraceWorkspaceViewModel {
  private(set) var workspace = TraceWorkspacePresentation.loading
  private(set) var selectedTargetID = ""
  private(set) var configurationMode = TraceConfigurationMode.preset
  private(set) var selectedPresetID = TracePresetID.arkuiDeep
  private(set) var customTags: Set<String> = []
  private(set) var durationText = "15"
  private(set) var bufferText = "8192"
  private(set) var parameterMode = TraceParameterUISelection.unchanged
  private(set) var persistentChangeConfirmed = false
  private(set) var filtersCreateFileAsset = false
  private(set) var isRefreshing = false
  private(set) var artifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]
  private(set) var artifactFailuresByJobID: [String: String] = [:]
  private(set) var evidenceByJobID: [String: RuntimeJobEvidencePresentation] = [:]
  private(set) var activeJobID: String?
  private(set) var terminalSubmission: TraceJobTerminalPresentation?
  private(set) var submissionFailure: String?
  private(set) var isSubmitting = false
  private(set) var isCancelling = false

  private let provider: any TraceApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding

  init(
    provider: any TraceApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil
  ) {
    self.provider = provider
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
  }

  var selectedTarget: TraceTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var runtimeArtifacts: [RuntimeArtifactPresentation] {
    workspace.relatedDiagnosticsJobs
      .filter { selectedTargetID.isEmpty || $0.targetID == selectedTargetID }
      .flatMap { artifactsByJobID[$0.id] ?? [] }
  }

  var runtimeArtifactFailures: [String] {
    workspace.relatedDiagnosticsJobs
      .filter { selectedTargetID.isEmpty || $0.targetID == selectedTargetID }
      .compactMap { artifactFailuresByJobID[$0.id] }
  }

  var latestTraceEvidence: RuntimeJobEvidencePresentation? {
    workspace.relatedDiagnosticsJobs
      .filter { selectedTargetID.isEmpty || $0.targetID == selectedTargetID }
      .compactMap { evidenceByJobID[$0.id] }
      .first { !$0.traceParameters.isEmpty }
  }

  func traceParameterEvidence(name: String) -> RuntimeTraceParameterPresentation? {
    latestTraceEvidence?.traceParameters.first { $0.name == name }
  }

  var selectedPreset: TracePresetDefinition {
    TracePresetCatalog.definition(for: selectedPresetID)
  }

  var hasAdapterCapabilityFacts: Bool {
    selectedRuntimeProbe?.adapterDisposition == "captureEligible"
  }

  var hasParameterSnapshotFacts: Bool {
    selectedRuntimeProbe?.parameters.count == TraceDebugParameterCatalog.definitions.count
  }

  var confirmedTags: [String] { selectedRuntimeProbe?.supportedTags ?? [] }

  var unsupportedRequestedTags: [String] {
    requestedTags.filter { !confirmedTags.contains($0) }
  }

  func parameterObservation(name: String) -> TraceRuntimeParameterObservation? {
    selectedRuntimeProbe?.parameters.first { $0.name == name }
  }

  var selectedRuntimeProbe: TraceRuntimeProbeSnapshot? {
    guard let probe = workspace.runtimeProbe,
      probe.targetID == selectedTargetID,
      probe.bindingRevision == selectedTarget?.bindingRevision
    else { return nil }
    return probe
  }

  var requestedTags: [String] {
    configurationMode == .preset ? selectedPreset.logicalTags : customTags.sorted()
  }

  var configurationTitle: String {
    configurationMode == .preset
      ? traceString("trace.preset.\(selectedPresetID.rawValue)")
      : traceString("trace.configuration.custom")
  }

  var durationRange: ClosedRange<Int> {
    workspace.operation.durationSecondsRange ?? 1...600
  }

  var bufferRange: ClosedRange<Int> {
    workspace.operation.traceBufferKBRange ?? 1_024...65_536
  }

  var durationValidation: TraceNumericInputValidation {
    TraceNumericInputValidator.validate(durationText, range: durationRange)
  }

  var bufferValidation: TraceNumericInputValidation {
    TraceNumericInputValidator.validate(bufferText, range: bufferRange)
  }

  var durationIsValid: Bool {
    if case .valid = durationValidation { return true }
    return false
  }

  var bufferIsValid: Bool {
    if case .valid = bufferValidation { return true }
    return false
  }

  var canUseTemporaryRestore: Bool { false }
  var canUsePersistentChange: Bool { false }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    let detailProvider = detailProvider
    let targetID = selectedTargetID
    Task { [weak self] in
      let next = await provider.refreshWorkspace(
        targetID: targetID.isEmpty ? nil : targetID)
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      let previousTarget = self.selectedTarget
      let nextTargetID =
        next.targets.contains(where: { $0.id == self.selectedTargetID })
        ? self.selectedTargetID
        : next.targets.first?.id ?? ""
      self.workspace = next
      self.selectedTargetID = nextTargetID
      var artifacts: [String: [RuntimeArtifactPresentation]] = [:]
      var failures: [String: String] = [:]
      var evidence: [String: RuntimeJobEvidencePresentation] = [:]
      for job in next.relatedDiagnosticsJobs.prefix(3) {
        let detail = await detailProvider.loadJobDetail(
          jobID: job.id,
          operationReference: TraceApplicationFacade.operationReference)
        switch detail.artifactAvailability {
        case .available:
          artifacts[job.id] = detail.artifacts
        case .unavailable(let reason):
          failures[job.id] = reason
        }
        if let jobEvidence = detail.evidence, !jobEvidence.traceParameters.isEmpty {
          evidence[job.id] = jobEvidence
        }
      }
      guard !Task.isCancelled else { return }
      self.artifactsByJobID = artifacts
      self.artifactFailuresByJobID = failures
      self.evidenceByJobID = evidence
      if previousTarget != self.selectedTarget {
        self.resetTargetScopedReview()
      }
    }
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    resetTargetScopedReview()
    refresh()
  }

  /// Custom is another entry to the same request, not a second run mode: it
  /// starts from the current preset's tag set instead of an empty selection.
  func setConfigurationMode(_ mode: TraceConfigurationMode) {
    configurationMode = mode
    if mode == .custom { customTags = Set(selectedPreset.logicalTags) }
  }

  /// A capture always carries at least one tag, so the last member of the
  /// custom selection cannot be toggled off. Tags outside the preset's
  /// logical family have no probe-backed vocabulary and are rejected.
  func toggleCustomTag(_ tag: String) {
    guard configurationMode == .custom, selectedPreset.logicalTags.contains(tag) else { return }
    if customTags.contains(tag) {
      guard customTags.count > 1 else { return }
      customTags.remove(tag)
    } else {
      customTags.insert(tag)
    }
  }

  func setPreset(_ preset: TracePresetID) {
    guard preset != .custom else {
      setConfigurationMode(.custom)
      return
    }
    selectedPresetID = preset
    configurationMode = .preset
  }

  func setDurationText(_ value: String) {
    durationText = value
  }

  func setParameterMode(_ mode: TraceParameterUISelection) {
    guard
      mode == .unchanged
        || (mode == .temporaryRestore && canUseTemporaryRestore)
        || (mode == .persistentChange && canUsePersistentChange)
    else { return }
    parameterMode = mode
    persistentChangeConfirmed = false
  }

  func setPersistentChangeConfirmed(_ confirmed: Bool) {
    guard parameterMode == .persistentChange, canUsePersistentChange else { return }
    persistentChangeConfirmed = confirmed
  }

  func setFiltersCreateFileAsset(_ filters: Bool) {
    guard workspace.operation.supportsFilteredTraceArtifact else {
      filtersCreateFileAsset = false
      return
    }
    filtersCreateFileAsset = filters
  }

  func submit() {
    guard !isSubmitting, let target = selectedTarget,
      case .valid(let durationSeconds) = durationValidation,
      case .valid(let bufferKB) = bufferValidation,
      hasAdapterCapabilityFacts, hasParameterSnapshotFacts,
      !requestedTags.isEmpty, unsupportedRequestedTags.isEmpty,
      parameterMode == .unchanged
    else { return }
    isSubmitting = true
    activeJobID = nil
    terminalSubmission = nil
    submissionFailure = nil
    let provider = provider
    let tags = requestedTags
    Task { [weak self] in
      let submitted = await provider.submitCapture(
        target: target, durationSeconds: durationSeconds, tags: tags, bufferKB: bufferKB)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.submissionFailure = failure
        self.isSubmitting = false
      case .submitted(let acceptance):
        self.activeJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh()
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeJobID = nil
        self.isSubmitting = false
        switch result {
        case .completed(let terminal): self.terminalSubmission = terminal
        case .failed(let failure): self.submissionFailure = failure
        }
        self.refresh()
      }
    }
  }

  func cancel() {
    guard let jobID = activeJobID, !isCancelling else { return }
    isCancelling = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancelling = false
      if !accepted {
        self.submissionFailure = traceString("trace.cancel.failed")
      }
    }
  }

  private func resetTargetScopedReview() {
    customTags = configurationMode == .custom ? Set(selectedPreset.logicalTags) : []
    parameterMode = .unchanged
    persistentChangeConfirmed = false
  }
}

enum TraceConfigurationMode: String, CaseIterable, Hashable {
  case preset
  case custom
}

enum TraceParameterUISelection: String, CaseIterable, Hashable {
  case unchanged
  case temporaryRestore
  case persistentChange
}

let traceActiveJobStates: Set<String> = [
  "queued", "planning", "preflight", "running", "finalizing", "waitingForDevice",
  "awaitingRebindConfirmation", "cancellingAtSafeBoundary", "reconciling",
]

func traceString(_ key: String) -> String {
  String(localized: String.LocalizationValue(key), table: "TraceLocalizable")
}

func traceCapability(_ title: String, supported: Bool) -> some View {
  Label(title, systemImage: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
    .font(.callout)
    .foregroundStyle(supported ? Color.green : Color.secondary)
    .accessibilityValue(
      supported ? traceString("trace.value.supported") : traceString("trace.value.unavailable"))
}

func traceNotice(
  _ text: String,
  systemImage: String,
  color: Color,
  identifier: String
) -> some View {
  Label {
    Text(text).fixedSize(horizontal: false, vertical: true)
  } icon: {
    Image(systemName: systemImage).foregroundStyle(color)
  }
  .font(WorkspaceFont.secondary)
  .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
  .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background(
    color.opacity(0.08),
    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
  )
  .overlay {
    RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
      .stroke(color.opacity(0.38), lineWidth: 1)
  }
  .accessibilityIdentifier(identifier)
}

func traceReviewRow(
  _ label: String,
  _ value: String,
  monospaced: Bool = false
) -> some View {
  GridRow(alignment: .firstTextBaseline) {
    Text(label)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.trailing)
    Text(value)
      .font(monospaced ? .body.monospaced() : .body)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .gridColumnAlignment(.leading)
  }
}
