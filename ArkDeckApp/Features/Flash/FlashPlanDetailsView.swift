import ArkDeckWorkflows
import Foundation
import SwiftUI

/// Progressive disclosure for the parts of an exact plan that are too large
/// for the summary: every mapped image and every profile prerequisite.
struct FlashPlanDetailsView: View {
  let plan: FlashExactPlanPresentation

  @State private var arePartitionsExpanded = false
  @State private var arePrerequisitesExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DisclosureGroup(isExpanded: $arePartitionsExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.partitions) { partition in
            partitionRow(partition)
          }
          if !plan.writeForbiddenMemberNames.isEmpty {
            Label("flash.plan.writeForbidden", systemImage: "checkmark.shield.fill")
              .font(.callout.weight(.semibold))
            Text(plan.writeForbiddenMemberNames.joined(separator: ", "))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, 8)
      } label: {
        Label(
          String(
            format: String(localized: "flash.plan.partitionCount"),
            plan.partitions.count),
          systemImage: "externaldrive.badge.checkmark")
          .font(.subheadline.weight(.semibold))
      }
      .accessibilityIdentifier("flash.plan.partitions.disclosure")

      DisclosureGroup(isExpanded: $arePrerequisitesExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          Text("flash.plan.prerequisitesNote")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          ForEach(plan.prerequisites) { prerequisite in
            prerequisiteRow(prerequisite)
          }
        }
        .padding(.top, 8)
      } label: {
        Label("flash.plan.prerequisites", systemImage: "checklist")
          .font(.subheadline.weight(.semibold))
      }
      .accessibilityIdentifier("flash.plan.prerequisites.disclosure")
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
      LabeledContent("flash.plan.imageSize") {
        Text(
          ByteCountFormatter.string(
            fromByteCount: partition.imageSizeBytes,
            countStyle: .file))
          .monospacedDigit()
      }
      LabeledContent("flash.plan.imageHash") {
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

  private func prerequisiteRow(_ prerequisite: FlashPrerequisitePresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: prerequisiteSymbol(prerequisite.requirement))
        .foregroundStyle(prerequisiteColor(prerequisite.requirement))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(prerequisiteName(prerequisite.identifier))
          .font(.callout.weight(.semibold))
        Text(requirementName(prerequisite.requirement))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text("flash.plan.prerequisitePending")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  private func prerequisiteName(
    _ prerequisite: RockchipPrerequisiteIdentifier
  ) -> LocalizedStringKey {
    switch prerequisite {
    case .loader: "flash.prerequisite.loader"
    case .recoveryPath: "flash.prerequisite.recoveryPath"
    case .unlocked: "flash.prerequisite.unlocked"
    case .stablePower: "flash.prerequisite.stablePower"
    }
  }

  private func requirementName(
    _ requirement: RockchipPrerequisiteRequirement
  ) -> LocalizedStringKey {
    switch requirement {
    case .required: "flash.prerequisite.required"
    case .optional: "flash.prerequisite.optional"
    case .notApplicable: "flash.prerequisite.notApplicable"
    }
  }

  private func prerequisiteSymbol(_ requirement: RockchipPrerequisiteRequirement) -> String {
    switch requirement {
    case .required: "exclamationmark.circle"
    case .optional: "info.circle"
    case .notApplicable: "minus.circle"
    }
  }

  private func prerequisiteColor(_ requirement: RockchipPrerequisiteRequirement) -> Color {
    switch requirement {
    case .required: .orange
    case .optional: .blue
    case .notApplicable: .secondary
    }
  }
}
