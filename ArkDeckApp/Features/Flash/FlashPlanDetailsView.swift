import ArkDeckWorkflows
import Foundation
import SwiftUI

/// Progressive disclosure for the part of an exact plan that is too large
/// for the summary: every mapped image. Prerequisites are not here — they
/// render as their own always-visible section before the plan.
struct FlashPlanDetailsView: View {
  let plan: FlashExactPlanPresentation

  @State private var arePartitionsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Button {
        arePartitionsExpanded.toggle()
      } label: {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: arePartitionsExpanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .accessibilityHidden(true)
          Label(
            String(
              localized: LocalizedStringResource.FlashLocalizable.flashPlanPartitionCount(
                Int32(clamping: plan.partitions.count))),
            systemImage: "externaldrive.badge.checkmark"
          )
          .font(WorkspaceFont.body.weight(.semibold))
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("flash.plan.partitions.disclosure")

      if arePartitionsExpanded {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(plan.partitions) { partition in
            partitionRow(partition)
          }
          if !plan.writeForbiddenMemberNames.isEmpty {
            Label(flashText("flash.plan.writeForbidden"), systemImage: "checkmark.shield.fill")
              .font(WorkspaceFont.body.weight(.semibold))
            Text(plan.writeForbiddenMemberNames.joined(separator: ", "))
              .font(WorkspaceFont.monospacedDense)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, WorkspaceMetrics.tightGap)
      }
    }
  }

  private func partitionRow(_ partition: FlashPartitionPresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
          partitionIdentity(partition)
          Spacer(minLength: WorkspaceMetrics.contentGap)
          Text(partition.imageMemberName)
            .font(WorkspaceFont.monospacedValue)
        }
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          partitionIdentity(partition)
          Text(partition.imageMemberName)
            .font(WorkspaceFont.monospacedValue)
        }
      }
      LabeledContent(flashText("flash.plan.imageSize")) {
        Text(
          ByteCountFormatter.string(
            fromByteCount: partition.imageSizeBytes,
            countStyle: .file)
        )
        .font(WorkspaceFont.tabularValue)
      }
      LabeledContent(flashText("flash.plan.imageHash")) {
        Text(partition.imageSHA256)
          .font(WorkspaceFont.monospacedDense)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(partition.imageSHA256)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .background(
      .quaternary.opacity(0.45),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius))
    .accessibilityIdentifier("flash.plan.partition.\(partition.partitionName)")
  }

  private func partitionIdentity(_ partition: FlashPartitionPresentation) -> some View {
    Text("\(partition.writeOrder). \(partition.partitionName)")
      .font(WorkspaceFont.monospacedValue.weight(.semibold))
  }

}

/// The profile's prerequisites, always expanded with the latest read-only
/// Runtime verdict. Symbols are paired with text so the state is not conveyed
/// by colour alone.
struct FlashPrerequisitesList: View {
  let prerequisites: [FlashPrerequisitePresentation]

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      ForEach(prerequisites) { prerequisite in
        prerequisiteRow(prerequisite)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.plan.prerequisitesList")
  }

  private func prerequisiteRow(_ prerequisite: FlashPrerequisitePresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: prerequisiteSymbol(prerequisite.status))
        .foregroundStyle(prerequisiteColor(prerequisite.status))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(flashText(prerequisiteName(prerequisite.identifier)))
          .font(WorkspaceFont.body.weight(.semibold))
        Text(flashText(requirementName(prerequisite.requirement)))
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: WorkspaceMetrics.tightGap)
      Text(flashText(statusName(prerequisite.status)))
        .font(WorkspaceFont.label)
        .foregroundStyle(prerequisiteColor(prerequisite.status))
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .background(
      .quaternary.opacity(0.45),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius))
  }

  private func prerequisiteName(
    _ prerequisite: RockchipPrerequisiteIdentifier
  ) -> String {
    switch prerequisite {
    case .loader: "flash.prerequisite.loader"
    case .recoveryPath: "flash.prerequisite.recoveryPath"
    case .unlocked: "flash.prerequisite.unlocked"
    case .stablePower: "flash.prerequisite.stablePower"
    }
  }

  private func requirementName(
    _ requirement: RockchipPrerequisiteRequirement
  ) -> String {
    switch requirement {
    case .required: "flash.prerequisite.required"
    case .optional: "flash.prerequisite.optional"
    case .notApplicable: "flash.prerequisite.notApplicable"
    }
  }

  private func statusName(_ status: RockchipPrerequisiteStatus) -> String {
    switch status {
    case .satisfied: "flash.prerequisite.status.satisfied"
    case .unsatisfied: "flash.prerequisite.status.unsatisfied"
    case .unknown: "flash.prerequisite.status.unknown"
    }
  }

  private func prerequisiteSymbol(_ status: RockchipPrerequisiteStatus) -> String {
    switch status {
    case .satisfied: "checkmark.circle.fill"
    case .unsatisfied: "xmark.octagon.fill"
    case .unknown: "questionmark.circle"
    }
  }

  private func prerequisiteColor(_ status: RockchipPrerequisiteStatus) -> Color {
    switch status {
    case .satisfied: .green
    case .unsatisfied: .red
    case .unknown: .orange
    }
  }
}
