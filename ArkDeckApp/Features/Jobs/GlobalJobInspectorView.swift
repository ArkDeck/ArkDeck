import ArkDeckCore
import ArkDeckWorkflows
import Foundation
import SwiftUI

private func jobsText(_ key: String) -> String {
  Bundle.main.localizedString(forKey: key, value: key, table: "JobsLocalizable")
}

private struct EstablishedCurrentEpochRelation {
  let id: String
  let messageKey: String
}

/// Cross-workspace, read-only Runtime status. This surface consumes only the
/// daemon's `job.list` projection; it has no submit, cancel, retry, resume,
/// reconcile or archive action to call.
struct GlobalJobInspectorView: View {
  let presentation: RuntimeHistoryPresentation
  let isRefreshInFlight: Bool
  let onRefresh: () -> Void
  let onOpenHistory: () -> Void
  @Binding var isExpanded: Bool
  @State private var selectedJobID: RuntimeJobSummaryPresentation.ID?

  private var orderedJobs: [RuntimeJobSummaryPresentation] {
    presentation.jobs.enumerated().sorted { lhs, rhs in
      let left = priority(of: lhs.element)
      let right = priority(of: rhs.element)
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
  }

  private var focusedJob: RuntimeJobSummaryPresentation? {
    if let selectedJobID,
      let selected = presentation.jobs.first(where: { $0.id == selectedJobID })
    {
      return selected
    }
    return orderedJobs.first
  }

  private var activeJobCount: Int {
    presentation.jobs.filter(isActive).count
  }

  var body: some View {
    VStack(spacing: 0) {
      if isExpanded {
        expandedContent
        Divider()
      }
      compactBar
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("jobInspector")
  }

  @ViewBuilder
  private var expandedContent: some View {
    switch presentation.availability {
    case .unavailable(let reason):
      ContentUnavailableView {
        Label(
          jobsText("jobInspector.unavailable.title"),
          systemImage: "antenna.radiowaves.left.and.right.slash")
      } description: {
        VStack(spacing: 6) {
          Text(reason).font(.callout.monospaced())
          Text(jobsText("jobInspector.unavailable.guidance"))
        }
        .multilineTextAlignment(.center)
      }
      .accessibilityIdentifier("jobInspector.unavailable")
    case .available:
      if presentation.jobs.isEmpty {
        ContentUnavailableView {
          Label(jobsText("jobInspector.empty.title"), systemImage: "clock")
        } description: {
          Text(jobsText("jobInspector.empty.description"))
        }
        .accessibilityIdentifier("jobInspector.empty")
      } else {
        HSplitView {
          jobList
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
          jobDetail
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private var jobList: some View {
    List(orderedJobs, selection: $selectedJobID) { job in
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          stateLabel(job)
          Spacer(minLength: 8)
          if job.outstandingResidueCount > 0 {
            Label(
              String(
                localized: LocalizedStringResource.JobsLocalizable.jobInspectorResidueCompact(
                  Int32(clamping: job.outstandingResidueCount))),
              systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }

          if isCriticalStepActive(job) {
            Label(
              jobsText("jobInspector.criticalWrite"),
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("jobInspector.criticalWrite")
          }
        }
        HStack(spacing: 6) {
          Text(displayedOperationReference(job.operationReference))
            .font(.callout.monospaced())
            .lineLimit(1)
          if let badge = RuntimeExecutionModeBadge(job.executionMode) {
            badge
          }
        }
        Text(job.targetID)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(.vertical, 3)
      .tag(job.id)
      .accessibilityIdentifier("jobInspector.row.\(job.id)")
    }
    .accessibilityIdentifier("jobInspector.list")
  }

  @ViewBuilder
  private var jobDetail: some View {
    if let job = focusedJob {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            stateLabel(job)
            if isActive(job) {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel(jobsText("jobInspector.progress"))
            }
            Spacer(minLength: 12)
            Text(jobsText("jobInspector.readOnly"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            factRow("jobInspector.fact.job", job.id)
            factRow(
              "jobInspector.fact.operation",
              displayedOperationReference(job.operationReference))
            factRow("jobInspector.fact.target", job.targetID)
            if job.hasEstablishedCurrentEpoch {
              recordedStateFactRow(job.state)
            }
            if let badge = RuntimeExecutionModeBadge(job.executionMode) {
              GridRow(alignment: .firstTextBaseline) {
                Text(jobsText("jobInspector.fact.mode")).foregroundStyle(.secondary)
                badge
              }
            }
          }

          if let relation = establishedCurrentEpochRelation(job) {
            VStack(alignment: .leading, spacing: 8) {
              Label(
                jobsText(relation.messageKey),
                systemImage: "checkmark.shield.fill"
              )
              .foregroundStyle(.green)
              .fixedSize(horizontal: false, vertical: true)
              Grid(alignment: .leading, horizontalSpacing: 16) {
                factRow("jobInspector.fact.recoveryRelation", relation.id)
              }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("jobInspector.establishedCurrentEpoch")
          }

          if job.needsAttention {
            Label(
              jobsText(
                job.outcomeUnknown
                  ? "jobInspector.result.outcomeUnknown"
                  : "jobInspector.result.waitingForHuman"),
              systemImage: job.outcomeUnknown
                ? "questionmark.diamond.fill"
                : "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("jobInspector.attention")
          }

          if job.outstandingResidueCount > 0 {
            Label(
              String(
                localized: LocalizedStringResource.JobsLocalizable.jobInspectorResidue(
                  Int32(clamping: job.outstandingResidueCount))),
              systemImage: "externaldrive.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          }

          if !job.timeline.isEmpty {
            Divider()
            Text(jobsText("jobInspector.timeline"))
              .font(.subheadline.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 7) {
              ForEach(Array(job.timeline.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Image(
                    systemName: index == job.timeline.count - 1
                      ? symbol(for: job)
                      : "checkmark.circle"
                  )
                  .foregroundStyle(
                    index == job.timeline.count - 1 ? color(for: job) : .secondary
                  )
                  .accessibilityHidden(true)
                  Text(entry)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .accessibilityIdentifier("jobInspector.timeline.entries")
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
      }
    } else {
      ContentUnavailableView(jobsText("jobInspector.select"), systemImage: "sidebar.right")
    }
  }

  private var compactBar: some View {
    HStack(spacing: 12) {
      Button {
        isExpanded.toggle()
      } label: {
        Label(
          jobsText(
            isExpanded ? "jobInspector.action.hide" : "jobInspector.action.show"),
          systemImage: isExpanded ? "chevron.down" : "chevron.up")
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
      .accessibilityIdentifier("jobInspector.toggle")

      Divider().frame(height: 20)

      compactStatus

      Spacer(minLength: 12)

      if isRefreshInFlight {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(jobsText("jobInspector.refreshing"))
      }
      Button(jobsText("jobInspector.action.refresh"), action: onRefresh)
        .disabled(isRefreshInFlight)
        .accessibilityIdentifier("jobInspector.refresh")
      Button(jobsText("jobInspector.action.openHistory"), action: onOpenHistory)
        .accessibilityIdentifier("jobInspector.openHistory")
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 40)
  }

  @ViewBuilder
  private var compactStatus: some View {
    switch presentation.availability {
    case .unavailable:
      Label(
        jobsText("jobInspector.compact.unavailable"),
        systemImage: "antenna.radiowaves.left.and.right.slash"
      )
      .foregroundStyle(.orange)
    case .available:
      if let job = focusedJob {
        HStack(spacing: 8) {
          stateLabel(job)
          Text(displayedOperationReference(job.operationReference))
            .font(.callout.monospaced())
            .lineLimit(1)
          if activeJobCount > 0 {
            Text(
              String(
                localized: LocalizedStringResource.JobsLocalizable.jobInspectorCompactActiveCount(
                  Int32(clamping: activeJobCount)))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if isActive(job) {
            // Elapsed since the job started — host wall clock, ticking. The
            // spinner alone says "busy"; the timer says "for how long".
            if let started = startedDate(job) {
              Text(started, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(jobsText("jobInspector.elapsed"))
            }
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel(jobsText("jobInspector.progress"))
          }
        }
      } else {
        Label(jobsText("jobInspector.compact.empty"), systemImage: "clock")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func startedDate(_ job: RuntimeJobSummaryPresentation) -> Date? {
    guard let startedAtUTC = job.startedAtUTC else { return nil }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(startedAtUTC)
  }

  private func factRow(_ key: String, _ value: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(jobsText(key)).foregroundStyle(.secondary)
      Text(value)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func recordedStateFactRow(_ rawState: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(jobsText("jobInspector.fact.recordedState")).foregroundStyle(.secondary)
      stateText(rawState)
        .font(.body.monospaced())
        .textSelection(.enabled)
    }
  }

  private func establishedCurrentEpochRelation(
    _ job: RuntimeJobSummaryPresentation
  ) -> EstablishedCurrentEpochRelation? {
    if let recoveryEpochID = job.supersededByRecoveryEpochID {
      return EstablishedCurrentEpochRelation(
        id: recoveryEpochID,
        messageKey: "jobInspector.result.supersededByRecovery")
    }
    if let resolutionID = job.resolvedByTargetAliasResolutionID {
      return EstablishedCurrentEpochRelation(
        id: resolutionID,
        messageKey: "jobInspector.result.targetAliasResolved")
    }
    return nil
  }

  @ViewBuilder
  private func stateLabel(_ job: RuntimeJobSummaryPresentation) -> some View {
    if job.hasEstablishedCurrentEpoch {
      Label(
        jobsText("jobInspector.state.currentEpochEstablished"),
        systemImage: "checkmark.shield.fill"
      )
      .font(.callout.weight(.semibold))
      .foregroundStyle(.green)
    } else {
      Label {
        stateText(job.state)
      } icon: {
        Image(systemName: symbol(for: job))
          .accessibilityHidden(true)
      }
      .font(.callout.weight(.semibold))
      .foregroundStyle(color(for: job))
    }
  }

  private func priority(of job: RuntimeJobSummaryPresentation) -> Int {
    if job.needsAttention { return 0 }
    if isActive(job) { return 1 }
    return 2
  }

  private func isActive(_ job: RuntimeJobSummaryPresentation) -> Bool {
    if job.hasEstablishedCurrentEpoch { return false }
    guard let state = JobState(rawValue: job.state) else { return false }
    return !state.isTerminal
  }

  private func isCriticalStepActive(_ job: RuntimeJobSummaryPresentation) -> Bool {
    guard isActive(job), let tail = job.timeline.last,
      let descriptor = RuntimeOperationCatalog.descriptor(reference: job.operationReference)
    else { return false }
    return descriptor.steps.contains { step in
      step.cancellation == .criticalNonInterruptible
        && (tail == step.stepID || tail.contains(" \(step.stepID)"))
    }
  }

  private func stateText(_ rawState: String) -> Text {
    guard let state = JobState(rawValue: rawState) else { return Text(rawState) }
    return Text(jobsText("job.state.\(state.rawValue)"))
  }

  private func symbol(for job: RuntimeJobSummaryPresentation) -> String {
    if job.hasEstablishedCurrentEpoch { return "checkmark.shield.fill" }
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

  private func color(for job: RuntimeJobSummaryPresentation) -> Color {
    if job.hasEstablishedCurrentEpoch { return .green }
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
}

/// Recovery guidance is kept above the workspace so it remains visible after
/// navigation. The only action opens the read-only History workspace.
///
/// This is a banner *family*: every outstanding item renders, ordered by
/// severity. Showing only the most severe one would hide a second,
/// different-kind item behind the first until it clears.
struct GlobalRecoveryBannerView: View {
  let presentation: RuntimeHistoryPresentation
  let onOpenHistory: () -> Void

  private var recoveryJobs: [RuntimeJobSummaryPresentation] {
    presentation.jobs
      .filter(\.requiresRecoveryGuidance)
      .sorted { severity($0) < severity($1) }
  }

  private func severity(_ job: RuntimeJobSummaryPresentation) -> Int {
    if job.outcomeUnknown { return 0 }
    if job.waitingForHuman { return 1 }
    return 2
  }

  var body: some View {
    let jobs = recoveryJobs
    if !jobs.isEmpty {
      VStack(spacing: 8) {
        ForEach(jobs) { job in
          banner(job)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
    }
  }

  private func banner(_ job: RuntimeJobSummaryPresentation) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: recoverySymbol(job))
        .font(.title3)
        .foregroundStyle(recoveryColor(job))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(jobsText(recoveryTitle(job)))
          .font(.headline)
        Text(jobsText(recoveryGuidance(job)))
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        Text("\(job.id) · \(job.targetID)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 12)
      Button(jobsText("jobRecovery.action.openHistory"), action: onOpenHistory)
        .accessibilityIdentifier("jobRecovery.openHistory")
    }
    .padding(14)
    .background(
      recoveryColor(job).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(recoveryColor(job).opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("jobRecovery.banner")
  }

  private func recoveryTitle(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.outcomeUnknown { return "jobRecovery.outcomeUnknown.title" }
    if job.waitingForHuman { return "jobRecovery.humanRequired.title" }
    guard let state = JobState(rawValue: job.state) else {
      return "jobRecovery.waiting.title"
    }
    switch state {
    case .resumeAtConfirmedSafeBoundary: return "jobRecovery.resumeSafe.title"
    case .userAbandonRequested: return "jobRecovery.archivePending.title"
    default: return "jobRecovery.waiting.title"
    }
  }

  private func recoveryGuidance(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.outcomeUnknown { return "jobRecovery.outcomeUnknown.guidance" }
    if job.waitingForHuman { return "jobRecovery.humanRequired.guidance" }
    guard let state = JobState(rawValue: job.state) else {
      return "jobRecovery.waiting.guidance"
    }
    switch state {
    case .resumeAtConfirmedSafeBoundary: return "jobRecovery.resumeSafe.guidance"
    case .userAbandonRequested: return "jobRecovery.archivePending.guidance"
    default: return "jobRecovery.waiting.guidance"
    }
  }

  // Four kinds, four symbols: the kind must be readable without color —
  // in Increase Contrast and grayscale the symbol is the only differentiator.
  private func recoverySymbol(_ job: RuntimeJobSummaryPresentation) -> String {
    if job.outcomeUnknown { return "questionmark.diamond.fill" }
    if job.waitingForHuman { return "person.crop.circle.badge.exclamationmark" }
    guard let state = JobState(rawValue: job.state) else {
      return "exclamationmark.shield.fill"
    }
    switch state {
    case .resumeAtConfirmedSafeBoundary: return "arrow.clockwise.circle"
    case .userAbandonRequested: return "archivebox"
    default: return "hourglass.circle"
    }
  }

  private func recoveryColor(_ job: RuntimeJobSummaryPresentation) -> Color {
    // outcomeUnknown is warn (the system warning tone), not danger: red
    // claims a known failure, and unknown is precisely not that.
    .orange
  }
}
