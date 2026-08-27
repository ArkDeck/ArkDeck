import ArkDeckWorkflows
import SwiftUI

/// "Run it again", stated before it happens.
///
/// The sheet exists because continuing work is exactly where a page can lie:
/// it is easy to offer a repeat that is not one. So it shows what the source
/// run recorded, which of those facts still hold, and — when the run did not
/// report its typed inputs — refuses instead of filling the gap with defaults.
///
/// It may open the source workspace or prepare a closed read-only request
/// draft. Neither action submits; submitting stays in the destination where
/// the operator can inspect the new request and its target again.
struct OverviewResumeSheet: View {
  let run: RuntimeJobSummaryPresentation
  let detail: RuntimeJobDetailPresentation?
  let isLoadingDetail: Bool
  let currentTargetID: String?
  let currentBindingRevision: Int?
  let onOpenWorkspace: () -> Void
  let onPrepare: (RuntimeWorkspaceContinuation) -> Void
  let onCancel: () -> Void

  private var evidence: RuntimeJobEvidencePresentation? { detail?.evidence }

  private var preparation: Result<RuntimeWorkspaceContinuation, RuntimeContinuationFailure> {
    RuntimeWorkspaceContinuation.prepare(
      job: run, detail: detail, currentTargetID: currentTargetID,
      currentBindingRevision: currentBindingRevision)
  }

  private var prepared: RuntimeWorkspaceContinuation? { try? preparation.get() }

  private var disposition: OverviewRunResumeDisposition {
    OverviewRunRecordProjection.resumeDisposition(
      for: run, parametersWereReported: evidence?.parametersWereReported)
  }

  private var targetStillMatches: Bool { currentTargetID == run.targetID }

