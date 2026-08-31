import ArkDeckCore
import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

private func jobsText(_ key: String) -> String {
  Bundle.main.localizedString(forKey: key, value: key, table: "JobsLocalizable")
}

private struct EstablishedCurrentEpochRelation {
  let id: String
  let messageKey: String
}

@MainActor
@Observable
private final class GlobalJobInspectorModel {
  private(set) var detail: RuntimeJobDetailPresentation?
  private(set) var isLoading = false
  private(set) var isReadingLog = false
  private(set) var logText: String?
  private(set) var logError: String?
  private(set) var cancellingJobID: String?
  private(set) var cancellationJobID: String?
  private(set) var cancellationMessage: String?
  private var generation = UUID()
  private var loadedJobID: String?
  @ObservationIgnored private let reader = RuntimeJobDetailApplicationFacade.make()
  @ObservationIgnored private let control = RuntimeJobControlApplicationFacade.make()

  func load(_ job: RuntimeJobSummaryPresentation?) {
    loadedJobID = job?.id
    generation = UUID()
    let ticket = generation
    detail = nil
    logText = nil
    logError = nil
    isReadingLog = false
    guard let job else { isLoading = false; return }
    isLoading = true
    Task { [weak self, reader] in
      let result = await reader.loadJobDetail(jobID: job.id, operationReference: job.operationReference)
      guard let self, generation == ticket else { return }
      detail = result
      isLoading = false
    }
  }

  func cancel(_ job: RuntimeJobSummaryPresentation, onRefresh: @escaping () -> Void) {
    guard cancellingJobID == nil else { return }
    cancellingJobID = job.id
    cancellationJobID = job.id
    cancellationMessage = nil
    Task { [weak self, control] in
      let result = await control.cancel(job)
      guard let self else { return }
      cancellingJobID = nil
      switch result {
      case .requested: cancellationMessage = jobsText("jobInspector.cancel.requested")
      case .refused(let reason):
        cancellationMessage = jobsText("jobInspector.cancel.refused") + " · " + reason
      }
      onRefresh()
      // A late cancellation response must not replace a newly selected Job.
      if loadedJobID == job.id { load(job) }
    }
  }

  func readLog(job: RuntimeJobSummaryPresentation, artifact: RuntimeArtifactPresentation) {
    guard !isReadingLog, let detail, detail.jobID == job.id,
      detail.correlation?.targetID == job.targetID, detail.correlation?.sessionID == job.sessionID,
      detail.artifacts.contains(artifact), artifact.role == "log", artifact.privacy == "standard"
    else { return }
    let ticket = generation
    isReadingLog = true
    logText = nil
    logError = nil
    Task { [weak self, reader] in
      let result = await reader.readArtifact(
        jobID: job.id, artifact: artifact, maximumBytes: 2 * 1_024 * 1_024, allowSensitive: false)
      guard let self, generation == ticket else { return }
      isReadingLog = false
      switch result {
      case .loaded(let bytes):
        guard let text = String(data: bytes, encoding: .utf8) else {
          logError = jobsText("jobInspector.log.notText")
          return
        }
        logText = text.split(separator: "\n", omittingEmptySubsequences: false)
          .suffix(200).joined(separator: "\n")
      case .failed(let reason): logError = reason
      }
    }
  }
}

