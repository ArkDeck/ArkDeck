import AppKit
import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

private final class FlashImageArchiveOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
  func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      return true
    }
    return FlashImageArchiveSelectionPolicy.allows(url)
  }
}

@MainActor
private enum FlashImageArchiveOpenPanel {
  static func choose() -> URL? {
    let panel = NSOpenPanel()
    let exactFilenameDelegate = FlashImageArchiveOpenPanelDelegate()
    panel.delegate = exactFilenameDelegate
    panel.allowedContentTypes = [
      .gzip,
      .zip,
      UTType(filenameExtension: "7z") ?? UTType(importedAs: "org.7-zip.7-zip-archive"),
    ]
    panel.allowsOtherFileTypes = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private struct FlashWorkspaceSurface<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
  }
}

private enum FlashWorkspaceRunStage: Int, CaseIterable {
  case prepare
  case write
  case verify

  var titleKey: String {
    switch self {
    case .prepare: "flash.workspace.stage.prepare"
    case .write: "flash.workspace.stage.write"
    case .verify: "flash.workspace.stage.verify"
    }
  }
}

private struct FlashPlanStageSummary: Identifiable {
  let id: Int
  let titleKey: String
  let stepCount: Int
  let highestEffect: FlashPlanEffect?
}

enum FlashWorkspaceMode: String, CaseIterable, Hashable {
  case execute
  case planOnly
  case simulated

  var executionMode: RockchipFlashExecutionMode {
    switch self {
    case .execute: .execute
    case .planOnly: .planOnly
    case .simulated: .simulated
    }
  }
}

