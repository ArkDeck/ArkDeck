import AppKit
import ArkDeckCore
import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

private let historyLocalizationTable = "HistoryLocalizable"

private func historyLocalized(_ key: String) -> String {
  String(localized: String.LocalizationValue(key), table: historyLocalizationTable)
}

/// Read-only Runtime records workspace. Summary rows come from `job.list`;
/// evidence and Artifact metadata are loaded only for the selected Job.
struct RuntimeHistoryView: View {
  let presentation: RuntimeHistoryPresentation
  let detailsByJobID: [String: RuntimeJobDetailPresentation]
  let loadingDetailJobIDs: Set<String>
  let exportStatesByArtifactID: [String: RuntimeArtifactExportState]
  let isRefreshInFlight: Bool
  let isLoadOlderInFlight: Bool
  let onRefresh: (() -> Void)?
  let onLoadOlder: (() -> Void)?
  let onLoadDetail: ((String, String) -> Void)?
  let onReloadDetail: ((String, String) -> Void)?
  let onExportArtifact: ((String, RuntimeArtifactPresentation, URL, Bool) -> Void)?
  let onOpenWorkspace: ((RuntimeHistoryWorkspaceContext) -> Void)?
  var onOpenDiagnostics: ((RuntimeHistoryWorkspaceContext) -> Void)? = nil
  let requestedJobID: String?

  @State private var selectedJobID: RuntimeJobSummaryPresentation.ID?
  @State private var searchText = ""
  @State private var statusFilter = HistoryStatusFilter.all
  @State private var modeFilter = HistoryModeFilter.all
  @State private var sessionFilter = Self.allSessions
  @State private var targetFilter = Self.allTargets
  @State private var timeFilter = HistoryTimeFilter.anyTime
  @State private var activityFilter = HistoryActivityFilter.all
  @State private var pendingExportArtifact: RuntimeArtifactPresentation?
  @State private var pendingExportJobID: String?
  @State private var isExportPreviewPresented = false

  @AppStorage("history.savedFilter.exists") private var hasSavedFilter = false
  @AppStorage("history.savedFilter.search") private var savedSearchText = ""
  @AppStorage("history.savedFilter.status") private var savedStatus = HistoryStatusFilter.all
    .rawValue
  @AppStorage("history.savedFilter.mode") private var savedMode = HistoryModeFilter.all.rawValue
  @AppStorage("history.savedFilter.session") private var savedSession = Self.allSessions
  @AppStorage("history.savedFilter.target") private var savedTarget = Self.allTargets
  @AppStorage("history.savedFilter.time") private var savedTime = HistoryTimeFilter.anyTime.rawValue
  @AppStorage("history.savedFilter.activity") private var savedActivity = HistoryActivityFilter.all
    .rawValue

  private static let allTargets = "__all_targets__"
  private static let allSessions = "__all_sessions__"

  private var selectedJob: RuntimeJobSummaryPresentation? {
    presentation.jobs.first { $0.id == selectedJobID }
  }

  private var targets: [String] {
    Array(Set(presentation.jobs.map(\.targetID))).sorted()
  }

  private var sessions: [String] {
    Array(Set(presentation.jobs.compactMap(\.sessionID))).sorted()
  }

  private var filteredJobs: [RuntimeJobSummaryPresentation] {
    presentation.jobs.filter(matchesFilters).sorted { lhs, rhs in
      let left = historyDate(lhs)
      let right = historyDate(rhs)
      if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
      return lhs.id > rhs.id
    }
  }