/// Cross-workspace Runtime status with a separate closed cancellation caller.
/// A cancel request is never presented as a confirmed terminal outcome.
struct GlobalJobInspectorView: View {
  let presentation: RuntimeHistoryPresentation
  let isRefreshInFlight: Bool
  let onRefresh: () -> Void
  let onOpenHistory: () -> Void
  let onOpenJob: (String) -> Void
  @Binding var isExpanded: Bool
  @State private var selectedJobID: RuntimeJobSummaryPresentation.ID?
  @State private var actions = GlobalJobInspectorModel()

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
    presentation.jobs.count(where: isActive)
  }

  var body: some View {
    VStack(spacing: 0) {
      if isExpanded {
        expandedContent
          .background(Color(nsColor: .controlBackgroundColor))
        Divider()
      }
      compactBar
        .background(.bar)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("jobInspector")
    .task(id: focusedJob?.id) {
      if isExpanded { actions.load(focusedJob) }
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded { actions.load(focusedJob) }
    }
  }

  @ViewBuilder
  private var expandedContent: some View {
    switch presentation.availability {
    case .loading:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel(jobsText("jobInspector.refreshing"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable(let reason):
      ContentUnavailableView {
        Label(
          jobsText("jobInspector.unavailable.title"),
          systemImage: "antenna.radiowaves.left.and.right.slash")
      } description: {
        VStack(spacing: WorkspaceMetrics.tightGap) {
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
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
          stateLabel(job)
          Spacer(minLength: WorkspaceMetrics.tightGap)
          if job.outstandingResidueCount > 0 {
            Label(
              String(
                localized: LocalizedStringResource.JobsLocalizable.jobInspectorResidueCompact(
                  Int32(clamping: job.outstandingResidueCount))),
              systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(WorkspaceFont.caption)
            .foregroundStyle(.orange)
          }
        }
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Text(displayedOperationReference(job.operationReference))
            .font(WorkspaceFont.monospacedValue)
            .lineLimit(1)
          if let badge = RuntimeExecutionModeBadge(job.executionMode) {
            badge
          }
        }
        Text(job.targetID)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        // A full-width callout, not a member of the baseline row above: nested
        // in that HStack it took the row's whole width and pushed the summary
        // it annotates out of view.
        if isCriticalStepActive(job) {
          WorkspaceNotice(
            tone: .warning,
            symbol: "exclamationmark.triangle.fill",
            identifier: "jobInspector.criticalWrite"
          ) {
            Text(jobsText("jobInspector.criticalWrite"))
              .bold()
          }
        }
      }
      .padding(.vertical, WorkspaceMetrics.rowGap)
      .tag(job.id)
      .accessibilityIdentifier("jobInspector.row.\(job.id)")
    }
    .accessibilityIdentifier("jobInspector.list")
  }

  @ViewBuilder
  private var jobDetail: some View {
    if let job = focusedJob {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
          HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
            stateLabel(job)
            if isActive(job) {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel(jobsText("jobInspector.progress"))
            }
            Spacer(minLength: WorkspaceMetrics.contentGap)
            Text(jobsText("jobInspector.runtimeFacts"))
              .accessibilityIdentifier("jobInspector.runtimeFacts")
              .font(WorkspaceFont.caption)
              .foregroundStyle(.secondary)
          }

          HStack(spacing: WorkspaceMetrics.contentGap) {
            Button(jobsText("jobInspector.action.openRecord")) { onOpenJob(job.id) }
              .accessibilityIdentifier("jobInspector.openRecord")
            if RuntimeJobControlApplicationFacade.canCancel(job) {
              Button(jobsText("jobInspector.action.cancel")) {
                actions.cancel(job, onRefresh: onRefresh)
              }
              .disabled(actions.cancellingJobID != nil)
              .accessibilityIdentifier("jobInspector.cancel")
            }
          }
          if actions.cancellationJobID == job.id, let message = actions.cancellationMessage {
            Text(message).font(WorkspaceFont.secondary).foregroundStyle(.secondary)
              .accessibilityIdentifier("jobInspector.cancel.result")
          }

          WorkspaceFactGrid {
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
            VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
              Label(
                jobsText(relation.messageKey),
                systemImage: "checkmark.shield.fill"
              )
              .foregroundStyle(.green)
              .fixedSize(horizontal: false, vertical: true)
              WorkspaceFactGrid {
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

          if let detail = actions.detail, detail.jobID == job.id {
            if case .unavailable(let reason) = detail.timelineAvailability {
              Text(reason).font(WorkspaceFont.secondary).foregroundStyle(.orange)
            } else if !detail.timeline.isEmpty {
              Text(jobsText("jobInspector.timeline")).font(WorkspaceFont.label)
              Text(detail.timeline.suffix(200).joined(separator: "\n"))
                .font(WorkspaceFont.monospacedDense).textSelection(.enabled)
                .accessibilityIdentifier("jobInspector.timeline.entries")
              if detail.timeline.count > 200 {
                Text(jobsText("jobInspector.log.tail")).font(WorkspaceFont.caption)
              }
            }
            ForEach(detail.artifacts.filter { $0.role == "log" && $0.status == "published" }) { artifact in
              Button(jobsText("jobInspector.action.readLog") + " · " + artifact.name) {
                actions.readLog(job: job, artifact: artifact)
              }
              .disabled(actions.isReadingLog || artifact.privacy == "sensitive")
              .help(jobsText("jobInspector.log.privacy"))
              .accessibilityIdentifier("jobInspector.readLog.\(artifact.id)")
            }
            if let log = actions.logText {
              Text(jobsText("jobInspector.log.tail")).font(WorkspaceFont.caption).foregroundStyle(.secondary)
              Text(log).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
                .accessibilityIdentifier("jobInspector.log.text")
            }
            if let error = actions.logError {
              Text(error).font(WorkspaceFont.secondary).foregroundStyle(.orange)
            }
          } else if actions.isLoading {
            ProgressView().controlSize(.small)
          } else if !job.timeline.isEmpty {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
              Text(jobsText("jobInspector.timeline"))
                .font(WorkspaceFont.label)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
              timelineEntries(job)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, WorkspaceMetrics.cardPaddingHorizontal)
        .padding(.vertical, WorkspaceMetrics.blockGap)
      }
    } else {
      ContentUnavailableView(jobsText("jobInspector.select"), systemImage: "sidebar.right")
    }
  }

  private func timelineEntries(_ job: RuntimeJobSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      ForEach(job.timeline.enumerated(), id: \.offset) { index, entry in
                HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
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
                    .font(WorkspaceFont.monospacedValue)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
      }
    }
    .accessibilityIdentifier("jobInspector.timeline.entries")
  }

  private var compactBar: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
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

      Spacer(minLength: WorkspaceMetrics.contentGap)

      if isRefreshInFlight {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(jobsText("jobInspector.refreshing"))
      }
      Button(jobsText("jobInspector.action.refresh")) {
        onRefresh()
        if isExpanded { actions.load(focusedJob) }
      }
        .disabled(isRefreshInFlight)
        .accessibilityIdentifier("jobInspector.refresh")
      Button(jobsText("jobInspector.action.openHistory"), action: onOpenHistory)
        .accessibilityIdentifier("jobInspector.openHistory")
    }
    .padding(.horizontal, WorkspaceMetrics.cardPaddingHorizontal)
    .frame(minHeight: WorkspaceMetrics.jobInspectorBarHeight)
  }

  @ViewBuilder
  private var compactStatus: some View {
    switch presentation.availability {
    case .loading:
      Label(jobsText("jobInspector.refreshing"), systemImage: "arrow.clockwise")
        .foregroundStyle(.secondary)
    case .unavailable:
      Label(
        jobsText("jobInspector.compact.unavailable"),
        systemImage: "antenna.radiowaves.left.and.right.slash"
      )
      .foregroundStyle(.orange)
    case .available:
      if let job = focusedJob {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          stateLabel(job)
          Text(displayedOperationReference(job.operationReference))
            .font(WorkspaceFont.monospacedValue)
            .lineLimit(1)
          if activeJobCount > 0 {
            Text(
              String(
                localized: LocalizedStringResource.JobsLocalizable.jobInspectorCompactActiveCount(
                  Int32(clamping: activeJobCount)))
            )
            .font(WorkspaceFont.caption)
            .foregroundStyle(.secondary)
          }
          if isActive(job) {
            // Elapsed since the job started — host wall clock, ticking. The
            // spinner alone says "busy"; the timer says "for how long".
            if let started = startedDate(job) {
              Text(started, style: .timer)
                .font(WorkspaceFont.tabularSecondary)
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

  private func factRow(_ key: String, _ value: String) -> WorkspaceFactRow {
    WorkspaceFactRow(name: Text(jobsText(key)), value: Text(value), isSelectable: true)
  }

  private func recordedStateFactRow(_ rawState: String) -> WorkspaceFactRow {
    WorkspaceFactRow(
      name: Text(jobsText("jobInspector.fact.recordedState")),
      value: stateText(rawState),
      isSelectable: true)
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
/// navigation. The only action opens this Job in the read-only History workspace.
///
/// This is a banner *family*: every outstanding item renders, ordered by
/// severity. Showing only the most severe one would hide a second,
/// different-kind item behind the first until it clears.
struct GlobalRecoveryBannerView: View {
  let presentation: RuntimeHistoryPresentation
  let onOpenJob: (String) -> Void
  let availableSize: CGSize

  @State private var contentHeight: CGFloat?

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
    // Leave room for workspace controls and records at the minimum window
    // height. Even with the inspector expanded, keep a scrollable warning
    // viewport without exceeding the proportional cap.
    let maximumHeight = max(0, min(availableSize.height * 0.45, max(96, availableSize.height - 400)))
    if !jobs.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          if jobs.count > 1 {
            Text(
              String(localized: LocalizedStringResource.JobsLocalizable.jobRecoveryCount(
                Int32(clamping: jobs.count))))
              .font(WorkspaceFont.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("jobRecovery.count")
          }
          ForEach(jobs) { job in
            banner(job)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
        .padding(.top, WorkspaceMetrics.pageInsetTop)
        .padding(.bottom, 1) // Keep the last card's border inside the scroll clip.
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          contentHeight = height
        }
      }
      // Measure the naturally wrapped content, not a fixed card height. A
      // single short item stays compact; a family cannot consume the workspace.
      .frame(height: min(contentHeight ?? maximumHeight, maximumHeight))
      .scrollIndicators(.visible)
      .scrollBounceBehavior(.basedOnSize)
      .accessibilityLabel(jobsText("jobRecovery.list"))
      .accessibilityIdentifier("jobRecovery.list")
    }
  }

  private func banner(_ job: RuntimeJobSummaryPresentation) -> some View {
    let tone = recoveryTone(job)
    let compact = availableSize.width - 2 * WorkspaceMetrics.pageInsetHorizontal <= 600
    return HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: recoverySymbol(job))
        .font(.title3)
        .foregroundStyle(tone.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(jobsText(recoveryTitle(job)))
          .font(WorkspaceFont.sectionTitle)
        Text(jobsText(recoveryGuidance(job)))
          .font(WorkspaceFont.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("\(job.id) · \(job.targetID)")
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if compact { reviewButton(job) }
      }
      if !compact {
        Spacer(minLength: WorkspaceMetrics.contentGap)
        reviewButton(job)
      }
    }
    .padding(.horizontal, WorkspaceMetrics.cardPaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.cardPaddingVertical)
    .background(
      tone.wash,
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius)
        .stroke(tone.line, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("jobRecovery.banner")
  }

  private func reviewButton(_ job: RuntimeJobSummaryPresentation) -> some View {
    Button(jobsText("jobRecovery.action.openHistory")) { onOpenJob(job.id) }
      .fixedSize()
      .accessibilityIdentifier("jobRecovery.openHistory.\(job.id)")
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

  private func recoveryTone(_ job: RuntimeJobSummaryPresentation) -> WorkspaceTone {
    // outcomeUnknown is warn (the system warning tone), not danger: red
    // claims a known failure, and unknown is precisely not that.
    .warning
  }
}
