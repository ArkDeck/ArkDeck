import ArkDeckCore
import ArkDeckWorkflows
import Observation
import SwiftUI

enum OverviewRemoteServerPresentation: Equatable {
  case loading
  case unbound
  case bound(RemoteBuildSourcePresentation)
  case stale
  case unavailable(String)
}

/// Resolves only an explicit target-to-source binding. A configured source,
/// recent source, or first source is never treated as the target's server.
@MainActor
@Observable
final class OverviewRemoteServerViewModel {
  private(set) var presentation: OverviewRemoteServerPresentation = .loading

  private let sources: any RemoteBuildSourceProviding
  private let bindings: any RemoteBuildSourceBindingProviding
  private var generation = 0

  init(
    sources: any RemoteBuildSourceProviding = RemoteBuildSourceApplicationFacade.make(),
    bindings: any RemoteBuildSourceBindingProviding =
      RemoteBuildSourceBindingApplicationFacade.make()
  ) {
    self.sources = sources
    self.bindings = bindings
  }

  func load(targetID: String?) {
    generation += 1
    let currentGeneration = generation
    guard let targetID else {
      presentation = .unbound
      return
    }
    presentation = .loading
    let sources = sources
    let bindings = bindings
    Task { [weak self] in
      do {
        async let availableSources = sources.listSources()
        async let targetBinding = bindings.binding(forTargetID: targetID)
        let (allSources, binding) = try await (availableSources, targetBinding)
        guard let self, currentGeneration == self.generation else { return }
        guard let binding else {
          self.presentation = .unbound
          return
        }
        guard let source = allSources.first(where: { $0.id == binding.sourceID }) else {
          self.presentation = .stale
          return
        }
        self.presentation = .bound(source)
      } catch {
        guard let self, currentGeneration == self.generation else { return }
        self.presentation = .unavailable(error.localizedDescription)
      }
    }
  }
}

/// Overview answers three questions in order: what target is in scope, what
/// deserves attention next, and what just happened. New-work shortcuts stay
/// in the sidebar; the complete archive stays in History.
struct OverviewRecordView: View {
  let devices: DeviceListPresentation
  let capabilities: OverviewCapabilityMatrixPresentation
  let remoteServer: OverviewRemoteServerPresentation
  let history: RuntimeHistoryPresentation
  let detailsByJobID: [String: RuntimeJobDetailPresentation]
  let onSelectTarget: (String?) -> Void
  let onOpenHistory: () -> Void
  let onOpenJob: (String) -> Void
  let onResume: (RuntimeJobSummaryPresentation) -> Void

  @State private var expandedThreadIDs: Set<String> = []