/// Flash execution workspace.
///
/// The App can read Runtime availability and target facts, and it can ask the
/// bundled provider to materialize an exact plan from a user-selected archive.
/// Runtime owns destructive admission; the UI only submits the reviewed typed
/// request and never carries or administers a capability.
struct FlashWorkspaceView: View {
  @ObservedObject var model: FlashWorkspaceViewModel
  let runtimeHistory: RuntimeHistoryPresentation
  let isRuntimeHistoryRefreshing: Bool
  let onRefreshRuntimeHistory: () -> Void
  let onOpenHistory: () -> Void
  @State private var isDetailsExpanded = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        pageLead
        currentDeviceSurface
        primarySurface
        flashDetails
      }
      .frame(maxWidth: 760, alignment: .topLeading)
      .padding(20)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.refresh()
          onRefreshRuntimeHistory()
        } label: {
          Label(flashText("flash.action.refresh"), systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .help(flashText("flash.action.refresh"))
        .accessibilityLabel(flashText("flash.action.refresh"))
        .accessibilityIdentifier("flash.refresh")
        .disabled(model.isRefreshing || model.isPreparingPlan || isRuntimeHistoryRefreshing)
      }
    }
    .task(id: model.isSubmitting) {
      guard model.isSubmitting else {
        if model.submission != nil || model.submissionFailure != nil {
          onRefreshRuntimeHistory()
        }
        return
      }
      while !Task.isCancelled && model.isSubmitting {
        onRefreshRuntimeHistory()
        try? await Task.sleep(for: .milliseconds(750))
      }
    }
    .task(id: progressPollingJobID) {
      guard let jobID = progressPollingJobID else { return }
      while !Task.isCancelled {
        let reachedTerminal = await model.refreshLiveStatus(jobID: jobID)
        if reachedTerminal {
          onRefreshRuntimeHistory()
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private var pageLead: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(flashText("flash.workspace.title"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("flash.workspace.title")
      Text(flashText("flash.workspace.subtitle"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var currentDeviceSurface: some View {
    FlashWorkspaceSurface {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          currentDeviceIdentity
          Spacer(minLength: 16)
          readinessLabel
        }
        VStack(alignment: .leading, spacing: 10) {
          currentDeviceIdentity
          readinessLabel
        }
      }
    }
  }

  private var currentDeviceIdentity: some View {
    HStack(spacing: 10) {
      Image(systemName: model.selectedTarget == nil ? "externaldrive.badge.questionmark" : "externaldrive.fill")
        .font(.title3)
        .foregroundStyle(readinessColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          model.selectedTarget == nil
            ? flashText("flash.workspace.device.none")
            : model.profileReference.uppercased()
        )
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        if let target = model.selectedTarget {
          Text(
            String(
              format: flashText("flash.workspace.device.detail"),
              target.id, target.bindingRevision)
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(target.id)
        } else {
          Text(flashText("flash.target.guidance"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .accessibilityIdentifier("flash.workspace.currentDevice")
  }

  private var readinessLabel: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Label(flashText(readinessTitleKey), systemImage: readinessSymbol)
        .font(.callout.weight(.semibold))
        .foregroundStyle(readinessColor)
        .accessibilityIdentifier("flash.workspace.readiness")
      Text(readinessDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var readinessTitleKey: String {
    switch model.workspace.availability {
    case .checking: return "flash.workspace.readiness.checking"
    case .unavailable: return "flash.workspace.readiness.blocked"
    case .available:
      if model.selectedTarget == nil { return "flash.workspace.readiness.noDevice" }
      if model.isPreparingPlan { return "flash.workspace.readiness.checking" }
      if model.planFailureCode != nil { return "flash.workspace.readiness.blocked" }
      if let plan = model.plan,
        !plan.blockingRequiredPrerequisites.isEmpty,
        !model.willActivateCurrentTargetOnSubmit
      {
        return "flash.workspace.readiness.blocked"
      }
      return model.plan == nil
        ? "flash.workspace.readiness.selected"
        : "flash.workspace.readiness.ready"
    }
  }

  private var readinessSymbol: String {
    switch readinessTitleKey {
    case "flash.workspace.readiness.ready": "checkmark.circle.fill"
    case "flash.workspace.readiness.blocked", "flash.workspace.readiness.noDevice":
      "exclamationmark.triangle.fill"
    case "flash.workspace.readiness.checking": "arrow.triangle.2.circlepath"
    default: "checkmark.circle"
    }
  }

  private var readinessColor: Color {
    switch readinessTitleKey {
    case "flash.workspace.readiness.ready": .green
    case "flash.workspace.readiness.blocked", "flash.workspace.readiness.noDevice": .orange
    case "flash.workspace.readiness.checking": .blue
    default: .secondary
    }
  }

  private var readinessDetail: String {
    if case .unavailable(let reasons) = model.workspace.availability {
      return reasons.first ?? flashText("flash.availability.unavailable")
    }
    if model.selectedTarget == nil {
      return flashText("flash.workspace.readiness.noDeviceDetail")
    }
    if model.isPreparingPlan {
      return flashText("flash.workspace.readiness.checkingDetail")
    }
    if model.planFailureCode != nil {
      return flashText("flash.workspace.readiness.planFailedDetail")
    }
    if let plan = model.plan {
      let blockers = plan.blockingRequiredPrerequisites.count
      if blockers > 0 && !model.willActivateCurrentTargetOnSubmit {
        return String(
          format: flashText("flash.workspace.readiness.blockerCount"), blockers)
      }
      let satisfied = plan.prerequisites.filter {
        $0.requirement == .required && $0.status == .satisfied
      }.count
      return String(
        format: flashText("flash.workspace.readiness.checkCount"), satisfied)
    }
    return flashText("flash.workspace.readiness.chooseImage")
  }

  @ViewBuilder
  private var primarySurface: some View {
    if let job = attentionFlashJob {
      recoveryBlockerSurface(job)
    } else if model.isSubmitting || activeFlashJob != nil {
      executionProgressSurface
    } else if model.submission != nil || model.submissionFailure != nil {
      executionResultSurface
    } else {
      imageAndActionSurface
    }
  }

  private var imageAndActionSurface: some View {
    FlashWorkspaceSurface {
      VStack(alignment: .leading, spacing: 16) {
        imagePickerRow

        if model.isPreparingPlan {
          Divider()
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(flashText("flash.workspace.image.validating"))
              .font(.callout)
          }
          .accessibilityIdentifier("flash.plan.preparing")
        } else if let errorCode = model.planFailureCode {
          Divider()
          Label(flashText(planFailureKey(errorCode)), systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.plan.error")
          if let detail = model.planFailureDetail {
            Text(detail)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          Button(flashText("flash.workspace.image.retry")) { model.preparePlan() }
            .accessibilityIdentifier("flash.plan.retry")
        } else if let plan = model.plan {
          Divider()
          flashAction(plan)
        }
      }
      .accessibilityIdentifier("flash.workspace.imageAction")
    }
  }

  private var imagePickerRow: some View {
    HStack(spacing: 14) {
      Image(systemName: model.selectedArchiveURL == nil ? "shippingbox" : "shippingbox.fill")
        .font(.title2)
        .foregroundStyle(
          model.selectedArchiveURL == nil ? Color.secondary : Color.accentColor)
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(
          model.selectedArchiveURL?.lastPathComponent
            ?? flashText("flash.workspace.image.chooseTitle")
        )
        .font(.callout.weight(.semibold))
        .lineLimit(2)
        .truncationMode(.middle)
        .accessibilityIdentifier("flash.image.value")
        if let plan = model.plan {
          Text(
            "\(ByteCountFormatter.string(fromByteCount: plan.archiveSizeBytes, countStyle: .file)) · \(plan.runtimeBuildVersion)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text(flashText("flash.workspace.image.chooseHelp"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      if model.selectedArchiveURL == nil {
        Button(flashText("flash.workspace.image.choose")) {
          if let url = FlashImageArchiveOpenPanel.choose() {
            model.selectArchive(url)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isPreparingPlan)
        .accessibilityIdentifier("flash.image.choose")
      } else {
        Button(flashText("flash.workspace.image.change")) {
          if let url = FlashImageArchiveOpenPanel.choose() {
            model.selectArchive(url)
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.isPreparingPlan)
        .accessibilityIdentifier("flash.image.choose")
      }
    }
    .padding(16)
    .background(
      Color(nsColor: .windowBackgroundColor).opacity(0.55),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          Color(nsColor: .separatorColor),
          style: StrokeStyle(
            lineWidth: 1,
            dash: model.selectedArchiveURL == nil ? [5, 4] : [])
        )
    }
  }

  private func flashAction(_ plan: FlashExactPlanPresentation) -> some View {
    let impact =
      plan.dataImpact.first {
        if case .userDataDestroyed = $0 { return true }
        return false
      } ?? .mappedPartitionsOverwritten(count: plan.mappedPartitionCount)
    return VStack(alignment: .leading, spacing: 12) {
      Label(mainImpactText(plan), systemImage: "externaldrive.badge.exclamationmark")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(dataImpactIdentifier(impact))
      Label(flashText("flash.workspace.action.power"), systemImage: "bolt.fill")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text(flashText("flash.workspace.action.authority"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if model.canSubmit {
        HStack {
          Spacer(minLength: 0)
          Button {
            model.submit()
          } label: {
            Text(flashText("flash.workspace.action.submit"))
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .controlSize(.large)
          .accessibilityIdentifier("flash.execute.submit")
        }
      } else {
        Label(flashBlockerText(plan), systemImage: "exclamationmark.triangle.fill")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("flash.execute.prerequisiteBlocker")
      }
    }
  }

  private func mainImpactText(_ plan: FlashExactPlanPresentation) -> String {
    let target = plan.target?.id ?? model.profileReference.uppercased()
    if plan.dataImpact.contains(where: {
      if case .userDataDestroyed = $0 { return true }
      return false
    }) {
      return String(format: flashText("flash.workspace.action.impact"), target)
    }
    return String(
      format: flashText("flash.impact.partitions"),
      plan.mappedPartitionCount)
  }

  private func dataImpactIdentifier(_ impact: FlashDataImpactPresentation) -> String {
    switch impact {
    case .mappedPartitionsOverwritten:
      return "flash.impact.partitions"
    case .userDataDestroyed:
      return "flash.impact.userdata"
    case .forbiddenAreasPreserved:
      return "flash.impact.preserved"
    }
  }

  private func flashBlockerText(_ plan: FlashExactPlanPresentation) -> String {
    if !plan.blockingRequiredPrerequisites.isEmpty {
      return String(
        format: flashText("flash.workspace.action.blocked"),
        plan.blockingRequiredPrerequisites.count)
    }
    return flashText("flash.execute.planRequired")
  }

  private var activeFlashJob: RuntimeJobSummaryPresentation? {
    runtimeHistory.jobs.first { job in
      job.operationReference == "flash.dayu200"
        && job.isCurrentActivity
    }
  }

  private var progressPollingJobID: String? {
    model.activeJobID ?? activeFlashJob?.id
  }

  private var currentFlashStatus: FlashSubmissionPresentation? {
    if let status = model.liveStatus,
      status.jobID == progressPollingJobID
    {
      return status
    }
    guard let job = activeFlashJob else { return nil }
    return FlashSubmissionPresentation(
      jobID: job.id, state: job.state,
      outcomeUnknown: job.outcomeUnknown, timeline: job.timeline)
  }

  private var liveProgress: FlashLiveProgressPresentation {
    FlashLiveProgressProjector.project(
      status: currentFlashStatus,
      partitions: model.plan?.partitions ?? [])
  }

  private var attentionFlashJob: RuntimeJobSummaryPresentation? {
    runtimeHistory.jobs.first {
      $0.operationReference == "flash.dayu200" && $0.requiresRecoveryGuidance
    }
  }

  private func recoveryBlockerSurface(
    _ job: RuntimeJobSummaryPresentation
  ) -> some View {
    FlashWorkspaceSurface {
      VStack(alignment: .leading, spacing: 12) {
        Label(
          flashText("flash.runtime.recoveryTitle"),
          systemImage: "exclamationmark.shield.fill"
        )
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityIdentifier("flash.runtime.attention")
        Text(
          flashText(
            job.outcomeUnknown
              ? "flash.runtime.outcomeUnknownGuidance"
              : "flash.runtime.waitingForHumanGuidance")
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        LabeledContent(flashText("flash.runtime.job")) {
          Text(job.id).font(.callout.monospaced())
        }
        Button(flashText("flash.runtime.openRecord"), action: onOpenHistory)
          .accessibilityIdentifier("flash.runtime.openHistory")
      }
    }
  }

  private var currentRunStage: FlashWorkspaceRunStage {
    switch liveProgress.phase {
    case .writingPartition:
      return .write
    case .verifyingPartitions, .rebootingDevice, .reconnectingDevice, .verifyingSystem:
      return .verify
    case .importingImage, .validatingImage, .enteringBootloader, .extractingImage:
      return .prepare
    }
  }

  private var executionProgressSurface: some View {
    FlashWorkspaceSurface {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text(progressTitle)
              .font(.title3.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
              .accessibilityIdentifier("flash.workspace.progress")
            Text(flashText("flash.workspace.progress.keepConnected"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          if let percent = liveProgress.writePercentCompleted {
            Text("\(percent)%")
              .font(.title3.monospacedDigit().weight(.semibold))
              .foregroundStyle(Color.accentColor)
              .accessibilityIdentifier("flash.runtime.progress.percent")
          } else {
            Label(
              flashText("flash.workspace.progress.running"),
              systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          }
        }

        if let fraction = liveProgress.writeFractionCompleted {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .accessibilityLabel(progressTitle)
            .accessibilityValue("\(liveProgress.writePercentCompleted ?? 0)%")
            .accessibilityIdentifier("flash.runtime.progress")
        } else {
          ProgressView()
            .progressViewStyle(.linear)
            .accessibilityLabel(progressTitle)
            .accessibilityIdentifier("flash.runtime.progress")
        }
        Text(progressDetail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("flash.runtime.progress.detail")

        flashStageTrack

        if isCurrentStepCritical {
          Label(
            flashText("flash.runtime.criticalWrite"),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityIdentifier("flash.runtime.criticalWrite")
        }

        if model.activeJobID != nil {
          Button(flashText("flash.action.cancel"), role: .cancel) {
            model.cancelActiveJob()
          }
          .disabled(model.isCancelling)
          .accessibilityIdentifier("flash.execute.cancel")
          Text(flashText("flash.action.cancel.help"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var flashStageTrack: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(FlashWorkspaceRunStage.allCases, id: \.rawValue) { stage in
        VStack(spacing: 6) {
          Image(
            systemName: stage.rawValue < currentRunStage.rawValue
              ? "checkmark.circle.fill"
              : stage == currentRunStage
                ? "circle.inset.filled"
                : "circle"
          )
          .foregroundStyle(
            stage.rawValue <= currentRunStage.rawValue
              ? Color.accentColor
              : Color.secondary)
          Text(flashText(stage.titleKey))
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(stage == currentRunStage ? .primary : .secondary)
            .frame(maxWidth: .infinity)
        }
        if stage != .verify {
          Divider()
            .frame(maxWidth: 60)
            .padding(.top, 8)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.workspace.progress.stages")
  }

  private var isCurrentStepCritical: Bool {
    liveProgress.phase == .writingPartition
  }

  private var progressTitle: String {
    switch liveProgress.phase {
    case .importingImage:
      return flashText("flash.workspace.progress.importing")
    case .validatingImage:
      return flashText("flash.workspace.progress.validating")
    case .enteringBootloader:
      return flashText("flash.workspace.progress.bootloader")
    case .extractingImage:
      return flashText("flash.workspace.progress.extracting")
    case .writingPartition:
      return String(
        format: flashText("flash.workspace.progress.partition"),
        liveProgress.partitionName ?? flashText("flash.workspace.progress.partitionUnknown"))
    case .verifyingPartitions:
      return flashText("flash.workspace.progress.verifyingPartitions")
    case .rebootingDevice:
      return flashText("flash.workspace.progress.rebooting")
    case .reconnectingDevice:
      return flashText("flash.workspace.progress.reconnecting")
    case .verifyingSystem:
      return flashText("flash.workspace.progress.verifyingSystem")
    }
  }

  private var progressDetail: String {
    if liveProgress.phase == .writingPartition,
      let completed = liveProgress.completedPartitionCount,
      let total = liveProgress.totalPartitionCount,
      let partitionPercent = liveProgress.currentPartitionPercent,
      let writePercent = liveProgress.writePercentCompleted
    {
      return String(
        format: flashText("flash.workspace.progress.partitionDetail"),
        completed, total, partitionPercent, writePercent)
    }
    return flashText("flash.workspace.progress.indeterminate")
  }

  private var executionResultSurface: some View {
    let succeeded = model.hasVerifiedPostflight
    return FlashWorkspaceSurface {
      HStack(alignment: .top, spacing: 15) {
        Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(succeeded ? .green : .orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 10) {
          Text(
            flashText(
              succeeded
                ? "flash.workspace.result.success"
                : "flash.workspace.result.stopped")
          )
          .font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("flash.execute.terminal")
          Text(resultDescription(succeeded: succeeded))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if let plan = model.plan, let evidence = model.postflightEvidence {
            flashPostflight(plan: plan, evidence: evidence)
          }
          HStack(spacing: 10) {
            Button(flashText("flash.workspace.result.again")) {
              model.resetForAnotherFlash()
            }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("flash.workspace.result.again")
            Button(flashText("flash.workspace.result.history"), action: onOpenHistory)
              .accessibilityIdentifier("flash.runtime.openHistory")
          }
        }
      }
    }
    .accessibilityIdentifier("flash.workspace.result")
  }

  private func resultDescription(succeeded: Bool) -> String {
    if succeeded { return flashText("flash.workspace.result.successDetail") }
    if let failure = model.submissionFailure { return failure }
    if let submission = model.submission {
      return String(
        format: flashText("flash.workspace.result.state"), submission.state)
    }
    return flashText("flash.workspace.result.unverified")
  }

  private var flashDetails: some View {
    DisclosureGroup(isExpanded: $isDetailsExpanded) {
      VStack(alignment: .leading, spacing: 18) {
        availabilitySection
        deviceAccessSection
        detailsInputs
        if let plan = model.plan {
          exactPlanDetails(plan)
        }
        FlashRuntimeActivityView(
          presentation: runtimeHistory,
          plan: model.plan,
          onOpenHistory: onOpenHistory)
      }
      .padding(.top, 12)
    } label: {
      Text(flashText("flash.workspace.details"))
        .font(.callout.weight(.semibold))
    }
    .accessibilityIdentifier("flash.workspace.details")
  }

  private var detailsInputs: some View {
    GroupBox(flashText("flash.workspace.details.configuration")) {
      VStack(alignment: .leading, spacing: 14) {
        Picker(flashText("flash.profile.label"), selection: profileBinding) {
          ForEach(FlashApplicationFacade.profileReferences, id: \.self) { reference in
            Text(reference).tag(reference)
          }
        }
        .accessibilityIdentifier("flash.profile")
        .disabled(model.isPreparingPlan || model.isSubmitting)
        targetContent
        Divider()
        Text(flashText("flash.plan.prerequisites"))
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        prerequisitesContent
          .accessibilityIdentifier("flash.plan.prerequisitesSection")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private func exactPlanDetails(_ plan: FlashExactPlanPresentation) -> some View {
    GroupBox(flashText("flash.plan.title")) {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          String(
            format: flashText("flash.workspace.plan.summary"),
            plan.steps.count,
            flashText(effectKey(highestEffect(in: plan.steps) ?? .hostOnly)))
        )
        .font(.callout.weight(.semibold))
        planStageSummary(plan)
        Divider()
        planSummary(plan)
        Divider()
        FlashPlanDetailsView(plan: plan)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
    .accessibilityIdentifier("flash.plan.steps")
  }

  private func planStageSummary(_ plan: FlashExactPlanPresentation) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
      GridRow {
        Text(flashText("flash.workspace.plan.stage"))
          .accessibilityIdentifier("flash.workspace.plan.stages")
        Text(flashText("flash.workspace.plan.steps"))
        Text(flashText("flash.workspace.plan.effect"))
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.bottom, 6)
      Divider().gridCellColumns(3)
      ForEach(planStageSummaries(plan.steps)) { stage in
        GridRow(alignment: .firstTextBaseline) {
          Text(flashText(stage.titleKey))
            .fixedSize(horizontal: false, vertical: true)
          Text(stage.stepCount, format: .number)
            .monospacedDigit()
          if let effect = stage.highestEffect {
            effectLabel(effect)
          } else {
            Text("—").foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 7)
        if stage.id < 3 { Divider().gridCellColumns(3) }
      }
    }
  }

  private func planStageSummaries(
    _ steps: [FlashPlanStepPresentation]
  ) -> [FlashPlanStageSummary] {
    let firstMutation = steps.firstIndex { $0.effect == .deviceMutation }
    let firstWrite = steps.firstIndex { $0.effect == .destructive }
    let lastWrite = steps.lastIndex { $0.effect == .destructive }
    var buckets = Array(repeating: [FlashPlanStepPresentation](), count: 4)

    for (index, step) in steps.enumerated() {
      if index < (firstMutation ?? firstWrite ?? steps.count) {
        buckets[0].append(step)
      } else if index < (firstWrite ?? steps.count) {
        buckets[1].append(step)
      } else if index <= (lastWrite ?? -1) {
        buckets[2].append(step)
      } else {
        buckets[3].append(step)
      }
    }

    let keys = [
      "flash.workspace.plan.prepare",
      "flash.workspace.plan.loader",
      "flash.workspace.plan.write",
      "flash.workspace.plan.verify",
    ]
    return buckets.enumerated().map { index, bucket in
      FlashPlanStageSummary(
        id: index,
        titleKey: keys[index],
        stepCount: bucket.count,
        highestEffect: highestEffect(in: bucket))
    }
  }

  private func highestEffect(
    in steps: [FlashPlanStepPresentation]
  ) -> FlashPlanEffect? {
    steps.map(\.effect).max { effectRank($0) < effectRank($1) }
  }

  private func effectRank(_ effect: FlashPlanEffect) -> Int {
    switch effect {
    case .hostOnly: 0
    case .readOnly: 1
    case .deviceMutation: 2
    case .destructive: 3
    }
  }

  private func effectKey(_ effect: FlashPlanEffect) -> String {
    switch effect {
    case .hostOnly: "flash.effect.hostOnly"
    case .readOnly: "flash.effect.readOnly"
    case .deviceMutation: "flash.effect.deviceMutation"
    case .destructive: "flash.effect.destructive"
    }
  }

  private var availabilitySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      flashSectionHeader(flashText("flash.availability.title"))
      switch model.workspace.availability {
      case .checking:
        Label(flashText("flash.availability.checking"), systemImage: "hourglass")
          .accessibilityIdentifier("flash.availability.status")
      case .available:
        Label(flashText("flash.availability.available"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityIdentifier("flash.availability.status")
      case .unavailable(let reasons):
        Label(flashText("flash.availability.unavailable"), systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
          .accessibilityIdentifier("flash.availability.status")
        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
          Text(reason)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(flashText("flash.availability.scope"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func flashSectionHeader(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Divider()
    }
  }

  private var deviceAccessSection: some View {
    GroupBox(flashText("flash.deviceAccess.title")) {
      VStack(alignment: .leading, spacing: 10) {
        switch model.deviceAccess.availability {
        case .checking:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(flashText("flash.deviceAccess.checking"))
          }
        case .unavailable(let reason):
          Label(
            flashText("flash.deviceAccess.toolUnavailable"),
            systemImage: "wrench.and.screwdriver.fill"
          )
          .foregroundStyle(.orange)
          Text(reason)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        case .available:
          if let advice = model.deviceAccess.advice {
            Label(
              flashText(deviceAccessVerdictKey(advice.verdict)),
              systemImage: deviceAccessSymbol(advice.verdict)
            )
            .foregroundStyle(deviceAccessColor(advice.verdict))
            .font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
              GridRow {
                Text(flashText("flash.deviceAccess.responsibility"))
                  .foregroundStyle(.secondary)
                Text(flashText(deviceAccessResponsibilityKey(advice.responsibility)))
              }
              GridRow {
                Text(flashText("flash.deviceAccess.nextStep"))
                  .foregroundStyle(.secondary)
                Text(flashText(deviceAccessRemediationKey(advice.remediation)))
                  .fixedSize(horizontal: false, vertical: true)
              }
              if model.deviceAccess.observationCount > 0 {
                GridRow {
                  Text(flashText("flash.deviceAccess.observations"))
                    .foregroundStyle(.secondary)
                  Text(
                    String(
                      format: flashText("flash.deviceAccess.observationValue"),
                      model.deviceAccess.observationCount,
                      model.deviceAccess.observedModes.map(\.rawValue).joined(separator: ", "))
                  )
                }
              }
            }
          }
        }
        if model.deviceAccess.advice?.reprobeAvailable == true {
          Button(flashText("flash.deviceAccess.reprobe")) {
            model.refreshDeviceAccess()
          }
          .disabled(model.isRefreshingDeviceAccess)
          .accessibilityIdentifier("flash.deviceAccess.reprobe")
        }
        if model.workspace.bootloaderStatus.disposition == .unbound
          || model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared,
          model.workspace.bootloaderStatus.mode == "loader"
        {
          Divider()
          Label(
            flashText("flash.bootloader.unbound.title"),
            systemImage: "externaldrive.badge.questionmark"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          Text(
            flashText(
              model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared
                ? "flash.bootloader.unprepared.detail"
                : "flash.bootloader.unbound.detail")
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else if model.workspace.bootloaderStatus.disposition == .exactBoundTarget,
          model.workspace.bootloaderStatus.mode == "loader"
        {
          Label(
            flashText("flash.bootloader.bound"),
            systemImage: "checkmark.seal.fill"
          )
          .foregroundStyle(.green)
          .accessibilityIdentifier("flash.bootloader.bound")
        } else if model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared,
          model.workspace.bootloaderStatus.mode == "hdcNormal"
        {
          Label(
            flashText("flash.binding.unprepared.hdc.title"),
            systemImage: "externaldrive.badge.questionmark"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          Text(flashText("flash.binding.unprepared.hdc.detail"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
    .accessibilityIdentifier("flash.deviceAccess")
  }

  private func deviceAccessVerdictKey(_ verdict: RockchipDeviceAccessVerdict) -> String {
    switch verdict {
    case .accessible: "flash.deviceAccess.verdict.accessible"
    case .offlineOrUnauthorized: "flash.deviceAccess.verdict.offline"
    case .permissionDenied: "flash.deviceAccess.verdict.permissionDenied"
    case .driverUnavailable: "flash.deviceAccess.verdict.driverUnavailable"
    case .protocolBlocked: "flash.deviceAccess.verdict.protocolBlocked"
    case .malformedOutput: "flash.deviceAccess.verdict.malformedOutput"
    case .toolBlocked: "flash.deviceAccess.verdict.toolBlocked"
    case .probeFailed: "flash.deviceAccess.verdict.probeFailed"
    }
  }

  private func deviceAccessResponsibilityKey(
    _ responsibility: RockchipDeviceAccessResponsibility
  ) -> String {
    "flash.deviceAccess.responsibility.\(responsibility.rawValue)"
  }

  private func deviceAccessRemediationKey(
    _ remediation: RockchipDeviceAccessRemediation
  ) -> String {
    "flash.deviceAccess.remediation.\(remediation.rawValue)"
  }

  private func deviceAccessSymbol(_ verdict: RockchipDeviceAccessVerdict) -> String {
    switch verdict {
    case .accessible: "checkmark.circle.fill"
    case .offlineOrUnauthorized: "cable.connector.slash"
    case .permissionDenied: "lock.trianglebadge.exclamationmark"
    case .driverUnavailable: "wrench.and.screwdriver.fill"
    case .protocolBlocked, .malformedOutput, .toolBlocked, .probeFailed:
      "exclamationmark.triangle.fill"
    }
  }

  private func deviceAccessColor(_ verdict: RockchipDeviceAccessVerdict) -> Color {
    switch verdict {
    case .accessible: .green
    case .permissionDenied, .driverUnavailable: .red
    case .offlineOrUnauthorized, .protocolBlocked, .malformedOutput, .toolBlocked, .probeFailed:
      .orange
    }
  }

  private var profileBinding: Binding<String> {
    Binding(get: { model.profileReference }, set: { model.setProfileReference($0) })
  }

  private var targetContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.workspace.targets.isEmpty {
        Label(flashText("flash.target.none"), systemImage: "externaldrive.badge.questionmark")
          .accessibilityIdentifier("flash.target.empty")
        if let failure = model.workspace.targetLoadFailure {
          Text(failure)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(flashText("flash.target.guidance"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Picker(flashText("flash.target.label"), selection: targetBinding) {
          ForEach(model.workspace.targets) { target in
            Text(target.id).tag(target.id)
          }
        }
        .accessibilityIdentifier("flash.target")
        .disabled(model.isPreparingPlan)
        if let target = model.selectedTarget {
          LabeledContent(flashText("flash.target.binding")) {
            Text(target.bindingRevision, format: .number)
              .monospacedDigit()
              .accessibilityIdentifier("flash.target.binding")
          }
          LabeledContent(flashText("flash.target.toolVersion")) {
            Text(target.toolVersion)
              .font(.body.monospaced())
              .accessibilityIdentifier("flash.target.toolVersion")
          }
        }
      }
    }
  }

  private var targetBinding: Binding<String> {
    Binding(get: { model.selectedTargetID }, set: { model.setTargetID($0) })
  }

  private var prerequisitesContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let plan = model.plan {
        Text(flashText("flash.plan.prerequisitesNote"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        FlashPrerequisitesList(prerequisites: plan.prerequisites)
      } else {
        Text(flashText("flash.plan.prerequisitesAwaitPlan"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func planSummary(_ plan: FlashExactPlanPresentation) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
      summaryRow("flash.plan.build", plan.runtimeBuildVersion)
      summaryRow(
        "flash.plan.size",
        ByteCountFormatter.string(fromByteCount: plan.archiveSizeBytes, countStyle: .file))
      summaryRow("flash.plan.archiveHash", plan.archiveSHA256, monospaced: true)
      summaryRow("flash.plan.digest", plan.planDigestSHA256, monospaced: true)
      summaryRow("flash.plan.stepSetDigest", plan.stepSetDigestSHA256, monospaced: true)
      summaryRow("flash.plan.toolchain", plan.toolchainFingerprint, monospaced: true)
    }
  }

  private func summaryRow(
    _ key: String, _ value: String, monospaced: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(flashText(key)).foregroundStyle(.secondary)
      Text(value)
        .font(monospaced ? .body.monospaced() : .body)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(value)
        .accessibilityLabel(value)
        .textSelection(.enabled)
    }
  }

  private func effectLabel(_ effect: FlashPlanEffect) -> some View {
    let key: String
    let symbol: String
    let color: Color
    switch effect {
    case .hostOnly:
      key = "flash.effect.hostOnly"
      symbol = "desktopcomputer"
      color = .secondary
    case .readOnly:
      key = "flash.effect.readOnly"
      symbol = "eye"
      color = .blue
    case .deviceMutation:
      key = "flash.effect.deviceMutation"
      symbol = "arrow.triangle.2.circlepath"
      color = .orange
    case .destructive:
      key = "flash.effect.destructive"
      symbol = "exclamationmark.triangle.fill"
      color = .red
    }
    return Label(flashText(key), systemImage: symbol)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color)
      .lineLimit(2)
  }

  private func flashPostflight(
    plan: FlashExactPlanPresentation,
    evidence: RuntimeJobEvidencePresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(flashText("flash.postflight.title"))
        .font(.subheadline.weight(.semibold))
      if let observedFirmware = evidence.observedFirmware {
        postflightRow(
          label: flashText("flash.postflight.build"),
          expected: plan.runtimeBuildVersion,
          observed: observedFirmware,
          matches: observedFirmware == plan.runtimeBuildVersion,
          identifier: "flash.postflight.build")
      }
      if let before = plan.target?.bindingRevision,
        let after = evidence.observedBindingRevision
      {
        let binding = FlashPostflightPresentationBuilder.binding(
          plannedRevision: before,
          observedRevision: after)
        postflightRow(
          label: flashText("flash.postflight.binding"),
          expected: binding.expected,
          observed: binding.observed,
          matches: binding.matches,
          identifier: "flash.postflight.binding")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.postflight")
  }

  private func postflightRow(
    label: String,
    expected: String,
    observed: String,
    matches: Bool,
    identifier: String
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: matches ? "checkmark.circle.fill" : "xmark.octagon.fill")
        .foregroundStyle(matches ? .green : .red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.callout.weight(.semibold))
        Text(
          String(
            format: flashText("flash.postflight.comparison"),
            expected, observed)
        )
        .font(.caption.monospaced())
        .textSelection(.enabled)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      String(
        format: flashText(
          matches ? "flash.postflight.match" : "flash.postflight.mismatch"),
        label, expected, observed)
    )
    .accessibilityIdentifier("\(identifier).\(matches ? "match" : "mismatch")")
  }

  private func planFailureKey(_ code: FlashPlanFailureCode) -> String {
    switch code {
    case .fileAccessDenied: "flash.error.fileAccess"
    case .unsupportedArchiveFormat: "flash.error.format"
    case .unreadableArchive: "flash.error.unreadable"
    case .invalidArchive: "flash.error.invalid"
    case .unsupportedBundle: "flash.error.unsupported"
    case .planMaterializationFailed: "flash.error.plan"
    }
  }
}

@MainActor
final class FlashWorkspaceViewModel: ObservableObject {
  @Published private(set) var workspace = FlashWorkspacePresentation.loading
  @Published private(set) var mode = FlashWorkspaceMode.execute
  @Published private(set) var selectedTargetID = ""
  @Published private(set) var selectedArchiveURL: URL?
  @Published private(set) var plan: FlashExactPlanPresentation?
  @Published private(set) var planFailureCode: FlashPlanFailureCode?
  @Published private(set) var planFailureDetail: String?
  @Published private(set) var submission: FlashSubmissionPresentation?
  @Published private(set) var liveStatus: FlashSubmissionPresentation?
  @Published private(set) var submissionFailure: String?
  @Published private(set) var postflightEvidence: RuntimeJobEvidencePresentation?
  @Published private(set) var deviceAccess = RockchipDeviceAccessPresentation.loading
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPreparingPlan = false
  @Published private(set) var isSubmitting = false
  @Published private(set) var isCancelling = false
  @Published private(set) var activeJobID: String?
  @Published private(set) var isRefreshingDeviceAccess = false
  @Published private(set) var profileReference =
    FlashApplicationFacade.profileReferences.last ?? "dayu200"

  private let provider: any FlashApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding
  private let deviceAccessProvider: any RockchipDeviceAccessApplicationProviding
  private let preparesUITestPlan: Bool
  /// The UI-test state file, honored only when the launch already carries the
  /// Flash fixture arguments: it lets one launched sweep walk the empty
  /// workspace first and enter the exact-plan flow later, without a relaunch.
  /// A production launch has no state URL and never reads one.
  private let uiTestFixtureStateURL: URL?
  private var didPrepareUITestPlan = false
  private var shouldRegeneratePlanWhenReady = false

  init(
    provider: any FlashApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil,
    deviceAccessProvider: (any RockchipDeviceAccessApplicationProviding)? = nil,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    self.provider = provider
    self.detailProvider =
      detailProvider
      ?? RuntimeJobDetailApplicationFacade.make(arguments: arguments)
    self.deviceAccessProvider =
      deviceAccessProvider
      ?? RockchipDeviceAccessApplicationFacade.make(arguments: arguments)
    preparesUITestPlan = arguments.contains("--ui-test-flash-plan")
    if arguments.contains("--ui-test-flash") || preparesUITestPlan,
      let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      uiTestFixtureStateURL = URL(fileURLWithPath: arguments[index + 1])
    } else {
      uiTestFixtureStateURL = nil
    }
    if preparesUITestPlan {
      mode = .execute
      selectedArchiveURL = URL(fileURLWithPath: "/ui-fixture/dayu200-images.tar.gz")
    }
  }

  private var uiTestFixtureStateRequestsPlan: Bool {
    guard let uiTestFixtureStateURL,
      let text = try? String(contentsOf: uiTestFixtureStateURL, encoding: .utf8)
    else { return false }
    return text.contains("--ui-test-flash-plan")
  }

  var selectedTarget: FlashTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var canPreparePlan: Bool {
    selectedArchiveURL != nil
      && (mode == .simulated || selectedTarget != nil)
      && !isPreparingPlan
  }

  var canSubmit: Bool {
    guard mode == .execute, !isSubmitting,
      let archive = selectedArchiveURL,
      let plan
    else { return false }
    return !archive.path.isEmpty
      && plan.target == selectedTarget
      && plan.mode == .execute
      && (plan.blockingRequiredPrerequisites.isEmpty || willActivateCurrentTargetOnSubmit)
  }

  var hasVerifiedPostflight: Bool {
    guard let submission,
      submission.state == "succeeded" || submission.state == "recovered",
      let plan,
      let evidence = postflightEvidence,
      let plannedBindingRevision = plan.target?.bindingRevision,
      evidence.observedFirmware == plan.runtimeBuildVersion,
      evidence.observedBindingRevision == plannedBindingRevision
    else { return false }
    return true
  }

  var willActivateCurrentTargetOnSubmit: Bool {
    guard mode == .execute, let selectedTarget else { return false }
    let status = workspace.bootloaderStatus
    guard status.observationCount == 1,
      status.mode == "loader" || status.mode == "hdcNormal"
    else { return false }
    switch status.disposition {
    case .unbound:
      return status.mode == "loader"
    case .targetBindingUnprepared:
      return status.targetID == selectedTarget.id
        && status.bindingRevision == selectedTarget.bindingRevision
    case .absent, .ambiguous, .exactBoundTarget:
      return false
    }
  }

  func refresh() {
    refreshDeviceAccess()
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshWorkspace()
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      let previousTarget = self.selectedTarget
      let nextSelectedTargetID =
        next.targets.contains(where: { $0.id == self.selectedTargetID })
        ? self.selectedTargetID
        : next.targets.first?.id ?? ""
      let nextTarget = next.targets.first { $0.id == nextSelectedTargetID }
      self.workspace = next
      self.selectedTargetID = nextSelectedTargetID
      if previousTarget != nextTarget {
        self.invalidatePlan()
      }
      if self.preparesUITestPlan || self.uiTestFixtureStateRequestsPlan,
        !self.didPrepareUITestPlan
      {
        self.didPrepareUITestPlan = true
        if self.selectedArchiveURL == nil {
          self.mode = .execute
          self.selectedArchiveURL = URL(fileURLWithPath: "/ui-fixture/dayu200-images.tar.gz")
        }
      }
      if self.selectedArchiveURL != nil, self.plan == nil {
        self.preparePlan()
      }
    }
  }

  func refreshDeviceAccess() {
    guard !isRefreshingDeviceAccess else { return }
    isRefreshingDeviceAccess = true
    let provider = deviceAccessProvider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self else { return }
      defer { self.isRefreshingDeviceAccess = false }
      guard !Task.isCancelled else { return }
      self.deviceAccess = next
    }
  }

  func setMode(_ mode: FlashWorkspaceMode) {
    guard self.mode != mode else { return }
    self.mode = mode
    invalidatePlan()
    preparePlan()
  }

  func setProfileReference(_ reference: String) {
    guard profileReference != reference else { return }
    profileReference = reference
    invalidatePlan()
    preparePlan()
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    invalidatePlan()
    preparePlan()
  }

  func selectArchive(_ url: URL) {
    guard FlashImageArchiveSelectionPolicy.allows(url) else {
      selectedArchiveURL = nil
      invalidatePlan()
      planFailureCode = .unsupportedArchiveFormat
      planFailureDetail = nil
      return
    }
    selectedArchiveURL = url
    invalidatePlan()
    preparePlan()
  }

  func preparePlan() {
    guard let archiveURL = selectedArchiveURL,
      mode == .simulated || selectedTarget != nil
    else { return }
    if isPreparingPlan {
      shouldRegeneratePlanWhenReady = true
      return
    }
    isPreparingPlan = true
    plan = nil
    submission = nil
    liveStatus = nil
    submissionFailure = nil
    postflightEvidence = nil
    planFailureCode = nil
    planFailureDetail = nil
    let provider = provider
    let profileReference = profileReference
    let mode = mode
    let target = selectedTarget
    Task { [weak self] in
      let result = await provider.preparePlan(
        archiveURL: archiveURL,
        profileReference: profileReference,
        mode: mode.executionMode,
        target: target)
      guard let self else { return }
      defer {
        self.isPreparingPlan = false
        if self.shouldRegeneratePlanWhenReady {
          self.shouldRegeneratePlanWhenReady = false
          self.preparePlan()
        }
      }
      guard
        self.selectedArchiveURL == archiveURL,
        self.profileReference == profileReference,
        self.mode == mode,
        self.selectedTarget == target,
        !Task.isCancelled
      else { return }
      switch result {
      case .ready(let plan):
        self.plan = plan
      case .failed(let code, let detail):
        self.planFailureCode = code
        self.planFailureDetail = detail
      }
    }
  }

  func resetForAnotherFlash() {
    guard !isSubmitting else { return }
    selectedArchiveURL = nil
    mode = .execute
    invalidatePlan()
  }

  func refreshLiveStatus(jobID: String) async -> Bool {
    let result = await provider.status(jobID: jobID)
    guard !Task.isCancelled else { return true }
    guard case .available(let status) = result,
      status.jobID == jobID,
      activeJobID == nil || activeJobID == jobID
    else { return false }
    liveStatus = status
    return status.outcomeUnknown
      || [
        "succeeded", "failed", "cancelled", "recovered", "interrupted",
        "waitingForRecovery", "awaitingRebindConfirmation", "userAbandonRequested",
      ].contains(status.state)
  }

  func submit() {
    guard canSubmit, let archiveURL = selectedArchiveURL, let plan else { return }
    isSubmitting = true
    submission = nil
    liveStatus = nil
    submissionFailure = nil
    postflightEvidence = nil
    let provider = provider
    let detailProvider = detailProvider
    Task { [weak self] in
      guard let self else { return }
      guard self.selectedArchiveURL == archiveURL,
        self.plan == plan,
        !Task.isCancelled
      else {
        self.isSubmitting = false
        return
      }
      var executionPlan = plan
      if self.willActivateCurrentTargetOnSubmit, let selectedTarget = plan.target {
        let bindingResult = await provider.bindCurrentLoader(target: selectedTarget)
        guard self.selectedArchiveURL == archiveURL,
          self.plan == plan,
          self.selectedTarget == selectedTarget,
          !Task.isCancelled
        else {
          self.isSubmitting = false
          return
        }
        guard case .bound(let rebound) = bindingResult else {
          self.isSubmitting = false
          if case .failed(let detail) = bindingResult {
            self.submissionFailure = detail
          }
          return
        }
        self.applyBoundLoader(rebound)
        let refreshed = await provider.preparePlan(
          archiveURL: archiveURL,
          profileReference: plan.profileReference,
          mode: .execute,
          target: rebound)
        guard self.selectedArchiveURL == archiveURL,
          self.selectedTarget == rebound,
          !Task.isCancelled
        else {
          self.isSubmitting = false
          return
        }
        guard case .ready(let reboundPlan) = refreshed else {
          self.isSubmitting = false
          if case .failed(let code, let detail) = refreshed {
            self.planFailureCode = code
            self.planFailureDetail = detail
          }
          return
        }
        self.plan = reboundPlan
        guard reboundPlan.target == rebound,
          reboundPlan.mode == .execute,
          reboundPlan.blockingRequiredPrerequisites.isEmpty
        else {
          self.isSubmitting = false
          self.submissionFailure =
            "Loader was bound, but Runtime prerequisites still block Flash"
          return
        }
        executionPlan = reboundPlan
      }

      let submissionResult = await provider.submit(
        archiveURL: archiveURL, plan: executionPlan)
      guard self.selectedArchiveURL == archiveURL,
        self.plan == executionPlan,
        !Task.isCancelled
      else {
        self.isSubmitting = false
        return
      }
      switch submissionResult {
      case .accepted(let jobID):
        self.activeJobID = jobID
        let runResult = await provider.run(jobID: jobID)
        guard self.selectedArchiveURL == archiveURL,
          self.plan == executionPlan,
          !Task.isCancelled
        else {
          self.activeJobID = nil
          self.isSubmitting = false
          self.isCancelling = false
          return
        }
        self.activeJobID = nil
        self.isCancelling = false
        guard case .completed(let terminal) = runResult else {
          self.isSubmitting = false
          if case .failed(let detail) = runResult {
            self.submissionFailure = detail
          }
          return
        }
        self.submission = terminal
        self.liveStatus = terminal
        guard terminal.state == "succeeded" || terminal.state == "recovered" else {
          self.isSubmitting = false
          return
        }
        let detail = await detailProvider.loadJobDetail(
          jobID: terminal.jobID,
          operationReference: "flash.dayu200")
        guard self.selectedArchiveURL == archiveURL,
          self.plan == executionPlan,
          !Task.isCancelled
        else {
          self.isSubmitting = false
          return
        }
        self.postflightEvidence = detail.evidence
        self.isSubmitting = false
      case .failed(let detail):
        self.isSubmitting = false
        self.submissionFailure = detail
      }
    }
  }

  private func applyBoundLoader(_ rebound: FlashTargetPresentation) {
    let observedMode = workspace.bootloaderStatus.mode
    workspace = FlashWorkspacePresentation(
      availability: workspace.availability,
      targets: workspace.targets.map { $0.id == rebound.id ? rebound : $0 },
      bootloaderStatus: RockchipBootloaderStatus(
        disposition: .exactBoundTarget,
        observationCount: 1,
        mode: observedMode,
        targetID: rebound.id,
        bindingRevision: rebound.bindingRevision),
      targetLoadFailure: workspace.targetLoadFailure)
  }

  func cancelActiveJob() {
    guard let jobID = activeJobID, !isCancelling else { return }
    isCancelling = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self, self.activeJobID == jobID else { return }
      self.isCancelling = false
      if !accepted {
        self.submissionFailure = "Runtime refused the cancellation request"
      }
    }
  }

  private func invalidatePlan() {
    plan = nil
    submission = nil
    liveStatus = nil
    submissionFailure = nil
    postflightEvidence = nil
    activeJobID = nil
    isCancelling = false
    planFailureCode = nil
    planFailureDetail = nil
  }
}
