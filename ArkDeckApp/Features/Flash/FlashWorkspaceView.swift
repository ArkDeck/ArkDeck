import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

enum FlashWorkspaceMode: String, CaseIterable, Hashable {
  case execute
  case planOnly
  case simulated

  var executionMode: RockchipFlashExecutionMode {
    switch self {
    case .execute: .execute
    case .planOnly: .planOnly
    case .simulated: .simulated
    }
  }
}

/// Flash planning workspace.
///
/// The App can read Runtime availability and target facts, and it can ask the
/// bundled provider to materialize an exact plan from a user-selected archive.
/// Runtime owns destructive admission; the UI only submits the reviewed typed
/// request and never carries or administers a capability.
struct FlashWorkspaceView: View {
  @ObservedObject var model: FlashWorkspaceViewModel
  let runtimeHistory: RuntimeHistoryPresentation
  let isRuntimeHistoryRefreshing: Bool
  let onRefreshRuntimeHistory: () -> Void
  let onOpenHistory: () -> Void
  @State private var isImporterPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        modeStatus
        availabilitySection
        deviceAccessSection
        FlashRuntimeActivityView(
          presentation: runtimeHistory,
          plan: model.plan,
          onOpenHistory: onOpenHistory)
        // Reading order matches the spec: Availability → Profile & Image Set
        // → Prerequisites → Exact Plan → Review & Run. Prerequisites are a
        // top-level section before the plan — what has to hold comes before
        // the steps that assume it, never folded inside them.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
              profileAndImageSection
              prerequisitesSection
              targetSection
            }
            .frame(minWidth: 260, maxWidth: 330)

            VStack(spacing: 16) {
              exactPlanSection
              reviewSection
            }
            .frame(minWidth: 360, maxWidth: .infinity)
          }

          VStack(spacing: 16) {
            profileAndImageSection
            prerequisitesSection
            targetSection
            exactPlanSection
            reviewSection
          }
        }
      }
      .frame(maxWidth: 1_000, alignment: .topLeading)
      .padding(20)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Picker(flashText("flash.mode.label"), selection: modeBinding) {
          Text(flashText("flash.mode.execute"))
            .tag(FlashWorkspaceMode.execute)
            .accessibilityIdentifier("flash.mode.execute")
          Text(flashText("flash.mode.planOnly"))
            .tag(FlashWorkspaceMode.planOnly)
            .accessibilityIdentifier("flash.mode.planOnly")
          Text(flashText("flash.mode.simulated"))
            .tag(FlashWorkspaceMode.simulated)
            .accessibilityIdentifier("flash.mode.simulated")
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        .accessibilityIdentifier("flash.mode")
        .disabled(model.isPreparingPlan)

        Button(flashText("flash.action.refresh")) {
          model.refresh()
          onRefreshRuntimeHistory()
        }
        .accessibilityIdentifier("flash.refresh")
        .disabled(
          model.isRefreshing || model.isPreparingPlan || isRuntimeHistoryRefreshing)
      }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.gzip, .data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          model.selectArchive(url)
        } else {
          model.rejectArchiveSelection()
        }
      case .failure: model.rejectArchiveSelection()
      }
    }
    .task(id: model.isSubmitting) {
      guard model.isSubmitting else {
        if model.submission != nil || model.submissionFailure != nil {
          onRefreshRuntimeHistory()
        }
        return
      }
      while !Task.isCancelled && model.isSubmitting {
        onRefreshRuntimeHistory()
        try? await Task.sleep(for: .milliseconds(750))
      }
    }
  }

  private var modeBinding: Binding<FlashWorkspaceMode> {
    Binding(get: { model.mode }, set: { model.setMode($0) })
  }

  // Execute deliberately has no badge: the absence is the statement that
  // this is real. Plan-only wears a purple outline, simulated an orange
  // dashed outline — outline, not filled, so neither reads as a state color.
  @ViewBuilder
  private var modeStatus: some View {
    switch model.mode {
    case .execute:
      EmptyView()
    case .planOnly:
      modeBadge(
        flashText("flash.mode.planOnly.badge"),
        systemImage: "doc.text.magnifyingglass",
        color: .purple,
        dashed: false)
    case .simulated:
      modeBadge(
        flashText("flash.mode.simulated.badge"),
        systemImage: "testtube.2",
        color: .orange,
        dashed: true)
    }
  }

  private func modeBadge(
    _ text: String, systemImage: String, color: Color, dashed: Bool
  ) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
      }
      .accessibilityIdentifier("flash.mode.badge")
  }

  private var availabilitySection: some View {
    GroupBox(flashText("flash.availability.title")) {
      VStack(alignment: .leading, spacing: 8) {
        switch model.workspace.availability {
        case .checking:
          Label(flashText("flash.availability.checking"), systemImage: "hourglass")
            .accessibilityIdentifier("flash.availability.status")
        case .available:
          Label(flashText("flash.availability.available"), systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityIdentifier("flash.availability.status")
        case .unavailable(let reasons):
          Label(flashText("flash.availability.unavailable"), systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .accessibilityIdentifier("flash.availability.status")
          ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
            Text(reason)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Text(flashText("flash.availability.scope"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var deviceAccessSection: some View {
    GroupBox(flashText("flash.deviceAccess.title")) {
      VStack(alignment: .leading, spacing: 10) {
        switch model.deviceAccess.availability {
        case .checking:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(flashText("flash.deviceAccess.checking"))
          }
        case .unavailable(let reason):
          Label(
            flashText("flash.deviceAccess.toolUnavailable"),
            systemImage: "wrench.and.screwdriver.fill"
          )
          .foregroundStyle(.orange)
          Text(reason)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        case .available:
          if let advice = model.deviceAccess.advice {
            Label(
              flashText(deviceAccessVerdictKey(advice.verdict)),
              systemImage: deviceAccessSymbol(advice.verdict)
            )
            .foregroundStyle(deviceAccessColor(advice.verdict))
            .font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
              GridRow {
                Text(flashText("flash.deviceAccess.responsibility"))
                  .foregroundStyle(.secondary)
                Text(flashText(deviceAccessResponsibilityKey(advice.responsibility)))
              }
              GridRow {
                Text(flashText("flash.deviceAccess.nextStep"))
                  .foregroundStyle(.secondary)
                Text(flashText(deviceAccessRemediationKey(advice.remediation)))
                  .fixedSize(horizontal: false, vertical: true)
              }
              if model.deviceAccess.observationCount > 0 {
                GridRow {
                  Text(flashText("flash.deviceAccess.observations"))
                    .foregroundStyle(.secondary)
                  Text(
                    String(
                      format: flashText("flash.deviceAccess.observationValue"),
                      model.deviceAccess.observationCount,
                      model.deviceAccess.observedModes.map(\.rawValue).joined(separator: ", "))
                  )
                }
              }
            }
          }
        }
        if model.deviceAccess.advice?.reprobeAvailable == true {
          Button(flashText("flash.deviceAccess.reprobe")) {
            model.refreshDeviceAccess()
          }
          .disabled(model.isRefreshingDeviceAccess)
          .accessibilityIdentifier("flash.deviceAccess.reprobe")
        }
        if (model.workspace.bootloaderStatus.disposition == .unbound
          || model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared),
          model.workspace.bootloaderStatus.mode == "loader"
        {
          Divider()
          Label(
            flashText("flash.bootloader.unbound.title"),
            systemImage: "externaldrive.badge.questionmark"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          Text(
            flashText(
              model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared
                ? "flash.bootloader.unprepared.detail"
                : "flash.bootloader.unbound.detail"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.workspace.bootloaderStatus.disposition == .exactBoundTarget,
          model.workspace.bootloaderStatus.mode == "loader"
        {
          Label(
            flashText("flash.bootloader.bound"),
            systemImage: "checkmark.seal.fill"
          )
          .foregroundStyle(.green)
          .accessibilityIdentifier("flash.bootloader.bound")
        } else if model.workspace.bootloaderStatus.disposition == .targetBindingUnprepared,
          model.workspace.bootloaderStatus.mode == "hdcNormal"
        {
          Label(
            flashText("flash.binding.unprepared.hdc.title"),
            systemImage: "externaldrive.badge.questionmark"
          )
          .font(.callout.weight(.semibold))
          .foregroundStyle(.orange)
          Text(flashText("flash.binding.unprepared.hdc.detail"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
    .accessibilityIdentifier("flash.deviceAccess")
  }

  private func deviceAccessVerdictKey(_ verdict: RockchipDeviceAccessVerdict) -> String {
    switch verdict {
    case .accessible: "flash.deviceAccess.verdict.accessible"
    case .offlineOrUnauthorized: "flash.deviceAccess.verdict.offline"
    case .permissionDenied: "flash.deviceAccess.verdict.permissionDenied"
    case .driverUnavailable: "flash.deviceAccess.verdict.driverUnavailable"
    case .protocolBlocked: "flash.deviceAccess.verdict.protocolBlocked"
    case .malformedOutput: "flash.deviceAccess.verdict.malformedOutput"
    case .toolBlocked: "flash.deviceAccess.verdict.toolBlocked"
    case .probeFailed: "flash.deviceAccess.verdict.probeFailed"
    }
  }

  private func deviceAccessResponsibilityKey(
    _ responsibility: RockchipDeviceAccessResponsibility
  ) -> String {
    "flash.deviceAccess.responsibility.\(responsibility.rawValue)"
  }

  private func deviceAccessRemediationKey(
    _ remediation: RockchipDeviceAccessRemediation
  ) -> String {
    "flash.deviceAccess.remediation.\(remediation.rawValue)"
  }

  private func deviceAccessSymbol(_ verdict: RockchipDeviceAccessVerdict) -> String {
    switch verdict {
    case .accessible: "checkmark.circle.fill"
    case .offlineOrUnauthorized: "cable.connector.slash"
    case .permissionDenied: "lock.trianglebadge.exclamationmark"
    case .driverUnavailable: "wrench.and.screwdriver.fill"
    case .protocolBlocked, .malformedOutput, .toolBlocked, .probeFailed:
      "exclamationmark.triangle.fill"
    }
  }

  private func deviceAccessColor(_ verdict: RockchipDeviceAccessVerdict) -> Color {
    switch verdict {
    case .accessible: .green
    case .permissionDenied, .driverUnavailable: .red
    case .offlineOrUnauthorized, .protocolBlocked, .malformedOutput, .toolBlocked, .probeFailed:
      .orange
    }
  }

  private var profileAndImageSection: some View {
    GroupBox(flashText("flash.profileImage.title")) {
      VStack(alignment: .leading, spacing: 12) {
        Picker(flashText("flash.profile.label"), selection: profileBinding) {
          ForEach(FlashApplicationFacade.profileReferences, id: \.self) { reference in
            Text(reference).tag(reference)
          }
        }
        .accessibilityIdentifier("flash.profile")
        .disabled(model.isPreparingPlan)

        LabeledContent(flashText("flash.image.label")) {
          Text(model.selectedArchiveURL?.lastPathComponent ?? flashText("flash.image.none"))
            .lineLimit(2)
            .truncationMode(.middle)
            .accessibilityIdentifier("flash.image.value")
        }
        Button(flashText("flash.image.choose")) { isImporterPresented = true }
          .accessibilityIdentifier("flash.image.choose")
          .disabled(model.isPreparingPlan)
        Text(flashText("flash.image.hint"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var profileBinding: Binding<String> {
    Binding(get: { model.profileReference }, set: { model.setProfileReference($0) })
  }

  private var targetSection: some View {
    GroupBox(flashText("flash.target.title")) {
      VStack(alignment: .leading, spacing: 10) {
        if model.workspace.targets.isEmpty {
          Label(flashText("flash.target.none"), systemImage: "externaldrive.badge.questionmark")
            .accessibilityIdentifier("flash.target.empty")
          if let failure = model.workspace.targetLoadFailure {
            Text(failure)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(flashText("flash.target.guidance"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Picker(flashText("flash.target.label"), selection: targetBinding) {
            ForEach(model.workspace.targets) { target in
              Text(target.id).tag(target.id)
            }
          }
          .accessibilityIdentifier("flash.target")
          .disabled(model.isPreparingPlan)
          if let target = model.selectedTarget {
            LabeledContent(flashText("flash.target.binding")) {
              Text(target.bindingRevision, format: .number)
                .monospacedDigit()
                .accessibilityIdentifier("flash.target.binding")
            }
            LabeledContent(flashText("flash.target.toolVersion")) {
              Text(target.toolVersion)
                .font(.body.monospaced())
                .accessibilityIdentifier("flash.target.toolVersion")
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var targetBinding: Binding<String> {
    Binding(get: { model.selectedTargetID }, set: { model.setTargetID($0) })
  }

  private var prerequisitesSection: some View {
    GroupBox(flashText("flash.plan.prerequisites")) {
      VStack(alignment: .leading, spacing: 8) {
        if let plan = model.plan {
          Text(flashText("flash.plan.prerequisitesNote"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          FlashPrerequisitesList(prerequisites: plan.prerequisites)
        } else {
          Text(flashText("flash.plan.prerequisitesAwaitPlan"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
    .accessibilityIdentifier("flash.plan.prerequisitesSection")
  }

  private var exactPlanSection: some View {
    GroupBox(flashText("flash.plan.title")) {
      VStack(alignment: .leading, spacing: 12) {
        if model.isPreparingPlan {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text(flashText("flash.plan.preparing"))
          }
          .accessibilityIdentifier("flash.plan.preparing")
        } else if let plan = model.plan {
          planSummary(plan)
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
              planStep(index: index, step: step)
            }
          }
          .accessibilityIdentifier("flash.plan.steps")
          Divider()
          FlashPlanDetailsView(plan: plan)
        } else {
          ContentUnavailableView {
            Label(flashText("flash.plan.empty"), systemImage: "list.number")
          } description: {
            Text(flashText("flash.plan.emptyDescription"))
          }
          .accessibilityIdentifier("flash.plan.empty")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private func planSummary(_ plan: FlashExactPlanPresentation) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
      summaryRow("flash.plan.build", plan.runtimeBuildVersion)
      summaryRow(
        "flash.plan.size",
        ByteCountFormatter.string(fromByteCount: plan.archiveSizeBytes, countStyle: .file))
      summaryRow("flash.plan.archiveHash", plan.archiveSHA256, monospaced: true)
      summaryRow("flash.plan.digest", plan.planDigestSHA256, monospaced: true)
      summaryRow("flash.plan.stepSetDigest", plan.stepSetDigestSHA256, monospaced: true)
      summaryRow("flash.plan.toolchain", plan.toolchainFingerprint, monospaced: true)
    }
  }

  private func summaryRow(
    _ key: String, _ value: String, monospaced: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(flashText(key)).foregroundStyle(.secondary)
      Text(value)
        .font(monospaced ? .body.monospaced() : .body)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(value)
        .accessibilityLabel(value)
        .textSelection(.enabled)
    }
  }

  private func planStep(index: Int, step: FlashPlanStepPresentation) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          stepIdentity(index: index, step: step)
          Spacer(minLength: 8)
          effectLabel(step.effect)
          dispositionLabel(step.disposition)
        }
        VStack(alignment: .leading, spacing: 4) {
          stepIdentity(index: index, step: step)
          HStack(spacing: 8) {
            effectLabel(step.effect)
            dispositionLabel(step.disposition)
          }
        }
      }
      Text(step.argumentSummary)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  private func stepIdentity(index: Int, step: FlashPlanStepPresentation) -> some View {
    Text("\(index + 1). \(step.kind)")
      .font(.callout.monospaced().weight(.semibold))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func effectLabel(_ effect: FlashPlanEffect) -> some View {
    let key: String
    let symbol: String
    let color: Color
    switch effect {
    case .hostOnly:
      key = "flash.effect.hostOnly"
      symbol = "desktopcomputer"
      color = .secondary
    case .readOnly:
      key = "flash.effect.readOnly"
      symbol = "eye"
      color = .blue
    case .deviceMutation:
      key = "flash.effect.deviceMutation"
      symbol = "arrow.triangle.2.circlepath"
      color = .orange
    case .destructive:
      key = "flash.effect.destructive"
      symbol = "exclamationmark.triangle.fill"
      color = .red
    }
    return Label(flashText(key), systemImage: symbol)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color)
  }

  private func dispositionLabel(_ disposition: FlashPlanStepDisposition) -> some View {
    let key: String
    switch disposition {
    case .planned: key = "flash.disposition.planned"
    case .simulatedPreview: key = "flash.disposition.simulatedPreview"
    case .executionLocked: key = "flash.disposition.executionLocked"
    }
    return Text(flashText(key))
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  private var reviewSection: some View {
    GroupBox(flashText("flash.review.title")) {
      VStack(alignment: .leading, spacing: 12) {
        if let errorCode = model.planFailureCode {
          Label(flashText(planFailureKey(errorCode)), systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .accessibilityIdentifier("flash.plan.error")
          if let detail = model.planFailureDetail {
            Text(detail)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Button(action: { model.preparePlan() }) {
          Text(
            flashText(
              model.plan == nil
                ? "flash.action.preparePlan"
                : "flash.action.preparePlanAgain"))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("flash.plan.prepare")
        .disabled(!model.canPreparePlan)

        if model.selectedArchiveURL == nil {
          Text(flashText("flash.review.selectImageBlocker"))
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if model.mode != .simulated && model.selectedTarget == nil {
          Text(flashText("flash.review.selectTargetBlocker"))
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        if let plan = model.plan {
          Divider()
          Text(flashText("flash.impact.title"))
            .font(.subheadline.weight(.semibold))
          ForEach(Array(plan.dataImpact.enumerated()), id: \.offset) { _, impact in
            dataImpactLabel(impact)
              .accessibilityIdentifier(dataImpactIdentifier(impact))
          }
        }

        switch model.mode {
        case .execute:
          Divider()
          if model.plan != nil {
            Label(
              flashText("flash.execute.recoveryPath"),
              systemImage: "arrow.uturn.backward.circle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            Label(
              flashText("flash.execute.powerWarning"),
              systemImage: "bolt.trianglebadge.exclamationmark.fill"
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          }
          Button {
            model.submit()
          } label: {
            if model.isSubmitting {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flashText("flash.action.submitting"))
              }
            } else {
              Text(flashText("flash.action.submit"))
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!model.canSubmit)
          .accessibilityIdentifier("flash.execute.submit")
          if model.activeJobID != nil {
            Button(flashText("flash.action.cancel"), role: .cancel) {
              model.cancelActiveJob()
            }
            .disabled(model.isCancelling)
            .accessibilityIdentifier("flash.execute.cancel")
            Text(flashText("flash.action.cancel.help"))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let plan = model.plan,
            !plan.blockingRequiredPrerequisites.isEmpty,
            !model.willActivateCurrentTargetOnSubmit,
            !model.isSubmitting
          {
            Label(
              flashText("flash.execute.prerequisiteBlocker"),
              systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.execute.prerequisiteBlocker")
          } else if !model.canSubmit && !model.isSubmitting {
            Label(
              flashText("flash.execute.planRequired"),
              systemImage: "list.bullet.clipboard"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Label(flashText("flash.execute.reviewNotAuthority"), systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if let submission = model.submission {
            let successful = submission.state == "succeeded" || submission.state == "recovered"
            Label(
              String(format: flashText("flash.execute.terminal"), submission.state),
              systemImage: successful
                ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .foregroundStyle(successful ? .green : .red)
            .accessibilityIdentifier("flash.execute.terminal")
            Text(submission.jobID)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .accessibilityIdentifier("flash.execute.jobId")
            if let postflight = model.postflightEvidence, let plan = model.plan {
              flashPostflight(plan: plan, evidence: postflight)
            }
          } else if let failure = model.submissionFailure {
            Label(failure, systemImage: "xmark.octagon.fill")
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("flash.execute.failure")
          }
        case .planOnly:
          Label(flashText("flash.planOnly.noSubmission"), systemImage: "checkmark.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.noOperationSubmitted")
        case .simulated:
          Label(flashText("flash.simulated.previewOnly"), systemImage: "testtube.2")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.noOperationSubmitted")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
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

  private func dataImpactIdentifier(_ impact: FlashDataImpactPresentation) -> String {
    switch impact {
    case .mappedPartitionsOverwritten:
      return "flash.impact.partitions"
    case .userDataDestroyed:
      return "flash.impact.userdata"
    case .forbiddenAreasPreserved:
      return "flash.impact.preserved"
    }
  }

  private func flashPostflight(
    plan: FlashExactPlanPresentation,
    evidence: RuntimeJobEvidencePresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(flashText("flash.postflight.title"))
        .font(.subheadline.weight(.semibold))
      if let observedFirmware = evidence.observedFirmware {
        postflightRow(
          label: flashText("flash.postflight.build"),
          expected: plan.runtimeBuildVersion,
          observed: observedFirmware,
          matches: observedFirmware == plan.runtimeBuildVersion,
          identifier: "flash.postflight.build")
      }
      if let before = plan.target?.bindingRevision,
        let after = evidence.observedBindingRevision
      {
        let binding = FlashPostflightPresentationBuilder.binding(
          plannedRevision: before,
          observedRevision: after)
        postflightRow(
          label: flashText("flash.postflight.binding"),
          expected: binding.expected,
          observed: binding.observed,
          matches: binding.matches,
          identifier: "flash.postflight.binding")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("flash.postflight")
  }

  private func postflightRow(
    label: String,
    expected: String,
    observed: String,
    matches: Bool,
    identifier: String
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: matches ? "checkmark.circle.fill" : "xmark.octagon.fill")
        .foregroundStyle(matches ? .green : .red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.callout.weight(.semibold))
        Text(
          String(
            format: flashText("flash.postflight.comparison"),
            expected, observed)
        )
        .font(.caption.monospaced())
        .textSelection(.enabled)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      String(
        format: flashText(
          matches ? "flash.postflight.match" : "flash.postflight.mismatch"),
        label, expected, observed))
    .accessibilityIdentifier(identifier)
  }

  private func planFailureKey(_ code: FlashPlanFailureCode) -> String {
    switch code {
    case .fileAccessDenied: "flash.error.fileAccess"
    case .unreadableArchive: "flash.error.unreadable"
    case .invalidArchive: "flash.error.invalid"
    case .unsupportedBundle: "flash.error.unsupported"
    case .planMaterializationFailed: "flash.error.plan"
    }
  }
}

@MainActor
final class FlashWorkspaceViewModel: ObservableObject {
  @Published private(set) var workspace = FlashWorkspacePresentation.loading
  @Published private(set) var mode = FlashWorkspaceMode.planOnly
  @Published private(set) var selectedTargetID = ""
  @Published private(set) var selectedArchiveURL: URL?
  @Published private(set) var plan: FlashExactPlanPresentation?
  @Published private(set) var planFailureCode: FlashPlanFailureCode?
  @Published private(set) var planFailureDetail: String?
  @Published private(set) var submission: FlashSubmissionPresentation?
  @Published private(set) var submissionFailure: String?
  @Published private(set) var postflightEvidence: RuntimeJobEvidencePresentation?
  @Published private(set) var deviceAccess = RockchipDeviceAccessPresentation.loading
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPreparingPlan = false
  @Published private(set) var isSubmitting = false
  @Published private(set) var isCancelling = false
  @Published private(set) var activeJobID: String?
  @Published private(set) var isRefreshingDeviceAccess = false
  @Published private(set) var profileReference =
    FlashApplicationFacade.profileReferences.last ?? "dayu200"

  private let provider: any FlashApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding
  private let deviceAccessProvider: any RockchipDeviceAccessApplicationProviding
  private let preparesUITestPlan: Bool
  /// The UI-test state file, honored only when the launch already carries the
  /// Flash fixture arguments: it lets one launched sweep walk the empty
  /// workspace first and enter the exact-plan flow later, without a relaunch.
  /// A production launch has no state URL and never reads one.
  private let uiTestFixtureStateURL: URL?
  private var didPrepareUITestPlan = false

  init(
    provider: any FlashApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil,
    deviceAccessProvider: (any RockchipDeviceAccessApplicationProviding)? = nil,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    self.provider = provider
    self.detailProvider = detailProvider
      ?? RuntimeJobDetailApplicationFacade.make(arguments: arguments)
    self.deviceAccessProvider = deviceAccessProvider
      ?? RockchipDeviceAccessApplicationFacade.make(arguments: arguments)
    preparesUITestPlan = arguments.contains("--ui-test-flash-plan")
    if arguments.contains("--ui-test-flash") || preparesUITestPlan,
      let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      uiTestFixtureStateURL = URL(fileURLWithPath: arguments[index + 1])
    } else {
      uiTestFixtureStateURL = nil
    }
    if preparesUITestPlan {
      mode = .execute
      selectedArchiveURL = URL(fileURLWithPath: "/ui-fixture/dayu200-images.tar.gz")
    }
  }

  private var uiTestFixtureStateRequestsPlan: Bool {
    guard let uiTestFixtureStateURL,
      let text = try? String(contentsOf: uiTestFixtureStateURL, encoding: .utf8)
    else { return false }
    return text.contains("--ui-test-flash-plan")
  }

  var selectedTarget: FlashTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var canPreparePlan: Bool {
    selectedArchiveURL != nil
      && (mode == .simulated || selectedTarget != nil)
      && !isPreparingPlan
  }

  var canSubmit: Bool {
    guard mode == .execute, !isSubmitting,
      let archive = selectedArchiveURL,
      let plan
    else { return false }
    return !archive.path.isEmpty
      && plan.target == selectedTarget
      && plan.mode == .execute
      && (plan.blockingRequiredPrerequisites.isEmpty || willActivateCurrentTargetOnSubmit)
  }

  var willActivateCurrentTargetOnSubmit: Bool {
    guard mode == .execute, let selectedTarget else { return false }
    let status = workspace.bootloaderStatus
    guard status.observationCount == 1,
      status.mode == "loader" || status.mode == "hdcNormal"
    else { return false }
    switch status.disposition {
    case .unbound:
      return status.mode == "loader"
    case .targetBindingUnprepared:
      return status.targetID == selectedTarget.id
        && status.bindingRevision == selectedTarget.bindingRevision
    case .absent, .ambiguous, .exactBoundTarget:
      return false
    }
  }

  func refresh() {
    refreshDeviceAccess()
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshWorkspace()
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      let previousTarget = self.selectedTarget
      let nextSelectedTargetID =
        next.targets.contains(where: { $0.id == self.selectedTargetID })
        ? self.selectedTargetID
        : next.targets.first?.id ?? ""
      let nextTarget = next.targets.first { $0.id == nextSelectedTargetID }
      self.workspace = next
      self.selectedTargetID = nextSelectedTargetID
      if previousTarget != nextTarget {
        self.invalidatePlan()
      }
      if self.preparesUITestPlan || self.uiTestFixtureStateRequestsPlan,
        !self.didPrepareUITestPlan
      {
        self.didPrepareUITestPlan = true
        if self.selectedArchiveURL == nil {
          self.mode = .execute
          self.selectedArchiveURL = URL(fileURLWithPath: "/ui-fixture/dayu200-images.tar.gz")
        }
        self.preparePlan()
      }
    }
  }

  func refreshDeviceAccess() {
    guard !isRefreshingDeviceAccess else { return }
    isRefreshingDeviceAccess = true
    let provider = deviceAccessProvider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self else { return }
      defer { self.isRefreshingDeviceAccess = false }
      guard !Task.isCancelled else { return }
      self.deviceAccess = next
    }
  }

  func setMode(_ mode: FlashWorkspaceMode) {
    guard self.mode != mode else { return }
    self.mode = mode
    invalidatePlan()
  }

  func setProfileReference(_ reference: String) {
    guard profileReference != reference else { return }
    profileReference = reference
    invalidatePlan()
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    invalidatePlan()
  }

  func selectArchive(_ url: URL) {
    selectedArchiveURL = url
    invalidatePlan()
  }

  func rejectArchiveSelection() {
    planFailureCode = .fileAccessDenied
    planFailureDetail = nil
  }

  func preparePlan() {
    guard let archiveURL = selectedArchiveURL, canPreparePlan else { return }
    isPreparingPlan = true
    plan = nil
    submission = nil
    submissionFailure = nil
    postflightEvidence = nil
    planFailureCode = nil
    planFailureDetail = nil
    let provider = provider
    let profileReference = profileReference
    let mode = mode
    let target = selectedTarget
    Task { [weak self] in
      let result = await provider.preparePlan(
        archiveURL: archiveURL,
        profileReference: profileReference,
        mode: mode.executionMode,
        target: target)
      guard let self else { return }
      defer { self.isPreparingPlan = false }
      guard
        self.selectedArchiveURL == archiveURL,
        self.profileReference == profileReference,
        self.mode == mode,
        self.selectedTarget == target,
        !Task.isCancelled
      else { return }
      switch result {
      case .ready(let plan):
        self.plan = plan
      case .failed(let code, let detail):
        self.planFailureCode = code
        self.planFailureDetail = detail
      }
    }
  }

  func submit() {
    guard canSubmit, let archiveURL = selectedArchiveURL, let plan else { return }
    isSubmitting = true
    submission = nil
    submissionFailure = nil
    postflightEvidence = nil
    let provider = provider
    let detailProvider = detailProvider
    Task { [weak self] in
      guard let self else { return }
      guard self.selectedArchiveURL == archiveURL,
        self.plan == plan,
        !Task.isCancelled
      else {
        self.isSubmitting = false
        return
      }
      var executionPlan = plan
      if self.willActivateCurrentTargetOnSubmit, let selectedTarget = plan.target {
        let bindingResult = await provider.bindCurrentLoader(target: selectedTarget)
        guard self.selectedArchiveURL == archiveURL,
          self.plan == plan,
          self.selectedTarget == selectedTarget,
          !Task.isCancelled
        else {
          self.isSubmitting = false
          return
        }
        guard case .bound(let rebound) = bindingResult else {
          self.isSubmitting = false
          if case .failed(let detail) = bindingResult {
            self.submissionFailure = detail
          }
          return
        }
        self.applyBoundLoader(rebound)
        let refreshed = await provider.preparePlan(
          archiveURL: archiveURL,
          profileReference: plan.profileReference,
          mode: .execute,
          target: rebound)
        guard self.selectedArchiveURL == archiveURL,
          self.selectedTarget == rebound,
          !Task.isCancelled
        else {
          self.isSubmitting = false
          return
        }
        guard case .ready(let reboundPlan) = refreshed else {
          self.isSubmitting = false
          if case .failed(let code, let detail) = refreshed {
            self.planFailureCode = code
            self.planFailureDetail = detail
          }
          return
        }
        self.plan = reboundPlan
        guard reboundPlan.target == rebound,
          reboundPlan.mode == .execute,
          reboundPlan.blockingRequiredPrerequisites.isEmpty
        else {
          self.isSubmitting = false
          self.submissionFailure =
            "Loader was bound, but Runtime prerequisites still block Flash"
          return
        }
        executionPlan = reboundPlan
      }

      let submissionResult = await provider.submit(
        archiveURL: archiveURL, plan: executionPlan)
      guard self.selectedArchiveURL == archiveURL,
        self.plan == executionPlan,
        !Task.isCancelled
      else {
        self.isSubmitting = false
        return
      }
      switch submissionResult {
      case .accepted(let jobID):
        self.activeJobID = jobID
        let runResult = await provider.run(jobID: jobID)
        guard self.selectedArchiveURL == archiveURL,
          self.plan == executionPlan,
          !Task.isCancelled
        else {
          self.activeJobID = nil
          self.isSubmitting = false
          self.isCancelling = false
          return
        }
        self.activeJobID = nil
        self.isSubmitting = false
        self.isCancelling = false
        guard case .completed(let terminal) = runResult else {
          if case .failed(let detail) = runResult {
            self.submissionFailure = detail
          }
          return
        }
        self.submission = terminal
        let detail = await detailProvider.loadJobDetail(
          jobID: terminal.jobID,
          operationReference: "flash.dayu200")
        guard self.selectedArchiveURL == archiveURL,
          self.plan == executionPlan,
          !Task.isCancelled
        else { return }
        self.postflightEvidence = detail.evidence
      case .failed(let detail):
        self.isSubmitting = false
        self.submissionFailure = detail
      }
    }
  }

  private func applyBoundLoader(_ rebound: FlashTargetPresentation) {
    let observedMode = workspace.bootloaderStatus.mode
    workspace = FlashWorkspacePresentation(
      availability: workspace.availability,
      targets: workspace.targets.map { $0.id == rebound.id ? rebound : $0 },
      bootloaderStatus: RockchipBootloaderStatus(
        disposition: .exactBoundTarget,
        observationCount: 1,
        mode: observedMode,
        targetID: rebound.id,
        bindingRevision: rebound.bindingRevision),
      targetLoadFailure: workspace.targetLoadFailure)
  }

  func cancelActiveJob() {
    guard let jobID = activeJobID, !isCancelling else { return }
    isCancelling = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self, self.activeJobID == jobID else { return }
      self.isCancelling = false
      if !accepted {
        self.submissionFailure = "Runtime refused the cancellation request"
      }
    }
  }

  private func invalidatePlan() {
    plan = nil
    submission = nil
    submissionFailure = nil
    postflightEvidence = nil
    activeJobID = nil
    isCancelling = false
    planFailureCode = nil
    planFailureDetail = nil
  }
}