  private var bindingStillMatches: Bool? {
    guard let recorded = evidence?.bindingRevision, let current = currentBindingRevision
    else { return nil }
    return recorded == current
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      header
      Text("overview.resume.explanation")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("overview.resume.explanation")

      checks
      driftNotice
      parameters
      if case .failure(let failure) = preparation, !isLoadingDetail {
        Text(String(localized: "overview.resume.prepare.unavailable") + " · " + failure.reason)
          .font(WorkspaceFont.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("overview.resume.prepare.reason")
      }

      HStack(spacing: WorkspaceMetrics.contentGap) {
        Spacer(minLength: 0)
        Button("overview.resume.cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("overview.resume.cancel")
        Button("overview.resume.open", action: onOpenWorkspace)
          .disabled(!disposition.isResumable)
          .accessibilityIdentifier("overview.resume.open")
        Button("overview.resume.prepare") {
          if let prepared { onPrepare(prepared) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(prepared == nil)
        .accessibilityIdentifier("overview.resume.prepare")
      }
    }
    .padding(WorkspaceMetrics.cardPaddingHorizontal + 6)
    .frame(width: 560)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("overview.resume")
  }

  private var header: some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: "arrow.clockwise")
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      Text("overview.resume.title")
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(run.operationReference)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private var checks: some View {
    WorkspaceFactGrid {
      WorkspaceFactRow(
        name: Text("overview.resume.source"),
        value: Text("\(run.id) · \(run.state)"),
        identifier: "overview.resume.source")
      WorkspaceFactRow(
        name: Text("overview.resume.thread"),
        value: Text(run.threadID ?? String(localized: "overview.record.thread.ungrouped")),
        identifier: "overview.resume.thread")
      WorkspaceFactRow(
        name: Text("overview.resume.target"),
        value: Text(run.targetID),
        identifier: "overview.resume.target")
      WorkspaceFactRow(
        name: Text("overview.resume.effect"),
        value: Text(run.actualEffect ?? String(localized: "overview.resume.effect.unrecorded")),
        identifier: "overview.resume.effect")
      if let digest = evidence?.catalogDigest {
        // Shown as provenance, not as a verdict: the App is not given the
        // current Catalog digest, so it cannot claim the two agree.
        WorkspaceFactRow(
          name: Text("overview.resume.catalogDigest"),
          value: Text(digest),
          identifier: "overview.resume.catalogDigest")
      }
    }
  }

  @ViewBuilder
  private var driftNotice: some View {
    if !targetStillMatches {
      WorkspaceNotice(tone: .warning, identifier: "overview.resume.drift.target") {
        Text("overview.resume.drift.target")
      }
    } else if bindingStillMatches == false {
      WorkspaceNotice(tone: .warning, identifier: "overview.resume.drift.binding") {
        Text("overview.resume.drift.binding")
      }
    } else if bindingStillMatches == nil {
      WorkspaceNotice(tone: .neutral, identifier: "overview.resume.drift.unknown") {
        Text("overview.resume.drift.unknown")
      }
    }
  }

  @ViewBuilder
  private var parameters: some View {
    switch disposition {
    case .detailNotLoaded where isLoadingDetail:
      HStack(spacing: WorkspaceMetrics.tightGap) {
        ProgressView().controlSize(.small)
        Text("overview.resume.loading").font(WorkspaceFont.secondary)
      }
    case .parametersNotReported, .detailNotLoaded:
      WorkspaceNotice(tone: .warning, identifier: "overview.resume.noParameters") {
        Text("overview.resume.noParameters")
      }
    case .requiresAuthorization(let effect):
      WorkspaceNotice(tone: .warning, identifier: "overview.resume.gated") {
        Text(
          String(
            localized: .overviewResumeGated(effect)))
      }
    case .neverReplayed:
      WorkspaceNotice(tone: .danger, identifier: "overview.resume.neverReplayed") {
        Text("overview.resume.neverReplayed")
      }
    case .notTerminal, .effectUnknown:
      WorkspaceNotice(tone: .warning, identifier: "overview.resume.notRepeatable") {
        Text("overview.resume.notRepeatable")
      }
    case .resumable:
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Text("overview.resume.parameters")
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        WorkspaceFactGrid {
          ForEach(evidence?.parameters ?? []) { parameter in
            WorkspaceFactRow(
              name: Text(parameter.name),
              value: Text(parameter.value),
              identifier: "overview.resume.parameter.\(parameter.name)")
          }
        }
        Text("overview.resume.parameters.note")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The copied request is visible in its workspace before the user submits.
/// This is distinct from opening historical artifacts, and never imports a
/// past authorization, artifact lease or Runtime session identity.
struct WorkspaceContinuationCard: View {
  let draft: RuntimeWorkspaceContinuation
  let currentTargetID: String?
  let currentBindingRevision: Int?
  let onOpenJob: (String) -> Void
  let onClose: () -> Void
  @State private var attempted = false
  @State private var isSubmitting = false
  @State private var jobID: String?
  @State private var result: String?
  @State private var inputsExpanded = true
  @State private var provider = RuntimeContinuationApplicationFacade.make()

  private var targetMatches: Bool {
    currentTargetID == draft.sourceJob.targetID && currentBindingRevision == draft.bindingRevision
  }
  private var encodedInputs: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let bytes = try? encoder.encode(draft.inputs) else { return "—" }
    return String(decoding: bytes, as: UTF8.self)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("overview.continuation.title").font(WorkspaceFont.label)
        Text(draft.sourceJob.id).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
        Spacer()
        Button("overview.continuation.close", action: onClose)
          .accessibilityIdentifier("overview.continuation.close")
      }
      Text(LocalizedStringKey(attempted ? "overview.continuation.statusNote" : "overview.continuation.explanation"))
        .font(WorkspaceFont.secondary).foregroundStyle(.secondary)
      DisclosureGroup(draft.sourceJob.operationReference + " · " + draft.sourceJob.targetID, isExpanded: $inputsExpanded) {
        ScrollView {
          Text(encodedInputs).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("overview.continuation.inputs")
        }.frame(maxHeight: 140)
        Text(draft.sourceJob.threadID ?? String(localized: "overview.record.thread.ungrouped"))
          .font(WorkspaceFont.monospacedDense)
          .accessibilityIdentifier("overview.continuation.thread")
      }
      if !targetMatches {
        Text("overview.resume.drift.target").font(WorkspaceFont.secondary).foregroundStyle(.orange)
      }
      HStack {
        Button("overview.continuation.submit", action: submit)
          .disabled(attempted || !targetMatches)
          .accessibilityIdentifier("overview.continuation.submit")
        if isSubmitting { ProgressView().controlSize(.small) }
        if let jobID {
          Button("overview.continuation.openJob") { onOpenJob(jobID) }
            .accessibilityIdentifier("overview.continuation.openJob")
        }
        if let result {
          Text(result).font(WorkspaceFont.secondary).textSelection(.enabled)
            .accessibilityIdentifier("overview.continuation.result")
        }
      }
    }
    .padding(12)
    .background(Color.accentColor.opacity(0.06))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("overview.continuation")
  }

  private func submit() {
    guard !attempted, targetMatches else { return }
    attempted = true
    isSubmitting = true
    Task {
      switch await provider.submit(draft) {
      case .failure(let failure): result = failure.reason
      case .success(let accepted):
        jobID = accepted
        result = String(localized: "overview.continuation.submitted")
        switch await provider.run(jobID: accepted) {
        case .success(let state): result = state
        case .failure(let failure): result = failure.reason
        }
      }
      isSubmitting = false
    }
  }
}
