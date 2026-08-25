import ArkDeckCore
import ArkDeckWorkflows
import SwiftUI

/// The Overview's record-first content: which device this page is talking
/// about, what can be started on it, and what has already run.
///
/// It renders above the HDC diagnostics rather than replacing them. The
/// accepted `desktop-ux-observability` requirement still asks Overview to show
/// the toolchain facts, so this adds the answer to "what ran and how do I
/// continue" without moving anything that requirement names. Moving those
/// fields to Settings is a behavior delta the maintainer has to rule on first
/// (`docs/design/overview-redesign.md` §6).
struct OverviewRecordView: View {
  let devices: DeviceListPresentation
  let capabilities: OverviewCapabilityMatrixPresentation
  let history: RuntimeHistoryPresentation
  let detailsByJobID: [String: RuntimeJobDetailPresentation]
  let onOpen: (OverviewAction.Kind) -> Void
  let onOpenHistory: () -> Void
  let onOpenJob: (String) -> Void
  let onResume: (RuntimeJobSummaryPresentation) -> Void

  private var threads: [OverviewRunThread] {
    OverviewRunRecordProjection.threads(from: history.jobs)
  }

  private var actions: [OverviewAction] {
    OverviewActionProjection.actions(from: capabilities)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
      deviceBar
      startSection
      recordSection
    }
    .accessibilityIdentifier("overview.record")
  }

  // MARK: - Device bar

  /// The target this page is describing, stated rather than assumed. The
  /// capability matrix binds one adopted target, so the page says which one
  /// instead of leaving the reader to guess which device the entries below
  /// describe.
  private var deviceBar: some View {
    WorkspaceCard {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        Image(systemName: "iphone.gen3")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(boundDeviceName)
            .font(WorkspaceFont.body.weight(.semibold))
            .accessibilityIdentifier("overview.record.device.name")
          Text(boundDeviceFacts)
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("overview.record.device.facts")
        }
        Spacer(minLength: 0)
      }
    }
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

  // MARK: - Start a new one

  private var startSection: some View {
    WorkspaceSection(
      Text("overview.record.start.title"), identifier: "overview.record.start"
    ) {
      // A fixed grid rather than a wrapping row: the entries must not
      // reshuffle as probes come back, or the operator learns their positions
      // twice.
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(minimum: 120), spacing: WorkspaceMetrics.contentGap),
          count: 5),
        alignment: .leading,
        spacing: WorkspaceMetrics.contentGap
      ) {
        ForEach(actions) { action in
          actionTile(action)
        }
      }
    }
  }

  private func actionTile(_ action: OverviewAction) -> some View {
    Button {
      onOpen(action.kind)
    } label: {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: symbol(for: action.kind))
            .foregroundStyle(action.availability.opensWorkspace ? Color.accentColor : .secondary)
            .accessibilityHidden(true)
          Text(LocalizedStringKey(titleKey(for: action.kind)))
            .font(WorkspaceFont.body.weight(.semibold))
          Spacer(minLength: 0)
        }
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Label {
            Text(LocalizedStringKey(availabilityKey(action.availability)))
              .font(WorkspaceFont.secondary)
          } icon: {
            Image(systemName: availabilityTone(action.availability).symbol)
              .foregroundStyle(availabilityTone(action.availability).color)
              .accessibilityHidden(true)
          }
          effectChip(action.effect)
        }
        Text(action.operationReference)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let reason = unavailableReason(action.availability) {
          Text(reason)
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("overview.record.start.\(action.id).reason")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
      .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .disabled(!action.availability.opensWorkspace)
    .accessibilityIdentifier("overview.record.start.\(action.id)")
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
      case .unavailable(let reason):
        WorkspaceNotice(tone: .warning, identifier: "overview.record.recent.unavailable") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text("overview.record.recent.unavailable.title")
              .font(WorkspaceFont.body.weight(.semibold))
            Text(reason).font(WorkspaceFont.monospacedDense)
          }
        }
      case .available where threads.isEmpty:
        emptyRecord
      case .available:
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          ForEach(threads) { thread in
            threadCard(thread)
          }
          Text("overview.record.recent.rules")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// A record page has to define its empty state, and it must not fill it with
  /// example rows: what has not run has not run. What it can honestly do is say
  /// what a run will record.
  private var emptyRecord: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Text("overview.record.empty.title")
        .font(WorkspaceFont.body.weight(.semibold))
        .accessibilityIdentifier("overview.record.empty")
      Text("overview.record.empty.description")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(["run", "artifact", "thread"], id: \.self) { key in
        Label {
          Text(LocalizedStringKey("overview.record.empty.\(key)"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "circle.fill")
            .font(.system(size: 4))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
    }
  }

  private func threadCard(_ thread: OverviewRunThread) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      threadHeader(thread)
      Divider()
      ForEach(Array(thread.runs.enumerated()), id: \.element.id) { index, run in
        if index > 0 { Divider() }
        runRow(run)
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
    .accessibilityIdentifier("overview.record.thread.\(thread.id)")
  }

  private func threadHeader(_ thread: OverviewRunThread) -> some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(thread.threadID ?? String(localized: "overview.record.thread.ungrouped"))
        .font(WorkspaceFont.monospacedDense)
      Text(threadSubtitle(thread))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
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
    var parts = thread.operationReferences
    parts.append(thread.targetID)
    parts.append(String(localized: .overviewRecordRunCount(thread.runs.count)))
    return parts.joined(separator: " · ")
  }

  private func runRow(_ run: RuntimeJobSummaryPresentation) -> some View {
    let disposition = OverviewRunRecordProjection.resumeDisposition(
      for: run,
      parametersWereReported: detailsByJobID[run.id]?.evidence?.parametersWereReported)
    return HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: stateTone(run).symbol)
        .foregroundStyle(stateTone(run).color)
        .accessibilityHidden(true)
      Text(run.id)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
      Text(displayedOperation(run.operationReference))
        .font(WorkspaceFont.body)
        .lineLimit(1)
      if let effect = run.actualEffect { effectChip(effect) }
      Spacer(minLength: 0)
      Text(runOutcome(run))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier("overview.record.run.\(run.id).outcome")
      resumeControl(run, disposition: disposition)
      Button("overview.record.run.open") { onOpenJob(run.id) }
        .buttonStyle(.link)
        .accessibilityIdentifier("overview.record.run.\(run.id).open")
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.rowGap + 2)
    .accessibilityIdentifier("overview.record.run.\(run.id)")
  }

  /// Every refusal names itself in place. A disabled control with no stated
  /// reason is the thing this page was redesigned to stop doing.
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

  // MARK: - Vocabulary

  private func symbol(for kind: OverviewAction.Kind) -> String {
    switch kind {
    case .uiDump: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .debugHAP: "ladybug"
    case .flash: "bolt"
    case .toolkit: "hand.tap"
    }
  }

  private func titleKey(for kind: OverviewAction.Kind) -> String {
    "overview.record.action.\(kind.rawValue)"
  }

  private func availabilityKey(_ availability: OverviewAction.Availability) -> String {
    switch availability {
    case .available: "overview.record.availability.available"
    case .limited: "overview.record.availability.limited"
    case .unavailable: "overview.record.availability.unavailable"
    case .notProbed: "overview.record.availability.notProbed"
    }
  }

  private func availabilityTone(_ availability: OverviewAction.Availability) -> WorkspaceTone {
    switch availability {
    case .available: .ok
    case .limited: .warning
    case .unavailable: .danger
    case .notProbed: .neutral
    }
  }

  private func unavailableReason(_ availability: OverviewAction.Availability) -> String? {
    switch availability {
    case .available: nil
    case .limited(let reason), .unavailable(let reason), .notProbed(let reason): reason
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
    case "readOnly": .ok
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
    case .cancelled, .planned: return .neutral
    case .interrupted: return .warning
    default: return .neutral
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

  /// Runtime prints the reference; the row shows it without the schema noise a
  /// reader does not need at a glance.
  private func displayedOperation(_ reference: String) -> String {
    reference.split(separator: "@").first.map(String.init) ?? reference
  }
}
