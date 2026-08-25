import ArkDeckWorkflows
import SwiftUI

/// "Run it again", stated before it happens.
///
/// The sheet exists because continuing work is exactly where a page can lie:
/// it is easy to offer a repeat that is not one. So it shows what the source
/// run recorded, which of those facts still hold, and — when the run did not
/// report its typed inputs — refuses instead of filling the gap with defaults.
///
/// Its primary action opens the workspace. Runtime's history surface is
/// read-only by construction, and submitting stays where the operator can see
/// the whole request: ArkDeck does not submit on their behalf from here.
struct OverviewResumeSheet: View {
  let run: RuntimeJobSummaryPresentation
  let detail: RuntimeJobDetailPresentation?
  let isLoadingDetail: Bool
  let currentTargetID: String?
  let currentBindingRevision: Int?
  let onOpenWorkspace: () -> Void
  let onCancel: () -> Void

  private var evidence: RuntimeJobEvidencePresentation? { detail?.evidence }

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

      checks
      driftNotice
      parameters

      HStack(spacing: WorkspaceMetrics.contentGap) {
        Spacer(minLength: 0)
        Button("overview.resume.cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("overview.resume.cancel")
        Button("overview.resume.open", action: onOpenWorkspace)
          .keyboardShortcut(.defaultAction)
          .disabled(!disposition.isResumable)
          .accessibilityIdentifier("overview.resume.open")
      }
    }
    .padding(WorkspaceMetrics.cardPaddingHorizontal + 6)
    .frame(width: 560)
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
