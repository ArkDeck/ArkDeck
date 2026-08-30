import ArkDeckCore
import ArkDeckWorkflows
import Foundation
import SwiftUI

/// Read-only projection of Runtime's Flash jobs. Cancellation is intentionally
/// owned by the submitting workspace, which can name only its gated Job ID;
/// this shared history card cannot retry, reconcile, resume, or mutate jobs.
struct FlashRuntimeActivityView: View {
  let presentation: RuntimeHistoryPresentation
  let plan: FlashExactPlanPresentation?
  let onOpenJob: (String) -> Void

  private var flashJobs: [RuntimeJobSummaryPresentation] {
    presentation.flashActivityJobs
  }

  /// Unknown effects and human stops outrank recency. Hiding either behind a
  /// later success would make the page unsafe on a shared target bench.
  private var focusedJob: RuntimeJobSummaryPresentation? {
    presentation.focusedFlashActivity
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      if let job = focusedJob, job.needsAttention {
        recoveryBanner(job)
      }

      if let job = focusedJob, criticalStep(for: job) != nil {
        criticalWriteCallout
      }

      WorkspaceSection(Text(flashText("flash.runtime.title"))) {
        switch presentation.availability {
        case .loading:
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(flashText("flash.action.refresh"))
        case .unavailable(let reason):
          unavailable(reason)
        case .available:
          if let job = focusedJob {
            jobSummary(job)
          } else {
            empty
          }
        }
      }
    }
  }

  private var criticalWriteCallout: some View {
    Label(
      flashText("flash.runtime.criticalWrite"),
      systemImage: "exclamationmark.triangle.fill"
    )
    .font(WorkspaceFont.body.weight(.semibold))
    .foregroundStyle(.orange)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkspaceTone.warning.wash,
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
        .stroke(WorkspaceTone.warning.line, lineWidth: 1)
    }
    .accessibilityIdentifier("flash.runtime.criticalWrite")
  }

  private func criticalStep(
    for job: RuntimeJobSummaryPresentation
  ) -> FlashPlanStepPresentation? {
    guard let tail = job.timeline.last,
      let state = JobState(rawValue: job.state), !state.isTerminal
    else { return nil }
    return plan?.steps.first { step in
      step.cancellation == .criticalNonInterruptible
        && (tail == step.id || tail.contains(" \(step.id)"))
    }
  }

  private func recoveryBanner(_ job: RuntimeJobSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Label(flashText("flash.runtime.recoveryTitle"), systemImage: "exclamationmark.shield.fill")
        .font(WorkspaceFont.sectionTitle)
        .foregroundStyle(.orange)
      Text(
        flashText(
          job.outcomeUnknown
            ? "flash.runtime.outcomeUnknownGuidance"
            : "flash.runtime.waitingForHumanGuidance")
      )
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("flash.runtime.recovery.guidance")
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.blockGap) {
        LabeledContent(flashText("flash.runtime.job")) {
          Text(job.id).font(WorkspaceFont.monospacedValue)
        }
        LabeledContent(flashText("flash.runtime.target")) {
          Text(job.targetID).font(WorkspaceFont.monospacedValue)
        }
      }
      Button(flashText("flash.runtime.openRecord")) { onOpenJob(job.id) }
        .accessibilityIdentifier("flash.runtime.openHistory")
    }
    .padding(.horizontal, WorkspaceMetrics.cardPaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.cardPaddingVertical)
    .background(
      WorkspaceTone.warning.wash,
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
        .stroke(WorkspaceTone.warning.line, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.runtime.attention")
  }

  private func unavailable(_ reason: String) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      Label(
        flashText("flash.runtime.unavailable"),
        systemImage: "antenna.radiowaves.left.and.right.slash"
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("flash.runtime.unavailable")
      Text(reason)
        .font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text(flashText("flash.runtime.unavailableNote"))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      Label(flashText("flash.runtime.empty"), systemImage: "clock")
        .font(WorkspaceFont.body.weight(.semibold))
        .accessibilityIdentifier("flash.runtime.empty")
      Text(flashText("flash.runtime.emptyDescription"))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func jobSummary(_ job: RuntimeJobSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkspaceMetrics.contentGap) {
          runtimeState(job)
          if displaysIndeterminateProgress(job.state) {
            ProgressView()
              .controlSize(.small)
              .accessibilityIdentifier("flash.runtime.progress")
          }
          Spacer(minLength: 12)
          Text(
            String(
              localized: LocalizedStringResource.FlashLocalizable.flashRuntimeJobCount(
                Int32(clamping: flashJobs.count)))
          )
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          HStack(spacing: WorkspaceMetrics.contentGap) {
            runtimeState(job)
            if displaysIndeterminateProgress(job.state) {
              ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("flash.runtime.progress")
            }
          }
          Text(
            String(
              localized: LocalizedStringResource.FlashLocalizable.flashRuntimeJobCount(
                Int32(clamping: flashJobs.count)))
          )
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        }
      }

      WorkspaceFactGrid {
        factRow("flash.runtime.job", job.id, identifier: "flash.runtime.jobID")
        factRow("flash.runtime.target", job.targetID, identifier: "flash.runtime.targetID")
      }

      if job.outstandingResidueCount > 0 {
        Label(
          String(
            localized: LocalizedStringResource.FlashLocalizable.flashRuntimeResidue(
              Int32(clamping: job.outstandingResidueCount))),
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
        .accessibilityIdentifier("flash.runtime.residue")
      }

      if !job.timeline.isEmpty {
        Divider()
        Text(flashText("flash.runtime.timeline"))
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(Array(job.timeline.enumerated()), id: \.offset) { index, entry in
            timelineRow(entry, index: index, job: job)
          }
        }
        .accessibilityIdentifier("flash.runtime.timeline.entries")
      }

      Divider()
      resultSummary(job)
      HStack(spacing: WorkspaceMetrics.contentGap) {
        if !job.needsAttention {
          Button(flashText("flash.runtime.openRecord")) { onOpenJob(job.id) }
            .accessibilityIdentifier("flash.runtime.openHistory")
        }
        Label(flashText("flash.runtime.readOnly"), systemImage: "eye")
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func runtimeState(_ job: RuntimeJobSummaryPresentation) -> some View {
    Label {
      stateText(job.state)
        .accessibilityIdentifier("flash.runtime.state")
    } icon: {
      Image(systemName: stateSymbol(job))
    }
    .font(WorkspaceFont.body.weight(.semibold))
    .foregroundStyle(stateColor(job))
  }

  private func factRow(
    _ key: String,
    _ value: String,
    identifier: String
  ) -> WorkspaceFactRow {
    WorkspaceFactRow(
      name: Text(flashText(key)),
      value: Text(value),
      isSelectable: true,
      identifier: identifier)
  }

  private func timelineRow(
    _ entry: String,
    index: Int,
    job: RuntimeJobSummaryPresentation
  ) -> some View {
    let isCurrent = index == job.timeline.count - 1
    return HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: isCurrent ? stateSymbol(job) : "checkmark.circle")
        .foregroundStyle(isCurrent ? stateColor(job) : .secondary)
        .accessibilityHidden(true)
      Text(entry)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func resultSummary(_ job: RuntimeJobSummaryPresentation) -> some View {
    Label(flashText(resultKey(job)), systemImage: resultSymbol(job))
      .font(.callout)
      .foregroundStyle(stateColor(job))
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("flash.runtime.result")
  }

  private func stateText(_ rawState: String) -> Text {
    guard let state = JobState(rawValue: rawState) else { return Text(rawState) }
    switch state {
    case .queued: return Text(flashText("flash.state.queued"))
    case .preflight: return Text(flashText("flash.state.preflight"))
    case .running: return Text(flashText("flash.state.running"))
    case .waitingForDevice: return Text(flashText("flash.state.waitingForDevice"))
    case .awaitingRebindConfirmation:
      return Text(flashText("flash.state.awaitingRebindConfirmation"))
    case .planning: return Text(flashText("flash.state.planning"))
    case .cancelRequested: return Text(flashText("flash.state.cancelRequested"))
    case .cancellingAtSafeBoundary:
      return Text(flashText("flash.state.cancellingAtSafeBoundary"))
    case .waitingForRecovery: return Text(flashText("flash.state.waitingForRecovery"))
    case .reconciling: return Text(flashText("flash.state.reconciling"))
    case .recoveringByCompleteOverwrite:
      return Text(flashText("flash.state.recoveringByCompleteOverwrite"))
    case .resumeAtConfirmedSafeBoundary:
      return Text(flashText("flash.state.resumeAtConfirmedSafeBoundary"))
    case .userAbandonRequested: return Text(flashText("flash.state.userAbandonRequested"))
    case .finalizing: return Text(flashText("flash.state.finalizing"))
    case .planned: return Text(flashText("flash.state.planned"))
    case .succeeded: return Text(flashText("flash.state.succeeded"))
    case .recovered: return Text(flashText("flash.state.recovered"))
    case .failed: return Text(flashText("flash.state.failed"))
    case .cancelled: return Text(flashText("flash.state.cancelled"))
    case .interrupted: return Text(flashText("flash.state.interrupted"))
    }
  }

  private func resultKey(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.supersededByRecoveryEpochID != nil {
      return "flash.runtime.result.supersededByRecovery"
    }
    if job.resolvedByTargetAliasResolutionID != nil {
      return "flash.runtime.result.targetAliasResolved"
    }
    if job.outcomeUnknown { return "flash.runtime.result.outcomeUnknown" }
    guard let state = JobState(rawValue: job.state) else {
      return "flash.runtime.result.unknown"
    }
    switch state {
    case .succeeded, .recovered: return "flash.runtime.result.succeeded"
    case .planned: return "flash.runtime.result.planned"
    case .failed: return "flash.runtime.result.failed"
    case .cancelled: return "flash.runtime.result.cancelled"
    case .interrupted: return "flash.runtime.result.interrupted"
    case .waitingForRecovery, .awaitingRebindConfirmation, .userAbandonRequested:
      return "flash.runtime.result.needsAction"
    default: return "flash.runtime.result.inProgress"
    }
  }

  private func resultSymbol(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.hasEstablishedCurrentEpoch { return "checkmark.shield.fill" }
    if job.outcomeUnknown { return "questionmark.diamond.fill" }
    guard let state = JobState(rawValue: job.state) else { return "questionmark.circle" }
    switch state {
    case .succeeded, .recovered: return "checkmark.circle.fill"
    case .planned: return "doc.text.magnifyingglass"
    case .failed: return "xmark.octagon.fill"
    case .cancelled: return "stop.circle"
    case .interrupted: return "pause.circle"
    case .waitingForRecovery, .awaitingRebindConfirmation, .userAbandonRequested:
      return "person.crop.circle.badge.exclamationmark"
    default: return "clock"
    }
  }

  private func stateSymbol(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.hasEstablishedCurrentEpoch { return "checkmark.shield.fill" }
    if job.outcomeUnknown { return "questionmark.diamond.fill" }
    guard let state = JobState(rawValue: job.state) else { return "questionmark.circle" }
    switch state {
    case .succeeded, .recovered: return "checkmark.circle.fill"
    case .failed: return "xmark.octagon.fill"
    case .cancelled: return "stop.circle"
    case .interrupted: return "pause.circle"
    case .waitingForRecovery, .awaitingRebindConfirmation, .userAbandonRequested:
      return "exclamationmark.triangle.fill"
    case .planned: return "doc.text.magnifyingglass"
    default: return "clock.arrow.circlepath"
    }
  }

  private func stateColor(_ job: RuntimeJobSummaryPresentation) -> Color {
    if job.hasEstablishedCurrentEpoch { return .green }
    // Unknown is warn, not danger: red stays reserved for known failure.
    if job.outcomeUnknown { return .orange }
    guard let state = JobState(rawValue: job.state) else { return .secondary }
    switch state {
    case .succeeded, .recovered: return .green
    case .failed: return .red
    case .waitingForRecovery, .awaitingRebindConfirmation, .userAbandonRequested,
      .interrupted:
      return .orange
    case .running, .preflight, .planning, .waitingForDevice, .reconciling,
      .recoveringByCompleteOverwrite, .finalizing:
      return .blue
    default: return .secondary
    }
  }

  private func displaysIndeterminateProgress(_ rawState: String) -> Bool {
    guard let state = JobState(rawValue: rawState) else { return false }
    switch state {
    case .queued, .preflight, .running, .waitingForDevice, .planning, .cancelRequested,
      .cancellingAtSafeBoundary, .reconciling, .recoveringByCompleteOverwrite,
      .resumeAtConfirmedSafeBoundary, .finalizing:
      return true
    default:
      return false
    }
  }
}
