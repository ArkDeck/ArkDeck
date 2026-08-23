import ArkDeckWorkflows
import Foundation
import SwiftUI

struct TraceProgressArtifactsView: View {
  var model: TraceWorkspaceViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
      stageModel
      artifactModel
    }
  }

  private var stageModel: some View {
    WorkspaceSection(Text(traceString("trace.progress.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        HStack(alignment: .top, spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: "timeline.selection")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(traceString("trace.progress.noActive"))
              .font(WorkspaceFont.body.weight(.semibold))
            Text(traceString("trace.progress.noActiveDetail"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
        }

        // The stage-by-stage track belongs to the job inspector, which renders
        // a running job's real timeline; a static copy here would only ever
        // show "not started" and read as one more thing to check.
        traceNotice(
          traceString("trace.progress.honestRule"),
          systemImage: "hourglass",
          color: .secondary,
          identifier: "trace.progress.honestRule")

        HStack(alignment: .top, spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: "stop.circle").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(traceString("trace.progress.cancelTitle"))
              .font(WorkspaceFont.body.weight(.semibold))
            Text(cancelDetail)
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private var artifactModel: some View {
    WorkspaceSection(Text(traceString("trace.artifacts.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        Text(traceString("trace.artifacts.description"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)

        if !model.runtimeArtifacts.isEmpty {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
            Text(traceString("trace.artifacts.runtimeTitle"))
              .font(WorkspaceFont.label)
              .foregroundStyle(.secondary)
            ForEach(model.runtimeArtifacts) { artifact in
              runtimeArtifactRow(artifact)
            }
          }
          .accessibilityIdentifier("trace.artifacts.runtime")
          Divider()
        } else if let failure = model.runtimeArtifactFailures.first {
          traceNotice(
            failure,
            systemImage: "exclamationmark.triangle",
            color: .orange,
            identifier: "trace.artifacts.runtimeFailure")
          Divider()
        }

        Grid(
          alignment: .leading,
          horizontalSpacing: WorkspaceMetrics.keyColumnGap,
          verticalSpacing: WorkspaceMetrics.contentGap
        ) {
          artifactRow(
            file: "trace.htrace",
            role: traceString("trace.artifacts.role.raw"),
            detail: traceString("trace.artifacts.rawDetail"),
            state: model.workspace.operation.supportsRawTraceArtifact
              ? .publishedContract : .missingContract)
          Divider().gridCellColumns(3)
          artifactRow(
            file: "trace-filtered.htrace",
            role: traceString("trace.artifacts.role.derived"),
            detail: model.filtersCreateFileAsset
              ? traceString("trace.artifacts.filteredRequested")
              : traceString("trace.artifacts.filteredDetail"),
            state: model.workspace.operation.supportsFilteredTraceArtifact
              ? .publishedContract : .missingContract)
          Divider().gridCellColumns(3)
          artifactRow(
            file: "capture.log",
            role: traceString("trace.artifacts.role.log"),
            detail: traceString("trace.artifacts.logDetail"),
            state: model.workspace.operation.supportsCaptureLogArtifact
              ? .publishedContract : .missingContract)
          Divider().gridCellColumns(3)
          artifactRow(
            file: "artifact-index.json + capture-summary.json",
            role: traceString("trace.artifacts.role.manifest"),
            detail: traceString("trace.artifacts.manifestDetail"),
            state: .partialContract)
        }

        Divider()

        Grid(alignment: .leading, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.rowGap) {
          traceReviewRow(
            traceString("trace.artifacts.receive"),
            traceString("trace.artifacts.partialFirst"))
          traceReviewRow(
            traceString("trace.artifacts.validate"),
            traceString("trace.artifacts.nonemptyFormatHash"))
          traceReviewRow(
            traceString("trace.artifacts.cleanup"),
            traceString("trace.artifacts.cleanupAfterPublish"))
          traceReviewRow(
            traceString("trace.artifacts.privacy"),
            traceString("trace.artifacts.sensitive"))
        }
      }
    }
  }

  private func runtimeArtifactRow(_ artifact: RuntimeArtifactPresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        Text(artifact.name)
          .font(WorkspaceFont.monospacedValue.weight(.semibold))
          .textSelection(.enabled)
        Spacer(minLength: WorkspaceMetrics.contentGap)
        Text(ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file))
          .font(WorkspaceFont.tabularSecondary)
        Text(artifact.status)
          .font(WorkspaceFont.label)
      }
      Text(artifact.sha256)
        .font(WorkspaceFont.monospacedDense)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(artifact.sha256)
        .textSelection(.enabled)
      Text("\(artifact.privacy) · \(artifact.role ?? "—")")
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, WorkspaceMetrics.rowGap)
    .accessibilityElement(children: .combine)
  }

  private var cancelDetail: String {
    let policy =
      model.workspace.operation.traceStepCancellation
      ?? traceString("trace.value.unavailable")
    return String(
      localized: LocalizedStringResource.TraceLocalizable.traceProgressCancelDetail(policy))
  }

  /// One artifact per row: file, role, contract status. Roles differ on
  /// purpose — raw is immutable, filtered is a rebuildable derivation — so
  /// the four never merge into one "output" line.
  private func artifactRow(
    file: String,
    role: String,
    detail: String,
    state: TraceArtifactContractState
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(file)
        .font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled)
        .gridColumnAlignment(.leading)
      Text(role)
        .font(WorkspaceFont.body)
        .gridColumnAlignment(.leading)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Label(state.label, systemImage: state.systemImage)
          .font(WorkspaceFont.body.weight(.semibold))
          .foregroundStyle(state.color)
        Text(detail)
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

private enum TraceArtifactContractState {
  case publishedContract
  case partialContract
  case missingContract

  var systemImage: String {
    switch self {
    case .publishedContract: "checkmark.circle.fill"
    case .partialContract: "exclamationmark.circle.fill"
    case .missingContract: "xmark.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .publishedContract: .green
    case .partialContract: .orange
    case .missingContract: .red
    }
  }

  var label: String {
    switch self {
    case .publishedContract: traceString("trace.artifacts.contractPublished")
    case .partialContract: traceString("trace.artifacts.contractPartial")
    case .missingContract: traceString("trace.artifacts.contractMissing")
    }
  }
}
