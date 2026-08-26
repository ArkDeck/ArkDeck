import ArkDeckWorkflows
import ArkDeckTraceAdapter
import ArkTraceAppSupport
import Foundation
import Observation
import SwiftUI

struct TraceWorkspaceView: View {
  var model: TraceWorkspaceViewModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      WorkspaceHeaderBar(
        summary: Text(traceString("trace.workspace.summary")),
        summaryIdentifier: "trace.workspace.summary")

      WorkspaceSection(
        Text(traceString("trace.capture.title")),
        identifier: "trace.capture.section",
        accessory: { availabilityStatus }
      ) {
        TraceConfigurationView(model: model)
        captureFooter
      }

      TraceProgressArtifactsView(model: model)
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
    .onChange(of: model.viewerOpenRequestID) { oldValue, newValue in
      guard newValue != oldValue else { return }
      openWindow(id: ArkDeckWindow.traceViewer)
    }
  }

  @ViewBuilder
  private var availabilityStatus: some View {
    if model.isRefreshing || model.workspace.operation.availability == .checking {
      Label(traceString("trace.availability.checking"), systemImage: "hourglass")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("trace.availability.status")
    } else if model.captureBlockers.isEmpty {
      Label(traceString("trace.availability.available"), systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityIdentifier("trace.availability.status")
    } else {
      Label(traceString("trace.availability.unavailable"), systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityIdentifier("trace.availability.status")
    }
  }

  private var captureFooter: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Divider()

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: WorkspaceMetrics.blockGap) {
          captureStatus
          Spacer(minLength: WorkspaceMetrics.contentGap)
          captureAction
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          captureStatus
          captureAction.frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }

  @ViewBuilder
  private var captureStatus: some View {
    if model.isSubmitting {
      HStack(spacing: WorkspaceMetrics.tightGap) {
        ProgressView().controlSize(.small)
        Text(traceString("trace.action.running"))
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("trace.capture.status")
    } else if let failure = model.submissionFailure {
      Label(failure, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("trace.submission.failure")
    } else if let terminal = model.terminalSubmission {
      if terminal.outcomeUnknown {
        Label(
          traceString("trace.capture.outcomeUnknown"),
          systemImage: "questionmark.diamond.fill")
          .foregroundStyle(.orange)
          .accessibilityIdentifier("trace.capture.status")
      } else if terminal.state == "succeeded" {
        Label(traceString("trace.capture.finished"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityIdentifier("trace.capture.status")
      } else {
        Label(traceString("trace.capture.notCompleted"), systemImage: "xmark.circle")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("trace.capture.status")
      }
    } else if let blocker = model.captureBlockers.first {
      Label(blocker, systemImage: "exclamationmark.circle")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .help(model.captureBlockerDetails.joined(separator: "\n"))
        .accessibilityIdentifier("trace.capture.status")
    } else {
      Label(traceString("trace.capture.localOnly"), systemImage: "lock")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("trace.capture.status")
    }
  }

  @ViewBuilder
  private var captureAction: some View {
    if let activeJobID = model.activeJobID {
      HStack(spacing: WorkspaceMetrics.contentGap) {
        Text(activeJobID)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Button(traceString("trace.action.cancel"), role: .cancel) {
          model.cancel()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(model.isCancelling)
        .accessibilityIdentifier("trace.cancel")
      }
    } else {
      Button(traceString("trace.action.start")) {
        model.submit()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(model.isSubmitting)
      .help(model.captureBlockerDetails.joined(separator: "\n"))
      .accessibilityHint(model.captureBlockers.first ?? "")
      .accessibilityIdentifier("trace.start")
    }
  }
}

@MainActor
@Observable
final class TraceWorkspaceViewModel {
  private static let defaultBufferKB = 8_192

  private(set) var workspace = TraceWorkspacePresentation.loading
  private(set) var selectedTargetID = ""
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var deviceNames: [String: String] = [:]
  private(set) var selectedPresetID = TracePresetID.arkuiDeep
  private(set) var durationText = "10"
  private(set) var durationUnit = TraceDurationInputUnit.seconds
  private(set) var isRefreshing = false
  private(set) var activeJobID: String?
  private(set) var terminalSubmission: TraceJobTerminalPresentation?
  private(set) var submissionFailure: String?
  private(set) var isSubmitting = false
  private(set) var isCancelling = false
  private(set) var isPreparingViewer = false
  private(set) var viewerArtifactFailure: String?
  private(set) var latestViewerArtifactName: String?
  private(set) var viewerOpenRequestID: UInt64 = 0

  private let provider: any TraceApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding
  let documentController: TraceDocumentController

  init(
    provider: any TraceApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil,
    documentController: TraceDocumentController = TraceDocumentController(
      configuration: ArkDeckTraceConfiguration.make())
  ) {
    self.provider = provider
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
    self.documentController = documentController
  }

  var targets: [TraceTargetPresentation] {
    TraceApplicationFacade.rejoin(targets: workspace.targets, with: deviceObservation)
  }

  var selectedTarget: TraceTargetPresentation? {
    targets.first { $0.id == selectedTargetID }
  }

  var capturePresets: [TracePresetDefinition] {
    TracePresetCatalog.definitions.filter { $0.id != .custom }
  }

  var selectedPreset: TracePresetDefinition {
    TracePresetCatalog.definition(for: selectedPresetID)
  }

  var requestedTags: [String] {
    selectedPreset.logicalTags
  }

  var selectedRuntimeProbe: TraceRuntimeProbeSnapshot? {
    guard let probe = workspace.runtimeProbe,
      probe.targetID == selectedTargetID,
      probe.bindingRevision == selectedTarget?.bindingRevision
    else { return nil }
    return probe
  }

  var hasAdapterCapabilityFacts: Bool {
    selectedRuntimeProbe?.adapterDisposition == "captureEligible"
  }

  var hasParameterSnapshotFacts: Bool {
    selectedRuntimeProbe?.parameters.count == TraceDebugParameterCatalog.definitions.count
  }

  var confirmedTags: [String] {
    selectedRuntimeProbe?.supportedTags ?? []
  }

  var unsupportedRequestedTags: [String] {
    requestedTags.filter { !confirmedTags.contains($0) }
  }

  var durationRange: ClosedRange<Int> {
    workspace.operation.durationSecondsRange ?? 1...600
  }

  var availableDurationUnits: [TraceDurationInputUnit] {
    TraceDurationInputUnit.allCases.filter {
      $0.inputRange(forDurationSecondsRange: durationRange) != nil
    }
  }

  var durationInputRange: ClosedRange<Int> {
    durationUnit.inputRange(forDurationSecondsRange: durationRange) ?? durationRange
  }

  var durationValidation: TraceNumericInputValidation {
    let input = TraceNumericInputValidator.validate(durationText, range: durationInputRange)
    guard case .valid(let inputValue) = input else { return input }
    guard
      let seconds = durationUnit.durationSeconds(
        for: inputValue,
        allowedRange: durationRange)
    else { return .invalid(.outsideRange(durationInputRange)) }
    return .valid(seconds)
  }

  var durationIsValid: Bool {
    if case .valid = durationValidation { return true }
    return false
  }

  var captureBufferKB: Int? {
    let range = workspace.operation.traceBufferKBRange ?? 1_024...65_536
    guard range.contains(Self.defaultBufferKB) else { return nil }
    return Self.defaultBufferKB
  }

  var captureBlockers: [String] {
    var blockers: [String] = []
    switch workspace.operation.availability {
    case .checking:
      blockers.append(traceString("trace.blocker.checking"))
    case .unavailable(let reasons):
      blockers.append(traceString("trace.blocker.operation"))
      blockers.append(contentsOf: reasons)
    case .available:
      break
    }
    if selectedTarget == nil {
      blockers.append(traceString("trace.blocker.target"))
    }
    if !durationIsValid {
      blockers.append(traceString("trace.blocker.duration"))
    }
    if captureBufferKB == nil {
      blockers.append(traceString("trace.blocker.buffer"))
    }
    if selectedRuntimeProbe == nil {
      blockers.append(traceString("trace.blocker.capability"))
    } else if !hasAdapterCapabilityFacts {
      blockers.append(traceString("trace.blocker.adapterUnsupported"))
    } else {
      if !hasParameterSnapshotFacts {
        blockers.append(traceString("trace.blocker.capability"))
      }
      if requestedTags.isEmpty {
        blockers.append(traceString("trace.blocker.noTags"))
      } else if !unsupportedRequestedTags.isEmpty {
        blockers.append(traceString("trace.blocker.tags"))
      }
    }
    return blockers
  }

  var captureBlockerDetails: [String] {
    var details = captureBlockers
    if let probeFailure = workspace.probeFailure,
      !probeFailure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      details.append(probeFailure)
    }
    return details
  }

  var canStartCapture: Bool {
    !isSubmitting && captureBlockers.isEmpty
  }

  func applyDeviceObservation(
    _ observation: DeviceListPresentation,
    names: [String: String]
  ) {
    deviceObservation = observation
    deviceNames = names
  }

  func deviceTitle(_ target: TraceTargetPresentation) -> String {
    if let name = deviceNames[target.id], name != target.id { return name }
    if let name = target.deviceName,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return name
    }
    return target.id
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    let requestedTargetID = selectedTargetID
    Task { [weak self] in
      let next = await provider.refreshWorkspace(
        targetID: requestedTargetID.isEmpty ? nil : requestedTargetID)
      guard let self else { return }
      guard !Task.isCancelled else {
        self.isRefreshing = false
        return
      }
      let selectionAtCompletion = self.selectedTargetID
      let resolvedTargetID: String
      if !selectionAtCompletion.isEmpty,
        next.targets.contains(where: { $0.id == selectionAtCompletion })
      {
        resolvedTargetID = selectionAtCompletion
      } else if let connectedTargetID = self.preferredConnectedTargetID(in: next.targets) {
        resolvedTargetID = connectedTargetID
      } else if let probedTargetID = next.runtimeProbe?.targetID,
        next.targets.contains(where: { $0.id == probedTargetID })
      {
        resolvedTargetID = probedTargetID
      } else {
        resolvedTargetID = next.targets.first?.id ?? ""
      }
      self.workspace = next
      self.selectedTargetID = resolvedTargetID
      self.isRefreshing = false

      // A picker change may arrive while the previous target's probe is in
      // flight. Never apply those capability facts to the new selection;
      // immediately request the exact target/binding instead.
      let selectionChangedDuringRefresh = resolvedTargetID != requestedTargetID
      if selectionChangedDuringRefresh,
        next.runtimeProbe?.targetID != resolvedTargetID
      {
        self.refresh()
      }
    }
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    submissionFailure = nil
    refresh()
  }

  func setPreset(_ preset: TracePresetID) {
    guard preset != .custom else { return }
    selectedPresetID = preset
    submissionFailure = nil
  }

  func setDurationText(_ value: String) {
    durationText = value
    submissionFailure = nil
  }

  func setDurationUnit(_ unit: TraceDurationInputUnit) {
    guard unit != durationUnit,
      unit.inputRange(forDurationSecondsRange: durationRange) != nil
    else { return }
    let currentSeconds: Int
    if case .valid(let seconds) = durationValidation {
      currentSeconds = seconds
    } else {
      currentSeconds = min(durationRange.upperBound, max(durationRange.lowerBound, 10))
    }
    guard
      let value = unit.inputValue(
        forDurationSeconds: currentSeconds,
        allowedRange: durationRange)
    else { return }
    durationUnit = unit
    durationText = String(value)
    submissionFailure = nil
  }

  func selectQuickDuration(_ value: Int) {
    guard durationUnit.quickValues.contains(value), quickDurationIsAvailable(value) else { return }
    durationText = String(value)
    submissionFailure = nil
  }

  func quickDurationIsAvailable(_ value: Int) -> Bool {
    durationUnit.durationSeconds(for: value, allowedRange: durationRange) != nil
  }

  private func preferredConnectedTargetID(
    in targets: [TraceTargetPresentation]
  ) -> String? {
    guard case .available = deviceObservation.availability else { return nil }
    return deviceObservation.candidates.first { candidate in
      guard candidate.isAuthorized,
        let targetID = candidate.adoptedTargetID,
        let bindingRevision = candidate.bindingRevision
      else { return false }
      return targets.contains {
        $0.id == targetID && $0.bindingRevision == bindingRevision
      }
    }?.adoptedTargetID
  }

  func submit() {
    guard !isSubmitting else { return }
    guard canStartCapture else {
      submissionFailure = captureBlockers.first
      return
    }
    guard
      let target = selectedTarget,
      case .valid(let durationSeconds) = durationValidation,
      let bufferKB = captureBufferKB
    else { return }
    isSubmitting = true
    activeJobID = nil
    terminalSubmission = nil
    submissionFailure = nil
    viewerArtifactFailure = nil
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
        case .completed(let terminal):
          self.terminalSubmission = terminal
          if terminal.state == "succeeded", !terminal.outcomeUnknown {
            await self.openPublishedTrace(jobID: terminal.jobID)
          }
        case .failed(let failure):
          self.submissionFailure = failure
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

  func reopenLatestTraceArtifact() {
    guard let terminalSubmission,
      terminalSubmission.state == "succeeded",
      !terminalSubmission.outcomeUnknown,
      !isPreparingViewer
    else { return }
    Task { [weak self] in
      await self?.openPublishedTrace(jobID: terminalSubmission.jobID)
    }
  }

  func showViewer() {
    viewerOpenRequestID &+= 1
  }

  private func openPublishedTrace(jobID: String) async {
    guard !isPreparingViewer else { return }
    isPreparingViewer = true
    viewerArtifactFailure = nil
    defer { isPreparingViewer = false }

    let detail = await detailProvider.loadJobDetail(
      jobID: jobID,
      operationReference: TraceApplicationFacade.operationReference)
    guard case .available = detail.artifactAvailability else {
      viewerArtifactFailure = traceString("trace.viewer.artifactListUnavailable")
      return
    }
    guard let artifact = TracePublishedArtifactPolicy.selectRawTrace(from: detail.artifacts) else {
      viewerArtifactFailure = traceString("trace.viewer.artifactInvalid")
      return
    }

    let destination: URL
    do {
      destination = try Self.traceInboxURL(sha256: artifact.sha256)
    } catch {
      viewerArtifactFailure = traceString("trace.viewer.stagingUnavailable")
      return
    }
    switch await detailProvider.exportArtifact(
      jobID: jobID,
      artifact: artifact,
      destinationURL: destination,
      allowSensitive: true)
    {
    case .completed(let url):
      latestViewerArtifactName = artifact.name
      documentController.open(url)
      viewerOpenRequestID &+= 1
    case .failed:
      viewerArtifactFailure = traceString("trace.viewer.readFailed")
    }
  }

  private static func traceInboxURL(sha256: String) throws -> URL {
    guard sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ byte in
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
          || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
      }),
      let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { throw TraceViewerInboxError.unavailable }
    let root = cache
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
      .appending(path: "TraceInbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw TraceViewerInboxError.unavailable
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path)
    let destination = root
      .resolvingSymlinksInPath()
      .appending(path: "\(sha256).htrace", directoryHint: .notDirectory)
    if FileManager.default.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw TraceViewerInboxError.unavailable
      }
    }
    return destination
  }
}

private enum TraceViewerInboxError: Error {
  case unavailable
}

func traceString(_ key: String) -> String {
  String(localized: String.LocalizationValue(key), table: "TraceLocalizable")
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
