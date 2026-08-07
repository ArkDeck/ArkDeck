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
/// It deliberately has no submit/run/authorization client. Execute remains a
/// visible locked state until a separately reviewed E2 App transport exists.
struct FlashWorkspaceView: View {
  @ObservedObject var model: FlashWorkspaceViewModel
  let runtimeHistory: RuntimeHistoryPresentation
  let isRuntimeHistoryRefreshing: Bool
  let onRefreshRuntimeHistory: () -> Void
  let onOpenHistory: () -> Void
  @State private var isImporterPresented = false
  @State private var confirmationPlan: FlashExactPlanPresentation?
  @State private var isConfirmationPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        modeStatus
        availabilitySection
        FlashRuntimeActivityView(
          presentation: runtimeHistory,
          onOpenHistory: onOpenHistory)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
              profileAndImageSection
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
    .sheet(
      isPresented: $isConfirmationPresented,
      onDismiss: { confirmationPlan = nil }
    ) {
      if let confirmationPlan {
        FlashDestructiveConfirmationSheet(plan: confirmationPlan) {
          destructivePhrase, userdataPhrase in
          model.confirm(
            reviewedPlan: confirmationPlan,
            destructivePhrase: destructivePhrase,
            userdataPhrase: userdataPhrase)
        }
      }
    }
  }

  private var modeBinding: Binding<FlashWorkspaceMode> {
    Binding(get: { model.mode }, set: { model.setMode($0) })
  }

  @ViewBuilder
  private var modeStatus: some View {
    switch model.mode {
    case .execute:
      EmptyView()
    case .planOnly:
      Label(flashText("flash.mode.planOnly.badge"), systemImage: "doc.text.magnifyingglass")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("flash.mode.badge")
    case .simulated:
      Label(flashText("flash.mode.simulated.badge"), systemImage: "testtube.2")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.purple)
        .accessibilityIdentifier("flash.mode.badge")
    }
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
          }
        }

        switch model.mode {
        case .execute:
          Divider()
          Label(flashText("flash.execute.locked"), systemImage: "lock.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flash.execute.blocker")
          if let handoff = model.humanHandoff {
            confirmedHandoff(handoff)
            Button(flashText("flash.action.submitLocked")) {}
              .buttonStyle(.borderedProminent)
              .tint(.red)
              .disabled(true)
              .accessibilityIdentifier("flash.execute.submit")
            Label(flashText("flash.execute.submitLockReason"), systemImage: "lock.shield")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Label(
              flashText("flash.execute.confirmationRequired"),
              systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            Button(flashText("flash.action.reviewImpact")) {
              if let plan = model.plan {
                confirmationPlan = plan
                isConfirmationPresented = true
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canReviewDestructiveImpact)
            .accessibilityIdentifier("flash.execute.review")
            .accessibilityValue(
              isConfirmationPresented ? flashText("flash.confirm.title") : "")
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

  private func confirmedHandoff(_ handoff: FlashHumanHandoffPresentation) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(flashText("flash.execute.confirmed"), systemImage: "checkmark.seal.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.orange)
      LabeledContent(flashText("flash.confirm.target")) {
        Text("\(handoff.target.id) · r\(handoff.target.bindingRevision)")
          .font(.body.monospaced())
      }
      LabeledContent(flashText("flash.execute.confirmedAt")) {
        Text(handoff.confirmedAtUTC).font(.body.monospaced())
      }
      LabeledContent(flashText("flash.plan.digest")) {
        Text(handoff.planDigestSHA256)
          .font(.body.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .help(handoff.planDigestSHA256)
      }
      LabeledContent(flashText("flash.plan.archiveHash")) {
        Text(handoff.archiveSHA256)
          .font(.body.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .help(handoff.archiveSHA256)
      }
      Label(flashText("flash.execute.reviewNotAuthority"), systemImage: "exclamationmark.shield")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("flash.execute.handoff")
    }
    .padding(12)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
  @Published private(set) var humanHandoff: FlashHumanHandoffPresentation?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPreparingPlan = false
  @Published private(set) var profileReference =
    FlashApplicationFacade.profileReferences.last ?? "dayu200@1"

  private let provider: any FlashApplicationProviding
  private let preparesUITestPlan: Bool
  private var didPrepareUITestPlan = false

  init(
    provider: any FlashApplicationProviding,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    self.provider = provider
    preparesUITestPlan = arguments.contains("--ui-test-flash-plan")
    if preparesUITestPlan {
      mode = .execute
      selectedArchiveURL = URL(fileURLWithPath: "/ui-fixture/dayu200-images.tar.gz")
    }
  }

  var selectedTarget: FlashTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var canPreparePlan: Bool {
    selectedArchiveURL != nil
      && (mode == .simulated || selectedTarget != nil)
      && !isPreparingPlan
  }

  var canReviewDestructiveImpact: Bool {
    mode == .execute
      && plan?.mode == .execute
      && plan?.target == selectedTarget
      && !isPreparingPlan
  }

  func refresh() {
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
      if self.preparesUITestPlan, !self.didPrepareUITestPlan {
        self.didPrepareUITestPlan = true
        self.preparePlan()
      }
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
    humanHandoff = nil
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

  func confirm(
    reviewedPlan: FlashExactPlanPresentation,
    destructivePhrase: String,
    userdataPhrase: String
  ) -> FlashManualConfirmationResult {
    let result = FlashManualConfirmationValidator.confirm(
      currentPlan: plan,
      reviewedPlan: reviewedPlan,
      currentTarget: selectedTarget,
      destructivePhrase: destructivePhrase,
      userdataPhrase: userdataPhrase,
      confirmedAtUTC: ISO8601DateFormatter().string(from: Date()))
    if case .accepted(let handoff) = result {
      humanHandoff = handoff
    }
    return result
  }

  private func invalidatePlan() {
    plan = nil
    humanHandoff = nil
    planFailureCode = nil
    planFailureDetail = nil
  }
}
