import ArkDeckWorkflows
import Foundation
import SwiftUI

struct TraceProgressArtifactsView: View {
  var model: TraceWorkspaceViewModel

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

        // The stage-by-stage track belongs to the job inspector, which renders
        // a running job's real timeline; a static copy here would only ever
        // show "not started" and read as one more thing to check.
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

        if !model.runtimeArtifacts.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(traceString("trace.artifacts.runtimeTitle"))
              .font(.subheadline.weight(.semibold))
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

        VStack(alignment: .leading, spacing: 0) {
          artifactRow(
            file: "trace.htrace",
            role: traceString("trace.artifacts.role.raw"),
            detail: traceString("trace.artifacts.rawDetail"),
            state: model.workspace.operation.supportsRawTraceArtifact
              ? .publishedContract : .missingContract)
          Divider()
          artifactRow(
            file: "trace-filtered.htrace",
            role: traceString("trace.artifacts.role.derived"),
            detail: model.filtersCreateFileAsset
              ? traceString("trace.artifacts.filteredRequested")
              : traceString("trace.artifacts.filteredDetail"),
            state: model.workspace.operation.supportsFilteredTraceArtifact
              ? .publishedContract : .missingContract)
          Divider()
          artifactRow(
            file: "capture.log",
            role: traceString("trace.artifacts.role.log"),
            detail: traceString("trace.artifacts.logDetail"),
            state: model.workspace.operation.supportsCaptureLogArtifact
              ? .publishedContract : .missingContract)
          Divider()
          artifactRow(
            file: "artifact-index.json + capture-summary.json",
            role: traceString("trace.artifacts.role.manifest"),
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

  private func runtimeArtifactRow(_ artifact: RuntimeArtifactPresentation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(artifact.name)
          .font(.callout.monospaced().weight(.semibold))
          .textSelection(.enabled)
        Spacer(minLength: 12)
        Text(ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file))
          .font(.caption.monospacedDigit())
        Text(artifact.status)
          .font(.caption.weight(.semibold))
      }
      Text(artifact.sha256)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .help(artifact.sha256)
        .textSelection(.enabled)
      Text("\(artifact.privacy) · \(artifact.role ?? "—")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 5)
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
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(file)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(minWidth: 200, alignment: .leading)
      Text(role)
        .font(.caption.weight(.semibold))
        .frame(minWidth: 130, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Label(state.label, systemImage: state.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(state.color)
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
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
