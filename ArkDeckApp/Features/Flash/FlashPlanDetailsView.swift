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
    VStack(alignment: .leading, spacing: 12) {
      Button {
        arePartitionsExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: arePartitionsExpanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .accessibilityHidden(true)
          Label(
            String(
              localized: LocalizedStringResource.FlashLocalizable.flashPlanPartitionCount(
                Int32(clamping: plan.partitions.count))),
            systemImage: "externaldrive.badge.checkmark"
          )
          .font(.subheadline.weight(.semibold))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("flash.plan.partitions.disclosure")

      if arePartitionsExpanded {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.partitions) { partition in
            partitionRow(partition)
          }
          if !plan.writeForbiddenMemberNames.isEmpty {
            Label(flashText("flash.plan.writeForbidden"), systemImage: "checkmark.shield.fill")
              .font(.callout.weight(.semibold))
            Text(plan.writeForbiddenMemberNames.joined(separator: ", "))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, 8)
      }
    }
  }

  private func partitionRow(_ partition: FlashPartitionPresentation) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          partitionIdentity(partition)
          Spacer(minLength: 12)
          Text(partition.imageMemberName)
            .font(.callout.monospaced())
        }
        VStack(alignment: .leading, spacing: 3) {
          partitionIdentity(partition)
          Text(partition.imageMemberName)
            .font(.callout.monospaced())
        }
      }
      LabeledContent(flashText("flash.plan.imageSize")) {
        Text(
          ByteCountFormatter.string(
            fromByteCount: partition.imageSizeBytes,
            countStyle: .file)
        )
        .monospacedDigit()
      }
      LabeledContent(flashText("flash.plan.imageHash")) {
        Text(partition.imageSHA256)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .help(partition.imageSHA256)
          .textSelection(.enabled)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("flash.plan.partition.\(partition.partitionName)")
  }

  private func partitionIdentity(_ partition: FlashPartitionPresentation) -> some View {
    Text("\(partition.writeOrder). \(partition.partitionName)")
      .font(.callout.monospaced().weight(.semibold))
  }

}

/// The profile's prerequisites, always expanded with the latest read-only
/// Runtime verdict. Symbols are paired with text so the state is not conveyed
/// by colour alone.
struct FlashPrerequisitesList: View {
  let prerequisites: [FlashPrerequisitePresentation]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(prerequisites) { prerequisite in
        prerequisiteRow(prerequisite)
      }
    }
    .accessibilityIdentifier("flash.plan.prerequisitesList")
  }

  private func prerequisiteRow(_ prerequisite: FlashPrerequisitePresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: prerequisiteSymbol(prerequisite.status))
        .foregroundStyle(prerequisiteColor(prerequisite.status))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(flashText(prerequisiteName(prerequisite.identifier)))
          .font(.callout.weight(.semibold))
        Text(flashText(requirementName(prerequisite.requirement)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(flashText(statusName(prerequisite.status)))
        .font(.caption.weight(.semibold))
        .foregroundStyle(prerequisiteColor(prerequisite.status))
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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
