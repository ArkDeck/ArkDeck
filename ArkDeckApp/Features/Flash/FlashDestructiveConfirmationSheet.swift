import ArkDeckWorkflows
import SwiftUI

struct FlashDestructiveConfirmationSheet: View {
  let plan: FlashExactPlanPresentation
  let submit: (String, String) -> FlashManualConfirmationResult

  @Environment(\.dismiss) private var dismiss
  @State private var destructivePhrase = ""
  @State private var userdataPhrase = ""
  @State private var failure: FlashManualConfirmationFailure?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case destructivePhrase
    case userdataPhrase
  }

  private var expectedDestructivePhrase: String {
    FlashManualConfirmationValidator.destructivePhrase(for: plan)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label(flashText("flash.confirm.title"), systemImage: "exclamationmark.triangle.fill")
          .font(.title2.bold())
          .foregroundStyle(.red)

        Text(flashText("flash.confirm.summary"))
          .fixedSize(horizontal: false, vertical: true)

        pinnedFacts
        dataImpact
        FlashPlanDetailsView(plan: plan)

        Label(
          flashText("flash.confirm.powerWarning"),
          systemImage: "bolt.trianglebadge.exclamationmark.fill"
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

        confirmationFields

        if let failure {
          Label(flashText(failureKey(failure)), systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.confirm.error")
        }

        Label(flashText("flash.confirm.noJob"), systemImage: "lock.shield")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          Spacer()
          Button(flashText("flash.confirm.cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("flash.confirm.cancel")
          Button(flashText("flash.confirm.accept")) { confirm() }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("flash.confirm.accept")
        }
      }
      .padding(24)
    }
    .frame(
      minWidth: 560, idealWidth: 640, maxWidth: 720,
      minHeight: 480, idealHeight: 560, maxHeight: 640)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.confirm.sheet")
    .onAppear { focusedField = .destructivePhrase }
  }

  private var pinnedFacts: some View {
    GroupBox(flashText("flash.confirm.exactPlan")) {
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent(flashText("flash.confirm.target")) {
          if let target = plan.target {
            Text("\(target.id) · r\(target.bindingRevision)")
              .font(.body.monospaced())
          } else {
            Text(flashText("flash.confirm.targetUnavailable"))
              .foregroundStyle(.red)
          }
        }
        LabeledContent(flashText("flash.confirm.profile")) {
          Text(plan.profileReference).font(.body.monospaced())
        }
        LabeledContent(flashText("flash.plan.toolchain")) {
          Text(plan.toolchainFingerprint)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .help(plan.toolchainFingerprint)
        }
        LabeledContent(flashText("flash.confirm.image")) {
          Text(plan.imageFileName)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(plan.imageFileName)
        }
        digestRow("flash.plan.archiveHash", plan.archiveSHA256)
        digestRow("flash.plan.digest", plan.planDigestSHA256)
        digestRow("flash.confirm.stepSet", plan.stepSetDigestSHA256)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var dataImpact: some View {
    GroupBox(flashText("flash.impact.title")) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(plan.dataImpact.enumerated()), id: \.offset) { _, impact in
          dataImpactLabel(impact)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var confirmationFields: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(flashText("flash.confirm.destructiveLabel"))
          .font(.subheadline.weight(.semibold))
        Text(expectedDestructivePhrase)
          .font(.body.monospaced().weight(.semibold))
          .textSelection(.enabled)
          .accessibilityIdentifier("flash.confirm.expectedDestructivePhrase")
        TextField(flashText("flash.confirm.destructivePlaceholder"), text: $destructivePhrase)
          .font(.body.monospaced())
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: .destructivePhrase)
          .accessibilityLabel(flashText("flash.confirm.destructiveLabel"))
          .accessibilityIdentifier("flash.confirm.destructivePhrase")
        Text(flashText("flash.confirm.destructiveHint"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(flashText("flash.confirm.userdataLabel"))
          .font(.subheadline.weight(.semibold))
        Text(FlashManualConfirmationValidator.userdataPhrase)
          .font(.body.monospaced().weight(.semibold))
          .textSelection(.enabled)
        TextField(flashText("flash.confirm.userdataPlaceholder"), text: $userdataPhrase)
          .font(.body.monospaced())
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: .userdataPhrase)
          .accessibilityLabel(flashText("flash.confirm.userdataLabel"))
          .accessibilityIdentifier("flash.confirm.userdataPhrase")
        Text(flashText("flash.confirm.userdataHint"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func digestRow(_ key: String, _ value: String) -> some View {
    LabeledContent(flashText(key)) {
      Text(value)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .help(value)
        .textSelection(.enabled)
    }
  }

  private func dataImpactLabel(_ impact: FlashDataImpactPresentation) -> some View {
    switch impact {
    case .mappedPartitionsOverwritten(let count):
      return Label(
        String(format: flashText("flash.impact.partitions"), count),
        systemImage: "externaldrive.badge.exclamationmark")
    case .userDataDestroyed:
      return Label(flashText("flash.impact.userdata"), systemImage: "trash.fill")
    case .forbiddenAreasPreserved:
      return Label(flashText("flash.impact.preserved"), systemImage: "checkmark.shield.fill")
    }
  }

  private func confirm() {
    let result = submit(destructivePhrase, userdataPhrase)
    switch result {
    case .accepted:
      dismiss()
    case .rejected(let failure):
      self.failure = failure
      switch failure {
      case .destructivePhraseMismatch:
        focusedField = .destructivePhrase
      case .userdataPhraseMismatch:
        focusedField = .userdataPhrase
      case .notExecutePlan, .missingOrStaleTarget, .stalePlan:
        focusedField = nil
      }
    }
  }

  private func failureKey(_ failure: FlashManualConfirmationFailure) -> String {
    switch failure {
    case .notExecutePlan: "flash.confirm.error.notExecutePlan"
    case .missingOrStaleTarget: "flash.confirm.error.missingOrStaleTarget"
    case .stalePlan: "flash.confirm.error.stalePlan"
    case .destructivePhraseMismatch: "flash.confirm.error.destructivePhraseMismatch"
    case .userdataPhraseMismatch: "flash.confirm.error.userdataPhraseMismatch"
    }
  }
}