  private var threads: [OverviewRunThread] {
    OverviewRunRecordProjection.threads(from: history.jobs)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
      deviceBar
      nextStepSection
      recordSection
    }
  }

  // MARK: - Scope

  private var deviceBar: some View {
    WorkspaceCard {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: WorkspaceMetrics.sectionGap) {
          deviceScope
          Divider().frame(minHeight: 46)
          remoteServerScope
            .frame(maxWidth: 410, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          deviceScope
          Divider()
          remoteServerScope
        }
      }
    }
  }

  private var deviceScope: some View {
    HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: "iphone.gen3")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text("overview.record.device.label")
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        if capabilities.adoptedTargets.count > 1 {
          targetPicker
        } else {
          Text(boundDeviceName)
            .font(WorkspaceFont.body.weight(.semibold))
            .accessibilityIdentifier("overview.record.device.name")
        }
        Text(boundDeviceFacts)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.record.device.facts")
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var targetPicker: some View {
    Picker(
      selection: Binding(
        get: { capabilities.targetID },
        set: { onSelectTarget($0) })
    ) {
      if capabilities.targetID == nil {
        Text("overview.record.device.choose").tag(String?.none)
      }
      // The view model projects this list from the current authorized device
      // observation. Historical adopted targets stay in History, not here.
      ForEach(capabilities.adoptedTargets) { target in
        Text(displayName(for: target.id)).tag(String?.some(target.id))
      }
    } label: {
      Text("overview.record.device.label")
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("overview.record.device.picker")
  }

  private var remoteServerScope: some View {
    HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: "server.rack")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text("overview.record.remoteServer.label")
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        remoteServerContent
      }
      .accessibilityIdentifier("overview.record.remoteServer")
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var remoteServerContent: some View {
    switch remoteServer {
    case .loading:
      HStack(spacing: WorkspaceMetrics.tightGap) {
        ProgressView().controlSize(.small)
        Text("overview.record.remoteServer.loading")
          .foregroundStyle(.secondary)
      }
    case .unbound:
      Text("overview.record.remoteServer.unbound")
        .font(WorkspaceFont.body.weight(.semibold))
      Text("overview.record.remoteServer.unboundDetail")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
    case .bound(let source):
      HStack(spacing: WorkspaceMetrics.tightGap) {
        Text(source.name).font(WorkspaceFont.body.weight(.semibold))
        WorkspaceChip(
          text: Text("overview.record.remoteServer.bound"), tone: .ok,
          symbol: "link")
      }
      Text(source.endpoint)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityIdentifier("overview.record.remoteServer.endpoint")
    case .stale:
      Text("overview.record.remoteServer.stale")
        .font(WorkspaceFont.body.weight(.semibold))
      Text("overview.record.remoteServer.staleDetail")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
    case .unavailable(let reason):
      Text("overview.record.remoteServer.unavailable")
        .font(WorkspaceFont.body.weight(.semibold))
      Text(reason)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private func displayName(for targetID: String) -> String {
    guard
      let candidate = devices.candidates.first(where: { $0.adoptedTargetID == targetID }),
      let name = candidate.deviceInformation?.name ?? candidate.observedFacts?.model,
      !name.isEmpty
    else { return targetID }
    return "\(name) · \(targetID)"
  }

  private var boundCandidate: DeviceCandidatePresentation? {
    guard let targetID = capabilities.targetID else { return nil }
    return devices.candidates.first { $0.adoptedTargetID == targetID }
  }

  private var boundDeviceName: String {
    guard let targetID = capabilities.targetID else {
      return String(localized: "overview.record.device.none")
    }
    if let candidate = boundCandidate,
      let name = candidate.deviceInformation?.name ?? candidate.observedFacts?.model,
      !name.isEmpty
    {
      return name
    }
    return targetID
  }

  private var boundDeviceFacts: String {
    guard let targetID = capabilities.targetID else {
      return String(localized: "overview.record.device.noneDetail")
    }
    var parts = [targetID]
    if let revision = capabilities.bindingRevision {
      parts.append(String(localized: .overviewRecordBinding(revision)))
    }
    if let candidate = boundCandidate {
      let facts = [
        candidate.observedFacts?.model,
        candidate.deviceInformation?.systemVersion ?? candidate.observedFacts?.firmware,
        candidate.deviceInformation?.transport ?? candidate.observedFacts?.transport,
      ].compactMap { $0 }.filter { !$0.isEmpty }
      parts.append(contentsOf: facts)
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Next step

  private var nextStepSection: some View {
    WorkspaceSection(
      Text("overview.record.next.title"), identifier: "overview.record.next"
    ) {
      WorkspaceCard {
        if let thread = threads.first, let run = featuredRun(in: thread) {
          nextStep(for: run, in: thread)
        } else {
          HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
            Image(systemName: "arrow.left")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
              Text("overview.record.next.empty.title")
                .font(WorkspaceFont.body.weight(.semibold))
              Text("overview.record.next.empty.detail")
                .font(WorkspaceFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityIdentifier("overview.record.next.empty")
        }
      }
    }
  }

  private func nextStep(
    for run: RuntimeJobSummaryPresentation, in thread: OverviewRunThread
  ) -> some View {
    let disposition = resumeDisposition(for: run)
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkspaceMetrics.sectionGap) {
        nextStepSummary(for: run, in: thread)
        Spacer(minLength: WorkspaceMetrics.contentGap)
        nextStepActions(for: run, disposition: disposition)
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        nextStepSummary(for: run, in: thread)
        nextStepActions(for: run, disposition: disposition)
      }
    }
    .accessibilityIdentifier("overview.record.next.\(run.id)")
  }

  private func nextStepSummary(
    for run: RuntimeJobSummaryPresentation, in thread: OverviewRunThread
  ) -> some View {
    HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(
        systemName: run.needsAttention
          ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath"
      )
      .foregroundStyle(run.needsAttention ? WorkspaceTone.warning.color : Color.accentColor)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          if run.needsAttention {
            Text("overview.record.next.attention")
          } else {
            Text(workspaceTitle(for: run))
          }
          if !run.needsAttention {
            WorkspaceChip(
              text: Text(LocalizedStringKey(stateLabelKey(for: run))),
              tone: stateTone(run))
          }
        }
        .font(WorkspaceFont.sectionTitle)
        if run.needsAttention {
          Text(workspaceTitle(for: run))
            .font(WorkspaceFont.body.weight(.semibold))
        }
        Text(nextStepDetail(for: run, in: thread))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("\(run.targetID) · \(displayedOperation(run.operationReference))")
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func nextStepActions(
    for run: RuntimeJobSummaryPresentation,
    disposition: OverviewRunResumeDisposition
  ) -> some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      Button("overview.record.run.open") { onOpenJob(run.id) }
        .accessibilityIdentifier("overview.record.next.open")
      switch disposition {
      case .resumable:
        Button("overview.record.run.again") { onResume(run) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("overview.record.next.again")
      case .requiresAuthorization:
        Button("overview.record.run.againGated") { onResume(run) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("overview.record.next.again")
      case .detailNotLoaded:
        ProgressView().controlSize(.small)
      case .neverReplayed, .notTerminal, .effectUnknown, .parametersNotReported:
        EmptyView()
      }
    }
  }

  private func nextStepDetail(
    for run: RuntimeJobSummaryPresentation, in thread: OverviewRunThread
  ) -> String {
    if run.outcomeUnknown, !run.hasEstablishedCurrentEpoch {
      return String(localized: "overview.record.next.unknownDetail")
    }
    if run.waitingForHuman {
      return String(localized: "overview.record.next.waitingDetail")
    }
    if run.outstandingResidueCount > 0 {
      return String(
        localized: .overviewRecordNextResidueDetail(run.outstandingResidueCount))
    }
    return String(
      localized: .overviewRecordNextRecentDetail(thread.runs.count, runOutcome(run)))
  }

  // MARK: - Recent work

  @ViewBuilder
  private var recordSection: some View {
    WorkspaceSection(
      Text("overview.record.recent.title"),
      identifier: "overview.record.recent",
      accessory: {
        Button("overview.record.recent.all", action: onOpenHistory)
          .buttonStyle(.link)
          .accessibilityIdentifier("overview.record.recent.all")
      }
    ) {
      switch history.availability {
      case .loading:
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text("overview.record.recent.title"))
      case .unavailable(let reason):
        WorkspaceNotice(tone: .warning, identifier: "overview.record.recent.unavailable") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text("overview.record.recent.unavailable.title")
              .font(WorkspaceFont.body.weight(.semibold))
            Text(reason).font(WorkspaceFont.monospacedDense)
          }
        }
      case .available where threads.isEmpty:
        Text("overview.record.recent.empty")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("overview.record.empty")
      case .available:
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          ForEach(threads) { thread in
            threadCard(thread)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func threadCard(_ thread: OverviewRunThread) -> some View {
    if let featured = featuredRun(in: thread) {
      let otherRuns = additionalRuns(in: thread, excluding: featured)
      VStack(alignment: .leading, spacing: 0) {
        threadHeader(thread, featured: featured)
        Divider()
        runRow(featured)
        if !otherRuns.isEmpty {
          Divider()
          DisclosureGroup(
            isExpanded: expandedBinding(for: thread.id)
          ) {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(otherRuns.enumerated()), id: \.element.id) { index, run in
                if index > 0 { Divider() }
                runRow(run)
              }
            }
            .padding(.top, WorkspaceMetrics.tightGap)
          } label: {
            Text(String(localized: .overviewRecordThreadMore(otherRuns.count)))
              .font(WorkspaceFont.secondary.weight(.medium))
          }
          .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
          .padding(.vertical, WorkspaceMetrics.tightGap)
          .accessibilityIdentifier("overview.record.thread.\(thread.id).more")
        }
      }
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
          .stroke(
            thread.needsAttention ? WorkspaceTone.warning.color : Color(nsColor: .separatorColor),
            lineWidth: 1)
      }
    }
  }

  private func threadHeader(
    _ thread: OverviewRunThread, featured: RuntimeJobSummaryPresentation
  ) -> some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: symbol(for: featured))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(workspaceTitle(for: featured))
          .font(WorkspaceFont.body.weight(.semibold))
        Text(threadSubtitle(thread))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .accessibilityIdentifier("overview.record.thread.\(thread.id)")
      Spacer(minLength: 0)
      if thread.needsAttention {
        WorkspaceChip(
          text: Text("overview.record.thread.needsAttention"),
          tone: .warning,
          identifier: "overview.record.thread.\(thread.id).needsAttention")
      }
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
  }

  private func threadSubtitle(_ thread: OverviewRunThread) -> String {
    [thread.targetID, String(localized: .overviewRecordRunCount(thread.runs.count))]
      .joined(separator: " · ")
  }

  private func runRow(_ run: RuntimeJobSummaryPresentation) -> some View {
    let disposition = resumeDisposition(for: run)
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkspaceMetrics.contentGap) {
        runIdentity(run)
        Spacer(minLength: WorkspaceMetrics.contentGap)
        Text(runOutcome(run))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("overview.record.run.\(run.id).outcome")
        runActions(run, disposition: disposition)
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        runIdentity(run)
        Text(runOutcome(run))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("overview.record.run.\(run.id).outcome")
        runActions(run, disposition: disposition)
      }
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.rowGap + 2)
  }

  private func runIdentity(_ run: RuntimeJobSummaryPresentation) -> some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: stateTone(run).symbol)
        .foregroundStyle(stateTone(run).color)
        .accessibilityHidden(true)
      Text(run.id)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("overview.record.run.\(run.id)")
      if let effect = run.actualEffect { effectChip(effect) }
    }
  }

  private func runActions(
    _ run: RuntimeJobSummaryPresentation,
    disposition: OverviewRunResumeDisposition
  ) -> some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      resumeControl(run, disposition: disposition)
      Button("overview.record.run.open") { onOpenJob(run.id) }
        .buttonStyle(.link)
        .accessibilityIdentifier("overview.record.run.\(run.id).open")
    }
  }

  @ViewBuilder
  private func resumeControl(
    _ run: RuntimeJobSummaryPresentation,
    disposition: OverviewRunResumeDisposition
  ) -> some View {
    switch disposition {
    case .resumable, .detailNotLoaded:
      Button("overview.record.run.again") { onResume(run) }
        .buttonStyle(.link)
        .disabled(disposition == .detailNotLoaded)
        .accessibilityIdentifier("overview.record.run.\(run.id).again")
    case .requiresAuthorization:
      Button("overview.record.run.againGated") { onResume(run) }
        .buttonStyle(.link)
        .accessibilityIdentifier("overview.record.run.\(run.id).again")
    case .neverReplayed, .notTerminal, .effectUnknown, .parametersNotReported:
      Text(LocalizedStringKey(refusalKey(disposition)))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("overview.record.run.\(run.id).refusal")
    }
  }

  // MARK: - Presentation helpers

  private func featuredRun(in thread: OverviewRunThread) -> RuntimeJobSummaryPresentation? {
    OverviewRunRecordProjection.featuredRun(in: thread)
  }

  private func additionalRuns(
    in thread: OverviewRunThread, excluding featured: RuntimeJobSummaryPresentation
  ) -> [RuntimeJobSummaryPresentation] {
    OverviewRunRecordProjection.additionalRuns(in: thread, excluding: featured)
  }

  private func expandedBinding(for threadID: String) -> Binding<Bool> {
    Binding(
      get: { expandedThreadIDs.contains(threadID) },
      set: { expanded in
        if expanded {
          expandedThreadIDs.insert(threadID)
        } else {
          expandedThreadIDs.remove(threadID)
        }
      })
  }

  private func resumeDisposition(
    for run: RuntimeJobSummaryPresentation
  ) -> OverviewRunResumeDisposition {
    OverviewRunRecordProjection.resumeDisposition(
      for: run,
      parametersWereReported: detailsByJobID[run.id]?.evidence?.parametersWereReported)
  }

  private func workspaceKind(for run: RuntimeJobSummaryPresentation) -> OverviewAction.Kind? {
    OverviewActionProjection.workspaceKind(
      forOperation: run.operationReference,
      parameters: detailsByJobID[run.id]?.evidence?.parameters ?? [])
  }

  private func workspaceTitle(for run: RuntimeJobSummaryPresentation) -> LocalizedStringKey {
    switch workspaceKind(for: run) {
    case .uiDump: "overview.record.workspace.viewer"
    case .trace: "overview.record.workspace.trace"
    case .debugHAP: "overview.record.workspace.debug"
    case .flash: "overview.record.workspace.flash"
    case .toolkit: "overview.record.workspace.toolkit"
    case nil: LocalizedStringKey(displayedOperation(run.operationReference))
    }
  }

  private func symbol(for run: RuntimeJobSummaryPresentation) -> String {
    switch workspaceKind(for: run) {
    case .uiDump: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .debugHAP: "ladybug"
    case .flash: "bolt"
    case .toolkit: "hand.tap"
    case nil: "clock.arrow.circlepath"
    }
  }

  private func refusalKey(_ disposition: OverviewRunResumeDisposition) -> String {
    switch disposition {
    case .neverReplayed: "overview.record.refusal.neverReplayed"
    case .notTerminal: "overview.record.refusal.notTerminal"
    case .effectUnknown: "overview.record.refusal.effectUnknown"
    case .parametersNotReported: "overview.record.refusal.parametersNotReported"
    case .resumable, .requiresAuthorization, .detailNotLoaded: ""
    }
  }

  private func effectChip(_ effect: String) -> some View {
    WorkspaceChip(text: Text(effect), tone: effectTone(effect))
  }

  private func effectTone(_ effect: String) -> WorkspaceTone {
    switch effect {
    case "readOnly", "hostOnly": .ok
    case "deviceMutation": .warning
    case "destructive": .danger
    default: .neutral
    }
  }

  private func stateTone(_ run: RuntimeJobSummaryPresentation) -> WorkspaceTone {
    if run.needsAttention { return .warning }
    guard let state = JobState(rawValue: run.state) else { return .neutral }
    switch state {
    case .succeeded, .recovered: return .ok
    case .failed: return .danger
    case .interrupted: return .warning
    default: return .neutral
    }
  }

  private func stateLabelKey(for run: RuntimeJobSummaryPresentation) -> String {
    switch JobState(rawValue: run.state) {
    case .succeeded, .recovered: "overview.record.state.succeeded"
    case .failed: "overview.record.state.failed"
    case .interrupted: "overview.record.state.interrupted"
    case .cancelled: "overview.record.state.cancelled"
    default: "overview.record.state.inProgress"
    }
  }

  private func runOutcome(_ run: RuntimeJobSummaryPresentation) -> String {
    var parts: [String] = [run.state]
    if run.outcomeUnknown, !run.hasEstablishedCurrentEpoch {
      parts.append(String(localized: "overview.record.run.outcomeUnknown"))
    }
    if run.outstandingResidueCount > 0 {
      parts.append(String(localized: .overviewRecordResidue(run.outstandingResidueCount)))
    }
    if let finished = run.finishedAtUTC ?? run.startedAtUTC ?? run.createdAtUTC {
      parts.append(finished)
    }
    return parts.joined(separator: " · ")
  }

  private func displayedOperation(_ reference: String) -> String {
    reference.split(separator: "@").first.map(String.init) ?? reference
  }
}
