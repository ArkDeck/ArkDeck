import ArkDeckCore
import ArkDeckWorkflows
import Foundation
import SwiftUI

/// Read-only projection of Runtime's Flash jobs. This surface can explain an
/// active or failed flash, but it cannot cancel, retry, reconcile or resume it.
struct FlashRuntimeActivityView: View {
  let presentation: RuntimeHistoryPresentation
  let onOpenHistory: () -> Void

  private var flashJobs: [RuntimeJobSummaryPresentation] {
    presentation.jobs.filter { $0.operationReference == "flash.dayu200@1" }
  }

  /// Unknown effects and human stops outrank recency. Hiding either behind a
  /// later success would make the page unsafe on a shared target bench.
  private var focusedJob: RuntimeJobSummaryPresentation? {
    flashJobs.first(where: \.outcomeUnknown)
      ?? flashJobs.first(where: \.waitingForHuman)
      ?? flashJobs.first(where: { job in
        guard let state = JobState(rawValue: job.state) else { return false }
        return !state.isTerminal
      })
      ?? flashJobs.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let job = focusedJob, job.needsAttention {
        recoveryBanner(job)
      }

      GroupBox(flashText("flash.runtime.title")) {
        VStack(alignment: .leading, spacing: 12) {
          switch presentation.availability {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }
    }
  }

  private func recoveryBanner(_ job: RuntimeJobSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(flashText("flash.runtime.recoveryTitle"), systemImage: "exclamationmark.shield.fill")
        .font(.headline)
        .foregroundStyle(.orange)
      Text(
        flashText(
          job.outcomeUnknown
            ? "flash.runtime.outcomeUnknownGuidance"
            : "flash.runtime.waitingForHumanGuidance")
      )
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("flash.runtime.recovery.guidance")
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        LabeledContent(flashText("flash.runtime.job")) {
          Text(job.id).font(.callout.monospaced())
        }
        LabeledContent(flashText("flash.runtime.target")) {
          Text(job.targetID).font(.callout.monospaced())
        }
      }
      Button(flashText("flash.runtime.openRecord"), action: onOpenHistory)
        .accessibilityIdentifier("flash.runtime.openHistory")
    }
    .padding(16)
    .background(
      Color.orange.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.runtime.attention")
  }

  private func unavailable(_ reason: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        flashText("flash.runtime.unavailable"),
        systemImage: "antenna.radiowaves.left.and.right.slash"
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("flash.runtime.unavailable")
      Text(reason)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text(flashText("flash.runtime.unavailableNote"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(flashText("flash.runtime.empty"), systemImage: "clock")
        .font(.callout.weight(.semibold))
        .accessibilityIdentifier("flash.runtime.empty")
      Text(flashText("flash.runtime.emptyDescription"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func jobSummary(_ job: RuntimeJobSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          runtimeState(job)
          if displaysIndeterminateProgress(job.state) {
            ProgressView()
              .controlSize(.small)
              .accessibilityIdentifier("flash.runtime.progress")
          }
          Spacer(minLength: 12)
          Text(
            String(
              format: flashText("flash.runtime.jobCount"),
              flashJobs.count)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            runtimeState(job)
            if displaysIndeterminateProgress(job.state) {
              ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("flash.runtime.progress")
            }
          }
          Text(
            String(
              format: flashText("flash.runtime.jobCount"),
              flashJobs.count)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        factRow("flash.runtime.job", job.id, identifier: "flash.runtime.jobID")
        factRow("flash.runtime.target", job.targetID, identifier: "flash.runtime.targetID")
      }

      if job.outstandingResidueCount > 0 {
        Label(
          String(
            format: flashText("flash.runtime.residue"),
            job.outstandingResidueCount),
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
        .accessibilityIdentifier("flash.runtime.residue")
      }

      if !job.timeline.isEmpty {
        Divider()
        Text(flashText("flash.runtime.timeline"))
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(job.timeline.enumerated()), id: \.offset) { index, entry in
            timelineRow(entry, index: index, job: job)
          }
        }
        .accessibilityIdentifier("flash.runtime.timeline.entries")
      }

      Divider()
      resultSummary(job)
      HStack(spacing: 12) {
        if !job.needsAttention {
          Button(flashText("flash.runtime.openRecord"), action: onOpenHistory)
            .accessibilityIdentifier("flash.runtime.openHistory")
        }
        Label(flashText("flash.runtime.readOnly"), systemImage: "eye")
          .font(.footnote)
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
    .font(.callout.weight(.semibold))
    .foregroundStyle(stateColor(job))
  }

  private func factRow(
    _ key: String,
    _ value: String,
    identifier: String
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(flashText(key)).foregroundStyle(.secondary)
      Text(value)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .accessibilityIdentifier(identifier)
    }
  }

  private func timelineRow(
    _ entry: String,
    index: Int,
    job: RuntimeJobSummaryPresentation
  ) -> some View {
    let isCurrent = index == job.timeline.count - 1
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
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
    case .resumeAtConfirmedSafeBoundary:
      return Text(flashText("flash.state.resumeAtConfirmedSafeBoundary"))
    case .userAbandonRequested: return Text(flashText("flash.state.userAbandonRequested"))
    case .finalizing: return Text(flashText("flash.state.finalizing"))
    case .planned: return Text(flashText("flash.state.planned"))
    case .succeeded: return Text(flashText("flash.state.succeeded"))
    case .failed: return Text(flashText("flash.state.failed"))
    case .cancelled: return Text(flashText("flash.state.cancelled"))
    case .interrupted: return Text(flashText("flash.state.interrupted"))
    }
  }

  private func resultKey(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.outcomeUnknown { return "flash.runtime.result.outcomeUnknown" }
    guard let state = JobState(rawValue: job.state) else {
      return "flash.runtime.result.unknown"
    }
    switch state {
    case .succeeded: return "flash.runtime.result.succeeded"
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
    if job.outcomeUnknown { return "questionmark.diamond.fill" }
    guard let state = JobState(rawValue: job.state) else { return "questionmark.circle" }
    switch state {
    case .succeeded: return "checkmark.circle.fill"
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
    if job.outcomeUnknown { return "questionmark.diamond.fill" }
    guard let state = JobState(rawValue: job.state) else { return "questionmark.circle" }
    switch state {
    case .succeeded: return "checkmark.circle.fill"
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
    // Unknown is warn, not danger: red stays reserved for known failure.
    if job.outcomeUnknown { return .orange }
    guard let state = JobState(rawValue: job.state) else { return .secondary }
    switch state {
    case .succeeded: return .green
    case .failed: return .red
    case .waitingForRecovery, .awaitingRebindConfirmation, .userAbandonRequested,
      .interrupted:
      return .orange
    case .running, .preflight, .planning, .waitingForDevice, .reconciling, .finalizing:
      return .blue
    default: return .secondary
    }
  }

  private func displaysIndeterminateProgress(_ rawState: String) -> Bool {
    guard let state = JobState(rawValue: rawState) else { return false }
    switch state {
    case .queued, .preflight, .running, .waitingForDevice, .planning, .cancelRequested,
      .cancellingAtSafeBoundary, .reconciling, .resumeAtConfirmedSafeBoundary, .finalizing:
      return true
    default:
      return false
    }
  }
}
