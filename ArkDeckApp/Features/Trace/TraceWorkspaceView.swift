import ArkDeckWorkflows
import Combine
import SwiftUI

struct TraceWorkspaceView: View {
  @ObservedObject var model: TraceWorkspaceViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        availability
        target
        relatedDiagnosticsJobs
        TraceConfigurationView(model: model)
        TraceProgressArtifactsView(model: model)
        review
      }
      .frame(maxWidth: 1_000, alignment: .topLeading)
      .padding(20)
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
    GroupBox(traceString("trace.availability.title")) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          availabilityStatus
          Spacer(minLength: 12)
          Text(model.workspace.operation.reference)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) { capabilityLabels }
          VStack(alignment: .leading, spacing: 6) { capabilityLabels }
        }

        if !model.workspace.operation.exposesAdapterCapabilityFacts {
          traceNotice(
            traceString("trace.availability.probeGap"),
            systemImage: "waveform.badge.exclamationmark",
            color: .orange,
            identifier: "trace.availability.probeGap")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
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
      VStack(alignment: .leading, spacing: 4) {
        Label(
          traceString("trace.availability.unavailable"), systemImage: "xmark.octagon.fill"
        )
        .foregroundStyle(.red)
        .accessibilityIdentifier("trace.availability.status")
        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
          Text(reason).font(.caption.monospaced()).textSelection(.enabled)
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
      supported: model.workspace.operation.exposesAdapterCapabilityFacts)
    traceCapability(
      traceString("trace.availability.parameters"),
      supported: model.workspace.operation.exposesParameterSnapshotFacts)
  }

  private var target: some View {
    GroupBox(traceString("trace.target.title")) {
      VStack(alignment: .leading, spacing: 10) {
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
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
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
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
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
      GroupBox(traceString("trace.jobs.title")) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.workspace.relatedDiagnosticsJobs.prefix(3)) { job in
            HStack(spacing: 8) {
              if job.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              } else if traceActiveJobStates.contains(job.state) {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text(job.id).font(.callout.monospaced())
                Text(traceString("trace.jobs.selectionUnknown"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              Text(job.state)
              Text(job.targetID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
          }
          Text(traceString("trace.jobs.readOnly"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }
    }
  }

  private var review: some View {
    GroupBox(traceString("trace.review.title")) {
      VStack(alignment: .leading, spacing: 14) {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
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
          .font(.subheadline.weight(.semibold))
        ForEach(Array(reviewBlockers.enumerated()), id: \.offset) { _, blocker in
          Label(blocker, systemImage: "xmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
          Spacer()
          Button(traceString("trace.action.start")) {}
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("trace.start")
            .disabled(true)
            .help(reviewBlockers.joined(separator: "\n"))
        }
        Text(traceString("trace.review.noDispatch"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
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
    if !model.workspace.operation.exposesAdapterCapabilityFacts {
      values.append(traceString("trace.blocker.adapter"))
    }
    if !model.requestedTags.isEmpty {
      values.append(traceString("trace.blocker.tags"))
    }
    if !model.workspace.operation.exposesParameterSnapshotFacts {
      values.append(traceString("trace.blocker.parameters"))
    }
    if !model.workspace.operation.supportsFilteredTraceArtifact
      || !model.workspace.operation.supportsCaptureLogArtifact
    {
      values.append(traceString("trace.blocker.artifacts"))
    }
    values.append(traceString("trace.blocker.readOnlyTransport"))
    return values
  }

  private var targetBinding: Binding<String> {
    Binding(
      get: { model.selectedTargetID },
      set: { model.setTargetID($0) })
  }
}

@MainActor
final class TraceWorkspaceViewModel: ObservableObject {
  @Published private(set) var workspace = TraceWorkspacePresentation.loading
  @Published private(set) var selectedTargetID = ""
  @Published private(set) var configurationMode = TraceConfigurationMode.preset
  @Published private(set) var selectedPresetID = TracePresetID.arkuiDeep
  @Published private(set) var customTags: Set<String> = []
  @Published private(set) var durationText = "10"
  @Published private(set) var bufferText = "8192"
  @Published private(set) var parameterMode = TraceParameterUISelection.unchanged
  @Published private(set) var persistentChangeConfirmed = false
  @Published private(set) var filtersCreateFileAsset = false
  @Published private(set) var isRefreshing = false

  private let provider: any TraceApplicationProviding

  init(provider: any TraceApplicationProviding) {
    self.provider = provider
  }

  var selectedTarget: TraceTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var selectedPreset: TracePresetDefinition {
    TracePresetCatalog.definition(for: selectedPresetID)
  }

  /// The current read facade exposes no per-target probe receipt, so an empty
  /// collection means unknown capabilities, not a device with zero tags.
  var confirmedTags: [String] { [] }

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
    Task { [weak self] in
      let next = await provider.refreshWorkspace()
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
      if previousTarget != self.selectedTarget {
        self.resetTargetScopedReview()
      }
    }
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    resetTargetScopedReview()
  }

  func setConfigurationMode(_ mode: TraceConfigurationMode) {
    configurationMode = mode
    if mode == .custom { customTags.removeAll() }
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

  func setBufferText(_ value: String) {
    bufferText = value
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
    filtersCreateFileAsset = filters
  }

  private func resetTargetScopedReview() {
    customTags.removeAll()
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
  .font(.callout)
  .padding(10)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