  var body: some View {
    Group {
      switch presentation.availability {
      case .loading:
        loading
      case .unavailable(let reason):
        unavailable(reason)
      case .available:
        available
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        savedFilterMenu
        if let onRefresh {
          Button(historyLocalized("history.action.refresh"), action: onRefresh)
            .accessibilityIdentifier("history.refresh")
            .disabled(isRefreshInFlight)
        }
      }
    }
    .onChange(of: filteredJobs.map(\.id), initial: true) { _, visibleIDs in
      if let selectedJobID, visibleIDs.contains(selectedJobID) { return }
      selectedJobID = visibleIDs.first
    }
    .onChange(of: requestedJobID, initial: true) { _, jobID in
      // A specific run's "View" action must open that run, not whichever row
      // sorts first. This only selects immutable evidence; it never replays.
      guard let jobID, presentation.jobs.contains(where: { $0.id == jobID }) else { return }
      resetFilters()
      selectedJobID = jobID
    }
    .onChange(of: selectedJobID, initial: true) { _, jobID in
      guard let jobID,
        let job = presentation.jobs.first(where: { $0.id == jobID })
      else { return }
      onLoadDetail?(job.id, job.operationReference)
    }
    .onChange(of: detailsByJobID.keys.sorted()) { _, _ in
      guard let job = selectedJob, detailsByJobID[job.id] == nil else { return }
      onLoadDetail?(job.id, job.operationReference)
    }
    .onChange(of: isRefreshInFlight) { _, isRefreshing in
      // A refresh can invalidate an in-flight detail without changing either
      // the selected Job or the empty cache's keys. Restart that read too.
      guard !isRefreshing, let job = selectedJob, detailsByJobID[job.id] == nil else { return }
      onLoadDetail?(job.id, job.operationReference)
    }
    .confirmationDialog(
      historyLocalized("history.artifacts.exportPreview.title"),
      isPresented: $isExportPreviewPresented,
      presenting: pendingExportArtifact
    ) { artifact in
      Button(
        historyLocalized(
          artifact.privacy == "sensitive"
            ? "history.artifacts.exportSensitive" : "history.artifacts.exportConfirm")
      ) {
        chooseExportDestination(for: artifact)
      }
      Button(historyLocalized("history.artifacts.exportCancel"), role: .cancel) {}
    } message: { artifact in
      Text(
        String(
          localized: LocalizedStringResource.HistoryLocalizable
            .historyArtifactsExportPreviewMessage(
              artifact.name,
              ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file),
              artifact.privacy,
              artifact.sha256)))
    }
  }

  private var loading: some View {
    VStack(spacing: WorkspaceMetrics.contentGap) {
      ProgressView()
        .controlSize(.large)
      Text(historyLocalized("history.loading"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("history.loading")
  }

  private func unavailable(_ reason: String) -> some View {
    ContentUnavailableView {
      Label {
        Text(historyLocalized("history.unavailable.title"))
          .accessibilityIdentifier("history.unavailable.title")
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
    } description: {
      VStack(spacing: WorkspaceMetrics.tightGap) {
        Text(reason)
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
          .accessibilityIdentifier("history.unavailable.reason")
        Text(historyLocalized("history.unavailable.guidance"))
      }
      .multilineTextAlignment(.center)
    }
  }

  @ViewBuilder
  private var available: some View {
    if presentation.jobs.isEmpty {
      ContentUnavailableView {
        Label {
          Text(historyLocalized("history.empty.title"))
            .accessibilityIdentifier("history.empty.title")
        } icon: {
          Image(systemName: "clock")
        }
      } description: {
        Text(historyLocalized("history.empty.description"))
          .accessibilityIdentifier("history.empty.description")
      }
    } else {
      GeometryReader { workspace in
        if workspace.size.width >= 890 {
          HSplitView {
            filterSidebar
              .frame(minWidth: 200, idealWidth: 230, maxWidth: 280, maxHeight: .infinity)
            jobTable
              .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            detail
              .frame(minWidth: 320, idealWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
          }
          .frame(width: workspace.size.width, height: workspace.size.height)
        } else {
          VStack(spacing: 0) {
            compactFilters
            Divider()
            HSplitView {
              jobTable
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
              detail
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .frame(width: workspace.size.width, height: workspace.size.height)
        }
      }
    }
  }

  private var filterSidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        Text(historyLocalized("history.activity.title"))
          .font(WorkspaceFont.sectionTitle)
          .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          ForEach(HistoryActivityFilter.allCases) { filter in
            Button {
              activityFilter = filter
            } label: {
              HStack(spacing: WorkspaceMetrics.contentGap) {
                Image(systemName: filter.systemImage)
                  .frame(width: 18)
                Text(historyLocalized(filter.localizationKey))
                Spacer(minLength: 8)
                Text(String(activityCount(filter)))
                  .font(WorkspaceFont.tabularValue)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
              .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
              .contentShape(Rectangle())
              .background(
                activityFilter == filter ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
              )
            }
            .buttonStyle(.plain)
            .foregroundStyle(activityFilter == filter ? Color.accentColor : .primary)
            .accessibilityAddTraits(activityFilter == filter ? .isSelected : [])
            .accessibilityIdentifier("history.activity.\(filter.rawValue)")
          }
        }
        Divider()
        Text(historyLocalized("history.filter.title"))
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
        filterPickers
        filterResultSummary
        Divider()
        Text(historyLocalized("history.activity.quickFilters"))
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
        Button(historyLocalized("history.filter.preset.needsAttention")) {
          resetFilters()
          statusFilter = .needsAttention
        }
        .accessibilityIdentifier("history.activity.needsAttention")
        if let selectedJob {
          Button(selectedJob.targetID) {
            resetFilters()
            targetFilter = selectedJob.targetID
          }
          .font(WorkspaceFont.monospacedValue)
          .accessibilityIdentifier("history.activity.selectedDevice")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var compactFilters: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Picker(historyLocalized("history.activity.title"), selection: $activityFilter) {
        ForEach(HistoryActivityFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      .accessibilityIdentifier("history.filter.activity")
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: WorkspaceMetrics.contentGap) {
          filterPickers.labelsHidden()
          filterResultSummary
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          filterPickers.labelsHidden()
          filterResultSummary
        }
      }
    }
    .padding(WorkspaceMetrics.pageInsetHorizontal)
  }

  private var filterPickers: some View {
    Group {
      Picker(historyLocalized("history.filter.status"), selection: $statusFilter) {
        ForEach(HistoryStatusFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      .accessibilityIdentifier("history.filter.status")
      Picker(historyLocalized("history.filter.mode"), selection: $modeFilter) {
        ForEach(HistoryModeFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      .accessibilityIdentifier("history.filter.mode")
      Picker(historyLocalized("history.filter.session"), selection: $sessionFilter) {
        Text(historyLocalized("history.filter.session.all")).tag(Self.allSessions)
        ForEach(sessions, id: \.self) { session in
          Text(session).font(WorkspaceFont.monospacedValue).tag(session)
        }
      }
      .accessibilityIdentifier("history.filter.session")
      Picker(historyLocalized("history.filter.device"), selection: $targetFilter) {
        Text(historyLocalized("history.filter.device.all")).tag(Self.allTargets)
        ForEach(targets, id: \.self) { target in
          Text(target).font(WorkspaceFont.monospacedValue).tag(target)
        }
      }
      .accessibilityIdentifier("history.filter.device")
      Picker(historyLocalized("history.filter.time"), selection: $timeFilter) {
        ForEach(HistoryTimeFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      .accessibilityIdentifier("history.filter.time")
    }
  }

  private var filterResultSummary: some View {
    Text(
      String(
        localized: LocalizedStringResource.HistoryLocalizable.historyFilterResultCount(
          filteredJobs.count,
          presentation.jobs.count))
    )
    .font(WorkspaceFont.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .accessibilityIdentifier("history.filter.resultCount")
  }

  private var savedFilterMenu: some View {
    Menu(historyLocalized("history.filter.saved")) {
      Button(historyLocalized("history.filter.save"), action: saveCurrentFilter)
        .accessibilityIdentifier("history.filter.save")
      if hasSavedFilter {
        Button(historyLocalized("history.filter.applySaved"), action: applySavedFilter)
          .accessibilityIdentifier("history.filter.applySaved")
        Button(historyLocalized("history.filter.deleteSaved"), role: .destructive) {
          hasSavedFilter = false
        }
        .accessibilityIdentifier("history.filter.deleteSaved")
      }
      Divider()
      Button(historyLocalized("history.filter.preset.needsAttention")) {
        resetFilters()
        statusFilter = .needsAttention
      }
      Button(historyLocalized("history.filter.preset.recentFailures")) {
        resetFilters()
        statusFilter = .failed
        timeFilter = .lastWeek
      }
    }
    .accessibilityIdentifier("history.filter.saved")
  }

  private var jobTable: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(historyLocalized("history.activity.recent"))
              .font(WorkspaceFont.sectionTitle)
            Text(historyLocalized("history.activity.recentDescription"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          filterResultSummary
        }
        TextField(historyLocalized("history.filter.search"), text: $searchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("history.filter.search")
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
      if filteredJobs.isEmpty {
        ContentUnavailableView {
          Label(
            historyLocalized("history.filter.empty.title"),
            systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text(historyLocalized("history.filter.empty.description"))
        } actions: {
          Button(historyLocalized("history.filter.reset"), action: resetFilters)
        }
        .accessibilityIdentifier("history.filter.empty")
      } else {
        List(filteredJobs, selection: $selectedJobID) { job in
          HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
            Image(systemName: activityCategory(for: job).systemImage)
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 24)
              .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
              HStack(alignment: .firstTextBaseline) {
                Text(displayedOperationReference(job.operationReference))
                  .font(WorkspaceFont.label)
                  .lineLimit(1)
                Spacer(minLength: 8)
                Text(formattedDate(historyDate(job)))
                  .font(WorkspaceFont.tabularValue)
                  .foregroundStyle(.secondary)
              }
              Text("\(job.targetID) · \(job.id)")
                .font(WorkspaceFont.monospacedDense)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              HStack(spacing: WorkspaceMetrics.tightGap) {
                historyStateLabel(job)
                  .accessibilityIdentifier("history.row.state.\(job.id)")
                if let badge = historyExecutionModeBadge(job.executionMode) { badge }
              }
            }
          }
          .padding(.vertical, WorkspaceMetrics.rowGap)
          .tag(job.id)
        }
        .accessibilityIdentifier("history.table")
      }
      Divider()
      if presentation.hasOlderJobs || presentation.olderJobsLoadFailure != nil {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          if let failure = presentation.olderJobsLoadFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("history.loadOlder.failure")
          }
          if presentation.hasOlderJobs, let onLoadOlder {
            Button(action: onLoadOlder) {
              if isLoadOlderInFlight {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label(
                  historyLocalized("history.action.loadOlder"),
                  systemImage: "clock.arrow.circlepath")
              }
            }
            .disabled(isLoadOlderInFlight)
            .accessibilityIdentifier("history.loadOlder")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
        .padding(.top, WorkspaceMetrics.contentGap)
      }
      Text(historyLocalized("history.readOnlyNote"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history.readOnlyNote")
        .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
        .padding(.vertical, WorkspaceMetrics.contentGap)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let job = selectedJob {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          detailHeader(job)
          summarySection(job)
          timelineSection(job)
          correlationSection(job)
          evidenceSections(job)
          recoverySection(job)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
        .padding(.top, WorkspaceMetrics.pageInsetTop)
        .padding(.bottom, WorkspaceMetrics.pageInsetBottom)
      }
      .accessibilityIdentifier("history.detail")
    } else {
      ContentUnavailableView {
        Text(historyLocalized("history.detail.select"))
          .accessibilityIdentifier("history.detail.select")
      }
    }
  }

  private func detailHeader(_ job: RuntimeJobSummaryPresentation) -> some View {
    let category = activityCategory(for: job)
    return VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        Text(historyLocalized("history.detail.title"))
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        historyStateLabel(job)
        Spacer(minLength: 8)
        if loadingDetailJobIDs.contains(job.id) {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(historyLocalized("history.detail.loading"))
        }
      }
      if job.outcomeUnknown {
        attention("history.detail.outcomeUnknown", id: "history.detail.outcomeUnknown")
      }
      if job.waitingForHuman {
        attention("history.detail.waitingForHuman", id: "history.detail.waitingForHuman")
      }
      if category.destination != nil, let onOpenWorkspace {
        if let detail = detailsByJobID[job.id],
          let context = RuntimeHistoryWorkspaceContext(job: job, detail: detail)
        {
          Button {
            onOpenWorkspace(context)
          } label: {
            Label(
              historyLocalized(category.openActionLocalizationKey),
              systemImage: "arrow.up.forward.app")
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("history.openWorkspace")
          if context.operationReference == "capture.diagnostics@1",
            context.workspaceKind != .diagnostics, let onOpenDiagnostics
          {
            Button {
              onOpenDiagnostics(context)
            } label: {
              Label(historyLocalized("history.activity.open.diagnostics"), systemImage: "waveform.path")
            }
            .help(historyLocalized("history.context.readOnly"))
            .accessibilityIdentifier("history.openDiagnostics")
          }
        } else if !loadingDetailJobIDs.contains(job.id) {
          Text(historyLocalized("history.activity.open.detailUnavailable"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history.openWorkspace.unavailable")
        }
      } else if category == .other {
        Text(historyLocalized("history.activity.open.unsupported"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history.openWorkspace.unsupported")
      }
      if let onReloadDetail {
        Button {
          onReloadDetail(job.id, job.operationReference)
        } label: {
          Label(historyLocalized("history.detail.reload"), systemImage: "arrow.clockwise")
        }
        .disabled(loadingDetailJobIDs.contains(job.id))
        .accessibilityIdentifier("history.detail.reload")
      }
    }
  }

  @ViewBuilder
  private func correlationSection(_ job: RuntimeJobSummaryPresentation) -> some View {
    if let detail = detailsByJobID[job.id] {
      historySection("history.detail.correlation") {
        switch detail.correlationAvailability {
        case .unavailable(let reason):
          unavailableSection(reason)
        case .available:
          if let correlation = detail.correlation {
            Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.tightGap) {
              row(
                "history.detail.job", correlation.jobID,
                id: "history.correlation.job", monospaced: true)
              row(
                "history.detail.session", correlation.sessionID,
                id: "history.correlation.session", monospaced: true)
              row(
                "history.detail.operation",
                displayedOperationReference(correlation.operationReference),
                id: "history.correlation.operation", monospaced: true)
              row(
                "history.detail.target", correlation.targetID,
                id: "history.correlation.target", monospaced: true)
            }
            Button(historyLocalized("history.correlation.showSession")) {
              sessionFilter = correlation.sessionID
            }
            .accessibilityIdentifier("history.correlation.showSession")
            if correlation.artifacts.isEmpty {
              Text(historyLocalized("history.correlation.noArtifacts"))
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
                Text(
                  String(
                    localized:
                      LocalizedStringResource.HistoryLocalizable.historyCorrelationArtifactCount(
                        correlation.artifacts.count))
                )
                .font(WorkspaceFont.label)
                ForEach(correlation.artifacts) { artifact in
                  VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                    Text("\(artifact.name) · \(artifact.role ?? "—")")
                      .font(WorkspaceFont.caption)
                    Text(artifact.id)
                      .font(WorkspaceFont.monospacedDense)
                      .textSelection(.enabled)
                    Text(artifact.sha256)
                      .font(WorkspaceFont.monospacedDense)
                      .lineLimit(1)
                      .truncationMode(.middle)
                      .help(artifact.sha256)
                      .textSelection(.enabled)
                  }
                  .accessibilityIdentifier("history.correlation.artifact.\(artifact.id)")
                }
              }
            }
            Text(historyLocalized("history.correlation.readOnly"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func summarySection(_ job: RuntimeJobSummaryPresentation) -> some View {
    historySection("history.detail.summary") {
      Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.tightGap) {
        row("history.detail.job", job.id, id: "history.detail.job", monospaced: true)
        row(
          "history.detail.session", job.sessionID ?? historyLocalized("history.value.notReported"),
          id: "history.detail.session", monospaced: true)
        row(
          "history.detail.operation", displayedOperationReference(job.operationReference),
          id: "history.detail.operation", monospaced: true)
        row("history.detail.target", job.targetID, id: "history.detail.target", monospaced: true)
        row("history.detail.state", localizedState(job.state), id: "history.detail.state")
        row(
          "history.detail.outcomeCertainty",
          historyLocalized(
            job.outcomeUnknown
              ? "history.outcome.unknown" : "history.outcome.confirmed"),
          id: "history.detail.outcomeCertainty")
        GridRow(alignment: .firstTextBaseline) {
          Text(historyLocalized("history.detail.mode"))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
          HStack(spacing: WorkspaceMetrics.tightGap) {
            Text(job.executionMode ?? "—")
              .accessibilityIdentifier("history.detail.mode")
            if let badge = historyExecutionModeBadge(job.executionMode) {
              badge
            }
          }
          .gridColumnAlignment(.leading)
        }
        row("history.detail.effect", job.actualEffect ?? "—", id: "history.detail.effect")
        row("history.detail.created", formattedUTC(job.createdAtUTC), id: "history.detail.created")
        row("history.detail.started", formattedUTC(job.startedAtUTC), id: "history.detail.started")
        row(
          "history.detail.finished", formattedUTC(job.finishedAtUTC), id: "history.detail.finished")
      }
      Text(historyLocalized("history.detail.projectionNote"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if job.outstandingResidueCount > 0 {
        Label(
          String(
            localized: LocalizedStringResource.HistoryLocalizable.historyDetailResidue(
              job.outstandingResidueCount)),
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
        .accessibilityIdentifier("history.detail.residue")
      }
    }
  }

  @ViewBuilder
  private func timelineSection(_ job: RuntimeJobSummaryPresentation) -> some View {
    if let detail = detailsByJobID[job.id] {
      switch detail.timelineAvailability {
      case .available:
        timelineEntries(detail.timeline, job: job)
      case .unavailable(let reason):
        historySection("history.detail.timeline") {
          unavailableSection(reason)
        }
      }
    } else if !job.timeline.isEmpty {
      timelineEntries(job.timeline, job: job)
    }
  }

  @ViewBuilder
  private func timelineEntries(
    _ timeline: [String], job: RuntimeJobSummaryPresentation
  ) -> some View {
    if !timeline.isEmpty {
      historySection("history.detail.timeline") {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(Array(timeline.enumerated()), id: \.offset) { index, entry in
            HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
              Image(
                systemName: index == timeline.count - 1 ? stateSymbol(job) : "checkmark.circle"
              )
              .foregroundStyle(index == timeline.count - 1 ? stateColor(job) : .secondary)
              .accessibilityHidden(true)
              Text(entry)
                .font(WorkspaceFont.monospacedValue)
                .textSelection(.enabled)
            }
          }
        }
        .accessibilityIdentifier("history.detail.timeline.entries")
      }
    }
  }

  @ViewBuilder
  private func evidenceSections(_ job: RuntimeJobSummaryPresentation) -> some View {
    if let detail = detailsByJobID[job.id] {
      evidenceSection(detail)
      parameterSection(detail)
      artifactSection(detail, job: job)
    } else if !loadingDetailJobIDs.contains(job.id) {
      historySection("history.detail.evidence") {
        Label(
          historyLocalized("history.detail.notLoaded"),
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func evidenceSection(_ detail: RuntimeJobDetailPresentation) -> some View {
    historySection("history.detail.evidence") {
      switch detail.evidenceAvailability {
      case .unavailable(let reason):
        unavailableSection(reason)
      case .available:
        if let evidence = detail.evidence {
          Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.tightGap) {
            row(
              "history.evidence.provider", evidence.providerID, id: "history.evidence.provider",
              monospaced: true)
            row(
              "history.evidence.catalog", evidence.catalogDigest, id: "history.evidence.catalog",
              monospaced: true)
            row(
              "history.evidence.binding", evidence.bindingRevision.map(String.init) ?? "—",
              id: "history.evidence.binding")
            row(
              "history.evidence.authority", evidence.authorityKind ?? "—",
              id: "history.evidence.authority")
            row(
              "history.evidence.authorityReference", evidence.authorityReference ?? "—",
              id: "history.evidence.authorityReference", monospaced: true)
            row(
              "history.evidence.model", evidence.observedModel ?? "—", id: "history.evidence.model")
            row(
              "history.evidence.firmware", evidence.observedFirmware ?? "—",
              id: "history.evidence.firmware")
            row(
              "history.evidence.transport", evidence.observedTransport ?? "—",
              id: "history.evidence.transport")
            row(
              "history.evidence.terminalState", localizedState(evidence.terminalState),
              id: "history.evidence.terminalState")
            row(
              "history.evidence.mode", evidence.executionMode,
              id: "history.evidence.mode")
            row(
              "history.evidence.effect", evidence.actualEffect ?? "—",
              id: "history.evidence.effect")
            row(
              "history.evidence.firstEvidence",
              formattedUTC(evidence.firstEvidenceStepAtUTC),
              id: "history.evidence.firstEvidence")
          }
          if !evidence.actualStepKinds.isEmpty {
            Text(evidence.actualStepKinds.joined(separator: " · "))
              .font(WorkspaceFont.monospacedDense)
              .textSelection(.enabled)
              .accessibilityIdentifier("history.evidence.steps")
          }
          ForEach(evidence.blockers, id: \.self) { blocker in
            Label(blocker, systemImage: "exclamationmark.triangle")
              .font(WorkspaceFont.monospacedValue)
              .foregroundStyle(.orange)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func parameterSection(_ detail: RuntimeJobDetailPresentation) -> some View {
    historySection("history.detail.parameters") {
      switch detail.evidenceAvailability {
      case .unavailable(let reason):
        unavailableSection(reason)
      case .available:
        if let evidence = detail.evidence {
          if !evidence.traceParameters.isEmpty {
            traceParameterTable(evidence.traceParameters)
            if evidence.parametersWereReported, !evidence.parameters.isEmpty {
              Text(historyLocalized("history.parameters.typedInputs"))
                .font(WorkspaceFont.label)
                .foregroundStyle(.secondary)
              typedParameterGrid(evidence.parameters)
            }
          } else if !evidence.parametersWereReported {
            Text(historyLocalized("history.parameters.unavailable"))
              .foregroundStyle(.secondary)
          } else if evidence.parameters.isEmpty {
            Text(historyLocalized("history.parameters.empty"))
              .foregroundStyle(.secondary)
          } else {
            typedParameterGrid(evidence.parameters)
          }
        }
      }
    }
  }

  private func traceParameterTable(
    _ parameters: [RuntimeTraceParameterPresentation]
  ) -> some View {
    Table(parameters) {
      TableColumn(historyLocalized("history.parameters.column.name")) { parameter in
        Text(parameter.name)
          .font(WorkspaceFont.monospacedDense)
          .lineLimit(2)
          .help(parameter.name)
          .textSelection(.enabled)
      }
      .width(min: 90, ideal: 170)
      TableColumn(historyLocalized("history.parameters.column.before")) { parameter in
        traceParameterValue(state: parameter.beforeState, value: parameter.beforeValue)
      }
      .width(min: 48, ideal: 72)
      TableColumn(historyLocalized("history.parameters.column.after")) { parameter in
        traceParameterValue(state: parameter.afterState, value: parameter.afterValue)
      }
      .width(min: 48, ideal: 72)
      TableColumn(historyLocalized("history.parameters.column.status")) { parameter in
        traceParameterStatus(parameter.comparison)
      }
      .width(min: 82, ideal: 104)
    }
    .frame(
      minHeight: 24 * CGFloat(min(max(parameters.count, 1), 8)) + 28,
      idealHeight: 24 * CGFloat(min(max(parameters.count, 1), 12)) + 28
    )
    .accessibilityIdentifier("history.parameters.traceDiff")
  }

  private func typedParameterGrid(
    _ parameters: [RuntimeJobParameterPresentation]
  ) -> some View {
    Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.tightGap) {
      ForEach(parameters) { parameter in
        GridRow(alignment: .firstTextBaseline) {
          Text(parameter.name).font(WorkspaceFont.monospacedValue)
          Text(parameter.value)
            .font(WorkspaceFont.monospacedValue)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityIdentifier("history.parameters")
  }

  private func traceParameterValue(state: String, value: String?) -> some View {
    let displayValue: String
    switch state {
    case "value": displayValue = value ?? historyLocalized("history.value.notReported")
    case "missing": displayValue = historyLocalized("history.parameters.state.missing")
    case "unreadable": displayValue = historyLocalized("history.parameters.state.unreadable")
    default: displayValue = historyLocalized("history.parameters.state.unknown")
    }
    return Text(displayValue)
      .font(WorkspaceFont.monospacedDense)
      .lineLimit(2)
      .textSelection(.enabled)
  }

  private func traceParameterStatus(
    _ comparison: RuntimeTraceParameterComparison
  ) -> some View {
    let presentation: (key: String, symbol: String, color: Color) =
      switch comparison {
      case .unchanged:
        ("history.parameters.comparison.unchanged", "checkmark.circle", .green)
      case .changed:
        ("history.parameters.comparison.changed", "exclamationmark.triangle.fill", .orange)
      case .unverified:
        ("history.parameters.comparison.unverified", "questionmark.circle", .orange)
      }
    return Label(historyLocalized(presentation.key), systemImage: presentation.symbol)
      .font(WorkspaceFont.label)
      .foregroundStyle(presentation.color)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func artifactSection(
    _ detail: RuntimeJobDetailPresentation, job: RuntimeJobSummaryPresentation
  ) -> some View {
    historySection("history.detail.artifacts") {
      switch detail.artifactAvailability {
      case .unavailable(let reason):
        unavailableSection(reason)
      case .available:
        if detail.artifacts.isEmpty {
          // A planned job legitimately carries no captured artifacts — that
          // emptiness is the mode's meaning, not a load failure.
          Text(
            historyLocalized(
              job.executionMode == JobExecutionMode.planOnly.rawValue
                ? "history.artifacts.emptyPlanned" : "history.artifacts.empty")
          )
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history.artifacts.empty")
        } else {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
            ForEach(detail.artifacts) { artifact in
              artifactRow(artifact, jobID: job.id)
            }
          }
          .accessibilityIdentifier("history.artifacts")
        }
        Label(historyLocalized("history.artifacts.exportBoundary"), systemImage: "lock.doc")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func artifactRow(
    _ artifact: RuntimeArtifactPresentation,
    jobID: String
  ) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
          Text(artifact.name).font(.callout.monospaced().weight(.semibold))
          Spacer(minLength: 8)
          artifactStatus(artifact)
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(artifact.name).font(.callout.monospaced().weight(.semibold))
          artifactStatus(artifact)
        }
      }
      Text(
        "\(artifact.role ?? "—") · \(artifact.sourceOperation) · "
          + ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file)
      )
      .font(WorkspaceFont.caption)
      .foregroundStyle(.secondary)
      Text(artifact.sha256)
        .font(WorkspaceFont.monospacedDense)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(artifact.sha256)
        .textSelection(.enabled)
      Text("\(artifact.privacy) · \(artifact.mediaType)")
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
      if let statusDetail = artifact.statusDetail {
        Label(statusDetail, systemImage: "exclamationmark.triangle")
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      HStack(spacing: WorkspaceMetrics.tightGap) {
        Button(historyLocalized("history.artifacts.export")) {
          pendingExportArtifact = artifact
          pendingExportJobID = jobID
          isExportPreviewPresented = true
        }
        .disabled(
          artifact.status != "published"
            || exportStatesByArtifactID[artifact.id] == .exporting
        )
        .accessibilityIdentifier("history.artifact.export.\(artifact.id)")
        if case .completed(let url) = exportStatesByArtifactID[artifact.id] {
          Button(historyLocalized("history.artifacts.showInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          .accessibilityIdentifier("history.artifact.finder.\(artifact.id)")
        }
        if exportStatesByArtifactID[artifact.id] == .exporting {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(historyLocalized("history.artifacts.exporting"))
        }
      }
      if case .failed(let reason) = exportStatesByArtifactID[artifact.id] {
        Label(reason, systemImage: "xmark.octagon")
          .font(WorkspaceFont.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history.artifact.exportFailure.\(artifact.id)")
      }
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .background(
      .quaternary.opacity(0.35),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
    )
    .accessibilityIdentifier("history.artifact.\(artifact.id)")
  }

  private func chooseExportDestination(for artifact: RuntimeArtifactPresentation) {
    guard let jobID = pendingExportJobID else { return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = safeExportName(artifact.name)
    Task { @MainActor in
      guard await panel.begin() == .OK, let url = panel.url else { return }
      onExportArtifact?(
        jobID, artifact, url, artifact.privacy == "sensitive")
    }
  }

  private func safeExportName(_ value: String) -> String {
    let sanitized =
      value
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return sanitized.isEmpty ? "ArkDeck-Artifact" : sanitized
  }

  private func artifactStatus(_ artifact: RuntimeArtifactPresentation) -> some View {
    Label {
      Text(artifact.status)
    } icon: {
      Image(
        systemName: artifact.status == "published" ? "checkmark.circle" : "exclamationmark.triangle"
      )
    }
    .font(WorkspaceFont.label)
    .foregroundStyle(artifact.status == "published" ? .green : .orange)
  }

  private func recoverySection(_ job: RuntimeJobSummaryPresentation) -> some View {
    historySection("history.detail.recovery") {
      if job.outcomeUnknown {
        Label(
          historyLocalized("history.recovery.outcomeUnknown"),
          systemImage: "questionmark.diamond.fill"
        )
        .foregroundStyle(.red)
      } else if job.waitingForHuman {
        Label(
          historyLocalized("history.recovery.waitingForHuman"),
          systemImage: "person.crop.circle.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
      } else if job.outstandingResidueCount > 0 {
        Label(
          historyLocalized("history.recovery.residue"),
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
      } else {
        Label(historyLocalized("history.recovery.none"), systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      }
      Text(historyLocalized("history.recovery.readOnly"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func historySection<Content: View>(
    _ titleKey: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    WorkspaceSection(Text(historyLocalized(titleKey))) {
      content()
    }
  }

  private func unavailableSection(_ reason: String) -> some View {
    Label {
      Text(reason)
        .font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    }
  }

  private func attention(_ titleKey: String, id: String) -> some View {
    Label {
      Text(historyLocalized(titleKey)).accessibilityIdentifier(id)
    } icon: {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
    }
    .font(.callout)
  }

  private func row(
    _ titleKey: String,
    _ value: String,
    id: String,
    monospaced: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(historyLocalized(titleKey))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      Text(value)
        .font(monospaced ? .body.monospaced() : .body)
        .accessibilityIdentifier(id)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func matchesFilters(_ job: RuntimeJobSummaryPresentation) -> Bool {
    if activityFilter != .all, activityFilter != activityCategory(for: job) { return false }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !query.isEmpty,
      ![
        job.id, job.sessionID ?? "", job.operationReference, job.targetID, job.state,
        job.executionMode ?? "",
      ]
      .contains(where: { $0.lowercased().contains(query) })
    {
      return false
    }
    if !statusFilter.matches(job) { return false }
    if !modeFilter.matches(job.executionMode) { return false }
    if sessionFilter != Self.allSessions, job.sessionID != sessionFilter { return false }
    if targetFilter != Self.allTargets, job.targetID != targetFilter { return false }
    if !timeFilter.matches(historyDate(job)) { return false }
    return true
  }

  private func resetFilters() {
    searchText = ""
    statusFilter = .all
    modeFilter = .all
    sessionFilter = Self.allSessions
    targetFilter = Self.allTargets
    timeFilter = .anyTime
    activityFilter = .all
  }

  private func activityCount(_ filter: HistoryActivityFilter) -> Int {
    presentation.jobs.filter {
      filter == .all || filter == activityCategory(for: $0)
    }.count
  }

  private func activityCategory(
    for job: RuntimeJobSummaryPresentation
  ) -> HistoryActivityFilter {
    let workspaceKind = job.resolvedWorkspaceKind
      ?? detailsByJobID[job.id]?.evidence.flatMap {
        RuntimeWorkspaceKindProjection.kind(
          forOperation: job.operationReference,
          parameters: $0.parameters)
      }
    return HistoryActivityFilter(workspaceKind: workspaceKind)
  }

  private func saveCurrentFilter() {
    savedSearchText = searchText
    savedStatus = statusFilter.rawValue
    savedMode = modeFilter.rawValue
    savedSession = sessionFilter
    savedTarget = targetFilter
    savedTime = timeFilter.rawValue
    savedActivity = activityFilter.rawValue
    hasSavedFilter = true
  }

  private func applySavedFilter() {
    searchText = savedSearchText
    statusFilter = HistoryStatusFilter(rawValue: savedStatus) ?? .all
    modeFilter = HistoryModeFilter(rawValue: savedMode) ?? .all
    sessionFilter = sessions.contains(savedSession) ? savedSession : Self.allSessions
    targetFilter = targets.contains(savedTarget) ? savedTarget : Self.allTargets
    timeFilter = HistoryTimeFilter(rawValue: savedTime) ?? .anyTime
    activityFilter = savedActivity == "toolkit"
      ? .device : HistoryActivityFilter(rawValue: savedActivity) ?? .all
  }

  private func historyDate(_ job: RuntimeJobSummaryPresentation) -> Date? {
    job.activityDate
  }

  private static func parseUTC(_ value: String?) -> Date? {
    guard let value else { return nil }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }

  private func formattedUTC(_ value: String?) -> String {
    guard let date = Self.parseUTC(value) else { return value ?? "—" }
    return formattedDate(date)
  }

  private func formattedDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private func localizedState(_ rawState: String) -> String {
    guard let state = JobState(rawValue: rawState) else { return rawState }
    return historyLocalized("history.state.\(state.rawValue)")
  }

  private func historyExecutionModeBadge(_ mode: String?) -> RuntimeExecutionModeBadge? {
    RuntimeExecutionModeBadge(mode)
  }

  // "· 结果未知" carries the whole weight of an unknown outcome: interrupted
  // with an unknown outcome is not a red variant of failed — failure is a
  // known result, unknown is the absence of one.
  private func historyStateLabel(_ job: RuntimeJobSummaryPresentation) -> some View {
    Label {
      Text(
        job.outcomeUnknown
          ? localizedState(job.state) + historyLocalized("history.state.outcomeUnknownSuffix")
          : localizedState(job.state))
    } icon: {
      Image(systemName: stateSymbol(job))
        .foregroundStyle(stateColor(job))
        .accessibilityHidden(true)
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
    // Unknown is warn, not danger: red is reserved for a *known* failure,
    // and painting unknown the same hue erases exactly that distinction.
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

/// The destination workspace's proof that it is showing an immutable History
/// record rather than silently treating that record as a new request.
struct HistoryWorkspaceContextBanner: View {
  let context: RuntimeHistoryWorkspaceContext
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        Label(historyLocalized("history.context.title"), systemImage: "clock.arrow.circlepath")
          .font(WorkspaceFont.body.weight(.semibold))
        Spacer(minLength: WorkspaceMetrics.contentGap)
        Button(action: onDismiss) {
          Label(historyLocalized("history.context.dismiss"), systemImage: "xmark")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(historyLocalized("history.context.dismiss"))
        .accessibilityIdentifier("history.context.dismiss")
      }

      Text(historyLocalized("history.context.readOnly"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.blockGap) {
          contextFact("history.context.job", value: context.jobID, id: "history.context.job")
          contextFact(
            "history.context.target", value: context.targetID, id: "history.context.target")
          contextFact(
            "history.context.operation", value: context.operationReference,
            id: "history.context.operation")
          contextFact("history.context.state", value: context.state, id: "history.context.state")
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          contextFact("history.context.job", value: context.jobID, id: "history.context.job")
          contextFact(
            "history.context.target", value: context.targetID, id: "history.context.target")
          contextFact(
            "history.context.operation", value: context.operationReference,
            id: "history.context.operation")
          contextFact("history.context.state", value: context.state, id: "history.context.state")
        }
      }

      if !context.artifacts.isEmpty {
        LabeledContent(historyLocalized("history.context.artifacts")) {
          Text(context.artifacts.map(\.name).joined(separator: ", "))
            .font(WorkspaceFont.monospacedDense)
            .lineLimit(2)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("history.context.artifacts")
      }
    }
    .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08))
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history.context")
  }

  private func contextFact(_ key: String, value: String, id: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
      Text(historyLocalized(key))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(value)
        .font(WorkspaceFont.monospacedDense)
        .lineLimit(1)
        .textSelection(.enabled)
        .accessibilityLabel(Text("\(historyLocalized(key)): \(value)"))
        .accessibilityIdentifier(id)
    }
  }
}

private enum HistoryActivityFilter: String, CaseIterable, Identifiable {
  case all
  case flash
  case viewer
  case trace
  case diagnostics
  case debug
  case device
  case other

  init(workspaceKind: RuntimeWorkspaceKind?) {
    switch workspaceKind {
    case .flash: self = .flash
    case .viewer: self = .viewer
    case .trace: self = .trace
    case .diagnostics: self = .diagnostics
    case .debug: self = .debug
    case .device: self = .device
    case nil: self = .other
    }
  }

  var id: String { rawValue }
  var localizationKey: String { "history.activity.\(rawValue)" }

  var systemImage: String {
    switch self {
    case .all: "clock.arrow.circlepath"
    case .flash: "bolt"
    case .viewer: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .diagnostics: "waveform.path"
    case .debug: "terminal"
    case .device: "iphone"
    case .other: "ellipsis.circle"
    }
  }

  var destination: RuntimeWorkspaceKind? {
    switch self {
    case .all: nil
    case .flash: .flash
    case .viewer: .viewer
    case .trace: .trace
    case .diagnostics: .diagnostics
    case .debug: .debug
    case .device: .device
    case .other: nil
    }
  }

  var openActionLocalizationKey: String { "history.activity.open.\(rawValue)" }
}

private enum HistoryStatusFilter: String, CaseIterable, Identifiable {
  case all
  case active
  case needsAttention
  case succeeded
  case failed
  case interrupted
  case cancelled

  var id: String { rawValue }
  var localizationKey: String { "history.filter.status.\(rawValue)" }

  func matches(_ job: RuntimeJobSummaryPresentation) -> Bool {
    switch self {
    case .all: return true
    case .active:
      guard let state = JobState(rawValue: job.state) else { return false }
      return !state.isTerminal
    case .needsAttention: return job.needsAttention || job.outstandingResidueCount > 0
    case .succeeded: return job.state == JobState.succeeded.rawValue
    case .failed: return job.state == JobState.failed.rawValue
    case .interrupted: return job.state == JobState.interrupted.rawValue
    case .cancelled: return job.state == JobState.cancelled.rawValue
    }
  }
}

private enum HistoryModeFilter: String, CaseIterable, Identifiable {
  case all
  case execute
  case planned
  case simulated
  case unknown

  var id: String { rawValue }
  var localizationKey: String { "history.filter.mode.\(rawValue)" }

  func matches(_ mode: String?) -> Bool {
    switch self {
    case .all: return true
    case .execute: return mode == "execute"
    case .planned: return mode == "planOnly" || mode == "planned"
    case .simulated: return mode == "simulated"
    case .unknown: return mode == nil
    }
  }
}

private enum HistoryTimeFilter: String, CaseIterable, Identifiable {
  case anyTime
  case lastHour
  case lastDay
  case lastWeek

  var id: String { rawValue }
  var localizationKey: String { "history.filter.time.\(rawValue)" }

  func matches(_ date: Date?) -> Bool {
    guard self != .anyTime else { return true }
    guard let date else { return false }
    let interval: TimeInterval
    switch self {
    case .anyTime: return true
    case .lastHour: interval = 60 * 60
    case .lastDay: interval = 24 * 60 * 60
    case .lastWeek: interval = 7 * 24 * 60 * 60
    }
    return date >= Date().addingTimeInterval(-interval)
  }
}

/// Bridges the App to two read-only domain readers. Detail requests are keyed
/// by Job ID and ignored if the Job disappears during a concurrent refresh.
@MainActor
@Observable
final class RuntimeHistoryViewModel {
  private(set) var presentation: RuntimeHistoryPresentation = .loading
  private(set) var detailsByJobID: [String: RuntimeJobDetailPresentation] = [:]
  private(set) var loadingDetailJobIDs: Set<String> = []
  private(set) var exportStatesByArtifactID: [String: RuntimeArtifactExportState] = [:]
  private(set) var isRefreshInFlight = false
  private(set) var isLoadOlderInFlight = false
  private let provider: any RuntimeHistoryApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding
  @ObservationIgnored private var historyGeneration = 0
  @ObservationIgnored private var detailGeneration = 0
  @ObservationIgnored private var detailRequestIDs: [String: UUID] = [:]

  init(
    provider: any RuntimeHistoryApplicationProviding,
    detailProvider: any RuntimeJobDetailApplicationProviding
  ) {
    self.provider = provider
    self.detailProvider = detailProvider
  }

  /// Whether any listed job is still in a non-terminal state. Settings uses
  /// this to escalate its "switching affects only new Jobs" sentence while
  /// it is actually true of something.
  var hasActiveJobs: Bool {
    presentation.jobs.contains { job in
      guard let state = JobState(rawValue: job.state) else { return false }
      return !state.isTerminal
    }
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    historyGeneration &+= 1
    let generation = historyGeneration
    // Refresh supersedes any older-page read, including its loading state.
    // That read may still finish, but must not clear a newer page's spinner.
    isLoadOlderInFlight = false
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshHistory()
      guard let self, self.historyGeneration == generation else { return }
      defer { self.isRefreshInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
      self.detailGeneration &+= 1
      self.detailsByJobID = [:]
      self.loadingDetailJobIDs = []
      self.detailRequestIDs = [:]
    }
  }

  func loadOlder() {
    guard !isRefreshInFlight, !isLoadOlderInFlight, presentation.hasOlderJobs else { return }
    isLoadOlderInFlight = true
    let generation = historyGeneration
    let provider = provider
    Task { [weak self] in
      guard self?.historyGeneration == generation else { return }
      let next = await provider.loadOlderHistory()
      guard let self, self.historyGeneration == generation else { return }
      defer { self.isLoadOlderInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
      let validJobIDs = Set(next.jobs.map(\.id))
      self.detailsByJobID = self.detailsByJobID.filter { validJobIDs.contains($0.key) }
      self.loadingDetailJobIDs.formIntersection(validJobIDs)
      self.detailRequestIDs = self.detailRequestIDs.filter { validJobIDs.contains($0.key) }
    }
  }

  func loadDetail(jobID: String, operationReference: String) {
    guard detailsByJobID[jobID] == nil, loadingDetailJobIDs.insert(jobID).inserted else {
      return
    }
    let detailProvider = detailProvider
    let generation = detailGeneration
    let requestID = UUID()
    detailRequestIDs[jobID] = requestID
    Task { [weak self] in
      let detail = await detailProvider.loadJobDetail(
        jobID: jobID,
        operationReference: operationReference)
      guard let self,
        self.detailGeneration == generation,
        self.detailRequestIDs[jobID] == requestID
      else { return }
      self.detailRequestIDs.removeValue(forKey: jobID)
      self.loadingDetailJobIDs.remove(jobID)
      guard !Task.isCancelled,
        self.presentation.jobs.contains(where: { $0.id == jobID })
      else { return }
      self.detailsByJobID[jobID] = detail
    }
  }

  func reloadDetail(jobID: String, operationReference: String) {
    detailsByJobID.removeValue(forKey: jobID)
    loadingDetailJobIDs.remove(jobID)
    detailRequestIDs.removeValue(forKey: jobID)
    loadDetail(jobID: jobID, operationReference: operationReference)
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
}

enum RuntimeArtifactExportState: Equatable {
  case exporting
  case completed(URL)
  case failed(String)
}

/// UI label only. Durable history keeps the exact old reference for detail
/// loading/export, while the product surface presents DAYU200 as one
/// singleton operation without reviving retired version choices.
func displayedOperationReference(_ reference: String) -> String {
  reference.hasPrefix("flash.dayu200@") ? "flash.dayu200" : reference
}

/// A permanent outline marker for a job's execution mode, shared by History
/// and the job inspector: PLANNED wears a purple outline, SIMULATED an
/// orange dashed outline — the same vocabulary as the Flash mode badge, so
/// the same job reads the same everywhere. Execute renders no badge at all;
/// an unrecognized mode falls back to neutral uppercase text rather than
/// guessing a color semantics for it.
struct RuntimeExecutionModeBadge: View {
  private let text: String
  private let tone: WorkspaceTone
  private let dashed: Bool

  init?(_ mode: String?) {
    switch mode {
    case nil, JobExecutionMode.execute.rawValue:
      return nil
    case JobExecutionMode.planOnly.rawValue:
      text = "PLANNED"
      tone = .planned
      dashed = false
    case "simulated":
      text = "SIMULATED"
      tone = .simulated
      dashed = true
    case let other?:
      text = other.uppercased()
      tone = .neutral
      dashed = false
    }
  }

  var body: some View {
    // The one chip shape in the App. Permanent, outline-only, and never a
    // filled control the user could mistake for something pressable
    // (spec §4.4).
    WorkspaceChip(text: Text(text), tone: tone, isDashed: dashed)
      .accessibilityLabel(text)
  }
}
