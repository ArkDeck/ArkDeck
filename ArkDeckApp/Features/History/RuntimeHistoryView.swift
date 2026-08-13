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
  let onExportArtifact: ((String, RuntimeArtifactPresentation, URL, Bool) -> Void)?

  @State private var selectedJobID: RuntimeJobSummaryPresentation.ID?
  @State private var searchText = ""
  @State private var statusFilter = HistoryStatusFilter.all
  @State private var modeFilter = HistoryModeFilter.all
  @State private var sessionFilter = Self.allSessions
  @State private var targetFilter = Self.allTargets
  @State private var timeFilter = HistoryTimeFilter.anyTime
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
    .onChange(of: selectedJobID, initial: true) { _, jobID in
      guard let jobID,
        let job = presentation.jobs.first(where: { $0.id == jobID })
      else { return }
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
          format: historyLocalized("history.artifacts.exportPreview.message"),
          artifact.name,
          ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file),
          artifact.privacy,
          artifact.sha256))
    }
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
      VStack(spacing: 8) {
        Text(reason)
          .font(.callout.monospaced())
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
        if workspace.size.width >= 860 {
          HSplitView {
            filterSidebar
              .frame(minWidth: 190, idealWidth: 210, maxWidth: 240, maxHeight: .infinity)
            jobTable
              .frame(minWidth: 360, idealWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
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
      VStack(alignment: .leading, spacing: 16) {
        Text(historyLocalized("history.filter.title"))
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        TextField(historyLocalized("history.filter.search"), text: $searchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("history.filter.search")
        filterPickers
        filterResultSummary
        Button(historyLocalized("history.filter.reset"), action: resetFilters)
          .accessibilityIdentifier("history.filter.reset")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .background(.quaternary.opacity(0.18))
  }

  private var compactFilters: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        TextField(historyLocalized("history.filter.search"), text: $searchText)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 180)
        filterPickers
        filterResultSummary
      }
      VStack(alignment: .leading, spacing: 10) {
        TextField(historyLocalized("history.filter.search"), text: $searchText)
          .textFieldStyle(.roundedBorder)
        filterPickers
        filterResultSummary
      }
    }
    .padding(12)
  }

  private var filterPickers: some View {
    Group {
      Picker(historyLocalized("history.filter.status"), selection: $statusFilter) {
        ForEach(HistoryStatusFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      Picker(historyLocalized("history.filter.mode"), selection: $modeFilter) {
        ForEach(HistoryModeFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
      Picker(historyLocalized("history.filter.session"), selection: $sessionFilter) {
        Text(historyLocalized("history.filter.session.all")).tag(Self.allSessions)
        ForEach(sessions, id: \.self) { session in
          Text(session).font(.body.monospaced()).tag(session)
        }
      }
      Picker(historyLocalized("history.filter.device"), selection: $targetFilter) {
        Text(historyLocalized("history.filter.device.all")).tag(Self.allTargets)
        ForEach(targets, id: \.self) { target in
          Text(target).font(.body.monospaced()).tag(target)
        }
      }
      Picker(historyLocalized("history.filter.time"), selection: $timeFilter) {
        ForEach(HistoryTimeFilter.allCases) { filter in
          Text(historyLocalized(filter.localizationKey)).tag(filter)
        }
      }
    }
    .labelsHidden()
  }

  private var filterResultSummary: some View {
    Text(
      String(
        format: historyLocalized("history.filter.resultCount"),
        filteredJobs.count,
        presentation.jobs.count)
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .accessibilityIdentifier("history.filter.resultCount")
  }

  private var savedFilterMenu: some View {
    Menu(historyLocalized("history.filter.saved")) {
      Button(historyLocalized("history.filter.save"), action: saveCurrentFilter)
      if hasSavedFilter {
        Button(historyLocalized("history.filter.applySaved"), action: applySavedFilter)
        Button(historyLocalized("history.filter.deleteSaved"), role: .destructive) {
          hasSavedFilter = false
        }
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
        Table(filteredJobs, selection: $selectedJobID) {
          TableColumn(historyLocalized("history.column.job")) { job in
            VStack(alignment: .leading, spacing: 2) {
              Text(job.id)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
              if let sessionID = job.sessionID {
                Text(sessionID)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          }
          .width(min: 110, ideal: 140)
          TableColumn(historyLocalized("history.column.state")) { job in
            historyStateLabel(job)
              .accessibilityIdentifier("history.row.state.\(job.id)")
          }
          .width(min: 105, ideal: 125)
          TableColumn(historyLocalized("history.column.operation")) { job in
            VStack(alignment: .leading, spacing: 2) {
              Text(displayedOperationReference(job.operationReference))
                .font(.body.monospaced())
                .lineLimit(1)
              if let badge = historyExecutionModeBadge(job.executionMode) {
                badge
              }
            }
          }
          .width(min: 160, ideal: 210)
          TableColumn(historyLocalized("history.column.target")) { job in
            Text(job.targetID)
              .font(.body.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .width(min: 120, ideal: 160)
          TableColumn(historyLocalized("history.column.time")) { job in
            Text(formattedDate(historyDate(job)))
              .font(.callout)
              .monospacedDigit()
          }
          .width(min: 120, ideal: 160)
        }
        .accessibilityIdentifier("history.table")
      }
      Divider()
      if presentation.hasOlderJobs || presentation.olderJobsLoadFailure != nil {
        VStack(alignment: .leading, spacing: 6) {
          if let failure = presentation.olderJobsLoadFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
              .font(.footnote)
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
      }
      Text(historyLocalized("history.readOnlyNote"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history.readOnlyNote")
        .padding(12)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let job = selectedJob {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          detailHeader(job)
          summarySection(job)
          timelineSection(job)
          evidenceSections(job)
          recoverySection(job)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
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
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
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
    }
  }

  private func summarySection(_ job: RuntimeJobSummaryPresentation) -> some View {
    historySection("history.detail.summary") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
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
          HStack(spacing: 6) {
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
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if job.outstandingResidueCount > 0 {
        Label(
          String(
            format: historyLocalized("history.detail.residue"),
            job.outstandingResidueCount),
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
        VStack(alignment: .leading, spacing: 7) {
          ForEach(Array(timeline.enumerated()), id: \.offset) { index, entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(
                systemName: index == timeline.count - 1 ? stateSymbol(job) : "checkmark.circle"
              )
              .foregroundStyle(index == timeline.count - 1 ? stateColor(job) : .secondary)
              .accessibilityHidden(true)
              Text(entry)
                .font(.callout.monospaced())
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
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
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
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .accessibilityIdentifier("history.evidence.steps")
          }
          ForEach(evidence.blockers, id: \.self) { blocker in
            Label(blocker, systemImage: "exclamationmark.triangle")
              .font(.callout.monospaced())
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
                .font(.caption.weight(.semibold))
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
          .font(.caption.monospaced())
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
    .frame(minHeight: 250, idealHeight: 300)
    .accessibilityIdentifier("history.parameters.traceDiff")
  }

  private func typedParameterGrid(
    _ parameters: [RuntimeJobParameterPresentation]
  ) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
      ForEach(parameters) { parameter in
        GridRow(alignment: .firstTextBaseline) {
          Text(parameter.name).font(.callout.monospaced())
          Text(parameter.value)
            .font(.callout.monospaced())
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
      .font(.caption.monospaced())
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
      .font(.caption.weight(.semibold))
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
          VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.artifacts) { artifact in
              artifactRow(artifact, jobID: job.id)
            }
          }
          .accessibilityIdentifier("history.artifacts")
        }
        Label(historyLocalized("history.artifacts.exportBoundary"), systemImage: "lock.doc")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func artifactRow(
    _ artifact: RuntimeArtifactPresentation,
    jobID: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(artifact.name).font(.callout.monospaced().weight(.semibold))
          Spacer(minLength: 8)
          artifactStatus(artifact)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(artifact.name).font(.callout.monospaced().weight(.semibold))
          artifactStatus(artifact)
        }
      }
      Text(
        "\(artifact.role ?? "—") · \(artifact.sourceOperation) · "
          + ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file)
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(artifact.sha256)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .help(artifact.sha256)
        .textSelection(.enabled)
      Text("\(artifact.privacy) · \(artifact.mediaType)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let statusDetail = artifact.statusDetail {
        Label(statusDetail, systemImage: "exclamationmark.triangle")
          .font(.caption.monospaced())
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      HStack(spacing: 8) {
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
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history.artifact.exportFailure.\(artifact.id)")
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
    .font(.caption.weight(.semibold))
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
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func historySection<Content: View>(
    _ titleKey: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(historyLocalized(titleKey))
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func unavailableSection(_ reason: String) -> some View {
    Label {
      Text(reason)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle")
    }
    .foregroundStyle(.orange)
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
  }

  private func saveCurrentFilter() {
    savedSearchText = searchText
    savedStatus = statusFilter.rawValue
    savedMode = modeFilter.rawValue
    savedSession = sessionFilter
    savedTarget = targetFilter
    savedTime = timeFilter.rawValue
    hasSavedFilter = true
  }

  private func applySavedFilter() {
    searchText = savedSearchText
    statusFilter = HistoryStatusFilter(rawValue: savedStatus) ?? .all
    modeFilter = HistoryModeFilter(rawValue: savedMode) ?? .all
    sessionFilter = sessions.contains(savedSession) ? savedSession : Self.allSessions
    targetFilter = targets.contains(savedTarget) ? savedTarget : Self.allTargets
    timeFilter = HistoryTimeFilter(rawValue: savedTime) ?? .anyTime
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
      Image(systemName: stateSymbol(job)).accessibilityHidden(true)
    }
    .foregroundStyle(stateColor(job))
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
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshHistory()
      guard let self else { return }
      defer { self.isRefreshInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
      let validJobIDs = Set(next.jobs.map(\.id))
      self.detailsByJobID = self.detailsByJobID.filter { validJobIDs.contains($0.key) }
      self.loadingDetailJobIDs.formIntersection(validJobIDs)
    }
  }

  func loadOlder() {
    guard !isRefreshInFlight, !isLoadOlderInFlight, presentation.hasOlderJobs else { return }
    isLoadOlderInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.loadOlderHistory()
      guard let self else { return }
      defer { self.isLoadOlderInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
      let validJobIDs = Set(next.jobs.map(\.id))
      self.detailsByJobID = self.detailsByJobID.filter { validJobIDs.contains($0.key) }
      self.loadingDetailJobIDs.formIntersection(validJobIDs)
    }
  }

  func loadDetail(jobID: String, operationReference: String) {
    guard detailsByJobID[jobID] == nil, loadingDetailJobIDs.insert(jobID).inserted else {
      return
    }
    let detailProvider = detailProvider
    Task { [weak self] in
      let detail = await detailProvider.loadJobDetail(
        jobID: jobID,
        operationReference: operationReference)
      guard let self else { return }
      self.loadingDetailJobIDs.remove(jobID)
      guard !Task.isCancelled,
        self.presentation.jobs.contains(where: { $0.id == jobID })
      else { return }
      self.detailsByJobID[jobID] = detail
    }
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
  private let color: Color
  private let dashed: Bool

  init?(_ mode: String?) {
    switch mode {
    case nil, JobExecutionMode.execute.rawValue:
      return nil
    case JobExecutionMode.planOnly.rawValue:
      text = "PLANNED"
      color = .purple
      dashed = false
    case "simulated":
      text = "SIMULATED"
      color = .orange
      dashed = true
    case let other?:
      text = other.uppercased()
      color = .secondary
      dashed = false
    }
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
      }
      .accessibilityLabel(text)
  }
}
