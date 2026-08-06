import ArkDeckWorkflows
import Foundation
import SwiftUI

struct TraceProgressArtifactsView: View {
  @ObservedObject var model: TraceWorkspaceViewModel

  var body: some View {
    VStack(spacing: 18) {
      stageModel
      artifactModel
    }
  }

  private var stageModel: some View {
    GroupBox(traceString("trace.progress.title")) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "timeline.selection")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(traceString("trace.progress.noActive"))
              .font(.callout.weight(.semibold))
            Text(traceString("trace.progress.noActiveDetail"))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
          spacing: 8
        ) {
          ForEach(Array(TraceWorkflowStage.allCases.enumerated()), id: \.offset) {
            index, stage in
            HStack(spacing: 8) {
              Text(String(index + 1))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
              VStack(alignment: .leading, spacing: 1) {
                Text(traceString("trace.stage.\(stage.rawValue)"))
                  .font(.callout.weight(.medium))
                Text(traceString("trace.value.notStarted"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 4)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
          }
        }
        .accessibilityIdentifier("trace.progress.stages")

        traceNotice(
          traceString("trace.progress.honestRule"),
          systemImage: "hourglass",
          color: .secondary,
          identifier: "trace.progress.honestRule")

        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "stop.circle").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(traceString("trace.progress.cancelTitle"))
              .font(.callout.weight(.semibold))
            Text(cancelDetail)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var artifactModel: some View {
    GroupBox(traceString("trace.artifacts.title")) {
      VStack(alignment: .leading, spacing: 12) {
        Text(traceString("trace.artifacts.description"))
          .font(.footnote)
          .foregroundStyle(.secondary)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
          spacing: 10
        ) {
          artifactCard(
            title: traceString("trace.artifacts.raw"),
            file: "trace.htrace",
            detail: traceString("trace.artifacts.rawDetail"),
            state: model.workspace.operation.supportsRawTraceArtifact
              ? .publishedContract : .missingContract)
          artifactCard(
            title: traceString("trace.artifacts.filtered"),
            file: "trace-filtered.htrace",
            detail: model.filtersCreateFileAsset
              ? traceString("trace.artifacts.filteredRequested")
              : traceString("trace.artifacts.filteredDetail"),
            state: model.workspace.operation.supportsFilteredTraceArtifact
              ? .publishedContract : .missingContract)
          artifactCard(
            title: traceString("trace.artifacts.log"),
            file: "capture.log",
            detail: traceString("trace.artifacts.logDetail"),
            state: model.workspace.operation.supportsCaptureLogArtifact
              ? .publishedContract : .missingContract)
          artifactCard(
            title: traceString("trace.artifacts.manifest"),
            file: "artifact-index.json + capture-summary.json",
            detail: traceString("trace.artifacts.manifestDetail"),
            state: .partialContract)
        }

        Divider()

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
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
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var cancelDetail: String {
    let policy =
      model.workspace.operation.traceStepCancellation
      ?? traceString("trace.value.unavailable")
    return String(format: traceString("trace.progress.cancelDetail"), policy)
  }

  private func artifactCard(
    title: String,
    file: String,
    detail: String,
    state: TraceArtifactContractState
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Label(title, systemImage: state.systemImage)
          .font(.callout.weight(.semibold))
          .foregroundStyle(state.color)
        Spacer(minLength: 8)
        Text(state.label)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(state.color)
      }
      Text(file)
        .font(.caption.monospaced())
        .textSelection(.enabled)
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    .background(state.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(state.color.opacity(0.24), lineWidth: 1)
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
