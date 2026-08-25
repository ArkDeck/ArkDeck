import SwiftUI

/// The Trace page's second and only other task: enter the shared viewer.
/// Capture details and Runtime artifact contracts stay behind the typed job;
/// the workspace presents only the result a person can act on.
struct TraceProgressArtifactsView: View {
  var model: TraceWorkspaceViewModel

  var body: some View {
    WorkspaceSection(
      Text(traceString("trace.viewer.title")),
      identifier: "trace.viewer.section"
    ) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: WorkspaceMetrics.blockGap) {
          viewerStatus
          Spacer(minLength: WorkspaceMetrics.contentGap)
          viewerAction
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          viewerStatus
          viewerAction
        }
      }
    }
  }

  @ViewBuilder
  private var viewerStatus: some View {
    if model.isPreparingViewer {
      HStack(spacing: WorkspaceMetrics.tightGap) {
        ProgressView().controlSize(.small)
        Text(traceString("trace.viewer.preparing"))
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("trace.viewer.preparing")
    } else if let failure = model.viewerArtifactFailure {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("trace.viewer.failure")
        Button(traceString("trace.viewer.tryAgain")) {
          model.reopenLatestTraceArtifact()
        }
        .accessibilityIdentifier("trace.viewer.tryAgain")
      }
    } else if let artifactName = model.latestViewerArtifactName {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Label(traceString("trace.viewer.latest"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(artifactName)
          .font(WorkspaceFont.monospacedValue)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("trace.viewer.latest")
    } else {
      Label(traceString("trace.viewer.description"), systemImage: "folder")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("trace.viewer.empty")
    }
  }

  private var viewerAction: some View {
    Button {
      model.showViewer()
    } label: {
      Label(traceString("trace.action.openViewer"), systemImage: "timeline.selection")
    }
    .accessibilityIdentifier("trace.openViewer")
  }
}
